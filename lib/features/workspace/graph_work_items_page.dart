import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ai/ai_work_item_write_registry.dart';
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/work_item_assignee_models.dart';
import '../../core/work_item_dates_models.dart';
import '../../core/work_item_graph_models.dart';
import '../../core/work_item_labels_models.dart';
import '../../core/work_item_state_models.dart';
import '../../core/work_item_status_models.dart';
import '../../shared/markdown_view.dart';
import '../../shared/resource_share.dart';
import '../../shared/skeleton.dart';
import '../../shared/workspace_ui.dart';
import '../auth/session_controller.dart';
import 'work_item_activity.dart';
import 'work_item_assignees.dart';
import 'work_item_attributes.dart';
import 'work_item_content.dart';
import 'work_item_dates.dart';
import 'work_item_labels.dart';
import 'work_item_milestone.dart';
import 'work_item_health.dart';
import 'work_item_notifications.dart';
import 'work_item_state_control.dart';
import 'work_item_status.dart';
import 'work_item_weight.dart';

import '../../l10n/l10n.dart';
String _graphWorkItemState(String value) => switch (value.toUpperCase()) {
  'OPEN' => 'opened',
  'CLOSED' => 'closed',
  _ => value.toLowerCase(),
};

/// Formats GitLab's date-only scalars without applying a device timezone.
/// These fields describe a calendar day rather than an instant.
String workItemCalendarDate(DateTime value) =>
    '${value.year}/${value.month.toString().padLeft(2, '0')}/${value.day.toString().padLeft(2, '0')}';

/// The `SessionController.generation` a route belongs to, taken once when the
/// route opens. An injected value wins; otherwise only a current session
/// owner for the same account and client supplies it. Null keeps
/// session-bound writers closed.
int? captureRouteSessionGeneration({
  required int? injected,
  required Listenable? owner,
  required Account account,
  required GitLabApi api,
  bool Function()? isCurrent,
}) {
  if (injected != null) return injected;
  if (owner is! SessionController) return null;
  if (!(isCurrent?.call() ?? true) ||
      owner.active?.key != account.key ||
      !identical(owner.api, api)) {
    return null;
  }
  return owner.generation;
}

