import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'code_text_view.dart';
import 'layout_constants.dart';
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

  double _signedShift(TextDirection direction) {
    final sweep = (progress * 1.5) - 0.75;
    return direction == TextDirection.rtl ? -sweep : sweep;
  }

  /// Signed horizontal shift factor in `[-0.75, 0.75]`.
  double get dx => _signedShift(textDirection);

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) {
    final effective = textDirection ?? this.textDirection;
    final shift = _signedShift(effective) * bounds.width;
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
      container: true,
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
    this.sweepDirection,
  });

  static const duration = Duration(milliseconds: 1500);

  final Widget child;
  final BoxDecoration? decoration;
  final bool liveRegion;
  final TextDirection? sweepDirection;

  static (Color, Color) _colorsFor(ThemeData theme) {
    final scheme = theme.colorScheme;
    if (theme.brightness == Brightness.dark) {
      final base = scheme.surfaceContainerHighest;
      final highlight = Color.lerp(base, scheme.onSurface, 0.12)!;
      return (base, highlight);
    }
    final base = Color.lerp(
      scheme.surfaceContainerHighest,
      scheme.outline,
      0.55,
    )!;
    final highlight = Color.lerp(base, scheme.surface, 0.35)!;
    return (base, highlight);
  }

  static LinearGradient _buildGradient({
    required Color base,
    required Color highlight,
    required double progress,
    required TextDirection textDirection,
  }) => LinearGradient(
    colors: [base, highlight, base],
    stops: const [0.25, 0.5, 0.75],
    transform: ShimmerGradientTransform(
      progress: progress,
      textDirection: textDirection,
    ),
  );

  /// Builds the theme-derived shimmer gradient for [progress] in `[0.0, 1.0]`.
  static LinearGradient gradientFor(
    BuildContext context, {
    required double progress,
    TextDirection? textDirection,
  }) {
    final (base, highlight) = _colorsFor(Theme.of(context));
    final direction =
        textDirection ?? Directionality.maybeOf(context) ?? TextDirection.ltr;
    return _buildGradient(
      base: base,
      highlight: highlight,
      progress: progress,
      textDirection: direction,
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
    final disable = reduceMotion(context);
    final tickerEnabled = TickerMode.valuesOf(context).enabled;
    if (disable || !tickerEnabled) {
      _controller.stop();
      if (disable) {
        _controller.value = 0;
      }
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
    final direction =
        widget.sweepDirection ??
        Directionality.maybeOf(context) ??
        TextDirection.ltr;
    final (baseColor, highlightColor) = SkeletonShimmer._colorsFor(
      Theme.of(context),
    );
    Widget content = reduce
        ? widget.child
        : AnimatedBuilder(
            animation: _sweep,
            child: RepaintBoundary(child: widget.child),
            builder: (context, child) {
              final gradient = SkeletonShimmer._buildGradient(
                base: baseColor,
                highlight: highlightColor,
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
    final (base, _) = SkeletonShimmer._colorsFor(Theme.of(context));
    final color = reduceMotion(context) ? base.withValues(alpha: 0.8) : base;
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
          clipBehavior: Clip.hardEdge,
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
    this.itemHeight = rowHeight,
    this.leadingSize = 36,
    this.leadingRadius = 8,
    this.showLeading = true,
    this.showSubtitle = true,
    this.liveRegion = true,
  });

  final int rows;

  /// Draws the rows on one rounded surface, like a grouped `RecordsFeed`.
  final bool grouped;

  final EdgeInsetsGeometry padding;
  final double itemHeight;
  final double leadingSize;
  final double leadingRadius;
  final bool showLeading;
  final bool showSubtitle;
  final bool liveRegion;

  static const rowHeight = 64.0;
  static const rowPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);

  static const _title = [.72, .54, .66, .46, .7, .58, .5, .64];
  static const _detail = [.4, .3, .36, .24, .44, .32, .28, .38];

  Widget _row(int index) {
    final contentHeight = showSubtitle ? 32.0 : 14.0;
    final verticalPad = ((itemHeight - contentHeight) / 2).clamp(2.0, 12.0);
    return SizedBox(
      height: itemHeight,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: verticalPad),
        child: Row(
          children: [
            if (showLeading) ...[
              SkeletonBone(
                width: leadingSize,
                height: leadingSize,
                radius: leadingRadius,
              ),
              const SizedBox(width: 16),
            ],
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
                  if (showSubtitle) ...[
                    const SizedBox(height: 8),
                    SkeletonBone(
                      widthFactor: _detail[index % _detail.length],
                      height: 10,
                      radius: 4,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

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
            ? (availableHeight / itemHeight).floor().clamp(1, rows)
            : rows;
        final column = Column(
          mainAxisSize: MainAxisSize.min,
          children: [for (var i = 0; i < fit; i++) _row(i)],
        );
        Widget shimmer = SkeletonShimmer(
          decoration: decoration,
          liveRegion: liveRegion,
          child: column,
        );
        if (padding != EdgeInsets.zero) {
          shimmer = Padding(padding: padding, child: shimmer);
        }
        if (constraints.hasBoundedHeight &&
            availableHeight < fit * itemHeight) {
          return ClipRect(
            child: Align(
              alignment: Alignment.topCenter,
              child: UnconstrainedBox(
                clipBehavior: Clip.hardEdge,
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
  const MarkdownSkeleton({
    super.key,
    this.padding = defaultPadding,
    this.liveRegion = true,
  });

  static const defaultPadding = EdgeInsets.all(20);
  static const cardPadding = EdgeInsets.all(16);
  static const overviewReadmePadding = EdgeInsets.fromLTRB(16, 8, 16, 24);

  final EdgeInsetsGeometry padding;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    return _boundedSkeletonBody(
      SkeletonShimmer(
        liveRegion: liveRegion,
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

/// Skeleton for source files and blame: line-number gutter plus uneven code
/// lines in [TextDirection.ltr], matching [CodeTextView].
class CodeSkeleton extends StatelessWidget implements Skeleton {
  const CodeSkeleton({
    super.key,
    this.padding = CodeTextView.padding,
    this.lines = 12,
    this.liveRegion = true,
  });

  static const defaultPadding = CodeTextView.padding;
  static const editorPadding = EdgeInsets.fromLTRB(20, 8, 20, 32);
  static const blamePadding = EdgeInsets.fromLTRB(12, 8, 12, 8);
  static const gutterWidth = CodeTextView.gutterWidth;
  static const gutterGap = CodeTextView.gutterGap;
  static const linePitch = CodeTextView.linePitch;

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
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final resolved = padding.resolve(TextDirection.ltr);
    return _boundedSkeletonBody(
      SkeletonShimmer(
        liveRegion: liveRegion,
        sweepDirection: TextDirection.ltr,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Padding(
            padding: EdgeInsets.only(
              top: resolved.top,
              bottom: resolved.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < lines; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      left: resolved.left,
                      right: resolved.right,
                      top: 1,
                      bottom: 1,
                    ),
                    child: SizedBox(
                      height: linePitch - 2,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(
                            width: gutterWidth,
                            height: 24,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: SkeletonBone(
                                width: 24,
                                height: 11,
                                radius: 4,
                              ),
                            ),
                          ),
                          const SizedBox(width: gutterGap),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Align(
                                alignment: Alignment.topLeft,
                                child: SkeletonBone(
                                  widthFactor:
                                      _lineFactors[i % _lineFactors.length],
                                  height: 14,
                                  radius: 4,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Skeleton for unified/review diffs and commit diffs: file header, hunk
/// header, and diff lines in [TextDirection.ltr].
class DiffSkeleton extends StatelessWidget implements Skeleton {
  const DiffSkeleton({
    super.key,
    this.padding = defaultPadding,
    this.liveRegion = true,
  });

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
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    return _boundedSkeletonBody(
      SkeletonShimmer(
        liveRegion: liveRegion,
        sweepDirection: TextDirection.ltr,
        child: Directionality(
          textDirection: TextDirection.ltr,
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
      ),
    );
  }
}

/// Skeleton for CI job logs: monospace-proportioned log lines in
/// [TextDirection.ltr] with no line-number gutter, matching `JobLogPage`.
class LogSkeleton extends StatelessWidget implements Skeleton {
  const LogSkeleton({
    super.key,
    this.padding = defaultPadding,
    this.lines = 12,
    this.liveRegion = true,
  });

  static const defaultPadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 8,
  );
  static const linePitch = 21.0;

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
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    return _boundedSkeletonBody(
      SkeletonShimmer(
        liveRegion: liveRegion,
        sweepDirection: TextDirection.ltr,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Padding(
            padding: padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < lines; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 9),
                    child: SkeletonBone(
                      widthFactor: _logLineFactors[i % _logLineFactors.length],
                      height: 12,
                      radius: 4,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Skeleton for issue and merge-request detail pages: header, 48 dp tab strip,
/// and summary tab body (description lines, reactions bar, metadata card).
class DetailSkeleton extends StatelessWidget implements Skeleton {
  const DetailSkeleton({
    super.key,
    this.headerPadding = defaultHeaderPadding,
    this.summaryPadding = defaultSummaryPadding,
  });

  static const defaultPadding = EdgeInsets.fromLTRB(16, 8, 16, 24);
  static const defaultHeaderPadding = EdgeInsets.fromLTRB(16, 8, 16, 12);
  static const defaultSummaryPadding = EdgeInsets.fromLTRB(16, 14, 16, 24);

  final EdgeInsetsGeometry headerPadding;
  final EdgeInsetsGeometry summaryPadding;

  @override
  Widget build(BuildContext context) {
    final dividerColor =
        Theme.of(context).dividerTheme.color ??
        Theme.of(context).colorScheme.outlineVariant;
    return _boundedSkeletonBody(
      SkeletonShimmer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: headerPadding,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SkeletonBone(widthFactor: 0.88, height: 22, radius: 6),
                  SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      SkeletonBone(width: 64, height: 24, radius: 999),
                      SkeletonBone(width: 84, height: 24, radius: 999),
                      SkeletonBone(width: 96, height: 24, radius: 999),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(
              height: 47,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Center(
                        child: SkeletonBone(width: 52, height: 14, radius: 4),
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: SkeletonBone(width: 52, height: 14, radius: 4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, thickness: 1, color: dividerColor),
            Padding(
              padding: summaryPadding,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SkeletonLines(
                    factors: [0.95, 0.88, 0.92, 0.66],
                    lineHeight: 13,
                    spacing: 10,
                  ),
                  SizedBox(height: 14),
                  Row(
                    children: [
                      SkeletonBone(width: 56, height: 28, radius: 999),
                      SizedBox(width: 8),
                      SkeletonBone(width: 48, height: 28, radius: 999),
                    ],
                  ),
                  SizedBox(height: 16),
                  SkeletonBone(height: 136, radius: 12),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Skeleton for Home hub sections (such as Starred Projects), matching
/// [SharedLayout.hubRowPadding] and monogram-plus-two-line layout.
class HomeSectionSkeleton extends StatelessWidget implements Skeleton {
  const HomeSectionSkeleton({
    super.key,
    this.rows = 3,
    this.padding = EdgeInsets.zero,
  });

  static const rowPadding = SharedLayout.hubRowPadding;
  static const _titleFactors = [0.58, 0.46, 0.64, 0.52];
  static const _subtitleFactors = [0.38, 0.30, 0.42, 0.34];

  final int rows;
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
              for (var i = 0; i < rows; i++)
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 56),
                  child: Padding(
                    padding: rowPadding,
                    child: Row(
                      children: [
                        const SkeletonBone(width: 32, height: 32, radius: 8),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SkeletonBone(
                                widthFactor:
                                    _titleFactors[i % _titleFactors.length],
                                height: 16,
                                radius: 4,
                              ),
                              const SizedBox(height: 11),
                              SkeletonBone(
                                widthFactor:
                                    _subtitleFactors[i %
                                        _subtitleFactors.length],
                                height: 13,
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
      ),
    );
  }
}

/// Skeleton for `PipelinePage`'s first load: status chips, 48 dp TabBar
/// placeholder, and grouped job rows at the exact vertical offset where the
/// jobs `RecordsFeed` will appear.
class PipelineSkeleton extends StatelessWidget implements Skeleton {
  const PipelineSkeleton({super.key, this.gutter = 16});

  final double gutter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dividerColor = theme.dividerTheme.color ?? scheme.outlineVariant;
    final cardDecoration = BoxDecoration(
      color: theme.cardTheme.color ?? scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: dividerColor),
    );
    return _boundedSkeletonBody(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SkeletonShimmer(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SkeletonBone(width: 72, height: 22, radius: 7),
                      SkeletonBone(width: 84, height: 22, radius: 7),
                      SkeletonBone(width: 88, height: 32, radius: 7),
                    ],
                  ),
                ),
                SizedBox(
                  height: 47,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Center(
                            child: SkeletonBone(
                              width: 48,
                              height: 14,
                              radius: 4,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Center(
                            child: SkeletonBone(
                              width: 56,
                              height: 14,
                              radius: 4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: dividerColor),
          const SizedBox(height: 8),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            child: SkeletonShimmer(
              decoration: cardDecoration,
              liveRegion: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 6; i++)
                    SizedBox(
                      height: RowsSkeleton.rowHeight,
                      child: Padding(
                        padding: RowsSkeleton.rowPadding,
                        child: Row(
                          children: [
                            const SkeletonBone(
                              width: 36,
                              height: 36,
                              radius: 8,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SkeletonBone(
                                    widthFactor:
                                        RowsSkeleton._title[i %
                                            RowsSkeleton._title.length],
                                    height: 14,
                                    radius: 4,
                                  ),
                                  const SizedBox(height: 8),
                                  SkeletonBone(
                                    widthFactor:
                                        RowsSkeleton._detail[i %
                                            RowsSkeleton._detail.length],
                                    height: 10,
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
          ),
        ],
      ),
    );
  }
}

/// Skeleton for `ComparePage`: 48 dp TabBar strip plus commit/file list tiles.
class CompareSkeleton extends StatelessWidget implements Skeleton {
  const CompareSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final dividerColor =
        Theme.of(context).dividerTheme.color ??
        Theme.of(context).colorScheme.outlineVariant;
    return _boundedSkeletonBody(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SkeletonShimmer(
            child: SizedBox(
              height: 47,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Expanded(
                      child: Center(
                        child: SkeletonBone(width: 64, height: 14, radius: 4),
                      ),
                    ),
                    Expanded(
                      child: Center(
                        child: SkeletonBone(width: 64, height: 14, radius: 4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Divider(height: 1, thickness: 1, color: dividerColor),
          SkeletonShimmer(
            liveRegion: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < 6; i++)
                  SizedBox(
                    height: RowsSkeleton.rowHeight,
                    child: Padding(
                      padding: RowsSkeleton.rowPadding,
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
                                  widthFactor:
                                      RowsSkeleton._title[i %
                                          RowsSkeleton._title.length],
                                  height: 14,
                                  radius: 4,
                                ),
                                const SizedBox(height: 8),
                                SkeletonBone(
                                  widthFactor:
                                      RowsSkeleton._detail[i %
                                          RowsSkeleton._detail.length],
                                  height: 10,
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
        ],
      ),
    );
  }
}

/// Skeleton for `ResourceEditor`: form-shaped field boxes plus a multiline text
/// area.
class EditorSkeleton extends StatelessWidget implements Skeleton {
  const EditorSkeleton({super.key, this.padding = defaultPadding});

  static const defaultPadding = EdgeInsets.fromLTRB(20, 8, 20, 32);

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
              SkeletonBone(width: 84, height: 12, radius: 4),
              SizedBox(height: 8),
              SkeletonBone(height: 48, radius: 10),
              SizedBox(height: 16),
              SkeletonBone(width: 96, height: 12, radius: 4),
              SizedBox(height: 8),
              SkeletonBone(height: 48, radius: 10),
              SizedBox(height: 16),
              SkeletonBone(width: 72, height: 12, radius: 4),
              SizedBox(height: 8),
              SkeletonBone(height: 168, radius: 10),
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton for `CommitDetailPage` when opened without an initial commit:
/// commit metadata card followed by the diff skeleton.
class CommitSkeleton extends StatelessWidget implements Skeleton {
  const CommitSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return _boundedSkeletonBody(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkeletonShimmer(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: const [
                  SkeletonBone(height: 92, radius: 12),
                ],
              ),
            ),
          ),
          const DiffSkeleton(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 24),
            liveRegion: false,
          ),
        ],
      ),
    );
  }
}

/// Skeleton for `_SnippetDetailPage`: snippet header (title, metadata chips,
/// content heading) plus code lines in one combined skeleton.
class SnippetDetailSkeleton extends StatelessWidget implements Skeleton {
  const SnippetDetailSkeleton({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 16, 16, 24),
  });

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final resolved = padding.resolve(
      Directionality.maybeOf(context) ?? TextDirection.ltr,
    );
    return _boundedSkeletonBody(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SkeletonShimmer(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                resolved.left,
                resolved.top,
                resolved.right,
                8,
              ),
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonBone(width: 220, height: 24, radius: 6),
                  SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      SkeletonBone(width: 72, height: 32, radius: 999),
                      SkeletonBone(width: 96, height: 32, radius: 999),
                      SkeletonBone(width: 88, height: 32, radius: 999),
                    ],
                  ),
                  SizedBox(height: 12),
                  SkeletonBone(width: 72, height: 16, radius: 4),
                ],
              ),
            ),
          ),
          CodeSkeleton(
            padding: EdgeInsets.fromLTRB(
              resolved.left,
              0,
              resolved.right,
              resolved.bottom,
            ),
            lines: 10,
            liveRegion: false,
          ),
        ],
      ),
    );
  }
}

/// Skeleton for `BoardsPage`: board selector, search field, column chips, and
/// one full-width column of cards.
class BoardColumnsSkeleton extends StatelessWidget implements Skeleton {
  const BoardColumnsSkeleton({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 12, 16, 16),
  });

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
              SkeletonBone(height: 48, radius: 10),
              SizedBox(height: 10),
              SkeletonBone(height: 48, radius: 10),
              SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  SkeletonBone(width: 84, height: 32, radius: 999),
                  SkeletonBone(width: 96, height: 32, radius: 999),
                  SkeletonBone(width: 76, height: 32, radius: 999),
                ],
              ),
              SizedBox(height: 12),
              SkeletonBone(height: 76, radius: 12),
              SizedBox(height: 10),
              SkeletonBone(height: 76, radius: 12),
              SizedBox(height: 10),
              SkeletonBone(height: 76, radius: 12),
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton for `PipelineGraphPage`: title, two text lines, stage chips, and a
/// vertical list of job rows.
class PipelineGraphSkeleton extends StatelessWidget implements Skeleton {
  const PipelineGraphSkeleton({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 24),
  });

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
              SkeletonBone(widthFactor: 0.48, height: 22, radius: 6),
              SizedBox(height: 8),
              SkeletonBone(widthFactor: 0.84, height: 14, radius: 4),
              SizedBox(height: 10),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: [
                  SkeletonBone(width: 72, height: 28, radius: 999),
                  SkeletonBone(width: 68, height: 28, radius: 999),
                  SkeletonBone(width: 80, height: 28, radius: 999),
                ],
              ),
              SizedBox(height: 10),
              SkeletonBone(widthFactor: 0.56, height: 14, radius: 4),
              SizedBox(height: 14),
              SkeletonBone(height: 84, radius: 12),
              SizedBox(height: 10),
              SkeletonBone(height: 84, radius: 12),
              SizedBox(height: 10),
              SkeletonBone(height: 84, radius: 12),
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton for `ProjectAnalyticsPage` contributors tab: two text lines plus
/// contributor card rows.
class ContributorsSkeleton extends StatelessWidget implements Skeleton {
  const ContributorsSkeleton({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 24),
  });

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
              SkeletonBone(widthFactor: 0.78, height: 14, radius: 4),
              SizedBox(height: 8),
              SkeletonBone(widthFactor: 0.56, height: 14, radius: 4),
              SizedBox(height: 12),
              SkeletonBone(height: 68, radius: 12),
              SizedBox(height: 8),
              SkeletonBone(height: 68, radius: 12),
              SizedBox(height: 8),
              SkeletonBone(height: 68, radius: 12),
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton for `ProjectAnalyticsPage`: chart-shaped summary and bar boxes.
class ChartSkeleton extends StatelessWidget implements Skeleton {
  const ChartSkeleton({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 24),
  });

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
              SkeletonBone(height: 68, radius: 12),
              SizedBox(height: 12),
              SkeletonBone(height: 140, radius: 12),
              SizedBox(height: 12),
              SkeletonBone(height: 84, radius: 12),
            ],
          ),
        ),
      ),
    );
  }
}
