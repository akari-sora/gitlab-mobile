import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_activity_models.dart';
import 'package:gitlab_mobile/core/work_item_dates_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_health_edit_models.dart';
import 'package:gitlab_mobile/core/work_item_state_models.dart';
import 'package:gitlab_mobile/core/work_item_status_models.dart';

import '../support/fake_adapter.dart';
import '../support/work_item_assignee_fixture.dart';
import '../support/work_item_dates_fixture.dart';
import '../support/work_item_health_fixture.dart';
import '../support/work_item_status_fixture.dart';

final _revision = DateTime.utc(2026, 10, 3, 10);

final _summary = WorkItemGraphSummary(
  id: 'gid://gitlab/WorkItem/31',
  iid: 31,
  title: 'Hook test item',
  state: 'OPEN',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: _revision,
  project: const GraphResourceRef(
    id: 'gid://gitlab/Project/42',
    fullPath: 'team/example-42',
  ),
  namespace: const GraphResourceRef(
    id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
    fullPath: 'team/example-42',
  ),
  type: const WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/9',
    name: 'Task',
  ),
);

final _project = Project.fromJson(projectJson(42));
const _discussionId = 'gid://gitlab/Discussion/hook-test';
const _replyId = 'gid://gitlab/IndividualNoteDiscussion/hook-test';
const _noteId = 'gid://gitlab/Note/401';
const _authorId = 'gid://gitlab/User/9';

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((failure) => failure.kind, 'kind', kind);

bool _isMutationRequest(Object request) {
  final data = (request as dynamic).data;
  return data is Map &&
      data['query'] is String &&
      (data['query'] as String).startsWith('mutation ');
}

String _source(String name) => File('lib/core/$name').readAsStringSync();

String _method(String source, String name) {
  final declaration = RegExp(
    'Future<[^\\n]+>\\s+${RegExp.escape(name)}\\(',
  ).firstMatch(source);
  expect(declaration, isNotNull, reason: 'missing $name');
  final nameAt = declaration!.start;
  final next = source.indexOf('\n  Future<', declaration.end);
  return source.substring(nameAt, next < 0 ? source.length : next);
}

void _expectPairedGuard(String body) {
  final beforeParameter = body.indexOf(
    'Future<void> Function()? beforeMutation',
  );
  final gateParameter = body.indexOf('bool Function()? mayStart');
  final guard = body.indexOf('(beforeMutation == null) != (mayStart == null)');
  expect(beforeParameter, isNonNegative);
  expect(gateParameter, greaterThan(beforeParameter));
  expect(guard, greaterThan(gateParameter));
  final firstAwait = body.indexOf('await ');
  if (firstAwait >= 0) expect(guard, lessThan(firstAwait));
}

void _expectSendOrder(String body, {bool reportsMutation = false}) {
  final hook = body.indexOf('await beforeMutation');
  final gate = body.indexOf('mayStart', hook + 1);
  final send = body.indexOf('_send(', gate);
  expect(hook, isNonNegative);
  expect(gate, greaterThan(hook));
  expect(send, greaterThan(gate));
  if (reportsMutation) {
    final report = body.indexOf('onMutationSent', hook);
    expect(report, greaterThan(hook));
    expect(report, lessThan(gate));
  }
  final hookEnd = body.indexOf(';', hook) + 1;
  expect(body.substring(hookEnd, gate), isNot(contains('await ')));
  final beforeSend = body.substring(gate, send);
  expect(
    beforeSend.replaceFirst(RegExp(r'await\s*$'), ''),
    isNot(contains('await ')),
    reason: 'the synchronous gate must lead directly to the mutation send',
  );
}

Map<String, Object?> _stateRead() => {
  'data': {
    'workItem': {
      'id': _summary.id,
      'iid': '${_summary.iid}',
      'state': 'OPEN',
      'updatedAt': _revision.toIso8601String(),
      'project': {
        'id': _summary.project!.id,
        'fullPath': _summary.project!.fullPath,
      },
      'namespace': {
        'id': _summary.namespace!.id,
        'fullPath': _summary.namespace!.fullPath,
      },
      'workItemType': {'id': _summary.type.id},
      'userPermissions': {'updateWorkItem': true},
    },
  },
};

