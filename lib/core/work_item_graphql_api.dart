part of 'gitlab_api.dart';

const _workItemPageSize = 20;
const _workItemAssigneeLimit = 20;
const _workItemLabelLimit = 50;
const _workItemChildLimit = 20;
const _workItemWidgetLimit = 32;
const _workItemCursorLimit = 4096;

const _workItemSummaryFields = r'''
id
iid
title
state
createdAt
updatedAt
project { id fullPath }
namespace { id fullPath }
workItemType { id name }
''';

final _projectWorkItemsQuery =
    '''
query MobileProjectWorkItems(\$path: ID!, \$first: Int!, \$after: String) {
  project(fullPath: \$path) {
    id
    fullPath
    workItems(first: \$first, after: \$after) {
      nodes { $_workItemSummaryFields }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

final _projectWorkItemQuery =
    '''
query MobileProjectWorkItem(\$path: ID!, \$iid: String!) {
  project(fullPath: \$path) {
    id
    fullPath
    workItems(first: 2, iid: \$iid) {
      nodes { ${_workItemDetailFields()} }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

final _namespaceWorkItemQuery =
    '''
query MobileNamespaceWorkItem(\$path: ID!, \$iid: String!) {
  namespace(fullPath: \$path) {
    id
    fullPath
    workItem(iid: \$iid) { ${_workItemDetailFields()} }
  }
}
''';

const _namespaceWorkItemTypesQuery = r'''
query MobileNamespaceWorkItemTypes($path: ID!, $first: Int!, $after: String) {
  namespace(fullPath: $path) {
    id
    fullPath
    workItemTypes(first: $first, after: $after) {
      nodes {
        id
        name
        enabled
        isGroupWorkItemType
        widgetDefinitions { type }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

String _workItemDetailFields() =>
    '''
$_workItemSummaryFields
description
widgets {
  type
  ... on WorkItemWidgetDescription {
    description
    edited
    lastEditedAt
  }
  ... on WorkItemWidgetAssignees {
    assignees(first: $_workItemAssigneeLimit) {
      nodes { id name username }
      pageInfo { hasNextPage endCursor }
    }
  }
  ... on WorkItemWidgetLabels {
    labels(first: $_workItemLabelLimit) {
      nodes { id title color description textColor }
      pageInfo { hasNextPage endCursor }
    }
  }
  ... on WorkItemWidgetHierarchy {
    hasParent
    hasChildren
    parent { $_workItemSummaryFields }
    children(first: $_workItemChildLimit) {
      nodes { $_workItemSummaryFields }
      pageInfo { hasNextPage endCursor }
    }
  }
  ... on WorkItemWidgetStartAndDueDate {
    startDate
    dueDate
    rollUp
  }
}
''';

const _workItemSchemaErrors = {
  'undefinedField',
  'undefinedArgument',
  'variableRequiresValidType',
  'argumentLiteralsIncompatible',
  'missingRequiredArguments',
};

extension WorkItemGraphQlApi on GitLabApi {
  /// Reads one bounded project page. Type names remain display-only metadata.
  Future<WorkItemGraphPage> projectWorkItems(
    Project project, {
    String? after,
    bool Function()? isCurrent,
  }) async {
    _validateWorkItemProject(project);
    final cursor = _validatedWorkItemCursor(after);
    _requireCurrentWorkItemRequest(isCurrent);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _projectWorkItemsQuery,
        'variables': {
          'path': project.path,
          'first': _workItemPageSize,
          'after': cursor,
        },
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final data = _workItemGraphData(response.bytes);
      final remote = _projectGraphContainer(data, project);
      final connection = _requiredWorkItemConnection(
        remote.container,
        'workItems',
      );
      final nodes = _boundedNodes(connection, _workItemPageSize);
      final seenIds = <String>{};
      final seenIids = <int>{};
      final items = <WorkItemGraphSummary>[];
      for (final raw in nodes) {
        final item = _parseWorkItemSummary(raw);
        _requireProjectWorkItem(item, remote.ref);
        if (!seenIds.add(item.id) || !seenIids.add(item.iid)) {
          throw const FormatException('Duplicate work item');
        }
        items.add(item);
      }
      return WorkItemGraphPage(
        items: List.unmodifiable(items),
        nextCursor: _nextWorkItemCursor(connection, previous: cursor),
      );
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  /// Reads exactly one project-bound IID using a duplicate-detecting query.
  Future<WorkItemGraphDetail> projectWorkItem(
    Project project,
    int iid, {
    bool Function()? isCurrent,
  }) async {
    _validateWorkItemProject(project);
    if (iid <= 0) throw const ApiFailure(FailureKind.validation);
    _requireCurrentWorkItemRequest(isCurrent);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _projectWorkItemQuery,
        'variables': {'path': project.path, 'iid': '$iid'},
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final data = _workItemGraphData(response.bytes);
      final remote = _projectGraphContainer(data, project);
      final connection = _requiredWorkItemConnection(
        remote.container,
        'workItems',
      );
      final nodes = _boundedNodes(connection, 2);
      final pageInfo = objectJson(connection['pageInfo']);
      if (pageInfo['hasNextPage'] != false || nodes.length > 1) {
        throw const FormatException('Ambiguous work item');
      }
      if (nodes.isEmpty) throw const ApiFailure(FailureKind.invisible);
      final detail = _parseWorkItemDetail(nodes.single);
      _requireProjectWorkItem(detail.summary, remote.ref);
      if (detail.summary.iid != iid) {
        throw const FormatException('Wrong work item IID');
      }
      return detail;
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  /// Reads a work item through a verified namespace identity. This supports
  /// group work-item URLs without pretending that a group is a REST Project.
  Future<WorkItemGraphDetail> namespaceWorkItem(
    String fullPath,
    int iid, {
    String? expectedNamespaceId,
    bool Function()? isCurrent,
  }) async {
    final path = _validatedNamespacePath(fullPath);
    final expectedId = _validatedOptionalOpaqueId(expectedNamespaceId);
    if (iid <= 0) throw const ApiFailure(FailureKind.validation);
    _requireCurrentWorkItemRequest(isCurrent);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _namespaceWorkItemQuery,
        'variables': {'path': path, 'iid': '$iid'},
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final data = _workItemGraphData(response.bytes);
      final namespace = _namespaceGraphContainer(
        data,
        path,
        expectedId: expectedId,
      );
      if (namespace.container['workItem'] == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final detail = _parseWorkItemDetail(namespace.container['workItem']);
      if (detail.summary.iid != iid ||
          detail.summary.namespace?.id != namespace.ref.id ||
          detail.summary.namespace?.fullPath != path) {
        throw const FormatException('Wrong namespace work item');
      }
      return detail;
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  /// Lists server-defined capabilities without filtering by ID or name.
  Future<WorkItemTypePage> namespaceWorkItemTypes(
    String fullPath, {
    String? expectedNamespaceId,
    String? after,
    bool Function()? isCurrent,
  }) async {
    final path = _validatedNamespacePath(fullPath);
    final expectedId = _validatedOptionalOpaqueId(expectedNamespaceId);
    final cursor = _validatedWorkItemCursor(after);
    _requireCurrentWorkItemRequest(isCurrent);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _namespaceWorkItemTypesQuery,
        'variables': {
          'path': path,
          'first': _workItemPageSize,
          'after': cursor,
        },
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final data = _workItemGraphData(response.bytes);
      final namespace = _namespaceGraphContainer(
        data,
        path,
        expectedId: expectedId,
      );
      final connection = _requiredWorkItemConnection(
        namespace.container,
        'workItemTypes',
      );
      final nodes = _boundedNodes(connection, _workItemPageSize);
      final ids = <String>{};
      final capabilities = <WorkItemTypeCapability>[];
      for (final raw in nodes) {
        final node = objectJson(raw);
        final type = _parseWorkItemType(node);
        final enabled = node['enabled'];
        final group = node['isGroupWorkItemType'];
        if (enabled is! bool || group is! bool || !ids.add(type.id)) {
          throw const FormatException('Invalid work item type');
        }
        capabilities.add(
          WorkItemTypeCapability(
            type: type,
            enabled: enabled,
            isGroupWorkItemType: group,
            widgetTypes: _parseWidgetDefinitions(node['widgetDefinitions']),
          ),
        );
      }
      return WorkItemTypePage(
        namespace: namespace.ref,
        items: List.unmodifiable(capabilities),
        nextCursor: _nextWorkItemCursor(connection, previous: cursor),
      );
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }
}

Json _workItemGraphData(Uint8List bytes) {
  try {
    final envelope = objectJson(jsonDecode(utf8.decode(bytes)));
    final errors = envelope['errors'];
    if (errors != null) {
      if (errors is! List) throw const FormatException('Invalid errors');
      if (errors.isNotEmpty) {
        final unsupported = errors.every(
          (error) =>
              error is Map &&
              error['extensions'] is Map &&
              _workItemSchemaErrors.contains(
                (error['extensions'] as Map)['code'],
              ),
        );
        throw ApiFailure(
          unsupported ? FailureKind.unsupported : FailureKind.invalidResponse,
          title: unsupported ? '實例未提供原生工作項目' : null,
          detail: unsupported ? '這個 GitLab 版本不支援所需的唯讀欄位。' : null,
        );
      }
    }
    return objectJson(envelope['data']);
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}

void _validateWorkItemProject(Project project) {
  if (project.id <= 0 || _validatedNamespacePathOrNull(project.path) == null) {
    throw const ApiFailure(FailureKind.validation);
  }
}

String _validatedNamespacePath(String value) {
  final path = _validatedNamespacePathOrNull(value);
  if (path == null) throw const ApiFailure(FailureKind.validation);
  return path;
}

String? _validatedNamespacePathOrNull(String value) {
  final path = value.trim();
  if (path.isEmpty ||
      path.length > 1024 ||
      !RegExp(r'^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$').hasMatch(path)) {
    return null;
  }
  return path;
}

String? _validatedOptionalOpaqueId(String? value) {
  if (value == null) return null;
  if (!_validOpaqueGraphId(value)) {
    throw const ApiFailure(FailureKind.validation);
  }
  return value;
}

String? _validatedWorkItemCursor(String? value) {
  if (value == null) return null;
  if (value.isEmpty || value.length > _workItemCursorLimit) {
    throw const ApiFailure(FailureKind.validation);
  }
  return value;
}

void _requireCurrentWorkItemRequest(bool Function()? isCurrent) {
  if (isCurrent != null && !isCurrent()) {
    throw const ApiFailure(FailureKind.cancelled);
  }
}

({Json container, GraphResourceRef ref}) _projectGraphContainer(
  Json data,
  Project project,
) {
  if (data['project'] == null) throw const ApiFailure(FailureKind.invisible);
  final remote = objectJson(data['project']);
  final ref = _parseResourceRef(remote);
  final match = RegExp(
    r'^gid://gitlab/Project/([1-9][0-9]*)$',
  ).firstMatch(ref.id);
  if (match == null ||
      int.tryParse(match.group(1)!) != project.id ||
      ref.fullPath != project.path) {
    throw const FormatException('Wrong project');
  }
  return (container: remote, ref: ref);
}

({Json container, GraphResourceRef ref}) _namespaceGraphContainer(
  Json data,
  String path, {
  String? expectedId,
}) {
  if (data['namespace'] == null) {
    throw const ApiFailure(FailureKind.invisible);
  }
  final remote = objectJson(data['namespace']);
  final ref = _parseResourceRef(remote);
  if (ref.fullPath != path || (expectedId != null && ref.id != expectedId)) {
    throw const FormatException('Wrong namespace');
  }
  return (container: remote, ref: ref);
}

Json _requiredWorkItemConnection(Json parent, String key) {
  if (parent[key] == null) throw const ApiFailure(FailureKind.forbidden);
  return objectJson(parent[key]);
}

List<Object?> _boundedNodes(Json connection, int limit) {
  final nodes = connection['nodes'];
  if (nodes is! List || nodes.length > limit) {
    throw const FormatException('Invalid bounded connection');
  }
  return nodes;
}

String? _nextWorkItemCursor(Json connection, {String? previous}) {
  final pageInfo = objectJson(connection['pageInfo']);
  final hasNext = pageInfo['hasNextPage'];
  final rawCursor = pageInfo['endCursor'];
  if (hasNext is! bool ||
      (rawCursor != null &&
          (rawCursor is! String ||
              rawCursor.isEmpty ||
              rawCursor.length > _workItemCursorLimit))) {
    throw const FormatException('Invalid page info');
  }
  if (!hasNext) return null;
  if (rawCursor is! String || rawCursor == previous) {
    throw const FormatException('Invalid continuation cursor');
  }
  return rawCursor;
}

WorkItemGraphSummary _parseWorkItemSummary(Object? raw) {
  final node = objectJson(raw);
  final id = requiredString(node, 'id');
  if (!_validOpaqueGraphId(id)) {
    throw const FormatException('Invalid work item ID');
  }
  final iid = _positiveWorkItemInt(node['iid']);
  final title = _boundedRequiredText(node, 'title', 4096);
  final state = _boundedRequiredText(node, 'state', 64);
  final type = _parseWorkItemType(node['workItemType']);
  final project = _parseOptionalResourceRef(node['project']);
  final namespace = _parseOptionalResourceRef(node['namespace']);
  final identities = <String>{id, type.id};
  if (identities.length != 2 ||
      (project != null && !identities.add(project.id)) ||
      (namespace != null && !identities.add(namespace.id))) {
    throw const FormatException('Confused graph identity');
  }
  return WorkItemGraphSummary(
    id: id,
    iid: iid,
    title: title,
    state: state,
    createdAt: _workItemTimestamp(node['createdAt']),
    updatedAt: _workItemTimestamp(node['updatedAt']),
    project: project,
    namespace: namespace,
    type: type,
  );
}

WorkItemGraphDetail _parseWorkItemDetail(Object? raw) {
  final node = objectJson(raw);
  final summary = _parseWorkItemSummary(node);
  final description = _boundedOptionalDescription(node['description']);
  final rawWidgets = node['widgets'];
  if (rawWidgets == null) {
    return WorkItemGraphDetail(
      summary: summary,
      description: description,
      widgetsAvailable: false,
      widgetTypes: const {},
      descriptionWidget: null,
      assignees: null,
      labels: null,
      hierarchy: null,
      dates: null,
    );
  }
  if (rawWidgets is! List || rawWidgets.length > _workItemWidgetLimit) {
    throw const FormatException('Invalid widgets');
  }
  final widgetTypes = <String>{};
  WorkItemDescriptionWidget? descriptionWidget;
  WorkItemAssigneesWidget? assignees;
  WorkItemLabelsWidget? labels;
  WorkItemHierarchyWidget? hierarchy;
  WorkItemDatesWidget? dates;
  for (final rawWidget in rawWidgets) {
    final widget = objectJson(rawWidget);
    final type = _boundedRequiredText(widget, 'type', 128);
    if (!widgetTypes.add(type)) {
      throw const FormatException('Duplicate widget');
    }
    switch (type) {
      case 'DESCRIPTION':
        descriptionWidget = _parseDescriptionWidget(widget);
      case 'ASSIGNEES':
        assignees = WorkItemAssigneesWidget(
          assignees: _parseOptionalConnection(
            widget['assignees'],
            _workItemAssigneeLimit,
            _parseAssignee,
            identity: (assignee) => assignee.id,
          ),
        );
      case 'LABELS':
        labels = WorkItemLabelsWidget(
          labels: _parseOptionalConnection(
            widget['labels'],
            _workItemLabelLimit,
            _parseWorkItemLabel,
            identity: (label) => label.id,
          ),
        );
      case 'HIERARCHY':
        hierarchy = _parseHierarchyWidget(widget);
      case 'START_AND_DUE_DATE':
        dates = _parseDatesWidget(widget);
    }
  }
  return WorkItemGraphDetail(
    summary: summary,
    description: description,
    widgetsAvailable: true,
    widgetTypes: Set.unmodifiable(widgetTypes),
    descriptionWidget: descriptionWidget,
    assignees: assignees,
    labels: labels,
    hierarchy: hierarchy,
    dates: dates,
  );
}

void _requireProjectWorkItem(
  WorkItemGraphSummary item,
  GraphResourceRef project,
) {
  if (item.project?.id != project.id ||
      item.project?.fullPath != project.fullPath) {
    throw const FormatException('Wrong work item project');
  }
}

GraphResourceRef? _parseOptionalResourceRef(Object? raw) =>
    raw == null ? null : _parseResourceRef(raw);

GraphResourceRef _parseResourceRef(Object? raw) {
  final node = objectJson(raw);
  final id = requiredString(node, 'id');
  final path = requiredString(node, 'fullPath');
  if (!_validOpaqueGraphId(id) || _validatedNamespacePathOrNull(path) == null) {
    throw const FormatException('Invalid graph resource');
  }
  return GraphResourceRef(id: id, fullPath: path);
}

WorkItemGraphType _parseWorkItemType(Object? raw) {
  final node = objectJson(raw);
  final id = requiredString(node, 'id');
  final name = _boundedRequiredText(node, 'name', 256);
  if (!_validOpaqueGraphId(id)) {
    throw const FormatException('Invalid work item type ID');
  }
  return WorkItemGraphType(id: id, name: name);
}

bool _validOpaqueGraphId(String value) {
  if (value.length > 512 || RegExp(r'\s').hasMatch(value)) return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'gid' &&
      uri.host == 'gitlab' &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      uri.pathSegments.length >= 2 &&
      uri.pathSegments.every((segment) => segment.isNotEmpty);
}

int _positiveWorkItemInt(Object? raw) {
  if (raw is int && raw > 0) return raw;
  if (raw is String &&
      raw.length <= 19 &&
      RegExp(r'^[1-9][0-9]*$').hasMatch(raw)) {
    return int.parse(raw);
  }
  throw const FormatException('Invalid positive integer');
}

String _boundedRequiredText(Json node, String key, int maxLength) {
  final value = requiredString(node, key);
  if (value.length > maxLength || value.contains('\u0000')) {
    throw FormatException('Invalid $key');
  }
  return value;
}

String? _boundedOptionalDescription(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || raw.contains('\u0000')) {
    throw const FormatException('Invalid description');
  }
  if (utf8.encode(raw).length > GitLabApi.maxTextBytes ||
      '\n'.allMatches(raw).length + 1 > GitLabApi.maxTextLines) {
    throw const ApiFailure(FailureKind.tooLarge);
  }
  return raw;
}

DateTime _workItemTimestamp(Object? raw) {
  if (raw is! String || raw.length > 64) {
    throw const FormatException('Invalid timestamp');
  }
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(raw);
  if (match == null) throw const FormatException('Invalid timestamp');
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final hour = int.parse(match.group(4)!);
  final minute = int.parse(match.group(5)!);
  final second = int.parse(match.group(6)!);
  final fraction = (match.group(7) ?? '').padRight(6, '0');
  final microseconds = fraction.isEmpty ? 0 : int.parse(fraction);
  final local = DateTime.utc(
    year,
    month,
    day,
    hour,
    minute,
    second,
    microseconds ~/ 1000,
    microseconds % 1000,
  );
  if (local.year != year ||
      local.month != month ||
      local.day != day ||
      local.hour != hour ||
      local.minute != minute ||
      local.second != second) {
    throw const FormatException('Invalid timestamp');
  }
  final zone = match.group(8)!;
  var offsetMinutes = 0;
  if (zone != 'Z') {
    final offsetHour = int.parse(zone.substring(1, 3));
    final offsetMinute = int.parse(zone.substring(4, 6));
    if (offsetHour > 23 || offsetMinute > 59) {
      throw const FormatException('Invalid timestamp offset');
    }
    offsetMinutes = offsetHour * 60 + offsetMinute;
    if (zone.startsWith('-')) offsetMinutes = -offsetMinutes;
  }
  final expected = local.subtract(Duration(minutes: offsetMinutes));
  final parsed = DateTime.tryParse(raw)?.toUtc();
  if (parsed == null || parsed != expected) {
    throw const FormatException('Invalid timestamp');
  }
  return expected;
}

DateTime? _workItemDate(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) {
    throw const FormatException('Invalid date');
  }
  final value = DateTime.tryParse('${raw}T00:00:00Z');
  if (value == null || value.toIso8601String().substring(0, 10) != raw) {
    throw const FormatException('Invalid date');
  }
  return value;
}

WorkItemDescriptionWidget _parseDescriptionWidget(Json widget) {
  final edited = widget['edited'];
  if (edited is! bool) {
    throw const FormatException('Invalid edited state');
  }
  return WorkItemDescriptionWidget(
    description: _boundedOptionalDescription(widget['description']),
    edited: edited,
    lastEditedAt: widget['lastEditedAt'] == null
        ? null
        : _workItemTimestamp(widget['lastEditedAt']),
  );
}

BoundedGraphConnection<T>? _parseOptionalConnection<T>(
  Object? raw,
  int limit,
  T Function(Object?) parse, {
  String Function(T)? identity,
  String Function(T)? secondaryIdentity,
}) {
  if (raw == null) return null;
  final connection = objectJson(raw);
  final nodes = _boundedNodes(connection, limit);
  final items = List<T>.unmodifiable(nodes.map(parse));
  if (identity != null) {
    final seen = <String>{};
    for (final item in items) {
      if (!seen.add(identity(item))) {
        throw const FormatException('Duplicate connection identity');
      }
    }
  }
  if (secondaryIdentity != null) {
    final seen = <String>{};
    for (final item in items) {
      if (!seen.add(secondaryIdentity(item))) {
        throw const FormatException('Duplicate scoped connection identity');
      }
    }
  }
  final cursor = _nextWorkItemCursor(connection);
  return BoundedGraphConnection(
    items: items,
    isPartial: cursor != null,
    nextCursor: cursor,
  );
}

WorkItemGraphAssignee _parseAssignee(Object? raw) {
  final node = objectJson(raw);
  final id = requiredString(node, 'id');
  if (!_validOpaqueGraphId(id)) throw const FormatException('Invalid user ID');
  return WorkItemGraphAssignee(
    id: id,
    name: _boundedRequiredText(node, 'name', 512),
    username: _boundedRequiredText(node, 'username', 255),
  );
}

WorkItemGraphLabel _parseWorkItemLabel(Object? raw) {
  final node = objectJson(raw);
  final id = requiredString(node, 'id');
  if (!_validOpaqueGraphId(id)) throw const FormatException('Invalid label ID');
  final description = node['description'];
  final textColor = node['textColor'];
  if ((description != null && description is! String) ||
      (textColor != null && textColor is! String)) {
    throw const FormatException('Invalid label metadata');
  }
  return WorkItemGraphLabel(
    id: id,
    title: _boundedRequiredText(node, 'title', 512),
    color: _boundedRequiredText(node, 'color', 64),
    description: description as String?,
    textColor: textColor as String?,
  );
}

WorkItemHierarchyWidget _parseHierarchyWidget(Json widget) {
  final hasParent = widget['hasParent'];
  final hasChildren = widget['hasChildren'];
  if ((hasParent != null && hasParent is! bool) ||
      (hasChildren != null && hasChildren is! bool)) {
    throw const FormatException('Invalid hierarchy flags');
  }
  final parent = widget['parent'] == null
      ? null
      : _parseHierarchyEntry(widget['parent']);
  final children = _parseOptionalConnection(
    widget['children'],
    _workItemChildLimit,
    _parseHierarchyEntry,
    identity: (child) => child.id,
    secondaryIdentity: (child) =>
        '${child.namespace?.fullPath ?? child.project?.fullPath ?? 'unknown'}#${child.iid}',
  );
  if (hasParent == false && parent != null) {
    throw const FormatException('Contradictory parent');
  }
  return WorkItemHierarchyWidget(
    hasParent: hasParent as bool?,
    hasChildren: hasChildren as bool?,
    parent: parent,
    children: children,
  );
}

WorkItemHierarchyEntry _parseHierarchyEntry(Object? raw) {
  final summary = _parseWorkItemSummary(raw);
  return WorkItemHierarchyEntry(
    id: summary.id,
    iid: summary.iid,
    title: summary.title,
    state: summary.state,
    project: summary.project,
    namespace: summary.namespace,
    type: summary.type,
  );
}

WorkItemDatesWidget _parseDatesWidget(Json widget) {
  final rollUp = widget['rollUp'];
  if (rollUp is! bool) {
    throw const FormatException('Invalid roll-up state');
  }
  return WorkItemDatesWidget(
    startDate: _workItemDate(widget['startDate']),
    dueDate: _workItemDate(widget['dueDate']),
    rollUp: rollUp,
  );
}

Set<String>? _parseWidgetDefinitions(Object? raw) {
  if (raw == null) return null;
  if (raw is! List || raw.length > _workItemWidgetLimit) {
    throw const FormatException('Invalid widget definitions');
  }
  final result = <String>{};
  for (final value in raw) {
    final type = _boundedRequiredText(objectJson(value), 'type', 128);
    if (!result.add(type)) {
      throw const FormatException('Duplicate widget definition');
    }
  }
  return Set.unmodifiable(result);
}
