part of 'gitlab_api.dart';

ApiFailure get _datesReadForbidden => ApiFailure(
  FailureKind.forbidden,
  title: '無法讀取工作項目日期',
  detail: '目前帳號沒有讀取這個工作項目的權限。',
);
ApiFailure get _datesInvalidResponse => ApiFailure(
  FailureKind.invalidResponse,
  title: '無法確認工作項目日期',
  detail: 'GitLab 回傳的日期、身分或欄位形狀不完整。',
);
ApiFailure get _datesSpent => ApiFailure(
  FailureKind.writeUncertain,
  title: '無法再次送出日期',
  detail: '這次日期編輯已經使用過。請重新開啟後再試。',
);
ApiFailure get _datesUncertain => ApiFailure(
  FailureKind.writeUncertain,
  title: '尚未確認日期是否已更新',
  detail: '請重新整理後再查看，不要重複送出同一次變更。',
);
const _datesCancelled = ApiFailure(FailureKind.cancelled);

final _datesBaseQuery =
    r'''
query MobileWorkItemDatesBase($id: WorkItemID!) {
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
      widgetDefinitions { type }
    }
    userPermissions { readWorkItem setWorkItemMetadata }
    widgets(onlyTypes: [START_AND_DUE_DATE]) {
      type
      ... on WorkItemWidgetStartAndDueDate {
        startDate
        dueDate
        rollUp
      }
    }
  }
}
'''
        .trim();

final _datesProbeQuery =
    r'''
query MobileWorkItemDatesProbe($id: WorkItemID!) {
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
      widgetDefinitions { type }
    }
    userPermissions { readWorkItem setWorkItemMetadata }
    widgets(onlyTypes: [START_AND_DUE_DATE]) {
      type
      ... on WorkItemWidgetStartAndDueDate {
        startDate
        dueDate
        rollUp
        isFixed
        startDateSourcingWorkItem { id }
        dueDateSourcingWorkItem { id }
        startDateSourcingMilestone { id }
        dueDateSourcingMilestone { id }
      }
    }
  }
}
'''
        .trim();

final _datesCeMutation =
    r'''
mutation MobileSetWorkItemDatesCe($input: WorkItemUpdateInput!) {
  workItemUpdate(input: $input) {
    errors
    workItem {
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
        widgetDefinitions { type }
      }
      widgets(onlyTypes: [START_AND_DUE_DATE]) {
        type
        ... on WorkItemWidgetStartAndDueDate {
          startDate
          dueDate
          rollUp
        }
      }
    }
  }
}
'''
        .trim();

final _datesEeMutation =
    r'''
mutation MobileSetWorkItemDatesEe($input: WorkItemUpdateInput!) {
  workItemUpdate(input: $input) {
    errors
    workItem {
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
        widgetDefinitions { type }
      }
      widgets(onlyTypes: [START_AND_DUE_DATE]) {
        type
        ... on WorkItemWidgetStartAndDueDate {
          startDate
          dueDate
          rollUp
          isFixed
          startDateSourcingWorkItem { id }
          dueDateSourcingWorkItem { id }
          startDateSourcingMilestone { id }
          dueDateSourcingMilestone { id }
        }
      }
    }
  }
}
'''
        .trim();

enum _DatesReadRole { access, fence, confirm }

/// A fresh dates read. [target] is null when this exact snapshot is read-only.
final class WorkItemDatesAccess {
  const WorkItemDatesAccess._({
    required this.snapshot,
    required this.canWrite,
    required this.target,
  });

  final WorkItemDatesSnapshot snapshot;
  final bool canWrite;
  final WorkItemDatesTarget? target;
}

/// Single-use dates capability owned by one account client and one fresh read.
final class WorkItemDatesTarget {
  WorkItemDatesTarget._({
    required GitLabApi owner,
    required this.snapshot,
    required this.edition,
    required bool Function()? isCurrent,
  }) : _owner = owner,
       _openingIsCurrent = isCurrent;

  final GitLabApi _owner;
  final bool Function()? _openingIsCurrent;
  final WorkItemDatesSnapshot snapshot;
  final WorkItemDatesEdition edition;
  bool _consumed = false;

