import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/providers.dart';
import '../auth/session_controller.dart';
import '../../shared/workspace_ui.dart';

import '../../l10n/l10n.dart';
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

/// Shared choices for the REST and Work Item note pickers.
const reactionChoices = {...quickReactions, ..._moreGlyphs};

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
  int _generation = 0;
  SessionController? _session;
  int? _sessionGeneration;
  NavigatorState? _navigator;
  Route<String>? _picker;

  bool _current(ReactionsBar owner, int generation) =>
      mounted &&
      generation == _generation &&
      !owner.api.isClosed &&
      owner.account.key == widget.account.key &&
      identical(owner.api, widget.api) &&
      owner.project.id == widget.project.id &&
      owner.resource == widget.resource &&
      owner.iid == widget.iid &&
      owner.note == widget.note &&
      (_session == null ||
          (_session!.active?.key == owner.account.key &&
              identical(_session!.api, owner.api) &&
              _session!.generation == _sessionGeneration));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
    _bindSession();
  }

  void _bindSession() {
    if (_session != null) return;
    try {
      _session = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(sessionProvider);
      _sessionGeneration = _session!.generation;
      _session!.addListener(_sessionChanged);
    } on StateError {
      // Standalone widget hosts do not have a session provider.
    }
  }

  void _dismissPicker() {
    final route = _picker, navigator = _navigator;
    _picker = null;
    if (route == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator?.mounted == true && route.isActive) {
        navigator!.removeRoute(route);
      }
    });
  }

  void _sessionChanged() {
    if (_current(widget, _generation)) return;
    _generation++;
    _epoch++;
    _dismissPicker();
    if (mounted) {
      setState(() {
        _awards = const [];
        _busy = false;
        _loading = false;
        _error = const ApiFailure(FailureKind.cancelled);
      });
    }
  }

  @override
  void didUpdateWidget(covariant ReactionsBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key == widget.account.key &&
        identical(oldWidget.api, widget.api) &&
        oldWidget.project.id == widget.project.id &&
        oldWidget.resource == widget.resource &&
        oldWidget.iid == widget.iid &&
        oldWidget.note == widget.note) {
      return;
    }
    _generation++;
    _epoch++;
    _dismissPicker();
    _session?.removeListener(_sessionChanged);
    _session = null;
    _sessionGeneration = null;
    _bindSession();
    _awards = const [];
    _error = null;
    _busy = false;
    unawaited(_load());
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _epoch++;
    _dismissPicker();
    _session?.removeListener(_sessionChanged);
    super.dispose();
  }

  Future<void> _load() async {
    final owner = widget, generation = _generation;
    final epoch = ++_epoch;
    if (!_current(owner, generation)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final awards = <Json>[];
      Uri? next;
      var pages = 0;
      do {
        final page = await owner.api.awardEmoji(
          owner.project.id,
          owner.resource,
          owner.iid,
          note: owner.note,
          next: next,
        );
        if (!_current(owner, generation) || epoch != _epoch) return;
        awards.addAll(page.items);
        next = page.next;
      } while (next != null && ++pages < _maxPages);
      setState(() => _awards = awards);
    } catch (e) {
      if (_current(owner, generation) && epoch == _epoch) {
        setState(() => _error = safeFailure(e));
      }
    } finally {
      if (_current(owner, generation) && epoch == _epoch) {
        setState(() => _loading = false);
      }
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
    final owner = widget, generation = _generation;
    if (_busy || !_current(owner, generation)) return;
    setState(() => _busy = true);
    try {
      final mine = _mine(name);
      if (mine != null) {
        await owner.api.removeAwardEmoji(
          owner.project.id,
          owner.resource,
          owner.iid,
          valueInt(mine, 'id'),
          note: owner.note,
        );
      } else {
        await owner.api.addAwardEmoji(
          owner.project.id,
          owner.resource,
          owner.iid,
          name,
          note: owner.note,
        );
      }
      if (_current(owner, generation)) await _load();
    } catch (e) {
      if (mounted && _current(owner, generation)) showFailure(context, e);
    } finally {
      if (_current(owner, generation)) setState(() => _busy = false);
    }
  }

  Future<void> _pick() async {
    final owner = widget, generation = _generation;
    if (!_current(owner, generation) || _picker != null) return;
    final route = ModalBottomSheetRoute<String>(
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.addReaction,
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in reactionChoices.entries)
                    Semantics(
                      button: true,
                      label: entry.key,
                      excludeSemantics: true,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => Navigator.pop(sheetContext, entry.key),
                        child: SizedBox(
                          width: 52,
                          height: 52,
                          child: Center(
                            child: Text(
                              entry.value,
                              style: const TextStyle(fontSize: 26),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    _picker = route;
    final name = await Navigator.of(context).push(route);
    if (identical(_picker, route)) _picker = null;
    if (name != null && _current(owner, generation)) await _toggle(name);
  }

  @override
  Widget build(BuildContext context) {
    final ownerCurrent = _current(widget, _generation);
    final counts = <String, int>{};
    for (final award in _awards) {
      final name = valueText(award, 'name');
      if (name.isNotEmpty) counts[name] = (counts[name] ?? 0) + 1;
    }
    final scheme = Theme.of(context).colorScheme;
    final error = _error;
    if (error != null && _awards.isEmpty) {
      return FailureNotice(error, account: widget.account, onRetry: ownerCurrent ? _load : null, onSwitchAccount: endSessionFrom(context),
        resourceLabel: l10n.resourceReactions(widget.project.path, widget.resource == 'merge_requests' ? '!' : '#', widget.iid));
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
          ].join(l10n.listSeparator),
          label: Text('${reactionGlyph(entry.key)} ${entry.value}'),
          onSelected: _busy || !ownerCurrent ? null : (_) => _toggle(entry.key),
        ),
      ActionChip(
        key: const ValueKey('reaction-add'),
        tooltip: l10n.addReaction,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.padded,
        avatar: Icon(Icons.add_reaction_outlined, size: 18, color: scheme.onSurfaceVariant),
        label: Text(l10n.addReaction),
        onPressed: _busy || !ownerCurrent || _loading && _awards.isEmpty ? null : _pick,
      ),
    ]);
  }
}
