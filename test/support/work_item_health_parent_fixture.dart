import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_health_edit_models.dart';

import 'fake_adapter.dart';
import 'work_item_dates_parent_fixture.dart';
import 'work_item_health_fixture.dart';
import 'work_item_status_fixture.dart';

/// One request as the synthetic Health parent server saw it.
final class HealthParentRequest {
  const HealthParentRequest({
    required this.nonce,
    required this.clientTag,
    required this.operation,
    required this.variables,
    required this.item,
  });

  final int nonce;
  final String clientTag;
  final String operation;
  final Map<String, Object?> variables;

  /// The work item the request addresses, resolved from its variables:
  /// [WorkItemStatusFixture.projectItemId] (X) or
  /// [WorkItemStatusFixture.groupItemId] (Y). Null when it names neither.
  final String? item;
}

/// Server-side HEALTH_STATUS state for one work item.
final class HealthParentItem {
  HealthParentItem({
    this.value = WorkItemHealthEditValue.onTrack,
    this.rolledUp = const [
      {'healthStatus': 'onTrack', 'count': 1},
    ],
    this.widgets = HealthWidgetMode.present,
    this.readWorkItem = true,
    this.adminWorkItem = true,
  });

  WorkItemHealthEditValue? value;
  List<Map<String, Object?>>? rolledUp;
  HealthWidgetMode widgets;
  bool readWorkItem;
  bool adminWorkItem;
}

typedef _PreHealthWrite = ({
  WorkItemHealthEditValue? value,
  List<Map<String, Object?>>? rolledUp,
  DateTime updatedAt,
  int lockVersion,
});

/// The parent-page synthetic server for the Health integration: Health edit/read,
/// Health attribute read, and Health mutation are served here from [health];
/// every other request goes to the wrapped [dates] (and [status]) fixture.
class WorkItemHealthParentFixture {
  WorkItemHealthParentFixture({
    WorkItemDatesParentFixture? dates,
  }) : dates = dates ?? (WorkItemDatesParentFixture()..healthWidget = true) {
    this.dates.healthWidget = true;
    health[itemX] = HealthParentItem(
      value: WorkItemHealthEditValue.onTrack,
      rolledUp: const [
        {'healthStatus': 'onTrack', 'count': 1},
      ],
    );
    health[itemY] = HealthParentItem(
      value: WorkItemHealthEditValue.needsAttention,
      rolledUp: const [],
    );
  }

  static const editOp = 'MobileWorkItemHealthEdit';
  static const mutationOp = 'MobileSetWorkItemHealthStatus';
  static const attributeOp = 'MobileWorkItemHealthAttribute';
  static const projectDetailOp = WorkItemDatesParentFixture.projectDetailOp;
  static const namespaceDetailOp = WorkItemDatesParentFixture.namespaceDetailOp;
  static const itemX = WorkItemDatesParentFixture.itemX;
  static const itemY = WorkItemDatesParentFixture.itemY;

  final WorkItemDatesParentFixture dates;
  WorkItemStatusFixture get status => dates.status;
  late final TaggedFakeAdapter adapter = TaggedFakeAdapter('primary', _respond);
  final health = <String, HealthParentItem>{};
  final ledger = <HealthParentRequest>[];
  final mutationInputs = <Map<String, Object?>>[];
  final _clients = <GitLabApi>[];
  final _unhandled = <String>[];

  Account get account => dates.account;

  /// While true, every Health probe for an item without a pending readback is
  /// parked until released by nonce.
  bool armFinalFence = false;

  /// One-shot: held after the mutation arrives and before it is applied.
  Completer<void>? holdBeforeApply;

  /// One-shot: held after the mutation is applied and before the ACK.
  Completer<void>? holdAck;

  /// Applies the next mutation, then answers HTTP 503 instead of the ACK.
  bool loseNextAck = false;

  /// One-shot: the next post-ACK readback read.
  Completer<void>? holdNextConfirmRead;

  /// One-shot: held during the next MobileWorkItemHealthAttribute read.
  Completer<void>? holdNextAttributeRead;

  /// One-shot: the next detail read of an item written here serves the pre-write
  /// node `updatedAt`.
  bool lagNextDetail = false;

  /// If true, the next mutation ACK does not advance updatedAt (serves preflight).
  bool unchangedUpdatedAtOnAck = false;