  WorkItemGraphSummary get summary => snapshot.summary;
  DateTime get preflightUpdatedAt => snapshot.updatedAt;
  String? get preflightStartDate => snapshot.startDate;
  String? get preflightDueDate => snapshot.dueDate;
  WorkItemDatesMode get preflightMode => snapshot.mode;
  String get actorId => snapshot.actorId;
  int get expectedUserId => snapshot.expectedUserId;
  int get generation => snapshot.generation;
  bool get consumed => _consumed;
}

extension WorkItemDatesApi on GitLabApi {
  Future<WorkItemDatesAccess> workItemDates(
    WorkItemGraphDetail detail, {
    required int expectedUserId,
    required int generation,
    bool Function()? isCurrent,
  }) async {
    _validateDatesExpected(detail.summary, expectedUserId, generation);
    final snapshot = await _readWorkItemDates(
      detail.summary,
      expectedUserId: expectedUserId,
      generation: generation,
      isCurrent: isCurrent,
      role: _DatesReadRole.access,
      expectedEdition: null,
    );
    final writable =
        snapshot.readWorkItem &&
        snapshot.setWorkItemMetadata &&
        snapshot.widgetPresent &&
        snapshot.edition != null &&
        snapshot.mode != WorkItemDatesMode.unknown;
    return WorkItemDatesAccess._(
      snapshot: snapshot,
      canWrite: writable,
      target: writable
          ? WorkItemDatesTarget._(
              owner: this,
              snapshot: snapshot,
              edition: snapshot.edition!,
              isCurrent: isCurrent,
            )
          : null,
    );
  }

  /// Burns [target] synchronously, sends at most one mutation, and never replays.
  Future<WorkItemDatesWriteResult> updateWorkItemDates(
    WorkItemDatesTarget target, {
    required WorkItemDatesMode mode,
    required String? startDate,
    required String? dueDate,
    required void Function() onMutationSent,
    bool Function()? isCurrent,
  }) async {
    if (target._consumed) throw _datesSpent;
    target._consumed = true;
    _requireActivityOwner(target._owner);
    _requireDatesCurrent(target._openingIsCurrent);
    _requireDatesCurrent(isCurrent);
    if (_notificationActorNumber(target.actorId) != target.expectedUserId ||
        target.expectedUserId <= 0 ||
        target.generation < 0) {
      throw _datesCancelled;
    }

    final validation = _validateDatesWrite(
      target.edition,
      mode,
      startDate,
      dueDate,
    );
    if (validation != null) return validation;
    if (_datesRequestIsNoop(target.snapshot, mode, startDate, dueDate)) {
      return WorkItemDatesWriteResult(
        outcome: WorkItemDatesWriteOutcome.applied,
        snapshot: target.snapshot,
        mutationSent: false,
      );
    }

    final WorkItemDatesSnapshot before;
    try {
      before = await _readWorkItemDates(
        target.summary,
        expectedUserId: target.expectedUserId,
        generation: target.generation,
        isCurrent: () =>
            _datesCurrent(target._openingIsCurrent) && _datesCurrent(isCurrent),
        role: _DatesReadRole.fence,
        expectedEdition: target.edition,
      );
    } on ApiFailure catch (failure) {
      if (failure.kind == FailureKind.cancelled) rethrow;
      throw _datesUncertain;
    } on Object {
      throw _datesUncertain;
    }
    if (before.actorId != target.actorId) throw _datesCancelled;
    if (!_sameDatesStateFence(before, target.snapshot)) {
      throw _datesUncertain;
    }
    if (!before.readWorkItem || !before.setWorkItemMetadata) {
      return WorkItemDatesWriteResult(
        outcome: WorkItemDatesWriteOutcome.notApplied,
        snapshot: before,
        mutationSent: false,
        message: '目前帳號不能變更日期',
      );
    }
    _requireDatesCurrent(target._openingIsCurrent);
    _requireDatesCurrent(isCurrent);
    if (isClosed) throw _datesCancelled;

    final widget = _datesMutationWidget(
      target.edition,
      mode,
      startDate,
      dueDate,
    );
    final input = <String, Object?>{
      'id': target.summary.id,
      'startAndDueDateWidget': widget,
    };
    onMutationSent();
    final ({Uint8List bytes, Headers headers, int statusCode}) response;
    try {
      response = await _send(
        instance.graphQL,
        method: 'POST',
        graphMutation: true,
        data: {
          'query': target.edition == WorkItemDatesEdition.ee
              ? _datesEeMutation
              : _datesCeMutation,
          'variables': {'input': input},
        },
      );
    } on Object {
      return _datesUncertainResult;
    }

    final _ParsedDatesNode acknowledged;
    try {
      acknowledged = _parseDatesAcknowledgement(
        response.bytes,
        expected: target.summary,
        edition: target.edition,
      );
    } on Object {
      return _datesUncertainResult;
    }

    final unchangedAck = _sameDatesNodeAndSnapshot(acknowledged, before);
    final requestedAck = _datesNodeMatchesRequest(
      acknowledged,
      mode,
      startDate,
      dueDate,
    );
    if (acknowledged.summary.updatedAt.isBefore(before.updatedAt) ||
        (!unchangedAck && !requestedAck)) {
      return _datesUncertainResult;
    }

    final WorkItemDatesSnapshot readback;
    try {
      readback = await _readWorkItemDates(
        target.summary,
        expectedUserId: target.expectedUserId,
        generation: target.generation,
        isCurrent: () =>
            _datesCurrent(target._openingIsCurrent) && _datesCurrent(isCurrent),
        role: _DatesReadRole.confirm,
        expectedEdition: target.edition,
      );
    } on Object {
      return _datesUncertainResult;
    }
    if (readback.actorId != target.actorId ||
        !readback.readWorkItem ||
        !readback.setWorkItemMetadata ||
        !_sameDatesNodeAndSnapshot(acknowledged, readback)) {
      return _datesUncertainResult;
    }
    if (unchangedAck) {
      if (!_sameDatesFence(readback, before)) {
        return _datesUncertainResult;
      }
      return WorkItemDatesWriteResult(
        outcome: WorkItemDatesWriteOutcome.notApplied,
        snapshot: readback,
        mutationSent: true,
        message: '伺服器未套用變更，請確認權限或重新整理',
      );
    }
    if (!_datesSnapshotMatchesRequest(readback, mode, startDate, dueDate)) {
      return _datesUncertainResult;
    }
    return WorkItemDatesWriteResult(
      outcome: WorkItemDatesWriteOutcome.applied,
      snapshot: readback,
      mutationSent: true,
    );
  }

