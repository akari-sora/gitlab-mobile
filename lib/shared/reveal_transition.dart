import 'package:flutter/material.dart';

import 'motion.dart';

/// How the layers of an [AnimatedIndexedStack] move when its index changes.
///
/// No motion uncovers the bare background: the layer being left stays painted
/// underneath (frozen and untouchable) until the switch ends. Material's fade
/// through fades out to the background before fading in, which reads as a
/// blink between two full screens. Opacity settles quickly, so the two layers
/// barely overlap, while position and scale ease out over the whole duration.
enum StackMotion {
  /// Between peer destinations: the new layer fades in over the old one and
  /// settles from slightly smaller.
  fade,

  /// One level deeper: the new layer slides in from the trailing edge over
  /// the old one.
  push,

  /// Back up a level: the old layer slides off towards the trailing edge,
  /// uncovering the new one already in place underneath.
  pop,
}

StackMotion _peers(int from, int to) => StackMotion.fade;

/// An [IndexedStack] whose switches animate. Every child keeps its element and
/// state; only the child at [index] can be touched, read out or tick. While a
/// switch plays, the child being left is painted too, below or above the new
/// one depending on the [StackMotion], and the moving child is backed by the
/// scaffold background so a page drawn straight on its parent's background
/// does not show the other through it. With reduced motion it switches at once.
class AnimatedIndexedStack extends StatefulWidget {
  const AnimatedIndexedStack({
    super.key,
    required this.index,
    required this.children,
    this.motion = _peers,
    this.sizing = StackFit.loose,
    this.onSettled,
  });

  final int index;
  final List<Widget> children;

  /// The motion for a switch from one index to another.
  final StackMotion Function(int from, int to) motion;
  final StackFit sizing;

  /// Called when a switch has finished and the layer left behind is hidden.
  final VoidCallback? onSettled;

  /// The duration of each motion: exits are shorter than entrances.
  static Duration durationOf(StackMotion motion) => switch (motion) {
    StackMotion.fade => Durations.medium1,
    StackMotion.push => Durations.medium2,
    StackMotion.pop => Durations.short4,
  };

  @override
  State<AnimatedIndexedStack> createState() => _AnimatedIndexedStackState();
}

class _AnimatedIndexedStackState extends State<AnimatedIndexedStack> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this, value: 1)
    ..addStatusListener(_onStatus);

  /// The index being left while a switch plays.
  int? _leaving;
  StackMotion _motion = StackMotion.fade;

  static const _idleOpacity = AlwaysStoppedAnimation<double>(1);
  static const _idleOffset = AlwaysStoppedAnimation<Offset>(Offset.zero);
  static const _idleScale = AlwaysStoppedAnimation<double>(1);

  late Animation<double> _opacity = _idleOpacity;
  late Animation<Offset> _offset = _idleOffset;
  late Animation<double> _scale = _idleScale;

  @override
  void didUpdateWidget(covariant AnimatedIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == oldWidget.index) return;
    if (reduceMotion(context) || oldWidget.index >= widget.children.length) {
      _settle();
      // Not during this build: the owner may update itself in response.
      final settled = widget.onSettled;
      if (settled != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) settled();
        });
      }
      return;
    }
    _leaving = oldWidget.index;
    _motion = widget.motion(oldWidget.index, widget.index);
    _configure(_motion);
    _controller
      ..duration = AnimatedIndexedStack.durationOf(_motion)
      ..forward(from: 0);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _leaving != null && mounted) {
      setState(_settle);
      widget.onSettled?.call();
    }
  }

  void _settle() {
    _leaving = null;
    _controller.value = 1;
    _opacity = _idleOpacity;
    _offset = _idleOffset;
    _scale = _idleScale;
  }

  void _configure(StackMotion motion) {
    final rtl = Directionality.maybeOf(context) == TextDirection.rtl;
    final trailing = Offset(rtl ? -.12 : .12, 0);
    Animation<T> along<T>(Tween<T> tween, Curve curve) =>
        tween.animate(CurvedAnimation(parent: _controller, curve: curve));
    switch (motion) {
      case StackMotion.fade:
        _opacity = along(Tween(begin: 0.0, end: 1.0), const Interval(0, .3, curve: Easing.standardDecelerate));
        _scale = along(Tween(begin: .97, end: 1.0), Easing.emphasizedDecelerate);
        _offset = _idleOffset;
      case StackMotion.push:
        _opacity = along(Tween(begin: 0.0, end: 1.0), const Interval(0, .3, curve: Easing.standardDecelerate));
        _offset = along(Tween(begin: trailing, end: Offset.zero), Easing.emphasizedDecelerate);
        _scale = _idleScale;
      case StackMotion.pop:
        // The leaving layer is the one that moves; these run it outwards.
        _opacity = along(Tween(begin: 1.0, end: 0.0), const Interval(.2, 1, curve: Easing.standardAccelerate));
        _offset = along(Tween(begin: Offset.zero, end: trailing), Easing.emphasizedAccelerate);
        _scale = _idleScale;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _layer(int i, {required bool visible, required bool moving, Color? backdrop}) {
    final current = i == widget.index;
    return KeyedSubtree(
      key: ValueKey<int>(i),
      child: Offstage(
        offstage: !visible,
        child: IgnorePointer(
          ignoring: !current,
          child: ExcludeSemantics(
            excluding: !current,
            child: TickerMode(
              enabled: current,
              // The same three transitions always wrap the child, at rest when
              // it is not moving, so starting a switch never rebuilds a page.
              child: FadeTransition(
                opacity: moving ? _opacity : _idleOpacity,
                child: SlideTransition(
                  position: moving ? _offset : _idleOffset,
                  child: ScaleTransition(
                    scale: moving ? _scale : _idleScale,
                    // A page that leaves its background to its parent would
                    // let the page underneath show through while it moves.
                    child: ColoredBox(
                      color: backdrop ?? const Color(0x00000000),
                      child: widget.children[i],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final leaving = _leaving;
    final count = widget.children.length;
    if (leaving == null || leaving >= count) {
      return Stack(
        fit: widget.sizing,
        children: [
          for (var i = 0; i < count; i++) _layer(i, visible: i == widget.index, moving: false),
        ],
      );
    }
    // A pop moves the leaving layer on top; the others move the new one.
    final pop = _motion == StackMotion.pop;
    final top = pop ? leaving : widget.index;
    final under = pop ? widget.index : leaving;
    final backdrop = Theme.of(context).scaffoldBackgroundColor;
    return Stack(
      fit: widget.sizing,
      children: [
        for (var i = 0; i < count; i++)
          if (i != top && i != under) _layer(i, visible: false, moving: false),
        _layer(under, visible: true, moving: false),
        _layer(top, visible: true, moving: true, backdrop: backdrop),
      ],
    );
  }
}
