import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Whether chrome that gives way to content is showing: the bottom navigation
/// and collapsing page headers. It hides while the user scrolls toward the end
/// of a list and returns on any scroll back, near the top of the content, and
/// whenever there is nothing to scroll.
class ScrollChromeController extends ValueNotifier<bool> {
  ScrollChromeController() : super(true);

  /// Offset from the top inside which the chrome always stays visible.
  static const topSlop = 56.0;

  /// Distance of continuous scrolling in one direction that flips the state.
  static const travelThreshold = 24.0;

  double _travel = 0;
  bool _userScrolling = false;

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
    if (notification is UserScrollNotification) {
      _userScrolling = notification.direction != ScrollDirection.idle;
      if (notification.direction == ScrollDirection.forward) show();
      return false;
    }
    if (!metrics.hasContentDimensions ||
        metrics.maxScrollExtent <= metrics.minScrollExtent ||
        metrics.pixels <= metrics.minScrollExtent + topSlop) {
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
      if (_travel > travelThreshold && value) {
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

/// Provides the nearest page-level [ScrollChromeController] so nested content
/// (tabs, embedded lists) can reveal the chrome, for example after switching
/// to a tab whose list starts at the top.
class ScrollChromeScope extends InheritedWidget {
  const ScrollChromeScope({super.key, required this.controller, required super.child});
  final ScrollChromeController controller;

  static ScrollChromeController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ScrollChromeScope>()?.controller;

  @override
  bool updateShouldNotify(ScrollChromeScope oldWidget) => controller != oldWidget.controller;
}

/// Collapses [child] to zero height while [visible] is false. The child keeps
/// its natural size and slides out toward [edge], so nothing reflows inside
/// it. Screen-reader users always see it.
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
    if (widget.visible.value) {
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
/// does not reserve it a second time.
class StatusBarInset extends StatelessWidget {
  const StatusBarInset({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    SizedBox(height: MediaQuery.paddingOf(context).top),
    Expanded(child: MediaQuery.removePadding(context: context, removeTop: true, child: child)),
  ]);
}

/// Bumped by the shell when the active destination is tapped again; feeds
/// under that destination scroll back to the top.
class ScrollTopSignal extends InheritedNotifier<ValueNotifier<int>> {
  const ScrollTopSignal({super.key, required ValueNotifier<int> super.notifier, required super.child});

  /// Looked up without a rebuild dependency; listeners react to the bump.
  static ValueListenable<int>? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ScrollTopSignal>()?.notifier;
}
