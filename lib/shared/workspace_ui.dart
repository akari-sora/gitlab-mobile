import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/failure.dart';
import '../core/gitlab_api.dart';
import '../core/models.dart';
import '../core/providers.dart';
import 'resume_target.dart';
import 'theme.dart';

export 'resume_target.dart';

/// Ends the active session so the user can pick another account. Does not rotate accounts.
VoidCallback endSessionFrom(BuildContext context, [ResumeTarget? resumeTarget]) => () {
  try {
    final session = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(sessionProvider);
    if (resumeTarget != null) {
      session.setPendingResumeTarget(resumeTarget);
    }
    unawaited(session.endSession(switching: resumeTarget != null));
  } catch (_) {}
};

String valueText(Json value, String key, [String fallback = '']) =>
    value[key] is String ? value[key] as String : fallback;
int valueInt(Json value, String key) =>
    value[key] is int ? value[key] as int : 0;
bool valueBool(Json value, String key, [bool fallback = false]) =>
    value[key] is bool ? value[key] as bool : fallback;
Json valueObject(Json value, String key) => value[key] is Map<String, dynamic>
    ? value[key] as Json
    : <String, dynamic>{};
List<Json> valueObjects(Json value, String key) =>
    value[key] is List ? (value[key] as List).whereType<Json>().toList() : [];
String shortSha(String sha) => sha.length > 8 ? sha.substring(0, 8) : sha;

/// A glyph for a repository file by its name, so trees scan by kind.
IconData fileIconFor(String name) {
  final lower = name.toLowerCase();
  final dot = lower.lastIndexOf('.');
  final ext = dot < 0 ? '' : lower.substring(dot + 1);
  if (lower == 'dockerfile' || lower == 'makefile' || lower.startsWith('.git')) return Icons.settings_outlined;
  if (lower.endsWith('.lock') || lower == 'license' || lower.startsWith('license.')) return Icons.gavel_outlined;
  return switch (ext) {
    'md' || 'markdown' || 'mdown' || 'txt' || 'rst' || 'adoc' => Icons.article_outlined,
    'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'svg' || 'ico' || 'bmp' => Icons.image_outlined,
    'pdf' => Icons.picture_as_pdf_outlined,
    'json' || 'yaml' || 'yml' || 'toml' || 'xml' || 'ini' || 'cfg' || 'conf' || 'properties' || 'gradle' || 'kts' =>
      Icons.data_object,
    'sh' || 'bash' || 'zsh' || 'fish' || 'ps1' || 'bat' => Icons.terminal,
    'zip' || 'tar' || 'gz' || 'tgz' || 'xz' || '7z' || 'jar' || 'apk' || 'aab' => Icons.folder_zip_outlined,
    'dart' || 'kt' || 'java' || 'swift' || 'js' || 'jsx' || 'ts' || 'tsx' || 'py' || 'go' || 'rs' || 'rb' || 'php' ||
    'c' || 'h' || 'cc' || 'cpp' || 'hpp' || 'cs' || 'm' || 'mm' || 'scala' || 'lua' || 'sql' || 'vue' || 'svelte' ||
    'html' || 'css' || 'scss' => Icons.code,
    _ => Icons.description_outlined,
  };
}
/// Keeps a scrolling body clear of the gesture bar and of side insets from
/// landscape navigation or a display cutout. The app bar already owns the top.
Widget gestureSafe(Widget child) => SafeArea(top: false, child: child);

/// A pop that finishes after [PopScope.onPopInvokedWithResult] returns, such as
/// an editor flushing a draft or waiting for confirmation. Callers that only
/// see the route await [pending] instead of assuming the veto is final.
final class RouteExit {
  static final Map<Route<dynamic>, Future<void>> _pending = {};

  static void track(Route<dynamic> route, Future<void> action) {
    late final Future<void> result;
    result = action.whenComplete(() {
      if (identical(_pending[route], result)) _pending.remove(route);
    });
    _pending[route] = result;
  }

  static Future<void>? pending(Route<dynamic> route) => _pending[route];
}

String relativeDate(String value) {
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return '';
  final diff = DateTime.now().difference(parsed);
  if (diff.inMinutes < 1) return '剛剛';
  if (diff.inHours < 1) return '${diff.inMinutes} 分鐘前';
  if (diff.inDays < 1) return '${diff.inHours} 小時前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  final date = parsed.toLocal();
  return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
}

