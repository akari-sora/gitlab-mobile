part of 'gitlab_api.dart';

const _workItemAttributeIdentityFields = r'''
id
iid
project { id fullPath }
namespace { id fullPath }
''';

final _workItemStatusAttributeQuery =
    '''
query MobileWorkItemStatusAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_workItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetStatus {
        status { id name iconName color category }
      }
    }
  }
}
''';

final _workItemMilestoneAttributeQuery =
    '''
query MobileWorkItemMilestoneAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_workItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetMilestone {
        milestone {
          id iid title state webPath dueDate startDate
          project { id fullPath }
          group { id fullPath }
        }
      }
    }
  }
}
''';

final _workItemWeightAttributeQuery =
    '''
query MobileWorkItemWeightAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_workItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetWeight {
        weight
        rolledUpWeight
        rolledUpCompletedWeight
      }
    }
  }
}
''';

final _workItemIterationAttributeQuery =
    '''
query MobileWorkItemIterationAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_workItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetIteration {
        iteration {
          id iid title state webUrl startDate dueDate
          group { id fullPath }
          iterationCadence { id title }
        }
      }
    }
  }
}
''';

final _workItemHealthAttributeQuery =
    '''
query MobileWorkItemHealthAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_workItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetHealthStatus {
        healthStatus
        rolledUpHealthStatus { healthStatus count }
      }
    }
  }
}
''';

final _workItemTimeTrackingAttributeQuery =
    '''
query MobileWorkItemTimeTrackingAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_workItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetTimeTracking {
        timeEstimate
        totalTimeSpent
        humanReadableAttributes { timeEstimate totalTimeSpent }
      }
    }
  }
}
''';

final _workItemDevelopmentAttributeQuery =
    '''
query MobileWorkItemDevelopmentAttribute(\$id: WorkItemID!) {
  workItem(id: \$id) {
    $_workItemAttributeIdentityFields
    widgets {
      type
      ... on WorkItemWidgetDevelopment {
        closingMergeRequestsCount
        willAutoCloseByMergeRequest
      }
    }
  }
}
''';

