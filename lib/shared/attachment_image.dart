import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/failure.dart';
import '../core/gitlab_api.dart';
import '../core/models.dart';
import '../core/providers.dart';
import 'artifact_storage.dart';
import 'attachment_budget.dart';
import 'attachment_ref.dart';
import 'external_link.dart';
import 'markdown_media.dart';
import 'markdown_media_source.dart';
import 'markdown_media_svg.dart';
import 'network_boundary.dart';
import 'workspace_ui.dart';

import '../l10n/l10n.dart';
const _pixelLimit = 24000000;
const _cacheWidthLimit = 2048;

ApiFailure get _decodeFailure => ApiFailure(
  FailureKind.unsupported,
  title: l10n.cannotDecodeImage,
  detail: l10n.attachmentNotDecodableImage,
);

String attachmentImageLabel(String? alt, [ApiFailure? failure]) {
  final name = alt != null && alt.isNotEmpty ? alt : l10n.attachedImageOpenInGitlab;
  if (failure == null) return name;
  final reason = failure.kind == FailureKind.tooLarge ? l10n.exceedsSizeLimit : failure.title;
  return l10n.attachmentLoadFailedNamed(name, reason);
}

Widget attachmentIconRow(String label) => LayoutBuilder(
  builder: (context, constraints) {
    if (constraints.maxWidth < 48 || constraints.maxHeight < 40) {
      final size = constraints.maxWidth.clamp(0.0, 18.0)
          .clamp(0.0, constraints.maxHeight.clamp(0.0, 18.0));
      return Tooltip(
        message: label,
        child: Icon(Icons.image_outlined, size: size, semanticLabel: label),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.image_outlined, size: 18),
        const SizedBox(width: 6),
        Flexible(child: Text(label)),
      ]),
    );
  },
);

Widget attachmentImageFallback(String? alt, [ApiFailure? failure]) =>
    attachmentIconRow(attachmentImageLabel(alt, failure));

int _decodeWidth(double layoutWidth, double devicePixelRatio) {
  final raw = (layoutWidth * devicePixelRatio).round();
  if (raw < 64) return 64;
  if (raw > _cacheWidthLimit) return _cacheWidthLimit;
  return raw;
}

enum _Phase {
  loading,
  ready,
  media,
  offlineMedia,
  failed,
  capped,
  overBytes,
  oversize,
}

class AttachmentImage extends StatefulWidget {
  const AttachmentImage({
    super.key,
    required this.api,
    required this.budget,
    required this.projectId,
    required this.secret,
    required this.filename,
    this.alt,
    this.width,
    this.height,
    this.projectWeb,
    this.projectPath,
    this.loader,
    this.account,
  });
  final GitLabApi api;
  final AttachmentBudget budget;
  final int projectId;
  final String secret;
  final String filename;
  final String? alt;
  final double? width;
  final double? height;
  final Uri? projectWeb;
  final String? projectPath;
  final MarkdownMediaLoader? loader;
  final Account? account;
  @override
  State<AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<AttachmentImage> {
  _Phase _phase = _Phase.loading;
  ApiFailure? _failure;
  bool _allowed = false;
  bool _mediaAudio = false;
  MarkdownMediaLoader? _ownedLoader;
  int _epoch = 0;

  ProjectUploadRef get _ref => ProjectUploadRef(secret: widget.secret, filename: widget.filename);

  String get _semanticLabel {
    final alt = widget.alt;
    if (alt != null && alt.isNotEmpty) return alt;
    return widget.filename;
  }

  String get _resourceLabel {
    final path = widget.projectPath;
    if (path != null && path.isNotEmpty) return '$path/${widget.filename}';
    return widget.filename;
  }

  @override
  void initState() {
    super.initState();
    _allowed = widget.budget.claimImage(ProjectUploadRef(secret: widget.secret, filename: widget.filename));
    _phase = _allowed ? _Phase.loading : _Phase.capped;
    if (_allowed) unawaited(_fetch());
  }

  @override
  void didUpdateWidget(AttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api || widget.loader != null) {
      _ownedLoader?.close();
      _ownedLoader = null;
    }
    if (oldWidget.api == widget.api &&
        oldWidget.projectId == widget.projectId &&
        oldWidget.secret == widget.secret &&
        oldWidget.filename == widget.filename &&
        identical(oldWidget.budget, widget.budget)) {
      return;
    }
    _allowed = widget.budget.claimImage(ProjectUploadRef(secret: widget.secret, filename: widget.filename));
    _failure = null;
    _mediaAudio = false;
    if (!_allowed) {
      _epoch++;
      setState(() => _phase = _Phase.capped);
      return;
    }
    setState(() => _phase = _Phase.loading);
    unawaited(_fetch());
  }

