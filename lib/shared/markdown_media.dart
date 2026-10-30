import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../core/failure.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../features/auth/session_controller.dart';
import '../l10n/l10n.dart';
import 'artifact_storage.dart';
import 'attachment_budget.dart';
import 'markdown_media_source.dart';
import 'markdown_media_svg.dart';
import 'network_boundary.dart';
import 'workspace_ui.dart';

String markdownMediaFailure(
  Object error, {
  bool image = true,
  bool blocked = false,
}) {
  if (blocked) return l10n.markdownMediaBlocked;
  if (error is AttachmentBudgetExceeded) return l10n.markdownMediaTooLarge;
  if (error is MarkdownMediaNotImage) return l10n.markdownMediaNotImage;
  if (error is FormatException) return l10n.cannotDecodeImage;
  if (error is ApiFailure) {
    return switch (error.kind) {
      FailureKind.tooLarge => l10n.markdownMediaTooLarge,
      FailureKind.redirectBlocked => l10n.markdownMediaBlocked,
      FailureKind.invalidResponse => l10n.cannotDecodeImage,
      FailureKind.unsupported => error.title,
      _ =>
        error.title == l10n.cannotSaveArtifact
            ? error.title
            : l10n.markdownMediaNetwork,
    };
  }
  return image && error is! IOException && error is! StateError
      ? l10n.cannotDecodeImage
      : l10n.markdownMediaNetwork;
}

bool markdownMediaNeedsDetails(Object error, MarkdownMediaSource source) =>
    (source.kind == MarkdownMediaSourceKind.repository ||
        source.kind == MarkdownMediaSourceKind.upload) &&
    error is ApiFailure &&
    const {
      FailureKind.invisible,
      FailureKind.forbidden,
      FailureKind.unauthenticated,
    }.contains(error.kind);

void openMarkdownMediaFailure(
  BuildContext context,
  ApiFailure failure, {
  required MarkdownMediaSource source,
  required VoidCallback onRetry,
  Account? account,
}) {
  account ??= _sessionAccount(context);
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: FailureNotice(
            failure,
            account: account,
            resourceLabel: [
              source.project,
              source.ref,
              source.path,
            ].whereType<String>().join('/'),
            onRetry: () {
              Navigator.of(sheetContext).pop();
              onRetry();
            },
            onSwitchAccount: endSessionFrom(sheetContext),
          ),
        ),
      ),
    ),
  );
}

Account? _sessionAccount(BuildContext context) {
  try {
    return ProviderScope.containerOf(
      context,
      listen: false,
    ).read(sessionProvider).active;
  } catch (_) {
    return null;
  }
}

class MarkdownMediaImage extends StatefulWidget {
  const MarkdownMediaImage({
    super.key,
    required this.source,
    required this.loader,
    required this.budget,
    this.alt,
    this.width,
    this.height,
    this.account,
    this.budgetScope,
  });
  final MarkdownMediaSource source;
  final MarkdownMediaLoader loader;
  final AttachmentBudget budget;
  final String? alt;
  final double? width;
  final double? height;
  final Account? account;
  final Object? budgetScope;

  @override
  State<MarkdownMediaImage> createState() => _MarkdownMediaImageState();
}

