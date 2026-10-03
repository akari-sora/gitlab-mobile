import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_graph_models.dart';
import '../../core/work_item_state_models.dart';
import '../../shared/markdown_view.dart';
import '../../shared/resource_share.dart';
import '../../shared/workspace_ui.dart';
import 'work_item_activity.dart';
import 'work_item_attributes.dart';
import 'work_item_state_control.dart';

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
  }) : _groupPath = null,
       embedded = false;

  const GraphWorkItemsPage.group({
    super.key,
    required this.account,
    required this.api,
    required String namespacePath,
    this.isCurrent,
    this.ownerChanges,
  }) : project = null,
       _groupPath = namespacePath,
       embedded = true;

  final Account account;
  final GitLabApi api;
  final Project? project;
  final String? _groupPath;
  String get namespacePath => project?.path ?? _groupPath!;
  final bool embedded;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;

  @override
  State<GraphWorkItemsPage> createState() => _GraphWorkItemsPageState();
}

class _GraphWorkItemsPageState extends State<GraphWorkItemsPage> {
  static const _maxItemPages = 10;
  static const _maxTypePages = 10;
  static const _maxResidentItems = 200;
  static const _maxResidentTypes = 200;

  final List<WorkItemGraphSummary> _items = [];
  final List<WorkItemTypeCapability> _types = [];
  final Set<String> _usedItemCursors = {};
  final Set<String> _usedTypeCursors = {};
  late final TextEditingController _searchController;
  late final ScrollController _searchScrollController;
  late GroupWorkItemListFilter _filter;
  GroupWorkItemListFilter? _activePageFilter;
  WorkItemTypePage? _pendingGroupTypes;
  ApiFailure? _itemsError;
  ApiFailure? _typesError;
  String? _filterNotice;
  String? _nextItems;
  String? _nextTypes;
  GraphResourceRef? _namespace;
  bool _loadingItems = false;
  bool _loadingTypes = false;
  bool _itemsLimitReached = false;
  bool _typesLimitReached = false;
  bool _selectedTypeNeedsVerification = false;
  GroupWorkItemListFilter? _typeVerificationFilter;
  int _itemPages = 0;
  int _typePages = 0;
  int _generation = 0;
  int _itemGeneration = 0;
  NavigatorState? _navigator;
  final Set<Route<dynamic>> _ownedRoutes = {};
  bool _ownerInvalid = false;

  bool _current(int generation) =>
      mounted &&
      generation == _generation &&
      (widget.isCurrent?.call() ?? true);

  bool _currentItems(int generation, int itemGeneration) =>
      _current(generation) && itemGeneration == _itemGeneration;

  GroupWorkItemListFilter get _defaultFilter => widget.project == null
      ? const GroupWorkItemListFilter(
          includeDescendants: true,
          state: GroupWorkItemState.opened,
        )
      : const GroupWorkItemListFilter();

  GroupWorkItemListFilter _withoutType(GroupWorkItemListFilter filter) =>
      GroupWorkItemListFilter(
        includeDescendants: filter.includeDescendants,
        state: filter.state,
        search: filter.search,
        sort: filter.sort,
      );

  bool _supportsSelectedType(
    GroupWorkItemListFilter filter,
    Iterable<WorkItemTypeCapability> types,
  ) {
    final typeId = filter.typeId;
    if (typeId == null) return true;
    return types.any(
      (item) =>
          item.type.id == typeId &&
          item.enabled &&
          (filter.includeDescendants || item.isGroupWorkItemType),
    );
  }

  bool _sameTypeBinding(
    GroupWorkItemListFilter left,
    GroupWorkItemListFilter right,
  ) =>
      left.includeDescendants == right.includeDescendants &&
      left.typeId == right.typeId &&
      left.typeNamespace?.id == right.typeNamespace?.id &&
      left.typeNamespace?.fullPath == right.typeNamespace?.fullPath;

  bool _replaceTypesForFilter(
    GroupWorkItemListFilter filter,
    List<WorkItemTypeCapability> items,
    String? nextCursor,
  ) {
    final typeId = filter.typeId;
    final retained = typeId == null
        ? null
        : _types.cast<WorkItemTypeCapability?>().firstWhere(
            (item) => item?.type.id == typeId,
            orElse: () => null,
          );
    final returned = typeId == null
        ? const <WorkItemTypeCapability>[]
        : items.where((item) => item.type.id == typeId).toList();
    _types
      ..clear()
      ..addAll(items);
    _selectedTypeNeedsVerification = false;
    _typeVerificationFilter = null;
    if (typeId == null || _supportsSelectedType(filter, returned)) {
      return false;
    }
    if (returned.isNotEmpty || nextCursor == null || retained == null) {
      return true;
    }
    if (_types.length < _maxResidentTypes) _types.add(retained);
    _selectedTypeNeedsVerification = true;
    _typeVerificationFilter = filter;
    return false;
  }

