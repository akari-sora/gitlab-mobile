import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/failure.dart';
import '../core/gitlab_api.dart';
import '../core/models.dart';
import '../core/read_cache_disk_contract.dart';
import '../core/providers.dart';
import 'resume_target.dart';
import 'skeleton.dart';
import 'theme.dart';

import '../l10n/l10n.dart';
export 'resume_target.dart';

/// Why the signed-in session is about to end (D1, §6.7): every way out of an
/// account deletes its read cache and offline projects.
enum LeaveKind { switchAccount, signOut, remove }

final class LeaveIntent {
  const LeaveIntent(this.kind, {this.target});
  final LeaveKind kind;

  /// The account switched to, when there is one.
  final Account? target;
}

/// Runs every way out of the session through the shell's confirmations: the
/// offline-projects loss first, then the AI guard (§6.7). Placed above the
/// navigator, so sheets and pushed pages use it too.
class SessionLeaveScope extends InheritedWidget {
  const SessionLeaveScope({super.key, required this.leave, required super.child});

  /// Confirms [intent] and then runs `action`; returns without running it
  /// when the user cancels.
  final Future<void> Function(LeaveIntent intent, Future<void> Function() action) leave;

  /// Runs [action] through the nearest scope, or directly without one.
  static Future<void> run(
    BuildContext context,
    LeaveIntent intent,
    Future<void> Function() action,
  ) {
    final scope = context.getInheritedWidgetOfExactType<SessionLeaveScope>();
    return scope == null ? action() : scope.leave(intent, action);
  }

  @override
  bool updateShouldNotify(SessionLeaveScope oldWidget) => leave != oldWidget.leave;
}

/// Ends the active session so the user can pick another account. Does not rotate accounts.
VoidCallback endSessionFrom(BuildContext context, [ResumeTarget? resumeTarget]) => () {
  try {
    final session = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(sessionProvider);
    unawaited(SessionLeaveScope.run(context, const LeaveIntent(LeaveKind.signOut), () {
      if (resumeTarget != null) {
        session.setPendingResumeTarget(resumeTarget);
      }
      return session.endSession(switching: resumeTarget != null);
    }));
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
  return relativeTime(parsed);
}

String relativeTime(DateTime parsed) {
  final diff = DateTime.now().difference(parsed);
  if (diff.inMinutes < 1) return l10n.justNow;
  if (diff.inHours < 1) return l10n.minutesAgo(diff.inMinutes);
  if (diff.inDays < 1) return l10n.hoursAgo(diff.inHours);
  if (diff.inDays < 7) return l10n.daysAgo(diff.inDays);
  final date = parsed.toLocal();
  return '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')}';
}