class _MarkdownMediaImageState extends State<MarkdownMediaImage> {
  Uint8List? _bytes;
  bool _svg = false;
  bool _capped = false;
  bool _mediaCard = false;
  bool _offlineMedia = false;
  bool _mediaAudio = false;
  Object? _error;
  int _epoch = 0;
  Object get _key => (
    widget.budgetScope ?? widget.loader,
    widget.account?.key,
    widget.account == null
        ? null
        : markdownMediaAccountGeneration(widget.account!),
    widget.source.cacheKey,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(MarkdownMediaImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.uri != widget.source.uri ||
        oldWidget.loader != widget.loader ||
        oldWidget.budget != widget.budget ||
        oldWidget.budgetScope != widget.budgetScope ||
        oldWidget.account?.key != widget.account?.key) {
      _bytes = null;
      _error = null;
      _mediaCard = false;
      _offlineMedia = false;
      _mediaAudio = false;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    _capped = false;
    if (widget.source.kind == MarkdownMediaSourceKind.blocked) {
      setState(() => _error = const ApiFailure(FailureKind.redirectBlocked));
      return;
    }
    if (!widget.budget.claimImage(_key)) {
      setState(() => _capped = true);
      return;
    }
    try {
      String? contentType;
      final bytes = await widget.budget.fetch(
        _key,
        () => widget.loader.load(
          widget.source,
          onContentType: (value) => contentType = value,
        ),
      );
      if (!mounted || epoch != _epoch) return;
      final sanitised = await sanitizeMarkdownSvg(
        bytes,
        contentType: contentType,
      );
      final svg = sanitised != null;
      if (!svg) {
        final headerSize = markdownRasterDimensions(bytes);
        if (headerSize != null &&
            headerSize.$1 > 0 &&
            headerSize.$2 > 0 &&
            headerSize.$1 * headerSize.$2 > 24000000) {
          throw const ApiFailure(FailureKind.tooLarge);
        }
        final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
        ui.ImageDescriptor? descriptor;
        try {
          descriptor = await ui.ImageDescriptor.encoded(buffer);
          if (descriptor.width * descriptor.height > 24000000) {
            throw const ApiFailure(FailureKind.tooLarge);
          }
        } finally {
          descriptor?.dispose();
          buffer.dispose();
        }
      }
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _bytes = sanitised ?? bytes;
        _svg = svg;
        _error = null;
      });
    } on MarkdownMediaNotImage catch (error) {
      if (!mounted || epoch != _epoch) return;
      if (error.isMedia) {
        final blocked = NetworkBoundary.blocks(context);
        setState(() {
          _mediaCard = !blocked;
          _offlineMedia = blocked;
          _mediaAudio = error.isAudio;
          _error = null;
        });
        return;
      }
      setState(() => _error = error);
    } catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = error);
    }
  }

  void _retry() {
    widget.budget.evict(_key);
    setState(() {
      _bytes = null;
      _error = null;
      _mediaCard = false;
      _offlineMedia = false;
      _mediaAudio = false;
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }

  Widget _failed(Object error) {
    if (widget.source.kind == MarkdownMediaSourceKind.blocked) {
      return Tooltip(
        message: l10n.markdownMediaBlocked,
        child: Icon(
          Icons.broken_image_outlined,
          semanticLabel: l10n.markdownMediaBlocked,
        ),
      );
    }
    final name = widget.alt?.isNotEmpty == true
        ? widget.alt!
        : widget.source.filename ?? '';
    final reason = markdownMediaFailure(error);
    return TextButton.icon(
      onPressed: markdownMediaNeedsDetails(error, widget.source)
          ? () => openMarkdownMediaFailure(
              context,
              error as ApiFailure,
              source: widget.source,
              account: widget.account,
              onRetry: _retry,
            )
          : _retry,
      icon: const Icon(Icons.broken_image_outlined),
      label: Text(
        '${name.isEmpty ? '' : '${isolated(name)} · '}$reason · ${l10n.markdownMediaRetry}',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_offlineMedia || (_mediaCard && NetworkBoundary.blocks(context))) {
      return SnapshotMediaPlaceholder(
        alt: widget.alt,
        note: NetworkBoundary.modeOf(context) == NetworkBoundaryMode.demo
            ? l10n.demoOffline
            : l10n.snapshotMediaOffline,
      );
    }
    if (_mediaCard) {
      return MarkdownMediaCard(
        source: widget.source,
        loader: widget.loader,
        account: widget.account,
        audio: _mediaAudio,
      );
    }
    if (_capped) return Text(l10n.attachmentExceedsDisplayLimit);
    final error = _error;
    if (error != null) return _failed(error);
    final bytes = _bytes;
    if (bytes == null) {
      return SizedBox(
        width: 32,
        height: 32,
        child: CircularProgressIndicator(
          semanticsLabel: l10n.attachmentLoading,
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final layoutWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 320.0;
        final ratio = MediaQuery.devicePixelRatioOf(context);
        final decodeWidth =
            (math.min(widget.width ?? layoutWidth, layoutWidth) * ratio)
                .round()
                .clamp(64, 2048);
        final decodeHeight = (480 * ratio).round().clamp(64, 2048);
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 480),
          child: _svg
              ? SvgPicture.memory(
                  bytes,
                  width: widget.width,
                  height: widget.height,
                  semanticsLabel: widget.alt,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => _failed(const FormatException()),
                )
              : Image(
                  image: ResizeImage(
                    MemoryImage(bytes),
                    width: decodeWidth,
                    height: decodeHeight,
                    policy: ResizeImagePolicy.fit,
                  ),
                  width: widget.width,
                  height: widget.height,
                  fit: BoxFit.contain,
                  semanticLabel: widget.alt,
                  errorBuilder: (_, _, _) => _failed(const FormatException()),
                ),
        );
      },
    );
  }
}

class MarkdownMediaCard extends StatefulWidget {
  const MarkdownMediaCard({
    super.key,
    required this.source,
    required this.loader,
    required this.account,
    this.audio = false,
  });
  final MarkdownMediaSource source;
  final MarkdownMediaLoader loader;
  final Account? account;
  final bool audio;

  @override
  State<MarkdownMediaCard> createState() => _MarkdownMediaCardState();
}

class _MarkdownMediaCardState extends State<MarkdownMediaCard> {
  VideoPlayerController? _player;
  Directory? _directory;
  CancelToken? _cancel;
  IOSink? _sink;
  void Function()? _unregisterCleanup;
  Object? _error;
  bool _loading = false;
  int _epoch = 0;
  int _received = 0;
  int? _total;
  int _accountGeneration = 0;
  String? _generationAccountKey;
  SessionController? _session;

  @override
  void initState() {
    super.initState();
    final account = widget.account ?? _sessionAccount(context);
    if (account != null) {
      _generationAccountKey = account.key;
      _accountGeneration = markdownMediaAccountGeneration(account);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindSession();
  }

  void _bindSession() {
    SessionController? session;
    if (widget.account == null) {
      try {
        session = ProviderScope.containerOf(
          context,
          listen: false,
        ).read(sessionProvider);
      } catch (_) {}
    }
    if (identical(session, _session)) return;
    _session?.removeListener(_sessionChanged);
    _session = session;
    session?.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    final account = _session?.active;
    if (widget.account != null || account?.key == _generationAccountKey) return;
    unawaited(_release());
    _generationAccountKey = account?.key;
    _accountGeneration = account == null
        ? 0
        : markdownMediaAccountGeneration(account);
    if (mounted) setState(() => _error = null);
  }

  @override
  void didUpdateWidget(MarkdownMediaCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bindSession();
    if (oldWidget.source.uri != widget.source.uri ||
        oldWidget.loader != widget.loader ||
        oldWidget.account?.key != widget.account?.key) {
      unawaited(_release());
      _error = null;
      final account = widget.account ?? _sessionAccount(context);
      _generationAccountKey = account?.key;
      if (account != null) {
        _accountGeneration = markdownMediaAccountGeneration(account);
      }
    }
  }

  Future<void> _release() async {
    _epoch++;
    _unregisterCleanup?.call();
    _unregisterCleanup = null;
    _cancel?.cancel();
    _cancel = null;
    _loading = false;
    final player = _player;
    _player = null;
    final directory = _directory;
    _directory = null;
    final sink = _sink;
    _sink = null;
    try {
      await player?.dispose();
    } catch (_) {
      // Cleanup still owns the file if the platform player has already gone.
    } finally {
      try {
        await sink?.close();
      } catch (_) {
        /* Cancelled write. */
      }
      await deleteAttemptFiles(directory, null);
    }
  }

  Future<void> _load() async {
    if (_loading || _player != null) return;
    if (widget.source.kind == MarkdownMediaSourceKind.blocked) {
      setState(() => _error = const ApiFailure(FailureKind.redirectBlocked));
      return;
    }
    final account = widget.account ?? _sessionAccount(context);
    if (account == null) {
      setState(() => _error = const ApiFailure(FailureKind.invalidResponse));
      return;
    }
    if (_generationAccountKey != account.key) {
      _generationAccountKey = account.key;
      _accountGeneration = markdownMediaAccountGeneration(account);
    }
    final epoch = ++_epoch;
    final cancel = CancelToken();
    _cancel = cancel;
    _unregisterCleanup?.call();
    final unregisterCleanup = registerMarkdownMediaCleanup(account, _accountCleanup);
    _unregisterCleanup = unregisterCleanup;
    setState(() {
      _loading = true;
      _error = null;
      _received = 0;
      _total = null;
    });
    Directory? directory;
    VideoPlayerController? player;
    IOSink? sink;
    try {
      _accountGeneration = usableMarkdownMediaAccountGeneration(
        account,
        generation: _accountGeneration,
      );
      directory = await markdownMediaDirectory(
        account,
        generation: _accountGeneration,
      );
      if (!mounted || epoch != _epoch) {
        await deleteAttemptFiles(directory, null);
        return;
      }
      _directory = directory;
      final sourceName = widget.source.filename?.trim();
      final originalName = attachmentDownloadFileName(
        sourceName?.isNotEmpty == true ? sourceName! : 'media',
        fallback: 'media',
      );
      var file = File('${directory.path}/$originalName');
      String? contentType;
      sink = file.openWrite();
      _sink = sink;
      await widget.loader.load(
        widget.source,
        image: false,
        sink: sink,
        cancelToken: cancel,
        onContentType: (value) => contentType = value,
        onProgress: (received, total) {
          if (mounted && epoch == _epoch) {
            setState(() {
              _received = received;
              _total = total;
            });
          }
        },
      );
      await sink.close();
      if (identical(_sink, sink)) _sink = null;
      if (!mounted || epoch != _epoch || cancel.isCancelled) return;
      if (!_hasFileExtension(originalName)) {
        final extension = markdownMediaExtensionForContentType(contentType);
        if (extension.isNotEmpty) {
          file = await file.rename('${file.path}$extension');
        }
      }
      player = VideoPlayerController.file(file);
      _player = player;
      try {
        await player.initialize();
      } on Object {
        throw ApiFailure(
          FailureKind.unsupported,
          title: l10n.markdownMediaCannotPlay,
        );
      }
      if (!mounted || epoch != _epoch) {
        await player.dispose();
        return;
      }
      player.addListener(_changed);
      // Loading began with an explicit play tap; rendering alone never plays.
      final lifecycleState = WidgetsBinding.instance.lifecycleState;
      if (lifecycleState == null ||
          lifecycleState == AppLifecycleState.resumed) {
        await player.play();
      }
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    } catch (error) {
      if (identical(_player, player)) _player = null;
      if (identical(_directory, directory)) _directory = null;
      try {
        await player?.dispose();
      } catch (_) {
        /* Platform has already stopped. */
      }
      try {
        await sink?.close();
      } catch (_) {
        /* Failed/cancelled write. */
      }
      if (identical(_sink, sink)) _sink = null;
      await deleteAttemptFiles(directory, null);
      if (mounted && epoch == _epoch) {
        setState(() {
          _error = error is FileSystemException
              ? ApiFailure.artifactStorage
              : error;
          _loading = false;
        });
      }
    } finally {
      if (player == null || !identical(_player, player) || cancel.isCancelled) {
        unregisterCleanup();
        if (identical(_unregisterCleanup, unregisterCleanup)) {
          _unregisterCleanup = null;
        }
      }
    }
  }

  Future<void> _accountCleanup() async {
    await _release();
    if (mounted) setState(() {});
  }

  Future<void> _retryMedia() async {
    await _release();
    if (mounted) await _load();
  }

  Future<void> _mute() async {
    final player = _player;
    if (player == null) return;
    try {
      await player.setVolume(player.value.volume == 0 ? 1 : 0);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _changed() {
    if (!mounted) return;
    final player = _player;
    if (player?.value.hasError == true) {
      if (_error == null) {
        setState(() {
          _error = ApiFailure(
            FailureKind.unsupported,
            title: l10n.markdownMediaCannotPlay,
          );
        });
      }
      return;
    }
    setState(() {});
  }

  Future<void> _toggle() async {
    final player = _player;
    if (player == null) {
      await _load();
      return;
    }
    try {
      if (player.value.isPlaying) {
        await player.pause();
      } else {
        await player.play();
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void dispose() {
    _session?.removeListener(_sessionChanged);
    unawaited(_release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final value = player?.value;
    final error = _error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  widget.audio
                      ? Icons.audiotrack_outlined
                      : Icons.movie_outlined,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isolated(
                      widget.source.filename?.isNotEmpty == true
                          ? widget.source.filename!
                          : l10n.unnamedFile,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (_loading)
                  IconButton(
                    tooltip: l10n.markdownMediaCancel,
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      await _release();
                      if (mounted) setState(() {});
                    },
                  )
                else
                  IconButton(
                    tooltip: value?.isPlaying == true
                        ? l10n.markdownMediaPause
                        : l10n.markdownMediaPlay,
                    icon: Icon(
                      value?.isPlaying == true ? Icons.pause : Icons.play_arrow,
                    ),
                    onPressed: () => unawaited(_toggle()),
                  ),
              ],
            ),
            if (_loading) ...[
              Text(l10n.markdownMediaLoading),
              Semantics(
                label: l10n.markdownMediaLoading,
                child: LinearProgressIndicator(
                  value: _total != null && _total! > 0
                      ? (_received / _total!).clamp(0.0, 1.0)
                      : null,
                ),
              ),
            ],
            if (error != null)
              TextButton(
                onPressed: () {
                  if (markdownMediaNeedsDetails(error, widget.source) &&
                      error is ApiFailure) {
                    openMarkdownMediaFailure(
                      context,
                      error,
                      source: widget.source,
                      account: widget.account,
                      onRetry: () => unawaited(_retryMedia()),
                    );
                    return;
                  }
                  unawaited(_retryMedia());
                },
                child: Text(
                  '${markdownMediaFailure(error, image: false, blocked: widget.source.kind == MarkdownMediaSourceKind.blocked)} · ${l10n.markdownMediaRetry}',
                ),
              ),
            if (error == null &&
                value != null &&
                value.isInitialized &&
                player != null) ...[
              if (!widget.audio)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 480),
                  child: AspectRatio(
                    aspectRatio:
                        value.aspectRatio > 0 && value.aspectRatio.isFinite
                        ? value.aspectRatio
                        : 16 / 9,
                    child: VideoPlayer(player),
                  ),
                ),
              VideoProgressIndicator(player, allowScrubbing: true),
              IconButton(
                tooltip: value.volume == 0
                    ? l10n.markdownMediaUnmute
                    : l10n.markdownMediaMute,
                icon: Icon(
                  value.volume == 0 ? Icons.volume_off : Icons.volume_up,
                ),
                onPressed: () => unawaited(_mute()),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

bool _hasFileExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 && dot < name.length - 1;
}

/// Stands in for media that an offline snapshot or demo view does not show.
class SnapshotMediaPlaceholder extends StatelessWidget {
  const SnapshotMediaPlaceholder({
    super.key,
    required this.alt,
    required this.note,
  });

  final String? alt;
  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = (alt ?? '').trim();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        key: const ValueKey('snapshot-media-placeholder'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              Icons.image_not_supported_outlined,
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (label.isNotEmpty)
                    Text(isolated(label), style: theme.textTheme.bodyMedium),
                  Text(
                    note,
                    style: (label.isEmpty
                            ? theme.textTheme.bodyMedium
                            : theme.textTheme.bodySmall)
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