Map<String, Object?> _incidentRead() => {
  'data': {
    'project': {
      'id': 'gid://gitlab/Project/42',
      'issues': {
        'nodes': [
          {
            'id': 'gid://gitlab/Issue/123',
            'iid': '7',
            'projectId': 42,
            'state': 'opened',
            'severity': 'HIGH',
            'escalationStatus': 'TRIGGERED',
            'updatedAt': '2026-10-02T10:00:00Z',
          },
        ],
        'pageInfo': {'hasNextPage': false},
      },
    },
  },
};

Map<String, Object?> _unsupportedControls() => {
  'errors': [
    {
      'message': "Field 'discussions' doesn't accept argument 'filter'",
      'extensions': {
        'code': 'argumentNotAccepted',
        'name': 'discussions',
        'typeName': 'Field',
        'argumentName': 'filter',
      },
    },
  ],
};

Map<String, Object?> _emptyActivity() => {
  'data': {
    'workItem': {
      'id': _summary.id,
      'iid': '${_summary.iid}',
      'project': {
        'id': _summary.project!.id,
        'fullPath': _summary.project!.fullPath,
      },
      'namespace': {
        'id': _summary.namespace!.id,
        'fullPath': _summary.namespace!.fullPath,
      },
      'widgets': <Object?>[],
    },
  },
};

Map<String, Object?> _activityNote() => {
  'id': _noteId,
  'system': false,
  'systemNoteIconName': null,
  'body': 'Anchor',
  'createdAt': '2026-10-01T01:02:03Z',
  'updatedAt': '2026-10-01T01:03:04Z',
  'author': {'id': _authorId, 'name': 'Hook Author', 'username': 'hook-author'},
};

Map<String, Object?> _activityPage() => {
  'data': {
    'workItem': {
      'id': _summary.id,
      'iid': '${_summary.iid}',
      'project': {
        'id': _summary.project!.id,
        'fullPath': _summary.project!.fullPath,
      },
      'namespace': {
        'id': _summary.namespace!.id,
        'fullPath': _summary.namespace!.fullPath,
      },
      'widgets': [
        {
          'type': 'NOTES',
          'discussionLocked': false,
          'discussions': {
            'nodes': [
              {
                'id': _discussionId,
                'replyId': _replyId,
                'createdAt': '2026-10-01T01:00:00Z',
                'notes': {
                  'nodes': [_activityNote()],
                  'pageInfo': {'hasNextPage': false, 'endCursor': null},
                },
              },
            ],
            'pageInfo': {'hasNextPage': false, 'endCursor': null},
          },
        },
      ],
    },
  },
};

Map<String, Object?> _activityWriteAccess({bool anchor = false}) => {
  'data': {
    'currentUser': {'id': _authorId},
    'workItem': {
      'id': _summary.id,
      'iid': '${_summary.iid}',
      'project': {
        'id': _summary.project!.id,
        'fullPath': _summary.project!.fullPath,
      },
      'namespace': {
        'id': _summary.namespace!.id,
        'fullPath': _summary.namespace!.fullPath,
      },
      'userPermissions': {'createNote': true},
      'widgets': [
        {'type': 'NOTES', 'discussionLocked': false},
      ],
    },
    if (anchor)
      'anchor': {
        ..._activityNote(),
        'internal': false,
        'noteableType': 'Issue',
        'noteableId': 31,
        'project': {
          'id': _summary.project!.id,
          'fullPath': _summary.project!.fullPath,
        },
        'discussion': {
          'id': _discussionId,
          'replyId': _replyId,
          'createdAt': '2026-10-01T01:00:00Z',
        },
      },
  },
};

Map<String, Object?> _notificationRead() => {
  'data': {
    'currentUser': {'id': 'gid://gitlab/User/7'},
    'workItem': {
      'id': _summary.id,
      'iid': '${_summary.iid}',
      'project': {
        'id': _summary.project!.id,
        'fullPath': _summary.project!.fullPath,
      },
      'namespace': {
        'id': _summary.namespace!.id,
        'fullPath': _summary.namespace!.fullPath,
      },
      'workItemType': {'id': _summary.type.id},
      'widgets': [
        {'type': 'NOTIFICATIONS', 'subscribed': false},
      ],
    },
  },
};

