import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';

/// GitLab award names offered in the quick picker, with their glyphs.
const quickReactions = <String, String>{
  'thumbsup': '👍',
  'thumbsdown': '👎',
  'smile': '😄',
  'tada': '🎉',
  'confused': '😕',
  'heart': '❤️',
  'rocket': '🚀',
  'eyes': '👀',
};

const _moreGlyphs = <String, String>{
  'laughing': '😆', '100': '💯', 'fire': '🔥', 'clap': '👏', 'thinking': '🤔', 'pray': '🙏',
  'white_check_mark': '✅', 'x': '❌', 'warning': '⚠️', 'star': '⭐', 'raised_hands': '🙌', 'ok_hand': '👌',
  'muscle': '💪', 'sweat_smile': '😅', 'joy': '😂', 'cry': '😢', 'sparkles': '✨', 'bug': '🐛',
};

String reactionGlyph(String name) => quickReactions[name] ?? _moreGlyphs[name] ?? ':$name:';

/// Emoji reactions on an issue, merge request or note: existing awards with
/// counts, the signed-in user's own highlighted, and a picker to add one.
class ReactionsBar extends StatefulWidget {
  const ReactionsBar({super.key, required this.account, required this.api, required this.project,
    required this.resource, required this.iid, this.note});
  final Account account;
  final GitLabApi api;
  final Project project;
  final String resource;
  final int iid;
  final int? note;
  @override
  State<ReactionsBar> createState() => _ReactionsBarState();
}

class _ReactionsBarState extends State<ReactionsBar> {
  /// Awards are one record per user and emoji; ten pages cover any real issue.
  static const _maxPages = 10;
  List<Json> _awards = const [];
  ApiFailure? _error;
  bool _loading = true, _busy = false;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _epoch++;
    super.dispose();
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final awards = <Json>[];
      Uri? next;
      var pages = 0;
      do {
        final page = await widget.api.awardEmoji(widget.project.id, widget.resource, widget.iid, note: widget.note, next: next);
        if (!mounted || epoch != _epoch) return;
        awards.addAll(page.items);
        next = page.next;
      } while (next != null && ++pages < _maxPages);
      setState(() => _awards = awards);
    } catch (e) {
      if (mounted && epoch == _epoch) setState(() => _error = safeFailure(e));
    } finally {
      if (mounted && epoch == _epoch) setState(() => _loading = false);
    }
  }

  Json? _mine(String name) {
    for (final award in _awards) {
      if (valueText(award, 'name') == name && valueInt(valueObject(award, 'user'), 'id') == widget.account.user.id) {
        return award;
      }
    }
    return null;
  }

  Future<void> _toggle(String name) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final mine = _mine(name);
      if (mine != null) {
        await widget.api.removeAwardEmoji(widget.project.id, widget.resource, widget.iid, valueInt(mine, 'id'), note: widget.note);
      } else {
        await widget.api.addAwardEmoji(widget.project.id, widget.resource, widget.iid, name, note: widget.note);
      }
      await _load();
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() async {
    final name = await showModalBottomSheet<String>(context: context, showDragHandle: true, builder: (sheetContext) => SafeArea(
      child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('新增回應', style: Theme.of(sheetContext).textTheme.titleMedium),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final entry in {...quickReactions, ..._moreGlyphs}.entries)
              Semantics(button: true, label: entry.key, excludeSemantics: true, child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => Navigator.pop(sheetContext, entry.key),
                child: SizedBox(width: 52, height: 52, child: Center(child: Text(entry.value, style: const TextStyle(fontSize: 26)))),
              )),
          ]),
        ])),
    ));
    if (name != null && mounted) await _toggle(name);
  }

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final award in _awards) {
      final name = valueText(award, 'name');
      if (name.isNotEmpty) counts[name] = (counts[name] ?? 0) + 1;
    }
    final scheme = Theme.of(context).colorScheme;
    final error = _error;
    if (error != null && _awards.isEmpty) {
      return FailureNotice(error, account: widget.account, onRetry: _load, onSwitchAccount: endSessionFrom(context),
        resourceLabel: '${widget.project.path} · ${widget.resource == 'merge_requests' ? '!' : '#'}${widget.iid} 回應');
    }
    return Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final entry in counts.entries)
        FilterChip(
          key: ValueKey('reaction-${entry.key}'),
          showCheckmark: false,
          selected: _mine(entry.key) != null,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.padded,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          tooltip: [
            for (final award in _awards)
              if (valueText(award, 'name') == entry.key) '@${valueText(valueObject(award, 'user'), 'username')}',
          ].join('、'),
          label: Text('${reactionGlyph(entry.key)} ${entry.value}'),
          onSelected: _busy ? null : (_) => _toggle(entry.key),
        ),
      ActionChip(
        key: const ValueKey('reaction-add'),
        tooltip: '新增回應',
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        avatar: Icon(Icons.add_reaction_outlined, size: 18, color: scheme.onSurfaceVariant),
        label: Text(counts.isEmpty ? '回應' : '新增'),
        onPressed: _busy || _loading && _awards.isEmpty ? null : _pick,
      ),
    ]);
  }
}