  Future<WorkItemDatesSnapshot> _readWorkItemDates(
    WorkItemGraphSummary expected, {
    required int expectedUserId,
    required int generation,
    required bool Function()? isCurrent,
    required _DatesReadRole role,
    required WorkItemDatesEdition? expectedEdition,
  }) async {
    _requireDatesCurrent(isCurrent);
    if (isClosed) throw _datesCancelled;
    final baseResponse = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      headers: const {'Cache-Control': 'no-store'},
      data: {
        'query': _datesBaseQuery,
        'variables': {'id': expected.id},
      },
    );
    _requireDatesCurrent(isCurrent);
    if (isClosed) throw _datesCancelled;
    final baseEnvelope = _datesEnvelope(baseResponse.bytes);
    if (baseEnvelope.errors.isNotEmpty) {
      throw role == _DatesReadRole.access
          ? _datesInvalidResponse
          : _datesUncertain;
    }
    final base = _parseDatesReadNode(
      baseEnvelope.data,
      expected: expected,
      expectedUserId: expectedUserId,
      edition: null,
      role: role,
    );
    if (!base.readWorkItem) {
      if (role == _DatesReadRole.access) throw _datesReadForbidden;
      if (role == _DatesReadRole.confirm) throw _datesUncertain;
    }
    if (!base.widgetPresent) {
      return _datesSnapshot(
        base,
        edition: null,
        mode: WorkItemDatesMode.unknown,
        expectedUserId: expectedUserId,
        generation: generation,
      );
    }

