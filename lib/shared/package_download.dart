import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../core/failure.dart';
import '../core/gitlab_api.dart';
import '../core/models.dart';
import '../core/registry_models.dart';
import 'artifact_storage.dart';
import 'workspace_ui.dart';

const packageDownloadMaximumBytes = 256 * 1024 * 1024;

ApiFailure get packageChecksumMismatch => ApiFailure(
  FailureKind.invalidResponse,
  title: '套件檔案驗證失敗',
  detail: '下載內容的 SHA-256 與 GitLab 檔案資訊不一致，檔案已刪除。',
);

ApiFailure get packageSizeMismatch => ApiFailure(
  FailureKind.invalidResponse,
  title: '套件檔案驗證失敗',
  detail: '下載內容的大小與 GitLab 檔案資訊不一致，檔案已刪除。',
);

String? packageFileDownloadBlockReason(
  RegistryPackage package,
  RegistryPackageFile file, {
  int maximumBytes = packageDownloadMaximumBytes,
}) {
  if (package.type.trim().isEmpty) return '套件類型未知，無法安全下載。';
  if (file.size < 0) return 'GitLab 未提供有效檔案大小，無法驗證下載。';
  if (file.size > maximumBytes) return '檔案超過 256 MiB 下載上限。';
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(file.sha256)) {
    return 'GitLab 未提供有效 SHA-256，無法驗證下載。';
  }
  return null;
}

abstract interface class PackageDownloader {
  Future<File> download({
    required int projectId,
    required RegistryPackage package,
    required RegistryPackageFile file,
    required Account account,
    required bool Function() isCurrent,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
  });
}

typedef PackageFileHasher = Future<String> Function(File file);

final class DefaultPackageDownloader implements PackageDownloader {
  DefaultPackageDownloader({
    required this.api,
    this.openSink = openArtifactSink,
    this.promote = promoteArtifactFile,
    this.attemptDirectory = attachmentAttemptDirectory,
    this.hashFile = hashPackageFile,
    this.maximumBytes = packageDownloadMaximumBytes,
  });

  final GitLabApi api;
  final IOSink Function(File file) openSink;
  final Future<File> Function(File partial, File target) promote;
  final Future<Directory> Function(Account account, int projectId)
  attemptDirectory;
  final PackageFileHasher hashFile;
  final int maximumBytes;

  @override
  Future<File> download({
    required int projectId,
    required RegistryPackage package,
    required RegistryPackageFile file,
    required Account account,
    required bool Function() isCurrent,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
  }) async {
    IOSink? ownedSink;
    Directory? ownedDirectory;
    File? ownedPartial;
    Object? sinkFailure;
    final abort = Completer<void>();
    if (cancel != null) {
      unawaited(
        cancel.then((_) {
          if (!abort.isCompleted) abort.complete();
        }),
      );
    }

    bool current() => !abort.isCompleted && !api.isClosed && isCurrent();
    void requireCurrent() {
      if (!current()) throw const ApiFailure(FailureKind.cancelled);
    }

    Future<void> cleanup() async {
      final sink = ownedSink;
      ownedSink = null;
      if (sink != null) {
        try {
          await sink.close();
        } on Object catch (error) {
          if (error is! StateError && error is! FileSystemException) rethrow;
        }
      }
      await deleteAttemptFiles(ownedDirectory, ownedPartial);
      ownedDirectory = null;
      ownedPartial = null;
    }

    try {
      requireCurrent();
      final fresh = await api.packageFileForDownload(
        projectId,
        package,
        file,
        isCurrent: current,
      );
      requireCurrent();
      final blocked = packageFileDownloadBlockReason(
        package,
        fresh,
        maximumBytes: maximumBytes,
      );
      if (blocked != null) {
        throw ApiFailure(
          fresh.size > maximumBytes
              ? FailureKind.tooLarge
              : FailureKind.unsupported,
          title: '無法下載套件檔案',
          detail: blocked,
        );
      }

      final directory = await attemptDirectory(account, projectId);
      ownedDirectory = directory;
      requireCurrent();
      final partial = File('${directory.path}/$artifactPartialName');
      ownedPartial = partial;
      final sink = openSink(partial);
      ownedSink = sink;
      unawaited(
        sink.done.then<void>(
          (_) {},
          onError: (Object error, StackTrace _) {
            sinkFailure ??= error;
            if (!abort.isCompleted) abort.complete();
          },
        ),
      );

      final result = await api.downloadPackageFile(
        projectId,
        package.id,
        fresh.id,
        sink: sink,
        fileName: attachmentDownloadFileName(
          fresh.name,
          fallback: 'package-file-${fresh.id}.bin',
        ),
        cancel: abort.future,
        onProgress: onProgress,
        maxBytes: maximumBytes,
      );
      if (sinkFailure != null) throw sinkFailure!;
      requireCurrent();
      await sink.flush();
      if (sinkFailure != null) throw sinkFailure!;
      requireCurrent();
      await sink.close();
      ownedSink = null;
      if (sinkFailure != null) throw sinkFailure!;
      requireCurrent();

      final actualSize = await partial.length();
      requireCurrent();
      if (result.bytesWritten != fresh.size || actualSize != fresh.size) {
        throw packageSizeMismatch;
      }
      final actualSha256 = await hashFile(partial);
      requireCurrent();
      if (actualSha256.toLowerCase() != fresh.sha256.toLowerCase()) {
        throw packageChecksumMismatch;
      }

      final safeName = attachmentDownloadFileName(
        fresh.name,
        fallback: 'package-file-${fresh.id}.bin',
      );
      final target = File('${directory.path}/$safeName');
      requireCurrent();
      final saved = await promote(partial, target);
      ownedPartial = null;
      if (sinkFailure != null || !current()) {
        if (saved.existsSync()) await saved.delete();
        throw sinkFailure ?? const ApiFailure(FailureKind.cancelled);
      }
      ownedDirectory = null;
      return saved;
    } catch (error) {
      await cleanup();
      final cause = sinkFailure ?? error;
      if (cause is FileSystemException) throw ApiFailure.artifactStorage;
      if (cause is ApiFailure) rethrow;
      throw safeFailure(cause);
    }
  }
}

