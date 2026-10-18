import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Whether the platform asks for less motion: Android's "remove animations"
/// (`MediaQuery.disableAnimations`) or iOS Reduce Motion, which Flutter only
/// reports through the accessibility features.
bool reduceMotion(BuildContext context) =>
    (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ||
    View.of(context).platformDispatcher.accessibilityFeatures.reduceMotion;

/// [duration], or zero when the platform asks for less motion.
Duration motionDuration(BuildContext context, Duration duration) =>
    reduceMotion(context) ? Duration.zero : duration;

/// Scrolls [controller] back to its first row; with reduced motion it jumps.
///
/// It glides the whole way rather than jumping near the top first: a list of
/// rows without a fixed extent has to build every row it passes on the way
/// back either way, and a jump would build them all in a single frame.
Future<void> scrollToStart(BuildContext context, ScrollController controller) async {
  final start = controller.position.minScrollExtent;
  if (reduceMotion(context)) {
    controller.jumpTo(start);
    return;
  }
  await controller.animateTo(start, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
}

/// Grows to show [child] when [expanded] and folds it away when not, instead
/// of rows popping in and out; content below follows smoothly. The child stays
/// built while it folds and leaves the tree once it is gone.
class ExpandSection extends StatefulWidget {
  const ExpandSection({super.key, required this.expanded, required this.child});
  final bool expanded;
  final Widget child;
  @override
  State<ExpandSection> createState() => _ExpandSectionState();
}

class _ExpandSectionState extends State<ExpandSection> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Durations.medium2,
    value: widget.expanded ? 1 : 0,
  )..addStatusListener((status) {
      if (status == AnimationStatus.dismissed && mounted) setState(() {});
    });
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Easing.emphasizedDecelerate,
    reverseCurve: Easing.emphasizedAccelerate,
  );

  @override
  void didUpdateWidget(covariant ExpandSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;
    if (reduceMotion(context)) {
      _controller.value = widget.expanded ? 1 : 0;
    } else if (widget.expanded) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.expanded && _controller.isDismissed) return const SizedBox(width: double.infinity);
    return SizeTransition(
      sizeFactor: _curve,
      alignment: Alignment.topCenter,
      child: FadeTransition(opacity: _curve, child: widget.child),
    );
  }
}

/// An expand chevron that turns over as its section opens.
class TurnChevron extends StatelessWidget {
  const TurnChevron({super.key, required this.open, this.size, this.color});
  final bool open;
  final double? size;
  final Color? color;
  @override
  Widget build(BuildContext context) => AnimatedRotation(
    turns: open ? .5 : 0,
    duration: motionDuration(context, Durations.short4),
    curve: Easing.standard,
    child: Icon(Icons.expand_more, size: size, color: color),
  );
}

/// Light haptic confirmation for the outcome of an action the user started:
/// a write that landed or one that failed. Not for taps, scrolls or switches.
abstract final class Haptics {
  static Future<void> success() => HapticFeedback.successNotification();
  static Future<void> failure() => HapticFeedback.errorNotification();
  static Future<void> selection() => HapticFeedback.selectionClick();
}
