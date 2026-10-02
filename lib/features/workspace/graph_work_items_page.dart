import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_graph_models.dart';
import '../../shared/markdown_view.dart';
import '../../shared/workspace_ui.dart';

String _graphWorkItemState(String value) => switch (value.toUpperCase()) {
  'OPEN' => 'opened',
  'CLOSED' => 'closed',
  _ => value.toLowerCase(),
};

/// Formats GitLab's date-only scalars without applying a device timezone.
/// These fields describe a calendar day rather than an instant.
String workItemCalendarDate(DateTime value) =>
    '${value.year}/${value.month.toString().padLeft(2, '0')}/${value.day.toString().padLeft(2, '0')}';

/// The native GraphQL list for every work-item type enabled by the server.
/// Type names and opaque IDs are display/capability data only; they never
/// select a REST endpoint or a navigation path.
class GraphWorkItemsPage extends StatefulWidget {
  const GraphWorkItemsPage({
    super.key,
    required this.account,
    required this.api,
    required this.project,
    this.isCurrent,
    this.ownerChanges,
  });

  final Account account;
  final GitLabApi api;
  final Project project;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;

  @override
  State<GraphWorkItemsPage> createState() => _GraphWorkItemsPageState();
}

class _GraphWorkItemsPageState extends State<GraphWorkItemsPage> {
  final List<WorkItemGraphSummary> _items = [];
  final List<WorkItemTypeCapability> _types = [];
  ApiFailure? _itemsError;
  ApiFailure? _typesError;
  String? _nextItems;
  String? _nextTypes;
  GraphResourceRef? _namespace;
  bool _loadingItems = false;
  bool _loadingTypes = false;
  int _generation = 0;
  NavigatorState? _navigator;
  final Set<Route<dynamic>> _ownedRoutes = {};
  bool _ownerInvalid = false;

