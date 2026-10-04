import 'dart:async';

import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'fake_adapter.dart';

/// One allowed status as the synthetic server stores it. Every field may be
/// null, as upstream allows; a member without [id] makes the list unusable.
final class StatusFixtureMember {
  const StatusFixtureMember({
    required this.id,
    this.name,
    this.iconName,
    this.color,
    this.position,
    this.description,
    this.category,
  });

  final String? id;
  final String? name;
  final String? iconName;
  final String? color;
  final int? position;
  final String? description;
  final String? category;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'iconName': iconName,
    'color': color,
    'position': position,
    'description': description,
    'category': category,
  };
}

/// Mutable server-side truth for one Work Item.
final class StatusFixtureItem {
  StatusFixtureItem({
    required this.id,
    required this.iid,
    required this.title,
    required this.project,
    required this.namespace,
    required this.updatedAt,
    required this.assignment,
    required List<StatusFixtureMember> members,
  }) : members = List<StatusFixtureMember>.of(members);

  String id;
  int iid;
  String title;
  GraphResourceRef? project;
  GraphResourceRef? namespace;
  String typeId = WorkItemStatusFixture.typeId;
  String typeName = '客戶自訂目標';
  final DateTime createdAt = DateTime.utc(2026, 10, 1, 9);
  DateTime updatedAt;
  int lockVersion = 8;
  String state = 'OPEN';
  bool statusWidgetPresent = true;
  bool statusDefinitionPresent = true;
  bool duplicateStatusDefinition = false;

  /// `null` is GitLab's explicit `status: null`.
  StatusFixtureMember? assignment;

  /// `null` serializes as `allowedStatuses: null`.
  List<StatusFixtureMember>? members;

  /// Raw JSON values so tests can send malformed permissions.
  Object? readWorkItem = true;
  Object? setWorkItemMetadata = true;

  /// Server-side lifecycle effects of applying a status.
  final Set<String> closesOn = {};
  final Set<String> reopensOn = {};

  /// Parent-page hierarchy (served only with `serveParent`): child Work Item
  /// IDs listed in the detail's HIERARCHY widget.
  final List<String> childIds = [];

  /// As a hierarchy child, report `namespace: null` so the client must
  /// resolve the project before it can open the child.
  bool hideNamespaceAsChild = false;

  /// Applied label IDs (served only with `serveParent`). `null` omits the
  /// LABELS widget everywhere, which is the pre-existing wire shape.
  List<String>? labelIds;

  /// Serves the WEIGHT widget and its reads/mutation (with `serveParent`).
  bool weightWidget = false;
  int? weight;

  /// Assigned user IDs (served only with `serveParent`). `null` omits the
  /// ASSIGNEES widget and every assignee operation.
  List<String>? assigneeIds;

  /// Serves the MILESTONE widget and its operations (with `serveParent`).
  bool milestoneWidget = false;
  String? milestoneId;
}

/// Label catalog entries in the shape of `work_item_labels_fixture.dart`.
const statusFixtureLabels = <String, String>{
  'gid://gitlab/ProjectLabel/1': '標籤1',
  'gid://gitlab/ProjectLabel/2': '標籤2',
};

/// Users the synthetic instance knows, in `work_item_assignee_fixture.dart`
/// node shape. Autocomplete answers at most 20 of them.
const statusFixtureUsers = <String, ({String name, String username})>{
  'gid://gitlab/User/11': (name: '既有負責人', username: 'owner11'),
  'gid://gitlab/User/12': (name: '候選人員', username: 'cand12'),
};

/// Active milestones owned by the item's own project or group.
const statusFixtureMilestones = <String, String>{
  'gid://gitlab/Milestone/5': '十月里程碑',
  'gid://gitlab/Milestone/6': '十一月里程碑',
};

enum StatusFixtureRequestKind {
  read,
  mutation,
  rejected,

  /// Parent-page GraphQL reads and REST lookups (only with `serveParent`).
  parentRead,

  /// The lifecycle close/reopen mutation (only with `serveParent`).
  parentMutation,
}

final class StatusFixtureRequest {
  const StatusFixtureRequest({
    required this.nonce,
    required this.kind,
    this.workItemId,
    this.mutationNonce,
    this.input,
    this.operation,
  });

  final int nonce;
  final StatusFixtureRequestKind kind;
  final String? workItemId;
  final int? mutationNonce;
  final Map<String, Object?>? input;

  /// GraphQL operation name, or `GET <api path>` for REST.
  final String? operation;
}

/// Stateful synthetic GitLab for the STATUS read and status-only update.
///
/// Every answer is built from [items] at the moment it is served. Only the two
/// Phase 1 operations on the instance GraphQL endpoint are accepted; anything
/// else is recorded in [unhandled] and answered with an error.
class WorkItemStatusFixture {
  WorkItemStatusFixture() {
    items[projectItemId] = StatusFixtureItem(
      id: projectItemId,
      iid: sharedIid,
      title: '專案狀態項目',
      project: projectRef,
      namespace: projectNamespaceRef,
      updatedAt: openedAt,
      assignment: defaultMembers.first,
      members: defaultMembers,
    )..closesOn.add(statusDone);
    items[groupItemId] = StatusFixtureItem(
      id: groupItemId,
      iid: sharedIid,
      title: '群組狀態項目',
      project: null,
      namespace: groupRef,
      updatedAt: openedAt,
      assignment: defaultMembers.first,
      members: defaultMembers,
    )..closesOn.add(statusDone);
    _created.add(api);
  }

  static const projectItemId = 'gid://gitlab/WorkItem/301';
  static const groupItemId = 'gid://gitlab/WorkItem/401';
  static const typeId = 'gid://gitlab/WorkItems::Type/91';
  static const sharedIid = 17;
  static const projectRef = GraphResourceRef(
    id: 'gid://gitlab/Project/42',
    fullPath: 'studio/mobile',
  );
  static const projectNamespaceRef = GraphResourceRef(
    id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
    fullPath: 'studio/mobile',
  );
  static const groupRef = GraphResourceRef(
    id: 'gid://gitlab/Group/84',
    fullPath: 'studio/group',
  );

