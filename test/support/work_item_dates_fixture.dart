import 'dart:async';

import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_dates_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'fake_adapter.dart';

const _actorId = 'gid://gitlab/User/7';
const _workItemId = 'gid://gitlab/WorkItem/501';
const _typeId = 'gid://gitlab/WorkItems::Type/9';
const _projectId = 'gid://gitlab/Project/42';
const _namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/42';
const _path = 'studio/mobile-workspace';
const _createdAt = '2026-10-01T08:00:00Z';
const _initialUpdatedAt = '2026-10-04T08:00:00Z';

final class WorkItemDatesFixture {
  WorkItemDatesFixture({
    this.edition = WorkItemDatesEdition.ee,
    this.mode = WorkItemDatesMode.manual,
    this.startDate,
    this.dueDate,
    this.rollUp = false,
    this.readWorkItem = true,
    this.setWorkItemMetadata = true,
    this.widgetPresent = true,
    this.unknownProbe = false,
    this.notApplied = false,
    this.startSourceWorkItemId,
    this.dueSourceWorkItemId,
    this.startSourceMilestoneId,
    this.dueSourceMilestoneId,
  }) {
    adapter = FakeAdapter(_respond);
    api = testApi(adapter);
  }

  final WorkItemDatesEdition edition;
  WorkItemDatesMode mode;
  String? startDate;
  String? dueDate;
  bool rollUp;
  bool readWorkItem;
  bool setWorkItemMetadata;
  bool widgetPresent;
  bool unknownProbe;
  bool notApplied;
  String? startSourceWorkItemId;
  String? dueSourceWorkItemId;
  String? startSourceMilestoneId;
  String? dueSourceMilestoneId;

  late final FakeAdapter adapter;
  late final GitLabApi api;

  final account = Account(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    user: const GitLabUser(id: 7, username: 'ada', name: 'Ada'),
    token: 'synthetic-test-token',
  );

  String state = 'OPEN';
  String updatedAt = _initialUpdatedAt;
  int baseReads = 0;
  int probeReads = 0;
  int mutations = 0;
  int mutationApplies = 0;
  int mutationAcks = 0;
  final operations = <String>[];
  Map<String, Object?>? lastWidget;
  Completer<void>? holdMutationApply;
  Completer<void>? holdMutationAck;
  Completer<void>? holdNextBaseRead;
  int? mutationHttpError;
  bool malformedAck = false;

  WorkItemGraphDetail get detail => WorkItemGraphDetail(
    summary: WorkItemGraphSummary(
      id: _workItemId,
      iid: 100,
      title: '日期測試工作項目',
      state: state,
      createdAt: DateTime.parse(_createdAt).toUtc(),
      updatedAt: DateTime.parse(updatedAt).toUtc(),
      project: const GraphResourceRef(id: _projectId, fullPath: _path),
      namespace: const GraphResourceRef(id: _namespaceId, fullPath: _path),
      type: const WorkItemGraphType(id: _typeId, name: 'Task'),
    ),
    description: null,
    widgetsAvailable: true,
    widgetTypes: const {'START_AND_DUE_DATE'},
    descriptionWidget: null,
    assignees: null,
    labels: null,
    hierarchy: null,
    dates: null,
  );

  void releaseApply() {
    final held = holdMutationApply;
    holdMutationApply = null;
    held?.complete();
  }

  void releaseAck() {
    final held = holdMutationAck;
    holdMutationAck = null;
    held?.complete();
  }

  void releaseBaseRead() {
    final held = holdNextBaseRead;
    holdNextBaseRead = null;
    held?.complete();
  }

  void releaseAll() {
    releaseBaseRead();
    releaseApply();
    releaseAck();
  }

