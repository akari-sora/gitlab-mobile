import 'package:flutter/material.dart';
import '../core/failure.dart';
import '../l10n/l10n.dart';
import 'workspace_ui.dart';

/// Says that a list shows rows loaded earlier: while they are refreshed in the
/// background, or when that refresh failed. Fresh rows get no strip at all.
class CacheFreshnessBar extends StatelessWidget {
  const CacheFreshnessBar({super.key, required this.fetchedAt, this.refreshing = false,
    this.failure, this.retryAt, this.onRetry});

  final DateTime fetchedAt;
  final bool refreshing;
  final FailureKind? failure;
  final DateTime? retryAt;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final updated = l10n.cacheLastUpdated(relativeTime(fetchedAt));
    final failure = this.failure;
    final (IconData? icon, String? title) = switch (failure) {
      null => (refreshing ? null : Icons.history, refreshing ? l10n.cacheRefreshing : null),
      FailureKind.network => (Icons.cloud_off_outlined, l10n.cannotConnect),
      FailureKind.rateLimited => (Icons.hourglass_empty, l10n.cacheRateLimited),
      _ => (Icons.sync_problem, l10n.cacheRefreshFailed),
    };
    final wait = retryAt?.difference(DateTime.now());
    // Only a reset time GitLab actually gave is worth stating.
    final resumes = failure == FailureKind.rateLimited && wait != null && !wait.isNegative
        ? l10n.cacheResumesInMinutes((wait.inSeconds + 59) ~/ 60) : null;
    final detail = [if (title != null) updated, ?resumes].join(' · ');
    final leading = icon == null
        ? SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary))
        : Icon(icon, size: 18, color: failure == null ? scheme.onSurfaceVariant : scheme.error);
    final status = MergeSemantics(child: Row(children: [
      leading,
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(title ?? updated, style: text.labelLarge),
        if (detail.isNotEmpty) Text(detail, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
      ])),
    ]));
    final button = failure != null && onRetry != null
        ? TextButton(onPressed: onRetry, child: Text(l10n.refreshAction)) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 8),
          child: button == null
              ? Padding(padding: const EdgeInsetsDirectional.only(end: 8), child: status)
              : LayoutBuilder(builder: (context, constraints) {
                  // A wide label (large text, long words) moves under the status
                  // instead of squeezing it into a narrow column.
                  final label = TextPainter(
                    text: TextSpan(text: l10n.refreshAction, style: text.labelLarge),
                    textScaler: MediaQuery.textScalerOf(context),
                    textDirection: Directionality.of(context),
                    maxLines: 1,
                  )..layout();
                  final width = label.width + 24;
                  label.dispose();
                  if (width <= constraints.maxWidth * 0.4) {
                    return Row(children: [Expanded(child: status), button]);
                  }
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Padding(padding: const EdgeInsetsDirectional.only(end: 8), child: status),
                    Align(alignment: AlignmentDirectional.centerEnd, child: button),
                  ]);
                }),
        ),
      ),
    );
  }
}
