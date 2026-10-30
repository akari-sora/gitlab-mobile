import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'motion.dart';

/// Marker implemented by every skeleton widget so test harnesses and helpers
/// can detect first-load placeholders with a single `is Skeleton` check.
abstract interface class Skeleton implements Widget {}

/// Sliding horizontal transform for [SkeletonShimmer]'s gradient sweep.
///
/// Moves left-to-right in [TextDirection.ltr] and flips to right-to-left in
/// [TextDirection.rtl].
@immutable
class ShimmerGradientTransform extends GradientTransform {
  const ShimmerGradientTransform({
    required this.progress,
    this.textDirection = TextDirection.ltr,
  });

  final double progress;
  final TextDirection textDirection;

  /// Signed horizontal shift factor in `[-1.0, 1.0]`.
  double get dx {
    final sweep = (progress * 2.0) - 1.0;
    return textDirection == TextDirection.rtl ? -sweep : sweep;
  }

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    final effective = textDirection ?? this.textDirection;
    final sweep = (progress * 2.0) - 1.0;
    final shift =
        (effective == TextDirection.rtl ? -sweep : sweep) * bounds.width;
    return Matrix4.translationValues(shift, 0.0, 0.0);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShimmerGradientTransform &&
          other.progress == progress &&
          other.textDirection == textDirection;

  @override
  int get hashCode => Object.hash(progress, textDirection);
}

/// Announces `正在載入` once as a live region and excludes all inner bones from
/// the semantics tree so bones never take focus or expose fake text.
class SkeletonSemantics extends StatelessWidget {
  const SkeletonSemantics({
    super.key,
    required this.child,
    this.enabled = true,
  });

  final Widget child;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return ExcludeSemantics(child: child);
    }
    return Semantics(
      label: l10n.loading2,
      liveRegion: true,
      child: ExcludeSemantics(child: child),
    );
  }
}

/// Shared shimmer group that drives all descendant [SkeletonBone]s with a
/// single [AnimationController] (1500 ms, [Curves.easeInOut]) and one
/// [ShaderMask] inside a [RepaintBoundary].
class SkeletonShimmer extends StatefulWidget implements Skeleton {
  const SkeletonShimmer({
    super.key,
    required this.child,
    this.decoration,
    this.liveRegion = true,
  });

  static const duration = Duration(milliseconds: 1500);

  final Widget child;
  final BoxDecoration? decoration;
  final bool liveRegion;

  /// Builds the theme-derived shimmer gradient for [progress] in `[0.0, 1.0]`.
  static LinearGradient gradientFor(
    BuildContext context, {
    required double progress,
    TextDirection? textDirection,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = scheme.surfaceContainerHighest;
    final highlight = theme.brightness == Brightness.dark
        ? Color.lerp(base, scheme.onSurface, 0.12)!
        : Color.lerp(base, scheme.surface, 0.65)!;
    final direction =
        textDirection ?? Directionality.maybeOf(context) ?? TextDirection.ltr;
    return LinearGradient(
      colors: [base, highlight, base],
      stops: const [0.25, 0.5, 0.75],
      transform: ShimmerGradientTransform(
        progress: progress,
        textDirection: direction,
      ),
    );
  }

  @override
  State<SkeletonShimmer> createState() => _SkeletonShimmerState();
}

class _SkeletonShimmerState extends State<SkeletonShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: SkeletonShimmer.duration,
  );
  late final CurvedAnimation _sweep = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _controller
        ..stop()
        ..value = 0;
    } else if (!_controller.isAnimating) {
      unawaited(_controller.repeat());
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = reduceMotion(context);
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    Widget content = reduce
        ? widget.child
        : AnimatedBuilder(
            animation: _sweep,
            child: widget.child,
            builder: (context, child) {
              final gradient = SkeletonShimmer.gradientFor(
                context,
                progress: _sweep.value,
                textDirection: direction,
              );
              return ShaderMask(
                blendMode: BlendMode.srcATop,
                shaderCallback: (bounds) =>
                    gradient.createShader(bounds, textDirection: direction),
                child: child,
              );
            },
          );
    if (widget.decoration != null) {
      content = DecoratedBox(decoration: widget.decoration!, child: content);
    }
    return SkeletonSemantics(
      enabled: widget.liveRegion,
      child: RepaintBoundary(child: content),
    );
  }
}