  Future<ResponseBody> _respond(RequestOptions request) async {
    final body = request.data;
    if (body is! Map) throw StateError('GraphQL body is not a map');
    final query = body['query'];
    if (query is! String) throw StateError('GraphQL query is missing');
    final variables = body['variables'];
    final vars = variables is Map ? variables : const <Object?, Object?>{};

    expectNoRedirect(request);
    if (query.startsWith('query MobileWorkItemDatesBase')) {
      operations.add('base');
      baseReads++;
      final held = holdNextBaseRead;
      if (held != null) await held.future;
      return jsonResponse(_readEnvelope(ee: false));
    }
    if (query.startsWith('query MobileWorkItemDatesProbe')) {
      operations.add('probe');
      probeReads++;
      if (unknownProbe) {
        return jsonResponse({
          'errors': [
            {
              'message': 'Synthetic incompatible schema',
              'extensions': {'code': 'INTERNAL'},
            },
          ],
        });
      }
      if (edition == WorkItemDatesEdition.ceFixed) {
        return jsonResponse({'errors': _ceErrors});
      }
      return jsonResponse(_readEnvelope(ee: true));
    }
    if (query.startsWith('mutation MobileSetWorkItemDates')) {
      operations.add('mutation');
      mutations++;
      final input = vars['input'];
      if (input is! Map) throw StateError('Mutation input is missing');
      final rawWidget = input['startAndDueDateWidget'];
      if (rawWidget is! Map) throw StateError('Dates widget input is missing');
      lastWidget = Map<String, Object?>.from(rawWidget);

      final apply = holdMutationApply;
      if (apply != null) await apply.future;
      if (!notApplied) _apply(lastWidget!);
      mutationApplies++;

      if (mutationHttpError != null) {
        return jsonResponse({
          'errors': [
            const {'message': 'Synthetic mutation transport failure'},
          ],
        }, status: mutationHttpError!);
      }
      final ack = holdMutationAck;
      if (ack != null) await ack.future;
      mutationAcks++;
      if (malformedAck) {
        return jsonResponse({
          'data': {
            'workItemUpdate': {'errors': <String>[], 'workItem': null},
          },
        });
      }
      return jsonResponse(_ackEnvelope());
    }
    operations.add('unexpected');
    throw StateError('Unexpected Dates operation');
  }

  void _apply(Map<String, Object?> widget) {
    if (widget['isFixed'] == false) {
      mode = WorkItemDatesMode.inherited;
      startDate = '2026-09-01';
      dueDate = '2026-12-31';
      startSourceWorkItemId = 'gid://gitlab/WorkItem/700';
      dueSourceWorkItemId = null;
      startSourceMilestoneId = null;
      dueSourceMilestoneId = 'gid://gitlab/Milestone/800';
      return;
    }
    mode = WorkItemDatesMode.manual;
    startDate = widget['startDate'] as String?;
    dueDate = widget['dueDate'] as String?;
    startSourceWorkItemId = null;
    dueSourceWorkItemId = null;
    startSourceMilestoneId = null;
    dueSourceMilestoneId = null;
  }

  Map<String, Object?> _readEnvelope({required bool ee}) => {
    'data': {
      'currentUser': {'id': _actorId},
      'workItem': _node(ee: ee, permissions: true),
    },
  };

  Map<String, Object?> _ackEnvelope() => {
    'data': {
      'workItemUpdate': {
        'errors': <String>[],
        'workItem': _node(
          ee: edition == WorkItemDatesEdition.ee,
          permissions: false,
        ),
      },
    },
  };

  Map<String, Object?> _node({required bool ee, required bool permissions}) {
    final widget = <String, Object?>{
      'type': 'START_AND_DUE_DATE',
      'startDate': startDate,
      'dueDate': dueDate,
      'rollUp': rollUp,
      if (ee) 'isFixed': mode == WorkItemDatesMode.manual,
      if (ee)
        'startDateSourcingWorkItem': startSourceWorkItemId == null
            ? null
            : {'id': startSourceWorkItemId},
      if (ee)
        'dueDateSourcingWorkItem': dueSourceWorkItemId == null
            ? null
            : {'id': dueSourceWorkItemId},
      if (ee)
        'startDateSourcingMilestone': startSourceMilestoneId == null
            ? null
            : {'id': startSourceMilestoneId},
      if (ee)
        'dueDateSourcingMilestone': dueSourceMilestoneId == null
            ? null
            : {'id': dueSourceMilestoneId},
    };
    return {
      'id': _workItemId,
      'iid': '100',
      'title': '日期測試工作項目',
      'state': state,
      'createdAt': _createdAt,
      'updatedAt': updatedAt,
      'project': {'id': _projectId, 'fullPath': _path},
      'namespace': {'id': _namespaceId, 'fullPath': _path},
      'workItemType': {
        'id': _typeId,
        'name': 'Task',
        'widgetDefinitions': [
          if (widgetPresent) {'type': 'START_AND_DUE_DATE'},
        ],
      },
      if (permissions)
        'userPermissions': {
          'readWorkItem': readWorkItem,
          'setWorkItemMetadata': setWorkItemMetadata,
        },
      'widgets': [if (widgetPresent) widget],
    };
  }
}

void expectNoRedirect(RequestOptions request) {
  if (request.followRedirects || request.maxRedirects != 0) {
    throw StateError('Dates fixture forbids redirects');
  }
  if (request.headers['Cache-Control'] != 'no-store') {
    throw StateError('Dates fixture requires no-store');
  }
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
