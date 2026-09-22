import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../core/failure.dart';
import '../core/gitlab_api.dart';
import 'attachment_ref.dart';
import 'external_link.dart';

String attachmentImageLabel(String? alt, [ApiFailure? failure]) {
  final name = alt != null && alt.isNotEmpty ? alt : '附加圖片（在 GitLab 開啟）';
  if (failure == null) return name;
  final reason = failure.kind == FailureKind.tooLarge ? '超過大小上限' : failure.title;
  return '$name 無法載入附件（$reason）';
}

Widget attachmentImageFallback(String? alt, [ApiFailure? failure]) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 8),
  child: Row(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.image_outlined, size: 18),
    const SizedBox(width: 6),
    Flexible(child: Text(attachmentImageLabel(alt, failure))),
  ]),
);

class AttachmentImage extends StatefulWidget {
  const AttachmentImage({
    super.key,
    required this.api,
    required this.projectId,
    required this.secret,
    required this.filename,
    this.alt,
    this.projectWeb,
  });
  final GitLabApi api;
  final int projectId;
  final String secret;
  final String filename;
  final String? alt;
  final Uri? projectWeb;
  @override
  State<AttachmentImage> createState() => _AttachmentImageState();
}

class _AttachmentImageState extends State<AttachmentImage> {
  Uint8List? _bytes;
  ApiFailure? _failure;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(AttachmentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.projectId != widget.projectId ||
        oldWidget.secret != widget.secret ||
        oldWidget.filename != widget.filename) {
      unawaited(_load(reset: true));
    }
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    final epoch = ++_epoch;
    if (reset && mounted) {
      setState(() {
        _bytes = null;
        _failure = null;
      });
    }
    try {
      final bytes = await widget.api.projectUpload(widget.projectId, widget.secret, widget.filename);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _bytes = bytes;
        _failure = null;
      });
    } catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _bytes = null;
        _failure = safeFailure(error);
      });
    }
  }

  void _open(BuildContext context, Uint8List bytes) {
    final alt = widget.alt;
    final title = alt != null && alt.isNotEmpty ? alt : widget.filename;
    final web = widget.projectWeb;
    final ref = ProjectUploadRef(secret: widget.secret, filename: widget.filename);
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (context) => Scaffold(
      appBar: AppBar(
        title: Text(title, overflow: TextOverflow.ellipsis),
        actions: [
          if (web != null) TextButton(
            onPressed: () => unawaited(openExternal(context, projectUploadWeb(web, ref))),
            child: const Text('在 GitLab 開啟'),
          ),
        ],
      ),
      body: Center(child: InteractiveViewer(
        child: Image.memory(bytes, semanticLabel: alt, fit: BoxFit.contain,
          errorBuilder: (_, _, _) => attachmentImageFallback(alt)),
      )),
    ))));
  }

  @override
  Widget build(BuildContext context) {
    final failure = _failure;
    if (failure != null) return attachmentImageFallback(widget.alt, failure);
    final bytes = _bytes;
    if (bytes == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 320.0;
        return GestureDetector(
          onTap: () => _open(context, bytes),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: Image.memory(
              bytes,
              width: width,
              fit: BoxFit.fitWidth,
              alignment: Alignment.topCenter,
              semanticLabel: widget.alt,
              errorBuilder: (_, _, _) => attachmentImageFallback(widget.alt),
            ),
          ),
        );
      }),
    );
  }
}