/// A single rounded placeholder bar.
class SkeletonBone extends StatelessWidget implements Skeleton {
  const SkeletonBone({
    super.key,
    this.width,
    this.widthFactor,
    this.height = 12,
    this.radius = 6,
  }) : assert(
         width == null || widthFactor == null,
         'Cannot provide both width and widthFactor.',
       );

  final double? width;
  final double? widthFactor;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = reduceMotion(context)
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.6)
        : scheme.surfaceContainerHighest;
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: SizedBox(width: width, height: height),
    );
    if (widthFactor != null) {
      return FractionallySizedBox(
        alignment: AlignmentDirectional.centerStart,
        widthFactor: widthFactor,
        child: bar,
      );
    }
    return bar;
  }
}

/// A vertical stack of [SkeletonBone] text lines with varied width factors.
class SkeletonLines extends StatelessWidget implements Skeleton {
  const SkeletonLines({
    super.key,
    this.factors = const [0.92, 0.78, 0.60],
    this.lineHeight = 12,
    this.spacing = 10,
    this.radius = 6,
  });

  final List<double> factors;
  final double lineHeight;
  final double spacing;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < factors.length; i++) ...[
          if (i > 0) SizedBox(height: spacing),
          SkeletonBone(
            widthFactor: factors[i],
            height: lineHeight,
            radius: radius,
          ),
        ],
      ],
    );
  }
}

Widget _boundedSkeletonBody(Widget child) => LayoutBuilder(
  builder: (context, constraints) {
    if (!constraints.hasBoundedHeight) {
      return child;
    }
    return ClipRect(
      child: Align(
        alignment: Alignment.topCenter,
        child: UnconstrainedBox(
          alignment: Alignment.topCenter,
          constrainedAxis: Axis.horizontal,
          child: child,
        ),
      ),
    );
  },
);

/// Placeholder rows shown while a list loads for the first time, in the shape
/// of the rows that will replace them, so the screen keeps its layout instead
/// of showing a lone spinner.
///
/// In a bounded height (an `Expanded` body) it shows only the rows that fit;
/// in a scroll view it shows [rows].
class RowsSkeleton extends StatelessWidget implements Skeleton {
  const RowsSkeleton({
    super.key,
    this.rows = 8,
    this.grouped = false,
    this.padding = EdgeInsets.zero,
  });

  final int rows;

  /// Draws the rows on one rounded surface, like a grouped `RecordsFeed`.
  final bool grouped;

  final EdgeInsetsGeometry padding;

  static const rowHeight = 64.0;
  static const rowPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);

  static const _title = [.72, .54, .66, .46, .7, .58, .5, .64];
  static const _detail = [.4, .3, .36, .24, .44, .32, .28, .38];

  Widget _row(int index) => SizedBox(
    height: rowHeight,
    child: Padding(
      padding: rowPadding,
      child: Row(
        children: [
          const SkeletonBone(width: 36, height: 36, radius: 8),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SkeletonBone(
                  widthFactor: _title[index % _title.length],
                  height: 14,
                  radius: 4,
                ),
                const SizedBox(height: 8),
                SkeletonBone(
                  widthFactor: _detail[index % _detail.length],
                  height: 10,
                  radius: 4,
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final decoration = grouped
        ? BoxDecoration(
            color: theme.cardTheme.color ?? scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.dividerTheme.color ?? scheme.outlineVariant,
            ),
          )
        : null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final resolvedPadding = padding.resolve(
          Directionality.maybeOf(context) ?? TextDirection.ltr,
        );
        final availableHeight = constraints.hasBoundedHeight
            ? (constraints.maxHeight - resolvedPadding.vertical).clamp(
                0.0,
                double.infinity,
              )
            : double.infinity;
        final fit = constraints.hasBoundedHeight
            ? (availableHeight / rowHeight).floor().clamp(1, rows)
            : rows;
        final column = Column(
          mainAxisSize: MainAxisSize.min,
          children: [for (var i = 0; i < fit; i++) _row(i)],
        );
        Widget shimmer = SkeletonShimmer(decoration: decoration, child: column);
        if (padding != EdgeInsets.zero) {
          shimmer = Padding(padding: padding, child: shimmer);
        }
        if (constraints.hasBoundedHeight &&
            availableHeight < fit * rowHeight) {
          return ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              child: UnconstrainedBox(
                alignment: Alignment.topCenter,
                constrainedAxis: Axis.horizontal,
                child: shimmer,
              ),
            ),
          );
        }
        return Align(alignment: Alignment.topCenter, child: shimmer);
      },
    );
  }
}

