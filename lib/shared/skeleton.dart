import 'dart:async';

import 'package:flutter/material.dart';

import 'motion.dart';

import '../l10n/l10n.dart';
/// Placeholder rows shown while a list loads for the first time, in the shape
/// of the rows that will replace them, so the screen keeps its layout instead
/// of showing a lone spinner. They pulse gently, hold still when the platform
/// asks for less motion, and read out as one 「正在載入」 live region.
///
/// In a bounded height (an `Expanded` body) it shows only the rows that fit;
/// in a scroll view it shows [rows].
class RowsSkeleton extends StatefulWidget {
  const RowsSkeleton({super.key, this.rows = 8, this.grouped = false});
  final int rows;

  /// Draws the rows on one rounded surface, like a grouped `RecordsFeed`.
  final bool grouped;

  static const rowHeight = 64.0;

  @override
  State<RowsSkeleton> createState() => _RowsSkeletonState();
}

class _RowsSkeletonState extends State<RowsSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final Animation<double> _opacity = Tween<double>(
    begin: 1,
    end: .45,
  ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));

  // Varied bar lengths read as text rather than as a grid of equal blocks.
  static const _title = [.72, .54, .66, .46, .7, .58, .5, .64];
  static const _detail = [.4, .3, .36, .24, .44, .32, .28, .38];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (reduceMotion(context)) {
      _pulse
        ..stop()
        ..value = 0;
    } else if (!_pulse.isAnimating) {
      unawaited(_pulse.repeat(reverse: true));
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Widget _row(int index, Color bar) {
    Widget block(double height, double radius) => DecoratedBox(
      decoration: BoxDecoration(
        color: bar,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: SizedBox(height: height),
    );
    return SizedBox(
      height: RowsSkeleton.rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            SizedBox.square(dimension: 36, child: block(36, 8)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FractionallySizedBox(
                    widthFactor: _title[index % _title.length],
                    child: block(14, 4),
                  ),
                  const SizedBox(height: 8),
                  FractionallySizedBox(
                    widthFactor: _detail[index % _detail.length],
                    child: block(10, 4),
                  ),
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
    return Semantics(
      label: l10n.loading2,
      liveRegion: true,
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final fit = constraints.hasBoundedHeight
                ? (constraints.maxHeight / RowsSkeleton.rowHeight)
                      .floor()
                      .clamp(1, widget.rows)
                : widget.rows;
            Widget rows = Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < fit; i++)
                  _row(i, scheme.surfaceContainerHighest),
              ],
            );
            if (widget.grouped) {
              rows = DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.cardTheme.color ?? scheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.dividerTheme.color ?? scheme.outlineVariant,
                  ),
                ),
                child: rows,
              );
            }
            return Align(
              alignment: Alignment.topCenter,
              child: FadeTransition(opacity: _opacity, child: rows),
            );
          },
        ),
      ),
    );
  }
}