Map<String, Object?> _deleteAccess() => {
  'data': {
    'currentUser': {'id': 'gid://gitlab/User/7'},
    'workItem': {
      'id': _summary.id,
      'iid': '${_summary.iid}',
      'project': {
        'id': _summary.project!.id,
        'fullPath': _summary.project!.fullPath,
      },
      'namespace': {
        'id': _summary.namespace!.id,
        'fullPath': _summary.namespace!.fullPath,
      },
    },
    'note': {
      ..._activityNote(),
      'internal': false,
      'noteableType': 'Issue',
      'noteableId': 31,
      'project': {
        'id': _summary.project!.id,
        'fullPath': _summary.project!.fullPath,
      },
      'discussion': {'id': _discussionId, 'createdAt': '2026-10-01T01:00:00Z'},
      'userPermissions': {'adminNote': true},
    },
  },
};

WorkItemGraphDetail _assigneeDetail(WorkItemAssigneeFixture fixture) =>
    WorkItemGraphDetail(
      summary: WorkItemGraphSummary(
        id: WorkItemAssigneeFixture.workItemId,
        iid: 31,
        title: '合成工作項目',
        state: 'OPEN',
        createdAt: DateTime.parse('2026-09-01T01:02:03Z'),
        updatedAt: DateTime.parse(fixture.updatedAt),
        project: GraphResourceRef(
          id: 'gid://gitlab/Project/42',
          fullPath: fixture.project.path,
        ),
        namespace: const GraphResourceRef(
          id: WorkItemAssigneeFixture.namespaceId,
          fullPath: 'team/example-42',
        ),
        type: const WorkItemGraphType(
          id: WorkItemAssigneeFixture.typeId,
          name: 'Task',
        ),
      ),
      description: null,
      widgetsAvailable: true,
      widgetTypes: const {'ASSIGNEES'},
      descriptionWidget: null,
      assignees: null,
      labels: null,
      hierarchy: null,
      dates: null,
    );

