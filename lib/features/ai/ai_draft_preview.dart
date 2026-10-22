import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/ai/draft_mentions.dart';
import '../../l10n/l10n.dart';
import '../../shared/hub_ui.dart';
import '../../shared/markdown_view.dart';
import '../../shared/theme.dart';

/// How many sources the preview lists before it only counts the rest.
const _shownSources = 5;

/// How many mentioned users the preview names before it only counts the rest.
const _shownMentions = 8;

/// How much of the text the preview shows; the editor shows all of it.
const _shownCharacters = 6000;

/// From this length on the draft is checked off the UI isolate: every mention
/// candidate reparses the whole draft, which takes seconds on a phone for a
/// long, code-heavy answer.
const _backgroundCharacters = 4000;

/// The mention check of [text] appended to [existing], both as written (for
/// "keep mention notifications") and with mentions turned off.
typedef AiDraftAnalysis = ({DraftMentions asWritten, DraftMentions neutralized});

Future<AiDraftAnalysis> analyzeAiDraft(String text, String existing) =>
    text.length + existing.length < _backgroundCharacters
    ? Future.value(_analyze(text, existing))
    : Isolate.run(() => _analyze(text, existing));

AiDraftAnalysis _analyze(String text, String existing) => (
  asWritten: analyzeDraftMentions(
    text,
    existing: existing,
    keepNotifications: true,
  ),
  neutralized: analyzeDraftMentions(text, existing: existing),
);