(String, IconData) statusStyle(String status) => switch (status) {
  'opened' => (l10n.statusOpen, Icons.adjust),
  'active' => (l10n.active, Icons.flag_outlined),
  'closed' => (l10n.statusClosed, Icons.check_circle_outline),
  'merged' => (l10n.merged, Icons.merge),
  'success' || 'passed' => (l10n.statusPassed, Icons.check_circle_outline),
  'failed' => (l10n.statusFailed, Icons.error_outline),
  'error' => (l10n.statusError, Icons.error_outline),
  'running' => (l10n.statusRunning, Icons.motion_photos_on_outlined),
  'pending' ||
  'created' ||
  'waiting_for_resource' ||
  'preparing' => (l10n.pending, Icons.schedule),
  'canceled' => (l10n.canceled, Icons.cancel_outlined),
  'skipped' => (l10n.skipped, Icons.skip_next_outlined),
  'manual' => (l10n.waitingForManualStart, Icons.play_circle_outline),
  'private' => (l10n.visibilityPrivate, Icons.lock_outline),
  'internal' => (l10n.visibilityInternal, Icons.business_outlined),
  'public' => (l10n.visibilityPublic, Icons.public),
  'marked_for_deletion' => (l10n.pendingDeletion, Icons.delete_outline),
  _ => (status.isEmpty ? l10n.unknownStatus : status, Icons.info_outline),
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
    if (project.archived == true) l10n.archived,
    if (when.isNotEmpty) when,
    if (project.markedForDeletionOn != null) l10n.pendingDeletion,
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
  final user = valueText(valueObject(value, 'user'), 'username');
  return [
    valueText(value, 'name'),
    statusLabel(valueText(value, 'status')),
    if (stage.isNotEmpty) stage,
    if (user.isNotEmpty) '@$user',
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
          padding: const EdgeInsetsDirectional.fromSTEB(8, 2, 6, 2),
          decoration: BoxDecoration(color: fill, borderRadius: const BorderRadiusDirectional.horizontal(start: radius),
            border: Border.all(color: fill)),
          child: Text(isolated(scope), maxLines: 1, overflow: TextOverflow.ellipsis, style: base.copyWith(color: ink)),
        )),
        Flexible(child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(6, 2, 8, 2),
          decoration: BoxDecoration(color: scheme.surface, borderRadius: const BorderRadiusDirectional.horizontal(end: radius),
            border: Border.all(color: fill)),
          child: Text(isolated(value), maxLines: 1, overflow: TextOverflow.ellipsis, style: base.copyWith(color: scheme.onSurface)),
        )),
      ]));
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(10)),
      child: Text(isolated(name), maxLines: 1, overflow: TextOverflow.ellipsis, style: base.copyWith(color: ink)),
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
    final names = people.map((p) => '@${valueText(p, 'username')}').join(l10n.listSeparator);
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
/// share one edge. The width is the viewport (`MediaQuery.widthOf`), not the
/// parent constraints, so a nested header and the list agree.
double feedGutter(BuildContext context, [double? containerWidth]) {
  final width = containerWidth ?? MediaQuery.widthOf(context);
  return width > 672 ? (width - 640) / 2 : 16.0;
}

/// Appearance picker: a segmented control when there is room, wrapping chips
/// on narrow widths or large text so labels never ellipsize.
class AppearancePicker extends StatelessWidget {
  const AppearancePicker({super.key, required this.mode, required this.onChanged});
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;
  static Map<ThemeMode, String> get _labels => {ThemeMode.system: l10n.systemDefault, ThemeMode.light: l10n.light, ThemeMode.dark: l10n.dark};
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
  const MetaChip(this.text, {super.key, this.icon, this.mono = false, this.onTap, this.semanticLabel});
  final String text;
  final IconData? icon;
  final bool mono;
  /// Makes the chip a link to what it names, drawn in the primary colour.
  final VoidCallback? onTap;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = onTap == null ? scheme.onSurfaceVariant : scheme.primary;
    final style = mono
        ? codeTextStyle(context, fontSize: 12, color: color)
        : Theme.of(context).textTheme.bodySmall?.copyWith(color: color);
    final chip = Row(mainAxisSize: MainAxisSize.min, children: [
      if (icon != null) ...[Icon(icon, size: 14, color: color), const SizedBox(width: 4)],
      Flexible(child: Text(isolated(text), maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
    ]);
    final tap = onTap;
    if (tap == null) return chip;
    return SemanticButton(label: semanticLabel ?? text, onTap: tap, child: InkWell(
      borderRadius: BorderRadius.circular(6), onTap: tap,
      child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 32),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: chip))));
  }
}

