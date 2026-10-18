import 'package:flutter/material.dart';

import 'motion.dart';

/// How a pane enters when it becomes the visible child of an [IndexedStack].
enum RevealStyle {
  /// Material fade through: fades in while growing slightly. For switching
  /// between root destinations.
  fadeThrough,

  /// Shared axis, moving forward: slides in from the trailing edge.
  forward,

  /// Shared axis, moving back: slides in from the leading edge.
  backward,
}

/// Plays a short entrance whenever [shown] turns true, so swapping the
/// children of an [IndexedStack] is not an instant cut. The child keeps its
/// element and state: the transitions stay in the tree at rest (opacity 1, no
/// offset) rather than being added and removed. Nothing animates on the first
/// build, unless [animateOnInsert] asks for it, or when the platform asks for
/// reduced motion.
class RevealOnShow extends StatefulWidget {
  const RevealOnShow({
    super.key,
    required this.shown,
    required this.style,
    required this.child,
    this.animateOnInsert = false,
    this.duration = Durations.medium1,
  });

  final bool shown;
  final RevealStyle style;
  final bool animateOnInsert;
  final Duration duration;
  final Widget child;

  @override
  State<RevealOnShow> createState() => _RevealOnShowState();
}

class _RevealOnShowState extends State<RevealOnShow> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  );
  late final Animation<double> _curve = CurvedAnimation(parent: _controller, curve: Easing.emphasizedDecelerate);
  bool _inserted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_inserted) return;
    _inserted = true;
    if (widget.animateOnInsert && widget.shown) _play();
  }

  @override
  void didUpdateWidget(covariant RevealOnShow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shown && !oldWidget.shown) {
      _play();
    } else if (!widget.shown) {
      _controller.value = 1;
    }
  }

  void _play() {
    if (reduceMotion(context)) {
      _controller.value = 1;
      return;
    }
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = FadeTransition(opacity: _curve, child: widget.child);
    return switch (widget.style) {
      RevealStyle.fadeThrough => ScaleTransition(
        scale: Tween<double>(begin: .96, end: 1).animate(_curve),
        child: fade,
      ),
      RevealStyle.forward || RevealStyle.backward => SlideTransition(
        position: Tween<Offset>(begin: Offset(_from(context), 0), end: Offset.zero).animate(_curve),
        child: fade,
      ),
    };
  }

  /// A small horizontal start, from the trailing edge going forward and the
  /// leading edge going back, mirrored for right-to-left text.
  double _from(BuildContext context) {
    final forward = widget.style == RevealStyle.forward;
    final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
    return (forward != rtl ? 1 : -1) * .08;
  }
}