  int healthMutationRequests = 0;
  int healthApplied = 0;

  var _nonce = 0;
  var _awaitingApply = false;
  var _awaitingAck = false;
  var _awaitingConfirmRead = false;
  var _awaitingAttributeRead = false;
  final _consumed = <Completer<void>>[];
  final _parkedFence = <int, Completer<void>>{};
  final _confirmPending = <String>{};
  final _ackServed = <String>{};
  final _preWrite = <String, _PreHealthWrite>{};

  bool get awaitingApply => _awaitingApply;
  bool get awaitingAck => _awaitingAck;
  bool get awaitingConfirmRead => _awaitingConfirmRead;
  bool get awaitingAttributeRead => _awaitingAttributeRead;
  int get awaitingFinalFenceReads => _parkedFence.length;

  /// Parked fence probes in arrival order.
  List<int> get parkedFenceNonces => List.unmodifiable(_parkedFence.keys);

  List<String> get unhandled => [
    ..._unhandled,
    ...dates.unhandled,
  ];

  /// A second client on the same server, tagged in the ledger.
  GitLabApi replaceApi({String tag = 'client-d'}) {
    final api = testApi(TaggedFakeAdapter(tag, _respond));
    _clients.add(api);
    return api;
  }

  /// A client on the primary adapter, for pure API tests.
  GitLabApi primaryApi() {
    final api = testApi(adapter);
    _clients.add(api);
    return api;
  }

  void releaseFenceNonce(int nonce) {
    final parked = _parkedFence.remove(nonce);
    if (parked == null) throw StateError('no parked fence probe $nonce');
    parked.complete();
  }

  int count(String operation, {String? tag, String? item}) => ledger
      .where(
        (request) =>
            request.operation == operation &&
            (tag == null || request.clientTag == tag) &&
            (item == null || request.item == item),
      )
      .length;

  int detailReads({String? tag, String? item}) =>
      count(projectDetailOp, tag: tag, item: item) +
      count(namespaceDetailOp, tag: tag, item: item);

  int editReads({String? tag, String? item}) =>
      count(editOp, tag: tag, item: item);

  int attributeReads({String? tag, String? item}) =>
      count(attributeOp, tag: tag, item: item);