  static const statusTodo =
      'gid://gitlab/WorkItems::Statuses::SystemDefined::Status/1';
  static const statusDoing =
      'gid://gitlab/WorkItems::Statuses::Custom::Status/37';
  static const statusDone =
      'gid://gitlab/WorkItems::Statuses::Custom::Status/38';
  static const statusCanceled =
      'gid://gitlab/WorkItems::Statuses::SystemDefined::Status/5';

  static final openedAt = DateTime.utc(2026, 10, 4, 4);

  static const defaultMembers = <StatusFixtureMember>[
    StatusFixtureMember(
      id: statusTodo,
      name: '待處理',
      iconName: 'status_todo',
      color: '#737278',
      position: 0,
      description: '尚未開始',
      category: 'TO_DO',
    ),
    StatusFixtureMember(
      id: statusDoing,
      name: '進行中',
      iconName: 'status_running',
      color: '#1f75cb',
      position: 1,
      description: null,
      category: 'IN_PROGRESS',
    ),
    StatusFixtureMember(
      id: statusDone,
      name: '完成',
      iconName: 'status_success',
      color: '#108548',
      position: 2,
      description: '伺服器會關閉項目',
      category: 'DONE',
    ),
    StatusFixtureMember(
      id: statusCanceled,
      name: '不處理',
      iconName: 'status_canceled',
      color: '#dd2b0e',
      position: 3,
      description: null,
      category: 'CANCELED',
    ),
  ];

  static String customStatusId(int number) =>
      'gid://gitlab/WorkItems::Statuses::Custom::Status/$number';

  late final FakeAdapter adapter = FakeAdapter(_respond);
  late GitLabApi api = testApi(adapter);

  final account = Account(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    user: const GitLabUser(id: 7, username: 'ada', name: 'Ada'),
    token: 'synthetic-test-token',
  );

  /// Client identity input: the immutable session generation the caller
  /// injects. The server never sees it.
  int sessionGeneration = 12;

  /// Numeric user component of `currentUser.id` as the server reports it.
  int actorUserId = 7;

  /// Seconds the server clock moves when a mutation is applied. Zero yields a
  /// same-second acknowledgement.
  int advanceSeconds = 1;

  final items = <String, StatusFixtureItem>{};
  final requests = <StatusFixtureRequest>[];
  final unhandled = <String>[];
  final appliedMutationNonces = <int>[];

  /// One-shot gates, consumed by the next matching request.
  Completer<void>? holdNextRead;
  Completer<void>? holdBeforeApply;
  Completer<void>? holdAck;

  /// One-shot drift applied when the next read is served.
  void Function(WorkItemStatusFixture fixture)? beforeNextRead;

  /// Applies the next mutation, then answers HTTP 503 instead of the ACK.
  bool loseNextAck = false;

  /// Next mutation is refused with these payload errors and not applied.
  List<String>? rejectNextMutation;

  /// Opt-in parent-page server. When false (the default) every request
  /// outside the two STATUS operations is rejected exactly as before.
  bool serveParent = false;

  /// `userPermissions.updateWorkItem` on lifecycle reads.
  bool lifecycleCanUpdate = true;

  /// One-shot parent gates, consumed by the next matching request.
  Completer<void>? holdNextDetail;
  Completer<void>? holdNextLifecycleRead;
  Completer<void>? holdNextLifecycleMutation;
  Completer<void>? holdNextAttribute;
  Completer<void>? holdNextProject;
  Completer<void>? holdNextList;
  Completer<void>? holdNextLabelsRead;
  Completer<void>? holdNextLabelsMutation;
  Completer<void>? holdNextGroup;
  Completer<void>? holdNextWeightMutation;
  Completer<void>? holdNextAssigneesMutation;
  Completer<void>? holdNextMilestoneMutation;

  /// One-shot: the next parent detail read is recorded, then answered with
  /// HTTP 503 after its gate.
  bool failNextDetail = false;

  /// Gates consumed and not yet completed.
  int get heldCount => _consumed.where((gate) => !gate.isCompleted).length;

  var _requestNonce = 0;
  var _mutationNonce = 0;
  var _awaitingApply = false;
  var _awaitingAck = false;
  final _created = <GitLabApi>[];

  bool get awaitingApply => _awaitingApply;
  bool get awaitingAck => _awaitingAck;

  StatusFixtureItem item({required bool group}) =>
      items[group ? groupItemId : projectItemId]!;

  int get reads => requests
      .where((request) => request.kind == StatusFixtureRequestKind.read)
      .length;

  int get mutations => requests
      .where((request) => request.kind == StatusFixtureRequestKind.mutation)
      .length;

  List<Map<String, Object?>> get mutationInputs => [
    for (final request in requests)
      if (request.kind == StatusFixtureRequestKind.mutation) request.input!,
  ];

  /// A new client on the same server. The previous one stays open unless the
  /// caller closes it; [closeAll] closes the initial and every replacement.
  GitLabApi replaceApi() {
    final next = testApi(adapter);
    _created.add(next);
    api = next;
    return next;
  }