void main() {
  test('all S0b write surfaces expose an early paired hook contract', () {
    final methods = <String, List<String>>{
      'work_item_state_api.dart': ['updateWorkItemState'],
      'work_item_status_api.dart': ['updateWorkItemStatus'],
      'work_item_dates_api.dart': ['updateWorkItemDates'],
      'work_item_health_api.dart': ['updateWorkItemHealthStatus'],
      'work_item_milestone_api.dart': ['updateWorkItemMilestone'],
      'work_item_weight_api.dart': ['updateWorkItemWeight'],
      'work_item_activity_api.dart': [
        'createWorkItemActivityComment',
        'createWorkItemActivityReply',
      ],
      'work_item_note_delete_api.dart': ['deleteWorkItemActivityNote'],
      'work_item_notifications_api.dart': ['setWorkItemNotifications'],
      'incident_api.dart': ['setIncidentStatus'],
      'work_item_assignee_api.dart': ['updateWorkItemAssignees'],
      'work_item_note_reactions_api.dart': ['setWorkItemActivityNoteReaction'],
      'todo_snooze_api.dart': ['snoozeTodo', 'unsnoozeTodo'],
    };

    for (final entry in methods.entries) {
      final source = _source(entry.key);
      for (final name in entry.value) {
        _expectPairedGuard(_method(source, name));
      }
    }
  });

  test('hooks and sync gates remain adjacent to every owned send boundary', () {
    final cases = <(String, String, bool)>[
      ('work_item_state_api.dart', 'updateWorkItemState', false),
      ('work_item_status_api.dart', 'updateWorkItemStatus', true),
      ('work_item_dates_api.dart', 'updateWorkItemDates', true),
      ('work_item_health_api.dart', 'updateWorkItemHealthStatus', true),
      ('work_item_milestone_api.dart', 'updateWorkItemMilestone', true),
      ('work_item_weight_api.dart', 'updateWorkItemWeight', true),
      ('work_item_note_delete_api.dart', 'deleteWorkItemActivityNote', false),
      ('work_item_notifications_api.dart', 'setWorkItemNotifications', false),
      ('incident_api.dart', 'setIncidentStatus', false),
    ];
    for (final (file, method, reports) in cases) {
      _expectSendOrder(
        _method(_source(file), method),
        reportsMutation: reports,
      );
    }

    final activity = _source('work_item_activity_api.dart');
    final shared = _method(activity, '_createWorkItemActivityNote');
    _expectSendOrder(shared);
    for (final method in [
      'createWorkItemActivityComment',
      'createWorkItemActivityReply',
    ]) {
      final body = _method(activity, method);
      expect(body, contains('beforeMutation: beforeMutation'));
      expect(body, contains('mayStart: mayStart'));
    }
  });

  test('assignee, reaction, and snooze gates precede their sends', () {
    for (final (file, method) in <(String, String)>[
      ('work_item_assignee_api.dart', 'updateWorkItemAssignees'),
      ('work_item_note_reactions_api.dart', 'setWorkItemActivityNoteReaction'),
      ('todo_snooze_api.dart', 'snoozeTodo'),
      ('todo_snooze_api.dart', 'unsnoozeTodo'),
    ]) {
      _expectSendOrder(_method(_source(file), method));
    }
  });

  test('pair mismatch is rejected before validation or network I/O', () async {
    final adapter = FakeAdapter((_) => fail('must not perform I/O'));
    final api = testApi(adapter);
    addTearDown(api.close);
    Future<void> hook() async {}

    await expectLater(
      api.updateWorkItemState(
        _summary,
        WorkItemStateEvent.close,
        expectedUpdatedAt: _revision,
        beforeMutation: hook,
      ),
      throwsArgumentError,
    );
    await expectLater(
      api.setIncidentStatus(_project, 7, 'INVALID', beforeMutation: hook),
      throwsArgumentError,
    );
    await expectLater(
      api.snoozeTodo(-1, DateTime.utc(2000), beforeMutation: hook),
      throwsA(_failure(FailureKind.validation)),
    );
    await expectLater(
      api.unsnoozeTodo(-1, beforeMutation: hook),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(adapter.requests, isEmpty);
  });

  test('awaited hook then false sync gate cancels before state send', () async {
    final adapter = FakeAdapter((_) => jsonResponse(_stateRead()));
    final api = testApi(adapter);
    addTearDown(api.close);
    final release = Completer<void>();
    final events = <String>[];

    final operation = api.updateWorkItemState(
      _summary,
      WorkItemStateEvent.close,
      expectedUpdatedAt: _revision,
      beforeMutation: () async {
        events.add('hook');
        await release.future;
        events.add('hook-complete');
      },
      mayStart: () {
        events.add('gate');
        return false;
      },
    );
    while (events.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(events, ['hook']);
    expect(adapter.requests, hasLength(1));
    release.complete();
    await expectLater(operation, throwsA(_failure(FailureKind.cancelled)));
    expect(events, ['hook', 'hook-complete', 'gate']);
    expect(adapter.requests.where(_isMutationRequest), isEmpty);
  });

  test(
    'status awaits hook, reports START, then checks the sync gate',
    () async {
      final fixture = WorkItemStatusFixture();
      addTearDown(fixture.closeAll);
      final access = await fixture.api.workItemStatus(
        fixture.detail(group: false),
        expectedUserId: fixture.actorUserId,
        generation: fixture.sessionGeneration,
      );
      final target = access.target!;
      final entered = Completer<void>();
      final release = Completer<void>();
      final events = <String>[];

      final operation = fixture.api.updateWorkItemStatus(
        target,
        candidateId: WorkItemStatusFixture.statusDoing,
        onMutationSent: (started) {
          events.add('start');
          started(Object());
        },
        beforeMutation: () async {
          events.add('hook');
          entered.complete();
          await release.future;
          events.add('hook-complete');
        },
        mayStart: () {
          events.add('gate');
          return false;
        },
      );
      await entered.future;
      expect(events, ['hook']);
      expect(fixture.mutations, 0);
      release.complete();
      await expectLater(
        operation,
        throwsA(
          isA<WorkItemStatusWriteFailure>()
              .having(
                (failure) => failure.failure.kind,
                'kind',
                FailureKind.cancelled,
              )
              .having((failure) => failure.mutationSent, 'mutationSent', false),
        ),
      );
      expect(events, ['hook', 'hook-complete', 'start', 'gate']);
      expect(fixture.mutations, 0);
    },
  );

  test(
    'status pair mismatch preserves target and noop skips all hooks',
    () async {
      final fixture = WorkItemStatusFixture();
      addTearDown(fixture.closeAll);
      final target = (await fixture.api.workItemStatus(
        fixture.detail(group: false),
        expectedUserId: fixture.actorUserId,
        generation: fixture.sessionGeneration,
      )).target!;
      Future<void> unexpectedHook() async => fail('noop must skip hook');

      await expectLater(
        fixture.api.updateWorkItemStatus(
          target,
          candidateId: WorkItemStatusFixture.statusTodo,
          onMutationSent: (_) => fail('mismatch must not report START'),
          beforeMutation: unexpectedHook,
        ),
        throwsArgumentError,
      );
      expect(target.consumed, isFalse);
      final result = await fixture.api.updateWorkItemStatus(
        target,
        candidateId: WorkItemStatusFixture.statusTodo,
        onMutationSent: (_) => fail('noop must not report START'),
        beforeMutation: unexpectedHook,
        mayStart: () => fail('noop must skip gate'),
      );
      expect(result.status, WorkItemStatusSaveStatus.noop);
      expect(result.mutationSent, isFalse);
      expect(fixture.mutations, 0);
    },
  );

  test('dates and health report START between awaited hook and gate', () async {
    final dates = WorkItemDatesFixture();
    addTearDown(dates.api.close);
    final datesTarget = (await dates.api.workItemDates(
      dates.detail,
      expectedUserId: 7,
      generation: 3,
      isCurrent: () => true,
    )).target!;
    final datesEvents = <String>[];
    await expectLater(
      dates.api.updateWorkItemDates(
        datesTarget,
        mode: WorkItemDatesMode.manual,
        startDate: '2026-10-20',
        dueDate: '2026-10-21',
        onMutationSent: () => datesEvents.add('start'),
        isCurrent: () => true,
        beforeMutation: () async => datesEvents.add('hook'),
        mayStart: () {
          datesEvents.add('gate');
          return false;
        },
      ),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(datesEvents, ['hook', 'start', 'gate']);
    expect(dates.mutations, 0);

    final health = WorkItemHealthFixture();
    final healthApi = testApi(health.adapter);
    addTearDown(healthApi.close);
    final healthTarget = (await healthApi.workItemHealthEdit(
      healthDetail(),
      expectedUserId: 7,
      generation: 3,
      isCurrent: () => true,
    )).target!;
    final healthEvents = <String>[];
    await expectLater(
      healthApi.updateWorkItemHealthStatus(
        healthTarget,
        desired: WorkItemHealthEditValue.atRisk,
        generation: 3,
        isCurrent: () => true,
        onMutationSent: () => healthEvents.add('start'),
        beforeMutation: () async => healthEvents.add('hook'),
        mayStart: () {
          healthEvents.add('gate');
          return false;
        },
      ),
      throwsA(
        isA<WorkItemHealthEditFailure>()
            .having(
              (failure) => failure.failure.kind,
              'kind',
              FailureKind.cancelled,
            )
            .having((failure) => failure.mutationSent, 'mutationSent', false),
      ),
    );
    expect(healthEvents, ['hook', 'start', 'gate']);
    expect(health.mutationsReceived, 0);
  });

  test('assignee reports START between awaited hook and gate', () async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    final target = (await fixture.api.workItemAssignees(
      _assigneeDetail(fixture),
      expectedUserId: 7,
      maxPages: 1,
    )).target!;
    final events = <String>[];
    await expectLater(
      fixture.api.updateWorkItemAssignees(
        target,
        assigneeIds: [fixture.userId(1)],
        onMutationSent: () => events.add('start'),
        beforeMutation: () async => events.add('hook'),
        mayStart: () {
          events.add('gate');
          return false;
        },
      ),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(events, ['hook', 'start', 'gate']);
    expect(fixture.mutations, 0);
  });

  test('weight and milestone report START between hook and gate', () async {
    final weightFixture = WorkItemStatusFixture()..serveParent = true;
    weightFixture.item(group: false)
      ..weightWidget = true
      ..weight = 3;
    addTearDown(weightFixture.closeAll);
    final weightTarget = (await weightFixture.api.workItemWeight(
      weightFixture.detail(group: false),
      expectedUserId: 7,
    )).target!;
    final weightEvents = <String>[];
    await expectLater(
      weightFixture.api.updateWorkItemWeight(
        weightTarget,
        weight: 4,
        onMutationSent: () => weightEvents.add('start'),
        beforeMutation: () async => weightEvents.add('hook'),
        mayStart: () {
          weightEvents.add('gate');
          return false;
        },
      ),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(weightEvents, ['hook', 'start', 'gate']);
    expect(weightFixture.count('MobileSetWorkItemWeight'), 0);

    final milestoneFixture = WorkItemStatusFixture()..serveParent = true;
    milestoneFixture.item(group: false)
      ..milestoneWidget = true
      ..milestoneId = 'gid://gitlab/Milestone/5';
    addTearDown(milestoneFixture.closeAll);
    final milestoneTarget = (await milestoneFixture.api.workItemMilestone(
      milestoneFixture.detail(group: false),
      expectedUserId: 7,
    )).target!;
    final choices = await milestoneFixture.api.workItemMilestoneChoices(
      milestoneTarget,
    );
    final selection = choices.items
        .firstWhere(
          (choice) => choice.milestone.id == 'gid://gitlab/Milestone/6',
        )
        .selection;
    final milestoneEvents = <String>[];
    await expectLater(
      milestoneFixture.api.updateWorkItemMilestone(
        milestoneTarget,
        selection: selection,
        onMutationSent: () => milestoneEvents.add('start'),
        beforeMutation: () async => milestoneEvents.add('hook'),
        mayStart: () {
          milestoneEvents.add('gate');
          return false;
        },
      ),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(milestoneEvents, ['hook', 'start', 'gate']);
    expect(milestoneFixture.count('MobileSetWorkItemMilestone'), 0);
  });

  test('incident and both snooze writes cancel before transport', () async {
    final incidentAdapter = FakeAdapter((_) => jsonResponse(_incidentRead()));
    final incidentApi = testApi(incidentAdapter);
    addTearDown(incidentApi.close);
    final events = <String>[];

    await expectLater(
      incidentApi.setIncidentStatus(
        _project,
        7,
        'ACKNOWLEDGED',
        beforeMutation: () async => events.add('incident-hook'),
        mayStart: () {
          events.add('incident-gate');
          return false;
        },
      ),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(events, ['incident-hook', 'incident-gate']);
    expect(incidentAdapter.requests.where(_isMutationRequest), isEmpty);

    final snoozeAdapter = FakeAdapter((_) => fail('must not send'));
    final snoozeApi = testApi(snoozeAdapter);
    addTearDown(snoozeApi.close);
    for (final operation in <Future<void> Function()>[
      () async {
        await snoozeApi.snoozeTodo(
          1,
          DateTime.now().toUtc().add(const Duration(days: 1)),
          beforeMutation: () async => events.add('snooze-hook'),
          mayStart: () {
            events.add('snooze-gate');
            return false;
          },
        );
      },
      () => snoozeApi.unsnoozeTodo(
        1,
        beforeMutation: () async => events.add('unsnooze-hook'),
        mayStart: () {
          events.add('unsnooze-gate');
          return false;
        },
      ),
    ]) {
      await expectLater(operation(), throwsA(_failure(FailureKind.cancelled)));
    }
    expect(events, containsAllInOrder(['snooze-hook', 'snooze-gate']));
    expect(events, containsAllInOrder(['unsnooze-hook', 'unsnooze-gate']));
    expect(snoozeAdapter.requests, isEmpty);
  });

  test(
    'activity comment and reply share the hook gate before transport',
    () async {
      var commentReads = 0;
      final commentAdapter = FakeAdapter((request) {
        expect(_isMutationRequest(request), isFalse);
        commentReads++;
        return jsonResponse(_activityWriteAccess());
      });
      final commentApi = testApi(commentAdapter);
      addTearDown(commentApi.close);
      final commentTarget = (await commentApi.workItemActivityWriteAccess(
        _summary,
      )).commentTarget!;
      final commentEvents = <String>[];
      await expectLater(
        commentApi.createWorkItemActivityComment(
          commentTarget,
          'Hooked comment',
          beforeMutation: () async => commentEvents.add('hook'),
          mayStart: () {
            commentEvents.add('gate');
            return false;
          },
        ),
        throwsA(_failure(FailureKind.cancelled)),
      );
      expect(commentEvents, ['hook', 'gate']);
      expect(commentReads, 2);
      expect(commentAdapter.requests.where(_isMutationRequest), isEmpty);

      var replyReads = 0;
      final replyAdapter = FakeAdapter((request) {
        expect(_isMutationRequest(request), isFalse);
        replyReads++;
        return jsonResponse(
          replyReads == 1
              ? _activityPage()
              : _activityWriteAccess(anchor: true),
        );
      });
      final replyApi = testApi(replyAdapter);
      addTearDown(replyApi.close);
      final page = await replyApi.workItemActivity(_summary);
      final replyTarget = page.replyTargetsByDiscussion[_discussionId]!;
      final replyEvents = <String>[];
      await expectLater(
        replyApi.createWorkItemActivityReply(
          replyTarget,
          'Hooked reply',
          beforeMutation: () async => replyEvents.add('hook'),
          mayStart: () {
            replyEvents.add('gate');
            return false;
          },
        ),
        throwsA(_failure(FailureKind.cancelled)),
      );
      expect(replyEvents, ['hook', 'gate']);
      expect(replyReads, 2);
      expect(replyAdapter.requests.where(_isMutationRequest), isEmpty);
    },
  );

  test('notification and delete hooks gate mutation transport', () async {
    final notificationAdapter = FakeAdapter(
      (_) => jsonResponse(_notificationRead()),
    );
    final notificationApi = testApi(notificationAdapter);
    addTearDown(notificationApi.close);
    final notificationTarget = (await notificationApi.workItemNotifications(
      _summary,
      expectedUserId: 7,
    )).target!;
    final notificationEvents = <String>[];
    await expectLater(
      notificationApi.setWorkItemNotifications(
        notificationTarget,
        subscribed: true,
        beforeMutation: () async => notificationEvents.add('hook'),
        mayStart: () {
          notificationEvents.add('gate');
          return false;
        },
      ),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(notificationEvents, ['hook', 'gate']);
    expect(notificationAdapter.requests.where(_isMutationRequest), isEmpty);

    final note = WorkItemActivityNote(
      id: _noteId,
      system: false,
      systemNoteIconName: null,
      body: 'Anchor',
      createdAt: DateTime.parse('2026-10-01T01:02:03Z'),
      updatedAt: DateTime.parse('2026-10-01T01:03:04Z'),
      author: const WorkItemActivityAuthor(
        id: _authorId,
        name: 'Hook Author',
        username: 'hook-author',
      ),
    );
    final discussion = WorkItemActivityDiscussion(
      id: _discussionId,
      replyId: _replyId,
      createdAt: DateTime.parse('2026-10-01T01:00:00Z'),
      notes: WorkItemActivityConnection(
        availability: WorkItemActivityConnectionAvailability.present,
        items: [note],
      ),
    );
    final deleteAdapter = FakeAdapter((_) => jsonResponse(_deleteAccess()));
    final deleteApi = testApi(deleteAdapter);
    addTearDown(deleteApi.close);
    final deleteTarget = (await deleteApi.workItemActivityDeleteAccess(
      _summary,
      discussion,
      note,
    )).target!;
    final deleteEvents = <String>[];
    await expectLater(
      deleteApi.deleteWorkItemActivityNote(
        deleteTarget,
        beforeMutation: () async => deleteEvents.add('hook'),
        mayStart: () {
          deleteEvents.add('gate');
          return false;
        },
      ),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(deleteEvents, ['hook', 'gate']);
    expect(deleteAdapter.requests.where(_isMutationRequest), isEmpty);
  });

  test('AI activity read refuses control fallback after one request', () async {
    final adapter = FakeAdapter((_) => jsonResponse(_unsupportedControls()));
    final api = testApi(adapter);
    addTearDown(api.close);

    await expectLater(
      api.workItemActivity(
        _summary,
        filter: WorkItemActivityFilter.comments,
        order: WorkItemActivityOrder.newestFirst,
        allowLegacyFallback: false,
      ),
      throwsA(_failure(FailureKind.unsupported)),
    );
    expect(adapter.requests, hasLength(1));
  });

  test(
    'AI activity read rejects cache-known unsupported without I/O',
    () async {
      var calls = 0;
      final adapter = FakeAdapter((_) {
        calls++;
        return jsonResponse(
          calls == 1 ? _unsupportedControls() : _emptyActivity(),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final legacy = await api.workItemActivity(_summary);
      expect(legacy.controlsSupported, isFalse);
      expect(calls, 2);
      await expectLater(
        api.workItemActivity(_summary, allowLegacyFallback: false),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(calls, 2);
    },
  );
}
