import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_health_edit_models.dart';

import 'fake_adapter.dart';

const healthActorId = 'gid://gitlab/User/7';
const healthUserId = 7;
final healthCreatedAt = DateTime.utc(2026, 10, 1);
final healthRevision = DateTime.utc(2026, 10, 3, 9);

WorkItemGraphSummary healthSummary({String state = 'OPEN'}) =>
    WorkItemGraphSummary(
      id: 'gid://gitlab/WorkItem/31',
      iid: 31,
      title: 'Synthetic health item',
      state: state,
      createdAt: healthCreatedAt,
      updatedAt: healthRevision,
      project: const GraphResourceRef(
        id: 'gid://gitlab/Project/42',
        fullPath: 'studio/mobile-workspace',
      ),
      namespace: const GraphResourceRef(
        id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
        fullPath: 'studio/mobile-workspace',
      ),
      type: const WorkItemGraphType(
        id: 'gid://gitlab/WorkItems::Type/9',
        name: 'Objective',
      ),
    );

WorkItemGraphDetail healthDetail({String state = 'OPEN'}) =>
    WorkItemGraphDetail(
      summary: healthSummary(state: state),
      description: null,
      widgetsAvailable: true,
      widgetTypes: const {'HEALTH_STATUS'},
      descriptionWidget: null,
      assignees: null,
      labels: null,
      hierarchy: null,
      dates: null,
    );

Account healthAccount({
  int id = healthUserId,
  String username = 'health-owner',
}) => Account(
  instance: GitLabInstance.parse('https://example.com/gitlab'),
  user: GitLabUser(id: id, username: username, name: '健康狀態測試者'),
  token: 'synthetic-test-token',
);

enum HealthWidgetMode { present, absent, unavailable, unknownValue }

/// A single controllable barrier. [reached] completes when the server arrives
/// at the barrier; the server waits until [release] is called.
final class HealthGate {
  final Completer<void> _reached = Completer<void>();
  final Completer<void> _released = Completer<void>();

  Future<void> get reached => _reached.future;
  bool get isReached => _reached.isCompleted;
  bool get isReleased => _released.isCompleted;

  Future<void> _arrive() {
    if (!_reached.isCompleted) _reached.complete();
    return _released.future;
  }

  void release() {
    if (!_released.isCompleted) _released.complete();
  }
}

/// Stateful synthetic GitLab GraphQL server for the Health editor. Only the
/// approved Health read and update operations are routed; every other request
/// is recorded in [unknownRequests] and answered with 404.
final class WorkItemHealthFixture {
  WorkItemHealthFixture({this.value = WorkItemHealthEditValue.needsAttention}) {
    adapter = FakeAdapter(_respond);
  }

  late final FakeAdapter adapter;
  WorkItemHealthEditValue? value;
  DateTime updatedAt = healthRevision;
  bool readWorkItem = true;
  bool adminWorkItem = true;
  HealthWidgetMode widgets = HealthWidgetMode.present;
  List<Map<String, Object?>> rolledUp = const [
    {'healthStatus': 'onTrack', 'count': 2},
  ];

  /// Barrier after the mutation is received but before the server applies it.
  HealthGate? beforeApply;

  /// Barrier after the server applied the mutation but before the ACK body.
  HealthGate? beforeAck;

  /// Barrier before the next read is answered (consumed by that read).
  HealthGate? nextReadGate;

  /// Next mutation answers with GraphQL payload `errors` and does not apply.
  List<String>? nextMutationErrors;

  /// Next mutation fails at transport level after being received.
  bool nextMutationTransportFailure = false;

  /// Next mutation acknowledges without applying (server keeps old value).
  bool nextMutationNotApplied = false;

  final List<String> operations = [];
  final List<Map<String, Object?>> mutationInputs = [];
  final List<String> unknownRequests = [];
  final List<bool> authorizationPresent = [];
  final List<bool> redirectsDisabled = [];
  final List<HealthGate> _heldGates = [];
  var appliedChanges = 0;

  /// Read response bodies actually returned to the client.
  var readsAnswered = 0;

  /// Mutation ACK response bodies actually returned to the client.
  var acksAnswered = 0;

  int get requests => adapter.requests.length;
  int get reads => operations.where((item) => item == 'read').length;
  int get mutationsReceived =>
      operations.where((item) => item == 'mutation').length;

  /// Releases every armed gate and every gate a request already parked on,
  /// including a consumed [nextReadGate].
  void releaseAll() {
    beforeApply?.release();
    beforeAck?.release();
    nextReadGate?.release();
    for (final gate in _heldGates) {
      gate.release();
    }
  }

