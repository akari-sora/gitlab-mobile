import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'fake_adapter.dart';
import 'work_item_status_fixture.dart';

typedef TaggedResponder =
    Future<ResponseBody> Function(String tag, RequestOptions request);

/// A [FakeAdapter] whose requests carry the tag of the client that sent them,
/// so two clients talking to one synthetic server stay distinguishable.
class TaggedFakeAdapter extends FakeAdapter {
  TaggedFakeAdapter(this.tag, TaggedResponder responder)
    : super((request) => responder(tag, request));

  final String tag;
}

/// One request as the synthetic server saw it.
final class DatesParentRequest {
  const DatesParentRequest({
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

/// Server-side START_AND_DUE_DATE state for one work item.
final class DatesParentItem {
  DatesParentItem({
    this.startDate,
    this.dueDate,
    this.isFixed = true,
    this.rollUp = false,
    this.ceFixed = false,
  });

  String? startDate;
  String? dueDate;
  bool isFixed;
  bool rollUp;

  /// The probe answers with the precise CE schema errors.
  bool ceFixed;
  bool setWorkItemMetadata = true;
  String? startSourceWorkItemId;
  String? dueSourceMilestoneId;
}

typedef _PreWrite = ({
  String? startDate,
  String? dueDate,
  bool rollUp,
  DateTime updatedAt,
  int lockVersion,
});

/// The parent-page server for the Dates integration: Dates base/probe reads
/// and the Dates mutation are served here from [dates]; every other request
/// goes to the wrapped [status] fixture with `serveParent` set. Detail reads
/// gain the START_AND_DUE_DATE widget built from [dates].
///
/// Only widgets, the navigator and these ledgers are observed; nothing here
/// reaches into a page's private state.
class WorkItemDatesParentFixture {
  WorkItemDatesParentFixture({WorkItemStatusFixture? status})
    : status = status ?? (WorkItemStatusFixture()..serveParent = true) {
    dates[WorkItemStatusFixture.projectItemId] = DatesParentItem(
      startDate: '2026-10-10',
      dueDate: '2026-10-20',
    );
    dates[WorkItemStatusFixture.groupItemId] = DatesParentItem(
      startDate: '2026-11-01',
      dueDate: '2026-11-30',
    );
  }

  static const baseOp = 'MobileWorkItemDatesBase';
  static const probeOp = 'MobileWorkItemDatesProbe';
  static const eeMutationOp = 'MobileSetWorkItemDatesEe';
  static const ceMutationOp = 'MobileSetWorkItemDatesCe';
  static const projectDetailOp = 'MobileProjectWorkItem';
  static const namespaceDetailOp = 'MobileNamespaceWorkItem';
  static const itemX = WorkItemStatusFixture.projectItemId;
  static const itemY = WorkItemStatusFixture.groupItemId;
  static const inheritedStart = '2026-09-01';
  static const inheritedDue = '2026-12-31';

  final WorkItemStatusFixture status;
  late final TaggedFakeAdapter adapter = TaggedFakeAdapter('primary', _respond);
  final dates = <String, DatesParentItem>{};
  final ledger = <DatesParentRequest>[];
  final mutationInputs = <Map<String, Object?>>[];
  final _clients = <GitLabApi>[];
  final _unhandled = <String>[];

  Account get account => status.account;

  /// One-shot: the next Dates base read that is not a post-ACK readback.
  Completer<void>? holdNextAccessRead;

  /// While true, every Dates probe for an item without a pending readback is
  /// parked until released by nonce. Arm it only after the editors that
  /// should not be parked have finished their access reads.
  bool armFinalFence = false;

  /// One-shot: held after the mutation arrives and before it is applied; the
  /// server item (dates and `updatedAt`) is unchanged while held.
  Completer<void>? holdBeforeApply;

  /// One-shot: held after the mutation is applied and before the ACK.
  Completer<void>? holdAck;

  /// Applies the next mutation, then answers HTTP 503 instead of the ACK.
  bool loseNextAck = false;

  /// One-shot: the next post-ACK readback base read.
  Completer<void>? holdNextConfirmRead;

  /// One-shot: the next detail read of an item written here serves the whole
  /// pre-write tuple together: dates widget values and node `updatedAt`.
  bool lagNextDetail = false;

  /// Detail reads also carry a bare HEALTH_STATUS widget.
  bool healthWidget = false;

  int datesMutationRequests = 0;
  int datesApplied = 0;

  var _nonce = 0;
  var _awaitingApply = false;
  var _awaitingAck = false;
  var _awaitingConfirmRead = false;
  final _consumed = <Completer<void>>[];
  final _parkedFence = <int, Completer<void>>{};
  final _confirmPending = <String>{};
  final _ackServed = <String>{};
  final _preWrite = <String, _PreWrite>{};

  bool get awaitingApply => _awaitingApply;
  bool get awaitingAck => _awaitingAck;
  bool get awaitingConfirmRead => _awaitingConfirmRead;
  int get awaitingFinalFenceReads => _parkedFence.length;

  /// Parked fence probes in arrival order.
  List<int> get parkedFenceNonces => List.unmodifiable(_parkedFence.keys);

  List<String> get unhandled => [..._unhandled, ...status.unhandled];

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

  /// Completes every armed, consumed or parked gate here and in [status].
  void releaseHolds() {
    for (final gate in [
      holdNextAccessRead,
      holdBeforeApply,
      holdAck,
      holdNextConfirmRead,
      ..._consumed,
      ..._parkedFence.values,
    ]) {
      if (gate != null && !gate.isCompleted) gate.complete();
    }
    _consumed.clear();
    _parkedFence.clear();
    armFinalFence = false;
    status.releaseHolds();
  }

  void closeAll() {
    for (final client in _clients) {
      client.close();
    }
    status.closeAll();
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
      DatesParentRequest(
        nonce: nonce,
        clientTag: tag,
        operation: operation,
        variables: Map<String, Object?>.unmodifiable(variables),
        item: item,
      ),
    );
    switch (operation) {
      case baseOp:
      case probeOp:
        return _datesRead(nonce, operation, item);
      case eeMutationOp:
      case ceMutationOp:
        return _datesMutation(operation, variables, item);
      case projectDetailOp:
      case namespaceDetailOp:
        return _detail(request, item);
    }
    return await status.adapter.respond(request);
  }

  String? _resolve(String operation, Map<String, Object?> variables) {
    final id = variables['id'];
    if (id is String && dates.containsKey(id)) return id;
    final input = variables['input'];
    if (input is Map && input['id'] is String) {
      final inputId = input['id'] as String;
      if (dates.containsKey(inputId)) return inputId;
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
        {'message': 'synthetic dates fixture rejected $reason'},
      ],
    }, status: 400);
  }

