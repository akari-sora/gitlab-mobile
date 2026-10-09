import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_state_models.dart';
import 'package:gitlab_mobile/core/work_item_status_models.dart';
import 'package:gitlab_mobile/features/workspace/work_item_status.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/work_item_status_fixture.dart';

const _todo = WorkItemStatusFixture.statusTodo;
const _doing = WorkItemStatusFixture.statusDoing;
const _done = WorkItemStatusFixture.statusDone;

Future<WorkItemStatusAccess> _open(
  WorkItemStatusFixture fixture, {
  bool group = false,
  GitLabApi? api,
}) => (api ?? fixture.api).workItemStatus(
  fixture.detail(group: group),
  expectedUserId: fixture.account.user.id,
  generation: fixture.sessionGeneration,
  isCurrent: () => true,
);

Future<WorkItemStatusSaveResult> _update(
  WorkItemStatusFixture fixture,
  WorkItemStatusTarget target,
  String candidateId, {
  List<Object>? tokens,
  bool Function()? isCurrent,
  GitLabApi? api,
}) => (api ?? fixture.api).updateWorkItemStatus(
  target,
  candidateId: candidateId,
  isCurrent: isCurrent ?? () => true,
  onMutationSent: (started) {
    final token = Object();
    tokens?.add(token);
    started(token);
  },
);

Matcher _writeFailure(
  FailureKind kind, {
  required bool mutationSent,
  required WorkItemStatusHandoff handoff,
}) => isA<WorkItemStatusWriteFailure>()
    .having((failure) => failure.failure.kind, 'kind', kind)
    .having((failure) => failure.mutationSent, 'mutationSent', mutationSent)
    .having((failure) => failure.handoff, 'handoff', handoff);

