import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/failure.dart';
import '../core/gitlab_api.dart';
import '../core/models.dart';
import '../core/providers.dart';
import 'attachment_budget.dart';
import 'attachment_ref.dart';
import 'external_link.dart';
import 'workspace_ui.dart';

const _pixelLimit = 24000000;
const _cacheWidthLimit = 2048;

const _decodeFailure = ApiFailure(
  FailureKind.unsupported,
  title: '無法解碼圖片',
  detail: '伺服器有回傳這份附件，但內容不是可解碼的圖片。',
);

String attachmentImageLabel(String? alt, [ApiFailure? failure]) {
  final name = alt != null && alt.isNotEmpty ? alt : '附加圖片（在 GitLab 開啟）';
  if (failure == null) return name;
  final reason = failure.kind == FailureKind.tooLarge ? '超過大小上限' : failure.title;
  return '$name 無法載入附件（$reason）';
}

Widget attachmentIconRow(String label) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 8),
  child: Row(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.image_outlined, size: 18),
    const SizedBox(width: 6),
    Flexible(child: Text(label)),
  ]),
);

Widget attachmentImageFallback(String? alt, [ApiFailure? failure]) =>
    attachmentIconRow(attachmentImageLabel(alt, failure));

int _decodeWidth(double layoutWidth, double devicePixelRatio) {
  final raw = (layoutWidth * devicePixelRatio).round();
  if (raw < 64) return 64;
  if (raw > _cacheWidthLimit) return _cacheWidthLimit;
  return raw;
}

enum _Phase { loading, ready, failed, capped, overBytes, oversize }

class AttachmentImage extends StatefulWidget {
  const AttachmentImage({
    super.key,
    required this.api,
    required this.budget,
    required this.projectId,
    required this.secret,
    required this.filename,
    this.alt,
    this.projectWeb,
    this.projectPath,
  });
  final GitLabApi api;
  final AttachmentBudget budget;
  final int projectId;
  final String secret;
  final String filename;
  final String? alt;
  final Uri? projectWeb;
  final String? projectPath;
  @override
  State<AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<AttachmentImage> {
  _Phase _phase = _Phase.loading;
  ApiFailure? _failure;
  bool _allowed = false;
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
    _allowed = widget.budget.claimImage();
    _phase = _allowed ? _Phase.loading : _Phase.capped;
    if (_allowed) unawaited(_fetch());
  }

  @override
  void didUpdateWidget(AttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api == widget.api &&
        oldWidget.projectId == widget.projectId &&
        oldWidget.secret == widget.secret &&
        oldWidget.filename == widget.filename &&
        identical(oldWidget.budget, widget.budget)) {
      return;
    }
    _allowed = widget.budget.claimImage();
    _failure = null;
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
    super.dispose();
  }

  Future<void> _fetch() async {
    if (!_allowed) return;
    final epoch = ++_epoch;
    final ref = _ref;
    try {
      final oversize = await _exceedsPixelLimit(await widget.budget.fetch(
        ref,
        () => widget.api.projectUpload(widget.projectId, widget.secret, widget.filename),
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
    label: '附件載入失敗，查看詳情',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openFailure(failure),
      child: ExcludeSemantics(child: child),
    ),
  );

  void _open() {
    final bytes = widget.budget.cachedBytes(_ref);
    if (bytes == null) return;
    final web = widget.projectWeb;
    final opened = web == null ? null : projectUploadWeb(web, _ref);
    final label = _semanticLabel;
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (context) => AttachmentViewer(
      bytes: bytes,
      title: label,
      semanticLabel: label,
      webUrl: opened,
    ))));
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed || _phase == _Phase.capped) {
      return attachmentIconRow('附件超過本頁顯示上限');
    }
    if (_phase == _Phase.overBytes) return attachmentIconRow('超過大小上限');
    if (_phase == _Phase.oversize) return attachmentIconRow('圖片尺寸超過預覽上限');
    final failure = _failure;
    if (_phase == _Phase.failed && failure != null) {
      return _failureButton(attachmentImageFallback(widget.alt, failure), failure);
    }
    if (_phase != _Phase.ready) {
      return Semantics(
        label: '附件載入中',
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
      return _failureButton(attachmentIconRow('無法解碼圖片'), _decodeFailure);
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
            errorBuilder: (_, _, _) => _failureButton(attachmentIconRow('無法解碼圖片'), _decodeFailure),
          ),
        );
      }),
    );
  }
}

class AttachmentViewer extends StatelessWidget {
  const AttachmentViewer({
    super.key,
    required this.bytes,
    required this.title,
    required this.semanticLabel,
    this.webUrl,
  });
  final Uint8List bytes;
  final String title;
  final String semanticLabel;
  final Uri? webUrl;

  @override
  Widget build(BuildContext context) {
    final opened = webUrl;
    return Scaffold(
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          if (opened != null) TextButton(
            onPressed: () => unawaited(openExternal(context, opened)),
            child: const Text('在 GitLab 開啟'),
          ),
        ],
      ),
      body: Center(child: InteractiveViewer(
        child: Image.memory(
          bytes,
          cacheWidth: _cacheWidthLimit,
          semanticLabel: semanticLabel,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => attachmentIconRow('無法解碼圖片'),
        ),
      )),
    );
  }
}