  @override
  void dispose() {
    _epoch++;
    _ownedLoader?.close();
    _ownedLoader = null;
    super.dispose();
  }

  Future<void> _fetch() async {
    if (!_allowed) return;
    final epoch = ++_epoch;
    final ref = _ref;
    try {
      final oversize = await _exceedsPixelLimit(await widget.budget.fetch(
        ref,
        () => widget.api.projectUpload(
          widget.projectId,
          widget.secret,
          widget.filename,
          onContentType: (contentType) {
            if (contentType.startsWith('video/') ||
                contentType.startsWith('audio/')) {
              throw MarkdownMediaNotImage(contentType);
            }
          },
        ),
      ));
      if (!mounted || epoch != _epoch) return;
      if (oversize) {
        setState(() => _phase = _Phase.oversize);
        return;
      }
      setState(() {
        _phase = _Phase.ready;
        _failure = null;
      });
    } on MarkdownMediaNotImage catch (error) {
      if (!mounted || epoch != _epoch) return;
      if (error.isMedia) {
        final blocked = NetworkBoundary.blocks(context);
        setState(() {
          _phase = blocked ? _Phase.offlineMedia : _Phase.media;
          _mediaAudio = error.isAudio;
          _failure = null;
        });
        return;
      }
      setState(() {
        _phase = _Phase.failed;
        _failure = _decodeFailure;
      });
    } on AttachmentBudgetExceeded {
      if (!mounted || epoch != _epoch) return;
      setState(() => _phase = _Phase.overBytes);
    } catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _phase = _Phase.failed;
        _failure = safeFailure(error);
      });
    }
  }

  /// True only when the header is readable and wider than the preview cap.
  /// A header that cannot be read falls through to [Image.memory]'s errorBuilder.
  Future<bool> _exceedsPixelLimit(Uint8List bytes) async {
    final headerSize = markdownRasterDimensions(bytes);
    if (headerSize != null &&
        headerSize.$1 > 0 &&
        headerSize.$2 > 0 &&
        headerSize.$1 * headerSize.$2 > _pixelLimit) {
      return true;
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 || height <= 0) return false;
      return width * height > _pixelLimit;
    } catch (_) {
      return false;
    } finally {
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  void _retry() {
    widget.budget.evict(_ref);
    setState(() {
      _phase = _Phase.loading;
      _failure = null;
      _mediaAudio = false;
    });
    unawaited(_fetch());
  }

  void _openFailure(ApiFailure failure) {
    final label = _resourceLabel;
    Account? account;
    try {
      account = ProviderScope.containerOf(context, listen: false).read(sessionProvider).active;
    } catch (_) {}
    unawaited(showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: FailureNotice(
            failure,
            account: account,
            resourceLabel: label,
            onRetry: () {
              Navigator.of(sheetContext).pop();
              _retry();
            },
            onSwitchAccount: endSessionFrom(sheetContext),
          ),
        ),
      ),
    ));
  }

  Widget _failureButton(Widget child, ApiFailure failure) => Semantics(
    button: true,
    label: l10n.attachmentLoadFailedDetails,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openFailure(failure),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: Align(
          alignment: Alignment.centerLeft,
          child: ExcludeSemantics(child: child),
        ),
      ),
    ),
  );

  void _open() {
    final bytes = widget.budget.cachedBytes(_ref);
    if (bytes == null) return;
    final web = widget.projectWeb;
    final opened = web == null ? null : projectUploadWeb(web, _ref);
    final label = _semanticLabel;
    Account? account;
    try {
      account = ProviderScope.containerOf(context, listen: false).read(sessionProvider).active;
    } catch (_) {}
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (context) => AttachmentViewer(
      bytes: bytes,
      title: label,
      semanticLabel: label,
      webUrl: opened,
      account: account,
    ))));
  }

  @override
  Widget build(BuildContext context) {
    if (_phase == _Phase.offlineMedia ||
        (_phase == _Phase.media && NetworkBoundary.blocks(context))) {
      return SnapshotMediaPlaceholder(
        alt: widget.alt,
        note: NetworkBoundary.modeOf(context) == NetworkBoundaryMode.demo
            ? l10n.demoOffline
            : l10n.snapshotMediaOffline,
      );
    }
    if (_phase == _Phase.media) {
      final web = widget.projectWeb;
      return MarkdownMediaCard(
        source: MarkdownMediaSource(
          kind: MarkdownMediaSourceKind.upload,
          project: '${widget.projectId}',
          path: '${widget.secret}/${widget.filename}',
          uri: web == null ? null : projectUploadWeb(web, _ref),
          filename: widget.filename,
        ),
        loader: widget.loader ??
            (_ownedLoader ??= MarkdownMediaLoader(api: widget.api)),
        account: widget.account,
        audio: _mediaAudio,
      );
    }
    final child = _buildContent(context);
    return widget.width == null && widget.height == null
        ? child
        : SizedBox(width: widget.width, height: widget.height, child: child);
  }

  Widget _buildContent(BuildContext context) {
    if (!_allowed || _phase == _Phase.capped) {
      return attachmentIconRow(l10n.attachmentExceedsDisplayLimit);
    }
    if (_phase == _Phase.overBytes) return attachmentIconRow(l10n.exceedsSizeLimit);
    if (_phase == _Phase.oversize) return attachmentIconRow(l10n.imageExceedsPreviewLimit2);
    final failure = _failure;
    if (_phase == _Phase.failed && failure != null) {
      return _failureButton(attachmentImageFallback(widget.alt, failure), failure);
    }
    if (_phase != _Phase.ready) {
      return Semantics(
        label: l10n.attachmentLoading,
        child: const ExcludeSemantics(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        ),
      );
    }
    final bytes = widget.budget.cachedBytes(_ref);
    if (bytes == null) {
      return _failureButton(attachmentIconRow(l10n.cannotDecodeImage), _decodeFailure);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: LayoutBuilder(builder: (context, constraints) {
        final layout = constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
        final cacheWidth = _decodeWidth(layout, MediaQuery.devicePixelRatioOf(context));
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: Image.memory(
            bytes,
            width: layout,
            cacheWidth: cacheWidth,
            fit: BoxFit.fitWidth,
            alignment: Alignment.topCenter,
            semanticLabel: _semanticLabel,
            frameBuilder: (context, child, frame, _) {
              if (frame == null) return child;
              return GestureDetector(onTap: _open, child: child);
            },
            errorBuilder: (_, _, _) => _failureButton(attachmentIconRow(l10n.cannotDecodeImage), _decodeFailure),
          ),
        );
      }),
    );
  }
}

