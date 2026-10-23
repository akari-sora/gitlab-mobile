part of 'gitlab_api.dart';

const _incidentStatusQuery = r'''
query MobileIncidentStatus($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    id
    issues(iids: [$iid], types: [INCIDENT], first: 2) {
      nodes { id iid projectId state severity escalationStatus updatedAt }
      pageInfo { hasNextPage }
    }
  }
}
''';

const _incidentStatusMutation = r'''
mutation MobileSetIncidentStatus($input: IssueSetEscalationStatusInput!) {
  issueSetEscalationStatus(input: $input) {
    errors
    issue { id iid projectId state severity escalationStatus updatedAt }
  }
}
''';

const _incidentStatuses = {'TRIGGERED', 'ACKNOWLEDGED', 'RESOLVED', 'IGNORED'};
const _incidentActions = {'TRIGGERED', 'ACKNOWLEDGED', 'RESOLVED'};
const _incidentSeverities = {'UNKNOWN', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL'};

Json _incidentGraphData(Uint8List bytes) {
  try {
    final envelope = objectJson(jsonDecode(utf8.decode(bytes)));
    final errors = envelope['errors'];
    if (errors != null) {
      if (errors is! List) throw const ApiFailure(FailureKind.invalidResponse);
      if (errors.isNotEmpty) {
        final unsupported = errors.every(
          (error) =>
              error is Map &&
              error['extensions'] is Map &&
              const {
                'undefinedField',
                'undefinedArgument',
                'variableRequiresValidType',
                'argumentLiteralsIncompatible',
                'missingRequiredArguments',
              }.contains((error['extensions'] as Map)['code']),
        );
        throw ApiFailure(
          unsupported ? FailureKind.unsupported : FailureKind.invalidResponse,
          title: unsupported ? l10n.instanceNoIncidentStatus : null,
          detail: unsupported ? l10n.stillEditIncidentContent : null,
        );
      }
    }
    return objectJson(envelope['data']);
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}

Json _validatedIncidentStatus(Object? raw, Project project, int iid) {
  try {
    final issue = objectJson(raw);
    if (issue['projectId'] != project.id ||
        issue['iid'] != '$iid' ||
        issue['id'] is! String ||
        !RegExp(
          r'^gid://gitlab/Issue/[1-9][0-9]*$',
        ).hasMatch(issue['id'] as String) ||
        !const {'opened', 'closed', 'locked'}.contains(issue['state']) ||
        issue['updatedAt'] is! String ||
        DateTime.tryParse(issue['updatedAt'] as String) == null ||
        (issue['severity'] != null &&
            !_incidentSeverities.contains(issue['severity']))) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    if (issue['escalationStatus'] == null) {
      throw ApiFailure(
        FailureKind.unsupported,
        title: l10n.cannotReadIncidentStatus,
        detail: l10n.stillEditIncidentContent,
      );
    }
    if (!_incidentStatuses.contains(issue['escalationStatus'])) {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
    return Map<String, dynamic>.unmodifiable(issue);
  } on FormatException {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
}

extension IncidentApi on GitLabApi {
  /// Fresh, fixed-query lifecycle read. Never equate this with REST issue state.
  Future<Json> incidentStatus(Project project, int iid) async {
    if (project.id <= 0 || project.path.trim().isEmpty || iid <= 0) {
      throw const ApiFailure(FailureKind.validation);
    }
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _incidentStatusQuery,
        'variables': {'path': project.path, 'iid': '$iid'},
      },
    );
    try {
      final data = _incidentGraphData(response.bytes);
      if (data['project'] == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final remote = objectJson(data['project']);
      if (remote['id'] != 'gid://gitlab/Project/${project.id}') {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      if (remote['issues'] == null) {
        throw const ApiFailure(FailureKind.forbidden);
      }
      final issues = objectJson(remote['issues']);
      final nodes = issues['nodes'];
      if (nodes is! List ||
          objectJson(issues['pageInfo'])['hasNextPage'] != false ||
          nodes.length > 1) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      if (nodes.isEmpty) throw const ApiFailure(FailureKind.invisible);
      return _validatedIncidentStatus(nodes.single, project, iid);
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  /// Preflight, one mutation, then an independent read of the same incident.
  /// GraphQL mutations retain write/cache fences and cannot replay after 401.
  Future<Json> setIncidentStatus(
    Project project,
    int iid,
    String status, {
    String? expectedUpdatedAt,
    bool Function()? isCurrent,
    Future<void> Function()? beforeMutation,
    bool Function()? mayStart,
  }) async {
    if ((beforeMutation == null) != (mayStart == null)) {
      throw ArgumentError('beforeMutation and mayStart must be paired');
    }
    if (!_incidentActions.contains(status)) {
      throw const ApiFailure(FailureKind.validation);
    }
    if (isCurrent != null && !isCurrent()) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    final before = await incidentStatus(project, iid);
    if (isCurrent != null && !isCurrent()) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    if (expectedUpdatedAt != null && before['updatedAt'] != expectedUpdatedAt) {
      throw const ApiFailure(FailureKind.conflict);
    }
    if (before['escalationStatus'] == status) return before;
    if (beforeMutation != null) await beforeMutation();
    if (mayStart != null && !mayStart()) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    final response = await _send(
      instance.graphQL,
      method: 'POST',
      graphMutation: true,
      data: {
        'query': _incidentStatusMutation,
        'variables': {
          'input': {
            'projectPath': project.path,
            'iid': '$iid',
            'status': status,
          },
        },
      },
    );
    final Json data;
    try {
      data = _incidentGraphData(response.bytes);
    } on ApiFailure catch (failure) {
      // A schema-validation rejection occurs before execution. Once a valid
      // payload is returned, missing status is an ambiguous acknowledgement.
      if (failure.kind == FailureKind.unsupported) rethrow;
      throw const ApiFailure(FailureKind.writeUncertain);
    } on FormatException {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
    try {
      if (data['issueSetEscalationStatus'] == null) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      final payload = objectJson(data['issueSetEscalationStatus']);
      final errors = payload['errors'];
      if (errors is! List || errors.any((error) => error is! String)) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
      if (errors.isNotEmpty) {
        throw ApiFailure(
          FailureKind.validation,
          title: l10n.gitlabRejectedIncidentStatus,
          detail: l10n.checkRoleThenIncidentStatus,
        );
      }
      final changed = _validatedIncidentStatus(payload['issue'], project, iid);
      if (changed['id'] != before['id'] ||
          changed['escalationStatus'] != status) {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
    } on FormatException {
      throw const ApiFailure(FailureKind.writeUncertain);
    } on ApiFailure catch (failure) {
      if (failure.kind == FailureKind.validation) rethrow;
      throw const ApiFailure(FailureKind.writeUncertain);
    }
    try {
      final readback = await incidentStatus(project, iid);
      if (readback['id'] != before['id'] ||
          readback['escalationStatus'] != status) {
        throw const ApiFailure(FailureKind.writeUncertain);
      }
      return readback;
    } on ApiFailure {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
  }
}