/// Whether the captured generation still names the live session. The value
/// is never re-sampled, so leaving and returning to the same account and
/// client keeps an old route invalid.
bool routeSessionMatches(
  int? generation,
  Listenable? owner,
  Account account,
  GitLabApi api,
) {
  if (generation == null) return false;
  if (owner is! SessionController) return true;
  return owner.generation == generation &&
      owner.active?.key == account.key &&
      identical(owner.api, api);
}

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
    this.sessionGeneration,
  }) : _groupPath = null,
       embedded = false;

  const GraphWorkItemsPage.group({
    super.key,
    required this.account,
    required this.api,
    required String namespacePath,
    this.isCurrent,
    this.ownerChanges,
    this.sessionGeneration,
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

  /// The `SessionController.generation` captured by the opener.
  final int? sessionGeneration;

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
  int? _activePageTier;
  WorkItemDisplayPreferences _displayPreferences =
      const WorkItemDisplayPreferences();
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
  int? _sessionGeneration;
  NavigatorState? _navigator;
  final Set<Route<dynamic>> _ownedRoutes = {};
  Route<void>? _displayOptionsRoute;
  bool _ownerInvalid = false;

  bool _current(int generation) =>
      mounted &&
      generation == _generation &&
      (widget.isCurrent?.call() ?? true);

  int? _captureSessionGeneration() => captureRouteSessionGeneration(
    injected: widget.sessionGeneration,
    owner: widget.ownerChanges,
    account: widget.account,
    api: widget.api,
    isCurrent: widget.isCurrent,
  );

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
    _sessionGeneration = _captureSessionGeneration();
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
      _sessionGeneration = _captureSessionGeneration();
      _generation++;
      _itemGeneration++;
      _dismissOwnedRoutes();
      _filter = _defaultFilter;
      _activePageFilter = null;
      _activePageTier = null;
      _displayPreferences = const WorkItemDisplayPreferences();
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
      _activePageTier = null;
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
    _displayOptionsRoute = null;
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
      _activePageTier = null;
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
                  summaries: true,
                  isCurrent: currentItems,
                )
              : owner.api.projectWorkItems(
                  owner.project!,
                  filter: requestFilter,
                  summaries: true,
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
        _activePageTier = itemResult.summaryTier;
        _items.addAll(itemResult.items);
        _nextItems = itemResult.nextCursor;
        _itemPages = 1;
      } else if (itemsCurrent && itemResult is WorkItemGraphPage) {
        _activePageFilter = itemResult.filter;
        _activePageTier = itemResult.summaryTier;
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
            _activePageTier = null;
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
      await _refreshItems(retryWithoutType!, notice: l10n.selectedTypeUnavailable);
    } else if (_selectedTypeNeedsVerification && _nextTypes != null) {
      await _loadMoreTypes();
    }
  }

  Future<void> _refreshItems(
    GroupWorkItemListFilter nextFilter, {
    String? notice,
  }) async {
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
      _activePageTier = null;
      _usedItemCursors.clear();
      _itemPages = 0;
      _itemsLimitReached = false;
      _loadingItems = true;
    });
    bool current() => _currentItems(generation, itemGeneration);
    try {
      if (owner.project != null) {
        final page = await owner.api.projectWorkItems(
          owner.project!,
          filter: nextFilter,
          summaries: true,
          isCurrent: current,
        );
        if (!current()) return;
        setState(() {
          _activePageFilter = page.filter;
          _activePageTier = page.summaryTier;
          _items.addAll(page.items);
          _nextItems = page.nextCursor;
          _itemPages = 1;
          _loadingItems = false;
        });
        return;
      }
      final page = await owner.api.groupWorkItems(
        owner.namespacePath,
        expectedGroupId: _namespace?.id,
        filter: nextFilter,
        summaries: true,
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
        _activePageTier = page.summaryTier;
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
              _activePageTier = null;
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
          notice: l10n.selectedTypeUnavailable,
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
    final pageFilter = _activePageFilter;
    if (pageFilter == null) return;
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
    setState(() => _loadingItems = true);
    try {
      final page = owner.project == null
          ? await owner.api.groupWorkItems(
              owner.namespacePath,
              expectedGroupId: _namespace?.id,
              after: cursor,
              filter: pageFilter,
              previousFilter: pageFilter,
              summaries: true,
              previousTier: _activePageTier,
              isCurrent: () => _currentItems(generation, itemGeneration),
            )
          : await owner.api.projectWorkItems(
              owner.project!,
              after: cursor,
              filter: pageFilter,
              previousFilter: pageFilter,
              summaries: true,
              previousTier: _activePageTier,
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
      if (page is WorkItemGraphPage && page.filter != pageFilter) {
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
      await _refreshItems(retryWithoutType!, notice: l10n.selectedTypeUnavailable);
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
        SnackBar(content: Text(l10n.workItemGroupLocationMissing)),
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
              sessionGeneration: _sessionGeneration,
            )
          : GraphWorkItemDetailPage.project(
              account: widget.account,
              api: widget.api,
              project: project,
              iid: item.iid,
              isCurrent: widget.isCurrent,
              ownerChanges: widget.ownerChanges,
              sessionGeneration: _sessionGeneration,
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
    final stateLabels = {
      GroupWorkItemState.opened: l10n.statusOpen,
      GroupWorkItemState.closed: l10n.statusClosed,
      GroupWorkItemState.all: l10n.allStatuses,
    };
    final sortLabels = {
      GroupWorkItemSort.createdDesc: l10n.sortNewestCreated,
      GroupWorkItemSort.createdAsc: l10n.sortOldestCreated,
      GroupWorkItemSort.updatedDesc: l10n.sortRecentlyUpdated,
      GroupWorkItemSort.updatedAsc: l10n.sortLeastRecentlyUpdated,
    };
    final selectableTypes = _selectableTypes.toList(growable: false);
    final scopeLabel = _filter.includeDescendants ? l10n.includeSubgroupsAndProjects : l10n.thisGroupOnly;
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
                      child: Text(
                        l10n.includeSubgroupsAndProjects,
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
                    label: Text(l10n.thisGroupOnly),
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
                      decoration: InputDecoration(
                        labelText: l10n.searchWorkItems,
                        hintText: l10n.titleOrKeyword,
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onSubmitted: (_) => _submitSearch(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    onPressed: _submitSearch,
                    tooltip: l10n.applySearch,
                    icon: const Icon(Icons.search),
                  ),
                  IconButton(
                    onPressed: () {
                      _searchController.clear();
                      _submitSearch();
                    },
                    tooltip: l10n.clearSearch,
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
                  decoration: InputDecoration(
                    labelText: l10n.sortOrder,
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
                  decoration: InputDecoration(
                    labelText: l10n.workItemTypeFilter,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(l10n.allWorkItemTypes),
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
      return Card(
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
              Expanded(child: Text(l10n.loadingWorkItemTypes)),
            ],
          ),
        ),
      );
    }
    if (_typesError != null && _types.isEmpty) {
      return FailureNotice(
        _typesError!,
        account: widget.account,
        resourceLabel: l10n.workItemTypesTitle(widget.namespacePath),
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
            Text(l10n.serverProvidedTypes, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (_types.isEmpty)
              Text(
                widget.project == null
                    ? l10n.groupNoWorkItemTypes
                    : l10n.projectNoWorkItemTypes,
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
                        '${capability.type.name}${capability.enabled ? '' : l10n.notEnabledSuffix}',
                      ),
                    ),
                ],
              ),
            if (_typesError != null) ...[
              const SizedBox(height: 8),
              Text(
                l10n.laterTypesLoadFailed,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextButton.icon(
                onPressed: _nextTypes == null ? _refresh : _loadMoreTypes,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.retryAction),
              ),
            ],
            if (_typesLimitReached) ...[
              const SizedBox(height: 8),
              Text(
                l10n.workItemTypeLoadLimit,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.refreshAction),
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
                label: Text(l10n.loadMoreTypes),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _itemRow(WorkItemGraphSummary item) {
    final summary = item.summary;
    final prefs = _displayPreferences;
    final metaChips = <Widget>[];

    metaChips.add(StatusBadge(_graphWorkItemState(item.state)));

    final author = item.author;
    if (author != null) {
      metaChips.add(PersonChip({
        'name': author.name,
        'username': author.username,
      }));
    }

    if (prefs.showStatus && summary?.status?.name != null) {
      metaChips.add(
        MetaChip(
          summary!.status!.name!,
          icon: Icons.flag_outlined,
        ),
      );
    }

    metaChips.add(
      MetaChip(
        relativeDate(item.updatedAt.toIso8601String()),
        icon: Icons.schedule_outlined,
      ),
    );

    if (prefs.showMilestone && summary?.milestone != null) {
      metaChips.add(
        MetaChip(
          summary!.milestone!.title,
          icon: Icons.flag_circle_outlined,
        ),
      );
    }

    if (prefs.showDates && summary?.dates != null) {
      final dates = summary!.dates!;
      String? dateText;
      if (dates.startDate != null && dates.dueDate != null) {
        dateText =
            '${workItemCalendarDate(dates.startDate!)} - ${workItemCalendarDate(dates.dueDate!)}';
      } else if (dates.startDate != null) {
        dateText = l10n.startDateColon(workItemCalendarDate(dates.startDate!));
      } else if (dates.dueDate != null) {
        dateText = l10n.dueDateColon(workItemCalendarDate(dates.dueDate!));
      }
      if (dateText != null) {
        metaChips.add(
          MetaChip(
            dateText,
            icon: Icons.event_outlined,
          ),
        );
      }
    }

    if (prefs.showHierarchy && summary?.hierarchy != null) {
      final hierarchy = summary!.hierarchy!;
      if (hierarchy.parent != null) {
        metaChips.add(
          MetaChip(
            '${hierarchy.parent!.type.name} #${hierarchy.parent!.iid}',
            icon: Icons.account_tree_outlined,
          ),
        );
      } else if (hierarchy.hasParent) {
        metaChips.add(
          MetaChip(
            l10n.parentNotVisible,
            icon: Icons.lock_outline,
          ),
        );
      }
    }

    if (prefs.showAssignees && summary?.assignees != null) {
      final assigneesConn = summary!.assignees!;
      for (final assignee in assigneesConn.items) {
        metaChips.add(
          MetaChip(
            assignee.name,
            icon: Icons.person_outline,
          ),
        );
      }
      if (assigneesConn.isPartial) {
        metaChips.add(
          Semantics(
            container: true,
            label: l10n.moreNotLoaded,
            excludeSemantics: true,
            child: MetaChip(l10n.moreItems, icon: Icons.more_horiz),
          ),
        );
      }
    }

    if (prefs.showLabels && summary?.labels != null) {
      final labelsConn = summary!.labels!;
      for (final label in labelsConn.items) {
        metaChips.add(
          LabelPill(
            label.title,
            color: parseHexColor(label.color),
          ),
        );
      }
      if (labelsConn.isPartial) {
        metaChips.add(
          Semantics(
            container: true,
            label: l10n.moreNotLoaded,
            excludeSemantics: true,
            child: LabelPill(l10n.moreItems),
          ),
        );
      }
    }

    return EntityCard(
      leading: const Icon(Icons.workspaces_outline),
      title: Text(item.title),
      subtitle: Text(
        widget.project == null
            ? '${isolated(_itemNamespace(item))} · ${item.type.name} · ${isolated('#${item.iid}')}'
            : '${item.type.name} · ${isolated('#${item.iid}')}',
      ),
      meta: metaChips,
      onTap: () => _open(item),
    );
  }

  List<Widget> _footer(BuildContext context) => [
    if (_itemsError != null && _items.isNotEmpty)
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: FailureNotice(
          _itemsError!,
          account: widget.account,
          resourceLabel: l10n.moreWorkItemsTitle(widget.namespacePath),
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
                l10n.workItemLoadLimit,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              TextButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.refreshAction),
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
          label: Text(l10n.loadMoreWorkItems),
        ),
      ),
  ];

  Widget _body(BuildContext context) {
    final gutter = feedGutter(context);
    final Widget itemSliver;
    if (_loadingItems && _items.isEmpty) {
      itemSliver = const SliverToBoxAdapter(child: RowsSkeleton());
    } else if (_itemsError != null && _items.isEmpty) {
      itemSliver = SliverToBoxAdapter(
        child: FailureNotice(
          _itemsError!,
          account: widget.account,
          resourceLabel: l10n.workItemsTitle(widget.namespacePath),
          onRetry: _refresh,
          onSwitchAccount: endSessionFrom(context),
        ),
      );
    } else if (_items.isEmpty) {
      itemSliver = SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 44),
          child: Column(
            children: [
              Icon(Icons.workspaces_outline, size: 38),
              SizedBox(height: 10),
              Text(l10n.noWorkItemsToDisplay),
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
                  if (widget.embedded)
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.namespacePath,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        IconButton(
                          key: const Key(
                            'graph-work-items-display-options-button',
                          ),
                          onPressed: _openDisplayOptions,
                          tooltip: l10n.displaySettings,
                          icon: const Icon(Icons.tune),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    )
                  else
                    Text(
                      widget.namespacePath,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  if (widget.project == null) ...[
                    const SizedBox(height: 6),
                    _groupFilters(context),
                  ] else ...[
                    const SizedBox(height: 6),
                    _projectFilters(context),
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

  Widget _projectFilters(BuildContext context) {
    final stateLabels = {
      GroupWorkItemState.opened: l10n.statusOpen,
      GroupWorkItemState.closed: l10n.statusClosed,
      GroupWorkItemState.all: l10n.allStatuses,
    };
    final sortLabels = {
      GroupWorkItemSort.createdDesc: l10n.sortNewestCreated,
      GroupWorkItemSort.createdAsc: l10n.sortOldestCreated,
      GroupWorkItemSort.updatedDesc: l10n.sortRecentlyUpdated,
      GroupWorkItemSort.updatedAsc: l10n.sortLeastRecentlyUpdated,
    };
    return Card(
      key: const Key('project-work-item-filters'),
      child: ExpansionTile(
        key: const PageStorageKey('project-work-item-filters-expansion'),
        title: Text(l10n.projectFiltersAndSort),
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
                      key: const Key('project-work-item-search'),
                      controller: _searchController,
                      scrollController: _searchScrollController,
                      textInputAction: TextInputAction.search,
                      maxLength: 256,
                      decoration: InputDecoration(
                        labelText: l10n.searchWorkItems,
                        hintText: l10n.titleOrKeyword,
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                      onSubmitted: (_) => _submitSearch(),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filledTonal(
                    onPressed: _submitSearch,
                    tooltip: l10n.applySearch,
                    icon: const Icon(Icons.search),
                  ),
                  IconButton(
                    onPressed: () {
                      _searchController.clear();
                      _submitSearch();
                    },
                    tooltip: l10n.clearSearch,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              KeyedSubtree(
                key: const Key('project-work-item-sort'),
                child: DropdownButtonFormField<GroupWorkItemSort>(
                  key: ValueKey('project-work-item-sort-${_filter.sort}'),
                  initialValue: _filter.sort,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.sortOrder,
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
            ],
          ),
        ],
      ),
    );
  }

  void _openDisplayOptions() {
    if (_displayOptionsRoute?.isActive == true) return;
    final route = ModalBottomSheetRoute<void>(
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => _WorkItemDisplaySheet(
          tier: _activePageTier,
          preferences: _displayPreferences,
          onChanged: (newPreferences) {
            if (!mounted) return;
            setState(() {
              _displayPreferences = newPreferences;
            });
            setSheetState(() {});
          },
        ),
      ),
      isScrollControlled: true,
      showDragHandle: true,
    );
    _displayOptionsRoute = route;
    _ownRoute(route);
    unawaited(
      Navigator.of(context).push(route).then((_) {
        if (_displayOptionsRoute == route) {
          _displayOptionsRoute = null;
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_ownerInvalid) {
      final closed = SafeArea(child: Center(child: Text(l10n.accountSwitchedWorkItemClosed)));
      return widget.embedded ? closed : Scaffold(body: closed);
    }
    if (widget.embedded) return _body(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.workItemsLabel),
        actions: [
          IconButton(
            key: const Key('graph-work-items-display-options-button'),
            onPressed: _openDisplayOptions,
            tooltip: l10n.displaySettings,
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            onPressed: _loadingItems || _loadingTypes ? null : _refresh,
            tooltip: l10n.refreshAction,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _body(context),
    );
  }
}

class _WorkItemDisplaySheet extends StatelessWidget {
  const _WorkItemDisplaySheet({
    required this.tier,
    required this.preferences,
    required this.onChanged,
  });

  final int? tier;
  final WorkItemDisplayPreferences preferences;
  final ValueChanged<WorkItemDisplayPreferences> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUnknown = tier == null;
    final isTier3 = tier == 3;
    final isTier2 = tier == 2;

    Widget buildSupportedTile({
      required String title,
      required bool value,
      required bool disabled,
      required ValueChanged<bool> onToggle,
    }) {
      return SwitchListTile(
        title: Text(title),
        subtitle: disabled ? Text(l10n.notProvidedByInstance) : null,
        value: disabled ? false : value,
        onChanged: disabled ? null : onToggle,
      );
    }

    Widget buildUnsupportedTile(String title) {
      return SwitchListTile(
        title: Text(title),
        subtitle: Text(l10n.notSupportedYet),
        value: false,
        onChanged: null,
      );
    }

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l10n.displaySettings,
              style: theme.textTheme.titleMedium,
            ),
          ),
          buildSupportedTile(
            title: l10n.labelNoun,
            value: preferences.showLabels,
            disabled: isUnknown || isTier3,
            onToggle: (v) => onChanged(preferences.copyWith(showLabels: v)),
          ),
          buildSupportedTile(
            title: l10n.assigneeFilter,
            value: preferences.showAssignees,
            disabled: isUnknown || isTier3,
            onToggle: (v) => onChanged(preferences.copyWith(showAssignees: v)),
          ),
          buildSupportedTile(
            title: l10n.milestoneLabel,
            value: preferences.showMilestone,
            disabled: isUnknown || isTier3,
            onToggle: (v) => onChanged(preferences.copyWith(showMilestone: v)),
          ),
          buildSupportedTile(
            title: l10n.startAndDueDates,
            value: preferences.showDates,
            disabled: isUnknown || isTier3,
            onToggle: (v) => onChanged(preferences.copyWith(showDates: v)),
          ),
          buildSupportedTile(
            title: l10n.hierarchyRelation,
            value: preferences.showHierarchy,
            disabled: isUnknown || isTier3,
            onToggle: (v) => onChanged(preferences.copyWith(showHierarchy: v)),
          ),
          buildSupportedTile(
            title: l10n.workflowStatus,
            value: preferences.showStatus,
            disabled: isUnknown || isTier3 || isTier2,
            onToggle: (v) => onChanged(preferences.copyWith(showStatus: v)),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(
              l10n.otherOptionsUnsupported,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ),
          buildUnsupportedTile(l10n.blockingItems),
          buildUnsupportedTile(l10n.commentCountSort),
          buildUnsupportedTile(l10n.healthStatus),
          buildUnsupportedTile(l10n.iteration),
          buildUnsupportedTile(l10n.popularity),
          buildUnsupportedTile(l10n.weight),
        ],
      ),
    );
  }
}

class _AssigneeSignals extends ChangeNotifier {
  void bump() => notifyListeners();
}

/// The page, session, account, client and item a Dates write started under.
class _DatesWriteOwner {
  const _DatesWriteOwner({
    required this.pageGeneration,
    required this.sessionGeneration,
    required this.account,
    required this.api,
    required this.summary,
  });

  final int pageGeneration;
  final int? sessionGeneration;
  final Account account;
  final GitLabApi api;
  final WorkItemGraphSummary summary;
}

class _DatesWrite {
  _DatesWrite(this.token, this.owner);

  final Object token;
  final _DatesWriteOwner owner;
  DateTime? confirmedRevision;
}

/// How the last Dates write on an item ended. `revision` is the newest
/// confirmed `updatedAt` seen on this client; an unconfirmed end keeps it.
class _DatesTerminal {
  const _DatesTerminal(this.revision, {required this.confirmed});

  final DateTime? revision;
  final bool confirmed;
}

/// Dates writes between START and SETTLE, per API client and item id. Every
/// page on the same client holds the item's Dates and STATUS writers while
/// one is active. The token is released only by the write's own SETTLE.
class _DatesWriteRegistry extends ChangeNotifier {
  _DatesWriteRegistry._();

  static final instance = _DatesWriteRegistry._();

  final Expando<Map<String, Set<Object>>> _active = Expando();
  final Expando<Map<String, _DatesTerminal>> _terminals = Expando();

  bool isActive(GitLabApi api, String id) =>
      _active[api]?[id]?.isNotEmpty ?? false;

  _DatesTerminal? terminal(GitLabApi api, String id) => _terminals[api]?[id];

  void start(GitLabApi api, String id, Object token) {
    final byId = _active[api] ??= <String, Set<Object>>{};
    if (!(byId[id] ??= <Object>{}).add(token)) return;
    notifyListeners();
  }

  bool tryStartAi(GitLabApi api, String id, Object token) {
    final byId = _active[api] ??= <String, Set<Object>>{};
    final tokens = byId[id] ??= <Object>{};
    if (tokens.isNotEmpty) return false;
    tokens.add(token);
    notifyListeners();
    return true;
  }

  void settleAi(
    GitLabApi api,
    String id,
    Object token, {
    required bool mutationSent,
    DateTime? confirmedRevision,
  }) {
    final byId = _active[api];
    final tokens = byId?[id];
    if (tokens == null || !tokens.remove(token)) return;
    if (tokens.isEmpty) byId!.remove(id);
    if (mutationSent) {
      final terminals = _terminals[api] ??= <String, _DatesTerminal>{};
      final earlier = terminals[id]?.revision;
      terminals[id] = _DatesTerminal(
        confirmedRevision == null
            ? earlier
            : earlier != null && earlier.isAfter(confirmedRevision)
            ? earlier
            : confirmedRevision,
        confirmed: confirmedRevision != null,
      );
    }
    notifyListeners();
  }

  void settle(
    GitLabApi api,
    String id,
    Object token, {
    DateTime? confirmedRevision,
  }) {
    final byId = _active[api];
    final tokens = byId?[id];
    if (tokens == null || !tokens.remove(token)) return;
    if (tokens.isEmpty) byId!.remove(id);
    final terminals = _terminals[api] ??= <String, _DatesTerminal>{};
    final earlier = terminals[id]?.revision;
    if (confirmedRevision == null) {
      terminals[id] = _DatesTerminal(earlier, confirmed: false);
    } else {
      terminals[id] = _DatesTerminal(
        earlier != null && earlier.isAfter(confirmedRevision)
            ? earlier
            : confirmedRevision,
        confirmed: true,
      );
    }
    notifyListeners();
  }
}

DateTime? _maxDateTime(DateTime? a, DateTime? b) {
  if (a == null) return b;
  if (b == null) return a;
  return a.isAfter(b) ? a : b;
}

final class _HealthPendingEntry {
  const _HealthPendingEntry({
    required this.api,
    required this.id,
    required this.preWriteRevision,
    required this.seq,
  });

  final GitLabApi api;
  final String id;
  final DateTime? preWriteRevision;
  final int seq;
}

final class _HealthTerminal {
  const _HealthTerminal({
    required this.floorRevision,
    required this.confirmed,
    required this.knownNotApplied,
    required this.seq,
  });

  final DateTime? floorRevision;
  final bool confirmed;
  final bool knownNotApplied;
  final int seq;
}

final class _HealthWriteOwner {
  const _HealthWriteOwner({
    required this.pageGeneration,
    required this.sessionGeneration,
    required this.account,
    required this.api,
    required this.summary,
  });

  final int pageGeneration;
  final int? sessionGeneration;
  final Account account;
  final GitLabApi api;
  final WorkItemGraphSummary summary;
}

final class _HealthWrite {
  _HealthWrite(this.token, this.owner);

  final Object token;
  final _HealthWriteOwner owner;
}

final class _InertListenable implements Listenable {
  const _InertListenable();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  static const instance = _InertListenable();
}

class _HealthWriteRegistry extends ChangeNotifier {
  _HealthWriteRegistry._();

  static final instance = _HealthWriteRegistry._();

  int _seq = 0;
  final Expando<Map<String, Map<Object, _HealthPendingEntry>>> _active =
      Expando();
  final Map<Object, _HealthPendingEntry> _settled = {};
  final Expando<Map<String, _HealthTerminal>> _terminals = Expando();

  bool isActive(GitLabApi api, String id) =>
      _active[api]?[id]?.isNotEmpty ?? false;

  _HealthTerminal? terminalFor(GitLabApi api, String id) =>
      _terminals[api]?[id];

  bool start({
    required GitLabApi api,
    required String id,
    required Object token,
    required DateTime? floorRevision,
  }) {
    final perApi = _active[api] ??= {};
    final perItem = perApi[id] ??= {};
    if (perItem.isNotEmpty) {
      return false;
    }
    perItem[token] = _HealthPendingEntry(
      api: api,
      id: id,
      preWriteRevision: floorRevision,
      seq: ++_seq,
    );
    notifyListeners();
    return true;
  }

  void settle(GitLabApi api, String id, Object token) {
    final perApi = _active[api];
    final perItem = perApi?[id];
    final entry = perItem?.remove(token);
    if (perItem != null && perItem.isEmpty) {
      perApi!.remove(id);
    }
    if (entry != null) {
      _settled[token] = entry;
      notifyListeners();
    }
  }

  void settleAi(
    GitLabApi api,
    String id,
    Object token, {
    required bool mutationSent,
    DateTime? confirmedRevision,
  }) {
    final perApi = _active[api];
    final perItem = perApi?[id];
    final entry = perItem?.remove(token);
    if (perItem != null && perItem.isEmpty) perApi!.remove(id);
    if (entry == null) return;
    if (mutationSent) {
      final terminals = _terminals[api] ??= <String, _HealthTerminal>{};
      final current = terminals[id];
      if (current == null || entry.seq > current.seq) {
        terminals[id] = _HealthTerminal(
          floorRevision: confirmedRevision == null
              ? current?.floorRevision
              : _maxDateTime(current?.floorRevision, confirmedRevision),
          confirmed: confirmedRevision != null,
          knownNotApplied: false,
          seq: entry.seq,
        );
      }
    }
    notifyListeners();
  }

  void recordOutcome(
    GitLabApi api,
    String id,
    Object token,
    WorkItemHealthSaveOutcome outcome,
  ) {
    final entry = _settled.remove(token);
    if (entry == null) {
      return;
    }
    final perApi = _terminals[entry.api] ??= {};
    final current = perApi[entry.id];
    if (current != null && entry.seq <= current.seq) {
      return;
    }
    final prevFloor = current?.floorRevision;
    final DateTime? newFloor;
    final bool confirmed;
    final bool knownNotApplied;

    switch (outcome) {
      case WorkItemHealthSaveOutcome.confirmed:
        newFloor = _maxDateTime(prevFloor, entry.preWriteRevision);
        confirmed = true;
        knownNotApplied = false;
      case WorkItemHealthSaveOutcome.notApplied:
      case WorkItemHealthSaveOutcome.rejected:
        newFloor = prevFloor;
        confirmed = false;
        knownNotApplied = true;
      case WorkItemHealthSaveOutcome.notSent:
      case WorkItemHealthSaveOutcome.unknown:
        newFloor = prevFloor;
        confirmed = false;
        knownNotApplied = false;
      case WorkItemHealthSaveOutcome.noop:
        return;
    }

    perApi[entry.id] = _HealthTerminal(
      floorRevision: newFloor,
      confirmed: confirmed,
      knownNotApplied: knownNotApplied,
      seq: entry.seq,
    );
    notifyListeners();
  }
}

/// Creates the session-bound adapter used by AI Work Item writes. The
/// adapter reserves the existing UI registries synchronously and therefore
/// shares their per-client, per-item exclusion and freshness floors.
AiWorkItemWriteRegistry createAiWorkspaceWorkItemWriteRegistry({
  required GitLabApi api,
  required String accountKey,
  required String instanceKey,
  required int generation,
  required bool Function() isCurrent,
}) => _AiWorkspaceWorkItemWriteRegistry(
  api: api,
  accountKey: accountKey,
  instanceKey: instanceKey,
  generation: generation,
  isCurrent: isCurrent,
);

final class _AiWorkspaceWorkItemWriteLease implements AiWorkItemWriteLease {
  _AiWorkspaceWorkItemWriteLease({
    required this.owner,
    required this.gid,
    required this.kind,
    required this.token,
    required this.holdsStatus,
  });

  final _AiWorkspaceWorkItemWriteRegistry owner;
  @override
  final String gid;
  @override
  final AiWorkItemWriteKind kind;
  final Object token;
  final bool holdsStatus;
  bool settled = false;
}

final class _AiWorkspaceWorkItemWriteRegistry
    implements AiWorkItemWriteRegistry {
  _AiWorkspaceWorkItemWriteRegistry({
    required this.api,
    required this.accountKey,
    required this.instanceKey,
    required this.generation,
    required this.isCurrent,
  });

  static final _workItemGid = RegExp(r'^gid://gitlab/WorkItem/[1-9][0-9]*$');

  final GitLabApi api;
  final String accountKey;
  final String instanceKey;
  final int generation;
  final bool Function() isCurrent;

  bool get _ownerCurrent {
    if (!accountKey.startsWith('$instanceKey#') ||
        accountKey.length <= instanceKey.length + 1 ||
        instanceKey != api.instance.key ||
        generation < 0 ||
        api.isClosed) {
      return false;
    }
    try {
      return isCurrent();
    } catch (_) {
      return false;
    }
  }

  bool _valid(String gid) => _workItemGid.hasMatch(gid);

  bool _occupied(String gid) =>
      WorkItemStatusWriteRegistry.instance.isActive(api, gid) ||
      _DatesWriteRegistry.instance.isActive(api, gid) ||
      _HealthWriteRegistry.instance.isActive(api, gid);

  @override
  bool isActive(String gid) {
    if (!_ownerCurrent || !_valid(gid)) return true;
    return _occupied(gid);
  }

  @override
  AiWorkItemWriteLease? tryStart(String gid, AiWorkItemWriteKind kind) {
    if (!_ownerCurrent || !_valid(gid) || _occupied(gid)) return null;
    final token = Object();
    var holdsStatus = false;
    final started = switch (kind) {
      AiWorkItemWriteKind.status =>
        WorkItemStatusWriteRegistry.instance.tryStartExternal(api, gid, token),
      AiWorkItemWriteKind.dates => _startDates(gid, token),
      AiWorkItemWriteKind.health => _HealthWriteRegistry.instance.start(
        api: api,
        id: gid,
        token: token,
        floorRevision: _HealthWriteRegistry.instance
            .terminalFor(api, gid)
            ?.floorRevision,
      ),
    };
    if (!started) return null;
    holdsStatus =
        kind == AiWorkItemWriteKind.status || kind == AiWorkItemWriteKind.dates;
    return _AiWorkspaceWorkItemWriteLease(
      owner: this,
      gid: gid,
      kind: kind,
      token: token,
      holdsStatus: holdsStatus,
    );
  }

  bool _startDates(String gid, Object token) {
    final status = WorkItemStatusWriteRegistry.instance;
    if (!status.tryStartExternal(api, gid, token)) return false;
    if (_DatesWriteRegistry.instance.tryStartAi(api, gid, token)) return true;
    status.settleExternal(api, gid, token: token, mutationSent: false);
    return false;
  }

  @override
  void settle(
    AiWorkItemWriteLease lease,
    AiWorkItemWriteResult result,
    DateTime? revision,
  ) {
    if (lease is! _AiWorkspaceWorkItemWriteLease ||
        !identical(lease.owner, this) ||
        lease.settled) {
      return;
    }
    lease.settled = true;
    final mutationSent = result != AiWorkItemWriteResult.notSent;
    final confirmedRevision = result == AiWorkItemWriteResult.confirmed
        ? revision
        : null;
    switch (lease.kind) {
      case AiWorkItemWriteKind.status:
        break;
      case AiWorkItemWriteKind.dates:
        _DatesWriteRegistry.instance.settleAi(
          api,
          lease.gid,
          lease.token,
          mutationSent: mutationSent,
          confirmedRevision: confirmedRevision,
        );
      case AiWorkItemWriteKind.health:
        _HealthWriteRegistry.instance.settleAi(
          api,
          lease.gid,
          lease.token,
          mutationSent: mutationSent,
          confirmedRevision: confirmedRevision,
        );
    }
    if (lease.holdsStatus) {
      WorkItemStatusWriteRegistry.instance.settleExternal(
        api,
        lease.gid,
        token: lease.token,
        // Dates borrows STATUS solely for mutual exclusion; its own registry
        // records the date result without manufacturing STATUS freshness.
        mutationSent: lease.kind == AiWorkItemWriteKind.status && mutationSent,
        confirmedRevision: confirmedRevision,
      );
    }
  }
}

/// Freshness recorded by the UI registries after an AI lease settles.
typedef AiWorkspaceWriteFreshness = ({
  DateTime? revision,
  bool confirmed,
  bool knownNotApplied,
});

@visibleForTesting
AiWorkspaceWriteFreshness? aiWorkspaceWriteFreshnessForTesting(
  GitLabApi api,
  String gid,
  AiWorkItemWriteKind kind,
) {
  switch (kind) {
    case AiWorkItemWriteKind.status:
      final value = WorkItemStatusWriteRegistry.instance.terminal(api, gid);
      return value == null
          ? null
          : (
              revision: value.revision,
              confirmed: value.confirmed,
              knownNotApplied: false,
            );
    case AiWorkItemWriteKind.dates:
      final value = _DatesWriteRegistry.instance.terminal(api, gid);
      return value == null
          ? null
          : (
              revision: value.revision,
              confirmed: value.confirmed,
              knownNotApplied: false,
            );
    case AiWorkItemWriteKind.health:
      final value = _HealthWriteRegistry.instance.terminalFor(api, gid);
      return value == null
          ? null
          : (
              revision: value.floorRevision,
              confirmed: value.confirmed,
              knownNotApplied: value.knownNotApplied,
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
    this.sessionGeneration,
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
    this.sessionGeneration,
  }) : project = null;

  final Account account;
  final GitLabApi api;
  final Project? project;
  final String namespacePath;
  final String? expectedNamespaceId;
  final int iid;
  final bool Function()? isCurrent;
  final Listenable? ownerChanges;

  /// The `SessionController.generation` captured by the opener. Without it
  /// (and without a session owner to capture from) the STATUS writer stays
  /// closed.
  final int? sessionGeneration;

  @override
  State<GraphWorkItemDetailPage> createState() =>
      _GraphWorkItemDetailPageState();
}

class _GraphWorkItemDetailPageState extends State<GraphWorkItemDetailPage> {
  WorkItemGraphDetail? _detail;
  Project? _resolvedProject;
  ApiFailure? _projectContextError;
  bool _resolvingProject = false;
  ApiFailure? _error;
  bool _loading = false;
  int _generation = 0;
  int _detailEpoch = 0;
  NavigatorState? _navigator;
  final Set<Route<dynamic>> _ownedRoutes = {};
  bool _ownerInvalid = false;
  final _AssigneeSignals _assigneeSignals = _AssigneeSignals();
  Listenable? _assigneeOwner;
  Object? _assigneesWriteToken;
  int? _assigneesWriteGeneration;
  bool _assigneesHideStalePreview = false;
  bool _assigneesRefetchPending = false;
  bool _assigneesRefreshFailed = false;
  WorkItemAssigneeSnapshot? _assigneeOverlay;
  int _assigneeReadSerial = 0;
  Route<dynamic>? _labelsRoute;
  Object? _labelsWriteToken;
  int? _labelsWriteGeneration;
  bool _labelsHidePreview = false;
  bool _labelsUnconfirmed = false;
  int _labelsReadSerial = 0;
  int? _labelsRefetchSerial;
  Object? _milestoneWriteToken;
  int? _milestoneWriteGeneration;
  String? _milestoneWriteAccount;
  GitLabApi? _milestoneWriteApi;
  WorkItemGraphSummary? _milestoneWriteSummary;
  Object? _weightWriteToken;
  int? _weightWriteGeneration;
  String? _weightWriteAccount;
  GitLabApi? _weightWriteApi;
  WorkItemGraphSummary? _weightWriteSummary;
  int? _sessionGeneration;
  Object? _statusWriteToken;
  int? _statusWriteGeneration;
  WorkItemGraphSummary? _statusWriteSummary;
  WorkItemStatusSnapshot? _statusConfirmed;
  bool _statusUnconfirmed = false;
  bool _statusReloadOnSettle = false;
  int _stateOperations = 0;
  bool _statusRegistryActive = false;
  bool _statusReloadAfterLoad = false;
  WorkItemStatusTerminal? _statusTerminalSeen;
  _DatesWrite? _datesWrite;
  bool _datesRegistryActive = false;
  bool _datesReloadAfterLoad = false;
  _DatesTerminal? _datesTerminalSeen;
  DateTime? _datesDetailRevision;
  _HealthWrite? _healthWrite;
  Object? _healthReservedToken;
  bool _healthRegistryActive = false;
  bool _healthReloadAfterLoad = false;
  _HealthTerminal? _healthTerminalSeen;
  DateTime? _healthDetailRevision;

  /// Keys the Health control. Advanced when another page's STATUS write on
  /// this item settles, so an open Health editor closes even when the detail
  /// read afterwards carries the same `updatedAt`.
  int _healthControlEpoch = 0;
  late final WorkItemStateLoader _stateLoader = _loadStateGuarded;
  late final WorkItemStateUpdater _stateUpdater = _updateStateGuarded;

  bool _current(int generation) =>
      mounted &&
      generation == _generation &&
      (widget.isCurrent?.call() ?? true);

  int? _captureSessionGeneration() => captureRouteSessionGeneration(
    injected: widget.sessionGeneration,
    owner: widget.ownerChanges,
    account: widget.account,
    api: widget.api,
    isCurrent: widget.isCurrent,
  );

  bool get _sessionCurrent => routeSessionMatches(
    _sessionGeneration,
    widget.ownerChanges,
    widget.account,
    widget.api,
  );

  /// A STATUS write on this item is between START and SETTLE, from this page
  /// or from any other page using the same API client. Before the first
  /// detail arrives the item id is unknown, so only this page's token counts.
  bool get _statusHeld {
    if (_statusWriteToken != null) return true;
    final detail = _detail;
    return detail != null &&
        WorkItemStatusWriteRegistry.instance.isActive(
          widget.api,
          detail.summary.id,
        );
  }

  WorkItemStatusTerminal? get _statusTerminal {
    final detail = _detail;
    return detail == null
        ? null
        : WorkItemStatusWriteRegistry.instance.terminal(
            widget.api,
            detail.summary.id,
          );
  }

  /// The detail on screen predates a confirmed STATUS write on this item, so
  /// its STATUS is not painted as current. Cleared only by a newer detail.
  bool get _statusStale {
    final revision = _statusTerminal?.revision;
    final detail = _detail;
    return revision != null &&
        detail != null &&
        detail.summary.updatedAt.isBefore(revision);
  }

  /// Another page's STATUS write on this item ended with an unknown outcome
  /// and this page has not been refreshed by hand since.
  bool get _statusForeignUnconfirmed {
    final terminal = _statusTerminal;
    return terminal != null &&
        !terminal.confirmed &&
        !identical(terminal, _statusTerminalSeen);
  }

  bool get _labelsRefetchPending =>
      _labelsRefetchSerial != null &&
      _labelsRefetchSerial == _labelsReadSerial;

  /// A Dates write on this item is between START and SETTLE, from this page
  /// or from any other page using the same API client.
  bool get _datesHeld {
    if (_datesWrite != null) return true;
    final detail = _detail;
    return detail != null &&
        _DatesWriteRegistry.instance.isActive(widget.api, detail.summary.id);
  }

  bool _datesHeldFor(WorkItemGraphSummary expected) =>
      _datesWrite != null ||
      _DatesWriteRegistry.instance.isActive(widget.api, expected.id);

  _DatesTerminal? get _datesTerminal {
    final detail = _detail;
    return detail == null
        ? null
        : _DatesWriteRegistry.instance.terminal(widget.api, detail.summary.id);
  }

  /// The full detail on screen was read before a confirmed Dates write on
  /// this item. Summary-only updates never advance this revision.
  bool get _datesStale {
    final revision = _datesTerminal?.revision;
    final shown = _datesDetailRevision;
    return revision != null && shown != null && shown.isBefore(revision);
  }

  bool get _datesUnconfirmed {
    final terminal = _datesTerminal;
    return terminal != null &&
        !terminal.confirmed &&
        !identical(terminal, _datesTerminalSeen);
  }

  bool get _healthHeld =>
      _healthWrite != null ||
      (_detail != null &&
          _HealthWriteRegistry.instance.isActive(
            widget.api,
            _detail!.summary.id,
          ));

  bool _healthHeldFor(WorkItemGraphSummary expected) =>
      _healthWrite != null ||
      _HealthWriteRegistry.instance.isActive(widget.api, expected.id);

  _HealthTerminal? get _healthTerminal => _detail == null
      ? null
      : _HealthWriteRegistry.instance.terminalFor(
          widget.api,
          _detail!.summary.id,
        );

  bool get _healthStale {
    final term = _healthTerminal;
    if (term == null ||
        term.floorRevision == null ||
        _healthDetailRevision == null) {
      return false;
    }
    if (identical(term, _healthTerminalSeen)) return false;
    return !_healthDetailRevision!.isAfter(term.floorRevision!);
  }

  bool get _healthUnconfirmed {
    final term = _healthTerminal;
    if (term == null || term.confirmed || term.knownNotApplied) return false;
    return !identical(term, _healthTerminalSeen);
  }

  bool _healthOwnerMatches(_HealthWriteOwner owner) {
    final detail = _detail;
    return mounted &&
        _current(_generation) &&
        owner.pageGeneration == _generation &&
        owner.sessionGeneration == _sessionGeneration &&
        _sessionCurrent &&
        owner.account.key == widget.account.key &&
        identical(owner.api, widget.api) &&
        detail != null &&
        _sameWorkItemResource(owner.summary, detail.summary);
  }

  /// The owner lock for a Health open/save.
  bool _healthDispatchAllowed() =>
      _current(_generation) &&
      _sessionCurrent &&
      _detail != null &&
      !_loading &&
      _stateOperations == 0 &&
      !_statusHeld &&
      !_datesHeld &&
      !_healthHeld &&
      _labelsWriteToken == null &&
      !_labelsRefetchPending &&
      _assigneesWriteToken == null &&
      !_assigneesRefetchPending &&
      _milestoneWriteToken == null &&
      _weightWriteToken == null;

  /// Once this page's write has started, only its owner decides; another
  /// writer's hold must not cut off the write's own confirmation.
  bool _healthIsCurrent() {
    final own = _healthWrite;
    return own != null
        ? _healthOwnerMatches(own.owner)
        : _healthDispatchAllowed();
  }

  bool _datesOwnerMatches(_DatesWriteOwner owner) {
    final detail = _detail;
    return mounted &&
        _current(_generation) &&
        owner.pageGeneration == _generation &&
        owner.sessionGeneration == _sessionGeneration &&
        _sessionCurrent &&
        owner.account.key == widget.account.key &&
        identical(owner.api, widget.api) &&
        detail != null &&
        _sameWorkItemResource(owner.summary, detail.summary);
  }

  /// The owner lock for a Dates open/save.
  bool _datesDispatchAllowed() =>
      _current(_generation) &&
      _sessionCurrent &&
      _detail != null &&
      !_loading &&
      _stateOperations == 0 &&
      !_statusHeld &&
      !_datesHeld &&
      !_healthHeld &&
      _labelsWriteToken == null &&
      !_labelsRefetchPending &&
      _assigneesWriteToken == null &&
      !_assigneesRefetchPending &&
      _milestoneWriteToken == null &&
      _weightWriteToken == null;

  /// Once this page's write has started, only its owner decides; another
  /// writer's hold must not cut off the write's own confirmation.
  bool _datesIsCurrent() {
    final own = _datesWrite;
    return own != null
        ? _datesOwnerMatches(own.owner)
        : _datesDispatchAllowed();
  }

  /// The owner lock for a STATUS open/save. Checked again synchronously in
  /// the editor's last pre-START check.
  bool _statusDispatchAllowed() =>
      _current(_generation) &&
      _sessionCurrent &&
      _detail != null &&
      !_loading &&
      _stateOperations == 0 &&
      !_statusHeld &&
      !_datesHeld &&
      !_healthHeld &&
      _labelsWriteToken == null &&
      !_labelsRefetchPending &&
      _assigneesWriteToken == null &&
      !_assigneesRefetchPending &&
      _milestoneWriteToken == null &&
      _weightWriteToken == null;

  @override
  void initState() {
    super.initState();
    _sessionGeneration = _captureSessionGeneration();
    widget.ownerChanges?.addListener(_ownerChanged);
    WorkItemStatusWriteRegistry.instance.addListener(_statusRegistryChanged);
    _DatesWriteRegistry.instance.addListener(_datesRegistryChanged);
    _HealthWriteRegistry.instance.addListener(_healthRegistryChanged);
    _assigneeOwner = _assigneeOwnerSignals();
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
      _assigneeOwner = _assigneeOwnerSignals();
    }
    if (oldWidget.account.key != widget.account.key ||
        !identical(oldWidget.api, widget.api) ||
        oldWidget.project?.id != widget.project?.id ||
        oldWidget.namespacePath != widget.namespacePath ||
        oldWidget.expectedNamespaceId != widget.expectedNamespaceId ||
        oldWidget.iid != widget.iid ||
        !identical(oldWidget.isCurrent, widget.isCurrent) ||
        oldWidget.sessionGeneration != widget.sessionGeneration) {
      _sessionGeneration = _captureSessionGeneration();
      _generation++;
      _dropAssigneeSession();
      _dropLabelSession();
      _dropMetadataWrites();
      _dismissOwnedRoutes();
      _detail = null;
      _datesDetailRevision = null;
      _healthDetailRevision = null;
      _resolvedProject = null;
      _projectContextError = null;
      _resolvingProject = false;
      _error = null;
      _loading = false;
      _ownerInvalid = false;
      _statusRegistryActive = false;
      _statusReloadAfterLoad = false;
      _datesRegistryActive = false;
      _datesReloadAfterLoad = false;
      _healthRegistryActive = false;
      _healthReloadAfterLoad = false;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    widget.ownerChanges?.removeListener(_ownerChanged);
    WorkItemStatusWriteRegistry.instance.removeListener(
      _statusRegistryChanged,
    );
    _DatesWriteRegistry.instance.removeListener(_datesRegistryChanged);
    _HealthWriteRegistry.instance.removeListener(_healthRegistryChanged);
    _generation++;
    _dropAssigneeSession();
    _dropLabelSession();
    _dropMetadataWrites();
    _dismissOwnedRoutes();
    _assigneeSignals.dispose();
    super.dispose();
  }

  /// Another page's STATUS write on this item: hold while it is active, and
  /// read the detail once after it settles. Its result supersedes this
  /// page's own earlier confirmed or unconfirmed STATUS. This page's own
  /// write is ordered by its outcome and SETTLE callbacks instead.
  void _statusRegistryChanged() {
    if (!mounted) return;
    final detail = _detail;
    if (detail == null) {
      if (_loading) _statusReloadAfterLoad = true;
      return;
    }
    final active = WorkItemStatusWriteRegistry.instance.isActive(
      widget.api,
      detail.summary.id,
    );
    if (active == _statusRegistryActive) return;
    final settled = _statusRegistryActive && !active;
    _statusRegistryActive = active;
    if (settled && _statusWriteToken == null) {
      setState(() {
        _statusConfirmed = null;
        _statusUnconfirmed = false;
        _healthControlEpoch++;
      });
      if (_current(_generation) &&
          (_sessionCurrent || widget.ownerChanges == null)) {
        if (_loading) {
          _statusReloadAfterLoad = true;
        } else {
          unawaited(_load());
        }
      }
      return;
    }
    setState(() {});
  }

  /// Any Dates write on this item, from this page or another page on the
  /// same client: hold while it is active and read the full detail once after
  /// it settles. This page's own write reloads from its SETTLE instead.
  void _datesRegistryChanged() {
    if (!mounted) return;
    final detail = _detail;
    if (detail == null) {
      if (_loading) _datesReloadAfterLoad = true;
      return;
    }
    final active = _DatesWriteRegistry.instance.isActive(
      widget.api,
      detail.summary.id,
    );
    if (active == _datesRegistryActive) return;
    final settled = _datesRegistryActive && !active;
    _datesRegistryActive = active;
    if (settled &&
        _datesWrite == null &&
        _current(_generation) &&
        (_sessionCurrent || widget.ownerChanges == null)) {
      if (_loading) {
        _datesReloadAfterLoad = true;
      } else {
        unawaited(_load(keepForDates: true));
      }
      return;
    }
    setState(() {});
  }

  /// The registry hears every START and SETTLE, even after this page lost
  /// the write; the release always comes first so no other page stays held.
  void _onDatesPhase(
    _DatesWriteOwner owner,
    WorkItemDatesWritePhase phase,
    Object token,
  ) {
    final registry = _DatesWriteRegistry.instance;
    if (phase == WorkItemDatesWritePhase.start) {
      registry.start(owner.api, owner.summary.id, token);
      if (!mounted || _datesWrite != null || !_datesOwnerMatches(owner)) {
        return;
      }
      setState(() {
        _datesWrite = _DatesWrite(token, owner);
        _datesRegistryActive = true;
      });
      return;
    }
    final own = _datesWrite;
    final mine = own != null && identical(own.token, token);
    registry.settle(
      owner.api,
      owner.summary.id,
      token,
      confirmedRevision: mine ? own.confirmedRevision : null,
    );
    if (!mounted || !mine) return;
    final reload = _datesOwnerMatches(owner);
    setState(() => _datesWrite = null);
    if (reload) unawaited(_load(keepForDates: true));
  }

  /// A confirmed Dates readback only records its revision; the dates shown
  /// come from the full detail read after SETTLE.
  void _onDatesSaved(WorkItemDatesSnapshot snapshot) {
    final own = _datesWrite;
    final detail = _detail;
    if (own == null ||
        detail == null ||
        !_datesOwnerMatches(own.owner) ||
        snapshot.summary.id != detail.summary.id ||
        snapshot.expectedUserId != widget.account.user.id ||
        snapshot.generation != _sessionGeneration) {
      return;
    }
    final earlier = own.confirmedRevision;
    if (earlier == null || snapshot.updatedAt.isAfter(earlier)) {
      own.confirmedRevision = snapshot.updatedAt;
    }
  }

  void _dropDatesWrite() {
    _datesWrite = null;
  }

  void _dropHealthWrite() {
    _healthWrite = null;
    _healthReservedToken = null;
  }

  void _healthRegistryChanged() {
    if (!mounted) return;
    final detail = _detail;
    if (detail == null) {
      if (_loading) _healthReloadAfterLoad = true;
      return;
    }
    final active = _HealthWriteRegistry.instance.isActive(
      widget.api,
      detail.summary.id,
    );
    final terminal = _HealthWriteRegistry.instance.terminalFor(
      widget.api,
      detail.summary.id,
    );
    final wasActive = _healthRegistryActive;
    final prevTerminal = _healthTerminalSeen;
    _healthRegistryActive = active;
    final settled = wasActive && !active;
    if (settled &&
        _healthWrite == null &&
        _current(_generation) &&
        (_sessionCurrent || widget.ownerChanges == null)) {
      if (_loading) {
        _healthReloadAfterLoad = true;
      } else {
        unawaited(_load(keepForHealth: true));
      }
      return;
    }
    if (active != wasActive || terminal != prevTerminal) {
      setState(() {});
    }
  }

  bool _onHealthReserve(_HealthWriteOwner owner, Object token) {
    if (!_healthOwnerMatches(owner) ||
        !_healthDispatchAllowed() ||
        _healthReservedToken != null) {
      return false;
    }
    _healthReservedToken = token;
    return true;
  }

  void _onHealthReleaseUnsent(Object token) {
    if (identical(_healthReservedToken, token) && _healthWrite == null) {
      _healthReservedToken = null;
      if (mounted) setState(() {});
    }
  }

  void _onHealthPhase(
    _HealthWriteOwner owner,
    WorkItemHealthWritePhase phase,
    Object token,
  ) {
    if (phase == WorkItemHealthWritePhase.start) {
      if (identical(_healthReservedToken, token)) {
        _healthReservedToken = null;
      }
      final floor = _maxDateTime(
        owner.summary.updatedAt,
        _maxDateTime(_detail?.summary.updatedAt, _healthDetailRevision),
      );
      final started = _HealthWriteRegistry.instance.start(
        api: owner.api,
        id: owner.summary.id,
        token: token,
        floorRevision: floor,
      );
      if (!started) {
        throw StateError(
          'Concurrent Health mutation already active for this work item',
        );
      }
      if (!mounted || _healthWrite != null || !_healthOwnerMatches(owner)) {
        return;
      }
      setState(() {
        _healthWrite = _HealthWrite(token, owner);
        _healthRegistryActive = true;
      });
      return;
    }

    if (identical(_healthReservedToken, token)) {
      _healthReservedToken = null;
    }
    _HealthWriteRegistry.instance.settle(owner.api, owner.summary.id, token);
    final own = _healthWrite;
    final mine = own != null && identical(own.token, token);
    if (!mounted || !mine) return;
    final reload = _healthOwnerMatches(owner);
    setState(() => _healthWrite = null);
    if (reload) {
      if (_loading) {
        _healthReloadAfterLoad = true;
      } else {
        unawaited(_load(keepForHealth: true));
      }
    }
  }

  void _onHealthOutcome(
    _HealthWriteOwner owner,
    Object token,
    WorkItemHealthSaveOutcome outcome,
  ) {
    _HealthWriteRegistry.instance.recordOutcome(
      owner.api,
      owner.summary.id,
      token,
      outcome,
    );
    final own = _healthWrite;
    if (own == null ||
        !identical(own.token, token) ||
        !_healthOwnerMatches(own.owner)) {
      return;
    }
    setState(() {});
  }

  void _ownerChanged() {
    if (widget.isCurrent?.call() ?? true) return;
    _generation++;
    _dropAssigneeSession();
    _dropLabelSession();
    _dropMetadataWrites();
    _dismissOwnedRoutes();
    _statusRegistryActive = false;
    _statusReloadAfterLoad = false;
    _datesRegistryActive = false;
    _datesReloadAfterLoad = false;
    _healthRegistryActive = false;
    _healthReloadAfterLoad = false;
    setState(() {
      _detail = null;
      _datesDetailRevision = null;
      _healthDetailRevision = null;
      _resolvedProject = null;
      _projectContextError = null;
      _resolvingProject = false;
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

  void _ownLabelRoute(Route<dynamic> route) {
    _labelsRoute = route;
    _ownRoute(route);
    unawaited(
      route.popped.then((_) {
        if (identical(_labelsRoute, route)) _labelsRoute = null;
      }),
    );
  }

  void _dismissOwnedRoutes() {
    final navigator = _navigator;
    final routes = _ownedRoutes.toList(growable: false);
    _ownedRoutes.clear();
    _labelsRoute = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator == null || !navigator.mounted) return;
      for (final route in routes) {
        if (route.isActive) navigator.removeRoute(route);
      }
    });
  }

  bool _sameLabelOwner(GraphWorkItemDetailPage owner, int generation) {
    return mounted &&
        _current(generation) &&
        owner.account.key == widget.account.key &&
        identical(owner.api, widget.api) &&
        owner.project?.id == widget.project?.id &&
        owner.project?.path == widget.project?.path &&
        owner.namespacePath == widget.namespacePath &&
        owner.expectedNamespaceId == widget.expectedNamespaceId &&
        owner.iid == widget.iid;
  }

  bool _ownerMatchesLabelResource(
    GraphWorkItemDetailPage owner,
    WorkItemGraphSummary summary,
  ) {
    if (owner.iid != summary.iid) return false;
    final project = owner.project;
    if (project != null) {
      return summary.project?.id == 'gid://gitlab/Project/${project.id}' &&
          summary.project?.fullPath == project.path;
    }
    return summary.project == null &&
        summary.namespace?.fullPath == owner.namespacePath &&
        (owner.expectedNamespaceId == null ||
            summary.namespace?.id == owner.expectedNamespaceId);
  }

  bool _labelsReadCurrent(
    GraphWorkItemDetailPage owner,
    int generation,
    WorkItemGraphSummary? expectedSummary,
    int serial, {
    required bool allowMissingDetail,
  }) {
    if (!_sameLabelOwner(owner, generation) ||
        _labelsReadSerial != serial ||
        _labelsWriteToken != null ||
        (expectedSummary != null &&
            !_ownerMatchesLabelResource(owner, expectedSummary))) {
      return false;
    }
    final detail = _detail;
    if (expectedSummary == null) return true;
    if (detail == null) return allowMissingDetail;
    return _sameWorkItemResource(detail.summary, expectedSummary);
  }

  /// A refresh the user asked for also acknowledges the unconfirmed STATUS
  /// and Dates outcomes shown when it started.
  void _refresh() => unawaited(
    _load(
      acknowledge: _statusTerminal,
      acknowledgeDates: _datesTerminal,
      acknowledgeHealth: _healthTerminal,
    ),
  );

  /// `keepForDates` keeps the Dates section and its editor mounted while the
  /// detail after a Dates write is read.
  Future<void> _load({
    WorkItemStatusTerminal? acknowledge,
    _DatesTerminal? acknowledgeDates,
    _HealthTerminal? acknowledgeHealth,
    bool keepForDates = false,
    bool keepForHealth = false,
  }) async {
    if (_loading ||
        _labelsWriteToken != null ||
        _statusHeld ||
        _datesHeld ||
        _healthHeld ||
        !_current(_generation)) {
      return;
    }
    final owner = widget;
    final generation = _generation;
    final loadEpoch = ++_detailEpoch;
    final expectedLabelsSummary = _detail?.summary;
    final labelsReadSerial = ++_labelsReadSerial;
    _statusReloadAfterLoad = false;
    _datesReloadAfterLoad = false;
    _healthReloadAfterLoad = false;
    final keepDetail =
        _assigneesWriteToken != null ||
        _labelsWriteToken != null ||
        _milestoneWriteToken != null ||
        _weightWriteToken != null ||
        _statusConfirmed != null ||
        keepForDates ||
        keepForHealth ||
        (_labelsRoute?.isActive ?? false);
    setState(() {
      _loading = true;
      _error = null;
      if (!keepDetail) {
        _detail = null;
        _datesDetailRevision = null;
        _healthDetailRevision = null;
      }
      _resolvedProject = null;
      _projectContextError = null;
      _resolvingProject = false;
    });
    try {
      final detail = owner.project == null
          ? await owner.api.namespaceWorkItem(
              owner.namespacePath,
              owner.iid,
              expectedNamespaceId: owner.expectedNamespaceId,
              isCurrent: () =>
                  _detailEpoch == loadEpoch &&
                  _labelsReadCurrent(
                    owner,
                    generation,
                    expectedLabelsSummary,
                    labelsReadSerial,
                    allowMissingDetail: true,
                  ),
            )
          : await owner.api.projectWorkItem(
              owner.project!,
              owner.iid,
              isCurrent: () =>
                  _detailEpoch == loadEpoch &&
                  _labelsReadCurrent(
                    owner,
                    generation,
                    expectedLabelsSummary,
                    labelsReadSerial,
                    allowMissingDetail: true,
                  ),
            );
      if (_detailEpoch != loadEpoch ||
          !_labelsReadCurrent(
            owner,
            generation,
            expectedLabelsSummary,
            labelsReadSerial,
            allowMissingDetail: true,
          ) ||
          (expectedLabelsSummary != null &&
              !_sameWorkItemResource(detail.summary, expectedLabelsSummary))) {
        return;
      }
      final statusRevision = _statusConfirmed?.updatedAt;
      if (_statusWriteToken != null ||
          (statusRevision != null &&
              detail.summary.updatedAt.isBefore(statusRevision))) {
        final kept = _detail;
        if (_statusWriteToken == null &&
            kept != null &&
            owner.project == null &&
            kept.summary.project != null) {
          unawaited(_resolveProjectContext(kept, generation));
        }
        return;
      }
      final previous = _detail;
      final assigneeBusy =
          _assigneesWriteToken != null || _assigneesRefetchPending;
      if (previous != null &&
          assigneeBusy &&
          !_sameWorkItemResource(previous.summary, detail.summary)) {
        _dropAssigneeSession();
      }
      if (previous != null &&
          _milestoneWriteToken != null &&
          !_sameWorkItemResource(previous.summary, detail.summary)) {
        _dropMilestoneWrite();
      }
      if (previous != null &&
          _weightWriteToken != null &&
          !_sameWorkItemResource(previous.summary, detail.summary)) {
        _dropWeightWrite();
      }
      if (previous != null &&
          _labelsWriteToken != null &&
          !_sameWorkItemResource(previous.summary, detail.summary)) {
        _dropLabelSession();
      }
      if (previous != null &&
          !_sameWorkItemResource(previous.summary, detail.summary)) {
        _dropStatusWrite();
      }
      setState(() {
        _detail = detail;
        _datesDetailRevision = detail.summary.updatedAt;
        _healthDetailRevision = detail.summary.updatedAt;
        _labelsHidePreview = false;
        _labelsUnconfirmed = false;
        _statusConfirmed = null;
        if (acknowledge != null &&
            identical(
              acknowledge,
              WorkItemStatusWriteRegistry.instance.terminal(
                owner.api,
                detail.summary.id,
              ),
            )) {
          _statusTerminalSeen = acknowledge;
        }
        if (acknowledgeDates != null &&
            identical(
              acknowledgeDates,
              _DatesWriteRegistry.instance.terminal(
                owner.api,
                detail.summary.id,
              ),
            )) {
          _datesTerminalSeen = acknowledgeDates;
        }
        if (acknowledgeHealth != null &&
            identical(
              acknowledgeHealth,
              _HealthWriteRegistry.instance.terminalFor(
                owner.api,
                detail.summary.id,
              ),
            )) {
          _healthTerminalSeen = acknowledgeHealth;
        }
      });
      _statusRegistryActive = WorkItemStatusWriteRegistry.instance.isActive(
        owner.api,
        detail.summary.id,
      );
      if (_statusRegistryActive) _statusReloadAfterLoad = false;
      _datesRegistryActive = _DatesWriteRegistry.instance.isActive(
        owner.api,
        detail.summary.id,
      );
      if (_datesRegistryActive) _datesReloadAfterLoad = false;
      _healthRegistryActive = _HealthWriteRegistry.instance.isActive(
        owner.api,
        detail.summary.id,
      );
      if (_healthRegistryActive) _healthReloadAfterLoad = false;
      if (_assigneesWriteToken == null && _assigneesHideStalePreview) {
        unawaited(_refetchAssignees(detail, generation));
      }
      if (owner.project == null && detail.summary.project != null) {
        unawaited(_resolveProjectContext(detail, generation));
      }
    } catch (error) {
      if (_detailEpoch != loadEpoch ||
          !_labelsReadCurrent(
            owner,
            generation,
            expectedLabelsSummary,
            labelsReadSerial,
            allowMissingDetail: true,
          )) {
        return;
      }
      _statusReloadAfterLoad = false;
      _datesReloadAfterLoad = false;
      _healthReloadAfterLoad = false;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) {
        setState(() => _error = failure);
      }
    } finally {
      if (_detailEpoch == loadEpoch && _sameLabelOwner(owner, generation)) {
        setState(() => _loading = false);
        if (_statusReloadAfterLoad) {
          unawaited(_load());
        } else if (_datesReloadAfterLoad) {
          unawaited(_load(keepForDates: true));
        } else if (_healthReloadAfterLoad) {
          unawaited(_load(keepForHealth: true));
        }
      }
    }
  }

  Listenable _assigneeOwnerSignals() => widget.ownerChanges == null
      ? _assigneeSignals
      : Listenable.merge([widget.ownerChanges!, _assigneeSignals]);

  void _dropAssigneeSession() {
    _assigneesWriteToken = null;
    _assigneesWriteGeneration = null;
    _assigneeOverlay = null;
    _assigneesHideStalePreview = false;
    _assigneesRefetchPending = false;
    _assigneesRefreshFailed = false;
    _assigneeReadSerial++;
    _assigneeSignals.bump();
  }

  void _dropLabelSession() {
    _labelsWriteToken = null;
    _labelsWriteGeneration = null;
    _labelsHidePreview = false;
    _labelsUnconfirmed = false;
    _labelsReadSerial++;
    _labelsRefetchSerial = null;
  }

  void _onLabelWrite(WorkItemLabelWritePhase phase, Object token) {
    if (!mounted) return;
    if (phase == WorkItemLabelWritePhase.start) {
      final detail = _detail;
      if (detail == null ||
          !_current(_generation) ||
          _labelsWriteToken != null) {
        return;
      }
      _labelsReadSerial++;
      setState(() {
        _labelsWriteToken = token;
        _labelsWriteGeneration = _generation;
        _labelsHidePreview = true;
        _labelsUnconfirmed = false;
      });
      return;
    }
    if (!identical(_labelsWriteToken, token) ||
        _labelsWriteGeneration != _generation) {
      return;
    }
    final detail = _detail;
    final generation = _labelsWriteGeneration!;
    final serial = ++_labelsReadSerial;
    if (detail == null || !_current(generation)) {
      setState(() {
        _labelsWriteToken = null;
        _labelsWriteGeneration = null;
      });
      return;
    }
    setState(() {
      _labelsWriteToken = null;
      _labelsWriteGeneration = null;
      _labelsRefetchSerial = serial;
    });
    unawaited(_refetchLabelsDetail(generation, detail.summary, serial));
  }

  Future<void> _refetchLabelsDetail(
    int generation,
    WorkItemGraphSummary expectedSummary,
    int serial,
  ) async {
    final owner = widget;
    try {
      final detail = owner.project == null
          ? await owner.api.namespaceWorkItem(
              owner.namespacePath,
              owner.iid,
              expectedNamespaceId: owner.expectedNamespaceId,
              isCurrent: () => _labelsReadCurrent(
                owner,
                generation,
                expectedSummary,
                serial,
                allowMissingDetail: false,
              ),
            )
          : await owner.api.projectWorkItem(
              owner.project!,
              owner.iid,
              isCurrent: () => _labelsReadCurrent(
                owner,
                generation,
                expectedSummary,
                serial,
                allowMissingDetail: false,
              ),
            );
      if (!_labelsReadCurrent(
        owner,
        generation,
        expectedSummary,
        serial,
        allowMissingDetail: false,
      )) {
        return;
      }
      if (!_sameWorkItemResource(detail.summary, expectedSummary)) return;
      final statusRevision = _statusConfirmed?.updatedAt;
      if (_statusWriteToken != null ||
          (statusRevision != null &&
              detail.summary.updatedAt.isBefore(statusRevision))) {
        setState(() {
          _labelsHidePreview = true;
          _labelsUnconfirmed = true;
        });
        return;
      }
      setState(() {
        _detail = detail;
        _datesDetailRevision = detail.summary.updatedAt;
        _healthDetailRevision = detail.summary.updatedAt;
        _labelsHidePreview = false;
        _labelsUnconfirmed = false;
        _statusConfirmed = null;
      });
    } catch (_) {
      if (!_labelsReadCurrent(
        owner,
        generation,
        expectedSummary,
        serial,
        allowMissingDetail: false,
      )) {
        return;
      }
      setState(() {
        _labelsHidePreview = true;
        _labelsUnconfirmed = true;
      });
    } finally {
      if (mounted && _labelsRefetchSerial == serial) {
        setState(() => _labelsRefetchSerial = null);
      }
    }
  }

  bool _sameWorkItemResource(
    WorkItemGraphSummary left,
    WorkItemGraphSummary right,
  ) {
    return left.id == right.id &&
        left.iid == right.iid &&
        left.type.id == right.type.id &&
        left.project?.id == right.project?.id &&
        left.project?.fullPath == right.project?.fullPath &&
        left.namespace?.id == right.namespace?.id &&
        left.namespace?.fullPath == right.namespace?.fullPath;
  }

  void _dropMetadataWrites() {
    _dropMilestoneWrite();
    _dropWeightWrite();
    _dropStatusWrite();
    _dropDatesWrite();
    _dropHealthWrite();
  }

  /// Forgets the parent's STATUS hold for an old owner or resource. The
  /// write itself still settles through its own `finally`, which also clears
  /// the per-client registry; nothing here releases that early.
  void _dropStatusWrite() {
    _statusWriteToken = null;
    _statusWriteGeneration = null;
    _statusWriteSummary = null;
    _statusConfirmed = null;
    _statusUnconfirmed = false;
    _statusReloadOnSettle = false;
  }

  bool _statusWriteMatches(
    Object token,
    Account account,
    GitLabApi api,
    int sessionGeneration,
  ) {
    final summary = _statusWriteSummary;
    final current = _detail;
    return identical(_statusWriteToken, token) &&
        _statusWriteGeneration == _generation &&
        account.key == widget.account.key &&
        identical(api, widget.api) &&
        sessionGeneration == _sessionGeneration &&
        _sessionCurrent &&
        summary != null &&
        current != null &&
        _current(_generation) &&
        _sameWorkItemResource(summary, current.summary);
  }

  void _onStatusWrite(
    WorkItemStatusWritePhase phase,
    Object token,
    Account account,
    GitLabApi api,
    WorkItemGraphDetail detail,
    int sessionGeneration,
  ) {
    if (!mounted) return;
    if (phase == WorkItemStatusWritePhase.start) {
      if (_statusWriteToken != null ||
          sessionGeneration != _sessionGeneration ||
          !_sessionCurrent ||
          !_acceptsMetadataWriteStart(account, api, detail)) {
        return;
      }
      setState(() {
        _statusWriteToken = token;
        _statusWriteGeneration = _generation;
        _statusWriteSummary = detail.summary;
        _statusUnconfirmed = false;
        _statusReloadOnSettle = false;
      });
      return;
    }
    if (!identical(_statusWriteToken, token)) return;
    final matches = _statusWriteMatches(
      token,
      account,
      api,
      sessionGeneration,
    );
    final reload = matches && _statusReloadOnSettle;
    setState(() {
      _statusWriteToken = null;
      _statusWriteGeneration = null;
      _statusWriteSummary = null;
      _statusReloadOnSettle = false;
      _statusTerminalSeen = WorkItemStatusWriteRegistry.instance.terminal(
        api,
        detail.summary.id,
      );
    });
    if (reload) unawaited(_load());
  }

  /// Runs from the write's `finally` just before SETTLE, while the parent
  /// still holds the token.
  void _onStatusOutcome(
    Object token,
    WorkItemStatusSaveResult? confirmed, {
    required bool mutationSent,
  }) {
    if (!mounted ||
        !_statusWriteMatches(
          token,
          widget.account,
          widget.api,
          _sessionGeneration ?? -1,
        )) {
      return;
    }
    if (confirmed == null ||
        confirmed.status == WorkItemStatusSaveStatus.notApplied) {
      setState(() {
        _statusConfirmed = null;
        _statusUnconfirmed = confirmed == null && mutationSent;
        _statusReloadOnSettle = true;
      });
      return;
    }
    _applyStatusSnapshot(confirmed.snapshot);
  }

  /// A confirmed no-op save never reaches START; its fresh snapshot still
  /// settles the row and revision.
  void _onStatusSaved(WorkItemStatusSaveResult result) {
    if (_statusHeld ||
        result.status != WorkItemStatusSaveStatus.noop ||
        !_current(_generation) ||
        !_sessionCurrent) {
      return;
    }
    _applyStatusSnapshot(result.snapshot);
  }

  void _applyStatusSnapshot(WorkItemStatusSnapshot snapshot) {
    final detail = _detail;
    if (detail == null ||
        snapshot.accountKey != widget.account.key ||
        snapshot.generation != _sessionGeneration) {
      return;
    }
    final summary = detail.summary;
    if (snapshot.id != summary.id ||
        snapshot.iid != summary.iid ||
        snapshot.project?.id != summary.project?.id ||
        snapshot.namespace?.id != summary.namespace?.id ||
        snapshot.typeId != summary.type.id ||
        snapshot.updatedAt.isBefore(summary.updatedAt)) {
      return;
    }
    final state = snapshot.state == WorkItemState.open ? 'OPEN' : 'CLOSED';
    setState(() {
      _statusConfirmed = snapshot;
      _statusUnconfirmed = false;
      _statusReloadOnSettle = false;
      _detail = _withSummary(
        detail,
        WorkItemGraphSummary(
          id: summary.id,
          iid: summary.iid,
          title: summary.title,
          state: state,
          createdAt: summary.createdAt,
          updatedAt: snapshot.updatedAt,
          project: summary.project,
          namespace: summary.namespace,
          type: summary.type,
        ),
      );
    });
  }

  WorkItemGraphDetail _withSummary(
    WorkItemGraphDetail detail,
    WorkItemGraphSummary summary,
  ) => WorkItemGraphDetail(
    summary: summary,
    description: detail.description,
    widgetsAvailable: detail.widgetsAvailable,
    widgetTypes: detail.widgetTypes,
    descriptionWidget: detail.descriptionWidget,
    assignees: detail.assignees,
    labels: detail.labels,
    hierarchy: detail.hierarchy,
    dates: detail.dates,
  );

  Future<WorkItemStateSnapshot> _loadStateGuarded(
    WorkItemGraphSummary expected, {
    bool Function()? isCurrent,
  }) async {
    if (_statusWriteToken != null ||
        WorkItemStatusWriteRegistry.instance.isActive(
          widget.api,
          expected.id,
        ) ||
        _datesHeldFor(expected) ||
        _healthHeldFor(expected)) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    _stateOperations++;
    try {
      return await widget.api.workItemState(
        expected,
        isCurrent: () =>
            !_statusHeldFor(expected) &&
            !_datesHeldFor(expected) &&
            !_healthHeldFor(expected) &&
            (isCurrent?.call() ?? true),
      );
    } finally {
      _stateOperationSettled();
    }
  }

  bool _statusHeldFor(WorkItemGraphSummary expected) =>
      _statusWriteToken != null ||
      WorkItemStatusWriteRegistry.instance.isActive(widget.api, expected.id);

  /// The STATUS editor reads the counter at build time and nothing else
  /// rebuilds it when a lifecycle operation ends. Always runs after an await.
  void _stateOperationSettled() {
    _stateOperations--;
    if (mounted) setState(() {});
  }

  Future<WorkItemStateSnapshot> _updateStateGuarded(
    WorkItemGraphSummary expected,
    WorkItemStateEvent event, {
    required DateTime expectedUpdatedAt,
    bool Function()? isCurrent,
  }) async {
    if (_statusWriteToken != null ||
        WorkItemStatusWriteRegistry.instance.isActive(
          widget.api,
          expected.id,
        ) ||
        _datesHeldFor(expected) ||
        _healthHeldFor(expected)) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    _stateOperations++;
    try {
      return await widget.api.updateWorkItemState(
        expected,
        event,
        expectedUpdatedAt: expectedUpdatedAt,
        isCurrent: () =>
            !_statusHeldFor(expected) &&
            !_datesHeldFor(expected) &&
            !_healthHeldFor(expected) &&
            (isCurrent?.call() ?? true),
      );
    } finally {
      _stateOperationSettled();
    }
  }

  void _dropMilestoneWrite() {
    _milestoneWriteToken = null;
    _milestoneWriteGeneration = null;
    _milestoneWriteAccount = null;
    _milestoneWriteApi = null;
    _milestoneWriteSummary = null;
  }

  void _dropWeightWrite() {
    _weightWriteToken = null;
    _weightWriteGeneration = null;
    _weightWriteAccount = null;
    _weightWriteApi = null;
    _weightWriteSummary = null;
  }

  bool _acceptsMetadataWriteStart(
    Account account,
    GitLabApi api,
    WorkItemGraphDetail detail,
  ) {
    final current = _detail;
    return current != null &&
        _current(_generation) &&
        account.key == widget.account.key &&
        identical(api, widget.api) &&
        _sameWorkItemResource(detail.summary, current.summary);
  }

  void _onMilestoneWrite(
    WorkItemMilestoneWritePhase phase,
    Object token,
    Account account,
    GitLabApi api,
    WorkItemGraphDetail detail,
  ) {
    if (!mounted) return;
    if (phase == WorkItemMilestoneWritePhase.start) {
      if (_milestoneWriteToken != null ||
          !_acceptsMetadataWriteStart(account, api, detail)) {
        return;
      }
      setState(() {
        _milestoneWriteToken = token;
        _milestoneWriteGeneration = _generation;
        _milestoneWriteAccount = account.key;
        _milestoneWriteApi = api;
        _milestoneWriteSummary = detail.summary;
      });
      return;
    }
    final summary = _milestoneWriteSummary;
    final current = _detail;
    if (!identical(_milestoneWriteToken, token) ||
        _milestoneWriteGeneration != _generation ||
        _milestoneWriteAccount != account.key ||
        !identical(_milestoneWriteApi, api) ||
        summary == null ||
        current == null ||
        !_current(_generation) ||
        !_sameWorkItemResource(summary, detail.summary) ||
        !_sameWorkItemResource(summary, current.summary)) {
      return;
    }
    setState(_dropMilestoneWrite);
  }

  void _onWeightWrite(
    WorkItemWeightWritePhase phase,
    Object token,
    Account account,
    GitLabApi api,
    WorkItemGraphDetail detail,
  ) {
    if (!mounted) return;
    if (phase == WorkItemWeightWritePhase.start) {
      if (_weightWriteToken != null ||
          !_acceptsMetadataWriteStart(account, api, detail)) {
        return;
      }
      setState(() {
        _weightWriteToken = token;
        _weightWriteGeneration = _generation;
        _weightWriteAccount = account.key;
        _weightWriteApi = api;
        _weightWriteSummary = detail.summary;
      });
      return;
    }
    final summary = _weightWriteSummary;
    final current = _detail;
    if (!identical(_weightWriteToken, token) ||
        _weightWriteGeneration != _generation ||
        _weightWriteAccount != account.key ||
        !identical(_weightWriteApi, api) ||
        summary == null ||
        current == null ||
        !_current(_generation) ||
        !_sameWorkItemResource(summary, detail.summary) ||
        !_sameWorkItemResource(summary, current.summary)) {
      return;
    }
    setState(_dropWeightWrite);
  }

  void _onAssigneesWrite(WorkItemAssigneesWritePhase phase, Object token) {
    if (!mounted) return;
    if (phase == WorkItemAssigneesWritePhase.start) {
      final detail = _detail;
      if (detail == null || !_current(_generation)) return;
      setState(() {
        _assigneesWriteToken = token;
        _assigneesWriteGeneration = _generation;
        _assigneesHideStalePreview = true;
        _assigneesRefetchPending = false;
        _assigneesRefreshFailed = false;
        _assigneeOverlay = null;
        _assigneeReadSerial++;
      });
      return;
    }
    if (!identical(_assigneesWriteToken, token)) return;
    final detail = _detail;
    final generation = _generation;
    setState(() {
      _assigneesWriteToken = null;
      _assigneesRefetchPending = detail != null && _current(generation);
      _assigneesRefreshFailed = false;
    });
    if (detail == null || !_current(generation)) return;
    unawaited(_refetchAssignees(detail, generation));
  }

  void _acceptAssigneeSave(WorkItemAssigneeSnapshot snapshot) {
    final detail = _detail;
    if (!mounted || detail == null || _assigneesWriteToken == null) return;
    if (_assigneesWriteGeneration != _generation || !_current(_generation)) {
      return;
    }
    if (!_sameWorkItemResource(detail.summary, snapshot.summary)) return;
  }

  Future<void> _refetchAssignees(
    WorkItemGraphDetail detail,
    int generation,
  ) async {
    final serial = ++_assigneeReadSerial;
    final startedToken = _assigneesWriteToken;
    try {
      final access = await widget.api.workItemAssignees(
        detail,
        expectedUserId: widget.account.user.id,
        isCurrent: () =>
            _current(generation) &&
            identical(_assigneesWriteToken, startedToken) &&
            _assigneeReadSerial == serial,
      );
      if (!mounted ||
          !_current(generation) ||
          !identical(_assigneesWriteToken, startedToken) ||
          _assigneeReadSerial != serial ||
          _detail == null ||
          !_sameWorkItemResource(_detail!.summary, detail.summary)) {
        return;
      }
      setState(() {
        _assigneeOverlay = access.snapshot;
        _assigneesHideStalePreview = false;
        _assigneesRefetchPending = false;
        _assigneesRefreshFailed = false;
      });
    } catch (error) {
      if (!mounted || !_current(generation) || _assigneeReadSerial != serial) {
        return;
      }
      final failure = safeFailure(error);
      if (failure.kind == FailureKind.cancelled) return;
      setState(() {
        _assigneesRefetchPending = false;
        _assigneesRefreshFailed = true;
      });
    }
  }

  Future<void> _openAssigneeRoster(WorkItemAssigneeSnapshot snapshot) async {
    final generation = _generation;
    final navigator = Navigator.of(context);
    final route = MaterialPageRoute<void>(
      builder: (context) => WorkItemAssigneeRosterPage(users: snapshot.users),
    );
    _ownRoute(route);
    await navigator.push(route);
    if (!_current(generation)) return;
  }

  Future<void> _resolveProjectContext(
    WorkItemGraphDetail detail,
    int generation, {
    bool refresh = false,
  }) async {
    final projectRef = detail.summary.project;
    if (projectRef == null || _resolvingProject) return;
    setState(() {
      _resolvingProject = true;
      _projectContextError = null;
    });
    try {
      final project = await widget.api.project(
        projectRef.fullPath,
        refresh: refresh,
      );
      if (!_current(generation) || !identical(_detail, detail)) return;
      final match = RegExp(
        r'^gid://gitlab/Project/([1-9][0-9]*)$',
      ).firstMatch(projectRef.id);
      if (match == null ||
          int.parse(match.group(1)!) != project.id ||
          project.path != projectRef.fullPath) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      setState(() => _resolvedProject = project);
    } catch (error) {
      if (!_current(generation) || !identical(_detail, detail)) return;
      final failure = safeFailure(error);
      if (failure.kind != FailureKind.cancelled) {
        setState(() => _projectContextError = failure);
      }
    } finally {
      if (_current(generation) && identical(_detail, detail)) {
        setState(() => _resolvingProject = false);
      }
    }
  }

  void _retryProjectContext() {
    final detail = _detail;
    if (detail == null || _resolvingProject || !_current(_generation)) return;
    unawaited(_resolveProjectContext(detail, _generation, refresh: true));
  }

  Future<void> _applyStateSnapshot(WorkItemStateSnapshot snapshot) async {
    final generation = _generation;
    final detail = _detail;
    if (detail == null || !_current(generation)) return;
    if (_statusHeld || _datesHeld || _healthHeld) return;
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
    if (_statusConfirmed != null &&
        snapshot.updatedAt.isBefore(summary.updatedAt)) {
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
    final confirmedRevision = _statusConfirmed?.updatedAt;
    setState(() {
      if (confirmedRevision != null &&
          snapshot.updatedAt.isAfter(confirmedRevision)) {
        _statusConfirmed = null;
      }
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
          sessionGeneration: _sessionGeneration,
        ),
      );
      return;
    }
    final projectRef = item.project;
    if (projectRef == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.relatedItemNamespaceMissing)),
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
          sessionGeneration: _sessionGeneration,
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

  Widget _assigneePreview(
    BuildContext context,
    WorkItemGraphDetail detail,
    BoundedGraphConnection<WorkItemGraphAssignee> preview,
  ) {
    final overlay = _assigneeOverlay;
    final pending = _assigneesWriteToken != null || _assigneesRefetchPending;
    final people = <WorkItemGraphAssignee>[];
    if (!pending && !_assigneesHideStalePreview) {
      if (overlay != null) {
        for (final user in overlay.users.take(20)) {
          people.add(
            WorkItemGraphAssignee(
              id: user.id,
              name: user.name,
              username: user.username,
            ),
          );
        }
      } else {
        people.addAll(preview.items.take(20));
      }
    }
    final total = overlay?.users.length;
    final generation = _generation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (pending)
          Text(l10n.updating, key: ValueKey('work-item-assignees-updating'))
        else if (_assigneesRefreshFailed)
          Text(
            l10n.assigneesUnconfirmed,
            key: ValueKey('work-item-assignees-unconfirmed'),
          )
        else if (people.isEmpty)
          Text(l10n.unassigned)
        else
          Wrap(
            key: const ValueKey('work-item-assignee-preview'),
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final person in people)
                Chip(
                  key: ValueKey('work-item-assignee-preview-${person.id}'),
                  avatar: Monogram(
                    person.name.isEmpty ? person.username : person.name,
                    size: 24,
                  ),
                  label: Text(
                    person.name.isEmpty
                        ? isolated('@${person.username}')
                        : '${isolated(person.name)} · ${isolated('@${person.username}')}',
                  ),
                ),
            ],
          ),
        if (!pending && total != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              total == 0
                  ? l10n.noAssignees
                  : total <= 20
                  ? l10n.assigneeTotal(total)
                  : l10n.assigneeTotalFirstTwenty(total),
              key: const ValueKey('work-item-assignee-count'),
            ),
          )
        else if (!pending && !_assigneesHideStalePreview && preview.isPartial)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(l10n.assigneesFirstTwentyOnly),
          ),
        if (!pending && total != null && total > 20)
          TextButton(
            key: const ValueKey('work-item-assignees-roster'),
            onPressed: () => unawaited(_openAssigneeRoster(overlay!)),
            child: Text(l10n.viewAllAssignees(total)),
          )
        else if (!pending && preview.isPartial && overlay == null)
          TextButton(
            key: const ValueKey('work-item-assignees-read-all'),
            onPressed: () => unawaited(_refetchAssignees(detail, generation)),
            child: Text(l10n.loadAllAssignees),
          ),
        WorkItemAssigneesControl(
          account: widget.account,
          api: widget.api,
          detail: detail,
          isCurrent: () =>
              _current(generation) &&
              !_statusHeld &&
              !_datesHeld &&
              !_healthHeld,
          ownerChanges: _assigneeOwner,
          onRoute: _ownRoute,
          onAssigneesWrite: _onAssigneesWrite,
          writePending: _assigneesWriteToken != null,
          onSaved: _acceptAssigneeSave,
        ),
      ],
    );
  }

  Widget _labelsPreview(
    BuildContext context,
    WorkItemGraphDetail detail,
    BoundedGraphConnection<WorkItemGraphLabel>? labels,
  ) {
    final generation = _generation;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_labelsHidePreview)
          Text(
            _labelsUnconfirmed ? l10n.labelsUnconfirmed : l10n.updatingLabels,
            key: ValueKey(
              _labelsUnconfirmed
                  ? 'work-item-labels-unconfirmed'
                  : 'work-item-labels-updating',
            ),
          )
        else if (labels != null) ...[
          if (labels.items.isEmpty)
            Text(l10n.noLabels)
          else
            Wrap(
              key: const ValueKey('work-item-labels-preview'),
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final label in labels.items)
                  Chip(
                    key: ValueKey('work-item-label-chip-${label.id}'),
                    avatar: CircleAvatar(
                      backgroundColor: _color(label.color),
                      radius: 7,
                    ),
                    label: Text(label.title),
                  ),
              ],
            ),
          if (labels.isPartial)
            Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(l10n.labelsFirstFiftyOnly),
            ),
        ] else
          Text(l10n.labelListNotReturned),
        WorkItemLabelsControl(
          account: widget.account,
          api: widget.api,
          detail: detail,
          generation: generation,
          isCurrent: () =>
              _current(generation) &&
              !_statusHeld &&
              !_datesHeld &&
              !_healthHeld,
          ownerChanges: widget.ownerChanges,
          onRoute: _ownLabelRoute,
          onLabelWrite: _onLabelWrite,
          writePending: _labelsWriteToken != null,
        ),
      ],
    );
  }

  /// The chips come only from a full detail read; a stale detail hides them
  /// rather than painting dates older than a confirmed write.
  Widget _datesBody(WorkItemGraphDetail detail, WorkItemDatesWidget dates) {
    final held = _datesHeld;
    final stale = !held && _datesStale;
    final unconfirmed = !held && !stale && _datesUnconfirmed;
    final sessionGeneration = _sessionGeneration;
    final owner = _DatesWriteOwner(
      pageGeneration: _generation,
      sessionGeneration: sessionGeneration,
      account: widget.account,
      api: widget.api,
      summary: detail.summary,
    );
    final showControl =
        detail.widgetsAvailable && _current(_generation) && _sessionCurrent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!_datesStale)
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (dates.startDate != null)
                MetaChip(
                  l10n.startDateValue(workItemCalendarDate(dates.startDate!)),
                  icon: Icons.play_arrow_outlined,
                ),
              if (dates.dueDate != null)
                MetaChip(
                  l10n.dueDateValue(workItemCalendarDate(dates.dueDate!)),
                  icon: Icons.event_outlined,
                ),
              if (dates.startDate == null && dates.dueDate == null)
                Text(l10n.noStartOrDueDate),
              if (dates.rollUp == true)
                MetaChip(l10n.datesRolledUpFromHierarchy, icon: Icons.account_tree_outlined),
            ],
          ),
        if (held)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              l10n.datesUpdatingLocked,
              key: ValueKey('work-item-dates-hold'),
            ),
          )
        else if (stale)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              l10n.datesUnconfirmed,
              key: ValueKey('work-item-dates-stale'),
            ),
          )
        else if (unconfirmed)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              l10n.datesUpdateUnconfirmed,
              key: ValueKey('work-item-dates-unconfirmed'),
            ),
          ),
        KeyedSubtree(
          key: const ValueKey('work-item-dates-control-slot'),
          child: showControl && sessionGeneration != null
              ? WorkItemDatesControl(
                  api: widget.api,
                  account: widget.account,
                  detail: detail,
                  generation: sessionGeneration,
                  isCurrent: _datesIsCurrent,
                  enabled: _datesDispatchAllowed(),
                  onDatesWrite: (phase, token) =>
                      _onDatesPhase(owner, phase, token),
                  onSaved: _onDatesSaved,
                  ownerChanges: null,
                  onRoute: _ownRoute,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _healthBody(WorkItemGraphDetail detail) {
    final held = _healthHeld;
    final stale = !held && _healthStale;
    final unconfirmed = !held && !stale && _healthUnconfirmed;
    final sessionGeneration = _sessionGeneration;
    final owner = _HealthWriteOwner(
      pageGeneration: _generation,
      sessionGeneration: sessionGeneration,
      account: widget.account,
      api: widget.api,
      summary: detail.summary,
    );
    final hasHealthWidget =
        detail.widgetsAvailable &&
        detail.widgetTypes.any((t) => t.toUpperCase() == 'HEALTH_STATUS');
    final showControl =
        hasHealthWidget &&
        sessionGeneration != null &&
        _current(_generation) &&
        _sessionCurrent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (held)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              l10n.healthStatusUpdatingLocked,
              key: ValueKey('work-item-health-hold'),
            ),
          )
        else if (stale)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              l10n.healthStatusUnconfirmed,
              key: ValueKey('work-item-health-stale'),
            ),
          )
        else if (unconfirmed)
          Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              l10n.healthStatusUpdateUnconfirmed,
              key: ValueKey('work-item-health-unconfirmed'),
            ),
          ),
        KeyedSubtree(
          key: const ValueKey('work-item-health-control-slot'),
          child: showControl
              ? WorkItemHealthControl(
                  key: ValueKey(_healthControlEpoch),
                  api: widget.api,
                  account: widget.account,
                  detail: detail,
                  generation: sessionGeneration,
                  isCurrent: _healthIsCurrent,
                  changes: _InertListenable.instance,
                  enabled: _healthDispatchAllowed(),
                  reserveWrite: (token) => _onHealthReserve(owner, token),
                  releaseUnsentWrite: _onHealthReleaseUnsent,
                  onWritePhase: (phase, token) =>
                      _onHealthPhase(owner, phase, token),
                  onOutcome: (token, outcome) =>
                      _onHealthOutcome(owner, token, outcome),
                  onRoute: _ownRoute,
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
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
    if (_statusHeld || _datesHeld || _healthHeld) return false;
    final closing = event == WorkItemStateEvent.close;
    final route = DialogRoute<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(closing ? l10n.closeWorkItemConfirm : l10n.reopenWorkItemConfirm),
        content: Text(
          closing
              ? l10n.confirmCloseWorkItem(widget.account.user.username, widget.account.instance.key, widget.namespacePath, widget.iid)
              : l10n.confirmReopenWorkItem(widget.account.user.username, widget.account.instance.key, widget.namespacePath, widget.iid),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancelAction),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(closing ? l10n.confirmClose : l10n.confirmReopen),
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
    final project = widget.project ?? _resolvedProject;
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
        WorkItemContentControl(
          account: widget.account,
          api: widget.api,
          detail: detail,
          project: project,
          isCurrent: widget.isCurrent,
          ownerChanges: widget.ownerChanges,
          onRoute: _ownRoute,
          onSaved: _load,
        ),
        const SizedBox(height: 8),
        Text(
          l10n.createdAndUpdatedAt(_instantDate(summary.createdAt), _instantDate(summary.updatedAt)),
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
          _section(context, l10n.descriptionLabel, Text(l10n.noDescription)),
        WorkItemStateControl(
          account: widget.account,
          api: widget.api,
          summary: summary,
          isCurrent: widget.isCurrent,
          ownerChanges: widget.ownerChanges,
          loadState: _stateLoader,
          updateState: _stateUpdater,
          confirmChange: _confirmStateChange,
          onChanged: _applyStateSnapshot,
        ),
        WorkItemNotificationsControl(
          account: widget.account,
          api: widget.api,
          summary: summary,
          isCurrent: widget.isCurrent,
          ownerChanges: widget.ownerChanges,
        ),
        WorkItemAttributesPanel(
          account: widget.account,
          api: widget.api,
          detail: detail,
          isCurrent: widget.isCurrent,
          ownerChanges: widget.ownerChanges,
          onRoute: _ownRoute,
          milestoneWritePending: _milestoneWriteToken != null,
          weightWritePending: _weightWriteToken != null,
          onMilestoneWrite: _onMilestoneWrite,
          onWeightWrite: _onWeightWrite,
          statusSessionGeneration: _sessionGeneration,
          statusWriteHeld: _statusHeld,
          datesWriteHeld: _datesHeld,
          healthWriteHeld: _healthHeld,
          healthStale: _healthStale,
          healthUnconfirmed: _healthUnconfirmed,
          statusConfirmed: _statusConfirmed,
          statusUnconfirmed: _statusUnconfirmed || _statusForeignUnconfirmed,
          statusStale: _statusStale,
          onStatusWrite: _onStatusWrite,
          onStatusOutcome: _onStatusOutcome,
          onStatusSaved: _onStatusSaved,
          statusDispatchAllowed: _statusDispatchAllowed,
          statusOperationCurrent: () =>
              _current(_generation) && _sessionCurrent,
        ),
        if (_statusHeld)
          Padding(
            key: ValueKey('work-item-status-hold-banner'),
            padding: EdgeInsets.symmetric(vertical: 6),
            child: Text(l10n.statusUpdatingLocked),
          ),
        if (assignees != null)
          _section(
            context,
            l10n.assigneesLabel,
            _assigneePreview(context, detail, assignees),
          ),
        if (detail.assignees != null && assignees == null)
          _section(context, l10n.assigneesLabel, Text(l10n.assigneeListNotReturned)),
        if (detail.labels != null)
          _section(context, l10n.labelNoun, _labelsPreview(context, detail, labels)),
        if (hierarchy != null)
          _section(
            context,
            l10n.hierarchySection,
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hierarchy.parent != null) ...[
                  Text(l10n.parentItem, style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  _HierarchyTile(
                    item: hierarchy.parent!,
                    onTap: () => unawaited(_openHierarchy(hierarchy.parent!)),
                  ),
                ] else if (hierarchy.hasParent == true)
                  Text(l10n.parentItemNotOpenable),
                if (hierarchy.children != null) ...[
                  if (hierarchy.parent != null) const Divider(height: 24),
                  Text(l10n.childItems, style: Theme.of(context).textTheme.labelLarge),
                  if (hierarchy.children!.items.isEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(l10n.noChildItems),
                    ),
                  for (final child in hierarchy.children!.items)
                    _HierarchyTile(
                      item: child,
                      onTap: () => unawaited(_openHierarchy(child)),
                    ),
                  if (hierarchy.children!.isPartial)
                    Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(l10n.childItemsFirstTwenty),
                    ),
                ] else if (hierarchy.hasChildren == true)
                  Text(l10n.childItemsNotReturned),
              ],
            ),
          ),
        if (dates != null)
          KeyedSubtree(
            key: const ValueKey('work-item-dates-section'),
            child: _section(
              context,
              l10n.datesSection,
              _datesBody(detail, dates),
            ),
          ),
        if (detail.widgetsAvailable &&
            detail.widgetTypes.any((t) => t.toUpperCase() == 'HEALTH_STATUS'))
          KeyedSubtree(
            key: const ValueKey('work-item-health-section'),
            child: _section(
              context,
              l10n.healthStatus,
              _healthBody(detail),
            ),
          ),
        WorkItemActivityPanel(
          account: widget.account,
          api: widget.api,
          detail: detail,
          project: project,
          isCurrent: widget.isCurrent,
          ownerChanges: widget.ownerChanges,
          onRoute: _ownRoute,
        ),
        if (widget.project == null && summary.project != null) ...[
          if (_resolvingProject)
            _section(
              context,
              l10n.projectMarkdownIntegration,
              Row(
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Expanded(child: Text(l10n.verifyingProjectIdentity)),
                ],
              ),
            )
          else if (_projectContextError case final error?)
            _section(
              context,
              l10n.projectMarkdownIntegration,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.workItemPlainMarkdownFallback),
                  const SizedBox(height: 10),
                  FailureNotice(
                    error,
                    key: const ValueKey('work-item-project-context-failure'),
                    account: widget.account,
                    resourceLabel: summary.project!.fullPath,
                    onRetry: _retryProjectContext,
                    onSwitchAccount: endSessionFrom(context),
                  ),
                ],
              ),
            ),
        ],
        if (!detail.widgetsAvailable)
          _section(
            context,
            l10n.detailsSection,
            Text(l10n.workItemWidgetsMissing),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_ownerInvalid || !(widget.isCurrent?.call() ?? true)) {
      return Scaffold(
        body: SafeArea(child: Center(child: Text(l10n.accountSwitchedWorkItemClosed))),
      );
    }
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: (MediaQuery.textScalerOf(context).scale(19) * 1.3 + 16)
            .clamp(56, double.infinity),
        title: Text(
          l10n.workItemIid(widget.iid),
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
            onPressed:
                _loading ||
                    _labelsWriteToken != null ||
                    _statusHeld ||
                    _datesHeld ||
                    _healthHeld
                ? null
                : _refresh,
            tooltip: l10n.refreshAction,
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
            resourceLabel: l10n.workItemPageTitle(widget.namespacePath, widget.iid),
            onRetry: _refresh,
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
    // Readable text only, cut on a character boundary.
    final normalized = markdownSummary(widget.description, 160).text.trim().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    _preview = normalized.characters.take(80).toString();
  }

  @override
  Widget build(BuildContext context) {
    final project = widget.project;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: _characterCount <= _collapsedThreshold,
        maintainState: false,
        title: Text(l10n.descriptionLabel, style: Theme.of(context).textTheme.titleMedium),
        subtitle: Text(
          l10n.characterCountWithSuffix(_characterCount, _preview.isEmpty ? '' : ' · $_preview'),
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
    title: Text(isolated(item.title), maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Text('${item.type.name} · ${isolated('#${item.iid}')}'),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );
}
