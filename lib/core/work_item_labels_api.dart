part of 'gitlab_api.dart';

const _labelPageSize = 100;
const _labelPageLimit = 20;
const _labelCandidatePageSize = 20;
const _aiLabelCandidatePageSize = 100;
const _labelCandidatePageLimit = 5;
const _labelTitleLimit = 255;

ApiFailure get _labelsReadForbidden => ApiFailure(
  FailureKind.forbidden,
  title: l10n.cannotReadWorkItemLabels,
  detail: l10n.noPermissionReadWorkItem,
);
ApiFailure get _labelsWriteForbidden => ApiFailure(
  FailureKind.forbidden,
  title: l10n.noPermissionChangeLabels,
  detail: l10n.needReadAndSetMetadata,
);
ApiFailure get _labelsUnsupported => ApiFailure(
  FailureKind.unsupported,
  title: l10n.labelsIncompleteCannotEdit,
  detail: l10n.labelConnectionIncomplete,
);
ApiFailure get _labelsInvalid => ApiFailure(
  FailureKind.validation,
  title: l10n.invalidLabelIdentifier,
  detail: l10n.useLoadedLabelCandidates,
);
ApiFailure get _labelsSearchInvalid => ApiFailure(
  FailureKind.validation,
  title: l10n.invalidLabelSearch,
  detail: l10n.searchLengthNoControlChars,
);
ApiFailure get _labelsConflict => ApiFailure(
  FailureKind.conflict,
  title: l10n.workItemUpdatedRefresh,
  detail: l10n.labelsScopeRevisionChanged,
);
ApiFailure get _labelsUncertain => ApiFailure(
  FailureKind.writeUncertain,
  title: l10n.cannotConfirmWriteResult,
  detail: l10n.refreshDoNotResubmit,
);
ApiFailure get _labelsSpent => ApiFailure(
  FailureKind.writeUncertain,
  title: l10n.cannotConfirmWriteResult,
  detail: l10n.editAlreadyUsedNoResubmit,
);
const _labelsCancelled = ApiFailure(FailureKind.cancelled);

final _labelGid = RegExp(
  r'^gid://gitlab/(Label|GroupLabel|ProjectLabel)/[1-9][0-9]*$',
);

const _workItemLabelsQuery = r'''
query MobileWorkItemLabels($id: WorkItemID!, $after: String) {
  currentUser { id }
  workItem(id: $id) {
    id
    iid
    title
    state
    createdAt
    updatedAt
    project { id fullPath }
    namespace { id fullPath }
    workItemType {
      id
      name
      widgetDefinitions {
        type
        ... on WorkItemWidgetDefinitionLabels { allowsScopedLabels }
      }
    }
    userPermissions { readWorkItem setWorkItemMetadata }
    widgets(onlyTypes: [LABELS]) {
      type
      ... on WorkItemWidgetLabels {
        labels(first: 100, after: $after) {
          nodes { id title color textColor }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
''';