    _requireDatesCurrent(isCurrent);
    final probeResponse = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      headers: const {'Cache-Control': 'no-store'},
      data: {
        'query': _datesProbeQuery,
        'variables': {'id': expected.id},
      },
    );
    _requireDatesCurrent(isCurrent);
    if (isClosed) throw _datesCancelled;
    final probeEnvelope = _datesEnvelope(probeResponse.bytes);
    if (probeEnvelope.errors.isNotEmpty) {
      final ce = _preciseCeDatesErrors(probeEnvelope.errors) && !base.rollUp;
      if (ce) {
        if (expectedEdition != null &&
            expectedEdition != WorkItemDatesEdition.ceFixed) {
          throw _datesUncertain;
        }
        return _datesSnapshot(
          base,
          edition: WorkItemDatesEdition.ceFixed,
          mode: WorkItemDatesMode.manual,
          expectedUserId: expectedUserId,
          generation: generation,
        );
      }
      if (role != _DatesReadRole.access || expectedEdition != null) {
        throw _datesUncertain;
      }
      return _datesSnapshot(
        base,
        edition: null,
        mode: WorkItemDatesMode.unknown,
        expectedUserId: expectedUserId,
        generation: generation,
      );
    }

    final probe = _parseDatesReadNode(
      probeEnvelope.data,
      expected: expected,
      expectedUserId: expectedUserId,
      edition: WorkItemDatesEdition.ee,
      role: role,
    );
    if (!_sameDatesReadEnvelope(base, probe)) {
      throw role == _DatesReadRole.access
          ? _datesInvalidResponse
          : _datesUncertain;
    }
    if (expectedEdition != null && expectedEdition != WorkItemDatesEdition.ee) {
      throw _datesUncertain;
    }
    final mode = probe.isFixed!
        ? WorkItemDatesMode.manual
        : WorkItemDatesMode.inherited;
    return _datesSnapshot(
      probe,
      edition: WorkItemDatesEdition.ee,
      mode: mode,
      expectedUserId: expectedUserId,
      generation: generation,
    );
  }
}

WorkItemDatesWriteResult get _datesUncertainResult => WorkItemDatesWriteResult(
  outcome: WorkItemDatesWriteOutcome.writeUncertain,
  mutationSent: true,
  message: '連線在寫入時中斷。尚未確認是否更新，請重新整理後再查看。',
);

typedef _DatesEnvelope = ({Json? data, List<Object?> errors});

typedef _ParsedDatesNode = ({
  WorkItemGraphSummary summary,
  String? actorId,
  bool readWorkItem,
  bool setWorkItemMetadata,
  bool widgetPresent,
  bool widgetDefined,
  String? startDate,
  String? dueDate,
  bool rollUp,
  bool? isFixed,
  String? startDateSourcingWorkItemId,
  String? dueDateSourcingWorkItemId,
  String? startDateSourcingMilestoneId,
  String? dueDateSourcingMilestoneId,
});

WorkItemDatesWriteResult? _validateDatesWrite(
  WorkItemDatesEdition edition,
  WorkItemDatesMode mode,
  String? startDate,
  String? dueDate,
) {
  if (mode == WorkItemDatesMode.unknown ||
      (edition == WorkItemDatesEdition.ceFixed &&
          mode != WorkItemDatesMode.manual)) {
    return const WorkItemDatesWriteResult(
      outcome: WorkItemDatesWriteOutcome.notApplied,
      mutationSent: false,
      message: '日期模式不明',
    );
  }
  if (mode == WorkItemDatesMode.inherited) return null;
  if (!_validDatesInput(startDate) || !_validDatesInput(dueDate)) {
    return const WorkItemDatesWriteResult(
      outcome: WorkItemDatesWriteOutcome.notApplied,
      mutationSent: false,
      message: '請輸入完整日期，例如 2026-10-04',
    );
  }
  if (startDate != null &&
      dueDate != null &&
      startDate.compareTo(dueDate) > 0) {
    return const WorkItemDatesWriteResult(
      outcome: WorkItemDatesWriteOutcome.notApplied,
      mutationSent: false,
      message: '開始日期必須早於或等於到期日期',
    );
  }
  return null;
}

bool _datesRequestIsNoop(
  WorkItemDatesSnapshot opening,
  WorkItemDatesMode mode,
  String? startDate,
  String? dueDate,
) {
  if (opening.mode != mode) return false;
  if (mode == WorkItemDatesMode.inherited) return true;
  return opening.startDate == startDate && opening.dueDate == dueDate;
}