  bool _current(int generation) =>
      mounted &&
      generation == _generation &&
      (widget.isCurrent?.call() ?? true);

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
    unawaited(_refresh());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
  }

  @override
  void didUpdateWidget(covariant GraphWorkItemsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      oldWidget.ownerChanges?.removeListener(_ownerChanged);
      widget.ownerChanges?.addListener(_ownerChanged);
    }
    if (oldWidget.account.key != widget.account.key ||
        oldWidget.project.id != widget.project.id ||
        oldWidget.project.path != widget.project.path ||
        !identical(oldWidget.api, widget.api)) {
      _generation++;
      _dismissOwnedRoutes();
      _items.clear();
      _types.clear();
      _itemsError = null;
      _typesError = null;
      _nextItems = null;
      _nextTypes = null;
      _namespace = null;
      _loadingItems = false;
      _loadingTypes = false;
      _ownerInvalid = false;
      unawaited(_refresh());
    }
  }

  @override
  void dispose() {
    widget.ownerChanges?.removeListener(_ownerChanged);
    _generation++;
    _dismissOwnedRoutes();
    super.dispose();
  }

  void _ownerChanged() {
    if (widget.isCurrent?.call() ?? true) return;
    _generation++;
    _dismissOwnedRoutes();
    setState(() {
      _items.clear();
      _types.clear();
      _itemsError = null;
      _typesError = null;
      _nextItems = null;
      _nextTypes = null;
      _namespace = null;
      _loadingItems = false;
      _loadingTypes = false;
      _ownerInvalid = true;
    });
    final route = ModalRoute.of(context);
    final navigator = _navigator;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          navigator == null ||
          !navigator.mounted ||
          route == null ||
          !route.isActive ||
          route.isFirst) {
        return;
      }
      navigator.removeRoute(route);
    });
  }

  void _ownRoute(Route<dynamic> route) {
    if (!_ownedRoutes.add(route)) return;
    unawaited(route.popped.then((_) => _ownedRoutes.remove(route)));
  }

  void _dismissOwnedRoutes() {
    final navigator = _navigator;
    final routes = _ownedRoutes.toList(growable: false);
    _ownedRoutes.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator == null || !navigator.mounted) return;
      for (final route in routes) {
        if (!route.isActive) continue;
        navigator.popUntil(
          (candidate) => candidate == route || candidate.isFirst,
        );
        if (route.isActive) navigator.removeRoute(route);
      }
    });
  }

  Future<void> _refresh() async {
    if (_loadingItems || _loadingTypes) return;
    final generation = ++_generation;
    setState(() {
      _items.clear();
      _types.clear();
      _itemsError = null;
      _typesError = null;
      _nextItems = null;
      _nextTypes = null;
      _namespace = null;
      _loadingItems = true;
      _loadingTypes = true;
    });
    final owner = widget;
    bool current() => _current(generation);
    final results = await Future.wait<Object?>([
      owner.api
          .projectWorkItems(owner.project, isCurrent: current)
          .then<Object?>((value) => value)
          .catchError((Object error) => error),
      owner.api
          .namespaceWorkItemTypes(owner.project.path, isCurrent: current)
          .then<Object?>((value) => value)
          .catchError((Object error) => error),
    ]);
    if (!current()) return;
    setState(() {
      final itemResult = results[0];
      if (itemResult is WorkItemGraphPage) {
        _items.addAll(itemResult.items);
        _nextItems = itemResult.nextCursor;
      } else {
        final failure = safeFailure(itemResult!);
        if (failure.kind != FailureKind.cancelled) {
          _itemsError = failure;
        }
      }
      final typeResult = results[1];
      if (typeResult is WorkItemTypePage) {
        _namespace = typeResult.namespace;
        _types.addAll(typeResult.items);
        _nextTypes = typeResult.nextCursor;
      } else {
        final failure = safeFailure(typeResult!);
        if (failure.kind != FailureKind.cancelled) {
          _typesError = failure;
        }
      }
      _loadingItems = false;
      _loadingTypes = false;
    });
  }

  Future<void> _loadMoreItems() async {
    final cursor = _nextItems;
    if (cursor == null || _loadingItems) return;
    final owner = widget;
    final generation = _generation;
    setState(() => _loadingItems = true);
    try {
      final page = await owner.api.projectWorkItems(
        owner.project,
        after: cursor,
        isCurrent: () => _current(generation),
      );
      if (!_current(generation)) return;
      final knownLocations = <String, String>{
        for (final item in _items)
          '${item.project?.fullPath ?? owner.project.path}#${item.iid}':
              item.id,
      };
      final knownIdentities = <String, String>{
        for (final item in _items)
          item.id:
              '${item.project?.fullPath ?? owner.project.path}#${item.iid}',
      };
      final additions = <WorkItemGraphSummary>[];
      for (final item in page.items) {
        final location =
            '${item.project?.fullPath ?? owner.project.path}#${item.iid}';
        final existingLocation = knownIdentities[item.id];
        final existingId = knownLocations[location];
        if (existingLocation == location && existingId == item.id) {
          continue;
        }
        if (existingLocation != null || existingId != null) {
          throw const ApiFailure(FailureKind.invalidResponse);
        }
        knownIdentities[item.id] = location;
        knownLocations[location] = item.id;
        additions.add(item);
      }
      setState(() {
        _items.addAll(additions);
        _nextItems = page.nextCursor;
        _itemsError = null;
      });
    } catch (error) {
      if (!_current(generation)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) {
        setState(() => _itemsError = failure);
      }
    } finally {
      if (_current(generation)) setState(() => _loadingItems = false);
    }
  }

  Future<void> _loadMoreTypes() async {
    final cursor = _nextTypes;
    if (cursor == null || _loadingTypes) return;
    final owner = widget;
    final generation = _generation;
    setState(() => _loadingTypes = true);
    try {
      final page = await owner.api.namespaceWorkItemTypes(
        owner.project.path,
        expectedNamespaceId: _namespace?.id,
        after: cursor,
        isCurrent: () => _current(generation),
      );
      if (!_current(generation)) return;
      setState(() {
        final known = _types.map((item) => item.type.id).toSet();
        _types.addAll(page.items.where((item) => known.add(item.type.id)));
        _nextTypes = page.nextCursor;
        _typesError = null;
      });
    } catch (error) {
      if (!_current(generation)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) {
        setState(() => _typesError = failure);
      }
    } finally {
      if (_current(generation)) setState(() => _loadingTypes = false);
    }
  }

  void _open(WorkItemGraphSummary item) {
    final route = MaterialPageRoute<void>(
      builder: (_) => GraphWorkItemDetailPage.project(
        account: widget.account,
        api: widget.api,
        project: widget.project,
        iid: item.iid,
        isCurrent: widget.isCurrent,
        ownerChanges: widget.ownerChanges,
      ),
    );
    _ownRoute(route);
    unawaited(Navigator.of(context).push(route));
  }

  Widget _capabilities(BuildContext context) {
    if (_loadingTypes && _types.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Expanded(child: Text('讀取此專案可用的工作項目類型…')),
            ],
          ),
        ),
      );
    }
    if (_typesError != null && _types.isEmpty) {
      return FailureNotice(
        _typesError!,
        account: widget.account,
        resourceLabel: '${widget.project.path} · 工作項目類型',
        onRetry: _refresh,
        onSwitchAccount: endSessionFrom(context),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('伺服器提供的類型', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (_types.isEmpty)
              Text(
                '此 namespace 沒有回傳可用類型。',
                style: Theme.of(context).textTheme.bodySmall,
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final capability in _types)
                    Chip(
                      avatar: Icon(
                        capability.enabled
                            ? Icons.check_circle_outline
                            : Icons.block,
                        size: 17,
                      ),
                      label: Text(
                        '${capability.type.name}${capability.enabled ? '' : '（未啟用）'}',
                      ),
                    ),
                ],
              ),
            if (_typesError != null) ...[
              const SizedBox(height: 8),
              Text(
                '後續類型載入失敗；目前只顯示已取得的資料。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (_nextTypes != null) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: _loadingTypes ? null : _loadMoreTypes,
                icon: _loadingTypes
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.expand_more),
                label: const Text('載入更多類型'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _ownerInvalid
      ? const Scaffold(
          body: SafeArea(child: Center(child: Text('帳號已切換，工作項目頁面已關閉。'))),
        )
      : Scaffold(
          appBar: AppBar(
            title: const Text('工作項目'),
            actions: [
              IconButton(
                onPressed: _loadingItems || _loadingTypes ? null : _refresh,
                tooltip: '重新整理',
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: gestureSafe(
            RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                key: const PageStorageKey('graph-work-items-list'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.fromLTRB(
                  feedGutter(context),
                  12,
                  feedGutter(context),
                  24,
                ),
                children: [
                  Text(
                    widget.project.path,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  _capabilities(context),
                  const SizedBox(height: 10),
                  if (_loadingItems && _items.isEmpty)
                    const ListSkeleton()
                  else if (_itemsError != null && _items.isEmpty)
                    FailureNotice(
                      _itemsError!,
                      account: widget.account,
                      resourceLabel: '${widget.project.path} · 工作項目',
                      onRetry: _refresh,
                      onSwitchAccount: endSessionFrom(context),
                    )
                  else if (_items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 44),
                      child: Column(
                        children: [
                          Icon(Icons.workspaces_outline, size: 38),
                          SizedBox(height: 10),
                          Text('沒有可顯示的工作項目'),
                        ],
                      ),
                    )
                  else ...[
                    for (final item in _items)
                      EntityCard(
                        leading: const Icon(Icons.workspaces_outline),
                        title: Text(item.title),
                        subtitle: Text('${item.type.name} · #${item.iid}'),
                        meta: [
                          StatusBadge(_graphWorkItemState(item.state)),
                          MetaChip(
                            relativeDate(item.updatedAt.toIso8601String()),
                            icon: Icons.schedule_outlined,
                          ),
                        ],
                        onTap: () => _open(item),
                      ),
                    if (_itemsError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: FailureNotice(
                          _itemsError!,
                          account: widget.account,
                          resourceLabel: '${widget.project.path} · 更多工作項目',
                          onRetry: _loadMoreItems,
                          onSwitchAccount: endSessionFrom(context),
                        ),
                      ),
                    if (_nextItems != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: OutlinedButton.icon(
                          onPressed: _loadingItems ? null : _loadMoreItems,
                          icon: _loadingItems
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.expand_more),
                          label: const Text('載入更多工作項目'),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        );
}

class GraphWorkItemDetailPage extends StatefulWidget {
  GraphWorkItemDetailPage.project({
    super.key,
    required this.account,
    required this.api,
    required Project project,
    required this.iid,
    this.isCurrent,
    this.ownerChanges,
  }) : project = project,
       namespacePath = project.path,
       expectedNamespaceId = null;

  const GraphWorkItemDetailPage.namespace({
    super.key,
    required this.account,
    required this.api,
    required this.namespacePath,
    required this.iid,
    this.expectedNamespaceId,
    this.isCurrent,
    this.ownerChanges,
  }) : project = null;

  final Account account;
  final GitLabApi api;
  final Project? project;
  final String namespacePath;
  final String? expectedNamespaceId;
  final int iid;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;

  @override
  State<GraphWorkItemDetailPage> createState() =>
      _GraphWorkItemDetailPageState();
}

class _GraphWorkItemDetailPageState extends State<GraphWorkItemDetailPage> {
  WorkItemGraphDetail? _detail;
  ApiFailure? _error;
  bool _loading = false;
  int _generation = 0;
  NavigatorState? _navigator;
  final Set<Route<dynamic>> _ownedRoutes = {};
  bool _ownerInvalid = false;

  bool _current(int generation) =>
      mounted &&
      generation == _generation &&
      (widget.isCurrent?.call() ?? true);

  @override
  void initState() {
    super.initState();
    widget.ownerChanges?.addListener(_ownerChanged);
    unawaited(_load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
  }

  @override
  void didUpdateWidget(covariant GraphWorkItemDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ownerChanges, widget.ownerChanges)) {
      oldWidget.ownerChanges?.removeListener(_ownerChanged);
      widget.ownerChanges?.addListener(_ownerChanged);
    }
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.project?.id != widget.project?.id ||
        oldWidget.namespacePath != widget.namespacePath ||
        oldWidget.expectedNamespaceId != widget.expectedNamespaceId ||
        oldWidget.iid != widget.iid ||
        !identical(oldWidget.isCurrent, widget.isCurrent)) {
      _generation++;
      _detail = null;
      _error = null;
      _loading = false;
      _ownerInvalid = false;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    widget.ownerChanges?.removeListener(_ownerChanged);
    _generation++;
    _dismissOwnedRoutes();
    super.dispose();
  }

  void _ownerChanged() {
    if (widget.isCurrent?.call() ?? true) return;
    _generation++;
    _dismissOwnedRoutes();
    setState(() {
      _detail = null;
      _error = null;
      _loading = false;
      _ownerInvalid = true;
    });
    final route = ModalRoute.of(context);
    final navigator = _navigator;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          navigator == null ||
          !navigator.mounted ||
          route == null ||
          !route.isActive ||
          route.isFirst) {
        return;
      }
      navigator.removeRoute(route);
    });
  }

  void _ownRoute(Route<dynamic> route) {
    if (!_ownedRoutes.add(route)) return;
    unawaited(route.popped.then((_) => _ownedRoutes.remove(route)));
  }

  void _dismissOwnedRoutes() {
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

  Future<void> _load() async {
    if (_loading || !_current(_generation)) return;
    final owner = widget;
    final generation = _generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = owner.project == null
          ? await owner.api.namespaceWorkItem(
              owner.namespacePath,
              owner.iid,
              expectedNamespaceId: owner.expectedNamespaceId,
              isCurrent: () => _current(generation),
            )
          : await owner.api.projectWorkItem(
              owner.project!,
              owner.iid,
              isCurrent: () => _current(generation),
            );
      if (!_current(generation)) return;
      setState(() => _detail = detail);
    } catch (error) {
      if (!_current(generation)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) {
        setState(() => _error = failure);
      }
    } finally {
      if (_current(generation)) setState(() => _loading = false);
    }
  }

  String _instantDate(DateTime value) {
    final local = value.toLocal();
    return '${local.year}/${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')}';
  }

  Color? _color(String raw) {
    final value = raw.replaceFirst('#', '');
    final parsed = int.tryParse(
      value.length == 6 ? 'FF$value' : value,
      radix: 16,
    );
    return parsed == null ? null : Color(parsed);
  }

  Future<void> _openHierarchy(WorkItemHierarchyEntry item) async {
    final generation = _generation;
    final namespace = item.namespace;
    if (namespace != null) {
      _pushHierarchy(
        GraphWorkItemDetailPage.namespace(
          account: widget.account,
          api: widget.api,
          namespacePath: namespace.fullPath,
          expectedNamespaceId: namespace.id,
          iid: item.iid,
          isCurrent: widget.isCurrent,
          ownerChanges: widget.ownerChanges,
        ),
      );
      return;
    }
    final projectRef = item.project;
    if (projectRef == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('伺服器沒有提供這個關聯項目的 namespace，無法安全開啟。')),
      );
      return;
    }
    try {
      final project = await widget.api.project(projectRef.fullPath);
      if (!_current(generation)) return;
      final match = RegExp(
        r'^gid://gitlab/Project/([1-9][0-9]*)$',
      ).firstMatch(projectRef.id);
      if (match == null ||
          int.parse(match.group(1)!) != project.id ||
          project.path != projectRef.fullPath) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      _pushHierarchy(
        GraphWorkItemDetailPage.project(
          account: widget.account,
          api: widget.api,
          project: project,
          iid: item.iid,
          isCurrent: widget.isCurrent,
          ownerChanges: widget.ownerChanges,
        ),
      );
    } catch (error) {
      if (mounted && _current(generation)) {
        showFailure(context, error);
      }
    }
  }

  void _pushHierarchy(Widget page) {
    if (!_current(_generation)) return;
    final route = MaterialPageRoute<void>(builder: (_) => page);
    _ownRoute(route);
    unawaited(Navigator.of(context).push(route));
  }

  Widget _section(BuildContext context, String title, Widget child) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          child,
        ],
      ),
    ),
  );

  Widget _body(BuildContext context, WorkItemGraphDetail detail) {
    final summary = detail.summary;
    final description =
        detail.descriptionWidget?.description ?? detail.description;
    final assignees = detail.assignees?.assignees;
    final labels = detail.labels?.labels;
    final hierarchy = detail.hierarchy;
    final dates = detail.dates;
    final project = widget.project;
    return ListView(
      padding: EdgeInsets.fromLTRB(
        feedGutter(context),
        12,
        feedGutter(context),
        28,
      ),
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 6,
          children: [
            StatusBadge(_graphWorkItemState(summary.state)),
            MetaChip(summary.type.name, icon: Icons.category_outlined),
            MetaChip('#${summary.iid}', mono: true),
          ],
        ),
        const SizedBox(height: 12),
        SelectionArea(
          child: Text(
            summary.title,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '建立於 ${_instantDate(summary.createdAt)} · 更新於 ${_instantDate(summary.updatedAt)}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 14),
        if (description != null && description.trim().isNotEmpty)
          _section(
            context,
            '說明',
            MarkdownView(
              description,
              account: widget.account,
              api: project == null ? null : widget.api,
              projectId: project?.id,
              projectWeb: project == null
                  ? null
                  : widget.account.instance.projectWeb(project.path),
              projectPath: project?.path,
              base: project == null
                  ? null
                  : widget.account.instance.projectWeb(project.path),
            ),
          )
        else if (detail.descriptionWidget != null)
          _section(context, '說明', const Text('沒有說明')),
        if (assignees != null)
          _section(
            context,
            '負責人',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (assignees.items.isEmpty)
                  const Text('尚未指派')
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final person in assignees.items)
                        Chip(
                          avatar: Monogram(
                            person.name.isEmpty ? person.username : person.name,
                            size: 24,
                          ),
                          label: Text(
                            person.name.isEmpty
                                ? '@${person.username}'
                                : '${person.name} · @${person.username}',
                          ),
                        ),
                    ],
                  ),
                if (assignees.isPartial)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('只顯示前 20 位負責人。'),
                  ),
              ],
            ),
          ),
        if (detail.assignees != null && assignees == null)
          _section(context, '負責人', const Text('此伺服器未回傳負責人清單。')),
        if (labels != null)
          _section(
            context,
            '標籤',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (labels.items.isEmpty)
                  const Text('沒有標籤')
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final label in labels.items)
                        Chip(
                          avatar: CircleAvatar(
                            backgroundColor: _color(label.color),
                            radius: 7,
                          ),
                          label: Text(label.title),
                        ),
                    ],
                  ),
                if (labels.isPartial)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('只顯示前 50 個標籤。'),
                  ),
              ],
            ),
          ),
        if (detail.labels != null && labels == null)
          _section(context, '標籤', const Text('此伺服器未回傳標籤清單。')),
        if (hierarchy != null)
          _section(
            context,
            '階層',
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hierarchy.parent != null) ...[
                  Text('上層項目', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  _HierarchyTile(
                    item: hierarchy.parent!,
                    onTap: () => unawaited(_openHierarchy(hierarchy.parent!)),
                  ),
                ] else if (hierarchy.hasParent == true)
                  const Text('伺服器指出有上層項目，但未提供可開啟的資料。'),
                if (hierarchy.children != null) ...[
                  if (hierarchy.parent != null) const Divider(height: 24),
                  Text('子項目', style: Theme.of(context).textTheme.labelLarge),
                  if (hierarchy.children!.items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('沒有子項目'),
                    ),
                  for (final child in hierarchy.children!.items)
                    _HierarchyTile(
                      item: child,
                      onTap: () => unawaited(_openHierarchy(child)),
                    ),
                  if (hierarchy.children!.isPartial)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('只顯示前 20 個子項目；請在 GitLab 查看完整清單。'),
                    ),
                ] else if (hierarchy.hasChildren == true)
                  const Text('伺服器指出有子項目，但未回傳清單。'),
              ],
            ),
          ),
        if (dates != null)
          _section(
            context,
            '日期',
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                if (dates.startDate != null)
                  MetaChip(
                    '開始 ${workItemCalendarDate(dates.startDate!)}',
                    icon: Icons.play_arrow_outlined,
                  ),
                if (dates.dueDate != null)
                  MetaChip(
                    '到期 ${workItemCalendarDate(dates.dueDate!)}',
                    icon: Icons.event_outlined,
                  ),
                if (dates.startDate == null && dates.dueDate == null)
                  const Text('沒有開始或到期日期'),
                if (dates.rollUp == true)
                  const MetaChip('日期由階層彙整', icon: Icons.account_tree_outlined),
              ],
            ),
          ),
        if (!detail.widgetsAvailable)
          _section(
            context,
            '詳細資料',
            const Text('此伺服器沒有回傳工作項目 widgets；未顯示的欄位不代表沒有設定。'),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_ownerInvalid || !(widget.isCurrent?.call() ?? true)) {
      return const Scaffold(
        body: SafeArea(child: Center(child: Text('帳號已切換，工作項目頁面已關閉。'))),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('工作項目 #${widget.iid}'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            tooltip: '重新整理',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: gestureSafe(switch ((_loading, _detail, _error)) {
        (true, null, _) => const ListSkeleton(),
        (_, final detail?, _) => _body(context, detail),
        (_, _, final error?) => SingleChildScrollView(
          child: FailureNotice(
            error,
            account: widget.account,
            resourceLabel: '${widget.namespacePath} · 工作項目 #${widget.iid}',
            onRetry: _load,
            onSwitchAccount: endSessionFrom(context),
          ),
        ),
        _ => const ListSkeleton(),
      }),
    );
  }
}

class _HierarchyTile extends StatelessWidget {
  const _HierarchyTile({required this.item, required this.onTap});

  final WorkItemHierarchyEntry item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.workspaces_outline),
    title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text('${item.type.name} · #${item.iid}'),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}