Future<String> hashPackageFile(File file) =>
    Isolate.run(() => _hashPackageFilePath(file.path));

Future<String> _hashPackageFilePath(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

class PackageDownloadSheet extends StatefulWidget {
  const PackageDownloadSheet({
    super.key,
    required this.account,
    required this.api,
    required this.projectId,
    required this.projectPath,
    required this.package,
    required this.file,
    required this.isCurrent,
    this.ownerChanges,
    this.downloader,
    this.sharer = const SystemArtifactSharer(),
  });

  final Account account;
  final GitLabApi api;
  final int projectId;
  final String projectPath;
  final RegistryPackage package;
  final RegistryPackageFile file;
  final bool Function() isCurrent;
  final Listenable? ownerChanges;
  final PackageDownloader? downloader;
  final ArtifactSharer sharer;

  @override
  State<PackageDownloadSheet> createState() => _PackageDownloadSheetState();
}

class _PackageDownloadSheetState extends State<PackageDownloadSheet> {
  var _abort = Completer<void>();
  late final ArtifactProgress _progress;
  int _attempt = 0;
  bool _disposed = false;
  bool _done = false;
  bool _popWhenCancelled = false;
  bool _sharing = false;
  ApiFailure? _error;
  File? _saved;

  @override
  void initState() {
    super.initState();
    _progress = ArtifactProgress(initial: (0, widget.file.size));
    widget.ownerChanges?.addListener(_ownerChanged);
    unawaited(_start());
  }

  @override
  void didUpdateWidget(covariant PackageDownloadSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      oldWidget.ownerChanges?.removeListener(_ownerChanged);
      widget.ownerChanges?.addListener(_ownerChanged);
    }
    final identityChanged =
        oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.projectId != widget.projectId ||
        oldWidget.package.id != widget.package.id ||
        oldWidget.package.name != widget.package.name ||
        oldWidget.package.version != widget.package.version ||
        oldWidget.package.type != widget.package.type ||
        oldWidget.file.id != widget.file.id ||
        oldWidget.file.name != widget.file.name ||
        oldWidget.file.size != widget.file.size ||
        oldWidget.file.sha256 != widget.file.sha256 ||
        !identical(oldWidget.downloader, widget.downloader);
    if (identityChanged) {
      _attempt++;
      if (!_abort.isCompleted) _abort.complete();
      final saved = _saved;
      _saved = null;
      if (saved != null) unawaited(deleteAttemptFiles(saved.parent, saved));
      _done = false;
      _error = null;
      _sharing = false;
      _progress.report(0, widget.file.size, completed: true);
      if (widget.isCurrent()) unawaited(_start());
    }
  }

  bool _current(int attempt, Completer<void> abort) =>
      !_disposed &&
      mounted &&
      attempt == _attempt &&
      identical(abort, _abort) &&
      !abort.isCompleted &&
      !widget.api.isClosed &&
      widget.isCurrent();

  void _ownerChanged() {
    if (widget.isCurrent()) return;
    _attempt++;
    if (!_abort.isCompleted) _abort.complete();
    final saved = _saved;
    _saved = null;
    if (saved != null) unawaited(deleteAttemptFiles(saved.parent, saved));
    if (mounted && ModalRoute.of(context)?.isCurrent == true) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    widget.ownerChanges?.removeListener(_ownerChanged);
    _disposed = true;
    _attempt++;
    if (!_abort.isCompleted) _abort.complete();
    final saved = _saved;
    _saved = null;
    if (saved != null) unawaited(deleteAttemptFiles(saved.parent, saved));
    _progress.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final attempt = ++_attempt;
    final abort = Completer<void>();
    _abort = abort;
    final downloader =
        widget.downloader ?? DefaultPackageDownloader(api: widget.api);
    try {
      if (!_current(attempt, abort)) {
        throw const ApiFailure(FailureKind.cancelled);
      }
      final blocked = packageFileDownloadBlockReason(
        widget.package,
        widget.file,
      );
      if (blocked != null) {
        throw ApiFailure(
          widget.file.size > packageDownloadMaximumBytes
              ? FailureKind.tooLarge
              : FailureKind.unsupported,
          title: '無法下載套件檔案',
          detail: blocked,
        );
      }
      final file = await downloader.download(
        projectId: widget.projectId,
        package: widget.package,
        file: widget.file,
        account: widget.account,
        isCurrent: () => _current(attempt, abort),
        cancel: abort.future,
        onProgress: (received, total) {
          if (!_current(attempt, abort)) return;
          _progress.report(received, total);
        },
      );
      if (!_current(attempt, abort)) {
        await deleteAttemptFiles(file.parent, file);
        return;
      }
      final length = await file.length();
      if (!_current(attempt, abort)) {
        await deleteAttemptFiles(file.parent, file);
        return;
      }
      _saved = file;
      _progress.report(length, length, completed: true);
      setState(() {
        _done = true;
        _error = null;
      });
    } catch (error) {
      if (_disposed || !mounted || attempt != _attempt) return;
      final failure = error is ApiFailure ? error : safeFailure(error);
      if (failure.kind == FailureKind.cancelled) {
        if (_popWhenCancelled) Navigator.of(context).pop();
        return;
      }
      setState(() => _error = failure);
    }
  }

  Future<void> _retry() async {
    if (!_abort.isCompleted) _abort.complete();
    final saved = _saved;
    _saved = null;
    if (saved != null) await deleteAttemptFiles(saved.parent, saved);
    if (!mounted || _disposed || !widget.isCurrent()) return;
    setState(() {
      _error = null;
      _done = false;
      _sharing = false;
    });
    _progress.report(0, widget.file.size, completed: true);
    await _start();
  }

  void _cancel() {
    _popWhenCancelled = true;
    if (!_abort.isCompleted) _abort.complete();
  }

  Future<void> _share(BuildContext buttonContext) async {
    final file = _saved;
    final attempt = _attempt;
    final abort = _abort;
    if (file == null || _sharing || !_current(attempt, abort)) return;
    setState(() => _sharing = true);
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    try {
      if (!_current(attempt, abort)) return;
      await shareDownloadedArtifact(
        widget.sharer,
        file.path,
        sharePositionOrigin: origin,
      );
      if (!_current(attempt, abort)) {
        await deleteAttemptFiles(file.parent, file);
        if (identical(_saved, file)) _saved = null;
      }
    } catch (error) {
      if (mounted && _current(attempt, abort)) showFailure(context, error);
    } finally {
      if (_current(attempt, abort)) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.file.name,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            '${formatByteCount(widget.file.size)} · SHA-256 ${_shortPackageSha(widget.file.sha256)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (_error != null)
            FailureNotice(
              _error!,
              onRetry: () => unawaited(_retry()),
              account: widget.account,
              resourceLabel:
                  '${widget.projectPath} · ${widget.package.identity} · ${widget.file.name}',
              onSwitchAccount: endSessionFrom(context),
            ),
          if (_done && _saved != null) ...[
            Text(
              '已驗證並下載 ${widget.file.name} · ${formatByteCount(widget.file.size)}',
            ),
            const SizedBox(height: 12),
            Builder(
              builder: (buttonContext) => FilledButton.icon(
                onPressed: _sharing
                    ? null
                    : () => unawaited(_share(buttonContext)),
                icon: const Icon(Icons.ios_share_outlined),
                label: const Text('開啟／分享'),
              ),
            ),
          ],
          if (_error == null && !_done) ...[
            ValueListenableBuilder<(int, int?)>(
              valueListenable: _progress.value,
              builder: (context, value, _) {
                final received = value.$1;
                final total = value.$2;
                final progress = total == null || total <= 0
                    ? null
                    : (received / total).clamp(0.0, 1.0).toDouble();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      label: '套件檔案下載進度',
                      value: progress == null
                          ? '下載中'
                          : '${(progress * 100).toInt()}%',
                      child: LinearProgressIndicator(
                        key: const Key('package-download-progress'),
                        minHeight: 4,
                        value: progress,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      total == null
                          ? formatByteCount(received)
                          : '${formatByteCount(received)} / ${formatByteCount(total)}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                );
              },
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _cancel, child: const Text('取消')),
            ),
          ],
        ],
      ),
    ),
  );
}

Future<void> showPackageDownloadSheet(
  BuildContext context, {
  required Account account,
  required GitLabApi api,
  required Project project,
  required RegistryPackage package,
  required RegistryPackageFile file,
  required bool Function() isCurrent,
  Listenable? ownerChanges,
  PackageDownloader? downloader,
  ArtifactSharer sharer = const SystemArtifactSharer(),
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => PackageDownloadSheet(
    account: account,
    api: api,
    projectId: project.id,
    projectPath: project.path,
    package: package,
    file: file,
    isCurrent: isCurrent,
    ownerChanges: ownerChanges,
    downloader: downloader,
    sharer: sharer,
  ),
);

String _shortPackageSha(String value) =>
    value.length <= 12 ? value : '${value.substring(0, 12)}…';