  /// Completes every armed or consumed gate. Tests call this from `finally`.
  void releaseHolds() {
    for (final gate in [
      holdNextRead,
      holdBeforeApply,
      holdAck,
      holdNextDetail,
      holdNextLifecycleRead,
      holdNextLifecycleMutation,
      holdNextAttribute,
      holdNextProject,
      holdNextList,
      holdNextLabelsRead,
      holdNextLabelsMutation,
      holdNextGroup,
      holdNextWeightMutation,
      holdNextAssigneesMutation,
      holdNextMilestoneMutation,
      ..._consumed,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    _consumed.clear();
  }

  /// Operation names in request order.
  List<String> get operations => [
    for (final request in requests) request.operation ?? '?',
  ];

  int count(String operation) =>
      requests.where((request) => request.operation == operation).length;

  final _consumed = <Completer<void>>[];

  void closeAll() {
    for (final client in {api, ..._created}) {
      client.close();
    }
  }

  /// The opening detail a parent would hold, built from current server truth.
  WorkItemGraphDetail detail({required bool group}) {
    final current = item(group: group);
    return WorkItemGraphDetail(
      summary: WorkItemGraphSummary(
        id: current.id,
        iid: current.iid,
        title: current.title,
        state: current.state,
        createdAt: current.createdAt,
        updatedAt: current.updatedAt,
        project: current.project,
        namespace: current.namespace,
        type: WorkItemGraphType(id: current.typeId, name: current.typeName),
      ),
      description: null,
      widgetsAvailable: true,
      widgetTypes: const {'STATUS'},
      descriptionWidget: null,
      assignees: null,
      labels: null,
      hierarchy: null,
      dates: null,
    );
  }

  /// Another actor edits the item: newer revision and lock version.
  void touch({required bool group, int seconds = 5}) {
    final current = item(group: group);
    current.updatedAt = current.updatedAt.add(Duration(seconds: seconds));
    current.lockVersion++;
  }

  Future<ResponseBody> _respond(RequestOptions request) async {
    final nonce = ++_requestNonce;
    if (serveParent && request.method == 'GET') {
      return _rest(nonce, request.uri);
    }
    if (request.method != 'POST' || request.uri != account.instance.graphQL) {
      return _reject(nonce, 'endpoint ${request.method} ${request.uri.path}');
    }
    final data = request.data;
    if (data is! Map || data['query'] is! String || data['variables'] is! Map) {
      return _reject(nonce, 'malformed GraphQL body');
    }
    final query = data['query'] as String;
    final variables = (data['variables'] as Map).cast<String, Object?>();
    if (query.startsWith('query MobileWorkItemStatus(')) {
      return _read(nonce, variables);
    }
    if (query.startsWith('mutation MobileUpdateWorkItemStatus(')) {
      return _mutate(nonce, variables);
    }
    if (serveParent) {
      final name = RegExp(
        r'^(?:query|mutation) (\w+)\(',
      ).firstMatch(query)?.group(1) ?? '';
      switch (name) {
        case 'MobileProjectWorkItem':
          return _projectDetail(nonce, name, variables);
        case 'MobileNamespaceWorkItem':
          return _namespaceDetail(nonce, name, variables);
        case 'MobileProjectWorkItems':
          return _projectList(nonce, name, variables);
        case 'MobileGroupWorkItems':
          return _groupList(nonce, name, variables);
        case 'MobileNamespaceWorkItemTypes':
          return _types(nonce, name, variables);
        case 'MobileWorkItemStatusAttribute':
          return _statusAttribute(nonce, name, variables);
        case 'MobileWorkItemState':
          return _lifecycleRead(nonce, name, variables);
        case 'MobileUpdateWorkItemState':
          return _lifecycleMutation(nonce, name, variables);
        case 'MobileWorkItemLabels':
          return _labelsRead(nonce, name, variables);
        case 'MobileUpdateWorkItemLabels':
          return _labelsMutation(nonce, name, variables);
        case 'MobileWorkItemWeightAttribute':
        case 'MobileWorkItemWeight':
          return _weightRead(nonce, name, variables);
        case 'MobileSetWorkItemWeight':
          return _weightMutation(nonce, name, variables);
        case 'MobileWorkItemAssignees':
          return _assigneesRead(nonce, name, variables);
        case 'MobileProjectAssigneeCandidates':
        case 'MobileGroupAssigneeCandidates':
          return _assigneeCandidates(nonce, name, variables);
        case 'MobileSetWorkItemAssignees':
          return _assigneesMutation(nonce, name, variables);
        case 'MobileWorkItemMilestoneAttribute':
        case 'MobileWorkItemMilestone':
          return _milestoneRead(nonce, name, variables);
        case 'MobileProjectWorkItemMilestones':
        case 'MobileGroupWorkItemMilestones':
          return _milestoneChoices(nonce, name, variables);
        case 'MobileSetWorkItemMilestone':
          return _milestoneMutation(nonce, name, variables);
      }
    }
    return _reject(nonce, 'operation ${query.split('\n').first}');
  }

  ResponseBody _reject(int nonce, String reason) {
    unhandled.add(reason);
    requests.add(
      StatusFixtureRequest(
        nonce: nonce,
        kind: StatusFixtureRequestKind.rejected,
        operation: 'rejected $reason',
      ),
    );
    return jsonResponse({
      'errors': [
        {'message': 'synthetic fixture rejected $reason'},
      ],
    }, status: 400);
  }

  Future<ResponseBody> _read(int nonce, Map<String, Object?> variables) async {
    final id = variables['id'];
    if (variables.length != 1 || id is! String) {
      return _reject(nonce, 'read variables');
    }
    requests.add(
      StatusFixtureRequest(
        nonce: nonce,
        kind: StatusFixtureRequestKind.read,
        workItemId: id,
        operation: 'MobileWorkItemStatus',
      ),
    );
    final gate = holdNextRead;
    holdNextRead = null;
    if (gate != null) {
      _consumed.add(gate);
      await gate.future;
    }
    final drift = beforeNextRead;
    beforeNextRead = null;
    drift?.call(this);
    final current = items[id];
    return jsonResponse({
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/$actorUserId'},
        'workItem': current == null ? null : _readNode(current),
      },
    });
  }

  Future<ResponseBody> _mutate(int nonce, Map<String, Object?> variables) async {
    final input = variables['input'];
    if (variables.length != 1 || input is! Map) {
      return _reject(nonce, 'mutation variables');
    }
    final typed = input.cast<String, Object?>();
    final widget = typed['statusWidget'];
    final id = typed['id'];
    if (typed.keys.toSet().difference({'id', 'statusWidget'}).isNotEmpty ||
        typed.length != 2 ||
        id is! String ||
        widget is! Map ||
        widget.length != 1 ||
        widget['status'] is! String) {
      return _reject(nonce, 'mutation input ${typed.keys.join(',')}');
    }
    final mutationNonce = ++_mutationNonce;
    requests.add(
      StatusFixtureRequest(
        nonce: nonce,
        kind: StatusFixtureRequestKind.mutation,
        workItemId: id,
        mutationNonce: mutationNonce,
        operation: 'MobileUpdateWorkItemStatus',
        input: Map<String, Object?>.unmodifiable({
          'id': id,
          'statusWidget': Map<String, Object?>.unmodifiable({
            'status': widget['status'],
          }),
        }),
      ),
    );
    final desired = widget['status'] as String;

    final apply = holdBeforeApply;
    holdBeforeApply = null;
    if (apply != null) {
      _consumed.add(apply);
      _awaitingApply = true;
      try {
        await apply.future;
      } finally {
        _awaitingApply = false;
      }
    }

    final current = items[id];
    final refused = rejectNextMutation;
    rejectNextMutation = null;
    final member = current?.members
        ?.where((candidate) => candidate.id == desired)
        .firstOrNull;
    if (refused != null ||
        current == null ||
        member == null ||
        current.setWorkItemMetadata != true) {
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': refused ?? const ['Status is not allowed'],
            'workItem': null,
          },
        },
      });
    }

    current.assignment = member;
    current.updatedAt = current.updatedAt.add(
      Duration(seconds: advanceSeconds),
    );
    current.lockVersion++;
    if (current.closesOn.contains(desired)) current.state = 'CLOSED';
    if (current.reopensOn.contains(desired)) current.state = 'OPEN';
    appliedMutationNonces.add(mutationNonce);
    final acknowledgement = _ackNode(current);
    final lose = loseNextAck;
    loseNextAck = false;

    final ack = holdAck;
    holdAck = null;
    if (ack != null) {
      _consumed.add(ack);
      _awaitingAck = true;
      try {
        await ack.future;
      } finally {
        _awaitingAck = false;
      }
    }
    if (lose) {
      return jsonResponse({'message': 'lost acknowledgement'}, status: 503);
    }
    return jsonResponse({
      'data': {
        'workItemUpdate': {'errors': <String>[], 'workItem': acknowledgement},
      },
    });
  }

  static const _refs = <GraphResourceRef>[
    projectNamespaceRef,
    groupRef,
  ];

  static const _emptyPage = {'hasNextPage': false, 'endCursor': null};

  Future<void> _gate(Completer<void>? gate) async {
    if (gate == null) return;
    _consumed.add(gate);
    await gate.future;
  }

  void _recordParent(
    int nonce,
    String operation, {
    String? workItemId,
    Map<String, Object?>? input,
    StatusFixtureRequestKind kind = StatusFixtureRequestKind.parentRead,
  }) {
    requests.add(
      StatusFixtureRequest(
        nonce: nonce,
        kind: kind,
        workItemId: workItemId,
        input: input == null ? null : Map<String, Object?>.unmodifiable(input),
        operation: operation,
      ),
    );
  }

  Future<ResponseBody> _rest(int nonce, Uri uri) async {
    final segments = uri.pathSegments;
    final api = segments.indexOf('api');
    if (api < 0 || api + 1 >= segments.length || segments[api + 1] != 'v4') {
      return _reject(nonce, 'endpoint GET ${uri.path}');
    }
    final rest = segments.sublist(api + 2);
    final operation = 'GET ${rest.join('/')}';
    if (rest.length == 1 && rest.single == 'user') {
      _recordParent(nonce, operation);
      return jsonResponse({
        'id': actorUserId,
        'username': account.user.username,
        'name': account.user.name,
      });
    }
    if (rest.length == 2 && rest.first == 'projects') {
      _recordParent(nonce, operation);
      final gate = holdNextProject;
      holdNextProject = null;
      await _gate(gate);
      final target = rest.last;
      if (target != projectRef.fullPath && target != '42') {
        return jsonResponse({'message': '404 Project Not Found'}, status: 404);
      }
      return jsonResponse({
        'id': 42,
        'name': 'mobile',
        'path_with_namespace': projectRef.fullPath,
        'visibility': 'private',
        'default_branch': 'main',
        'archived': false,
      });
    }
    if (rest.length == 2 &&
        rest.first == 'groups' &&
        rest.last == groupRef.fullPath) {
      _recordParent(nonce, operation);
      final gate = holdNextGroup;
      holdNextGroup = null;
      await _gate(gate);
      return jsonResponse({
        'id': 84,
        'name': 'group',
        'full_path': groupRef.fullPath,
        'visibility': 'private',
        'description': null,
      });
    }
    return _reject(nonce, 'endpoint GET ${uri.path}');
  }

  Future<ResponseBody> _labelsRead(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final id = variables['id'];
    final current = items[id];
    if (current == null || current.labelIds == null) {
      return _reject(nonce, 'operation $operation without labels');
    }
    _recordParent(nonce, operation, workItemId: current.id);
    final gate = holdNextLabelsRead;
    holdNextLabelsRead = null;
    await _gate(gate);
    return jsonResponse({
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/$actorUserId'},
        'workItem': {
          'id': current.id,
          'iid': '${current.iid}',
          'title': current.title,
          'state': current.state,
          'createdAt': statusFixtureTimestamp(current.createdAt),
          'updatedAt': statusFixtureTimestamp(current.updatedAt),
          'project': _ref(current.project),
          'namespace': _ref(current.namespace),
          'workItemType': {
            'id': current.typeId,
            'name': current.typeName,
            'widgetDefinitions': [
              {'type': 'LABELS', 'allowsScopedLabels': null},
            ],
          },
          'userPermissions': {
            'readWorkItem': current.readWorkItem,
            'setWorkItemMetadata': current.setWorkItemMetadata,
          },
          'widgets': [_labelsWidget(current)],
        },
      },
    });
  }

  Future<ResponseBody> _labelsMutation(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final input = variables['input'];
    if (variables.length != 1 || input is! Map) {
      return _reject(nonce, 'labels variables');
    }
    final typed = input.cast<String, Object?>();
    final current = items[typed['id']];
    final widget = typed['labelsWidget'];
    if (current == null ||
        current.labelIds == null ||
        typed.length != 2 ||
        widget is! Map) {
      return _reject(nonce, 'labels input ${typed.keys.join(',')}');
    }
    _recordParent(
      nonce,
      operation,
      workItemId: current.id,
      input: typed,
      kind: StatusFixtureRequestKind.parentMutation,
    );
    final gate = holdNextLabelsMutation;
    holdNextLabelsMutation = null;
    await _gate(gate);
    List<String> ids(Object? raw) =>
        raw is List ? [for (final id in raw) '$id'] : const [];
    final remove = ids(widget['removeLabelIds']).toSet();
    current.labelIds = [
      for (final id in current.labelIds!)
        if (!remove.contains(id)) id,
      ...ids(widget['addLabelIds']),
    ];
    current.updatedAt = current.updatedAt.add(
      Duration(seconds: advanceSeconds),
    );
    current.lockVersion++;
    return jsonResponse({
      'data': {
        'workItemUpdate': {
          'errors': <String>[],
          'workItem': {
            'id': current.id,
            'updatedAt': statusFixtureTimestamp(current.updatedAt),
          },
        },
      },
    });
  }

  Future<ResponseBody> _weightRead(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final current = items[variables['id']];
    if (current == null || !current.weightWidget) {
      return _reject(nonce, 'operation $operation without weight');
    }
    _recordParent(nonce, operation, workItemId: current.id);
    return jsonResponse({
      'data': {
        if (operation == 'MobileWorkItemWeight')
          'currentUser': {'id': 'gid://gitlab/User/$actorUserId'},
        'workItem': _weightNode(current),
      },
    });
  }

  Future<ResponseBody> _weightMutation(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final input = variables['input'];
    if (variables.length != 1 || input is! Map) {
      return _reject(nonce, 'weight variables');
    }
    final typed = input.cast<String, Object?>();
    final current = items[typed['id']];
    final widget = typed['weightWidget'];
    if (current == null ||
        !current.weightWidget ||
        typed.length != 2 ||
        widget is! Map ||
        widget.length != 1 ||
        !widget.containsKey('weight') ||
        (widget['weight'] != null && widget['weight'] is! int)) {
      return _reject(nonce, 'weight input ${typed.keys.join(',')}');
    }
    _recordParent(
      nonce,
      operation,
      workItemId: current.id,
      input: typed,
      kind: StatusFixtureRequestKind.parentMutation,
    );
    final gate = holdNextWeightMutation;
    holdNextWeightMutation = null;
    await _gate(gate);
    current.weight = widget['weight'] as int?;
    current.updatedAt = current.updatedAt.add(
      Duration(seconds: advanceSeconds),
    );
    current.lockVersion++;
    return jsonResponse({
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/$actorUserId'},
        'workItemUpdate': {
          'errors': <String>[],
          'workItem': _weightNode(current),
        },
      },
    });
  }

  Map<String, Object?> _weightWidget(StatusFixtureItem current) => {
    'type': 'WEIGHT',
    'weight': current.weight,
    'rolledUpWeight': null,
    'rolledUpCompletedWeight': null,
  };

  Map<String, Object?> _weightNode(StatusFixtureItem current) => {
    'id': current.id,
    'iid': '${current.iid}',
    'title': current.title,
    'state': current.state,
    'createdAt': statusFixtureTimestamp(current.createdAt),
    'updatedAt': statusFixtureTimestamp(current.updatedAt),
    'project': _ref(current.project),
    'namespace': _ref(current.namespace),
    'workItemType': {'id': current.typeId, 'name': current.typeName},
    'userPermissions': {'readWorkItem': true, 'adminWorkItem': true},
    'widgets': [_weightWidget(current)],
  };

  /// Summary fields every assignee and milestone read repeats.
  Map<String, Object?> _metadataSummary(StatusFixtureItem current) => {
    'id': current.id,
    'iid': '${current.iid}',
    'title': current.title,
    'state': current.state,
    'createdAt': statusFixtureTimestamp(current.createdAt),
    'updatedAt': statusFixtureTimestamp(current.updatedAt),
    'project': _ref(current.project),
    'namespace': _ref(current.namespace),
    'workItemType': {'id': current.typeId, 'name': current.typeName},
  };

  Map<String, Object?> _metadataPermissions(StatusFixtureItem current) => {
    'readWorkItem': current.readWorkItem,
    'setWorkItemMetadata': current.setWorkItemMetadata,
  };

  void _advance(StatusFixtureItem current) {
    current.updatedAt = current.updatedAt.add(
      Duration(seconds: advanceSeconds),
    );
    current.lockVersion++;
  }

  /// The detail preview is `first: 20`; full reads and the ACK are
  /// `first: 100`. Larger sets are outside this fixture.
  Map<String, Object?> _assigneesWidget(
    StatusFixtureItem current, {
    required int limit,
  }) {
    final ids = current.assigneeIds!;
    if (ids.length > 100) throw StateError('more than one assignee page');
    final more = ids.length > limit;
    return {
      'type': 'ASSIGNEES',
      'allowsMultipleAssignees': true,
      'assignees': {
        'nodes': [
          for (final id in ids.take(limit))
            {
              'id': id,
              'name': statusFixtureUsers[id]?.name ?? '人員-$id',
              'username': statusFixtureUsers[id]?.username ?? 'user',
            },
        ],
        'pageInfo': {'hasNextPage': more, 'endCursor': more ? '$limit' : null},
      },
    };
  }

  Future<ResponseBody> _assigneesRead(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final current = items[variables['id']];
    if (current == null ||
        current.assigneeIds == null ||
        variables.length != 2 ||
        variables['after'] != null) {
      return _reject(nonce, 'operation $operation without assignees');
    }
    _recordParent(nonce, operation, workItemId: current.id);
    return jsonResponse({
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/$actorUserId'},
        'workItem': {
          ..._metadataSummary(current),
          'userPermissions': _metadataPermissions(current),
          'widgets': [_assigneesWidget(current, limit: 100)],
        },
      },
    });
  }

  Future<ResponseBody> _assigneeCandidates(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final path = variables['fullPath'];
    final search = variables['search'];
    if (variables.length != 2 ||
        path is! String ||
        search is! String ||
        !items.values.any((item) => item.assigneeIds != null)) {
      return _reject(nonce, 'operation $operation without assignees');
    }
    _recordParent(nonce, operation);
    final group = operation == 'MobileGroupAssigneeCandidates';
    final scope = group ? groupRef : projectRef;
    final users = [
      for (final entry in statusFixtureUsers.entries)
        if (search.isEmpty ||
            entry.value.name.contains(search) ||
            entry.value.username.contains(search))
          {
            'id': entry.key,
            'name': entry.value.name,
            'username': entry.value.username,
          },
    ].take(20).toList();
    return jsonResponse({
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/$actorUserId'},
        (group ? 'group' : 'project'): path != scope.fullPath
            ? null
            : {
                'id': scope.id,
                'fullPath': scope.fullPath,
                'autocompleteUsers': users,
              },
      },
    });
  }

  Future<ResponseBody> _assigneesMutation(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final input = variables['input'];
    if (variables.length != 1 || input is! Map) {
      return _reject(nonce, 'assignees variables');
    }
    final typed = input.cast<String, Object?>();
    final current = items[typed['id']];
    final widget = typed['assigneesWidget'];
    if (current == null ||
        current.assigneeIds == null ||
        typed.length != 2 ||
        widget is! Map ||
        widget.length != 1 ||
        widget['assigneeIds'] is! List) {
      return _reject(nonce, 'assignees input ${typed.keys.join(',')}');
    }
    _recordParent(
      nonce,
      operation,
      workItemId: current.id,
      input: typed,
      kind: StatusFixtureRequestKind.parentMutation,
    );
    final gate = holdNextAssigneesMutation;
    holdNextAssigneesMutation = null;
    await _gate(gate);
    current.assigneeIds = [
      for (final id in widget['assigneeIds'] as List) '$id',
    ];
    _advance(current);
    return jsonResponse({
      'data': {
        'workItemUpdate': {
          'errors': <String>[],
          'workItem': {
            ..._metadataSummary(current),
            'widgets': [_assigneesWidget(current, limit: 100)],
          },
        },
      },
    });
  }

  /// A milestone owned by the item's own scope: project-owned for a project
  /// item (`group: null`), group-owned for a group item (`project: null`).
  /// The attribute query does not select `expired`.
  Map<String, Object?>? _milestoneNode(
    String? id, {
    required bool groupOwned,
    required bool withExpiry,
  }) {
    if (id == null) return null;
    final number = id.split('/').last;
    final owner = groupOwned ? groupRef : projectRef;
    return {
      'id': id,
      'iid': number,
      'title': statusFixtureMilestones[id] ?? '里程碑-$number',
      'state': 'active',
      if (withExpiry) 'expired': false,
      'dueDate': '2026-10-31',
      'startDate': '2026-10-01',
      'webPath': '/${owner.fullPath}/-/milestones/$number',
      'project': groupOwned ? null : _ref(owner),
      'group': groupOwned ? _ref(owner) : null,
    };
  }

  Future<ResponseBody> _milestoneRead(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final current = items[variables['id']];
    if (current == null || !current.milestoneWidget || variables.length != 1) {
      return _reject(nonce, 'operation $operation without milestone');
    }
    _recordParent(nonce, operation, workItemId: current.id);
    final attribute = operation == 'MobileWorkItemMilestoneAttribute';
    final widget = {
      'type': 'MILESTONE',
      'milestone': _milestoneNode(
        current.milestoneId,
        groupOwned: current.project == null,
        withExpiry: !attribute,
      ),
    };
    if (attribute) {
      return jsonResponse({
        'data': {
          'workItem': {
            'id': current.id,
            'iid': '${current.iid}',
            'project': _ref(current.project),
            'namespace': _ref(current.namespace),
            'widgets': [widget],
          },
        },
      });
    }
    return jsonResponse({
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/$actorUserId'},
        'workItem': {
          ..._metadataSummary(current),
          'userPermissions': _metadataPermissions(current),
          'widgets': [widget],
        },
      },
    });
  }

  Future<ResponseBody> _milestoneChoices(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final path = variables['fullPath'];
    final search = variables['search'];
    if (variables.length != 3 ||
        path is! String ||
        variables['after'] != null ||
        (search != null && search is! String) ||
        !items.values.any((item) => item.milestoneWidget)) {
      return _reject(nonce, 'operation $operation without milestone');
    }
    _recordParent(nonce, operation);
    final filter = search as String?;
    final group = operation == 'MobileGroupWorkItemMilestones';
    final scope = group ? groupRef : projectRef;
    return jsonResponse({
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/$actorUserId'},
        (group ? 'group' : 'project'): path != scope.fullPath
            ? null
            : {
                'id': scope.id,
                'fullPath': scope.fullPath,
                'milestones': {
                  'nodes': [
                    for (final entry in statusFixtureMilestones.entries)
                      if (filter == null || entry.value.contains(filter))
                        _milestoneNode(
                          entry.key,
                          groupOwned: group,
                          withExpiry: true,
                        ),
                  ],
                  'pageInfo': _emptyPage,
                },
              },
      },
    });
  }

  Future<ResponseBody> _milestoneMutation(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final input = variables['input'];
    if (variables.length != 1 || input is! Map) {
      return _reject(nonce, 'milestone variables');
    }
    final typed = input.cast<String, Object?>();
    final current = items[typed['id']];
    final widget = typed['milestoneWidget'];
    if (current == null ||
        !current.milestoneWidget ||
        typed.length != 2 ||
        widget is! Map ||
        widget.length != 1 ||
        !widget.containsKey('milestoneId') ||
        (widget['milestoneId'] != null && widget['milestoneId'] is! String)) {
      return _reject(nonce, 'milestone input ${typed.keys.join(',')}');
    }
    _recordParent(
      nonce,
      operation,
      workItemId: current.id,
      input: typed,
      kind: StatusFixtureRequestKind.parentMutation,
    );
    final gate = holdNextMilestoneMutation;
    holdNextMilestoneMutation = null;
    await _gate(gate);
    final desired = widget['milestoneId'] as String?;
    if (desired != null && !statusFixtureMilestones.containsKey(desired)) {
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': ['Milestone not found'],
            'workItem': null,
          },
        },
      });
    }
    current.milestoneId = desired;
    _advance(current);
    return jsonResponse({
      'data': {
        'workItemUpdate': {
          'errors': <String>[],
          'workItem': {
            ..._metadataSummary(current),
            'widgets': [
              {
                'type': 'MILESTONE',
                'milestone': _milestoneNode(
                  desired,
                  groupOwned: current.project == null,
                  withExpiry: true,
                ),
              },
            ],
          },
        },
      },
    });
  }

  Map<String, Object?> _labelsWidget(StatusFixtureItem current) => {
    'type': 'LABELS',
    'labels': {
      'nodes': [
        for (final id in current.labelIds!)
          {
            'id': id,
            'title': statusFixtureLabels[id] ?? '標籤-$id',
            'color': '#1068BF',
            'textColor': '#FFFFFF',
          },
      ],
      'pageInfo': _emptyPage,
    },
  };

  Future<ResponseBody> _projectDetail(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final path = variables['path'];
    final iid = variables['iid'];
    _recordParent(nonce, operation);
    final gate = holdNextDetail;
    holdNextDetail = null;
    await _gate(gate);
    if (failNextDetail) {
      failNextDetail = false;
      return jsonResponse({'message': 'synthetic detail outage'}, status: 503);
    }
    if (path != projectRef.fullPath || iid is! String) {
      return jsonResponse({
        'data': {'project': null},
      });
    }
    final matches = [
      for (final item in items.values)
        if (item.project?.fullPath == path && '${item.iid}' == iid) item,
    ];
    return jsonResponse({
      'data': {
        'project': {
          'id': projectRef.id,
          'fullPath': projectRef.fullPath,
          'workItems': {
            'nodes': [for (final item in matches) _detailNode(item)],
            'pageInfo': _emptyPage,
          },
        },
      },
    });
  }

  Future<ResponseBody> _namespaceDetail(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final path = variables['path'];
    final iid = variables['iid'];
    _recordParent(nonce, operation);
    final gate = holdNextDetail;
    holdNextDetail = null;
    await _gate(gate);
    final ref = _refs
        .where((candidate) => candidate.fullPath == path)
        .firstOrNull;
    if (ref == null) {
      return jsonResponse({
        'data': {'namespace': null},
      });
    }
    final item = items.values
        .where(
          (item) => item.namespace?.id == ref.id && '${item.iid}' == iid,
        )
        .firstOrNull;
    return jsonResponse({
      'data': {
        'namespace': {
          'id': ref.id,
          'fullPath': ref.fullPath,
          'workItem': item == null ? null : _detailNode(item),
        },
      },
    });
  }

  Future<ResponseBody> _projectList(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    _recordParent(nonce, operation);
    final gate = holdNextList;
    holdNextList = null;
    await _gate(gate);
    if (variables['path'] != projectRef.fullPath) {
      return jsonResponse({
        'data': {'project': null},
      });
    }
    return jsonResponse({
      'data': {
        'project': {
          'id': projectRef.id,
          'fullPath': projectRef.fullPath,
          'workItems': {
            'nodes': [
              for (final item in items.values)
                if (item.project?.id == projectRef.id) _summaryNode(item),
            ],
            'pageInfo': _emptyPage,
          },
        },
      },
    });
  }

  Future<ResponseBody> _groupList(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    _recordParent(nonce, operation);
    final gate = holdNextList;
    holdNextList = null;
    await _gate(gate);
    if (variables['path'] != groupRef.fullPath) {
      return jsonResponse({
        'data': {'group': null},
      });
    }
    final state = variables['state'];
    return jsonResponse({
      'data': {
        'group': {
          'id': groupRef.id,
          'fullPath': groupRef.fullPath,
          'workItems': {
            'nodes': [
              for (final item in items.values)
                if (item.namespace?.id == groupRef.id &&
                    item.project == null &&
                    (state == 'all' ||
                        (state == 'opened' && item.state == 'OPEN') ||
                        (state == 'closed' && item.state == 'CLOSED')))
                  _summaryNode(item),
            ],
            'pageInfo': _emptyPage,
          },
        },
      },
    });
  }

  Future<ResponseBody> _types(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    _recordParent(nonce, operation);
    final ref = _refs.where(
      (candidate) => candidate.fullPath == variables['path'],
    );
    if (ref.isEmpty) {
      return jsonResponse({
        'data': {'namespace': null},
      });
    }
    return jsonResponse({
      'data': {
        'namespace': {
          'id': ref.first.id,
          'fullPath': ref.first.fullPath,
          'workItemTypes': {
            'nodes': [
              {
                'id': typeId,
                'name': '客戶自訂目標',
                'enabled': true,
                'isGroupWorkItemType': true,
                'widgetDefinitions': [
                  {'type': 'STATUS'},
                ],
              },
            ],
            'pageInfo': _emptyPage,
          },
        },
      },
    });
  }

  Future<ResponseBody> _statusAttribute(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final id = variables['id'];
    _recordParent(nonce, operation, workItemId: id is String ? id : null);
    final gate = holdNextAttribute;
    holdNextAttribute = null;
    await _gate(gate);
    final current = items[id];
    final assignment = current?.assignment;
    return jsonResponse({
      'data': {
        'workItem': current == null
            ? null
            : {
                'id': current.id,
                'iid': '${current.iid}',
                'project': _ref(current.project),
                'namespace': _ref(current.namespace),
                'widgets': current.statusWidgetPresent
                    ? [
                        {
                          'type': 'STATUS',
                          'status': assignment == null
                              ? null
                              : {
                                  'id': assignment.id,
                                  'name': assignment.name,
                                  'iconName': assignment.iconName,
                                  'color': assignment.color,
                                  'category': assignment.category,
                                },
                        },
                      ]
                    : const <Object?>[],
              },
      },
    });
  }

  Future<ResponseBody> _lifecycleRead(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final id = variables['id'];
    _recordParent(nonce, operation, workItemId: id is String ? id : null);
    final gate = holdNextLifecycleRead;
    holdNextLifecycleRead = null;
    await _gate(gate);
    final current = items[id];
    return jsonResponse({
      'data': {
        'workItem': current == null
            ? null
            : {
                ..._lifecycleNode(current),
                'userPermissions': {'updateWorkItem': lifecycleCanUpdate},
              },
      },
    });
  }

  Future<ResponseBody> _lifecycleMutation(
    int nonce,
    String operation,
    Map<String, Object?> variables,
  ) async {
    final input = variables['input'];
    if (input is! Map) return _reject(nonce, 'lifecycle variables');
    final typed = input.cast<String, Object?>();
    final id = typed['id'];
    _recordParent(
      nonce,
      operation,
      workItemId: id is String ? id : null,
      input: typed,
      kind: StatusFixtureRequestKind.parentMutation,
    );
    final gate = holdNextLifecycleMutation;
    holdNextLifecycleMutation = null;
    await _gate(gate);
    final current = items[id];
    final event = typed['stateEvent'];
    if (current == null || (event != 'CLOSE' && event != 'REOPEN')) {
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': ['Lifecycle event refused'],
            'workItem': null,
          },
        },
      });
    }
    current.state = event == 'CLOSE' ? 'CLOSED' : 'OPEN';
    current.updatedAt = current.updatedAt.add(
      Duration(seconds: advanceSeconds),
    );
    current.lockVersion++;
    return jsonResponse({
      'data': {
        'workItemUpdate': {
          'errors': <String>[],
          'workItem': _lifecycleNode(current),
        },
      },
    });
  }

  Map<String, Object?> _lifecycleNode(StatusFixtureItem current) => {
    'id': current.id,
    'iid': '${current.iid}',
    'state': current.state,
    'updatedAt': statusFixtureTimestamp(current.updatedAt),
    'project': _ref(current.project),
    'namespace': _ref(current.namespace),
    'workItemType': {'id': current.typeId},
  };

  Map<String, Object?> _summaryNode(
    StatusFixtureItem current, {
    bool asChild = false,
  }) => {
    'id': current.id,
    'iid': '${current.iid}',
    'title': current.title,
    'state': current.state,
    'createdAt': statusFixtureTimestamp(current.createdAt),
    'updatedAt': statusFixtureTimestamp(current.updatedAt),
    'project': _ref(current.project),
    'namespace': asChild && current.hideNamespaceAsChild
        ? null
        : _ref(current.namespace),
    'workItemType': {'id': current.typeId, 'name': current.typeName},
  };

  Map<String, Object?> _detailNode(StatusFixtureItem current) {
    final children = [for (final id in current.childIds) ?items[id]];
    return {
      ..._summaryNode(current),
      'description': null,
      'widgets': [
        if (current.statusWidgetPresent) {'type': 'STATUS'},
        if (current.assigneeIds != null) _assigneesWidget(current, limit: 20),
        if (current.milestoneWidget) {'type': 'MILESTONE'},
        if (current.labelIds != null) _labelsWidget(current),
        if (current.weightWidget) _weightWidget(current),
        if (current.childIds.isNotEmpty)
          {
            'type': 'HIERARCHY',
            'hasParent': false,
            'hasChildren': children.isNotEmpty,
            'parent': null,
            'children': {
              'nodes': [
                for (final child in children)
                  _summaryNode(child, asChild: true),
              ],
              'pageInfo': _emptyPage,
            },
          },
      ],
    };
  }

  Map<String, Object?> _readNode(StatusFixtureItem current) {
    final members = current.members;
    final definition = {
      'type': 'STATUS',
      'allowedStatuses': members == null
          ? null
          : [for (final member in members) member.toJson()],
    };
    return {
      'id': current.id,
      'iid': '${current.iid}',
      'title': current.title,
      'state': current.state,
      'createdAt': statusFixtureTimestamp(current.createdAt),
      'updatedAt': statusFixtureTimestamp(current.updatedAt),
      'lockVersion': current.lockVersion,
      'project': _ref(current.project),
      'namespace': _ref(current.namespace),
      'workItemType': {
        'id': current.typeId,
        'name': current.typeName,
        'widgetDefinitions': [
          {'type': 'ASSIGNEES'},
          if (current.statusDefinitionPresent) definition,
          if (current.duplicateStatusDefinition) definition,
        ],
      },
      'userPermissions': {
        'readWorkItem': current.readWorkItem,
        'setWorkItemMetadata': current.setWorkItemMetadata,
      },
      'widgets': _statusWidgets(current),
    };
  }

  Map<String, Object?> _ackNode(StatusFixtureItem current) => {
    'id': current.id,
    'iid': '${current.iid}',
    'state': current.state,
    'updatedAt': statusFixtureTimestamp(current.updatedAt),
    'project': _ref(current.project),
    'namespace': _ref(current.namespace),
    'workItemType': {'id': current.typeId},
    'widgets': _statusWidgets(current),
  };

  List<Object?> _statusWidgets(StatusFixtureItem current) =>
      current.statusWidgetPresent
      ? [
          {'type': 'STATUS', 'status': current.assignment?.toJson()},
        ]
      : const <Object?>[];

  Map<String, Object?>? _ref(GraphResourceRef? ref) =>
      ref == null ? null : {'id': ref.id, 'fullPath': ref.fullPath};
}

/// Integer-second ISO8601 in UTC, the shape GitLab returns for `updatedAt`.
String statusFixtureTimestamp(DateTime value) {
  final utc = value.toUtc();
  if (utc.millisecond != 0 || utc.microsecond != 0) {
    throw ArgumentError.value(value, 'value', 'integer seconds only');
  }
  String two(int part) => part.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-'
      '${two(utc.day)}T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
}
