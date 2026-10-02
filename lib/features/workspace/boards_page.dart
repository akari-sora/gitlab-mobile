import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/board_queries.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';
import 'records_feed.dart';
import 'work_item_page.dart';

class BoardsPage extends StatefulWidget {
  const BoardsPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
  });

  final Account account;
  final GitLabApi api;
  final Project project;

  @override
  State<BoardsPage> createState() => _BoardsPageState();
}

class _BoardsPageState extends State<BoardsPage> {
  final _search = TextEditingController();
  final _pages = PageController();
  List<Json> _boards = const [];
  BoardDefinition? _board;
  ApiFailure? _error;
  bool _loading = true;
  int _columnIndex = 0;
  int _generation = 0;
  String _query = '';
  final Map<String, GlobalKey<RecordsFeedState>> _feeds = {};

  @override
  void initState() {
    super.initState();
    unawaited(_loadBoards());
  }

  @override
  void didUpdateWidget(covariant BoardsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        oldWidget.project.id != widget.project.id ||
        !identical(oldWidget.api, widget.api)) {
      _boards = const [];
      _board = null;
      _feeds.clear();
      _query = '';
      _search.clear();
      unawaited(_loadBoards());
    }
  }

  @override
  void dispose() {
    _generation++;
    _search.dispose();
    _pages.dispose();
    super.dispose();
  }

  Future<List<Json>> _allPages(List<String> path, {int maxPages = 4}) async {
    final values = <Json>[];
    Uri? next;
    final seen = <String>{};
    for (var page = 0; page < maxPages; page++) {
      final response = await widget.api.records(path, next: next);
      values.addAll(response.items);
      next = response.next;
      if (next == null) return values;
      if (!seen.add(next.toString())) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      if (page == maxPages - 1) {
        throw const ApiFailure(
          FailureKind.tooLarge,
          title: '看板定義超過載入上限',
          detail: '最多載入 4 頁看板或欄位定義；未顯示不完整的看板。',
        );
      }
    }
    throw const ApiFailure(FailureKind.invalidResponse);
  }

  Future<void> _loadBoards({int? preferredId}) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final boards = await _allPages([
        'projects',
        '${widget.project.id}',
        'boards',
      ]);
      if (!mounted || generation != _generation) return;
      _boards = List.unmodifiable(boards);
      if (boards.isEmpty) {
        setState(() {
          _board = null;
          _loading = false;
        });
        return;
      }
      final selected = boards.cast<Json?>().firstWhere(
        (value) => value?['id'] == (preferredId ?? _board?.id),
        orElse: () => boards.first,
      )!;
      await _loadBoard(requiredInt(selected, 'id'), generation: generation);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = safeFailure(error);
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadBoard(int id, {int? generation}) async {
    final activeGeneration = generation ?? ++_generation;
    if (generation == null) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait<Object>([
        widget.api.record([
          'projects',
          '${widget.project.id}',
          'boards',
          '$id',
        ]),
        _allPages([
          'projects',
          '${widget.project.id}',
          'boards',
          '$id',
          'lists',
        ]),
      ]);
      if (!mounted || activeGeneration != _generation) return;
      final definition = BoardDefinition.fromJson(
        results[0] as Json,
        results[1] as List<Json>,
      );
      _feeds.clear();
      setState(() {
        _board = definition;
        _columnIndex = 0;
        _loading = false;
      });
      if (_pages.hasClients) _pages.jumpToPage(0);
    } catch (error) {
      if (mounted && activeGeneration == _generation) {
        setState(() {
          _error = safeFailure(error);
          _loading = false;
        });
      }
    }
  }

  void _submitSearch(String value) {
    final next = value.trim();
    if (next == _query) return;
    setState(() => _query = next);
  }

  void _showColumn(int index) {
    if (_columnIndex == index) return;
    setState(() => _columnIndex = index);
    _pages.jumpToPage(index);
  }

  Iterable<RecordsFeedState> get _mountedFeeds sync* {
    final seen = <RecordsFeedState>{};
    for (final key in _feeds.values) {
      final state = key.currentState;
      if (state != null && seen.add(state)) yield state;
    }
  }

  void _removeIssueFromMountedFeeds(int iid) {
    for (final feed in _mountedFeeds) {
      feed.removeItem('$iid');
    }
  }

  Future<void> _refreshMountedFeeds() async {
    final feeds = _mountedFeeds.toList(growable: false);
    await Future.wait(feeds.map((feed) => feed.refresh()));
  }

  void _openIssue(BoardColumn column, Json issue) {
    final iid = requiredInt(issue, 'iid');
    unawaited(
      Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => WorkItemPage(
            account: widget.account,
            api: widget.api,
            project: widget.project,
            resource: 'issues',
            iid: iid,
            onDeleted: () {
              _removeIssueFromMountedFeeds(iid);
              if (mounted) Navigator.pop(context);
            },
            onMutated: (_) => unawaited(_refreshMountedFeeds()),
          ),
        ),
      ),
    );
  }

  Widget _controls(BoardDefinition board) {
    final gutter = feedGutter(context);
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<int>(
              key: const ValueKey('board-selector'),
              initialValue: board.id,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '看板',
                prefixIcon: Icon(Icons.view_kanban_outlined),
              ),
              items: [
                for (final value in _boards)
                  DropdownMenuItem(
                    value: requiredInt(value, 'id'),
                    child: Text(
                      valueText(value, 'name', '看板 ${valueInt(value, 'id')}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _loading
                  ? null
                  : (value) {
                      if (value != null && value != board.id) {
                        unawaited(_loadBoard(value));
                      }
                    },
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _search,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜尋看板議題',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _search,
                  builder: (context, value, _) => value.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(
                          tooltip: '清除搜尋',
                          onPressed: () {
                            _search.clear();
                            _submitSearch('');
                          },
                          icon: const Icon(Icons.clear),
                        ),
                ),
              ),
              onSubmitted: _submitSearch,
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final (index, column) in board.columns.indexed) ...[
                    ChoiceChip(
                      key: ValueKey('board-column-${column.key}'),
                      selected: index == _columnIndex,
                      showCheckmark: false,
                      avatar: Icon(_columnIcon(column.kind), size: 18),
                      label: Text(column.title),
                      onSelected: (_) => _showColumn(index),
                    ),
                    if (index != board.columns.length - 1)
                      const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _column(BoardDefinition board, BoardColumn column) {
    final query = boardIssueQuery(board, column, search: _query);
    if (!query.supported) {
      return ListView(
        key: PageStorageKey(
          '${widget.account.key}/${widget.project.id}/${board.id}/${column.key}',
        ),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          feedGutter(context),
          24,
          feedGutter(context),
          24,
        ),
        children: [
          EmptyState(
            '無法載入「${column.title}」',
            icon: Icons.do_not_disturb_alt_outlined,
            detail: query.reason,
          ),
        ],
      );
    }
    final key = _feeds.putIfAbsent(column.key, GlobalKey<RecordsFeedState>.new);
    return RecordsFeed(
      key: key,
      identity:
          '${widget.account.key}/${widget.project.id}/${board.id}/${column.key}/$_query',
      storageId:
          'board/${widget.account.key}/${widget.project.id}/${board.id}/${column.key}',
      account: widget.account,
      resourceLabel: '${widget.project.path} · ${board.name} · ${column.title}',
      onSwitchAccount: endSessionFrom(context),
      empty: _query.isEmpty
          ? '「${column.title}」目前沒有議題'
          : '「${column.title}」沒有符合「$_query」的議題',
      emptyDetail: _query.isEmpty ? '下拉即可重新整理此欄。' : '搜尋只會在送出後套用，請調整關鍵字再試一次。',
      emptyIcon: _columnIcon(column.kind),
      grouped: true,
      visible: column.kind == BoardColumnKind.open
          ? (issue) => boardOpenIssueMatches(board, issue)
          : null,
      load: (next) => widget.api.records(
        ['projects', '${widget.project.id}', 'issues'],
        query: query.parameters,
        next: next,
      ),
      itemBuilder: (context, issue) => workItemCard(
        context,
        issue,
        mr: false,
        onTap: () => _openIssue(column, issue),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const ListSkeleton();
    final error = _error;
    if (error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          FailureNotice(
            error,
            account: widget.account,
            resourceLabel: '${widget.project.path} · 議題看板',
            onSwitchAccount: endSessionFrom(context),
            onRetry: _loadBoards,
          ),
        ],
      );
    }
    final board = _board;
    if (board == null) {
      return RefreshIndicator(
        onRefresh: _loadBoards,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            Padding(
              padding: EdgeInsets.only(top: 48),
              child: EmptyState(
                '這個專案沒有議題看板',
                icon: Icons.view_kanban_outlined,
                detail: '建立看板後，下拉即可重新載入。',
              ),
            ),
          ],
        ),
      );
    }
    if (board.columns.isEmpty) {
      return Column(
        children: [
          _controls(board),
          const Expanded(
            child: EmptyState(
              '這個看板沒有可見欄位',
              icon: Icons.view_column_outlined,
              detail: 'Open 與 Closed 已隱藏，且 GitLab 沒有回傳其他清單。',
            ),
          ),
        ],
      );
    }
    return Column(
      children: [
        _controls(board),
        Expanded(
          child: PageView.builder(
            controller: _pages,
            itemCount: board.columns.length,
            onPageChanged: (index) => setState(() => _columnIndex = index),
            itemBuilder: (context, index) =>
                _column(board, board.columns[index]),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('議題看板'),
      actions: [
        IconButton(
          tooltip: '重新整理看板',
          onPressed: _loading
              ? null
              : () => unawaited(_loadBoards(preferredId: _board?.id)),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: _body(),
  );
}

IconData _columnIcon(BoardColumnKind kind) => switch (kind) {
  BoardColumnKind.open => Icons.inbox_outlined,
  BoardColumnKind.closed => Icons.check_circle_outline,
  BoardColumnKind.label => Icons.label_outline,
  BoardColumnKind.assignee => Icons.person_outline,
  BoardColumnKind.milestone => Icons.tour_outlined,
  BoardColumnKind.unsupported => Icons.do_not_disturb_alt_outlined,
};
