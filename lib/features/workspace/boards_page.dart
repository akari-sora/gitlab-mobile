import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/board_queries.dart';
import '../../core/board_mutations.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../shared/workspace_ui.dart';
import 'records_feed.dart';
import 'work_item_page.dart';

import '../../l10n/l10n.dart';
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
  bool _writing = false;
  int _columnIndex = 0;
  int _generation = 0;
  String _query = '';
  final Map<String, GlobalKey<RecordsFeedState>> _feeds = {};
  final Set<Route<dynamic>> _ownedRoutes = {};
  NavigatorState? _navigator;

  BoardColumn? _columnWithKey(BoardDefinition board, String key) {
    for (final column in board.columns) {
      if (column.key == key) return column;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadBoards());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
  }

  void _ownRoute(Route<dynamic> route) {
    if (!_ownedRoutes.add(route)) return;
    unawaited(route.popped.then((_) => _ownedRoutes.remove(route)));
  }

  void _dismissRoutes() {
    final navigator = _navigator;
    final routes = _ownedRoutes.toList(growable: false);
    _ownedRoutes.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator == null || !navigator.mounted) return;
      for (final route in routes) {
        if (route.isActive) navigator.removeRoute(route);
      }
    });
  }

  @override
  void didUpdateWidget(covariant BoardsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.account.key != widget.account.key ||
        oldWidget.project.id != widget.project.id ||
        !identical(oldWidget.api, widget.api)) {
      _generation++;
      _dismissRoutes();
      _writing = false;
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
    _dismissRoutes();
    _search.dispose();
    _pages.dispose();
    super.dispose();
  }

  Future<List<Json>> _allPagesFor(
    GitLabApi api,
    List<String> path, {
    int maxPages = 4,
  }) async {
    final values = <Json>[];
    Uri? next;
    final seen = <String>{};
    for (var page = 0; page < maxPages; page++) {
      final response = await api.records(path, next: next);
      values.addAll(response.items);
      next = response.next;
      if (next == null) return values;
      if (!seen.add(next.toString())) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      if (page == maxPages - 1) {
        throw ApiFailure(
          FailureKind.tooLarge,
          title: l10n.boardDefinitionsOverLimit,
          detail: l10n.boardDefinitionsPageCap,
        );
      }
    }
    throw const ApiFailure(FailureKind.invalidResponse);
  }

  Future<List<Json>> _allPages(List<String> path, {int maxPages = 4}) =>
      _allPagesFor(widget.api, path, maxPages: maxPages);

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

  List<String> _boardPathFor(int projectId, [int? boardId]) => [
    'projects',
    '$projectId',
    'boards',
    if (boardId != null) '$boardId',
  ];

  Future<BoardDefinition> _freshBoardFor(
    GitLabApi api,
    int projectId,
    int boardId,
  ) async {
    final results = await Future.wait<Object>([
      api.record(_boardPathFor(projectId, boardId)),
      _allPagesFor(api, [..._boardPathFor(projectId, boardId), 'lists']),
    ]);
    return BoardDefinition.fromJson(
      results[0] as Json,
      results[1] as List<Json>,
    );
  }

  Future<void> _showMoveSheet(BoardColumn source, Json issue) async {
    final board = _board;
    if (board == null || _writing) return;
    final generation = _generation;
    final api = widget.api;
    final projectId = widget.project.id;
    final targets = board.columns
        .where(boardColumnAcceptsDirectMove)
        .where((column) => column.key != source.key)
        .toList(growable: false);
    if (!boardColumnAcceptsDirectMove(source) || targets.isEmpty) {
      showFailure(
        context,
        ApiFailure(
          FailureKind.unsupported,
          title: l10n.noDirectMoveDestination,
          detail: l10n.directMoveOpenClosedLabelOnly,
        ),
      );
      return;
    }
    final target = await showModalBottomSheet<BoardColumn>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final route = ModalRoute.of(context);
        if (route != null) _ownRoute(route);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text(l10n.moveIssue),
                subtitle: Text(l10n.keepLabelsOutsideBoardLists),
              ),
              for (final column in targets)
                ListTile(
                  key: ValueKey('move-issue-to-${column.key}'),
                  leading: Icon(_columnIcon(column.kind)),
                  title: Text(column.title),
                  onTap: () => Navigator.pop(context, column),
                ),
            ],
          ),
        );
      },
    );
    if (target == null ||
        !mounted ||
        generation != _generation ||
        !identical(widget.api, api) ||
        widget.project.id != projectId) {
      return;
    }
    await _moveIssue(
      source.key,
      target.key,
      requiredInt(issue, 'iid'),
      api: api,
      projectId: projectId,
      ownerGeneration: generation,
    );
  }

  Future<void> _moveIssue(
    String sourceKey,
    String targetKey,
    int iid, {
    required GitLabApi api,
    required int projectId,
    required int ownerGeneration,
  }) async {
    if (_writing) return;
    final generation = ownerGeneration;
    final boardId = _board?.id;
    if (boardId == null) return;
    setState(() => _writing = true);
    try {
      final freshBoard = await _freshBoardFor(api, projectId, boardId);
      if (!mounted || generation != _generation) return;
      final source = _columnWithKey(freshBoard, sourceKey);
      final target = _columnWithKey(freshBoard, targetKey);
      if (source == null || target == null) {
        throw ApiFailure(
          FailureKind.conflict,
          title: l10n.boardListsHaveChanged,
          detail: l10n.refreshBoardBeforeMove,
        );
      }
      final issuePath = ['projects', '$projectId', 'issues', '$iid'];
      final freshIssue = await api.record(issuePath);
      if (!mounted || generation != _generation) return;
      final plan = planBoardIssueMove(
        board: freshBoard,
        source: source,
        target: target,
        issue: freshIssue,
      );
      await api.writeRecord('PUT', issuePath, plan.payload);
      if (!mounted || generation != _generation) return;
      final readback = await api.record(issuePath);
      if (!mounted || generation != _generation) return;
      final refreshedBoard = await _freshBoardFor(api, projectId, boardId);
      if (!mounted || generation != _generation) return;
      final refreshedTarget = _columnWithKey(refreshedBoard, targetKey);
      final refreshedSource = _columnWithKey(refreshedBoard, sourceKey);
      if (refreshedTarget == null ||
          refreshedSource == null ||
          !boardMoveReadbackMatches(
            refreshedBoard,
            refreshedSource,
            refreshedTarget,
            readback,
          )) {
        throw ApiFailure(
          FailureKind.writeUncertain,
          title: l10n.issueMoveResultUnconfirmed,
          detail: l10n.reloadMismatchTargetList,
        );
      }
      if (!mounted || generation != _generation) return;
      await _loadBoard(boardId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.movedToNamedList(refreshedTarget.title))),
        );
      }
    } catch (error) {
      if (mounted && generation == _generation) showFailure(context, error);
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<String?> _askName(String title, {String initial = ''}) async {
    var value = initial;
    return showDialog<String>(
      context: context,
      builder: (context) {
        final route = ModalRoute.of(context);
        if (route != null) _ownRoute(route);
        return AlertDialog(
          title: Text(title),
          content: TextFormField(
            key: const ValueKey('board-name-field'),
            initialValue: initial,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(labelText: l10n.nameLabel),
            onChanged: (next) => value = next,
            onFieldSubmitted: (next) {
              if (next.trim().isNotEmpty) Navigator.pop(context, next.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.cancelAction),
            ),
            FilledButton(
              onPressed: () {
                final trimmed = value.trim();
                if (trimmed.isNotEmpty) Navigator.pop(context, trimmed);
              },
              child: Text(l10n.saveAction),
            ),
          ],
        );
      },
    );
  }

  Future<bool> _confirm(String title, String detail) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) {
          final route = ModalRoute.of(context);
          if (route != null) _ownRoute(route);
          return AlertDialog(
            title: Text(title),
            content: Text(detail),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l10n.cancelAction),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l10n.confirmAction),
              ),
            ],
          );
        },
      ) ??
      false;

  Future<void> _boardWrite(Future<void> Function(int generation) action) async {
    if (_writing) return;
    final generation = _generation;
    setState(() => _writing = true);
    try {
      await action(generation);
    } catch (error) {
      if (mounted && generation == _generation) showFailure(context, error);
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _createBoard() async {
    final ownerGeneration = _generation;
    final api = widget.api;
    final projectId = widget.project.id;
    final name = await _askName(l10n.newBoard);
    if (name == null ||
        !mounted ||
        ownerGeneration != _generation ||
        !identical(widget.api, api) ||
        widget.project.id != projectId) {
      return;
    }
    await _boardWrite((generation) async {
      final created = await api.writeRecord('POST', _boardPathFor(projectId), {
        'name': name,
      });
      if (!mounted || generation != _generation) return;
      final id = requiredInt(created, 'id');
      final readback = await api.record(_boardPathFor(projectId, id));
      if (optionalString(readback, 'name') != name) {
        throw const ApiFailure(FailureKind.writeUncertain);
      }
      if (!mounted || generation != _generation) return;
      await _loadBoards(preferredId: id);
    });
  }

  Future<void> _renameBoard(BoardDefinition board) async {
    final ownerGeneration = _generation;
    final api = widget.api;
    final projectId = widget.project.id;
    final name = await _askName(l10n.renameBoard, initial: board.name);
    if (name == null ||
        name == board.name ||
        !mounted ||
        ownerGeneration != _generation ||
        !identical(widget.api, api) ||
        widget.project.id != projectId) {
      return;
    }
    await _boardWrite((generation) async {
      await api.writeRecord('PUT', _boardPathFor(projectId, board.id), {
        'name': name,
      });
      if (!mounted || generation != _generation) return;
      final readback = await api.record(_boardPathFor(projectId, board.id));
      if (optionalString(readback, 'name') != name) {
        throw const ApiFailure(FailureKind.writeUncertain);
      }
      if (!mounted || generation != _generation) return;
      await _loadBoards(preferredId: board.id);
    });
  }

  Future<void> _setSystemColumnHidden(
    BoardDefinition board, {
    required bool backlog,
    required bool hidden,
  }) async {
    final api = widget.api;
    final projectId = widget.project.id;
    final field = backlog ? 'hide_backlog_list' : 'hide_closed_list';
    await _boardWrite((generation) async {
      await api.writeRecord('PUT', _boardPathFor(projectId, board.id), {
        field: hidden,
      });
      if (!mounted || generation != _generation) return;
      final readback = await api.record(_boardPathFor(projectId, board.id));
      if (readback[field] != hidden) {
        throw const ApiFailure(FailureKind.writeUncertain);
      }
      if (!mounted || generation != _generation) return;
      await _loadBoard(board.id);
    });
  }

  Future<Json?> _chooseLabel(BoardDefinition board) async {
    final generation = _generation;
    final api = widget.api;
    final projectId = widget.project.id;
    final labels = await _allPagesFor(api, [
      'projects',
      '$projectId',
      'labels',
    ]);
    if (!mounted ||
        generation != _generation ||
        !identical(widget.api, api) ||
        widget.project.id != projectId) {
      return null;
    }
    final existing = board.columns
        .where((column) => column.kind == BoardColumnKind.label)
        .map((column) => column.label)
        .toSet();
    final available = labels
        .where((label) => !existing.contains(optionalString(label, 'name')))
        .toList(growable: false);
    if (available.isEmpty) {
      showFailure(
        context,
        ApiFailure(
          FailureKind.unsupported,
          title: l10n.noLabelListToAdd,
          detail: l10n.allProjectLabelsOnBoard,
        ),
      );
      return null;
    }
    return showDialog<Json>(
      context: context,
      builder: (context) {
        final route = ModalRoute.of(context);
        if (route != null) _ownRoute(route);
        return SimpleDialog(
          title: Text(l10n.addLabelList),
          children: [
            for (final label in available)
              SimpleDialogOption(
                key: ValueKey('add-board-label-${requiredInt(label, 'id')}'),
                onPressed: () => Navigator.pop(context, label),
                child: Text(valueText(label, 'name', 'Label')),
              ),
          ],
        );
      },
    );
  }

  Future<void> _addLabelList(BoardDefinition board) async {
    final ownerGeneration = _generation;
    final api = widget.api;
    final projectId = widget.project.id;
    Json? label;
    try {
      label = await _chooseLabel(board);
    } catch (error) {
      if (mounted) showFailure(context, error);
      return;
    }
    if (label == null ||
        !mounted ||
        ownerGeneration != _generation ||
        !identical(widget.api, api) ||
        widget.project.id != projectId) {
      return;
    }
    final labelId = requiredInt(label, 'id');
    await _boardWrite((generation) async {
      final created = await api.writeRecord(
        'POST',
        [..._boardPathFor(projectId, board.id), 'lists'],
        {'label_id': labelId},
      );
      if (!mounted || generation != _generation) return;
      final listId = requiredInt(created, 'id');
      final lists = await _allPagesFor(api, [
        ..._boardPathFor(projectId, board.id),
        'lists',
      ]);
      if (!lists.any((value) => value['id'] == listId)) {
        throw const ApiFailure(FailureKind.writeUncertain);
      }
      if (!mounted || generation != _generation) return;
      await _loadBoard(board.id);
    });
  }

  Future<void> _deleteList(BoardDefinition board, BoardColumn column) async {
    final ownerGeneration = _generation;
    final api = widget.api;
    final projectId = widget.project.id;
    final listId = column.listId;
    if (listId == null ||
        !await _confirm(l10n.deleteNamedListQuestion(column.title), l10n.issuesNotDeletedWithList)) {
      return;
    }
    if (!mounted ||
        ownerGeneration != _generation ||
        !identical(widget.api, api) ||
        widget.project.id != projectId) {
      return;
    }
    await _boardWrite((generation) async {
      await api.removeRecord([
        ..._boardPathFor(projectId, board.id),
        'lists',
        '$listId',
      ]);
      if (!mounted || generation != _generation) return;
      final lists = await _allPagesFor(api, [
        ..._boardPathFor(projectId, board.id),
        'lists',
      ]);
      if (lists.any((value) => value['id'] == listId)) {
        throw const ApiFailure(FailureKind.writeUncertain);
      }
      if (!mounted || generation != _generation) return;
      await _loadBoard(board.id);
    });
  }

  Future<void> _moveList(
    BoardDefinition board,
    BoardColumn column,
    int direction,
  ) async {
    final api = widget.api;
    final projectId = widget.project.id;
    final serverColumns = board.columns
        .where((value) => value.listId != null)
        .toList(growable: false);
    final index = serverColumns.indexWhere((value) => value.key == column.key);
    final targetIndex = index + direction;
    if (index < 0 || targetIndex < 0 || targetIndex >= serverColumns.length) {
      return;
    }
    final listId = column.listId!;
    final position = serverColumns[targetIndex].position ?? targetIndex;
    await _boardWrite((generation) async {
      await api.writeRecord(
        'PUT',
        [..._boardPathFor(projectId, board.id), 'lists', '$listId'],
        {'position': position},
      );
      if (!mounted || generation != _generation) return;
      final fresh = await _freshBoardFor(api, projectId, board.id);
      final freshColumns = fresh.columns
          .where((value) => value.listId != null)
          .toList(growable: false);
      final freshIndex = freshColumns.indexWhere(
        (value) => value.listId == listId,
      );
      if ((direction < 0 && freshIndex >= index) ||
          (direction > 0 && freshIndex <= index)) {
        throw const ApiFailure(FailureKind.writeUncertain);
      }
      if (!mounted || generation != _generation) return;
      await _loadBoard(board.id);
    });
  }

  Future<void> _deleteBoard(BoardDefinition board) async {
    final ownerGeneration = _generation;
    final api = widget.api;
    final projectId = widget.project.id;
    if (!await _confirm(l10n.deleteNamedBoardQuestion(board.name), l10n.deleteBoardKeepsIssues)) {
      return;
    }
    if (!mounted ||
        ownerGeneration != _generation ||
        !identical(widget.api, api) ||
        widget.project.id != projectId) {
      return;
    }
    await _boardWrite((generation) async {
      await api.removeRecord(_boardPathFor(projectId, board.id));
      if (!mounted || generation != _generation) return;
      final boards = await _allPagesFor(api, _boardPathFor(projectId));
      if (boards.any((value) => value['id'] == board.id)) {
        throw const ApiFailure(FailureKind.writeUncertain);
      }
      if (!mounted || generation != _generation) return;
      await _loadBoards();
    });
  }

  Future<void> _showBoardManager(BoardDefinition board) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        final route = ModalRoute.of(sheetContext);
        if (route != null) _ownRoute(route);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: Text(board.name),
                subtitle: Text(l10n.boardsAndLists),
              ),
              ListTile(
                key: const ValueKey('rename-board'),
                leading: const Icon(Icons.edit_outlined),
                title: Text(l10n.renameAction),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_renameBoard(board));
                },
              ),
              SwitchListTile(
                key: const ValueKey('show-open-column'),
                title: Text(l10n.showOpenList),
                value: !board.hideBacklogList,
                onChanged: (value) {
                  Navigator.pop(sheetContext);
                  unawaited(
                    _setSystemColumnHidden(
                      board,
                      backlog: true,
                      hidden: !value,
                    ),
                  );
                },
              ),
              SwitchListTile(
                key: const ValueKey('show-closed-column'),
                title: Text(l10n.showClosedList),
                value: !board.hideClosedList,
                onChanged: (value) {
                  Navigator.pop(sheetContext);
                  unawaited(
                    _setSystemColumnHidden(
                      board,
                      backlog: false,
                      hidden: !value,
                    ),
                  );
                },
              ),
              ListTile(
                key: const ValueKey('add-label-list'),
                leading: const Icon(Icons.add),
                title: Text(l10n.addLabelList),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_addLabelList(board));
                },
              ),
              const Divider(),
              for (final (index, column)
                  in board.columns
                      .where((value) => value.listId != null)
                      .indexed)
                ListTile(
                  key: ValueKey('manage-board-list-${column.listId}'),
                  leading: Icon(_columnIcon(column.kind)),
                  title: Text(column.title),
                  trailing: PopupMenuButton<String>(
                    tooltip: l10n.listActions,
                    onSelected: (value) {
                      Navigator.pop(sheetContext);
                      if (value == 'left') {
                        unawaited(_moveList(board, column, -1));
                      } else if (value == 'right') {
                        unawaited(_moveList(board, column, 1));
                      } else if (value == 'delete') {
                        unawaited(_deleteList(board, column));
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'left',
                        enabled: index > 0,
                        child: Text(l10n.moveLeft),
                      ),
                      PopupMenuItem(
                        value: 'right',
                        enabled:
                            index <
                            board.columns
                                    .where((value) => value.listId != null)
                                    .length -
                                1,
                        child: Text(l10n.moveRight),
                      ),
                      PopupMenuItem(value: 'delete', child: Text(l10n.deleteList)),
                    ],
                  ),
                ),
              const Divider(),
              ListTile(
                key: const ValueKey('delete-board'),
                leading: const Icon(Icons.delete_outline),
                title: Text(l10n.deleteBoard),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_deleteBoard(board));
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _openIssue(BoardColumn column, Json issue) {
    final iid = requiredInt(issue, 'iid');
    final route = MaterialPageRoute<void>(
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
    );
    _ownRoute(route);
    unawaited(Navigator.push<void>(context, route));
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
              decoration: InputDecoration(
                labelText: l10n.boardLabel,
                prefixIcon: Icon(Icons.view_kanban_outlined),
              ),
              items: [
                for (final value in _boards)
                  DropdownMenuItem(
                    value: requiredInt(value, 'id'),
                    child: Text(
                      valueText(value, 'name', l10n.boardWithValueInt(valueInt(value, 'id'))),
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
                hintText: l10n.searchBoardIssues,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _search,
                  builder: (context, value, _) => value.text.isEmpty
                      ? const SizedBox.shrink()
                      : IconButton(
                          tooltip: l10n.clearSearch,
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
            l10n.cannotLoadNamedList(column.title),
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
          ? l10n.namedListHasNoIssues(column.title)
          : l10n.namedListNoQueryMatch(column.title, _query),
      emptyDetail: _query.isEmpty ? l10n.pullToRefreshThisList : l10n.searchAppliesAfterSubmit,
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
      itemBuilder: (context, issue) => Semantics(
        button: true,
        onLongPressHint: l10n.moveToAnotherList,
        child: GestureDetector(
          onLongPress: _writing
              ? null
              : () => unawaited(_showMoveSheet(column, issue)),
          child: workItemCard(
            context,
            issue,
            mr: false,
            onTap: () => _openIssue(column, issue),
          ),
        ),
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
            resourceLabel: l10n.pathIssueBoard(widget.project.path),
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
          children: [
            Padding(
              padding: EdgeInsets.only(top: 48),
              child: EmptyState(
                l10n.projectHasNoIssueBoard,
                icon: Icons.view_kanban_outlined,
                detail: l10n.pullToReloadAfterNewBoard,
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
          Expanded(
            child: EmptyState(
              l10n.boardHasNoVisibleLists,
              icon: Icons.view_column_outlined,
              detail: l10n.openClosedHiddenNoLists,
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
      title: Text(l10n.issueBoardLabel),
      actions: [
        PopupMenuButton<String>(
          tooltip: l10n.manageBoards,
          enabled: !_loading && !_writing,
          onSelected: (value) {
            if (value == 'create') unawaited(_createBoard());
            if (value == 'manage' && _board != null) {
              unawaited(_showBoardManager(_board!));
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'create',
              child: ListTile(leading: Icon(Icons.add), title: Text(l10n.newBoard)),
            ),
            if (_board != null)
              PopupMenuItem(
                value: 'manage',
                child: ListTile(
                  leading: Icon(Icons.settings_outlined),
                  title: Text(l10n.manageCurrentBoard),
                ),
              ),
          ],
        ),
        IconButton(
          tooltip: l10n.refreshBoard,
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
