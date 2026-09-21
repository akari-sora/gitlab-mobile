import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';
import 'record_controller.dart';

enum PickerSource { labels, members, branches }

class PickerChoice {
  const PickerChoice({required this.id, required this.name, this.username, this.color});
  final String id, name;
  final String? username, color;

  Map<String, String> toJson() => {
    'id': id,
    'name': name,
    if (username != null && username!.isNotEmpty) 'username': username!,
    if (color != null && color!.isNotEmpty) 'color': color!,
  };

  factory PickerChoice.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    return PickerChoice(
      id: id is String ? id : id is num ? '$id' : '',
      name: name is String ? name : '',
      username: json['username'] is String ? json['username'] as String : null,
      color: json['color'] is String ? json['color'] as String : null,
    );
  }
}

String encodeChoices(List<PickerChoice> choices) => jsonEncode({
  'picker': 1,
  'choices': [for (final choice in choices) choice.toJson()],
});

/// Structured drafts are the envelope `{"picker": 1, "choices": [...]}` and the
/// bare list earlier builds saved (`[{"id":..,"name":..}, ...]`). Anything else
/// is legacy text. Branches stay whole, because a name may contain commas;
/// labels and members split on commas.
List<PickerChoice> decodeChoices(String raw, {PickerSource? source}) {
  if (raw.trim().isEmpty) return const [];
  final structured = _structuredChoices(raw.trim());
  if (structured != null) return structured;
  if (source == PickerSource.branches) {
    return [PickerChoice(id: raw, name: raw)];
  }
  return [
    for (final part in raw.split(','))
      if (part.trim().isNotEmpty) PickerChoice(id: part.trim(), name: part.trim()),
  ];
}

List<PickerChoice>? _structuredChoices(String raw) {
  try {
    final value = jsonDecode(raw);
    if (value is List<dynamic>) return _bareChoices(value);
    if (value is! Map<String, dynamic> || value['picker'] != 1) return null;
    final choices = value['choices'];
    if (choices is! List<dynamic>) return const <PickerChoice>[];
    return [for (final item in choices) ?_choiceOrNull(item)];
  } on FormatException {
    return null;
  }
}

/// A bare list is a picker payload only when every element is an object with
/// `id` and a non-empty `name`. An empty list is an empty selection.
List<PickerChoice>? _bareChoices(List<dynamic> items) {
  final choices = <PickerChoice>[];
  for (final item in items) {
    if (item is! Map) return null;
    final id = item['id'];
    final name = item['name'];
    if (id is! String && id is! num) return null;
    if (name is! String || name.isEmpty) return null;
    final choice = _choiceOrNull(item);
    if (choice == null) return null;
    choices.add(choice);
  }
  return choices;
}

PickerChoice? _choiceOrNull(Object? item) {
  if (item is Map<String, dynamic>) {
    final choice = PickerChoice.fromJson(item);
    return choice.name.isEmpty ? null : choice;
  }
  if (item is Map) {
    final mapped = <String, dynamic>{};
    item.forEach((key, entry) {
      if (key is String) mapped[key] = entry;
    });
    final choice = PickerChoice.fromJson(mapped);
    return choice.name.isEmpty ? null : choice;
  }
  return null;
}

