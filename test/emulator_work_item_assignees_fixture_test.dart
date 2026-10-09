import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';

import '../tool/emulator_ui.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

Future<WorkItemGraphDetail> _detail(EmulatorQaFixture fixture, bool group) =>
    group
    ? fixture.api.namespaceWorkItem(
        'qa/synthetic-group',
        41,
        expectedNamespaceId: 'gid://gitlab/Group/84',
      )
    : fixture.api.projectWorkItem(fixture.project, 31);

Future<WorkItemAssigneeAccess> _open(
  EmulatorQaFixture fixture,
  bool group,
) async {
  final detail = await _detail(fixture, group);
  return fixture.api.workItemAssignees(
    detail,
    expectedUserId: fixture.account.user.id,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'project and group complete 101 across two pages and preview 20',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      fixture.setWorkItemAssigneeCount(group: false, count: 101);
      fixture.setWorkItemAssigneeCount(group: true, count: 101);

      final projectDetail = await _detail(fixture, false);
      final groupDetail = await _detail(fixture, true);
      expect(projectDetail.assignees!.assignees!.items, hasLength(20));
      expect(projectDetail.assignees!.assignees!.isPartial, isTrue);
      expect(groupDetail.assignees!.assignees!.items, hasLength(20));

      final project = await fixture.api.workItemAssignees(
        projectDetail,
        expectedUserId: fixture.account.user.id,
      );
      final group = await fixture.api.workItemAssignees(
        groupDetail,
        expectedUserId: fixture.account.user.id,
      );
      expect(project.snapshot.users, hasLength(101));
      expect(group.snapshot.users, hasLength(101));
      expect(
        project.snapshot.users.map((user) => user.id).toSet(),
        hasLength(101),
      );
      expect(
        fixture.workItemAssigneeReads.where((event) => event['after'] != null),
        hasLength(2),
      );
      expect(fixture.workItemAssigneeEvents, isEmpty);
      expect(fixture.unhandled, isEmpty);
    },
  );

  test(
    'single cap rejects two ids and multiple replaces the whole set',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      fixture.workItemAssigneeMultiple[false] = false;
      final single = await _open(fixture, false);
      expect(single.snapshot.allowsMultiple, isFalse);
      await expectLater(
        fixture.api.updateWorkItemAssignees(
          single.target!,
          assigneeIds: const [
            'gid://gitlab/User/1001',
            'gid://gitlab/User/1003',
          ],
        ),
        throwsA(failure(FailureKind.validation)),
      );
      expect(fixture.workItemAssigneeEvents, isEmpty);

      fixture.workItemAssigneeMultiple[true] = true;
      final multiple = await _open(fixture, true);
      expect(multiple.snapshot.allowsMultiple, isTrue);
      const desired = ['gid://gitlab/User/3009', 'gid://gitlab/User/3004'];
      final updated = await fixture.api.updateWorkItemAssignees(
        multiple.target!,
        assigneeIds: desired,
      );
      expect(updated.users.map((user) => user.id), desired);
      expect(fixture.workItemAssigneeEvents, hasLength(1));
      final input =
          fixture.workItemAssigneeEvents.single['input']
              as Map<String, Object?>;
      expect(input.keys, ['id', 'assigneesWidget']);
      expect((input['assigneesWidget'] as Map)['assigneeIds'], desired);
    },
  );

  test(
    'clear logs an explicit empty array and an unchanged set sends nothing',
    () async {
      final logs = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => logs.add('$message');
      addTearDown(() => debugPrint = previous);
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final current = await _open(fixture, false);
      final same = await fixture.api.updateWorkItemAssignees(
        current.target!,
        assigneeIds: current.snapshot.assigneeIds,
      );
      expect(same.assigneeIds, current.snapshot.assigneeIds);
      expect(fixture.workItemAssigneeEvents, isEmpty);

      final again = await _open(fixture, false);
      final cleared = await fixture.api.updateWorkItemAssignees(
        again.target!,
        assigneeIds: const [],
      );
      expect(cleared.users, isEmpty);
      expect(fixture.workItemAssigneeEvents, hasLength(1));
      final line = logs.singleWhere(
        (entry) => entry.startsWith('[work_item_assignee_qa]'),
      );
      expect(line, contains('scope=project'));
      expect(line, contains('assigneeIds=[]'));
      expect(line, contains('accepted=true'));
      expect(line, contains('sequence=1'));
      expect(line, contains('assigneeIds: []'));
      expect(line, isNot(contains('PRIVATE-TOKEN')));
    },
  );

  test('candidate search is a capped array in the exact scope', () async {
    final fixture = EmulatorQaFixture();
    addTearDown(fixture.api.close);
    final project = await _open(fixture, false);
    final projectHits = await fixture.api.searchWorkItemAssigneeCandidates(
      project.target!,
      search: '',
    );
    expect(projectHits, hasLength(20));
    final exact = await fixture.api.searchWorkItemAssigneeCandidates(
      project.target!,
      search: '專案候選25',
    );
    expect(exact, hasLength(1));
    expect(exact.single.id, 'gid://gitlab/User/6025');
    final group = await _open(fixture, true);
    final groupHits = await fixture.api.searchWorkItemAssigneeCandidates(
      group.target!,
      search: '群組候選01',
    );
    expect(groupHits.single.username, 'gcand1');
    expect(
      fixture.workItemAssigneeCandidateEvents.map((event) => event['group']),
      [false, false, true],
    );
    expect(
      fixture.workItemAssigneeCandidateEvents.every(
        (event) => event['paged'] == false,
      ),
      isTrue,
    );
    final candidateRequests = fixture.adapter.requests.where((request) {
      final data = request.data;
      return data is Map &&
          (data['query'] as String).contains('autocompleteUsers');
    });
    expect(candidateRequests, hasLength(3));
    for (final request in candidateRequests) {
      final data = request.data as Map;
      expect((data['variables'] as Map).keys, ['fullPath', 'search']);
      final query = data['query'] as String;
      expect(query.contains('autocompleteUsers(first'), isFalse);
      expect(query.contains('after:'), isFalse);
    }
    expect(fixture.workItemAssigneeEvents, isEmpty);
  });

  test(
    'permission, widget, revision, malformed and incomplete pages do not write',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      fixture.workItemAssigneeMetadataAllowed = false;
      final denied = await _open(fixture, false);
      expect(denied.canWrite, isFalse);
      expect(denied.target, isNull);

      fixture.workItemAssigneeMetadataAllowed = true;
      fixture.workItemAssigneeWidgetPresent = false;
      await expectLater(
        _open(fixture, false),
        throwsA(failure(FailureKind.unsupported)),
      );

      fixture.workItemAssigneeWidgetPresent = true;
      final current = await _open(fixture, false);
      fixture.reviseWorkItemAssignee(group: false);
      await expectLater(
        fixture.api.updateWorkItemAssignees(
          current.target!,
          assigneeIds: const ['gid://gitlab/User/1009'],
        ),
        throwsA(failure(FailureKind.conflict)),
      );

      fixture.malformNextAssigneeRead = true;
      await expectLater(
        _open(fixture, false),
        throwsA(failure(FailureKind.unsupported)),
      );

      fixture.setWorkItemAssigneeCount(group: false, count: 101);
      fixture.workItemAssigneeRevisionDuringPagination = true;
      await expectLater(
        _open(fixture, false),
        throwsA(failure(FailureKind.unsupported)),
      );

      fixture.setWorkItemAssigneeCount(group: false, count: 2001);
      await expectLater(
        _open(fixture, false),
        throwsA(failure(FailureKind.unsupported)),
      );
      await expectLater(
        fixture.api.updateWorkItemAssignees(
          current.target!,
          assigneeIds: [
            for (var number = 1; number <= 2001; number++)
              'gid://gitlab/User/${1000 + number}',
          ],
        ),
        throwsA(failure(FailureKind.validation)),
      );
      expect(fixture.workItemAssigneeEvents, isEmpty);
    },
  );

  test(
    'lost acknowledgement applies once and blocks replay until a fresh read',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final current = await _open(fixture, false);
      fixture.failNextWorkItemAssigneeAcknowledgement = true;
      const desired = ['gid://gitlab/User/1019'];
      await expectLater(
        fixture.api.updateWorkItemAssignees(
          current.target!,
          assigneeIds: desired,
        ),
        throwsA(failure(FailureKind.writeUncertain)),
      );
      await expectLater(
        fixture.api.updateWorkItemAssignees(
          current.target!,
          assigneeIds: desired,
        ),
        throwsA(failure(FailureKind.writeUncertain)),
      );
      expect(fixture.workItemAssigneeEvents, hasLength(1));
      final fresh = await _open(fixture, false);
      expect(fresh.snapshot.users.single.id, desired.single);
    },
  );

  test(
    'dropped acknowledgement and mismatched readback stay one mutation',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final current = await _open(fixture, false);
      fixture.dropNextWorkItemAssigneeAckUser = true;
      const desired = ['gid://gitlab/User/1004', 'gid://gitlab/User/1008'];
      await expectLater(
        fixture.api.updateWorkItemAssignees(
          current.target!,
          assigneeIds: desired,
        ),
        throwsA(failure(FailureKind.writeUncertain)),
      );
      final dropped = await _open(fixture, false);
      expect(dropped.snapshot.users.single.id, 'gid://gitlab/User/1004');

      fixture.mismatchNextWorkItemAssigneeReadback = true;
      await expectLater(
        fixture.api.updateWorkItemAssignees(
          dropped.target!,
          assigneeIds: desired,
        ),
        throwsA(failure(FailureKind.writeUncertain)),
      );
      final restored = await _open(fixture, false);
      expect(restored.snapshot.users.map((user) => user.id), desired);
      expect(fixture.workItemAssigneeEvents, hasLength(2));
    },
  );

  test('acknowledgement continuation uses the real update payload', () async {
    final fixture = EmulatorQaFixture();
    addTearDown(fixture.api.close);
    final current = await _open(fixture, true);
    final desired = [
      for (var number = 1; number <= 150; number++)
        'gid://gitlab/User/${4000 + number}',
    ];
    final updated = await fixture.api.updateWorkItemAssignees(
      current.target!,
      assigneeIds: desired,
    );
    expect(updated.users.map((user) => user.id), desired);
    expect(fixture.workItemAssigneeEvents, hasLength(1));
    expect(
      fixture.workItemAssigneeReads.where((event) => event['after'] != null),
      isNotEmpty,
    );
    final body = fixture.lastAssigneeMutationResponse!;
    final data = body['data'] as Map;
    expect(data.keys, ['workItemUpdate']);
    expect(data.containsKey('currentUser'), isFalse);
    final update = data['workItemUpdate'] as Map;
    expect(update['errors'], isEmpty);
    expect(update.containsKey('currentUser'), isFalse);
    final widget =
        ((update['workItem'] as Map)['widgets'] as List).single as Map;
    expect(widget['type'], 'ASSIGNEES');
    expect((widget['assignees'] as Map)['pageInfo'], {
      'hasNextPage': true,
      'endCursor': 'qa-assignees:group:100',
    });
  });

  test('complete 2000 reads stop at the page cap and 2001 does not', () async {
    final fixture = EmulatorQaFixture();
    addTearDown(fixture.api.close);
    fixture.setWorkItemAssigneeCount(group: false, count: 2000);
    final complete = await _open(fixture, false);
    expect(complete.snapshot.users, hasLength(2000));
    expect(fixture.workItemAssigneeReads, hasLength(20));
    expect(
      fixture.workItemAssigneeReads.every((event) => event['accepted'] == true),
      isTrue,
    );
    fixture.workItemAssigneeReads.clear();
    fixture.setWorkItemAssigneeCount(group: false, count: 2001);
    await expectLater(
      _open(fixture, false),
      throwsA(failure(FailureKind.unsupported)),
    );
    expect(fixture.workItemAssigneeReads, hasLength(20));
    expect(fixture.workItemAssigneeEvents, isEmpty);
  });

  testWidgets('phone QA menu scrolls to the assignee controls', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('emulator-qa-note-edit-controls'));
    await tester.tap(menu);
    await tester.pumpAndSettle();
    final option = find.text('允許負責人設定');
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();
    await tester.tap(
      find.ancestor(
        of: option,
        matching: find.byWidgetPredicate((widget) => widget is PopupMenuItem),
      ),
    );
    await tester.pump();
    expect(find.text('負責人設定：允許'), findsOneWidget);
    expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
  });
}

Matcher failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);