  Future<void> _hold(HealthGate gate) {
    _heldGates.add(gate);
    return gate._arrive();
  }

  Future<ResponseBody> _respond(RequestOptions request) async {
    authorizationPresent.add(
      request.headers['Authorization'] == 'Bearer synthetic-test-token',
    );
    redirectsDisabled.add(
      !request.followRedirects && request.maxRedirects == 0,
    );
    final body = request.data;
    final query = body is Map ? body['query'] : null;
    if (request.method != 'POST' ||
        request.uri.path != '/gitlab/api/graphql' ||
        query is! String) {
      unknownRequests.add('${request.method} ${request.uri.path}');
      return jsonResponse({'message': '404 Not Found'}, status: 404);
    }
    final variables = (body as Map)['variables'];
    if (query.startsWith('query MobileWorkItemHealthEdit')) {
      if (variables is! Map ||
          variables.length != 1 ||
          variables['id'] != healthSummary().id) {
        unknownRequests.add('read with unexpected variables');
        return jsonResponse({'message': '404 Not Found'}, status: 404);
      }
      operations.add('read');
      final gate = nextReadGate;
      nextReadGate = null;
      if (gate != null) await _hold(gate);
      final response = jsonResponse(_read());
      readsAnswered++;
      return response;
    }
    if (query.startsWith('mutation MobileSetWorkItemHealthStatus')) {
      final input = variables is Map ? variables['input'] : null;
      if (input is! Map ||
          input.length != 2 ||
          input['id'] != healthSummary().id ||
          input['healthStatusWidget'] is! Map ||
          (input['healthStatusWidget'] as Map).length != 1 ||
          !(input['healthStatusWidget'] as Map).containsKey('healthStatus')) {
        unknownRequests.add('mutation with unexpected input');
        return jsonResponse({'message': '404 Not Found'}, status: 404);
      }
      operations.add('mutation');
      mutationInputs.add(jsonDecode(jsonEncode(input)) as Map<String, Object?>);
      final desired = WorkItemHealthEditValue.parse(
        (input['healthStatusWidget'] as Map)['healthStatus'],
      );
      final apply = beforeApply;
      if (apply != null) await _hold(apply);
      if (nextMutationTransportFailure) {
        nextMutationTransportFailure = false;
        throw DioException.connectionError(
          requestOptions: request,
          reason: 'synthetic transport failure',
        );
      }
      final errors = nextMutationErrors;
      nextMutationErrors = null;
      final notApplied = nextMutationNotApplied;
      nextMutationNotApplied = false;
      if (errors == null && !notApplied) {
        value = desired;
        appliedChanges++;
        operations.add('apply');
      }
      final ack = beforeAck;
      if (ack != null) await _hold(ack);
      acksAnswered++;
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': errors ?? const <String>[],
            'workItem': _node(includePermissions: false),
          },
        },
      });
    }
    unknownRequests.add('unknown GraphQL operation');
    return jsonResponse({'message': '404 Not Found'}, status: 404);
  }

  Map<String, Object?> _read() => {
    'data': {
      'currentUser': {'id': healthActorId},
      'workItem': _node(includePermissions: true),
    },
  };

  Map<String, Object?> _node({required bool includePermissions}) {
    final summary = healthSummary();
    return {
      'id': summary.id,
      'iid': '${summary.iid}',
      'title': summary.title,
      'state': summary.state,
      'createdAt': summary.createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'project': {
        'id': summary.project!.id,
        'fullPath': summary.project!.fullPath,
      },
      'namespace': {
        'id': summary.namespace!.id,
        'fullPath': summary.namespace!.fullPath,
      },
      'workItemType': {'id': summary.type.id, 'name': summary.type.name},
      if (includePermissions)
        'userPermissions': {
          'readWorkItem': readWorkItem,
          'adminWorkItem': adminWorkItem,
        },
      'widgets': switch (widgets) {
        HealthWidgetMode.unavailable => null,
        HealthWidgetMode.absent => const <Object?>[],
        HealthWidgetMode.present => [
          {
            'type': 'HEALTH_STATUS',
            'healthStatus': value?.graphValue,
            'rolledUpHealthStatus': rolledUp,
          },
        ],
        HealthWidgetMode.unknownValue => [
          {
            'type': 'HEALTH_STATUS',
            'healthStatus': 'somethingNew',
            'rolledUpHealthStatus': const <Object?>[],
          },
        ],
      },
    };
  }
}