(String, IconData) statusStyle(String status) => switch (status) {
  'opened' => ('開啟中', Icons.adjust),
  'active' => ('進行中', Icons.flag_outlined),
  'closed' => ('已關閉', Icons.check_circle_outline),
  'merged' => ('已合併', Icons.merge),
  'success' || 'passed' => ('成功', Icons.check_circle_outline),
  'failed' => ('失敗', Icons.error_outline),
  'error' => ('錯誤', Icons.error_outline),
  'running' => ('執行中', Icons.motion_photos_on_outlined),
  'pending' ||
  'created' ||
  'waiting_for_resource' ||
  'preparing' => ('等待中', Icons.schedule),
  'canceled' => ('已取消', Icons.cancel_outlined),
  'skipped' => ('已略過', Icons.skip_next_outlined),
  'manual' => ('等待手動啟動', Icons.play_circle_outline),
  'private' => ('私有', Icons.lock_outline),
  'internal' => ('內部', Icons.business_outlined),
  'public' => ('公開', Icons.public),
  'marked_for_deletion' => ('待刪除', Icons.delete_outline),
  _ => (status.isEmpty ? '狀態未知' : status, Icons.info_outline),
};

String statusLabel(String status) => statusStyle(status).$1;

String projectCardLabel(Project project, String lastActivity) {
  final when = relativeDate(lastActivity);
  final description = project.description?.trim() ?? '';
  return [
    project.name,
    project.path,
    if (description.isNotEmpty) description,
    statusLabel(project.visibility ?? ''),
    if (project.archived == true) '已封存',
    if (when.isNotEmpty) when,
    if (project.markedForDeletionOn != null) '待刪除',
  ].join(' · ');
}

String pipelineCardLabel(Json value) {
  final ref = valueText(value, 'ref');
  final sha = shortSha(valueText(value, 'sha'));
  final when = relativeDate(valueText(value, 'updated_at'));
  return [
    valueText(value, 'name', 'Pipeline #${valueInt(value, 'id')}'),
    statusLabel(valueText(value, 'status')),
    if (ref.isNotEmpty) ref,
    if (sha.isNotEmpty) sha,
    if (when.isNotEmpty) when,
  ].join(' · ');
}

String jobCardLabel(Json value) {
  final stage = valueText(value, 'stage');
  return [
    valueText(value, 'name'),
    statusLabel(valueText(value, 'status')),
    if (stage.isNotEmpty) stage,
  ].join(' · ');
}

/// One semantics button. Descendants stay visible but are not separate nodes.
class SemanticButton extends StatelessWidget {
  const SemanticButton({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
  });
  final String label;
  final VoidCallback onTap;
  final Widget child;
  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    label: label,
    onTap: onTap,
    excludeSemantics: true,
    child: child,
  );
}

class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key});
  final String status;
  @override
  Widget build(BuildContext context) {
    final (label, icon) = statusStyle(status);
    final scheme = Theme.of(context).colorScheme;
    final workshop = WorkshopColors.of(context);
    // Tint reinforces the icon + label pair; it is never the only signal.
    final (background, foreground) = switch (status) {
      'success' || 'passed' => (workshop.successContainer, workshop.onSuccessContainer),
      'running' => (workshop.runningContainer, workshop.onRunningContainer),
      'pending' || 'created' || 'waiting_for_resource' || 'preparing' || 'manual' || 'scheduled' =>
        (workshop.pendingContainer, workshop.onPendingContainer),
      'failed' || 'error' => (scheme.errorContainer, scheme.onErrorContainer),
      'opened' || 'merged' || 'active' => (scheme.primaryContainer, scheme.onPrimaryContainer),
      _ => (workshop.neutralContainer, workshop.onNeutralContainer),
    };
    return MergeSemantics(child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(7)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(child: Icon(icon, size: 13, color: foreground)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: foreground)),
          ),
        ],
      ),
    ));
  }
}

/// `#RRGGBB` (GitLab label and avatar colours) to a [Color]; null if malformed.
Color? parseHexColor(String value) {
  final hex = value.trim().replaceFirst('#', '');
  if (hex.length != 6) return null;
  final parsed = int.tryParse(hex, radix: 16);
  return parsed == null ? null : Color(0xFF000000 | parsed);
}

/// Label names with their colours, from either plain names or the objects
/// returned with `with_labels_details=true`.
List<({String name, Color? color, Color? textColor})> labelDetails(Json value) {
  final raw = value['labels'];
  final out = <({String name, Color? color, Color? textColor})>[];
  if (raw is List) {
    for (final item in raw) {
      if (item is String && item.trim().isNotEmpty) {
        out.add((name: item.trim(), color: null, textColor: null));
      } else if (item is Map && item['name'] is String && (item['name'] as String).trim().isNotEmpty) {
        out.add((
          name: (item['name'] as String).trim(),
          color: item['color'] is String ? parseHexColor(item['color'] as String) : null,
          textColor: item['text_color'] is String ? parseHexColor(item['text_color'] as String) : null,
        ));
      }
    }
  }
  return out;
}