Map<String, Object?> _datesMutationWidget(
  WorkItemDatesEdition edition,
  WorkItemDatesMode mode,
  String? startDate,
  String? dueDate,
) {
  if (mode == WorkItemDatesMode.inherited) {
    return <String, Object?>{'isFixed': false};
  }
  return <String, Object?>{
    if (edition == WorkItemDatesEdition.ee) 'isFixed': true,
    'startDate': startDate,
    'dueDate': dueDate,
  };
}

void _validateDatesExpected(
  WorkItemGraphSummary expected,
  int expectedUserId,
  int generation,
) {
  if (expectedUserId <= 0 ||
      generation < 0 ||
      !_isGraphIdType(expected.id, const {'WorkItem'}) ||
      expected.iid <= 0 ||
      !_isGraphIdType(expected.type.id, const {'WorkItems::Type'}) ||
      (expected.project == null && expected.namespace == null)) {
    throw const ApiFailure(FailureKind.validation);
  }
}

bool _validDatesInput(String? raw) {
  if (raw == null) return true;
  final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(raw);
  if (match == null) return false;
  final year = int.parse(match.group(1)!);
  if (year < 1000 || year > 9999) return false;
  final value = DateTime.tryParse('${raw}T00:00:00Z')?.toUtc();
  return value != null &&
      value.year == year &&
      value.toIso8601String().substring(0, 10) == raw;
}

String? _strictDatesScalar(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || !_validDatesInput(raw)) {
    throw const FormatException('Invalid dates scalar');
  }
  return raw;
}

void _requireDatesCurrent(bool Function()? isCurrent) {
  if (!_datesCurrent(isCurrent)) throw _datesCancelled;
}

bool _datesCurrent(bool Function()? isCurrent) => isCurrent?.call() ?? true;

_DatesEnvelope _datesEnvelope(Uint8List bytes) {
  try {
    final envelope = objectJson(jsonDecode(utf8.decode(bytes)));
    final rawErrors = envelope['errors'];
    if (rawErrors != null && rawErrors is! List) {
      throw const FormatException('Invalid GraphQL errors');
    }
    final errors = rawErrors is List
        ? List<Object?>.unmodifiable(rawErrors)
        : const <Object?>[];
    final rawData = envelope['data'];
    final data = rawData == null ? null : objectJson(rawData);
    if (errors.isEmpty && data == null) {
      throw const FormatException('Missing GraphQL data');
    }
    return (data: data, errors: errors);
  } on FormatException {
    throw _datesInvalidResponse;
  } on ApiFailure {
    rethrow;
  } on Object {
    throw _datesInvalidResponse;
  }
}

bool _preciseCeDatesErrors(List<Object?> errors) {
  const fields = {
    'isFixed',
    'startDateSourcingWorkItem',
    'dueDateSourcingWorkItem',
    'startDateSourcingMilestone',
    'dueDateSourcingMilestone',
  };
  if (errors.isEmpty) return false;
  final seen = <String>{};
  for (final raw in errors) {
    if (raw is! Map) return false;
    final error = objectJson(raw);
    final extensions = error['extensions'];
    if (extensions is! Map) return false;
    final details = objectJson(extensions);
    if (details['code'] != 'undefinedField' ||
        details['typeName'] != 'WorkItemWidgetStartAndDueDate') {
      return false;
    }
    final field = details['fieldName'];
    if (field is! String || !fields.contains(field) || !seen.add(field)) {
      return false;
    }
  }
  return seen.contains('isFixed');
}

_ParsedDatesNode _parseDatesReadNode(
  Json? data, {
  required WorkItemGraphSummary expected,
  required int expectedUserId,
  required WorkItemDatesEdition? edition,
  required _DatesReadRole role,
}) {
  if (data == null) throw _datesInvalidResponse;
  try {
    if (!data.containsKey('currentUser')) {
      throw const FormatException('Missing dates actor');
    }
    final actorId = _parseNotificationActor(data['currentUser']);
    if (actorId == null) {
      throw const ApiFailure(
        FailureKind.unauthenticated,
        title: '登入已失效',
        detail: '請重新連接目前帳號，再讀取工作項目日期。',
      );
    }
    if (_notificationActorNumber(actorId) != expectedUserId) {
      throw _datesCancelled;
    }
    if (data['workItem'] == null) {
      throw const ApiFailure(FailureKind.invisible);
    }
    return _parseDatesNode(
      data['workItem'],
      expected: expected,
      edition: edition,
      actorId: actorId,
      requirePermissions: true,
      role: role,
    );
  } on ApiFailure {
    rethrow;
  } on FormatException {
    throw role == _DatesReadRole.access
        ? _datesInvalidResponse
        : _datesUncertain;
  }
}