  @override
  void initState() {
    super.initState();
    _filter = _defaultFilter;
    _searchController = TextEditingController(text: _filter.search);
    _searchScrollController = ScrollController(keepScrollOffset: false);
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
        oldWidget.project?.id != widget.project?.id ||
        oldWidget.namespacePath != widget.namespacePath ||
        !identical(oldWidget.api, widget.api)) {
      _generation++;
      _itemGeneration++;
      _dismissOwnedRoutes();
      _filter = _defaultFilter;
      _activePageFilter = null;
      _pendingGroupTypes = null;
      _searchController.text = _filter.search;
      _items.clear();
      _types.clear();
      _itemsError = null;
      _typesError = null;
      _filterNotice = null;
      _nextItems = null;
      _nextTypes = null;
      _namespace = null;
      _usedItemCursors.clear();
      _usedTypeCursors.clear();
      _itemPages = 0;
      _typePages = 0;
      _itemsLimitReached = false;
      _typesLimitReached = false;
      _selectedTypeNeedsVerification = false;
      _typeVerificationFilter = null;
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
    _itemGeneration++;
    _dismissOwnedRoutes();
    _searchController.dispose();
    _searchScrollController.dispose();
    super.dispose();
  }

  void _ownerChanged() {
    if (widget.isCurrent?.call() ?? true) return;
    _generation++;
    _itemGeneration++;
    _dismissOwnedRoutes();
    setState(() {
      _items.clear();
      _types.clear();
      _itemsError = null;
      _typesError = null;
      _filterNotice = null;
      _nextItems = null;
      _activePageFilter = null;
      _pendingGroupTypes = null;
      _nextTypes = null;
      _namespace = null;
      _usedItemCursors.clear();
      _usedTypeCursors.clear();
      _itemPages = 0;
      _typePages = 0;
      _itemsLimitReached = false;
      _typesLimitReached = false;
      _selectedTypeNeedsVerification = false;
      _typeVerificationFilter = null;
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
    final generation = ++_generation;
    final itemGeneration = ++_itemGeneration;
    final requestFilter = _filter;
    setState(() {
      _items.clear();
      if (requestFilter.typeId == null) _types.clear();
      _itemsError = null;
      _typesError = null;
      _filterNotice = null;
      _nextItems = null;
      _activePageFilter = null;
      _pendingGroupTypes = null;
      _nextTypes = null;
      _namespace = null;
      _usedItemCursors.clear();
      _usedTypeCursors.clear();
      _itemPages = 0;
      _typePages = 0;
      _itemsLimitReached = false;
      _typesLimitReached = false;
      _selectedTypeNeedsVerification = false;
      _typeVerificationFilter = null;
      _loadingItems = true;
      _loadingTypes = true;
    });
    final owner = widget;
    bool current() => _current(generation);
    bool currentItems() => _currentItems(generation, itemGeneration);
    final results = await Future.wait<Object?>([
      (owner.project == null
              ? owner.api.groupWorkItems(
                  owner.namespacePath,
                  filter: requestFilter,
                  isCurrent: currentItems,
                )
              : owner.api.projectWorkItems(
                  owner.project!,
                  isCurrent: currentItems,
                ))
          .then<Object?>((value) => value)
          .catchError((Object error) => error),
      owner.api
          .namespaceWorkItemTypes(owner.namespacePath, isCurrent: current)
          .then<Object?>((value) => value)
          .catchError((Object error) => error),
    ]);
    if (!current()) return;
    final itemsCurrent = currentItems();
    GroupWorkItemListFilter? retryWithoutType;
    setState(() {
      final itemResult = results[0];
      GraphResourceRef? itemNamespace = _namespace;
      if (itemsCurrent && itemResult is GroupWorkItemGraphPage) {
        itemNamespace = itemResult.group;
        _namespace = itemResult.group;
        _activePageFilter = itemResult.filter;
        _items.addAll(itemResult.items);
        _nextItems = itemResult.nextCursor;
        _itemPages = 1;
      } else if (itemsCurrent && itemResult is WorkItemGraphPage) {
        _items.addAll(itemResult.items);
        _nextItems = itemResult.nextCursor;
        _itemPages = 1;
      } else if (itemsCurrent) {
        final failure = safeFailure(itemResult!);
        if (failure.kind != FailureKind.cancelled) {
          _itemsError = failure;
        }
      }
      final typeResult = results[1];
      if (typeResult is WorkItemTypePage) {
        final expectedNamespace = itemNamespace ?? _namespace;
        final matchesGroup =
            expectedNamespace == null ||
            (expectedNamespace.id == typeResult.namespace.id &&
                expectedNamespace.fullPath == typeResult.namespace.fullPath);
        if (owner.project == null && expectedNamespace == null) {
          if (!itemsCurrent && _loadingItems) {
            _pendingGroupTypes = typeResult;
          } else {
            _typesError = const ApiFailure(FailureKind.invalidResponse);
          }
        } else if (owner.project == null && !matchesGroup) {
          _typesError = const ApiFailure(FailureKind.invalidResponse);
        } else {
          _namespace = typeResult.namespace;
          _nextTypes = typeResult.nextCursor;
          _typePages = 1;
          final filterForTypes = itemsCurrent ? requestFilter : _filter;
          if (_replaceTypesForFilter(
            filterForTypes,
            typeResult.items,
            typeResult.nextCursor,
          )) {
            retryWithoutType = _withoutType(filterForTypes);
            _items.clear();
            _itemsError = null;
            _nextItems = null;
            _activePageFilter = null;
            _usedItemCursors.clear();
            _itemPages = 0;
            _itemsLimitReached = false;
          }
        }
      } else {
        final failure = safeFailure(typeResult!);
        if (failure.kind != FailureKind.cancelled) {
          _typesError = failure;
        }
      }
      if (itemsCurrent) _loadingItems = false;
      _loadingTypes = _pendingGroupTypes != null;
    });
    if (retryWithoutType != null) {
      await _refreshItems(retryWithoutType!, notice: '已選類型不再可用，已改為所有類型並重新讀取。');
    } else if (_selectedTypeNeedsVerification && _nextTypes != null) {
      await _loadMoreTypes();
    }
  }

  Future<void> _refreshItems(
    GroupWorkItemListFilter nextFilter, {
    String? notice,
  }) async {
    if (widget.project != null) return;
    final owner = widget;
    final generation = _generation;
    final itemGeneration = ++_itemGeneration;
    setState(() {
      if (!_sameTypeBinding(_filter, nextFilter)) {
        _selectedTypeNeedsVerification = false;
        _typeVerificationFilter = null;
      }
      _filter = nextFilter;
      _filterNotice = notice;
      _items.clear();
      _itemsError = null;
      _nextItems = null;
      _activePageFilter = null;
      _usedItemCursors.clear();
      _itemPages = 0;
      _itemsLimitReached = false;
      _loadingItems = true;
    });
    bool current() => _currentItems(generation, itemGeneration);
    try {
      final page = await owner.api.groupWorkItems(
        owner.namespacePath,
        expectedGroupId: _namespace?.id,
        filter: nextFilter,
        isCurrent: current,
      );
      if (!current()) return;
      if (_namespace != null &&
          (page.group.id != _namespace!.id ||
              page.group.fullPath != _namespace!.fullPath)) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      GroupWorkItemListFilter? retryWithoutType;
      setState(() {
        _namespace = page.group;
        _activePageFilter = page.filter;
        _items.addAll(page.items);
        _nextItems = page.nextCursor;
        _itemPages = 1;
        final pendingTypes = _pendingGroupTypes;
        if (pendingTypes != null) {
          _pendingGroupTypes = null;
          _loadingTypes = false;
          if (pendingTypes.namespace.id != page.group.id ||
              pendingTypes.namespace.fullPath != page.group.fullPath) {
            _typesError = const ApiFailure(FailureKind.invalidResponse);
          } else {
            _namespace = pendingTypes.namespace;
            _nextTypes = pendingTypes.nextCursor;
            _typePages = 1;
            if (_replaceTypesForFilter(
              nextFilter,
              pendingTypes.items,
              pendingTypes.nextCursor,
            )) {
              retryWithoutType = _withoutType(nextFilter);
              _items.clear();
              _nextItems = null;
              _activePageFilter = null;
              _usedItemCursors.clear();
              _itemPages = 0;
              _itemsLimitReached = false;
            }
          }
        }
        _loadingItems = false;
      });
      if (retryWithoutType != null) {
        await _refreshItems(
          retryWithoutType!,
          notice: '已選類型不再可用，已改為所有類型並重新讀取。',
        );
      } else if (_selectedTypeNeedsVerification && _nextTypes != null) {
        await _loadMoreTypes();
      }
    } catch (error) {
      if (!current()) return;
      final failure = safeFailure(error);
      setState(() {
        if (failure.kind != FailureKind.cancelled) _itemsError = failure;
        if (_pendingGroupTypes != null) {
          _pendingGroupTypes = null;
          _loadingTypes = false;
          _typesError = const ApiFailure(FailureKind.invalidResponse);
        }
        _loadingItems = false;
      });
    }
  }

  Future<void> _loadMoreItems() async {
    final cursor = _nextItems;
    if (cursor == null || _loadingItems) return;
    final atItemLimit =
        _itemPages >= _maxItemPages || _items.length >= _maxResidentItems;
    if (atItemLimit || !_usedItemCursors.add(cursor)) {
      setState(() {
        _nextItems = null;
        _itemsLimitReached = atItemLimit;
        if (!atItemLimit) {
          _itemsError = const ApiFailure(FailureKind.invalidResponse);
        }
      });
      return;
    }
    final owner = widget;
    final generation = _generation;
    final itemGeneration = _itemGeneration;
    final pageFilter = _activePageFilter;
    if (owner.project == null && pageFilter == null) return;
    setState(() => _loadingItems = true);
    try {
      final page = owner.project == null
          ? await owner.api.groupWorkItems(
              owner.namespacePath,
              expectedGroupId: _namespace?.id,
              after: cursor,
              filter: pageFilter!,
              previousFilter: pageFilter,
              isCurrent: () => _currentItems(generation, itemGeneration),
            )
          : await owner.api.projectWorkItems(
              owner.project!,
              after: cursor,
              isCurrent: () => _currentItems(generation, itemGeneration),
            );
      if (!_currentItems(generation, itemGeneration)) return;
      final pageItems = page is GroupWorkItemGraphPage
          ? page.items
          : (page as WorkItemGraphPage).items;
      if (page is GroupWorkItemGraphPage &&
          (_namespace == null ||
              page.group.id != _namespace!.id ||
              page.group.fullPath != _namespace!.fullPath)) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      if (page is GroupWorkItemGraphPage && page.filter != pageFilter) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      final knownLocations = <String, String>{
        for (final item in _items)
          '${_itemNamespace(item)}#${item.iid}': item.id,
      };
      final knownIdentities = <String, String>{
        for (final item in _items)
          item.id: '${_itemNamespace(item)}#${item.iid}',
      };
      final additions = <WorkItemGraphSummary>[];
      for (final item in pageItems) {
        final location = '${_itemNamespace(item)}#${item.iid}';
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
      if (_items.length + additions.length > _maxResidentItems) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      setState(() {
        _items.addAll(additions);
        _itemPages++;
        final serverNext = page is GroupWorkItemGraphPage
            ? page.nextCursor
            : (page as WorkItemGraphPage).nextCursor;
        final cursorLoop =
            serverNext != null && _usedItemCursors.contains(serverNext);
        _itemsLimitReached = serverNext != null && _itemPages >= _maxItemPages;
        _nextItems = _itemsLimitReached || cursorLoop ? null : serverNext;
        if (cursorLoop) {
          _itemsError = const ApiFailure(FailureKind.invalidResponse);
        } else {
          _itemsError = null;
        }
      });
    } catch (error) {
      _usedItemCursors.remove(cursor);
      if (!_currentItems(generation, itemGeneration)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) {
        setState(() => _itemsError = failure);
      }
    } finally {
      if (_currentItems(generation, itemGeneration)) {
        setState(() => _loadingItems = false);
      }
    }
  }

  Future<void> _loadMoreTypes() async {
    final cursor = _nextTypes;
    if (cursor == null || _loadingTypes) return;
    final atTypeLimit =
        _typePages >= _maxTypePages || _types.length >= _maxResidentTypes;
    if (atTypeLimit || !_usedTypeCursors.add(cursor)) {
      setState(() {
        _nextTypes = null;
        _typesLimitReached = atTypeLimit;
        if (!atTypeLimit || _selectedTypeNeedsVerification) {
          _typesError = const ApiFailure(FailureKind.invalidResponse);
        }
        _selectedTypeNeedsVerification = false;
        _typeVerificationFilter = null;
      });
      return;
    }
    final owner = widget;
    final generation = _generation;
    final verificationFilter = _typeVerificationFilter;
    setState(() => _loadingTypes = true);
    GroupWorkItemListFilter? retryWithoutType;
    var loadedPage = false;
    try {
      final page = await owner.api.namespaceWorkItemTypes(
        owner.namespacePath,
        expectedNamespaceId: _namespace?.id,
        after: cursor,
        isCurrent: () => _current(generation),
      );
      if (!_current(generation)) return;
      if (_namespace == null ||
          page.namespace.id != _namespace!.id ||
          page.namespace.fullPath != _namespace!.fullPath) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      setState(() {
        final ownsVerification =
            _selectedTypeNeedsVerification &&
            verificationFilter != null &&
            _typeVerificationFilter == verificationFilter &&
            _sameTypeBinding(_filter, verificationFilter);
        final selectedId = ownsVerification ? verificationFilter.typeId : null;
        final returnedSelected = selectedId == null
            ? const <WorkItemTypeCapability>[]
            : page.items.where((item) => item.type.id == selectedId).toList();
        final known = _types.map((item) => item.type.id).toSet();
        if (returnedSelected.isNotEmpty) {
          _types.removeWhere((item) => item.type.id == selectedId);
          known.remove(selectedId);
        }
        final additions = page.items.where((item) => known.add(item.type.id));
        _types.addAll(additions.take(_maxResidentTypes - _types.length));
        _typePages++;
        final cursorLoop =
            page.nextCursor != null &&
            _usedTypeCursors.contains(page.nextCursor);
        _typesLimitReached =
            page.nextCursor != null &&
            (_typePages >= _maxTypePages || _types.length >= _maxResidentTypes);
        _nextTypes = _typesLimitReached || cursorLoop ? null : page.nextCursor;
        if (ownsVerification && returnedSelected.isNotEmpty) {
          if (_supportsSelectedType(verificationFilter, returnedSelected)) {
            _selectedTypeNeedsVerification = false;
            _typeVerificationFilter = null;
          } else {
            retryWithoutType = _withoutType(_filter);
            _selectedTypeNeedsVerification = false;
            _typeVerificationFilter = null;
          }
        } else if (ownsVerification && page.nextCursor == null) {
          retryWithoutType = _withoutType(_filter);
          _selectedTypeNeedsVerification = false;
          _typeVerificationFilter = null;
        }
        if (cursorLoop ||
            (_typesLimitReached &&
                ownsVerification &&
                _selectedTypeNeedsVerification)) {
          _typesError = const ApiFailure(FailureKind.invalidResponse);
          _selectedTypeNeedsVerification = false;
          _typeVerificationFilter = null;
        } else {
          _typesError = null;
        }
      });
      loadedPage = true;
    } catch (error) {
      _usedTypeCursors.remove(cursor);
      if (!_current(generation)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) {
        setState(() => _typesError = failure);
      }
    } finally {
      if (_current(generation)) setState(() => _loadingTypes = false);
    }
    if (!_current(generation)) return;
    if (retryWithoutType != null) {
      await _refreshItems(retryWithoutType!, notice: '已選類型不再可用，已改為所有類型並重新讀取。');
    } else if (loadedPage &&
        _selectedTypeNeedsVerification &&
        _typeVerificationFilter == verificationFilter &&
        verificationFilter != null &&
        _sameTypeBinding(_filter, verificationFilter) &&
        _nextTypes != null) {
      await _loadMoreTypes();
    }
  }

  void _open(WorkItemGraphSummary item) {
    final project = widget.project;
    final namespace = item.namespace;
    if (project == null && namespace == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('伺服器沒有提供這個工作項目的群組位置，無法安全開啟。')),
      );
      return;
    }
    final route = MaterialPageRoute<void>(
      builder: (_) => project == null
          ? GraphWorkItemDetailPage.namespace(
              account: widget.account,
              api: widget.api,
              namespacePath: namespace!.fullPath,
              expectedNamespaceId: namespace.id,
              iid: item.iid,
              isCurrent: widget.isCurrent,
              ownerChanges: widget.ownerChanges,
            )
          : GraphWorkItemDetailPage.project(
              account: widget.account,
              api: widget.api,
              project: project,
              iid: item.iid,
              isCurrent: widget.isCurrent,
              ownerChanges: widget.ownerChanges,
            ),
    );
    _ownRoute(route);
    unawaited(Navigator.of(context).push(route));
  }

  String _itemNamespace(WorkItemGraphSummary item) =>
      item.namespace?.fullPath ??
      item.project?.fullPath ??
      widget.namespacePath;

  void _changeScope(bool includeDescendants) {
    String? typeId = _filter.typeId;
    if (!includeDescendants && typeId != null) {
      final selected = _types.where((item) => item.type.id == typeId);
      if (selected.isEmpty || !selected.first.isGroupWorkItemType) {
        typeId = null;
      }
    }
    unawaited(
      _refreshItems(
        GroupWorkItemListFilter(
          includeDescendants: includeDescendants,
          state: _filter.state,
          search: _filter.search,
          sort: _filter.sort,
          typeId: typeId,
          typeNamespace: typeId == null ? null : _filter.typeNamespace,
        ),
      ),
    );
  }

  void _changeState(GroupWorkItemState state) {
    unawaited(
      _refreshItems(
        GroupWorkItemListFilter(
          includeDescendants: _filter.includeDescendants,
          state: state,
          search: _filter.search,
          sort: _filter.sort,
          typeId: _filter.typeId,
          typeNamespace: _filter.typeNamespace,
        ),
      ),
    );
  }

  void _submitSearch() {
    final search = _searchController.text.trim();
    if (search == _filter.search) return;
    _searchController.value = TextEditingValue(
      text: search,
      selection: TextSelection.collapsed(offset: search.length),
    );
    unawaited(
      _refreshItems(
        GroupWorkItemListFilter(
          includeDescendants: _filter.includeDescendants,
          state: _filter.state,
          search: search,
          sort: _filter.sort,
          typeId: _filter.typeId,
          typeNamespace: _filter.typeNamespace,
        ),
      ),
    );
  }

  void _changeSort(GroupWorkItemSort? sort) {
    if (sort == null || sort == _filter.sort) return;
    unawaited(
      _refreshItems(
        GroupWorkItemListFilter(
          includeDescendants: _filter.includeDescendants,
          state: _filter.state,
          search: _filter.search,
          sort: sort,
          typeId: _filter.typeId,
          typeNamespace: _filter.typeNamespace,
        ),
      ),
    );
  }

  void _changeType(String? typeId) {
    if (typeId == _filter.typeId) return;
    unawaited(
      _refreshItems(
        GroupWorkItemListFilter(
          includeDescendants: _filter.includeDescendants,
          state: _filter.state,
          search: _filter.search,
          sort: _filter.sort,
          typeId: typeId,
          typeNamespace: typeId == null ? null : _namespace,
        ),
      ),
    );
  }

  Iterable<WorkItemTypeCapability> get _selectableTypes => _types.where(
    (item) =>
        item.enabled &&
        (_filter.includeDescendants || item.isGroupWorkItemType),
  );

  Widget _groupFilters(BuildContext context) {
    const stateLabels = {
      GroupWorkItemState.opened: '開啟中',
      GroupWorkItemState.closed: '已關閉',
      GroupWorkItemState.all: '全部狀態',
    };
    const sortLabels = {
      GroupWorkItemSort.createdDesc: '最新建立',
      GroupWorkItemSort.createdAsc: '最早建立',
      GroupWorkItemSort.updatedDesc: '最近更新',
      GroupWorkItemSort.updatedAsc: '最早更新',
    };
    final selectableTypes = _selectableTypes.toList(growable: false);
    final scopeLabel = _filter.includeDescendants ? '包含子群組與專案' : '僅此群組';
    return Card(
      key: const Key('group-work-item-filters'),
      child: ExpansionTile(
        key: const PageStorageKey('group-work-item-filters-expansion'),
        title: Text(scopeLabel),
        subtitle: Text(
          '${stateLabels[_filter.state]} · ${sortLabels[_filter.sort]}'
          '${_filterNotice == null ? '' : '\n$_filterNotice'}',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 176),
                      child: const Text(
                        '包含子群組與專案',
                        maxLines: 2,
                        softWrap: true,
                        textAlign: TextAlign.center,
                      ),
                    ),
                    selected: _filter.includeDescendants,
                    onSelected: (selected) {
                      if (selected) _changeScope(true);
                    },
                  ),
                  ChoiceChip(
                    label: const Text('僅此群組'),
                    selected: !_filter.includeDescendants,
                    onSelected: (selected) {
                      if (selected) _changeScope(false);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final state in GroupWorkItemState.values)
                    ChoiceChip(
                      label: Text(stateLabels[state]!),
                      selected: _filter.state == state,
                      onSelected: (selected) {
                        if (selected) _changeState(state);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('group-work-item-search'),
                      controller: _searchController,
                      scrollController: _searchScrollController,
                      textInputAction: TextInputAction.search,
                      maxLength: 256,
                      decoration: const InputDecoration(
                        labelText: '搜尋工作項目',
                        hintText: '標題或關鍵字',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onSubmitted: (_) => _submitSearch(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    onPressed: _submitSearch,
                    tooltip: '套用搜尋',
                    icon: const Icon(Icons.search),
                  ),
                  IconButton(
                    onPressed: () {
                      _searchController.clear();
                      _submitSearch();
                    },
                    tooltip: '清除搜尋',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              KeyedSubtree(
                key: const Key('group-work-item-sort'),
                child: DropdownButtonFormField<GroupWorkItemSort>(
                  key: ValueKey('group-work-item-sort-${_filter.sort}'),
                  initialValue: _filter.sort,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '排序',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final sort in GroupWorkItemSort.values)
                      DropdownMenuItem(
                        value: sort,
                        child: Text(sortLabels[sort]!),
                      ),
                  ],
                  onChanged: _changeSort,
                ),
              ),
              const SizedBox(height: 10),
              KeyedSubtree(
                key: const Key('group-work-item-type'),
                child: DropdownButtonFormField<String?>(
                  key: ValueKey(
                    'group-work-item-type-${_filter.includeDescendants}-${_filter.typeId}',
                  ),
                  initialValue: _filter.typeId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '類型',
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('所有類型'),
                    ),
                    for (final capability in selectableTypes)
                      DropdownMenuItem<String?>(
                        value: capability.type.id,
                        child: Text(capability.type.name),
                      ),
                  ],
                  onChanged: _changeType,
                ),
              ),
            ],
          ),
        ],
      ),
    );
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
              Expanded(child: Text('讀取可用的工作項目類型…')),
            ],
          ),
        ),
      );
    }
    if (_typesError != null && _types.isEmpty) {
      return FailureNotice(
        _typesError!,
        account: widget.account,
        resourceLabel: '${widget.namespacePath} · 工作項目類型',
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
                widget.project == null
                    ? '此群組目前沒有啟用可顯示的工作項目類型。'
                    : '此專案沒有回傳可用類型。',
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
              TextButton.icon(
                onPressed: _nextTypes == null ? _refresh : _loadMoreTypes,
                icon: const Icon(Icons.refresh),
                label: const Text('重試'),
              ),
            ],
            if (_typesLimitReached) ...[
              const SizedBox(height: 8),
              Text(
                '已載入類型上限；重新整理可從第一頁重新讀取。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('重新整理'),
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

  Widget _itemRow(WorkItemGraphSummary item) => EntityCard(
    leading: const Icon(Icons.workspaces_outline),
    title: Text(item.title),
    subtitle: Text(
      widget.project == null
          ? '${_itemNamespace(item)} · ${item.type.name} · #${item.iid}'
          : '${item.type.name} · #${item.iid}',
    ),
    meta: [
      StatusBadge(_graphWorkItemState(item.state)),
      MetaChip(
        relativeDate(item.updatedAt.toIso8601String()),
        icon: Icons.schedule_outlined,
      ),
    ],
    onTap: () => _open(item),
  );

  List<Widget> _footer(BuildContext context) => [
    if (_itemsError != null && _items.isNotEmpty)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: FailureNotice(
          _itemsError!,
          account: widget.account,
          resourceLabel: '${widget.namespacePath} · 更多工作項目',
          onRetry: _nextItems == null ? _refresh : _loadMoreItems,
          onSwitchAccount: endSessionFrom(context),
        ),
      ),
    if (_itemsLimitReached)
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '已載入工作項目上限；重新整理可從第一頁重新讀取。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('重新整理'),
              ),
            ],
          ),
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
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.expand_more),
          label: const Text('載入更多工作項目'),
        ),
      ),
  ];

  Widget _body(BuildContext context) {
    final gutter = feedGutter(context);
    final Widget itemSliver;
    if (_loadingItems && _items.isEmpty) {
      itemSliver = const SliverToBoxAdapter(child: ListSkeleton());
    } else if (_itemsError != null && _items.isEmpty) {
      itemSliver = SliverToBoxAdapter(
        child: FailureNotice(
          _itemsError!,
          account: widget.account,
          resourceLabel: '${widget.namespacePath} · 工作項目',
          onRetry: _refresh,
          onSwitchAccount: endSessionFrom(context),
        ),
      );
    } else if (_items.isEmpty) {
      itemSliver = const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 44),
          child: Column(
            children: [
              Icon(Icons.workspaces_outline, size: 38),
              SizedBox(height: 10),
              Text('沒有可顯示的工作項目'),
            ],
          ),
        ),
      );
    } else {
      itemSliver = SliverList.builder(
        itemCount: _items.length,
        itemBuilder: (context, index) => _itemRow(_items[index]),
      );
    }
    return gestureSafe(
      RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          key: PageStorageKey('graph-work-items-list-${widget.namespacePath}'),
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(gutter, 12, gutter, 0),
              sliver: SliverList.list(
                children: [
                  Text(
                    widget.namespacePath,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (widget.project == null) ...[
                    const SizedBox(height: 6),
                    _groupFilters(context),
                  ],
                  const SizedBox(height: 10),
                  _capabilities(context),
                  const SizedBox(height: 10),
                ],
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              sliver: itemSliver,
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 24),
              sliver: SliverList.list(children: _footer(context)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_ownerInvalid) {
      const closed = SafeArea(child: Center(child: Text('帳號已切換，工作項目頁面已關閉。')));
      return widget.embedded ? closed : const Scaffold(body: closed);
    }
    if (widget.embedded) return _body(context);
    return Scaffold(
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
      body: _body(context),
    );
  }
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
  int _detailEpoch = 0;
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
      _dismissOwnedRoutes();
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
    _detailEpoch++;
    setState(() {
      _loading = true;
      _error = null;
      _detail = null;
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

  Future<void> _applyStateSnapshot(WorkItemStateSnapshot snapshot) async {
    final generation = _generation;
    final detail = _detail;
    if (detail == null || !_current(generation)) return;
    final summary = detail.summary;
    if (snapshot.id != summary.id ||
        snapshot.iid != summary.iid ||
        snapshot.project?.id != summary.project?.id ||
        snapshot.project?.fullPath != summary.project?.fullPath ||
        snapshot.namespace?.id != summary.namespace?.id ||
        snapshot.namespace?.fullPath != summary.namespace?.fullPath ||
        snapshot.typeId != summary.type.id) {
      return;
    }
    final state = snapshot.state == WorkItemState.open ? 'OPEN' : 'CLOSED';
    if (state == summary.state &&
        snapshot.updatedAt.isAtSameMomentAs(summary.updatedAt)) {
      return;
    }
    final updatedSummary = WorkItemGraphSummary(
      id: summary.id,
      iid: summary.iid,
      title: summary.title,
      state: state,
      createdAt: summary.createdAt,
      updatedAt: snapshot.updatedAt,
      project: summary.project,
      namespace: summary.namespace,
      type: summary.type,
    );
    if (!_current(generation) || !identical(_detail, detail)) return;
    setState(() {
      _detail = WorkItemGraphDetail(
        summary: updatedSummary,
        description: detail.description,
        widgetsAvailable: detail.widgetsAvailable,
        widgetTypes: detail.widgetTypes,
        descriptionWidget: detail.descriptionWidget,
        assignees: detail.assignees,
        labels: detail.labels,
        hierarchy: detail.hierarchy,
        dates: detail.dates,
      );
    });
  }

  String _instantDate(DateTime value) {
    final local = value.toLocal();
    return '${local.year}/${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')}';
  }

  Uri _shareUri(WorkItemGraphSummary summary) {
    final project = summary.project;
    final path = project == null
        ? 'groups/${summary.namespace!.fullPath}/-/work_items/${summary.iid}'
        : '${project.fullPath}/-/work_items/${summary.iid}';
    return widget.account.instance.projectWeb(path);
  }

  Object _shareOwnerKey(WorkItemGraphSummary summary) => (
    widget.account.key,
    widget.api,
    summary.id,
    summary.project?.id,
    summary.project?.fullPath,
    summary.namespace?.id,
    summary.namespace?.fullPath,
    summary.iid,
  );

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

  Future<bool> _confirmStateChange(
    BuildContext context,
    WorkItemStateSnapshot _,
    WorkItemStateEvent event,
  ) async {
    final generation = _generation;
    final closing = event == WorkItemStateEvent.close;
    final route = DialogRoute<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(closing ? '關閉工作項目？' : '重新開啟工作項目？'),
        content: Text(
          '@${widget.account.user.username} · ${widget.account.instance.key}\n'
          '${widget.namespacePath} · #${widget.iid}\n\n'
          '${closing ? '關閉' : '重新開啟'}這個工作項目？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(closing ? '確認關閉' : '確認重開'),
          ),
        ],
      ),
    );
    _ownRoute(route);
    final accepted = await Navigator.of(context).push(route);
    return _current(generation) && accepted == true;
  }

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
          _WorkItemDescriptionCard(
            key: PageStorageKey(
              'work-item-description:${widget.account.key}:${summary.id}:'
              '$_detailEpoch',
            ),
            description: description,
            account: widget.account,
            api: widget.api,
            project: project,
          )
        else if (detail.descriptionWidget != null)
          _section(context, '說明', const Text('沒有說明')),
        WorkItemStateControl(
          account: widget.account,
          api: widget.api,
          summary: summary,
          isCurrent: widget.isCurrent,
          ownerChanges: widget.ownerChanges,
          confirmChange: _confirmStateChange,
          onChanged: _applyStateSnapshot,
        ),
        WorkItemAttributesPanel(
          account: widget.account,
          api: widget.api,
          detail: detail,
          isCurrent: widget.isCurrent,
          ownerChanges: widget.ownerChanges,
        ),
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
        WorkItemActivityPanel(
          account: widget.account,
          api: widget.api,
          detail: detail,
          project: project,
          isCurrent: widget.isCurrent,
          ownerChanges: widget.ownerChanges,
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
        toolbarHeight: (MediaQuery.textScalerOf(context).scale(19) * 1.3 + 16)
            .clamp(56, double.infinity),
        title: Text(
          '工作項目 #${widget.iid}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (_detail != null)
            ResourceShareButton(
              uri: _shareUri(_detail!.summary),
              ownerKey: _shareOwnerKey(_detail!.summary),
              isCurrent: widget.isCurrent,
            ),
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

class _WorkItemDescriptionCard extends StatefulWidget {
  const _WorkItemDescriptionCard({
    super.key,
    required this.description,
    required this.account,
    required this.api,
    required this.project,
  });

  final String description;
  final Account account;
  final GitLabApi api;
  final Project? project;

  @override
  State<_WorkItemDescriptionCard> createState() =>
      _WorkItemDescriptionCardState();
}

class _WorkItemDescriptionCardState extends State<_WorkItemDescriptionCard> {
  static const _collapsedThreshold = 800;
  late int _characterCount;
  late String _preview;

  @override
  void initState() {
    super.initState();
    _cacheDescriptionSummary();
  }

  @override
  void didUpdateWidget(covariant _WorkItemDescriptionCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.description != widget.description) {
      _cacheDescriptionSummary();
    }
  }

  void _cacheDescriptionSummary() {
    _characterCount = widget.description.runes.length;
    final normalized = widget.description.trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    _preview = String.fromCharCodes(normalized.runes.take(80));
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: _characterCount <= _collapsedThreshold,
        maintainState: false,
        title: Text('說明', style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(
          '$_characterCount 字元${_preview.isEmpty ? '' : ' · $_preview'}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: MarkdownView(
              widget.description,
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
          ),
        ],
      ),
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