extension WorkItemAttributesApi on GitLabApi {
  /// Reads one independently degradable, server-defined work item widget.
  /// Unsupported fields affect only the selected [kind], never base detail.
  Future<WorkItemAttributeSnapshot> workItemAttribute(
    WorkItemGraphSummary expected,
    WorkItemAttributeKind kind, {
    bool Function()? isCurrent,
  }) async {
    _requireStrictGroupOwnerApi(this, expected.strictGroupOwner);
    _validateExpectedAttributeIdentity(expected);
    _requireCurrentWorkItemRequest(isCurrent);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _attributeQuery(kind),
        'variables': {'id': expected.id},
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final data = _workItemGraphData(response.bytes);
      if (data['workItem'] == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final node = objectJson(data['workItem']);
      final identity = _parseAttributeIdentity(node, expected: expected);
      _requireExpectedAttributeIdentity(identity, expected);
      final rawWidgets = node['widgets'];
      if (rawWidgets == null) {
        return _attributeSnapshot(
          identity,
          kind,
          WorkItemAttributeAvailability.widgetsUnavailable,
        );
      }
      if (rawWidgets is! List || rawWidgets.length > _workItemWidgetLimit) {
        throw const FormatException('Invalid work item widgets');
      }
      final seenTypes = <String>{};
      Json? selected;
      for (final raw in rawWidgets) {
        final widget = objectJson(raw);
        final type = _boundedRequiredText(widget, 'type', 128);
        if (!seenTypes.add(type)) {
          throw const FormatException('Duplicate work item widget');
        }
        if (type == _attributeWidgetType(kind)) selected = widget;
      }
      if (selected == null) {
        return _attributeSnapshot(
          identity,
          kind,
          WorkItemAttributeAvailability.absent,
        );
      }
      return _attributeSnapshot(
        identity,
        kind,
        WorkItemAttributeAvailability.present,
        value: _parseAttributeValue(kind, selected, instance),
      );
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }
}

String _attributeQuery(WorkItemAttributeKind kind) => switch (kind) {
  WorkItemAttributeKind.status => _workItemStatusAttributeQuery,
  WorkItemAttributeKind.milestone => _workItemMilestoneAttributeQuery,
  WorkItemAttributeKind.weight => _workItemWeightAttributeQuery,
  WorkItemAttributeKind.iteration => _workItemIterationAttributeQuery,
  WorkItemAttributeKind.health => _workItemHealthAttributeQuery,
  WorkItemAttributeKind.timeTracking => _workItemTimeTrackingAttributeQuery,
  WorkItemAttributeKind.development => _workItemDevelopmentAttributeQuery,
};

String _attributeWidgetType(WorkItemAttributeKind kind) => switch (kind) {
  WorkItemAttributeKind.status => 'STATUS',
  WorkItemAttributeKind.milestone => 'MILESTONE',
  WorkItemAttributeKind.weight => 'WEIGHT',
  WorkItemAttributeKind.iteration => 'ITERATION',
  WorkItemAttributeKind.health => 'HEALTH_STATUS',
  WorkItemAttributeKind.timeTracking => 'TIME_TRACKING',
  WorkItemAttributeKind.development => 'DEVELOPMENT',
};

void _validateExpectedAttributeIdentity(WorkItemGraphSummary expected) {
  if (!_validOpaqueGraphId(expected.id) || expected.iid <= 0) {
    throw const ApiFailure(FailureKind.validation);
  }
  final ids = <String>{expected.id};
  for (final ref in [expected.project, expected.namespace]) {
    if (ref == null) continue;
    if (!_validOpaqueGraphId(ref.id) ||
        _validatedNamespacePathOrNull(ref.fullPath) == null ||
        !ids.add(ref.id)) {
      throw const ApiFailure(FailureKind.validation);
    }
  }
}

({String id, int iid, GraphResourceRef? project, GraphResourceRef? namespace})
_parseAttributeIdentity(
  Json node, {
  WorkItemGraphSummary? expected,
  VerifiedGroupWorkItemIdentity? strictGroupOwner,
}) {
  _requireStrictGroupWorkItemOwner(
    node,
    expected?.strictGroupOwner ?? strictGroupOwner,
  );
  final id = requiredString(node, 'id');
  if (!_validOpaqueGraphId(id)) {
    throw const FormatException('Invalid work item identity');
  }
  final project = _parseOptionalResourceRef(node['project']);
  final namespace = _parseOptionalResourceRef(node['namespace']);
  final ids = <String>{id};
  if ((project != null && !ids.add(project.id)) ||
      (namespace != null && !ids.add(namespace.id))) {
    throw const FormatException('Confused work item identity');
  }
  return (
    id: id,
    iid: _positiveWorkItemInt(node['iid']),
    project: project,
    namespace: namespace,
  );
}

void _requireExpectedAttributeIdentity(
  ({String id, int iid, GraphResourceRef? project, GraphResourceRef? namespace})
  identity,
  WorkItemGraphSummary expected,
) {
  if (identity.id != expected.id ||
      identity.iid != expected.iid ||
      !_sameAttributeRef(identity.project, expected.project) ||
      !_sameAttributeRef(identity.namespace, expected.namespace)) {
    throw const FormatException('Wrong work item identity');
  }
}

bool _sameAttributeRef(GraphResourceRef? left, GraphResourceRef? right) =>
    left == null
    ? right == null
    : right != null && left.id == right.id && left.fullPath == right.fullPath;

WorkItemAttributeSnapshot _attributeSnapshot(
  ({String id, int iid, GraphResourceRef? project, GraphResourceRef? namespace})
  identity,
  WorkItemAttributeKind kind,
  WorkItemAttributeAvailability availability, {
  WorkItemAttributeValue? value,
}) => WorkItemAttributeSnapshot(
  workItemId: identity.id,
  iid: identity.iid,
  project: identity.project,
  namespace: identity.namespace,
  kind: kind,
  availability: availability,
  value: value,
);

WorkItemAttributeValue _parseAttributeValue(
  WorkItemAttributeKind kind,
  Json widget,
  GitLabInstance instance,
) => switch (kind) {
  WorkItemAttributeKind.status => _parseStatusAttribute(widget),
  WorkItemAttributeKind.milestone => _parseMilestoneAttribute(widget),
  WorkItemAttributeKind.weight => _parseWeightAttribute(widget),
  WorkItemAttributeKind.iteration => _parseIterationAttribute(widget, instance),
  WorkItemAttributeKind.health => _parseHealthAttribute(widget),
  WorkItemAttributeKind.timeTracking => _parseTimeAttribute(widget),
  WorkItemAttributeKind.development => _parseDevelopmentAttribute(widget),
};

WorkItemStatusAttribute _parseStatusAttribute(Json widget) {
  final raw = widget['status'];
  if (raw == null) return const WorkItemStatusAttribute(status: null);
  final status = objectJson(raw);
  final id = _attributeOptionalString(status['id'], 512);
  if (id != null && !_validOpaqueGraphId(id)) {
    throw const FormatException('Invalid status identity');
  }
  return WorkItemStatusAttribute(
    status: WorkItemStatusValue(
      id: id,
      name: _attributeOptionalString(status['name'], 512),
      iconName: _attributeOptionalString(status['iconName'], 256),
      color: _attributeOptionalString(status['color'], 128),
      category: _attributeOptionalString(status['category'], 128),
    ),
  );
}

WorkItemMilestoneAttribute _parseMilestoneAttribute(Json widget) {
  final raw = widget['milestone'];
  if (raw == null) return const WorkItemMilestoneAttribute(milestone: null);
  final milestone = objectJson(raw);
  final id = requiredString(milestone, 'id');
  if (!_validOpaqueGraphId(id)) {
    throw const FormatException('Invalid milestone identity');
  }
  return WorkItemMilestoneAttribute(
    milestone: WorkItemMilestoneValue(
      id: id,
      iid: _positiveWorkItemInt(milestone['iid']),
      title: _boundedRequiredText(milestone, 'title', 4096),
      state: _boundedRequiredText(milestone, 'state', 128),
      webPath: _attributeWebPath(milestone['webPath']),
      dueDate: _workItemDate(milestone['dueDate']),
      startDate: _workItemDate(milestone['startDate']),
      project: _parseAttributeOwner(milestone['project']),
      group: _parseAttributeOwner(milestone['group']),
    ),
  );
}

WorkItemWeightAttribute _parseWeightAttribute(Json widget) =>
    WorkItemWeightAttribute(
      weight: _attributeNonNegativeInt(widget['weight']),
      rolledUpWeight: _attributeNonNegativeInt(widget['rolledUpWeight']),
      rolledUpCompletedWeight: _attributeNonNegativeInt(
        widget['rolledUpCompletedWeight'],
      ),
    );

WorkItemIterationAttribute _parseIterationAttribute(
  Json widget,
  GitLabInstance instance,
) {
  final raw = widget['iteration'];
  if (raw == null) return const WorkItemIterationAttribute(iteration: null);
  final iteration = objectJson(raw);
  final id = requiredString(iteration, 'id');
  if (!_validOpaqueGraphId(id)) {
    throw const FormatException('Invalid iteration identity');
  }
  final group = _parseAttributeOwner(iteration['group']);
  if (group == null) throw const FormatException('Missing iteration group');
  final cadence = objectJson(iteration['iterationCadence']);
  final cadenceId = requiredString(cadence, 'id');
  if (!_validOpaqueGraphId(cadenceId) || cadenceId == id) {
    throw const FormatException('Invalid iteration cadence');
  }
  return WorkItemIterationAttribute(
    iteration: WorkItemIterationValue(
      id: id,
      iid: _positiveWorkItemInt(iteration['iid']),
      title: _attributeOptionalString(iteration['title'], 4096),
      state: _boundedRequiredText(iteration, 'state', 128),
      webUrl: _attributeWebUrl(instance, iteration['webUrl']),
      startDate: _workItemDate(iteration['startDate']),
      dueDate: _workItemDate(iteration['dueDate']),
      group: group,
      cadence: WorkItemIterationCadence(
        id: cadenceId,
        title: _attributeOptionalString(cadence['title'], 4096),
      ),
    ),
  );
}

WorkItemHealthAttribute _parseHealthAttribute(Json widget) {
  final current = _attributeOptionalString(widget['healthStatus'], 128);
  final rawRollup = widget['rolledUpHealthStatus'];
  List<WorkItemHealthRollup>? rollup;
  if (rawRollup != null) {
    if (rawRollup is! List || rawRollup.length > 32) {
      throw const FormatException('Invalid health rollup');
    }
    final seen = <String>{};
    final values = <WorkItemHealthRollup>[];
    for (final raw in rawRollup) {
      final item = objectJson(raw);
      final status = _boundedRequiredText(item, 'healthStatus', 128);
      final count = _attributeRequiredNonNegativeInt(item['count']);
      if (!seen.add(status)) {
        throw const FormatException('Duplicate health rollup');
      }
      values.add(WorkItemHealthRollup(healthStatus: status, count: count));
    }
    rollup = List.unmodifiable(values);
  }
  return WorkItemHealthAttribute(
    healthStatus: current,
    rolledUpHealthStatus: rollup,
  );
}

WorkItemTimeTrackingAttribute _parseTimeAttribute(Json widget) {
  final rawHuman = widget['humanReadableAttributes'];
  WorkItemHumanReadableTime? human;
  if (rawHuman != null) {
    final value = objectJson(rawHuman);
    human = WorkItemHumanReadableTime(
      timeEstimate: _attributeOptionalString(value['timeEstimate'], 256),
      totalTimeSpent: _attributeOptionalString(value['totalTimeSpent'], 256),
    );
  }
  return WorkItemTimeTrackingAttribute(
    timeEstimate: _attributeNonNegativeInt(widget['timeEstimate']),
    totalTimeSpent: _attributeNonNegativeInt(widget['totalTimeSpent']),
    humanReadable: human,
  );
}

WorkItemDevelopmentAttribute _parseDevelopmentAttribute(Json widget) {
  final autoClose = widget['willAutoCloseByMergeRequest'];
  if (autoClose is! bool) {
    throw const FormatException('Invalid development auto-close state');
  }
  return WorkItemDevelopmentAttribute(
    closingMergeRequestsCount: _attributeRequiredNonNegativeInt(
      widget['closingMergeRequestsCount'],
    ),
    willAutoCloseByMergeRequest: autoClose,
  );
}

WorkItemAttributeOwnerRef? _parseAttributeOwner(Object? raw) {
  if (raw == null) return null;
  final owner = objectJson(raw);
  final id = _attributeOptionalString(owner['id'], 512);
  if (id != null && !_validOpaqueGraphId(id)) {
    throw const FormatException('Invalid attribute owner identity');
  }
  final path = requiredString(owner, 'fullPath');
  if (_validatedNamespacePathOrNull(path) == null) {
    throw const FormatException('Invalid attribute owner path');
  }
  return WorkItemAttributeOwnerRef(id: id, fullPath: path);
}

String? _attributeOptionalString(Object? raw, int maxLength) {
  if (raw == null) return null;
  if (raw is! String || raw.length > maxLength || raw.contains('\u0000')) {
    throw const FormatException('Invalid optional attribute text');
  }
  return raw;
}

int? _attributeNonNegativeInt(Object? raw) =>
    raw == null ? null : _attributeRequiredNonNegativeInt(raw);

int _attributeRequiredNonNegativeInt(Object? raw) {
  if (raw is! int || raw < 0) {
    throw const FormatException('Invalid attribute count');
  }
  return raw;
}

String _attributeWebPath(Object? raw) {
  if (raw is! String || raw.isEmpty || raw.length > 8192) {
    throw const FormatException('Invalid web path');
  }
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      uri.isAbsolute ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      !raw.startsWith('/') ||
      raw.contains('\\') ||
      uri.pathSegments.any((segment) => segment == '.' || segment == '..') ||
      _attributeHasSensitiveQuery(uri)) {
    throw const FormatException('Invalid web path');
  }
  return raw;
}

Uri _attributeWebUrl(GitLabInstance instance, Object? raw) {
  if (raw is! String || raw.isEmpty || raw.length > 8192) {
    throw const FormatException('Invalid web URL');
  }
  final uri = Uri.tryParse(raw);
  if (uri == null ||
      !uri.isAbsolute ||
      !instance.sameOrigin(uri) ||
      uri.hasFragment ||
      uri.pathSegments.length < instance.base.pathSegments.length ||
      !_attributeStartsWith(uri.pathSegments, instance.base.pathSegments) ||
      _attributeHasSensitiveQuery(uri)) {
    throw const FormatException('Invalid web URL');
  }
  return uri;
}

bool _attributeHasSensitiveQuery(Uri uri) => uri.queryParameters.keys.any(
  (key) => const {
    'access_token',
    'private_token',
    'token',
  }.contains(key.toLowerCase()),
);

bool _attributeStartsWith(List<String> value, List<String> prefix) {
  if (value.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (value[index] != prefix[index]) return false;
  }
  return true;
}