  Future<ResponseBody> _datesRead(
    int nonce,
    String operation,
    String? id,
  ) async {
    if (id == null || status.items[id] == null) {
      return _reject('$operation without a known item');
    }
    final readback = _ackServed.contains(id);
    if (operation == baseOp) {
      if (readback) {
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
      } else {
        final gate = holdNextAccessRead;
        holdNextAccessRead = null;
        await _gate(gate);
      }
    } else if (readback) {
      _ackServed.remove(id);
      _confirmPending.remove(id);
    } else if (armFinalFence && !_confirmPending.contains(id)) {
      final parked = Completer<void>();
      _parkedFence[nonce] = parked;
      await parked.future;
    }
    final current = status.items[id]!;
    final state = dates[id]!;
    if (operation == probeOp && state.ceFixed) {
      return jsonResponse({'errors': _ceErrors});
    }
    return jsonResponse({
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/${status.actorUserId}'},
        'workItem': _datesNode(
          current,
          state,
          ee: operation == probeOp,
          permissions: true,
        ),
      },
    });
  }

  Future<ResponseBody> _datesMutation(
    String operation,
    Map<String, Object?> variables,
    String? id,
  ) async {
    final input = variables['input'];
    if (variables.length != 1 ||
        input is! Map ||
        id == null ||
        input.length != 2 ||
        input['startAndDueDateWidget'] is! Map) {
      return _reject('$operation input');
    }
    final widget = (input['startAndDueDateWidget'] as Map)
        .cast<String, Object?>();
    datesMutationRequests++;
    mutationInputs.add(
      Map<String, Object?>.unmodifiable({
        'id': id,
        'startAndDueDateWidget': Map<String, Object?>.unmodifiable(widget),
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
    final state = dates[id]!;
    _preWrite[id] = (
      startDate: state.startDate,
      dueDate: state.dueDate,
      rollUp: state.rollUp,
      updatedAt: current.updatedAt,
      lockVersion: current.lockVersion,
    );
    if (widget['isFixed'] == false) {
      state
        ..isFixed = false
        ..startDate = inheritedStart
        ..dueDate = inheritedDue
        ..startSourceWorkItemId = 'gid://gitlab/WorkItem/700'
        ..dueSourceMilestoneId = 'gid://gitlab/Milestone/800';
    } else {
      state
        ..isFixed = true
        ..startDate = widget['startDate'] as String?
        ..dueDate = widget['dueDate'] as String?
        ..startSourceWorkItemId = null
        ..dueSourceMilestoneId = null;
    }
    current.updatedAt = current.updatedAt.add(
      Duration(seconds: status.advanceSeconds),
    );
    current.lockVersion++;
    datesApplied++;

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
          'workItem': _datesNode(
            current,
            state,
            ee: operation == eeMutationOp,
            permissions: false,
          ),
        },
      },
    });
  }

  Future<ResponseBody> _detail(RequestOptions request, String? id) async {
    final body = await status.adapter.respond(request);
    if (body.statusCode != 200 || id == null) return body;
    final decoded = jsonDecode(await utf8.decodeStream(body.stream));
    final node = _detailNode(decoded);
    final state = dates[id];
    if (node != null && state != null) {
      final pre = lagNextDetail ? _preWrite[id] : null;
      if (pre != null) {
        lagNextDetail = false;
        node['updatedAt'] = statusFixtureTimestamp(pre.updatedAt);
        if (node.containsKey('lockVersion')) {
          node['lockVersion'] = pre.lockVersion;
        }
      }
      final widgets = node['widgets'];
      if (widgets is List) {
        widgets.add({
          'type': 'START_AND_DUE_DATE',
          'startDate': pre == null ? state.startDate : pre.startDate,
          'dueDate': pre == null ? state.dueDate : pre.dueDate,
          'rollUp': pre == null ? state.rollUp : pre.rollUp,
        });
        if (healthWidget) widgets.add({'type': 'HEALTH_STATUS'});
      }
    }
    return jsonResponse(decoded);
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

  Map<String, Object?> _datesNode(
    StatusFixtureItem current,
    DatesParentItem state, {
    required bool ee,
    required bool permissions,
  }) => {
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
        {'type': 'START_AND_DUE_DATE'},
      ],
    },
    if (permissions)
      'userPermissions': {
        'readWorkItem': true,
        'setWorkItemMetadata': state.setWorkItemMetadata,
      },
    'widgets': [
      {
        'type': 'START_AND_DUE_DATE',
        'startDate': state.startDate,
        'dueDate': state.dueDate,
        'rollUp': state.rollUp,
        if (ee) 'isFixed': state.isFixed,
        if (ee)
          'startDateSourcingWorkItem': state.startSourceWorkItemId == null
              ? null
              : {'id': state.startSourceWorkItemId},
        if (ee) 'dueDateSourcingWorkItem': null,
        if (ee) 'startDateSourcingMilestone': null,
        if (ee)
          'dueDateSourcingMilestone': state.dueSourceMilestoneId == null
              ? null
              : {'id': state.dueSourceMilestoneId},
      },
    ],
  };

  Map<String, Object?>? _ref(GraphResourceRef? ref) =>
      ref == null ? null : {'id': ref.id, 'fullPath': ref.fullPath};
}

final _ceErrors = <Object?>[
  for (final field in [
    'isFixed',
    'startDateSourcingWorkItem',
    'dueDateSourcingWorkItem',
    'startDateSourcingMilestone',
    'dueDateSourcingMilestone',
  ])
    {
      'message': 'Field $field does not exist',
      'extensions': {
        'code': 'undefinedField',
        'typeName': 'WorkItemWidgetStartAndDueDate',
        'fieldName': field,
      },
    },
];