Future<void> _turns(bool Function() ready) async {
  for (var turn = 0; turn < 500 && !ready(); turn++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(ready(), isTrue);
}

void main() {
  group('host-only synthetic STATUS fixture (no device, no native run)', () {
    test(
      'request and mutation nonces are unique and increasing and confirm reads after apply',
      () async {
        final fixture = WorkItemStatusFixture();
        addTearDown(fixture.closeAll);
        final access = await _open(fixture);
        final result = await _update(fixture, access.target!, _doing);
        expect(result.status, WorkItemStatusSaveStatus.success);

        final nonces = [for (final request in fixture.requests) request.nonce];
        expect(nonces.toSet(), hasLength(nonces.length));
        for (var index = 1; index < nonces.length; index++) {
          expect(nonces[index], greaterThan(nonces[index - 1]));
        }
        expect(fixture.requests.map((request) => request.kind), [
          StatusFixtureRequestKind.read,
          StatusFixtureRequestKind.read,
          StatusFixtureRequestKind.mutation,
          StatusFixtureRequestKind.read,
        ]);
        final mutation = fixture.requests[2];
        expect(mutation.mutationNonce, 1);
        expect(fixture.appliedMutationNonces, [1]);
        expect(fixture.requests.last.nonce, greaterThan(mutation.nonce));

        final second = await _open(fixture);
        await _update(fixture, second.target!, _todo);
        final mutationNonces = [
          for (final request in fixture.requests)
            if (request.mutationNonce != null) request.mutationNonce!,
        ];
        expect(mutationNonces, [1, 2]);
        expect(fixture.appliedMutationNonces, [1, 2]);
        expect(fixture.unhandled, isEmpty);
      },
    );

    test(
      'unknown operations, endpoints and widened inputs are rejected, not answered',
      () async {
        final fixture = WorkItemStatusFixture();
        addTearDown(fixture.closeAll);

        await expectLater(
          fixture.api.projectWorkItem(
            Project.fromJson(projectJson(42)),
            WorkItemStatusFixture.sharedIid,
          ),
          throwsA(isA<ApiFailure>()),
        );
        expect(fixture.unhandled.single, startsWith('operation'));

        await expectLater(
          fixture.api.record(['projects', '42']),
          throwsA(isA<ApiFailure>()),
        );
        expect(fixture.unhandled.last, startsWith('endpoint'));

        Future<ResponseBody> raw(Map<String, Object?> input) =>
            fixture.adapter.fetch(
              RequestOptions(
                path: 'https://example.com/gitlab/api/graphql',
                method: 'POST',
                data: {
                  'query':
                      'mutation MobileUpdateWorkItemStatus(\$input: WorkItemUpdateInput!) {}',
                  'variables': {'input': input},
                },
              ),
              null,
              null,
            );
        final widened = [
          {
            'id': WorkItemStatusFixture.projectItemId,
            'statusWidget': {'status': _doing, 'name': '進行中'},
          },
          {
            'id': WorkItemStatusFixture.projectItemId,
            'statusWidget': {'status': _doing},
            'stateEvent': 'CLOSE',
          },
          {
            'id': WorkItemStatusFixture.projectItemId,
            'statusWidget': {'name': '進行中'},
          },
          {
            'id': WorkItemStatusFixture.projectItemId,
            'statusWidget': {'status': _doing},
            'lockVersion': 8,
          },
        ];
        for (final input in widened) {
          final response = await raw(input);
          expect(response.statusCode, 400);
        }
        expect(fixture.mutations, 0);
        expect(fixture.appliedMutationNonces, isEmpty);
        expect(fixture.unhandled, hasLength(2 + widened.length));
        expect(fixture.item(group: false).assignment!.id, _todo);
      },
    );

    test('timestamps are integer-second ISO8601 and same-second saves succeed', () async {
      expect(
        statusFixtureTimestamp(DateTime.utc(2026, 10, 4, 4, 0, 1)),
        '2026-10-04T04:00:01Z',
      );
      expect(
        () => statusFixtureTimestamp(DateTime.utc(2026, 10, 4, 4, 0, 1, 5)),
        throwsArgumentError,
      );

      final fixture = WorkItemStatusFixture()..advanceSeconds = 0;
      addTearDown(fixture.closeAll);
      final access = await _open(fixture);
      final result = await _update(fixture, access.target!, _doing);
      expect(result.status, WorkItemStatusSaveStatus.success);
      expect(result.acknowledgement!.updatedAt, access.snapshot.updatedAt);
      expect(result.snapshot.updatedAt, access.snapshot.updatedAt);

      final later = WorkItemStatusFixture();
      addTearDown(later.closeAll);
      final opened = await _open(later);
      final saved = await _update(later, opened.target!, _doing);
      expect(
        saved.snapshot.updatedAt.difference(opened.snapshot.updatedAt),
        const Duration(seconds: 1),
      );
    });

    test(
      'separate BEFORE-APPLY and ACK holds: state changes before ACK and confirm reads truth',
      () async {
        final fixture = WorkItemStatusFixture();
        addTearDown(fixture.closeAll);
        final apply = Completer<void>();
        final ack = Completer<void>();
        fixture
          ..holdBeforeApply = apply
          ..holdAck = ack;
        try {
          final access = await _open(fixture);
          final tokens = <Object>[];
          final pending = _update(fixture, access.target!, _done, tokens: tokens);
          await _turns(() => fixture.awaitingApply);
          expect(tokens, hasLength(1));
          expect(fixture.item(group: false).assignment!.id, _todo);
          expect(fixture.item(group: false).state, 'OPEN');
          expect(fixture.appliedMutationNonces, isEmpty);

          apply.complete();
          await _turns(() => fixture.awaitingAck);
          expect(fixture.item(group: false).assignment!.id, _done);
          expect(fixture.item(group: false).state, 'CLOSED');
          expect(fixture.appliedMutationNonces, [1]);
          expect(fixture.reads, 2);

          ack.complete();
          final result = await pending;
          expect(fixture.reads, 3);
          expect(result.status, WorkItemStatusSaveStatus.success);
          expect(result.snapshot.state, WorkItemState.closed);
          expect(result.snapshot.assignment.id, _done);
          expect(result.snapshot.lockVersion, 9);
        } finally {
          fixture.releaseHolds();
        }
      },
    );

    test(
      'an independent confirm read observes drift made while the ACK is held',
      () async {
        final fixture = WorkItemStatusFixture();
        addTearDown(fixture.closeAll);
        final ack = Completer<void>();
        fixture.holdAck = ack;
        try {
          final access = await _open(fixture);
          final pending = _update(fixture, access.target!, _doing);
          await _turns(() => fixture.awaitingAck);
          fixture.item(group: false).assignment =
              WorkItemStatusFixture.defaultMembers[3];
          ack.complete();
          await expectLater(
            pending,
            throwsA(
              _writeFailure(
                FailureKind.writeUncertain,
                mutationSent: true,
                handoff: WorkItemStatusHandoff.started,
              ),
            ),
          );
          expect(fixture.mutations, 1);
        } finally {
          fixture.releaseHolds();
        }
      },
    );

    test('each independent drift between open and Save sends zero', () async {
      final serverDrifts =
          <String, (FailureKind, void Function(WorkItemStatusFixture))>{
            'revision': (
              FailureKind.conflict,
              (fixture) => fixture.touch(group: false),
            ),
            'lock': (
              FailureKind.conflict,
              (fixture) => fixture.item(group: false).lockVersion++,
            ),
            'status': (
              FailureKind.conflict,
              (fixture) => fixture.item(group: false).assignment =
                  WorkItemStatusFixture.defaultMembers[1],
            ),
            'state': (
              FailureKind.conflict,
              (fixture) => fixture.item(group: false).state = 'CLOSED',
            ),
            'ordered members': (
              FailureKind.conflict,
              (fixture) => fixture.item(group: false).members = [
                ...WorkItemStatusFixture.defaultMembers.reversed,
              ],
            ),
            'permission': (
              FailureKind.conflict,
              (fixture) =>
                  fixture.item(group: false).setWorkItemMetadata = false,
            ),
            'actor': (
              FailureKind.cancelled,
              (fixture) => fixture.actorUserId = 8,
            ),
            'resource': (
              FailureKind.unsupported,
              (fixture) => fixture.item(group: false).namespace =
                  const GraphResourceRef(
                    id: 'gid://gitlab/Namespaces::ProjectNamespace/99',
                    fullPath: 'other/project',
                  ),
            ),
            'type': (
              FailureKind.unsupported,
              (fixture) => fixture.item(group: false).typeId =
                  'gid://gitlab/WorkItems::Type/99',
            ),
            'schema': (
              FailureKind.unsupported,
              (fixture) =>
                  fixture.item(group: false).statusDefinitionPresent = false,
            ),
          };
      for (final entry in serverDrifts.entries) {
        final fixture = WorkItemStatusFixture();
        addTearDown(fixture.closeAll);
        final access = await _open(fixture);
        entry.value.$2(fixture);
        final tokens = <Object>[];
        await expectLater(
          _update(fixture, access.target!, _doing, tokens: tokens),
          throwsA(
            _writeFailure(
              entry.value.$1,
              mutationSent: false,
              handoff: WorkItemStatusHandoff.none,
            ),
          ),
          reason: entry.key,
        );
        expect(tokens, isEmpty, reason: entry.key);
        expect(fixture.mutations, 0, reason: entry.key);
      }

      final apiFixture = WorkItemStatusFixture();
      addTearDown(apiFixture.closeAll);
      final owned = await _open(apiFixture);
      final other = apiFixture.replaceApi();
      await expectLater(
        _update(apiFixture, owned.target!, _doing, api: other),
        throwsA(
          _writeFailure(
            FailureKind.validation,
            mutationSent: false,
            handoff: WorkItemStatusHandoff.none,
          ),
        ),
      );

      final sessionFixture = WorkItemStatusFixture();
      addTearDown(sessionFixture.closeAll);
      final session = await _open(sessionFixture);
      sessionFixture.sessionGeneration = 13;
      await expectLater(
        _update(
          sessionFixture,
          session.target!,
          _doing,
          isCurrent: () => sessionFixture.sessionGeneration == 12,
        ),
        throwsA(
          _writeFailure(
            FailureKind.cancelled,
            mutationSent: false,
            handoff: WorkItemStatusHandoff.none,
          ),
        ),
      );
      expect(apiFixture.mutations + sessionFixture.mutations, 0);
    });

    test('a lost ACK applies once, is never replayed and reopen sees it', () async {
      final fixture = WorkItemStatusFixture()..loseNextAck = true;
      addTearDown(fixture.closeAll);
      final access = await _open(fixture);
      await expectLater(
        _update(fixture, access.target!, _doing),
        throwsA(
          _writeFailure(
            FailureKind.writeUncertain,
            mutationSent: true,
            handoff: WorkItemStatusHandoff.started,
          ),
        ),
      );
      await expectLater(
        _update(fixture, access.target!, _doing),
        throwsA(
          _writeFailure(
            FailureKind.writeUncertain,
            mutationSent: false,
            handoff: WorkItemStatusHandoff.none,
          ),
        ),
      );
      expect(fixture.mutations, 1);
      expect(fixture.appliedMutationNonces, [1]);
      final reopened = await _open(fixture);
      expect(reopened.snapshot.assignment.id, _doing);
      expect(fixture.mutations, 1);
    });

    test(
      'closeAll closes the initial client and every replacement after replaceApi',
      () async {
        final fixture = WorkItemStatusFixture();
        addTearDown(fixture.closeAll);
        final initial = fixture.api;
        final opened = await _open(fixture);
        expect(opened.snapshot.assignment.id, _todo);
        final first = fixture.replaceApi();
        final second = fixture.replaceApi();
        expect(fixture.api, same(second));
        expect(first, isNot(same(initial)));
        expect(second, isNot(same(first)));
        await _open(fixture, api: first);
        expect(fixture.reads, 2);
        expect([initial, first, second].any((api) => api.isClosed), isFalse);

        fixture.closeAll();
        expect(initial.isClosed, isTrue);
        expect(first.isClosed, isTrue);
        expect(second.isClosed, isTrue);

        final before = fixture.requests.length;
        for (final api in [initial, first, second]) {
          await expectLater(
            _open(fixture, api: api),
            throwsA(
              isA<ApiFailure>().having(
                (failure) => failure.kind,
                'kind',
                FailureKind.cancelled,
              ),
            ),
          );
        }
        expect(fixture.requests, hasLength(before));
        expect(fixture.mutations, 0);
        expect(fixture.unhandled, isEmpty);
      },
    );

    test('project and group records with the same IID stay independent', () async {
      final fixture = WorkItemStatusFixture();
      addTearDown(fixture.closeAll);
      final project = await _open(fixture);
      final group = await _open(fixture, group: true);
      expect(project.snapshot.iid, group.snapshot.iid);
      expect(project.snapshot.id, isNot(group.snapshot.id));
      expect(group.snapshot.project, isNull);
      await _update(fixture, project.target!, _done);
      expect(fixture.item(group: false).state, 'CLOSED');
      expect(fixture.item(group: true).state, 'OPEN');
      expect(fixture.item(group: true).assignment!.id, _todo);
      expect(fixture.mutationInputs.single, {
        'id': WorkItemStatusFixture.projectItemId,
        'statusWidget': {'status': _done},
      });
    });
  });

  testWidgets(
    'host-rendered status editor over the synthetic fixture at phone width',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final fixture = WorkItemStatusFixture();
      addTearDown(fixture.releaseHolds);
      addTearDown(fixture.closeAll);
      final saved = <WorkItemStatusSaveResult>[];
      final phases = <WorkItemStatusWritePhase>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                const Text('合成資料 QA · 無 GitLab 連線'),
                WorkItemStatusControl(
                  account: fixture.account,
                  api: fixture.api,
                  detail: fixture.detail(group: true),
                  sessionGeneration: fixture.sessionGeneration,
                  onSaved: saved.add,
                  onStatusWrite:
                      (phase, token, account, api, detail, generation) =>
                          phases.add(phase),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('work-item-status-edit')));
      await settleNetworkWidgets(tester);
      expect(find.text('studio/group · 工作項目 #17'), findsOneWidget);
      expect(find.text('目前生命週期：開啟中'), findsOneWidget);
      final row = find.byKey(const ValueKey('work-item-status-choice-$_done'));
      await tester.ensureVisible(row);
      await tester.pump();
      await tester.tap(row);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('work-item-status-save')));
      await tester.pump();
      await pumpUntil(tester, () => saved.isNotEmpty);
      await tester.pump();
      expect(phases, [
        WorkItemStatusWritePhase.start,
        WorkItemStatusWritePhase.settle,
      ]);
      expect(find.text('已確認狀態：完成 · 已關閉'), findsOneWidget);
      expect(fixture.item(group: true).state, 'CLOSED');
      expect(fixture.item(group: false).state, 'OPEN');
      expect(fixture.unhandled, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
