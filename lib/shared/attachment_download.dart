import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/failure.dart';
import '../core/gitlab_api.dart';
import '../core/models.dart';
import 'artifact_storage.dart';
import 'external_link.dart';
import 'workspace_ui.dart';

abstract interface class AttachmentDownloader {
  Future<File> downloadUpload({
    required int projectId,
    required String secret,
    required String filename,
    required Account account,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
  });
}

final class DefaultAttachmentDownloader implements AttachmentDownloader {
  DefaultAttachmentDownloader({
    required this.api,
    this.openSink = openArtifactSink,
    this.promote = promoteArtifactFile,
    this.attemptDirectory = attachmentAttemptDirectory,
  });

  final GitLabApi api;
  final IOSink Function(File file) openSink;
  final Future<File> Function(File partial, File target) promote;
  final Future<Directory> Function(Account account, int projectId) attemptDirectory;

  @override
  Future<File> downloadUpload({
    required int projectId,
    required String secret,
    required String filename,
    required Account account,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
  }) async {
    final directory = await attemptDirectory(account, projectId);
    final partial = File('${directory.path}/.download.partial');
    IOSink? ownedSink;
    Object? sinkFailure;
    final abort = Completer<void>();
    if (cancel != null) {
      unawaited(cancel.then((_) {
        if (!abort.isCompleted) abort.complete();
      }));
    }

    Future<void> cleanup() async {
      final open = ownedSink;
      ownedSink = null;
      if (open != null) {
        try {
          await open.close();
        } on Object catch (error) {
          if (error is! StateError && error is! FileSystemException) rethrow;
        }
      }
      await deleteAttemptFiles(directory, partial);
    }

    try {
      final sink = openSink(partial);
      ownedSink = sink;
      unawaited(sink.done.then<void>((_) {}, onError: (Object error, StackTrace _) {
        sinkFailure ??= error;
        if (!abort.isCompleted) abort.complete();
      }));

      final result = await api.downloadProjectUpload(
        projectId,
        secret,
        filename,
        sink: sink,
        cancel: abort.future,
        onProgress: onProgress,
      );
      if (sinkFailure != null) throw sinkFailure!;
      await sink.flush();
      if (sinkFailure != null) throw sinkFailure!;
      await sink.close();
      ownedSink = null;
      if (sinkFailure != null) throw sinkFailure!;

      final safeName = attachmentDownloadFileName(result.fileName, fallback: 'attachment.bin');
      final target = File('${directory.path}/$safeName');
      final saved = await promote(partial, target);
      if (sinkFailure != null) {
        if (saved.existsSync()) await saved.delete();
        throw sinkFailure!;
      }
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

class AttachmentDownloadSheet extends StatefulWidget {
  const AttachmentDownloadSheet({
    super.key,
    required this.account,
    required this.api,
    required this.projectId,
    required this.secret,
    required this.filename,
    this.projectPath,
    this.webUri,
    this.suggestedSize,
    this.sharer = const SystemArtifactSharer(),
    this.downloader,
  });

  final Account account;
  final GitLabApi api;
  final int projectId;
  final String? projectPath;
  final String secret;
  final String filename;
  final Uri? webUri;
  final int? suggestedSize;
  final ArtifactSharer sharer;
  final AttachmentDownloader? downloader;

  @override
  State<AttachmentDownloadSheet> createState() => _AttachmentDownloadSheetState();
}

class _AttachmentDownloadSheetState extends State<AttachmentDownloadSheet> {
  int _attempt = 0;
  bool _done = false;
  bool _disposed = false;
  bool _sharing = false;
  ApiFailure? _error;
  String? _savedName;
  String? _savedPath;
  int _savedBytes = 0;
  var _abort = Completer<void>();
  late final ArtifactProgress _progress;
  bool _popWhenCancelled = false;

  @override
  void initState() {
    super.initState();
    _progress = ArtifactProgress(initial: (0, widget.suggestedSize));
    unawaited(_start());
  }

  @override
  void dispose() {
    _disposed = true;
    if (!_abort.isCompleted) _abort.complete();
    _progress.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final attempt = ++_attempt;
    final abort = Completer<void>();
    _abort = abort;
    final downloader = widget.downloader ?? DefaultAttachmentDownloader(api: widget.api);

    try {
      final file = await downloader.downloadUpload(
        projectId: widget.projectId,
        secret: widget.secret,
        filename: widget.filename,
        account: widget.account,
        cancel: abort.future,
        onProgress: (received, total) {
          if (_disposed || attempt != _attempt) return;
          _progress.report(received, total);
        },
      );
      if (!mounted || attempt != _attempt) return;
      final length = await file.length();
      _progress.report(length, length, completed: true);
      setState(() {
        _done = true;
        _error = null;
        _savedName = file.uri.pathSegments.last;
        _savedBytes = length;
        _savedPath = file.path;
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
    if (!mounted || _disposed) return;
    setState(() {
      _error = null;
      _done = false;
      _savedName = null;
      _savedPath = null;
      _savedBytes = 0;
    });
    _progress.report(0, widget.suggestedSize, completed: true);
    await _start();
  }

  void _cancel() {
    _popWhenCancelled = true;
    if (!_abort.isCompleted) _abort.complete();
  }

  Future<void> _share(BuildContext buttonContext) async {
    final path = _savedPath;
    if (path == null || _sharing) return;
    setState(() => _sharing = true);
    final box = buttonContext.findRenderObject() as RenderBox?;
    final Rect? origin = box != null && box.hasSize
        ? box.localToGlobal(Offset.zero) & box.size
        : null;
    try {
      await shareDownloadedArtifact(widget.sharer, path, sharePositionOrigin: origin);
    } catch (error) {
      if (mounted) showFailure(context, error);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.filename, style: Theme.of(context).textTheme.titleMedium),
            if (widget.suggestedSize != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  formatByteCount(widget.suggestedSize!),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 16),
            if (_error != null) ...[
              FailureNotice(
                _error!,
                onRetry: () => unawaited(_retry()),
                account: widget.account,
                resourceLabel: '${widget.projectPath ?? '專案'} · ${widget.filename} 附件',
                onSwitchAccount: endSessionFrom(context),
              ),
              if (widget.webUri != null) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => unawaited(openExternal(context, widget.webUri!)),
                  child: const Text('在 GitLab 開啟'),
                ),
              ],
            ],
            if (_done) ...[
              Text('已下載 ${_savedName ?? widget.filename} · ${formatByteCount(_savedBytes)}'),
              const SizedBox(height: 12),
              Builder(
                builder: (buttonContext) => FilledButton(
                  onPressed: _sharing ? null : () => unawaited(_share(buttonContext)),
                  child: const Text('開啟／分享'),
                ),
              ),
              if (widget.webUri != null)
                TextButton(
                  onPressed: () => unawaited(openExternal(context, widget.webUri!)),
                  child: const Text('在 GitLab 開啟'),
                ),
            ],
            if (_error == null && !_done) ...[
              ValueListenableBuilder<(int, int?)>(
                valueListenable: _progress.value,
                builder: (context, value, _) {
                  final received = value.$1;
                  final total = value.$2;
                  final double? progress = total == null || total <= 0
                      ? null
                      : (received / total).clamp(0.0, 1.0).toDouble();
                  final bytes = total == null
                      ? formatByteCount(received)
                      : '${formatByteCount(received)} / ${formatByteCount(total)}';
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        label: '附件下載進度',
                        value: progress != null ? '${(progress * 100).toInt()}%' : '下載中',
                        child: LinearProgressIndicator(
                          key: const Key('attachment-progress'),
                          minHeight: 4,
                          value: progress,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(bytes, style: Theme.of(context).textTheme.bodySmall),
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
}

Future<void> showAttachmentDownloadSheet(
  BuildContext context, {
  required GitLabApi api,
  required int projectId,
  required String secret,
  required String filename,
  required Account account,
  String? projectPath,
  Uri? webUri,
  int? suggestedSize,
  ArtifactSharer sharer = const SystemArtifactSharer(),
  AttachmentDownloader? downloader,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => AttachmentDownloadSheet(
      api: api,
      projectId: projectId,
      secret: secret,
      filename: filename,
      account: account,
      projectPath: projectPath,
      webUri: webUri,
      suggestedSize: suggestedSize,
      sharer: sharer,
      downloader: downloader,
    ),
  );
}
