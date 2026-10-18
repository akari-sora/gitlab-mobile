import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'motion.dart';

/// Whether chrome that gives way to content is showing: the bottom navigation
/// and collapsing page headers. It hides while the user drags toward the end
/// of a list that scrolls far enough, and returns on a scroll back, near the
/// top of the content, and when nothing scrolls any more.
class ScrollChromeController extends ValueNotifier<bool> {
  ScrollChromeController() : super(true);

  /// Offset from the top inside which the chrome always stays visible.
  static const topSlop = 56.0;

  /// Distance of continuous scrolling in one direction that flips the state.
  static const travelThreshold = 24.0;

  /// Content that scrolls less than this keeps the chrome. Hiding a header and
  /// the navigation bar together grows the viewport by about 150 dp, which
  /// would end the scroll and bring the chrome straight back.
  static const minHideExtent = 200.0;

  double _travel = 0;
  bool _userScrolling = false;
  double _hiddenViewport = 0;

  /// How much the viewport grew the last time the chrome hid. Content whose
  /// scroll range is not well above it would fit once the chrome is gone, so
  /// it keeps the chrome instead of hiding and bouncing back.
  double _growth = 0;

  void show() {
    _travel = 0;
    value = true;
  }

  void hide() {
    _travel = 0;
    value = false;
  }

  /// Feed from a [NotificationListener]. Always returns false so the
  /// notification keeps bubbling to outer listeners.
  bool handle(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis != Axis.vertical) return false;
    // Lists kept alive out of sight (other destinations, the list behind an
    // open detail) still lay out and report metrics; they run without tickers.
    final origin = notification.context;
    if (origin is Element && origin.mounted && !TickerMode.getValuesNotifier(origin).value.enabled) return false;
    if (notification is UserScrollNotification) {
      _userScrolling = notification.direction != ScrollDirection.idle;
      return false;
    }
    if (!metrics.hasContentDimensions) return false;
    if (!value && metrics.viewportDimension > _hiddenViewport) {
      _growth = metrics.viewportDimension - _hiddenViewport;
    }
    // Hidden chrome only returns for content that no longer scrolls at all:
    // anything still scrollable can bring it back with a scroll up.
    if (metrics.maxScrollExtent <= metrics.minScrollExtent || metrics.pixels <= metrics.minScrollExtent + topSlop) {
      if (!value) show();
      _travel = 0;
      return false;
    }
    if (notification is ScrollUpdateNotification) {
      // Programmatic jumps (restoring a position, refreshing) leave it alone.
      if (notification.dragDetails == null && !_userScrolling) return false;
      final delta = notification.scrollDelta ?? 0;
      if (delta == 0) return false;
      if ((delta > 0) != (_travel > 0)) _travel = 0;
      _travel += delta;
      final range = metrics.maxScrollExtent - metrics.minScrollExtent;
      if (_travel > travelThreshold && value && range >= math.max(minHideExtent, _growth + topSlop + travelThreshold)) {
        _hiddenViewport = metrics.viewportDimension;
        value = false;
      } else if (_travel < -travelThreshold && !value) {
        value = true;
      }
    }
    return false;
  }
}

/// Asks the chrome above to come back, e.g. after opening or closing a detail
/// from a list that was scrolled with the navigation tucked away.
class RevealChromeNotification extends Notification {
  const RevealChromeNotification();
}

/// Collapses [child] to zero height while [visible] is false. The child keeps
/// its natural size and slides out toward [edge], so nothing reflows inside
/// it. Screen-reader users always see it; reduced motion skips the slide.
class CollapsingChrome extends StatefulWidget {
  const CollapsingChrome({
    super.key,
    required this.visible,
    required this.child,
    this.edge = AxisDirection.up,
  });
  final ValueListenable<bool> visible;
  final Widget child;

  /// [AxisDirection.up] for headers, [AxisDirection.down] for bottom bars.
  final AxisDirection edge;

  @override
  State<CollapsingChrome> createState() => _CollapsingChromeState();
}

class _CollapsingChromeState extends State<CollapsingChrome> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.visible.value ? 1 : 0,
  );
  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    widget.visible.addListener(_sync);
  }

  @override
  void didUpdateWidget(covariant CollapsingChrome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      oldWidget.visible.removeListener(_sync);
      widget.visible.addListener(_sync);
      _sync();
    }
  }

  void _sync() {
    if (!mounted) return;
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _controller.value = widget.visible.value ? 1 : 0;
    } else if (widget.visible.value) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    widget.visible.removeListener(_sync);
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.accessibleNavigationOf(context)) return widget.child;
    return ClipRect(
      child: SizeTransition(
        sizeFactor: _curve,
        alignment: widget.edge == AxisDirection.up ? Alignment.bottomCenter : Alignment.topCenter,
        child: widget.child,
      ),
    );
  }
}

/// Reserves the status-bar height above [child] and removes it from the
/// child's padding, so a page nested in place (an issue inside a project)
/// does not reserve it a second time. The strip takes the app bar colour
/// (or [color]) so it reads as part of the header above a darker canvas.
class StatusBarInset extends StatelessWidget {
  const StatusBarInset({super.key, required this.child, this.color});
  final Widget child;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ColoredBox(
        color: color ?? theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface,
        child: SizedBox(height: MediaQuery.paddingOf(context).top),
      ),
      Expanded(child: MediaQuery.removePadding(context: context, removeTop: true, child: child)),
    ]);
  }
}

/// Bumped by the shell when the active destination is tapped again; feeds
/// under that destination scroll back to the top.
class ScrollTopSignal extends InheritedNotifier<ValueNotifier<int>> {
  const ScrollTopSignal({super.key, required ValueNotifier<int> super.notifier, required super.child});

  /// Looked up without a rebuild dependency; listeners react to the bump.
  static ValueListenable<int>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ScrollTopSignal>()?.notifier;
}

/// Scrolls [controller] back to the top when the [ScrollTopSignal] above
/// fires, but only while this subtree is on screen: lists kept alive behind
/// an open detail or on an inactive tab run with tickers disabled.
class ScrollToTopOnSignal extends StatefulWidget {
  const ScrollToTopOnSignal({super.key, required this.controller, required this.child});
  final ScrollController controller;
  final Widget child;
  @override
  State<ScrollToTopOnSignal> createState() => _ScrollToTopOnSignalState();
}

class _ScrollToTopOnSignalState extends State<ScrollToTopOnSignal> {
  ValueListenable<int>? _signal;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final signal = ScrollTopSignal.maybeOf(context);
    if (!identical(signal, _signal)) {
      _signal?.removeListener(_toTop);
      _signal = signal?..addListener(_toTop);
    }
  }

  void _toTop() {
    final controller = widget.controller;
    if (!mounted || !controller.hasClients || !TickerMode.getValuesNotifier(context).value.enabled) return;
    unawaited(scrollToStart(context, controller));
  }

  @override
  void dispose() {
    _signal?.removeListener(_toTop);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