/// Who a row is by (the author, the person who ran it): a small monogram and
/// `@username`, or the name when there is no username (a commit author), in
/// the meta row's style. Nothing when both are missing; build rows with
/// [PersonChip.of] so a missing person leaves no gap.
class PersonChip extends StatelessWidget {
  const PersonChip(this.person, {super.key, this.author = true});
  /// A chip for [person], or null when there is nobody to show, so a row does
  /// not keep an empty slot.
  static PersonChip? of(Json person, {bool author = true}) =>
      valueText(person, 'username').isEmpty && valueText(person, 'name').isEmpty ? null : PersonChip(person, author: author);
  final Json person;
  /// Screen readers hear "Author …"; otherwise just the person.
  final bool author;
  @override
  Widget build(BuildContext context) {
    final username = valueText(person, 'username'), name = valueText(person, 'name');
    final shown = username.isNotEmpty ? '@$username' : name;
    if (shown.isEmpty) return const SizedBox.shrink();
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return Semantics(label: author ? l10n.authorLabel(shown) : shown, excludeSemantics: true, child: Row(mainAxisSize: MainAxisSize.min, children: [
      Monogram(name.isEmpty ? username : name, size: 18, circle: true),
      const SizedBox(width: 4),
      Flexible(child: Text(isolated(shown), maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
    ]));
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
            borderRadius: BorderRadius.circular(12),
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
  const Monogram(this.name, {super.key, this.size = 42, this.circle = false});
  final String name;
  final double size;

  /// People are round, projects and groups are rounded squares.
  final bool circle;
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
        borderRadius: BorderRadius.circular(circle ? size / 2 : size * .28),
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
    this.art,
  });
  final String title;
  final String? detail;
  final IconData icon;
  final Widget? action;

  /// An illustration shown instead of the icon badge, with a larger title.
  final Widget? art;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(horizontal: 28, vertical: art == null ? 40 : 28),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        art ?? Container(
          width: 64, height: 64, alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest, shape: BoxShape.circle),
          child: Icon(icon, size: 30, color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
        SizedBox(height: art == null ? 16 : 24),
        Text(
          title,
          textAlign: TextAlign.center,
          style: art == null
              ? Theme.of(context).textTheme.titleMedium
              : Theme.of(context).textTheme.headlineSmall,
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

/// The one renderer for read-cache cleanup states (§4.6). Text comes from the
/// state and the current language at display time; nothing translated is
/// stored on the failure or on disk.
(String, String) readCacheCleanupText(ReadCacheCleanupState state) =>
    switch (state.disposition) {
      ReadCacheCleanupDisposition.requestBlockedBeforeSend =>
        (l10n.readCacheBlockedTitle, l10n.readCacheBlockedDetail),
      ReadCacheCleanupDisposition.originalOutcomePreserved =>
        (l10n.readCachePreservedTitle, l10n.readCachePreservedDetail),
      ReadCacheCleanupDisposition.legalNetworkValueReturned =>
        (l10n.readCachePrivacyTitle, l10n.readCachePrivacyDetail),
      ReadCacheCleanupDisposition.accountRetained =>
        (l10n.readCacheCleanupFailedTitle, l10n.readCacheRetainedDetail),
      ReadCacheCleanupDisposition.signedOutCleanupPending =>
        (l10n.readCacheSignedOutTitle, l10n.readCacheSignedOutDetail),
      ReadCacheCleanupDisposition.diskClosed =>
        (l10n.readCacheCleanupFailedTitle, l10n.readCacheClosedDetail),
    };

String failureTitle(UserFacingFailure failure) => switch (failure) {
  ApiFailure(kind: FailureKind.readCacheCleanup, :final cleanup?) =>
    readCacheCleanupText(cleanup).$1,
  _ => failure.title,
};

String failureDetail(UserFacingFailure failure) => switch (failure) {
  ApiFailure(kind: FailureKind.readCacheCleanup, :final cleanup?) =>
    readCacheCleanupText(cleanup).$2,
  _ => failure.detail,
};

/// A cleanup notice can only retry the cleanup. A retained account is retried
/// by removing it again from its account row, not from the notice.
bool offersCleanupRetry(UserFacingFailure failure) => switch (failure) {
  ApiFailure(kind: FailureKind.readCacheCleanup, :final cleanup?) =>
    cleanup.disposition != ReadCacheCleanupDisposition.accountRetained,
  _ => false,
};

/// Whether the screen's own retry may be offered. It is never offered for an
/// uncertain write, nor for a cleanup notice whose request already reached
/// GitLab; only a request the barrier stopped before sending may be retried.
bool _offersOriginalRetry(ApiFailure error) => switch (error.kind) {
  FailureKind.writeUncertain => false,
  FailureKind.readCacheCleanup =>
    error.cleanup?.disposition ==
        ReadCacheCleanupDisposition.requestBlockedBeforeSend,
  _ => true,
};

class FailureNotice extends StatelessWidget {
  const FailureNotice(
    this.error, {
    super.key,
    this.account,
    this.resourceLabel,
    this.onRetry,
    this.onSwitchAccount,
    this.resumeTarget,
    this.onRetryCleanup,
    this.offlineSavedAt,
    this.onOpenOffline,
  });
  final ApiFailure error;
  final Account? account;
  final String? resourceLabel;
  final VoidCallback? onRetry;
  final VoidCallback? onSwitchAccount;
  final ResumeTarget? resumeTarget;

  /// Retries only the offline-cache cleanup of a read-cache notice.
  final VoidCallback? onRetryCleanup;

  /// A complete offline version of the same project exists (§6.2): offered
  /// on network failures as "view offline version (saved …)".
  final String? offlineSavedAt;
  final VoidCallback? onOpenOffline;
  @override
  Widget build(BuildContext context) {
    Account? effectiveAccount = account;
    VoidCallback? effectiveSwitch = onSwitchAccount;
    // A cleanup notice is about this device's cache, not account access:
    // switching accounts would not resolve it.
    final cacheNotice = error.kind == FailureKind.readCacheCleanup;
    if (cacheNotice) {
      effectiveSwitch = null;
    } else if (effectiveAccount == null || effectiveSwitch == null) {
      try {
        final session = ProviderScope.containerOf(
          context,
          listen: false,
        ).read(sessionProvider);
        effectiveAccount ??= session.active;
        effectiveSwitch ??= () => unawaited(SessionLeaveScope.run(
          context,
          const LeaveIntent(LeaveKind.signOut),
          () {
            if (resumeTarget != null) {
              session.setPendingResumeTarget(resumeTarget);
            }
            return session.endSession(switching: resumeTarget != null);
          },
        ));
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
                      failureTitle(error),
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(failureDetail(error)),
              if (effectiveAccount != null) ...[
                const SizedBox(height: 12),
                Text(l10n.instanceKey(effectiveAccount.instance.key)),
                Text(l10n.appAccountUsername(effectiveAccount.user.username)),
              ],
              if (resourceLabel != null && resourceLabel!.isNotEmpty)
                Text(l10n.targetResource(resourceLabel)),
              Wrap(
                spacing: 8,
                children: [
                  if (onRetry != null && _offersOriginalRetry(error))
                    TextButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: Text(l10n.refreshAction),
                    ),
                  if (onRetryCleanup != null && offersCleanupRetry(error))
                    TextButton.icon(
                      key: const ValueKey('read-cache-retry-cleanup'),
                      onPressed: onRetryCleanup,
                      icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                      label: Text(l10n.offlineCacheRetryCleanup),
                    ),
                  if (effectiveSwitch != null)
                    TextButton(
                      onPressed: effectiveSwitch,
                      child: Text(l10n.switchAccount),
                    ),
                  if (onOpenOffline != null && offlineSavedAt != null)
                    TextButton.icon(
                      key: const ValueKey('failure-open-offline'),
                      onPressed: onOpenOffline,
                      icon: const Icon(Icons.offline_pin_outlined, size: 18),
                      label: Text(l10n.offlineViewSaved(offlineSavedAt)),
                    ),
                ],
              ),
              ExpansionTile(
                key: const PageStorageKey<String>('failure-notice-diagnostics'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: EdgeInsets.zero,
                title: Text(l10n.diagnosticInformation, style: TextStyle(fontSize: 12)),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      key: const PageStorageKey<String>(
                        'failure-notice-diagnostics-detail',
                      ),
                      [
                        error.kind.name,
                        if (error.status != null) 'HTTP ${error.status}',
                        if (error.cleanup case final state?) ...[
                          state.disposition.name,
                          state.code.name,
                        ],
                      ].join(' · '),
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

class ListSkeleton extends StatelessWidget implements Skeleton {
  const ListSkeleton({
    super.key,
    this.rows = 8,
    this.grouped = false,
    this.padding = EdgeInsets.zero,
    this.rowHeight = RowsSkeleton.rowHeight,
    this.leadingSize = 36,
    this.leadingRadius = 8,
    this.showLeading = true,
    this.showSubtitle = true,
    this.liveRegion = true,
  });

  final int rows;
  final bool grouped;
  final EdgeInsetsGeometry padding;
  final double rowHeight;
  final double leadingSize;
  final double leadingRadius;
  final bool showLeading;
  final bool showSubtitle;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) => RowsSkeleton(
    rows: rows,
    grouped: grouped,
    padding: padding,
    itemHeight: rowHeight,
    leadingSize: leadingSize,
    leadingRadius: leadingRadius,
    showLeading: showLeading,
    showSubtitle: showSubtitle,
    liveRegion: liveRegion,
  );
}

Future<bool> confirmAction(
  BuildContext context,
  String title,
  String detail, {
  String? requiredText,
  ValueChanged<Route<dynamic>>? onRoute,
  String? confirmLabel,
}) async {
  final input = TextEditingController();
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) {
      final route = ModalRoute.of(context);
      if (route != null) onRoute?.call(route);
      return StatefulBuilder(
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
                Text(l10n.typeToConfirm(requiredText)),
                const SizedBox(height: 8),
                TextField(
                  controller: input,
                  autocorrect: false,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(labelText: l10n.confirmName),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            onPressed:
                requiredText != null &&
                    _withoutIsolates(input.text) !=
                        _withoutIsolates(requiredText)
                ? null
                : () => Navigator.pop(context, true),
            child: Text(confirmLabel ?? l10n.confirmAction),
          ),
        ],
      ),
      );
    },
  );
  // The route may still be animating out; do not dispose its controller early.
  Future<void>.delayed(const Duration(milliseconds: 400), input.dispose);
  return answer ?? false;
}

/// [onRetryCleanup] is offered only for a read-cache cleanup notice, and it
/// retries the cleanup alone; it is never a way to repeat the operation.
void showFailure(
  BuildContext context,
  Object error, {
  VoidCallback? onRetryCleanup,
}) {
  final failure = error is UserFacingFailure ? error : safeFailure(error);
  // Text and action label are read when built, so a snack bar on screen or
  // still queued follows a language change (rebuildForLanguage).
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: _FailureSnackText(failure),
    action: onRetryCleanup != null && offersCleanupRetry(failure)
        ? RetryCleanupSnackAction(onPressed: onRetryCleanup)
        : null,
  ));
}

class _FailureSnackText extends StatelessWidget {
  const _FailureSnackText(this.failure);
  final UserFacingFailure failure;
  @override
  Widget build(BuildContext context) =>
      Text(l10n.titleThenDetail(failureTitle(failure), failureDetail(failure)));
}

/// Snack bar text read from the current language whenever it is built, so a
/// snack bar on screen or queued follows a language change.
class LiveText extends StatelessWidget {
  const LiveText(this.text, {super.key});
  final String Function() text;
  @override
  Widget build(BuildContext context) => Text(text());
}

/// A snack bar action that retries only an offline-cache cleanup; its label is
/// read from the current language on every build.
class RetryCleanupSnackAction extends SnackBarAction {
  const RetryCleanupSnackAction({super.key, required super.onPressed}) : super(label: '');
  @override
  String get label => l10n.offlineCacheRetryCleanup;
}

/// Text without the invisible direction marks an Arabic interface wraps
/// around names, so a name copied from the dialog still matches.
String _withoutIsolates(String text) =>
    text.replaceAll(RegExp('[\u200e\u200f\u2066-\u2069]'), '');