class AttachmentViewer extends StatefulWidget {
  const AttachmentViewer({
    super.key,
    required this.bytes,
    required this.title,
    required this.semanticLabel,
    this.webUrl,
    this.account,
    this.sharer = const SystemArtifactSharer(),
  });

  final Uint8List bytes;
  final String title;
  final String semanticLabel;
  final Uri? webUrl;
  final Account? account;
  final ArtifactSharer sharer;

  @override
  State<AttachmentViewer> createState() => _AttachmentViewerState();
}

class _AttachmentViewerState extends State<AttachmentViewer> {
  bool _sharing = false;

  Future<void> _share(BuildContext buttonContext) async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final box = buttonContext.findRenderObject() as RenderBox?;
      final Rect? origin = box != null && box.hasSize
          ? box.localToGlobal(Offset.zero) & box.size
          : null;
      Account? account = widget.account;
      if (account == null) {
        try {
          account = ProviderScope.containerOf(context, listen: false).read(sessionProvider).active;
        } catch (_) {}
      }
      final root = await artifactStorageRoot();
      final accountSeg = account != null ? artifactAccountSegment(account) : 'shared';
      final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
      final safeName = attachmentDownloadFileName(widget.title, fallback: 'image.png');
      final dir = Directory('${root.path}/attachments/$accountSeg/share_staging/$stamp');
      dir.createSync(recursive: true);
      final tempFile = File('${dir.path}/$safeName');
      tempFile.writeAsBytesSync(widget.bytes, flush: true);
      await shareDownloadedArtifact(widget.sharer, tempFile.path, sharePositionOrigin: origin);
    } catch (error) {
      if (mounted) showFailure(context, error);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final opened = widget.webUrl;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
        actions: [
          Builder(
            builder: (buttonContext) => IconButton(
              icon: const Icon(Icons.share_outlined),
              tooltip: l10n.share,
              onPressed: _sharing ? null : () => unawaited(_share(buttonContext)),
            ),
          ),
          if (opened != null) TextButton(
            onPressed: () => unawaited(openExternal(context, opened)),
            child: Text(l10n.openInGitlab),
          ),
        ],
      ),
      body: Center(child: InteractiveViewer(
        child: Image.memory(
          widget.bytes,
          cacheWidth: _cacheWidthLimit,
          semanticLabel: widget.semanticLabel,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => attachmentIconRow(l10n.cannotDecodeImage),
        ),
      )),
    );
  }
}