_ParsedDatesNode _parseDatesNode(
  Object? raw, {
  required WorkItemGraphSummary expected,
  required WorkItemDatesEdition? edition,
  required String? actorId,
  required bool requirePermissions,
  required _DatesReadRole role,
}) {
  final node = objectJson(raw);
  final summary = _parseWorkItemSummary(node);
  if (!_sameDatesIdentity(summary, expected)) {
    throw role == _DatesReadRole.access
        ? const FormatException('Wrong dates identity')
        : _datesUncertain;
  }

  var readWorkItem = true;
  var setWorkItemMetadata = true;
  if (requirePermissions) {
    final rawPermissions = node['userPermissions'];
    if (rawPermissions is! Map) {
      throw const FormatException('Missing dates permissions');
    }
    final permissions = objectJson(rawPermissions);
    final read = permissions['readWorkItem'];
    final setMetadata = permissions['setWorkItemMetadata'];
    if (read is! bool || setMetadata is! bool) {
      throw const FormatException('Invalid dates permissions');
    }
    readWorkItem = read;
    setWorkItemMetadata = setMetadata;
  }

  final type = objectJson(node['workItemType']);
  final definitions = type['widgetDefinitions'];
  if (definitions is! List || definitions.length > _workItemWidgetLimit) {
    throw const FormatException('Invalid dates widget definitions');
  }
  var widgetDefined = false;
  final seenDefinitions = <String>{};
  for (final rawDefinition in definitions) {
    final definition = objectJson(rawDefinition);
    final definitionType = _boundedRequiredText(definition, 'type', 128);
    if (!seenDefinitions.add(definitionType)) {
      throw const FormatException('Duplicate widget definition');
    }
    if (definitionType == 'START_AND_DUE_DATE') widgetDefined = true;
  }

  final rawWidgets = node['widgets'];
  if (rawWidgets == null) {
    return (
      summary: summary,
      actorId: actorId,
      readWorkItem: readWorkItem,
      setWorkItemMetadata: setWorkItemMetadata,
      widgetPresent: false,
      widgetDefined: widgetDefined,
      startDate: null,
      dueDate: null,
      rollUp: false,
      isFixed: null,
      startDateSourcingWorkItemId: null,
      dueDateSourcingWorkItemId: null,
      startDateSourcingMilestoneId: null,
      dueDateSourcingMilestoneId: null,
    );
  }
  if (rawWidgets is! List || rawWidgets.length > 1) {
    throw const FormatException('Invalid dates widgets');
  }
  if (rawWidgets.isEmpty) {
    return (
      summary: summary,
      actorId: actorId,
      readWorkItem: readWorkItem,
      setWorkItemMetadata: setWorkItemMetadata,
      widgetPresent: false,
      widgetDefined: widgetDefined,
      startDate: null,
      dueDate: null,
      rollUp: false,
      isFixed: null,
      startDateSourcingWorkItemId: null,
      dueDateSourcingWorkItemId: null,
      startDateSourcingMilestoneId: null,
      dueDateSourcingMilestoneId: null,
    );
  }
  if (!widgetDefined) {
    throw const FormatException('Dates widget missing definition');
  }
  final widget = objectJson(rawWidgets.single);
  if (widget['type'] != 'START_AND_DUE_DATE') {
    throw const FormatException('Unexpected dates widget');
  }
  if (!widget.containsKey('startDate') ||
      !widget.containsKey('dueDate') ||
      !widget.containsKey('rollUp')) {
    throw const FormatException('Missing dates scalar');
  }
  final rollUp = widget['rollUp'];
  if (rollUp is! bool) throw const FormatException('Invalid rollUp');
  final startDate = _strictDatesScalar(widget['startDate']);
  final dueDate = _strictDatesScalar(widget['dueDate']);
  if (startDate != null &&
      dueDate != null &&
      startDate.compareTo(dueDate) > 0) {
    throw const FormatException('Invalid dates order');
  }
  bool? isFixed;
  String? startWorkItem;
  String? dueWorkItem;
  String? startMilestone;
  String? dueMilestone;
  if (edition == WorkItemDatesEdition.ee) {
    if (!widget.containsKey('isFixed') ||
        !widget.containsKey('startDateSourcingWorkItem') ||
        !widget.containsKey('dueDateSourcingWorkItem') ||
        !widget.containsKey('startDateSourcingMilestone') ||
        !widget.containsKey('dueDateSourcingMilestone')) {
      throw const FormatException('Missing EE dates scalar');
    }
    final rawFixed = widget['isFixed'];
    if (rawFixed is! bool) throw const FormatException('Invalid isFixed');
    isFixed = rawFixed;
    startWorkItem = _datesSourceId(
      widget['startDateSourcingWorkItem'],
      'WorkItem',
    );
    dueWorkItem = _datesSourceId(widget['dueDateSourcingWorkItem'], 'WorkItem');
    startMilestone = _datesSourceId(
      widget['startDateSourcingMilestone'],
      'Milestone',
    );
    dueMilestone = _datesSourceId(
      widget['dueDateSourcingMilestone'],
      'Milestone',
    );
  }
  return (
    summary: summary,
    actorId: actorId,
    readWorkItem: readWorkItem,
    setWorkItemMetadata: setWorkItemMetadata,
    widgetPresent: true,
    widgetDefined: true,
    startDate: startDate,
    dueDate: dueDate,
    rollUp: rollUp,
    isFixed: isFixed,
    startDateSourcingWorkItemId: startWorkItem,
    dueDateSourcingWorkItemId: dueWorkItem,
    startDateSourcingMilestoneId: startMilestone,
    dueDateSourcingMilestoneId: dueMilestone,
  );
}