/// Skeleton for README and Markdown previews: heading bar, paragraph lines,
/// and one media box.
class MarkdownSkeleton extends StatelessWidget implements Skeleton {
  const MarkdownSkeleton({super.key, this.padding = defaultPadding});

  static const defaultPadding = EdgeInsets.all(20);
  static const cardPadding = EdgeInsets.all(16);
  static const overviewReadmePadding = EdgeInsets.fromLTRB(16, 8, 16, 24);

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return _boundedSkeletonBody(
      SkeletonShimmer(
        child: Padding(
          padding: padding,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SkeletonBone(widthFactor: 0.52, height: 22, radius: 6),
              SizedBox(height: 16),
              SkeletonLines(
                factors: [0.96, 0.88, 0.92, 0.64],
                lineHeight: 13,
                spacing: 10,
              ),
              SizedBox(height: 18),
              SkeletonBone(height: 136, radius: 12),
              SizedBox(height: 18),
              SkeletonLines(
                factors: [0.90, 0.76, 0.54],
                lineHeight: 13,
                spacing: 10,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton for source files, blame, and the editor's first load: line-number
/// gutter plus uneven code lines.
class CodeSkeleton extends StatelessWidget implements Skeleton {
  const CodeSkeleton({
    super.key,
    this.padding = defaultPadding,
    this.lines = 12,
  });

  static const defaultPadding = EdgeInsets.all(12);
  static const editorPadding = EdgeInsets.fromLTRB(20, 8, 20, 32);
  static const blamePadding = EdgeInsets.fromLTRB(12, 8, 12, 8);
  static const gutterWidth = 48.0;

  static const _lineFactors = [
    0.68,
    0.42,
    0.84,
    0.56,
    0.76,
    0.32,
    0.90,
    0.62,
    0.48,
    0.80,
    0.38,
    0.72,
  ];

  final EdgeInsetsGeometry padding;
  final int lines;

  @override
  Widget build(BuildContext context) {
    return _boundedSkeletonBody(
      SkeletonShimmer(
        child: Padding(
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < lines; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                Row(
                  children: [
                    const SizedBox(
                      width: gutterWidth,
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: SkeletonBone(width: 24, height: 11, radius: 4),
                      ),
                    ),
                    Expanded(
                      child: SkeletonBone(
                        widthFactor: _lineFactors[i % _lineFactors.length],
                        height: 11,
                        radius: 4,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton for unified/review diffs, compare views, and commit diffs:
/// file header, hunk header, and diff lines.
class DiffSkeleton extends StatelessWidget implements Skeleton {
  const DiffSkeleton({super.key, this.padding = defaultPadding});

  static const defaultPadding = EdgeInsets.all(16);
  static const filePadding = EdgeInsets.symmetric(horizontal: 16, vertical: 8);

  static const _diffLineFactors = [
    0.82,
    0.64,
    0.90,
    0.72,
    0.56,
    0.86,
    0.48,
    0.76,
  ];

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return _boundedSkeletonBody(
      SkeletonShimmer(
        child: Padding(
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  SkeletonBone(width: 18, height: 18, radius: 4),
                  SizedBox(width: 10),
                  Expanded(
                    child: SkeletonBone(
                      widthFactor: 0.66,
                      height: 14,
                      radius: 6,
                    ),
                  ),
                  SizedBox(width: 10),
                  SkeletonBone(width: 48, height: 18, radius: 9),
                ],
              ),
              const SizedBox(height: 12),
              const SkeletonBone(widthFactor: 0.46, height: 18, radius: 6),
              const SizedBox(height: 12),
              for (var i = 0; i < _diffLineFactors.length; i++) ...[
                if (i > 0) const SizedBox(height: 9),
                Row(
                  children: [
                    const SkeletonBone(width: 28, height: 11, radius: 4),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SkeletonBone(
                        widthFactor: _diffLineFactors[i],
                        height: 11,
                        radius: 4,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton for CI job logs: monospace-proportioned log lines with step/time
/// prefixes.
class LogSkeleton extends StatelessWidget implements Skeleton {
  const LogSkeleton({
    super.key,
    this.padding = defaultPadding,
    this.lines = 12,
  });

  static const defaultPadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 8,
  );

  static const _logLineFactors = [
    0.74,
    0.58,
    0.88,
    0.66,
    0.92,
    0.46,
    0.80,
    0.62,
    0.84,
    0.52,
    0.78,
    0.60,
  ];

  final EdgeInsetsGeometry padding;
  final int lines;

  @override
  Widget build(BuildContext context) {
    return _boundedSkeletonBody(
      SkeletonShimmer(
        child: Padding(
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < lines; i++) ...[
                if (i > 0) const SizedBox(height: 10),
                Row(
                  children: [
                    const SkeletonBone(width: 36, height: 11, radius: 4),
                    const SizedBox(width: 10),
                    Expanded(
                      child: SkeletonBone(
                        widthFactor: _logLineFactors[i % _logLineFactors.length],
                        height: 11,
                        radius: 4,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton for issue and merge-request detail pages: title, label pills,
/// description lines, and two comment blocks.
class DetailSkeleton extends StatelessWidget implements Skeleton {
  const DetailSkeleton({super.key, this.padding = defaultPadding});

  static const defaultPadding = EdgeInsets.fromLTRB(16, 8, 16, 24);
  static const headerPadding = EdgeInsets.fromLTRB(16, 8, 16, 12);

  final EdgeInsetsGeometry padding;

  Widget _commentBlock(List<double> factors) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Row(
        children: [
          SkeletonBone(width: 28, height: 28, radius: 14),
          SizedBox(width: 10),
          SkeletonBone(width: 108, height: 12, radius: 6),
          SizedBox(width: 8),
          SkeletonBone(width: 52, height: 10, radius: 5),
        ],
      ),
      const SizedBox(height: 10),
      SkeletonLines(factors: factors, lineHeight: 12, spacing: 8),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return _boundedSkeletonBody(
      SkeletonShimmer(
        child: Padding(
          padding: padding,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SkeletonBone(widthFactor: 0.88, height: 20, radius: 6),
              const SizedBox(height: 8),
              const SkeletonBone(widthFactor: 0.54, height: 20, radius: 6),
              const SizedBox(height: 12),
              const Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  SkeletonBone(width: 64, height: 24, radius: 999),
                  SkeletonBone(width: 84, height: 24, radius: 999),
                  SkeletonBone(width: 56, height: 24, radius: 999),
                ],
              ),
              const SizedBox(height: 18),
              const SkeletonLines(
                factors: [0.95, 0.88, 0.92, 0.66],
                lineHeight: 13,
                spacing: 10,
              ),
              const SizedBox(height: 24),
              _commentBlock(const [0.92, 0.76]),
              const SizedBox(height: 18),
              _commentBlock(const [0.86, 0.68, 0.50]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton for Home hub sections (such as Starred Projects), matching
/// `HubRow` padding and monogram-plus-two-line layout.
class HomeSectionSkeleton extends StatelessWidget implements Skeleton {
  const HomeSectionSkeleton({
    super.key,
    this.rows = 3,
    this.padding = EdgeInsets.zero,
  });

  static const rowPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 8);
  static const _titleFactors = [0.58, 0.46, 0.64, 0.52];
  static const _subtitleFactors = [0.38, 0.30, 0.42, 0.34];

  final int rows;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < rows; i++)
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: Padding(
                  padding: rowPadding,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SkeletonBone(width: 32, height: 32, radius: 8),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(height: 2),
                            SkeletonBone(
                              widthFactor:
                                  _titleFactors[i % _titleFactors.length],
                              height: 15,
                              radius: 4,
                            ),
                            const SizedBox(height: 6),
                            SkeletonBone(
                              widthFactor:
                                  _subtitleFactors[i % _subtitleFactors.length],
                              height: 11,
                              radius: 4,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