/// Shows what appending the answer to the comment draft on [target] would do,
/// and returns the text to append, or null when the user backs out. Nothing
/// is sent: the caller opens the ordinary comment editor with the result.
///
/// [asWritten] and [neutralized] come from [analyzeAiDraft]; their text has
/// already been through `neutralizeForGitLabDraft`, which changed
/// [quickActionLines] of its lines. [afterExisting] says the answer follows a
/// draft that is already there. [sources] are display labels (already
/// isolated) of what the answer read. [confidential] warns that the
/// conversation read a confidential issue and [target] is not one;
/// [internal] that it read internal notes.
Future<String?> showAiDraftPreview(
  BuildContext context, {
  required String target,
  required DraftMentions asWritten,
  required DraftMentions neutralized,
  required bool afterExisting,
  required int quickActionLines,
  required List<String> sources,
  required bool confidential,
  required bool internal,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => AiDraftPreviewSheet(
    target: target,
    asWritten: asWritten,
    neutralized: neutralized,
    afterExisting: afterExisting,
    quickActionLines: quickActionLines,
    sources: sources,
    confidential: confidential,
    internal: internal,
  ),
);

class AiDraftPreviewSheet extends StatefulWidget {
  const AiDraftPreviewSheet({
    super.key,
    required this.target,
    required this.asWritten,
    required this.neutralized,
    required this.afterExisting,
    required this.quickActionLines,
    required this.sources,
    required this.confidential,
    required this.internal,
  });

  final String target;
  final DraftMentions asWritten;
  final DraftMentions neutralized;
  final bool afterExisting;
  final int quickActionLines;
  final List<String> sources;
  final bool confidential;
  final bool internal;

  @override
  State<AiDraftPreviewSheet> createState() => _AiDraftPreviewSheetState();
}

class _AiDraftPreviewSheetState extends State<AiDraftPreviewSheet> {
  var _keep = false;
  var _acknowledged = false;

  /// Every mention the answer adds outside code, as written.
  DraftMentions get _asWritten => widget.asWritten;
  DraftMentions get _result => _keep ? widget.asWritten : widget.neutralized;

  /// Mentions that would still notify although the user did not choose to
  /// keep notifications: the conversion could not be verified for them.
  bool get _needsAcknowledgement => !_keep && _result.mentions.isNotEmpty;

  void _setKeep(bool keep) => setState(() {
    _keep = keep;
    _acknowledged = false;
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final keyboard = media.viewInsets.bottom;
    final ready = !_needsAcknowledgement || _acknowledged;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The constraints already leave out the status bar (useSafeArea) and
        // the drag handle. A short window uses all of the room it has.
        final room = math.max(0.0, constraints.maxHeight - keyboard);
        final height = room < 420 ? room : room * 0.9;
        return Padding(
          padding: EdgeInsets.only(bottom: keyboard),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: height),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    key: const ValueKey('ai-draft-preview-scroll'),
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.aiDraftPreviewTitle,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(widget.target, style: muted),
                        const SizedBox(height: 12),
                        if (widget.confidential)
                          _Fact(
                            key: const ValueKey('ai-draft-confidential'),
                            icon: Icons.lock_outline,
                            color: HubColors.orange,
                            text: l10n.aiDraftConfidential,
                            strong: true,
                          ),
                        if (widget.internal)
                          _Fact(
                            key: const ValueKey('ai-draft-internal'),
                            icon: Icons.visibility_off_outlined,
                            color: HubColors.orange,
                            text: l10n.aiDraftInternal,
                            strong: true,
                          ),
                        if (widget.afterExisting)
                          _Fact(
                            key: const ValueKey('ai-draft-after-existing'),
                            icon: Icons.edit_note,
                            text: l10n.aiDraftAfterExisting,
                          ),
                        if (_asWritten.mentions.isNotEmpty)
                          ..._mentions(theme, muted),
                        if (widget.quickActionLines > 0)
                          _Fact(
                            key: const ValueKey('ai-draft-quick-actions'),
                            icon: Icons.code_off,
                            text: l10n.aiDraftQuickActions(
                              '${widget.quickActionLines}',
                            ),
                          ),
                        if (_result.references > 0)
                          _Fact(
                            key: const ValueKey('ai-draft-references'),
                            icon: Icons.link,
                            text: l10n.aiDraftReferences(
                              '${_result.references}',
                            ),
                          ),
                        if (widget.sources.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            l10n.aiDraftSources,
                            style: theme.textTheme.labelLarge,
                          ),
                          const SizedBox(height: 4),
                          for (final source in widget.sources.take(
                            _shownSources,
                          ))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.description_outlined,
                                    size: 16,
                                    color: muted?.color,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text(source, style: muted)),
                                ],
                              ),
                            ),
                          if (widget.sources.length > _shownSources)
                            Padding(
                              padding: const EdgeInsetsDirectional.only(
                                start: 24,
                                top: 2,
                              ),
                              child: Text(
                                l10n.aiDraftMore(
                                  '${widget.sources.length - _shownSources}',
                                ),
                                style: muted,
                              ),
                            ),
                        ],
                        const SizedBox(height: 12),
                        Text(
                          l10n.aiDraftText,
                          style: theme.textTheme.labelLarge,
                        ),
                        const SizedBox(height: 6),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: SizedBox(
                              width: double.infinity,
                              child: Text(
                                _shown,
                                key: const ValueKey('ai-draft-preview-text'),
                                // The answer reads in its own direction,
                                // whatever the interface language.
                                textDirection: firstStrongDirection(
                                  _result.text,
                                ),
                                style: codeTextStyle(context),
                              ),
                            ),
                          ),
                        ),
                        if (_cut) ...[
                          const SizedBox(height: 6),
                          Text(l10n.aiDraftPreviewCut, style: muted),
                        ],
                        const SizedBox(height: 8),
                        Text(l10n.aiDraftNotSent, style: muted),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  // Clear of the system navigation bar.
                  padding: EdgeInsets.fromLTRB(
                    16,
                    8,
                    16,
                    8 + (keyboard > 0 ? 0 : media.padding.bottom),
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(l10n.cancelAction),
                      ),
                      FilledButton.icon(
                        key: const ValueKey('ai-draft-confirm'),
                        icon: const Icon(Icons.add_comment_outlined, size: 18),
                        label: Text(l10n.aiDraftConfirm),
                        onPressed: ready
                            ? () => Navigator.of(context).pop(_result.text)
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Whether the preview shows only the start of the text.
  bool get _cut => _result.text.length > _shownCharacters;

  /// The start of the text: one long paragraph is slow to lay out, and the
  /// editor shows all of it.
  String get _shown {
    final text = _result.text;
    if (!_cut) return text;
    var end = _shownCharacters;
    // Never split a surrogate pair.
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xd800 && last <= 0xdbff) end--;
    return '${text.substring(0, end)}…';
  }

  List<Widget> _mentions(ThemeData theme, TextStyle? muted) {
    final names = _result.mentions;
    return [
      if (names.isEmpty)
        _Fact(
          key: const ValueKey('ai-draft-mentions-off'),
          icon: Icons.notifications_off_outlined,
          text: l10n.aiDraftMentionsOff('${_result.neutralized}'),
        )
      else ...[
        _Fact(
          key: const ValueKey('ai-draft-mentions-notify'),
          icon: Icons.notifications_active_outlined,
          color: _keep ? null : HubColors.orange,
          text: l10n.aiDraftMentionsNotify('${names.length}'),
          strong: !_keep,
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 28, bottom: 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final name in names.take(_shownMentions))
                Chip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: Text(isolated('@$name')),
                ),
              if (names.length > _shownMentions)
                Chip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: Text(
                    l10n.aiDraftMore('${names.length - _shownMentions}'),
                  ),
                ),
            ],
          ),
        ),
      ],
      SwitchListTile(
        key: const ValueKey('ai-draft-keep-mentions'),
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(l10n.aiDraftKeepMentions),
        value: _keep,
        onChanged: _setKeep,
      ),
      if (_needsAcknowledgement)
        CheckboxListTile(
          key: const ValueKey('ai-draft-acknowledge'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(l10n.aiDraftAcknowledge),
          value: _acknowledged,
          onChanged: (value) => setState(() => _acknowledged = value ?? false),
        ),
    ];
  }
}

/// One line of what the append will do: an icon and a sentence.
class _Fact extends StatelessWidget {
  const _Fact({
    super.key,
    required this.icon,
    required this.text,
    this.color,
    this.strong = false,
  });

  final IconData icon;
  final String text;
  final Color? color;

  /// A warning the user should read before going on.
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = strong
        ? theme.textTheme.bodyMedium
        : theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 20,
            color: color ?? theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}
