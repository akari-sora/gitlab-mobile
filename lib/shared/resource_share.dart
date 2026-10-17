import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'external_link.dart';

/// A compact native share action for a canonical GitLab web URL.
class ResourceShareButton extends StatefulWidget {
  const ResourceShareButton({
    super.key,
    required this.uri,
    this.ownerKey,
    this.isCurrent,
    this.builder,
  });

  final Uri uri;
  final Object? ownerKey;
  final bool Function()? isCurrent;

  /// Renders the control; receives null while sharing is unavailable or busy.
  /// Defaults to an icon button.
  final Widget Function(BuildContext context, VoidCallback? onPressed)? builder;

  @override
  State<ResourceShareButton> createState() => _ResourceShareButtonState();
}

class _ResourceShareButtonState extends State<ResourceShareButton> {
  bool _busy = false;
  int _operation = 0;

  bool get _mayShare =>
      safeExternalUri(widget.uri) &&
      widget.uri.host.isNotEmpty &&
      (widget.isCurrent?.call() ?? true);

  @override
  void didUpdateWidget(covariant ResourceShareButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri || oldWidget.ownerKey != widget.ownerKey) {
      _operation++;
      _busy = false;
    }
  }

  @override
  void dispose() {
    _operation++;
    super.dispose();
  }

  bool _sameRequest(int operation, Uri uri, Object? ownerKey) =>
      mounted &&
      operation == _operation &&
      widget.uri == uri &&
      widget.ownerKey == ownerKey;

  bool _current(
    int operation,
    Uri uri,
    Object? ownerKey,
    bool Function()? originalIsCurrent,
  ) =>
      _sameRequest(operation, uri, ownerKey) &&
      (originalIsCurrent?.call() ?? true) &&
      (widget.isCurrent?.call() ?? true);

  Future<void> _share() async {
    if (_busy || !_mayShare) return;
    final uri = widget.uri;
    final ownerKey = widget.ownerKey;
    final originalIsCurrent = widget.isCurrent;
    final operation = ++_operation;
    final renderObject = context.findRenderObject();
    final origin = renderObject is RenderBox && renderObject.hasSize
        ? renderObject.localToGlobal(Offset.zero) & renderObject.size
        : null;
    setState(() => _busy = true);
    try {
      await SharePlus.instance.share(
        ShareParams(text: uri.toString(), sharePositionOrigin: origin),
      );
    } catch (_) {
      if (!mounted || !_current(operation, uri, ownerKey, originalIsCurrent)) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('無法分享連結。')));
    } finally {
      if (_current(operation, uri, ownerKey, originalIsCurrent)) {
        setState(() => _busy = false);
      } else if (_sameRequest(operation, uri, ownerKey)) {
        _busy = false;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final onPressed = _busy || !_mayShare ? null : _share;
    return widget.builder?.call(context, onPressed) ?? IconButton(
      tooltip: '分享連結',
      onPressed: onPressed,
      icon: const Icon(Icons.share_outlined),
    );
  }
}
