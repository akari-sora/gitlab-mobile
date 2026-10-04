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
}

enum StatusFixtureRequestKind { read, mutation, rejected }

final class StatusFixtureRequest {
  const StatusFixtureRequest({
    required this.nonce,
    required this.kind,
    this.workItemId,
    this.mutationNonce,
    this.input,
  });

  final int nonce;
  final StatusFixtureRequestKind kind;
  final String? workItemId;
  final int? mutationNonce;
  final Map<String, Object?>? input;
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
    for (final gate in [holdNextRead, holdBeforeApply, holdAck, ..._consumed]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    _consumed.clear();
  }

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
    return _reject(nonce, 'operation ${query.split('\n').first}');
  }

  ResponseBody _reject(int nonce, String reason) {
    unhandled.add(reason);
    requests.add(
      StatusFixtureRequest(nonce: nonce, kind: StatusFixtureRequestKind.rejected),
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