Color? labelColor(String? hex) {
  if (hex == null) return null;
  var raw = hex.trim();
  if (raw.startsWith('#')) raw = raw.substring(1);
  if (raw.length != 6 && raw.length != 8) return null;
  final value = int.tryParse(raw, radix: 16);
  if (value == null) return null;
  final argb = raw.length == 6 ? (0xFF000000 | value) : value;
  return Color.fromARGB((argb >> 24) & 0xFF, (argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
}

class PickerChoiceLabel extends StatelessWidget {
  const PickerChoiceLabel(this.choice, this.source, {super.key, this.expand = false, this.compact = false});
  final PickerChoice choice;
  final PickerSource source;
  final bool expand, compact;

  @override
  Widget build(BuildContext context) {
    final username = choice.username;
    final text = switch (source) {
      PickerSource.members => '@${(username == null || username.isEmpty) ? choice.name : username}',
      _ => choice.name,
    };
    final label = Text(text, overflow: TextOverflow.ellipsis);
    final leading = switch (source) {
      PickerSource.labels => _dot(),
      PickerSource.members => Monogram(choice.name.isEmpty ? (username ?? 'G') : choice.name, size: compact ? 24 : 28),
      PickerSource.branches => const Icon(Icons.alt_route, size: 18),
    };
    return Row(
      mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (leading != null) ...[leading, const SizedBox(width: 8)],
        if (expand) Expanded(child: label) else label,
      ],
    );
  }

  Widget? _dot() {
    final color = labelColor(choice.color);
    if (color == null) return null;
    return Container(
      key: ValueKey('label-dot-${choice.id}'),
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

Future<List<PickerChoice>?> showChoicePicker(
  BuildContext context, {
  required GitLabApi api,
  required Account account,
  required int projectId,
  required PickerSource source,
  required bool multi,
  required String title,
  required List<PickerChoice> initial,
}) {
  return showModalBottomSheet<List<PickerChoice>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) {
      final media = MediaQuery.of(context);
      // useSafeArea leaves the bottom edge open. Keep the larger of the
      // keyboard inset and the home-indicator inset so 完成 stays clear of both.
      final bottom = max(media.viewInsets.bottom, media.viewPadding.bottom);
      return Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: LayoutBuilder(builder: (context, constraints) {
          final raw = constraints.maxHeight;
          final height = raw.isFinite ? raw.clamp(0.0, double.infinity) : 0.0;
          return SizedBox(
            height: height,
            child: ChoicePickerSheet(
              api: api,
              account: account,
              projectId: projectId,
              source: source,
              multi: multi,
              title: title,
              initial: initial,
            ),
          );
        }),
      );
    },
  );
}

class ChoicePickerSheet extends StatefulWidget {
  const ChoicePickerSheet({
    super.key,
    required this.api,
    required this.account,
    required this.projectId,
    required this.source,
    required this.multi,
    required this.title,
    required this.initial,
  });
  final GitLabApi api;
  final Account account;
  final int projectId;
  final PickerSource source;
  final bool multi;
  final String title;
  final List<PickerChoice> initial;
  @override
  State<ChoicePickerSheet> createState() => _ChoicePickerSheetState();
}

class _ChoicePickerSheetState extends State<ChoicePickerSheet> {
  late final TextEditingController _search;
  late final RecordController _records;
  late List<PickerChoice> _selected;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController();
    _selected = [...widget.initial];
    _records = RecordController(_loader(''));
    unawaited(_records.refresh());
  }

  RecordLoader _loader(String query) {
    final path = switch (widget.source) {
      PickerSource.labels => ['projects', '${widget.projectId}', 'labels'],
      PickerSource.members => ['projects', '${widget.projectId}', 'members', 'all'],
      PickerSource.branches => ['projects', '${widget.projectId}', 'repository', 'branches'],
    };
    final key = widget.source == PickerSource.members ? 'query' : 'search';
    return (next) => widget.api.records(path, query: {if (query.isNotEmpty) key: query}, next: next);
  }

  void _onSearch(String value) {
    setState(() {});
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _records.loader = _loader(value.trim());
      unawaited(_records.refresh());
    });
  }

  PickerChoice _fromRecord(Json item) => switch (widget.source) {
    PickerSource.labels => PickerChoice(
      id: valueText(item, 'name'),
      name: valueText(item, 'name'),
      color: valueText(item, 'color').isEmpty ? null : valueText(item, 'color'),
    ),
    PickerSource.members => PickerChoice(
      id: '${valueInt(item, 'id')}',
      name: valueText(item, 'name').isEmpty ? valueText(item, 'username') : valueText(item, 'name'),
      username: valueText(item, 'username'),
    ),
    PickerSource.branches => PickerChoice(id: valueText(item, 'name'), name: valueText(item, 'name')),
  };

  void _toggle(PickerChoice choice) {
    if (choice.id.isEmpty) return;
    final index = _selected.indexWhere((item) => item.id == choice.id);
    setState(() {
      if (widget.multi) {
        if (index >= 0) {
          _selected.removeAt(index);
        } else {
          _selected.add(choice);
        }
      } else {
        _selected = index >= 0 ? [] : [choice];
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _search.dispose();
    _records.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
        child: Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: TextField(
          key: const ValueKey('picker-search'),
          controller: _search,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(hintText: '搜尋', prefixIcon: Icon(Icons.search)),
          onChanged: _onSearch,
        ),
      ),
      Expanded(child: ListenableBuilder(listenable: _records, builder: (context, _) {
        final items = _records.items.map(_fromRecord).where((item) => item.name.isNotEmpty).toList();
        final loadedIds = <String>{for (final item in items) item.id};
        final pinned = [
          for (final choice in _selected)
            if (!loadedIds.contains(choice.id)) choice,
        ];
        // Loaded rows only. A synthetic label is not on the server, so the
        // create row stays available and can clear that selection. Choices
        // missing from this page stay visible under 已選擇.
        final exact = query.isNotEmpty && items.any((item) => item.name == query);
        final showCreate = widget.source == PickerSource.labels && query.isNotEmpty && !exact;
        final empty = !_records.loading && items.isEmpty && _records.error == null && !showCreate;
        return ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.manual,
          children: [
            if (pinned.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Text('已選擇'),
              ),
              for (final choice in pinned) _row(choice),
            ],
            if (_records.loading && _records.items.isEmpty) const ListSkeleton(),
            if (showCreate) _row(PickerChoice(id: query, name: query), create: true),
            if (empty) const EmptyState('沒有符合的項目'),
            for (final item in items) _row(item),
            if (_records.error != null) FailureNotice(
              _records.error!,
              account: widget.account,
              resourceLabel: widget.title,
              onSwitchAccount: endSessionFrom(context),
              onRetry: () { unawaited(_records.retry()); },
            ),
            if (_records.next != null) TextButton.icon(
              onPressed: _records.loadingMore || _records.loading ? null : () { unawaited(_records.more()); },
              icon: const Icon(Icons.expand_more),
              label: Text(_records.loadingMore ? '載入中…' : '載入更多'),
            ),
          ],
        );
      })),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: FilledButton(
          key: const Key('picker-done'),
          onPressed: () => Navigator.pop(context, List<PickerChoice>.unmodifiable(_selected)),
          child: const Text('完成'),
        ),
      ),
    ]);
  }

  Widget _row(PickerChoice choice, {bool create = false}) {
    final selected = _selected.any((item) => item.id == choice.id);
    return Semantics(
      button: true,
      selected: widget.multi ? selected : null,
      checked: widget.multi ? null : selected,
      inMutuallyExclusiveGroup: widget.multi ? null : true,
      child: InkWell(
        key: ValueKey(create ? 'picker-create-label' : 'picker-row-${choice.id}'),
        onTap: () => _toggle(choice),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              if (widget.multi) Padding(
                padding: const EdgeInsets.only(right: 4),
                child: ExcludeSemantics(
                  child: IgnorePointer(child: Checkbox(value: selected, onChanged: (_) {})),
                ),
              ),
              if (!widget.multi) Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ExcludeSemantics(
                  child: Icon(selected ? Icons.check_circle : Icons.circle_outlined, size: 22),
                ),
              ),
              Expanded(child: create
                ? Text('建立標籤「${choice.name}」', overflow: TextOverflow.ellipsis)
                : PickerChoiceLabel(choice, widget.source, expand: true)),
            ]),
          ),
        ),
      ),
    );
  }
}