const _workItemLabelCandidatesQuery = r'''
query MobileProjectLabelCandidates(
  $fullPath: ID!, $search: String!, $after: String
) {
  currentUser { id }
  project(fullPath: $fullPath) {
    id
    fullPath
    labels(
      searchTerm: $search
      searchIn: [TITLE]
      includeAncestorGroups: true
      archived: false
      first: 20
      after: $after
    ) {
      nodes { id title color textColor }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

const _groupWorkItemLabelCandidatesQuery = r'''
query MobileGroupLabelCandidates(
  $fullPath: ID!, $search: String!, $after: String
) {
  currentUser { id }
  group(fullPath: $fullPath) {
    id
    fullPath
    labels(
      searchTerm: $search
      searchIn: [TITLE]
      onlyGroupLabels: true
      archived: false
      first: 20
      after: $after
    ) {
      nodes { id title color textColor }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

// Complete, search-free project candidates for bounded AI proposals. A partial
// page never registers candidates; callers must not send unseen identifiers.
const _aiWorkItemLabelCandidatesQuery = r'''
query MobileProjectWorkItemLabelCandidates($fullPath: ID!) {
  currentUser { id }
  project(fullPath: $fullPath) {
    id
    fullPath
    labels(includeAncestorGroups: true, archived: false, first: 100) {
      nodes { id title color textColor }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

const _workItemLabelMutation = r'''
mutation MobileUpdateWorkItemLabels($input: WorkItemUpdateInput!) {
  workItemUpdate(input: $input) {
    errors
    workItem { id updatedAt }
  }
}
''';

enum _LabelReadRole { load, fence, confirm }

final class WorkItemLabelAccess {
  const WorkItemLabelAccess._({
    required this.snapshot,
    required this.canWrite,
    required this.target,
  });

  final WorkItemLabelSnapshot snapshot;
  final bool canWrite;
  final WorkItemLabelTarget? target;
}

final class WorkItemLabelTarget {
  WorkItemLabelTarget._({
    required this.opening,
    required GitLabApi owner,
    required int expectedUserId,
    required int generation,
    required int handoffEpoch,
    required int maxPages,
  }) : _owner = owner,
       _expectedUserId = expectedUserId,
       _generation = generation,
       _handoffEpoch = handoffEpoch,
       _maxPages = maxPages;

  final WorkItemLabelSnapshot opening;
  final GitLabApi _owner;
  final int _expectedUserId;
  final int _generation;
  final int _handoffEpoch;
  final int _maxPages;
  final Set<String> _knownCandidateIds = <String>{};
  bool _consumed = false;
  bool get consumed => _consumed;
  String? _chainTerm;
  int _chainNextIndex = 0;
  String? _chainCursor;
  bool _chainOpen = false;
}

extension WorkItemLabelApi on GitLabApi {
  Future<WorkItemLabelAccess> workItemLabels(
    WorkItemGraphDetail detail, {
    required int expectedUserId,
    required int generation,
    int maxPages = _labelPageLimit,
    bool Function()? isCurrent,
  }) async {
    if (maxPages < 1 || maxPages > _labelPageLimit) {
      throw const ApiFailure(FailureKind.validation);
    }
    final loaded = await _readLabelCatalog(
      detail.summary,
      expectedUserId: expectedUserId,
      generation: generation,
      readEpoch: 0,
      isCurrent: isCurrent,
      role: _LabelReadRole.load,
      maxPages: maxPages,
    );
    final handoffEpoch = _readEpoch;
    final snapshot = WorkItemLabelSnapshot(
      labels: loaded.labels,
      updatedAt: loaded.updatedAt,
      actorId: loaded.actorId,
      summary: loaded.summary,
      readWorkItem: loaded.readWorkItem,
      setWorkItemMetadata: loaded.setWorkItemMetadata,
      labelsWidgetPresent: loaded.labelsWidgetPresent,
      allowsScopedLabels: loaded.allowsScopedLabels,
      generation: generation,
      readEpoch: handoffEpoch,
    );
    final writable =
        snapshot.readWorkItem &&
        snapshot.setWorkItemMetadata &&
        snapshot.labelsWidgetPresent;
    return WorkItemLabelAccess._(
      snapshot: snapshot,
      canWrite: writable,
      target: writable
          ? WorkItemLabelTarget._(
              opening: snapshot,
              owner: this,
              expectedUserId: expectedUserId,
              generation: generation,
              handoffEpoch: handoffEpoch,
              maxPages: maxPages,
            )
          : null,
    );
  }

  /// Reads one complete project catalog without search, then registers every
  /// returned identifier on this target. Partial catalogs fail closed.
  Future<List<WorkItemLabel>> workItemLabelCandidates(
    WorkItemLabelTarget target, {
    bool Function()? isCurrent,
  }) async {
    _requireLabelCaller(this, target, isCurrent);
    if (target._consumed) throw _labelsSpent;
    final scope = _labelCandidateScope(target.opening.summary);
    if (scope.group) throw _labelsUnsupported;
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _aiWorkItemLabelCandidatesQuery,
        'variables': {'fullPath': scope.fullPath},
      },
    );
    _requireLabelCaller(this, target, isCurrent);
    try {
      final data = _labelGraphData(response.bytes);
      if (_requiredLabelActor(data, target._expectedUserId) !=
          target.opening.actorId) {
        throw _labelsCancelled;
      }
      final project = objectJson(data['project']);
      if (requiredString(project, 'id') != scope.containerId ||
          requiredString(project, 'fullPath') != scope.fullPath) {
        throw _labelsUnsupported;
      }
      final page = _parseCandidateConnection(
        project['labels'],
        0,
        pageSize: _aiLabelCandidatePageSize,
      );
      if (page.hasNextPage) throw _labelsUnsupported;
      target._knownCandidateIds.addAll(page.labels.map((label) => label.id));
      return List<WorkItemLabel>.unmodifiable(page.labels);
    } on FormatException {
      throw _labelsUnsupported;
    }
  }

  /// Completed pages stay selectable. A later page failure does not remove them.
  Future<WorkItemLabelCandidatePage> searchWorkItemLabelCandidates(
    WorkItemLabelTarget target, {
    String? search,
    String? searchTerm,
    String? after,
    required int pageIndex,
    bool Function()? isCurrent,
  }) async {
    if (search != null && searchTerm != null && search != searchTerm) {
      throw _labelsSearchInvalid;
    }
    final query = search ?? searchTerm;
    if (query == null) throw _labelsSearchInvalid;
    final term = query.trim();
    if (term.isEmpty ||
        term.runes.length > 256 ||
        term.runes.any((rune) => rune < 0x20 || rune == 0x7F)) {
      throw _labelsSearchInvalid;
    }
    if (pageIndex < 0 || pageIndex >= _labelCandidatePageLimit) {
      throw _labelsUnsupported;
    }
    if (pageIndex == 0) {
      if (after != null) throw _labelsUnsupported;
    } else if (!target._chainOpen ||
        pageIndex != target._chainNextIndex ||
        after == null ||
        after.isEmpty ||
        after != target._chainCursor ||
        term != target._chainTerm) {
      throw _labelsUnsupported;
    }
    _requireLabelCaller(this, target, isCurrent);
    final scope = _labelCandidateScope(target.opening.summary);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': scope.group
            ? _groupWorkItemLabelCandidatesQuery
            : _workItemLabelCandidatesQuery,
        'variables': {
          'fullPath': scope.fullPath,
          'search': term,
          'after': after,
        },
      },
    );
    _requireLabelCaller(this, target, isCurrent);
    final data = _labelGraphData(response.bytes);
    final WorkItemLabelCandidatePage page;
    try {
      final actorId = _requiredLabelActor(data, target._expectedUserId);
      if (actorId != target.opening.actorId) throw _labelsCancelled;
      final container = objectJson(data[scope.group ? 'group' : 'project']);
      if (requiredString(container, 'id') != scope.containerId ||
          requiredString(container, 'fullPath') != scope.fullPath) {
        throw _labelsUnsupported;
      }
      page = _parseCandidateConnection(
        container['labels'],
        pageIndex,
        pageSize: _labelCandidatePageSize,
      );
    } on ApiFailure {
      rethrow;
    } on FormatException {
      throw _labelsUnsupported;
    }
    if (pageIndex == 0) {
      target._chainTerm = term;
      target._chainOpen = true;
    }
    target._knownCandidateIds.addAll(page.labels.map((label) => label.id));
    if (page.hasNextPage) {
      target._chainNextIndex = pageIndex + 1;
      target._chainCursor = page.endCursor;
      target._chainOpen = pageIndex + 1 < _labelCandidatePageLimit;
    } else {
      target._chainOpen = false;
      target._chainCursor = null;
    }
    return page;
  }

  /// Consumes [target] before any wait, including a fresh no-op.
  Future<WorkItemLabelSaveResult> updateWorkItemLabels(
    WorkItemLabelTarget target, {
    required List<String> desiredLabelIds,
    bool Function()? isCurrent,
    void Function()? onMutationSent,
    Future<void> Function()? beforeMutation,
    bool Function()? mayStart,
  }) async {
    if ((beforeMutation == null) != (mayStart == null)) {
      throw ArgumentError('beforeMutation and mayStart must be paired');
    }
    if (target._consumed) {
      throw WorkItemLabelWriteFailure(
        failure: _labelsSpent,
        mutationSent: false,
      );
    }
    target._consumed = true;
    try {
      _requireLabelCaller(this, target, isCurrent);
      if (_notificationActorNumber(target.opening.actorId) !=
          target._expectedUserId) {
        throw _labelsCancelled;
      }
    } on WorkItemLabelWriteFailure {
      rethrow;
    } on ApiFailure catch (failure) {
      throw WorkItemLabelWriteFailure(failure: failure, mutationSent: false);
    } on FormatException {
      throw const WorkItemLabelWriteFailure(
        failure: _labelsCancelled,
        mutationSent: false,
      );
    }

    final WorkItemLabelSnapshot fresh;
    try {
      fresh = await _readLabelCatalog(
        target.opening.summary,
        expectedUserId: target._expectedUserId,
        generation: target._generation,
        readEpoch: target._handoffEpoch,
        isCurrent: isCurrent,
        role: _LabelReadRole.fence,
        maxPages: target._maxPages,
      );
    } on WorkItemLabelWriteFailure {
      rethrow;
    } on ApiFailure catch (failure) {
      throw WorkItemLabelWriteFailure(failure: failure, mutationSent: false);
    }

    try {
      _rejectStaleLabelFence(fresh, target.opening);
      _validateDesiredLabels(
        desiredLabelIds,
        fresh.labelIds.toSet(),
        target._knownCandidateIds,
      );
    } on ApiFailure catch (failure) {
      throw WorkItemLabelWriteFailure(failure: failure, mutationSent: false);
    }
    if (_sameLabelIdSet(fresh.labelIds, desiredLabelIds)) {
      return WorkItemLabelSaveResult(
        status: WorkItemLabelSaveStatus.noop,
        snapshot: fresh,
        acknowledgedUpdatedAt: null,
        mutationSent: false,
      );
    }

    final addLabelIds = <String>[
      for (final id in desiredLabelIds)
        if (!fresh.labelIds.contains(id)) id,
    ];
    final desiredSet = desiredLabelIds.toSet();
    final removeLabelIds = <String>[
      for (final id in fresh.labelIds)
        if (!desiredSet.contains(id)) id,
    ];
    final input = <String, Object?>{
      'id': target.opening.summary.id,
      'labelsWidget': <String, Object?>{
        if (addLabelIds.isNotEmpty) 'addLabelIds': addLabelIds,
        if (removeLabelIds.isNotEmpty) 'removeLabelIds': removeLabelIds,
      },
    };

    try {
      _requireLabelCaller(this, target, isCurrent);
    } on ApiFailure catch (failure) {
      throw WorkItemLabelWriteFailure(failure: failure, mutationSent: false);
    }
    if (beforeMutation != null) await beforeMutation();
    if (mayStart != null && !mayStart()) throw _labelsCancelled;
    onMutationSent?.call();
    final ({Uint8List bytes, Headers headers, int statusCode}) response;
    try {
      response = await _send(
        instance.graphQL,
        method: 'POST',
        graphMutation: true,
        data: {
          'query': _workItemLabelMutation,
          'variables': {'input': input},
        },
      );
    } on Object {
      throw WorkItemLabelWriteFailure(
        failure: _labelsUncertain,
        mutationSent: true,
      );
    }

    final DateTime acknowledged;
    try {
      acknowledged = _parseLabelAcknowledgement(
        response.bytes,
        target.opening.summary.id,
      );
    } on ApiFailure catch (failure) {
      throw WorkItemLabelWriteFailure(failure: failure, mutationSent: true);
    } on Object {
      throw WorkItemLabelWriteFailure(
        failure: _labelsUncertain,
        mutationSent: true,
      );
    }

    final WorkItemLabelSnapshot readback;
    try {
      _requireLabelCaller(this, target, isCurrent);
      readback = await _readLabelCatalog(
        target.opening.summary,
        expectedUserId: target._expectedUserId,
        generation: target._generation,
        readEpoch: target._handoffEpoch,
        isCurrent: isCurrent,
        role: _LabelReadRole.confirm,
        maxPages: target._maxPages,
        requiredUpdatedAt: acknowledged,
      );
    } on Object {
      throw WorkItemLabelWriteFailure(
        failure: _labelsUncertain,
        mutationSent: true,
      );
    }
    if (!readback.labelsWidgetPresent ||
        readback.actorId != target.opening.actorId ||
        readback.updatedAt != acknowledged ||
        !_sameLabelScope(readback.summary, target.opening.summary)) {
      throw WorkItemLabelWriteFailure(
        failure: _labelsUncertain,
        mutationSent: true,
      );
    }
    final applied = _sameLabelIdSet(readback.labelIds, desiredLabelIds);
    return WorkItemLabelSaveResult(
      status: applied
          ? WorkItemLabelSaveStatus.success
          : WorkItemLabelSaveStatus.notApplied,
      snapshot: readback,
      acknowledgedUpdatedAt: acknowledged,
      mutationSent: true,
    );
  }

  Future<WorkItemLabelSnapshot> _readLabelCatalog(
    WorkItemGraphSummary expected, {
    required int expectedUserId,
    required int generation,
    required int readEpoch,
    required bool Function()? isCurrent,
    required _LabelReadRole role,
    required int maxPages,
    DateTime? requiredUpdatedAt,
  }) async {
    if (expectedUserId <= 0 || generation < 0) {
      throw const ApiFailure(FailureKind.validation);
    }
    if (!_isGraphIdType(expected.id, const {'WorkItem'}) ||
        expected.iid <= 0 ||
        (expected.project == null && expected.namespace == null)) {
      throw role == _LabelReadRole.fence ? _labelsConflict : _labelsUnsupported;
    }
    final labels = <WorkItemLabel>[];
    final seenIds = <String>{};
    final seenCursors = <String>{};
    WorkItemGraphSummary? summary;
    String? actorId;
    DateTime? updatedAt;
    bool? readWorkItem;
    bool? setMetadata;
    bool? widgetPresent;
    WorkItemLabelAllowsScoped? scoped;
    String? after;
    for (var page = 0; page < maxPages; page++) {
      if (isClosed || (isCurrent != null && !isCurrent())) {
        throw _labelsCancelled;
      }
      final response = await _read(
        instance.graphQL,
        method: 'POST',
        graphQuery: true,
        data: {
          'query': _workItemLabelsQuery,
          'variables': {'id': expected.id, 'after': after},
        },
      );
      if (isClosed || (isCurrent != null && !isCurrent())) {
        throw _labelsCancelled;
      }
      final parsed = () {
        try {
          return _parseLabelPage(
            _labelGraphData(response.bytes),
            expected: expected,
            expectedUserId: expectedUserId,
            previousCursor: after,
            seenCursors: seenCursors,
            seenIds: seenIds,
            role: role,
          );
        } on FormatException {
          throw _labelsUnsupported;
        }
      }();
      summary ??= parsed.summary;
      actorId ??= parsed.actorId;
      updatedAt ??= parsed.updatedAt;
      readWorkItem ??= parsed.readWorkItem;
      setMetadata ??= parsed.setWorkItemMetadata;
      widgetPresent ??= parsed.labelsWidgetPresent;
      scoped ??= parsed.allowsScopedLabels;
      if (parsed.actorId != actorId ||
          parsed.updatedAt != updatedAt ||
          parsed.readWorkItem != readWorkItem ||
          parsed.setWorkItemMetadata != setMetadata ||
          parsed.labelsWidgetPresent != widgetPresent ||
          parsed.allowsScopedLabels != scoped ||
          !_sameLabelScope(parsed.summary, summary)) {
        throw _labelsUnsupported;
      }
      if (!parsed.labelsWidgetPresent) {
        if (parsed.hasNextPage) throw _labelsUnsupported;
        break;
      }
      labels.addAll(parsed.labels);
      if (!parsed.hasNextPage) break;
      if (page == maxPages - 1 || parsed.endCursor == null) {
        throw _labelsUnsupported;
      }
      after = parsed.endCursor;
    }
    if (summary == null ||
        actorId == null ||
        updatedAt == null ||
        readWorkItem == null ||
        setMetadata == null ||
        widgetPresent == null ||
        scoped == null) {
      throw _labelsUnsupported;
    }
    if (requiredUpdatedAt != null && updatedAt != requiredUpdatedAt) {
      throw role == _LabelReadRole.confirm ? _labelsUncertain : _labelsConflict;
    }
    if (!readWorkItem) throw _labelsReadForbidden;
    return WorkItemLabelSnapshot(
      labels: List<WorkItemLabel>.unmodifiable(labels),
      updatedAt: updatedAt,
      actorId: actorId,
      summary: summary,
      readWorkItem: readWorkItem,
      setWorkItemMetadata: setMetadata,
      labelsWidgetPresent: widgetPresent,
      allowsScopedLabels: scoped,
      generation: generation,
      readEpoch: readEpoch,
    );
  }
}

void _requireLabelCaller(
  GitLabApi api,
  WorkItemLabelTarget target,
  bool Function()? isCurrent,
) {
  if (!identical(api, target._owner) ||
      api.isClosed ||
      (isCurrent != null && !isCurrent())) {
    throw _labelsCancelled;
  }
}

({bool group, String fullPath, String containerId}) _labelCandidateScope(
  WorkItemGraphSummary summary,
) {
  final project = summary.project;
  if (project != null) {
    return (group: false, fullPath: project.fullPath, containerId: project.id);
  }
  final namespace = summary.namespace;
  if (namespace == null || !_isGraphIdType(namespace.id, const {'Group'})) {
    throw _labelsUnsupported;
  }
  return (group: true, fullPath: namespace.fullPath, containerId: namespace.id);
}

void _rejectStaleLabelFence(
  WorkItemLabelSnapshot fresh,
  WorkItemLabelSnapshot opening,
) {
  if (fresh.actorId != opening.actorId) throw _labelsCancelled;
  if (fresh.updatedAt != opening.updatedAt ||
      !_sameLabelScope(fresh.summary, opening.summary)) {
    throw _labelsConflict;
  }
  if (!fresh.labelsWidgetPresent) throw _labelsUnsupported;
  if (!fresh.readWorkItem || !fresh.setWorkItemMetadata) {
    throw _labelsWriteForbidden;
  }
  if (!_sameLabelIdSet(fresh.labelIds, opening.labelIds)) throw _labelsConflict;
}

void _validateDesiredLabels(
  List<String> desired,
  Set<String> current,
  Set<String> knownCandidates,
) {
  final seen = <String>{};
  for (final id in desired) {
    if (id.isEmpty || !_labelGid.hasMatch(id) || !seen.add(id)) {
      throw _labelsInvalid;
    }
    if (!current.contains(id) && !knownCandidates.contains(id)) {
      throw _labelsInvalid;
    }
  }
}

bool _sameLabelIdSet(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  final first = left.toSet();
  final second = right.toSet();
  return first.length == left.length &&
      second.length == right.length &&
      first.length == second.length &&
      first.containsAll(second);
}

bool _sameLabelScope(WorkItemGraphSummary left, WorkItemGraphSummary right) =>
    left.id == right.id &&
    left.iid == right.iid &&
    left.type.id == right.type.id &&
    _sameAttributeRef(left.project, right.project) &&
    _sameAttributeRef(left.namespace, right.namespace);

({
  WorkItemGraphSummary summary,
  String actorId,
  DateTime updatedAt,
  bool readWorkItem,
  bool setWorkItemMetadata,
  bool labelsWidgetPresent,
  WorkItemLabelAllowsScoped allowsScopedLabels,
  List<WorkItemLabel> labels,
  bool hasNextPage,
  String? endCursor,
})
_parseLabelPage(
  Json data, {
  required WorkItemGraphSummary expected,
  required int expectedUserId,
  required String? previousCursor,
  required Set<String> seenCursors,
  required Set<String> seenIds,
  required _LabelReadRole role,
}) {
  final actorId = _requiredLabelActor(data, expectedUserId);
  if (data['workItem'] == null) throw _labelsReadForbidden;
  final node = objectJson(data['workItem']);
  final summary = _parseWorkItemSummary(node);
  if (!_sameLabelScope(summary, expected)) {
    throw role == _LabelReadRole.fence ? _labelsConflict : _labelsUnsupported;
  }
  final updatedAt = summary.updatedAt;
  final permissions = node['userPermissions'];
  if (permissions is! Map) throw _labelsReadForbidden;
  if (permissions['readWorkItem'] != true) throw _labelsReadForbidden;
  final setMetadata = permissions['setWorkItemMetadata'] == true;
  final scoped = _parseScopedDefinition(node['workItemType']);
  final widgets = node['widgets'];
  if (widgets == null || (widgets is List && widgets.isEmpty)) {
    return (
      summary: summary,
      actorId: actorId,
      updatedAt: updatedAt,
      readWorkItem: true,
      setWorkItemMetadata: setMetadata,
      labelsWidgetPresent: false,
      allowsScopedLabels: scoped,
      labels: const <WorkItemLabel>[],
      hasNextPage: false,
      endCursor: null,
    );
  }
  if (widgets is! List || widgets.length != 1) throw _labelsUnsupported;
  final widget = objectJson(widgets.single);
  if (widget['type'] != 'LABELS') throw _labelsUnsupported;
  final connection = widget['labels'];
  if (connection is! Map) throw _labelsUnsupported;
  final nodes = connection['nodes'];
  if (nodes is! List || nodes.length > _labelPageSize) throw _labelsUnsupported;
  final pageInfo = objectJson(connection['pageInfo']);
  final hasNext = pageInfo['hasNextPage'];
  final rawCursor = pageInfo['endCursor'];
  if (hasNext is! bool) throw _labelsUnsupported;
  if (rawCursor != null &&
      (rawCursor is! String ||
          rawCursor.isEmpty ||
          rawCursor.length > _workItemCursorLimit)) {
    throw _labelsUnsupported;
  }
  if (hasNext &&
      (rawCursor is! String ||
          rawCursor == previousCursor ||
          !seenCursors.add(rawCursor))) {
    throw _labelsUnsupported;
  }
  final labels = <WorkItemLabel>[];
  for (final raw in nodes) {
    final label = _parseLabelRecord(raw);
    if (!seenIds.add(label.id)) throw _labelsUnsupported;
    labels.add(label);
  }
  return (
    summary: summary,
    actorId: actorId,
    updatedAt: updatedAt,
    readWorkItem: true,
    setWorkItemMetadata: setMetadata,
    labelsWidgetPresent: true,
    allowsScopedLabels: scoped,
    labels: labels,
    hasNextPage: hasNext,
    endCursor: rawCursor is String ? rawCursor : null,
  );
}

WorkItemLabelAllowsScoped _parseScopedDefinition(Object? rawType) {
  if (rawType is! Map || rawType['widgetDefinitions'] is! List) {
    return WorkItemLabelAllowsScoped.unknown;
  }
  final definitions = rawType['widgetDefinitions'];
  if (definitions is! List) return WorkItemLabelAllowsScoped.unknown;
  Map<String, dynamic>? found;
  for (final raw in definitions) {
    if (raw is! Map) return WorkItemLabelAllowsScoped.unknown;
    final definition = objectJson(raw);
    if (definition['type'] != 'LABELS') continue;
    if (found != null) return WorkItemLabelAllowsScoped.unknown;
    found = definition;
  }
  if (found == null || !found.containsKey('allowsScopedLabels')) {
    return WorkItemLabelAllowsScoped.unknown;
  }
  final value = found['allowsScopedLabels'];
  if (value == true) return WorkItemLabelAllowsScoped.allowed;
  if (value == false) return WorkItemLabelAllowsScoped.disabled;
  return WorkItemLabelAllowsScoped.unknown;
}

WorkItemLabelCandidatePage _parseCandidateConnection(
  Object? raw,
  int pageIndex, {
  required int pageSize,
}) {
  if (raw is! Map) throw _labelsUnsupported;
  final connection = objectJson(raw);
  final nodes = connection['nodes'];
  if (nodes is! List || nodes.length > pageSize) {
    throw _labelsUnsupported;
  }
  final pageInfo = objectJson(connection['pageInfo']);
  final hasNext = pageInfo['hasNextPage'];
  final rawCursor = pageInfo['endCursor'];
  if (hasNext is! bool) throw _labelsUnsupported;
  if (rawCursor != null &&
      (rawCursor is! String ||
          rawCursor.isEmpty ||
          rawCursor.length > _workItemCursorLimit)) {
    throw _labelsUnsupported;
  }
  if (hasNext && rawCursor is! String) throw _labelsUnsupported;
  final labels = <WorkItemLabel>[];
  final seen = <String>{};
  for (final node in nodes) {
    final label = _parseLabelRecord(node);
    if (!seen.add(label.id)) throw _labelsUnsupported;
    labels.add(label);
  }
  return WorkItemLabelCandidatePage(
    labels: List<WorkItemLabel>.unmodifiable(labels),
    endCursor: rawCursor is String ? rawCursor : null,
    hasNextPage: hasNext,
    pageIndex: pageIndex,
  );
}

WorkItemLabel _parseLabelRecord(Object? raw) {
  final node = objectJson(raw);
  final id = requiredString(node, 'id');
  final title = requiredString(node, 'title');
  if (!_labelGid.hasMatch(id) ||
      title.isEmpty ||
      title.length > _labelTitleLimit ||
      title.contains('\u0000')) {
    throw _labelsUnsupported;
  }
  return WorkItemLabel(
    id: id,
    title: title,
    color: _neutralLabelColor(node['color']),
    textColor: _neutralLabelColor(node['textColor']),
  );
}

String? _neutralLabelColor(Object? raw) {
  if (raw is! String || !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(raw)) {
    return null;
  }
  return raw;
}

String _requiredLabelActor(Json data, int expectedUserId) {
  if (!data.containsKey('currentUser') || data['currentUser'] == null) {
    throw _labelsUnsupported;
  }
  final actorId = _parseNotificationActor(data['currentUser']);
  if (actorId == null || _notificationActorNumber(actorId) != expectedUserId) {
    throw _labelsCancelled;
  }
  return actorId;
}

DateTime _parseLabelAcknowledgement(Uint8List bytes, String workItemId) {
  try {
    final envelope = objectJson(jsonDecode(utf8.decode(bytes)));
    final topErrors = envelope['errors'];
    if (topErrors is List && topErrors.isNotEmpty) throw _labelsUncertain;
    if (topErrors != null && topErrors is! List) throw _labelsUncertain;
    final data = objectJson(envelope['data']);
    final update = data['workItemUpdate'];
    if (update is! Map) throw _labelsUncertain;
    final payload = objectJson(update);
    final errors = payload['errors'];
    if (errors is! List) throw _labelsUncertain;
    final messages = <String>[];
    for (final error in errors) {
      if (error is! String || error.isEmpty) throw _labelsUncertain;
      messages.add(error);
    }
    if (messages.isNotEmpty) {
      throw ApiFailure(
        FailureKind.validation,
        title: l10n.invalidLabelIdentifier,
        detail: messages.join('\n'),
      );
    }
    final item = payload['workItem'];
    if (item is! Map) throw _labelsUncertain;
    final node = objectJson(item);
    if (node['id'] != workItemId) throw _labelsUncertain;
    return _workItemTimestamp(node['updatedAt']);
  } on ApiFailure {
    rethrow;
  } on Object {
    throw _labelsUncertain;
  }
}

Json _labelGraphData(Uint8List bytes) {
  try {
    final envelope = objectJson(jsonDecode(utf8.decode(bytes)));
    final errors = envelope['errors'];
    if (errors is List && errors.isNotEmpty) throw _labelsUnsupported;
    if (errors != null && errors is! List) throw _labelsUnsupported;
    return objectJson(envelope['data']);
  } on ApiFailure {
    rethrow;
  } on Object {
    throw _labelsUnsupported;
  }
}