double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (math.max(la, lb) + .05) / (math.min(la, lb) + .05);
}

/// Text colour for small type on [fill]: [preferred] when it reaches the WCAG
/// 4.5:1 ratio, otherwise whichever of white or near-black contrasts more.
Color readableInk(Color fill, {Color? preferred}) {
  if (preferred != null && contrastRatio(preferred, fill) >= 4.5) return preferred;
  const dark = Color(0xFF1F1F1F);
  return contrastRatio(Colors.white, fill) >= contrastRatio(dark, fill) ? Colors.white : dark;
}

/// A GitLab label in its own colour. Scoped labels (`scope::value`) render as
/// two joined segments, the way GitLab shows them.
class LabelPill extends StatelessWidget {
  const LabelPill(this.name, {super.key, this.color, this.textColor});
  final String name;
  final Color? color, textColor;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = Theme.of(context).textTheme.labelSmall!;
    final fill = color ?? scheme.surfaceContainerHighest;
    final ink = color == null ? scheme.onSurfaceVariant : readableInk(fill, preferred: textColor);
    final split = name.lastIndexOf('::');
    const radius = Radius.circular(10);
    if (split > 0 && split < name.length - 2) {
      final scope = name.substring(0, split), value = name.substring(split + 2);
      return Semantics(label: name, excludeSemantics: true, child: Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Container(
          padding: const EdgeInsets.fromLTRB(8, 2, 6, 2),
          decoration: BoxDecoration(color: fill, borderRadius: const BorderRadius.horizontal(left: radius),
            border: Border.all(color: fill)),
          child: Text(scope, maxLines: 1, overflow: TextOverflow.ellipsis, style: base.copyWith(color: ink)),
        )),
        Flexible(child: Container(
          padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
          decoration: BoxDecoration(color: scheme.surface, borderRadius: const BorderRadius.horizontal(right: radius),
            border: Border.all(color: fill)),
          child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: base.copyWith(color: scheme.onSurface)),
        )),
      ]));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(10)),
      child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: base.copyWith(color: ink)),
    );
  }
}

/// Up to [max] overlapping monograms for assignees or reviewers.
class PeopleStack extends StatelessWidget {
  const PeopleStack(this.people, {super.key, this.size = 22, this.max = 3});
  final List<Json> people;
  final double size;
  final int max;
  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();
    final shown = people.take(max).toList();
    final names = people.map((p) => '@${valueText(p, 'username')}').join('、');
    final surface = Theme.of(context).colorScheme.surface;
    return Semantics(label: names, excludeSemantics: true, child: Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: size,
        width: size + (shown.length - 1) * size * .62,
        child: Stack(children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(left: i * size * .62, child: Container(
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: surface, width: 1.5)),
              child: ClipOval(child: Monogram(valueText(shown[i], 'name', valueText(shown[i], 'username')), size: size - 3)),
            )),
        ]),
      ),
      if (people.length > max) Padding(padding: const EdgeInsets.only(left: 3),
        child: Text('+${people.length - max}', style: Theme.of(context).textTheme.labelSmall)),
    ]));
  }
}

/// Horizontal inset for feeds and their header rows: 16 dp on phones, a
/// centred 640 dp column on wider windows so lists and their search rows
/// share one edge. The width is the viewport (`MediaQuery.sizeOf`), not the
/// parent constraints, so a nested header and the list agree.
double feedGutter(BuildContext context, [double? containerWidth]) {
  final width = containerWidth ?? MediaQuery.sizeOf(context).width;
  return width > 672 ? (width - 640) / 2 : 16.0;
}

/// Appearance picker: a segmented control when there is room, wrapping chips
/// on narrow widths or large text so labels never ellipsize.
class AppearancePicker extends StatelessWidget {
  const AppearancePicker({super.key, required this.mode, required this.onChanged});
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;
  static const _labels = {ThemeMode.system: '跟隨系統', ThemeMode.light: '淺色', ThemeMode.dark: '深色'};
  static const _icons = {ThemeMode.system: Icons.brightness_auto_outlined, ThemeMode.light: Icons.light_mode_outlined, ThemeMode.dark: Icons.dark_mode_outlined};
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    if (constraints.maxWidth >= 400 * scale) {
      return SizedBox(width: double.infinity, child: SegmentedButton<ThemeMode>(
        showSelectedIcon: false,
        segments: [for (final entry in _labels.entries)
          ButtonSegment(value: entry.key, icon: Icon(_icons[entry.key]), label: Text(entry.value))],
        selected: {mode}, onSelectionChanged: (values) => onChanged(values.first)));
    }
    return Wrap(spacing: 8, runSpacing: 8, children: [for (final entry in _labels.entries)
      ChoiceChip(avatar: Icon(_icons[entry.key], size: 18), label: Text(entry.value), showCheckmark: false,
        selected: mode == entry.key, onSelected: (_) => onChanged(entry.key))]);
  });
}