String? _datesSourceId(Object? raw, String type) {
  if (raw == null) return null;
  final id = requiredString(objectJson(raw), 'id');
  if (!_isGraphIdType(id, {type})) {
    throw const FormatException('Invalid dates source');
  }
  return id;
}

WorkItemDatesSnapshot _datesSnapshot(
  _ParsedDatesNode parsed, {
  required WorkItemDatesEdition? edition,
  required WorkItemDatesMode mode,
  required int expectedUserId,
  required int generation,
}) => WorkItemDatesSnapshot(
  summary: parsed.summary,
  updatedAt: parsed.summary.updatedAt,
  edition: edition,
  mode: mode,
  startDate: parsed.startDate,
  dueDate: parsed.dueDate,
  rollUp: parsed.rollUp,
  startDateSourcingWorkItemId: parsed.startDateSourcingWorkItemId,
  dueDateSourcingWorkItemId: parsed.dueDateSourcingWorkItemId,
  startDateSourcingMilestoneId: parsed.startDateSourcingMilestoneId,
  dueDateSourcingMilestoneId: parsed.dueDateSourcingMilestoneId,
  readWorkItem: parsed.readWorkItem,
  setWorkItemMetadata: parsed.setWorkItemMetadata,
  widgetPresent: parsed.widgetPresent,
  actorId: parsed.actorId!,
  expectedUserId: expectedUserId,
  generation: generation,
);

bool _sameDatesReadEnvelope(_ParsedDatesNode left, _ParsedDatesNode right) =>
    left.actorId == right.actorId &&
    _sameDatesIdentity(left.summary, right.summary) &&
    left.summary.updatedAt == right.summary.updatedAt &&
    left.readWorkItem == right.readWorkItem &&
    left.setWorkItemMetadata == right.setWorkItemMetadata &&
    left.widgetPresent == right.widgetPresent &&
    left.widgetDefined == right.widgetDefined &&
    left.startDate == right.startDate &&
    left.dueDate == right.dueDate &&
    left.rollUp == right.rollUp;

bool _sameDatesIdentity(
  WorkItemGraphSummary left,
  WorkItemGraphSummary right,
) =>
    left.id == right.id &&
    left.iid == right.iid &&
    left.state == right.state &&
    left.type.id == right.type.id &&
    left.type.name == right.type.name &&
    _sameAttributeRef(left.project, right.project) &&
    _sameAttributeRef(left.namespace, right.namespace);

