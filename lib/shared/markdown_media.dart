import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:video_player/video_player.dart';

import '../core/failure.dart';
import '../core/models.dart';
import '../l10n/l10n.dart';
import 'artifact_storage.dart';
import 'attachment_budget.dart';
import 'markdown_media_source.dart';

String markdownMediaFailure(
  Object error, {
  bool image = true,
  bool blocked = false,
}) {
  if (blocked) return l10n.markdownMediaBlocked;
  if (error is AttachmentBudgetExceeded) return l10n.markdownMediaTooLarge;
  if (error is ApiFailure) {
    return switch (error.kind) {
      FailureKind.tooLarge => l10n.markdownMediaTooLarge,
      FailureKind.unsupported ||
      FailureKind.redirectBlocked => l10n.markdownMediaBlocked,
      _ => l10n.markdownMediaNetwork,
    };
  }
  return image ? l10n.markdownMediaNotImage : l10n.markdownMediaNetwork;
}

/// All references are local fragments. No nested URI can reach an SVG loader.
/// Rejecting declarations also prevents entity expansion before SVG parsing.
bool markdownSvgIsSelfContained(String text) {
  final lower = text.toLowerCase();
  if (lower.contains('<!') ||
      lower.contains('<?xml-stylesheet') ||
      lower.contains('<style') ||
      lower.contains('<script')) {
    return false;
  }
  final references = RegExp(
    r'''(?:[\w-]+:)?href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
    caseSensitive: false,
  );
  for (final match in references.allMatches(text)) {
    final value = (match[1] ?? match[2] ?? match[3] ?? '').trim();
    if (!value.startsWith('#')) return false;
  }
  for (final match in RegExp(
    r'url\s*\(\s*([^)]*)\)',
    caseSensitive: false,
  ).allMatches(text)) {
    final value = match[1]!.replaceAll(RegExp('[\'"\\s]'), '');
    if (!value.startsWith('#')) return false;
  }
  return true;
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
  });
  final MarkdownMediaSource source;
  final MarkdownMediaLoader loader;
  final AttachmentBudget budget;
  final String? alt;
  final double? width;
  final double? height;

  @override
  State<MarkdownMediaImage> createState() => _MarkdownMediaImageState();
}

class _MarkdownMediaImageState extends State<MarkdownMediaImage> {
  Uint8List? _bytes;
  bool _svg = false;
  Object? _error;
  int _epoch = 0;
  Object get _key => (widget.loader, widget.source.cacheKey);

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
        oldWidget.budget != widget.budget) {
      _bytes = null;
      _error = null;
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    try {
      if (!widget.budget.claimImage(_key)) {
        throw const AttachmentBudgetExceeded();
      }
      final bytes = await widget.budget.fetch(
        _key,
        () => widget.loader.load(widget.source),
      );
      if (!mounted || epoch != _epoch) return;
      final head = utf8
          .decode(bytes.take(1024).toList(), allowMalformed: true)
          .trimLeft();
      final svg = head.startsWith('<svg') || head.startsWith('<?xml');
      if (svg) {
        if (!markdownSvgIsSelfContained(utf8.decode(bytes))) {
          throw const ApiFailure(FailureKind.unsupported);
        }
      } else {
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
        _bytes = bytes;
        _svg = svg;
        _error = null;
      });
    } catch (error) {
      if (mounted && epoch == _epoch) setState(() => _error = error);
    }
  }

  void _retry() {
    widget.budget.evict(_key);
    setState(() {
      _bytes = null;
      _error = null;
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }

  Widget _failed(Object error) => TextButton.icon(
    onPressed: _retry,
    icon: const Icon(Icons.broken_image_outlined),
    label: Text(
      '${widget.alt ?? widget.source.filename} · ${markdownMediaFailure(error)} · ${l10n.markdownMediaRetry}',
    ),
  );

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) return _failed(error);
    final bytes = _bytes;
    if (bytes == null) {
      return const SizedBox(
        width: 32,
        height: 32,
        child: CircularProgressIndicator(),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 480),
      child: _svg
          ? SvgPicture.memory(
              bytes,
              width: widget.width,
              height: widget.height,
              semanticsLabel: widget.alt,
              fit: BoxFit.contain,
              errorBuilder: (_, error, _) => _failed(error),
            )
          : Image.memory(
              bytes,
              width: widget.width,
              height: widget.height,
              cacheWidth: 2048,
              fit: BoxFit.contain,
              semanticLabel: widget.alt,
              errorBuilder: (_, error, _) => _failed(error),
            ),
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

  @override
  void initState() {
    super.initState();
    final account = widget.account;
    if (account != null) {
      _accountGeneration = markdownMediaAccountGeneration(account);
    }
  }

  @override
  void didUpdateWidget(MarkdownMediaCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.uri != widget.source.uri ||
        oldWidget.loader != widget.loader ||
        oldWidget.account?.key != widget.account?.key) {
      unawaited(_release());
      _error = null;
      final account = widget.account;
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
    final account = widget.account;
    if (account == null) {
      setState(() => _error = const ApiFailure(FailureKind.invalidResponse));
      return;
    }
    final epoch = ++_epoch;
    final cancel = CancelToken();
    _cancel = cancel;
    _unregisterCleanup?.call();
    _unregisterCleanup = registerMarkdownMediaCleanup(account, _accountCleanup);
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
      directory = await markdownMediaDirectory(
        account,
        generation: _accountGeneration,
      );
      if (!mounted || epoch != _epoch) {
        await deleteAttemptFiles(directory, null);
        return;
      }
      _directory = directory;
      final file = File(
        '${directory.path}/${attachmentDownloadFileName(widget.source.filename ?? 'media.bin', fallback: 'media.bin')}',
      );
      sink = file.openWrite();
      _sink = sink;
      await widget.loader.load(
        widget.source,
        image: false,
        sink: sink,
        cancelToken: cancel,
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
      player = VideoPlayerController.file(file);
      _player = player;
      await player.initialize();
      if (!mounted || epoch != _epoch) {
        await player.dispose();
        return;
      }
      player.addListener(_changed);
      // Loading began with an explicit play tap; rendering alone never plays.
      await player.play();
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
          _error = error;
          _loading = false;
        });
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
    if (mounted) setState(() {});
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
                    widget.source.filename ?? l10n.unnamedFile,
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
              LinearProgressIndicator(
                value: _total != null && _total! > 0
                    ? (_received / _total!).clamp(0.0, 1.0)
                    : null,
              ),
            ],
            if (error != null)
              TextButton(
                onPressed: () => unawaited(_retryMedia()),
                child: Text(
                  '${markdownMediaFailure(error, image: false, blocked: widget.source.kind == MarkdownMediaSourceKind.blocked)} · ${l10n.markdownMediaRetry}',
                ),
              ),
            if (value != null && value.isInitialized && player != null) ...[
              if (value.hasError) Text(l10n.markdownMediaNetwork),
              if (!widget.audio)
                AspectRatio(
                  aspectRatio: value.aspectRatio,
                  child: VideoPlayer(player),
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