/// Small icon + text pair for card meta rows (time, ref, SHA, counts).
class MetaChip extends StatelessWidget {
  const MetaChip(this.text, {super.key, this.icon, this.mono = false});
  final String text;
  final IconData? icon;
  final bool mono;
  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    final style = mono
        ? codeTextStyle(context, fontSize: 12, color: color)
        : Theme.of(context).textTheme.bodySmall?.copyWith(color: color);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
      Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
    ]);
  }
}

/// One card grammar for projects, issues, merge requests, pipelines and jobs:
/// leading mark, title, optional subtitle, meta row, optional chevron.
class EntityCard extends StatelessWidget {
  const EntityCard({
    super.key, required this.title, this.leading, this.subtitle, this.body,
    this.meta = const [], this.trailing, this.chevron = true, this.onTap,
    this.muted = false, this.titleMaxLines = 2, this.selected = false,
  });
  final Widget title;
  final Widget? leading, subtitle, body, trailing;
  final List<Widget> meta;
  final bool chevron, muted, selected;
  final int titleMaxLines;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final cardColor = selected ? scheme.secondaryContainer : null;
    final cardShape = selected
        ? RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: scheme.primary, width: 2),
          )
        : null;
    final details = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      DefaultTextStyle.merge(
        style: Theme.of(context).textTheme.titleMedium!.copyWith(
          fontSize: 15, height: 1.35, color: muted ? scheme.onSurfaceVariant : scheme.onSurface),
        maxLines: titleMaxLines, overflow: TextOverflow.ellipsis, child: title),
      if (subtitle != null) ...[
        const SizedBox(height: 2),
        DefaultTextStyle.merge(
          style: Theme.of(context).textTheme.bodySmall!.copyWith(color: scheme.onSurfaceVariant),
          maxLines: 1, overflow: TextOverflow.ellipsis, child: subtitle!),
      ],
      if (body != null) ...[const SizedBox(height: 6), body!],
      if (meta.isNotEmpty) ...[
        const SizedBox(height: 7),
        Wrap(spacing: 10, runSpacing: 5, crossAxisAlignment: WrapCrossAlignment.center, children: meta),
      ],
    ]);
    final overlay = WidgetStatePropertyAll(scheme.onSurface.withValues(alpha: .06));
    if (trailing == null) {
      // Whole card is one merged node: title, status and meta are read together
      // with the tap action instead of as separate stops.
      final row = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(child: details),
        if (chevron && onTap != null) ...[
          const SizedBox(width: 4),
          Padding(padding: const EdgeInsets.only(top: 1),
            child: Icon(selected ? Icons.check_circle : Icons.chevron_right, size: 20,
              color: selected ? scheme.primary : scheme.onSurfaceVariant)),
        ],
      ]);
      final content = Padding(padding: const EdgeInsets.fromLTRB(14, 12, 10, 12), child: row);
      final card = Card(clipBehavior: Clip.antiAlias, color: cardColor, shape: cardShape,
        child: onTap == null ? content : InkWell(onTap: onTap, overlayColor: overlay, child: content));
      return MergeSemantics(child: Semantics(button: onTap != null, child: card));
    }
    // A trailing control (todo completion, metadata menu) keeps its own node and
    // action; the tappable content is one merged, named button beside it.
    final content = Padding(padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (leading != null) ...[leading!, const SizedBox(width: 12)],
        Expanded(child: details),
      ]));
    final tappable = onTap == null ? content : InkWell(onTap: onTap, overlayColor: overlay, child: content);
    return Card(clipBehavior: Clip.antiAlias, color: cardColor, shape: cardShape,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: MergeSemantics(child: Semantics(button: onTap != null, child: tappable))),
        Padding(padding: const EdgeInsets.only(top: 4, right: 4), child: trailing!),
      ]));
  }
}