  /// Completes every armed, consumed or parked gate here and in [dates].
  void releaseHolds() {
    for (final gate in [
      holdBeforeApply,
      holdAck,
      holdNextConfirmRead,
      holdNextAttributeRead,
      ..._consumed,
      ..._parkedFence.values,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    _consumed.clear();
    _parkedFence.clear();
    armFinalFence = false;
    dates.releaseHolds();
  }

  void closeAll() {
    for (final client in _clients) {
      client.close();
    }
    dates.closeAll();
  }

  Future<ResponseBody> _respond(String tag, RequestOptions request) async {
    final nonce = ++_nonce;
    final data = request.data;
    String? query;
    var variables = const <String, Object?>{};
    if (request.method == 'POST' && data is Map && data['query'] is String) {
      query = data['query'] as String;
      final raw = data['variables'];
      if (raw is Map) variables = raw.cast<String, Object?>();
    }
    final operation = query == null
        ? '${request.method} ${request.uri.path}'
        : RegExp(
                r'^\s*(?:query|mutation) (\w+)',
              ).firstMatch(query)?.group(1) ??
              '?';
    final item = _resolve(operation, variables);
    ledger.add(
      HealthParentRequest(
        nonce: nonce,
        clientTag: tag,
        operation: operation,
        variables: Map<String, Object?>.unmodifiable(variables),
        item: item,
      ),
    );
    switch (operation) {
      case editOp:
        return _healthEditRead(nonce, operation, item);
      case mutationOp:
        return _healthMutation(operation, variables, item);
      case attributeOp:
        return _healthAttributeRead(operation, item);
      case projectDetailOp:
      case namespaceDetailOp:
        return _detail(request, item);
    }
    return await dates.adapter.respond(request);
  }

  String? _resolve(String operation, Map<String, Object?> variables) {
    final id = variables['id'];
    if (id is String && health.containsKey(id)) return id;
    final input = variables['input'];
    if (input is Map && input['id'] is String) {
      final inputId = input['id'] as String;
      if (health.containsKey(inputId)) return inputId;
    }
    final path = variables['path'];
    if (operation == projectDetailOp || operation == namespaceDetailOp) {
      for (final entry in status.items.entries) {
        final current = entry.value;
        final location = operation == projectDetailOp
            ? current.project?.fullPath
            : current.namespace?.fullPath;
        if (location == path && '${current.iid}' == '${variables['iid']}') {
          return entry.key;
        }
      }
    }
    return null;
  }

  Future<void> _gate(Completer<void>? gate) async {
    if (gate == null) return;
    _consumed.add(gate);
    await gate.future;
  }

  ResponseBody _reject(String reason) {
    _unhandled.add(reason);
    return jsonResponse({
      'errors': [
        {'message': 'synthetic health parent fixture rejected $reason'},
      ],
    }, status: 400);
  }

  Future<ResponseBody> _healthEditRead(
    int nonce,
    String operation,
    String? id,
  ) async {
    if (id == null || status.items[id] == null || health[id] == null) {
      return _reject('$operation without a known item');
    }
    final readback = _ackServed.contains(id);
    if (readback) {
      _ackServed.remove(id);
      _confirmPending.remove(id);
      final gate = holdNextConfirmRead;
      holdNextConfirmRead = null;
      if (gate != null) {
        _awaitingConfirmRead = true;
        try {
          await _gate(gate);
        } finally {
          _awaitingConfirmRead = false;
        }
      }
    } else if (armFinalFence && !_confirmPending.contains(id)) {
      final parked = Completer<void>();
      _parkedFence[nonce] = parked;
      await parked.future;
    }
    final current = status.items[id]!;
    final state = health[id]!;
    final pre = !readback ? _preWrite[id] : null;
    return jsonResponse({
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/${status.actorUserId}'},
        'workItem': _healthNode(
          current,
          state,
          includePermissions: true,
          pre: pre,
        ),
      },
    });
  }

  Future<ResponseBody> _healthAttributeRead(
    String operation,
    String? id,
  ) async {
    final gate = holdNextAttributeRead;
    holdNextAttributeRead = null;
    if (gate != null) {
      _awaitingAttributeRead = true;
      try {
        await _gate(gate);
      } finally {
        _awaitingAttributeRead = false;
      }
    }
    if (id == null || status.items[id] == null || health[id] == null) {
      return _reject('$operation without a known item');
    }
    final current = status.items[id]!;
    final state = health[id]!;
    return jsonResponse({
      'data': {
        'workItem': {
          'id': current.id,
          'iid': current.iid,
          'project': _ref(current.project),
          'namespace': _ref(current.namespace),
          'widgets': switch (state.widgets) {
            HealthWidgetMode.unavailable => null,
            HealthWidgetMode.absent => const <Object?>[],
            HealthWidgetMode.present => [
              {
                'type': 'HEALTH_STATUS',
                'healthStatus': state.value?.graphValue,
                'rolledUpHealthStatus': state.rolledUp,
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
        },
      },
    });
  }

  Future<ResponseBody> _healthMutation(
    String operation,
    Map<String, Object?> variables,
    String? id,
  ) async {
    final input = variables['input'];
    if (variables.length != 1 ||
        input is! Map ||
        id == null ||
        input.length != 2 ||
        input['healthStatusWidget'] is! Map) {
      return _reject('$operation input');
    }
    final widgetMap = (input['healthStatusWidget'] as Map)
        .cast<String, Object?>();
    healthMutationRequests++;
    mutationInputs.add(
      Map<String, Object?>.unmodifiable({
        'id': id,
        'healthStatusWidget': Map<String, Object?>.unmodifiable(widgetMap),
      }),
    );
    _confirmPending.add(id);

    final apply = holdBeforeApply;
    holdBeforeApply = null;
    if (apply != null) {
      _awaitingApply = true;
      try {
        await _gate(apply);
      } finally {
        _awaitingApply = false;
      }
    }

    final current = status.items[id]!;
    final state = health[id]!;
    final preUpdatedAt = current.updatedAt;
    _preWrite[id] = (
      value: state.value,
      rolledUp: state.rolledUp,
      updatedAt: preUpdatedAt,
      lockVersion: current.lockVersion,
    );
    final rawHealth = widgetMap['healthStatus'];
    final desired = rawHealth == null
        ? null
        : WorkItemHealthEditValue.parse(rawHealth as String);
    state.value = desired;
    if (!unchangedUpdatedAtOnAck) {
      current.updatedAt = current.updatedAt.add(
        Duration(seconds: status.advanceSeconds),
      );
      current.lockVersion++;
    }
    healthApplied++;

    final ack = holdAck;
    holdAck = null;
    if (ack != null) {
      _awaitingAck = true;
      try {
        await _gate(ack);
      } finally {
        _awaitingAck = false;
      }
    }
    if (loseNextAck) {
      loseNextAck = false;
      _confirmPending.remove(id);
      return jsonResponse({'message': 'lost acknowledgement'}, status: 503);
    }
    _ackServed.add(id);
    return jsonResponse({
      'data': {
        'workItemUpdate': {
          'errors': <String>[],
          'workItem': {
            'id': current.id,
            'updatedAt': statusFixtureTimestamp(
              unchangedUpdatedAtOnAck ? preUpdatedAt : current.updatedAt,
            ),
            'widgets': [
              {
                'type': 'HEALTH_STATUS',
                'healthStatus': state.value?.graphValue,
              },
            ],
          },
        },
      },
    });
  }

  Future<ResponseBody> _detail(RequestOptions request, String? id) async {
    final body = await dates.adapter.respond(request);
    if (body.statusCode != 200 || id == null) return body;
    final pre = lagNextDetail ? _preWrite[id] : null;
    if (pre == null) {
      _preWrite.remove(id);
    }
    final state = health[id];
    final unavailable = state?.widgets == HealthWidgetMode.unavailable;
    final absent = state?.widgets == HealthWidgetMode.absent;
    if (pre != null || unavailable || (absent && dates.healthWidget)) {
      if (pre != null) lagNextDetail = false;
      final decoded = jsonDecode(await utf8.decodeStream(body.stream));
      final node = _detailNode(decoded);
      if (node != null) {
        if (pre != null) {
          node['updatedAt'] = statusFixtureTimestamp(pre.updatedAt);
          if (node.containsKey('lockVersion')) {
            node['lockVersion'] = pre.lockVersion;
          }
        }
        if (unavailable) {
          node['widgets'] = null;
        } else if (absent) {
          final widgets = node['widgets'];
          if (widgets is List) {
            widgets.removeWhere(
              (w) => w is Map && w['type'] == 'HEALTH_STATUS',
            );
          }
        }
      }
      return jsonResponse(decoded);
    }
    return body;
  }

  Map<String, Object?>? _detailNode(Object? decoded) {
    if (decoded is! Map) return null;
    final data = decoded['data'];
    if (data is! Map) return null;
    final project = data['project'];
    if (project is Map) {
      final nodes = (project['workItems'] as Map?)?['nodes'];
      if (nodes is List && nodes.length == 1 && nodes.single is Map) {
        return (nodes.single as Map).cast<String, Object?>();
      }
      return null;
    }
    final namespace = data['namespace'];
    if (namespace is Map && namespace['workItem'] is Map) {
      return (namespace['workItem'] as Map).cast<String, Object?>();
    }
    return null;
  }

  Map<String, Object?> _healthNode(
    StatusFixtureItem current,
    HealthParentItem state, {
    required bool includePermissions,
    _PreHealthWrite? pre,
  }) => {
    'id': current.id,
    'iid': '${current.iid}',
    'title': current.title,
    'state': current.state,
    'createdAt': statusFixtureTimestamp(current.createdAt),
    'updatedAt': statusFixtureTimestamp(pre?.updatedAt ?? current.updatedAt),
    'project': _ref(current.project),
    'namespace': _ref(current.namespace),
    'workItemType': {'id': current.typeId, 'name': current.typeName},
    if (includePermissions)
      'userPermissions': {
        'readWorkItem': state.readWorkItem,
        'adminWorkItem': state.adminWorkItem,
      },
    'widgets': switch (state.widgets) {
      HealthWidgetMode.unavailable => null,
      HealthWidgetMode.absent => const <Object?>[],
      HealthWidgetMode.present => [
        {
          'type': 'HEALTH_STATUS',
          'healthStatus': (pre != null ? pre.value : state.value)?.graphValue,
          'rolledUpHealthStatus': pre?.rolledUp ?? state.rolledUp,
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

  Map<String, Object?>? _ref(GraphResourceRef? ref) =>
      ref == null ? null : {'id': ref.id, 'fullPath': ref.fullPath};
}