bool _sameDatesFence(WorkItemDatesSnapshot left, WorkItemDatesSnapshot right) =>
    _sameDatesStateFence(left, right) &&
    left.readWorkItem == right.readWorkItem &&
    left.setWorkItemMetadata == right.setWorkItemMetadata;

bool _sameDatesStateFence(
  WorkItemDatesSnapshot left,
  WorkItemDatesSnapshot right,
) =>
    left.actorId == right.actorId &&
    left.expectedUserId == right.expectedUserId &&
    left.generation == right.generation &&
    _sameDatesIdentity(left.summary, right.summary) &&
    left.updatedAt == right.updatedAt &&
    left.edition == right.edition &&
    left.mode == right.mode &&
    left.startDate == right.startDate &&
    left.dueDate == right.dueDate &&
    left.rollUp == right.rollUp &&
    left.startDateSourcingWorkItemId == right.startDateSourcingWorkItemId &&
    left.dueDateSourcingWorkItemId == right.dueDateSourcingWorkItemId &&
    left.startDateSourcingMilestoneId == right.startDateSourcingMilestoneId &&
    left.dueDateSourcingMilestoneId == right.dueDateSourcingMilestoneId &&
    left.widgetPresent == right.widgetPresent;

_ParsedDatesNode _parseDatesAcknowledgement(
  Uint8List bytes, {
  required WorkItemGraphSummary expected,
  required WorkItemDatesEdition edition,
}) {
  try {
    final envelope = _datesEnvelope(bytes);
    if (envelope.errors.isNotEmpty || envelope.data == null) {
      throw const FormatException('Mutation GraphQL errors');
    }
    final payload = objectJson(envelope.data!['workItemUpdate']);
    final errors = payload['errors'];
    if (errors is! List ||
        errors.any((error) => error is! String || error.isEmpty) ||
        errors.isNotEmpty) {
      throw const FormatException('Mutation payload errors');
    }
    if (payload['workItem'] == null) {
      throw const FormatException('Missing mutation work item');
    }
    return _parseDatesNode(
      payload['workItem'],
      expected: expected,
      edition: edition,
      actorId: null,
      requirePermissions: false,
      role: _DatesReadRole.confirm,
    );
  } on ApiFailure {
    rethrow;
  } on FormatException {
    throw _datesUncertain;
  }
}

bool _sameDatesNodeAndSnapshot(
  _ParsedDatesNode node,
  WorkItemDatesSnapshot snapshot,
) =>
    _sameDatesIdentity(node.summary, snapshot.summary) &&
    node.summary.updatedAt == snapshot.updatedAt &&
    node.widgetPresent == snapshot.widgetPresent &&
    node.startDate == snapshot.startDate &&
    node.dueDate == snapshot.dueDate &&
    node.rollUp == snapshot.rollUp &&
    (snapshot.edition == WorkItemDatesEdition.ceFixed
        ? node.isFixed == null && snapshot.mode == WorkItemDatesMode.manual
        : node.isFixed ==
              (snapshot.mode == WorkItemDatesMode.manual
                  ? true
                  : snapshot.mode == WorkItemDatesMode.inherited
                  ? false
                  : null)) &&
    node.startDateSourcingWorkItemId == snapshot.startDateSourcingWorkItemId &&
    node.dueDateSourcingWorkItemId == snapshot.dueDateSourcingWorkItemId &&
    node.startDateSourcingMilestoneId ==
        snapshot.startDateSourcingMilestoneId &&
    node.dueDateSourcingMilestoneId == snapshot.dueDateSourcingMilestoneId;

bool _datesNodeMatchesRequest(
  _ParsedDatesNode node,
  WorkItemDatesMode mode,
  String? startDate,
  String? dueDate,
) {
  if (!node.widgetPresent) return false;
  if (mode == WorkItemDatesMode.inherited) return node.isFixed == false;
  return (node.isFixed == null || node.isFixed == true) &&
      node.startDate == startDate &&
      node.dueDate == dueDate;
}

bool _datesSnapshotMatchesRequest(
  WorkItemDatesSnapshot snapshot,
  WorkItemDatesMode mode,
  String? startDate,
  String? dueDate,
) {
  if (!snapshot.widgetPresent || snapshot.mode != mode) return false;
  if (mode == WorkItemDatesMode.inherited) return true;
  return snapshot.startDate == startDate && snapshot.dueDate == dueDate;
}