class Monogram extends StatelessWidget {
  const Monogram(this.name, {super.key, this.size = 42});
  final String name;
  final double size;
  /// Eight tonal hues keyed by the name so lists stop looking uniform while
  /// the same name always gets the same colour.
  static const _hues = [222.0, 258.0, 300.0, 340.0, 20.0, 158.0, 190.0, 62.0];
  static (Color, Color) colorsFor(String name, Brightness brightness) {
    var hash = 0;
    for (final unit in name.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    final hue = _hues[hash % _hues.length];
    final dark = brightness == Brightness.dark;
    final container = HSLColor.fromAHSL(1, hue, dark ? .38 : .52, dark ? .24 : .90).toColor();
    final foreground = HSLColor.fromAHSL(1, hue, .55, dark ? .82 : .27).toColor();
    return (container, foreground);
  }
  @override
  Widget build(BuildContext context) {
    final (container, foreground) = colorsFor(name, Theme.of(context).brightness);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: container,
        borderRadius: BorderRadius.circular(size * .28),
      ),
      child: Text(
        name.isEmpty ? 'G' : name.characters.first.toUpperCase(),
        style: TextStyle(
          fontSize: size * .4,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState(
    this.title, {
    super.key,
    this.detail,
    this.icon = Icons.inbox_outlined,
    this.action,
  });
  final String title;
  final String? detail;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64, height: 64, alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest, shape: BoxShape.circle),
          child: Icon(icon, size: 30, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (detail != null) ...[
          const SizedBox(height: 6),
          Text(
            detail!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (action != null) ...[const SizedBox(height: 12), action!],
      ],
    ),
  );
}

class FailureNotice extends StatelessWidget {
  const FailureNotice(
    this.error, {
    super.key,
    this.account,
    this.resourceLabel,
    this.onRetry,
    this.onSwitchAccount,
    this.resumeTarget,
  });
  final ApiFailure error;
  final Account? account;
  final String? resourceLabel;
  final VoidCallback? onRetry;
  final VoidCallback? onSwitchAccount;
  final ResumeTarget? resumeTarget;
  @override
  Widget build(BuildContext context) {
    Account? effectiveAccount = account;
    VoidCallback? effectiveSwitch = onSwitchAccount;
    if (effectiveAccount == null || effectiveSwitch == null) {
      try {
        final session = ProviderScope.containerOf(
          context,
          listen: false,
        ).read(sessionProvider);
        effectiveAccount ??= session.active;
        effectiveSwitch ??= () {
          if (resumeTarget != null) {
            session.setPendingResumeTarget(resumeTarget);
          }
          unawaited(session.endSession(switching: resumeTarget != null));
        };
      } catch (_) {}
    } else if (resumeTarget != null) {
      final original = effectiveSwitch;
      effectiveSwitch = () {
        try {
          final session = ProviderScope.containerOf(
            context,
            listen: false,
          ).read(sessionProvider);
          session.setPendingResumeTarget(resumeTarget);
        } catch (_) {}
        original();
      };
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 20,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      error.title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(error.detail),
              if (effectiveAccount != null) ...[
                const SizedBox(height: 12),
                Text('實例：${effectiveAccount.instance.key}'),
                Text('App 帳號：@${effectiveAccount.user.username}'),
              ],
              if (resourceLabel != null && resourceLabel!.isNotEmpty)
                Text('目標：$resourceLabel'),
              Wrap(
                spacing: 8,
                children: [
                  if (onRetry != null &&
                      error.kind != FailureKind.writeUncertain)
                    TextButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重新整理'),
                    ),
                  if (effectiveSwitch != null)
                    TextButton(
                      onPressed: effectiveSwitch,
                      child: const Text('切換帳號'),
                    ),
                ],
              ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: const Text('診斷資訊', style: TextStyle(fontSize: 12)),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      '${error.kind.name}${error.status == null ? '' : ' · HTTP ${error.status}'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ListSkeleton extends StatelessWidget {
  const ListSkeleton({super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    label: '正在載入',
    liveRegion: true,
    child: const Padding(
      padding: EdgeInsets.all(32),
      child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
    ),
  );
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String detail, {
  String? requiredText,
}) async {
  final input = TextEditingController();
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(detail),
              if (requiredText != null) ...[
                const SizedBox(height: 16),
                Text('輸入「$requiredText」確認'),
                const SizedBox(height: 8),
                TextField(
                  controller: input,
                  autocorrect: false,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(labelText: '確認名稱'),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: requiredText != null && input.text != requiredText
                ? null
                : () => Navigator.pop(context, true),
            child: const Text('確認'),
          ),
        ],
      ),
    ),
  );
  // The route may still be animating out; do not dispose its controller early.
  Future<void>.delayed(const Duration(milliseconds: 400), input.dispose);
  return answer ?? false;
}

void showFailure(BuildContext context, Object error) {
  final failure = safeFailure(error);
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text('${failure.title}。${failure.detail}')));
}
