import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/work_item_dates_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'support/c2d7_barrier.dart';
import 'support/fake_adapter.dart';

const _actor = 'gid://gitlab/User/7';
const _item = 'gid://gitlab/WorkItem/100';
const _type = 'gid://gitlab/WorkItems::Type/9';
const _project = 'gid://gitlab/Project/42';
const _projectPath = 'studio/mobile-workspace';
const _namespace = 'gid://gitlab/Namespaces::ProjectNamespace/42';
final _created = DateTime.utc(2026, 10, 1, 8);
final _revision = DateTime.utc(2026, 10, 4, 8, 0, 0);
final _older = DateTime.utc(2026, 10, 4, 7, 59, 59);
final _newer = DateTime.utc(2026, 10, 4, 8, 0, 1);
const _revisionText = '2026-10-04T08:00:00Z';
const _keep = Object();

enum _RequestKind { base, probe, mutation }

const _eeAccess = [_RequestKind.base, _RequestKind.probe];
const _eeFence = [_RequestKind.base, _RequestKind.probe];
const _eeConfirm = [_RequestKind.base, _RequestKind.probe];
const _eeWrite = [
  ..._eeAccess,
  ..._eeFence,
  _RequestKind.mutation,
  ..._eeConfirm,
];
const _eeWriteNoConfirm = [..._eeAccess, ..._eeFence, _RequestKind.mutation];
const _ceWrite = _eeWrite;

typedef _MutationResponder =
    FutureOr<ResponseBody> Function(
      _DatesServer server,
      RequestOptions request,
      Map<String, Object?> widget,
    );

void main() {
  test('C2-D8 dates callback failure is cancelled before gate and send', () async {
    final server = _DatesServer(
      initial: const _ServerState(),
      expected: const [_RequestKind.base, _RequestKind.probe, _RequestKind.base, _RequestKind.probe],
    );
    final api = _api(server);
    final target = (await _access(api)).target!;
    final events = <String>[];
    await expectLater(
      api.updateWorkItemDates(
        target,
        mode: WorkItemDatesMode.manual,
        startDate: '2026-10-04',
        dueDate: null,
        beforeMutation: () async => events.add('hook'),
        onMutationSent: () {
          events.add('start');
          throw StateError('synthetic callback failure');
        },
        mayStart: () {
          events.add('gate');
          return true;
        },
      ),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(events, ['hook', 'start']);
    expect(server.mutationCount, 0);
  });

  test('C2-D8 dates barrier failure after START is certainly unsent', () async {
    final server = _DatesServer(
      initial: const _ServerState(),
      expected: [..._eeAccess, ..._eeFence],
    );
    final api = _api(server);
    api.bindReadCache('https://example.com/gitlab#7', 4);
    final target = (await _access(api)).target!;
    api.attachReadCacheDiskBackend(C2d7Barrier());
    var started = 0;
    await expectLater(
      api.updateWorkItemDates(
        target,
        mode: WorkItemDatesMode.manual,
        startDate: '2026-10-04',
        dueDate: null,
        onMutationSent: () => started++,
      ),
      throwsA(
        isA<ApiFailure>()
            .having((e) => e.kind, 'kind', FailureKind.readCacheCleanup)
            .having(
              (e) => e.cleanup?.disposition,
              'disposition',
              ReadCacheCleanupDisposition.requestBlockedBeforeSend,
            ),
      ),
    );
    expect(started, 1);
    expect(server.mutationCount, 0);
  });

  test('same-second manual set and explicit-null clear both apply', () async {
    for (final clear in [false, true]) {
      final initial = _ServerState(
        startDate: clear ? '2026-10-01' : null,
        dueDate: clear ? '2026-10-02' : null,
      );
      final server = _DatesServer(initial: initial, expected: _eeWrite);
      final api = _api(server);
      var handoffs = 0;
      final result = await api.updateWorkItemDates(
        (await _access(api)).target!,
        mode: WorkItemDatesMode.manual,
        startDate: clear ? null : '2026-10-04',
        dueDate: clear ? null : '2026-10-05',
        onMutationSent: () => handoffs++,
      );

      expect(result.outcome, WorkItemDatesWriteOutcome.applied);
      expect(result.mutationSent, isTrue);
      expect(result.snapshot!.updatedAt, _revision);
      expect(result.snapshot!.startDate, clear ? null : '2026-10-04');
      expect(result.snapshot!.dueDate, clear ? null : '2026-10-05');
      _expectOneSend(server, handoffs);
    }
  });

  test(
    'equal-revision non-null mode changes apply in both directions',
    () async {
      final cases = [
        (
          opening: _ServerState(
            mode: WorkItemDatesMode.manual,
            startDate: '2026-10-04',
            dueDate: '2026-10-05',
          ),
          requested: WorkItemDatesMode.inherited,
        ),
        (
          opening: _ServerState(
            mode: WorkItemDatesMode.inherited,
            startDate: '2026-10-04',
            dueDate: '2026-10-05',
            startWorkItem: 'gid://gitlab/WorkItem/201',
            dueMilestone: 'gid://gitlab/Milestone/301',
          ),
          requested: WorkItemDatesMode.manual,
        ),
      ];
      for (final testCase in cases) {
        final server = _DatesServer(
          initial: testCase.opening,
          expected: _eeWrite,
          inheritedResult: testCase.opening.copyWith(
            mode: WorkItemDatesMode.inherited,
            startWorkItem: 'gid://gitlab/WorkItem/201',
            dueMilestone: 'gid://gitlab/Milestone/301',
          ),
        );
        final api = _api(server);
        final result = await api.updateWorkItemDates(
          (await _access(api)).target!,
          mode: testCase.requested,
          startDate: '2026-10-04',
          dueDate: '2026-10-05',
          onMutationSent: () {},
        );

        expect(result.outcome, WorkItemDatesWriteOutcome.applied);
        expect(result.snapshot!.mode, testCase.requested);
        expect(result.snapshot!.updatedAt, _revision);
        expect(server.mutationCount, 1);
      }
    },
  );

  test(
    'inherited confirmation uses changed ACK rolled dates and sources',
    () async {
      final inherited = _ServerState(
        mode: WorkItemDatesMode.inherited,
        startDate: '2026-09-01',
        dueDate: '2026-12-31',
        startWorkItem: 'gid://gitlab/WorkItem/201',
        dueMilestone: 'gid://gitlab/Milestone/301',
      );
      final server = _DatesServer(
        initial: const _ServerState(),
        expected: _eeWrite,
        inheritedResult: inherited,
      );
      final api = _api(server);
      final result = await api.updateWorkItemDates(
        (await _access(api)).target!,
        mode: WorkItemDatesMode.inherited,
        startDate: '2025-01-01',
        dueDate: '2025-12-31',
        onMutationSent: () {},
      );

      expect(result.outcome, WorkItemDatesWriteOutcome.applied);
      expect(result.snapshot!.startDate, '2026-09-01');
      expect(result.snapshot!.dueDate, '2026-12-31');
      expect(
        result.snapshot!.startDateSourcingWorkItemId,
        'gid://gitlab/WorkItem/201',
      );
      expect(
        result.snapshot!.dueDateSourcingMilestoneId,
        'gid://gitlab/Milestone/301',
      );
      expect(server.sentWidgets.single, {'isFixed': false});
    },
  );

  test('older ACK and equal-revision wrong value are uncertain', () async {
    for (final wrongValue in [false, true]) {
      final server = _DatesServer(
        initial: const _ServerState(),
        expected: _eeWriteNoConfirm,
        mutationResponder: (server, _, widget) {
          server.applyRequested(widget);
          server.state = server.state.copyWith(
            updatedAt: wrongValue ? _revisionText : _older.toIso8601String(),
            startDate: wrongValue ? '2026-10-06' : _keep,
          );
          return jsonResponse(_ackEnvelope(server.state));
        },
      );
      final api = _api(server);
      final result = await api.updateWorkItemDates(
        (await _access(api)).target!,
        mode: WorkItemDatesMode.manual,
        startDate: '2026-10-04',
        dueDate: null,
        onMutationSent: () {},
      );
      expect(result.outcome, WorkItemDatesWriteOutcome.writeUncertain);
      expect(result.mutationSent, isTrue);
      expect(server.mutationCount, 1);
    }
  });

  test('only exact unchanged old ACK and postread is silent denial', () async {
    final server = _DatesServer(
      initial: const _ServerState(),
      expected: _eeWrite,
      applyMutation: false,
    );
    final api = _api(server);
    final result = await api.updateWorkItemDates(
      (await _access(api)).target!,
      mode: WorkItemDatesMode.manual,
      startDate: '2026-10-04',
      dueDate: null,
      onMutationSent: () {},
    );

    expect(result.outcome, WorkItemDatesWriteOutcome.notApplied);
    expect(result.mutationSent, isTrue);
    expect(result.snapshot!.updatedAt, _revision);
    expect(result.snapshot!.startDate, isNull);
    expect(server.mutationCount, 1);
  });

  test('unchanged values with a newer ACK revision are uncertain', () async {
    final server = _DatesServer(
      initial: const _ServerState(),
      expected: _eeWriteNoConfirm,
      applyMutation: false,
      mutationResponder: (server, _, _) {
        server.state = server.state.copyWith(
          updatedAt: _newer.toIso8601String(),
        );
        return jsonResponse(_ackEnvelope(server.state));
      },
    );
    final api = _api(server);
    final result = await api.updateWorkItemDates(
      (await _access(api)).target!,
      mode: WorkItemDatesMode.manual,
      startDate: '2026-10-04',
      dueDate: null,
      onMutationSent: () {},
    );
    expect(result.outcome, WorkItemDatesWriteOutcome.writeUncertain);
  });

  test(
    'postread revision drift older or newer than ACK is uncertain',
    () async {
      for (final revision in [_older, _newer]) {
        final server = _DatesServer(
          initial: const _ServerState(),
          expected: _eeWrite,
          beforeConfirm: (server) {
            server.state = server.state.copyWith(
              updatedAt: revision.toIso8601String(),
            );
          },
        );
        final api = _api(server);
        final result = await api.updateWorkItemDates(
          (await _access(api)).target!,
          mode: WorkItemDatesMode.manual,
          startDate: '2026-10-04',
          dueDate: null,
          onMutationSent: () {},
        );
        expect(result.outcome, WorkItemDatesWriteOutcome.writeUncertain);
        expect(server.mutationCount, 1);
      }
    },
  );

  test('postread value mode source and rollUp drift are uncertain', () async {
    final changedStates = [
      const _ServerState(startDate: '2026-10-05'),
      const _ServerState(
        mode: WorkItemDatesMode.inherited,
        startDate: '2026-10-04',
        startWorkItem: 'gid://gitlab/WorkItem/201',
      ),
      const _ServerState(startDate: '2026-10-04', rollUp: true),
    ];
    for (final changed in changedStates) {
      final server = _DatesServer(
        initial: const _ServerState(),
        expected: _eeWrite,
        beforeConfirm: (server) => server.state = changed,
      );
      final api = _api(server);
      final result = await api.updateWorkItemDates(
        (await _access(api)).target!,
        mode: WorkItemDatesMode.manual,
        startDate: '2026-10-04',
        dueDate: null,
        onMutationSent: () {},
      );
      expect(result.outcome, WorkItemDatesWriteOutcome.writeUncertain);
      expect(result.mutationSent, isTrue);
      expect(server.mutationCount, 1);
    }
  });

  test(
    'OPEN-CLOSED fresh drift burns target and sends zero mutations',
    () async {
      for (final openingState in ['OPEN', 'CLOSED']) {
        final targetState = openingState == 'OPEN' ? 'CLOSED' : 'OPEN';
        final server = _DatesServer(
          initial: _ServerState(state: openingState),
          expected: [..._eeAccess, _RequestKind.base],
          beforeFence: (server) {
            server.state = server.state.copyWith(state: targetState);
          },
        );
        final api = _api(server);
        final target = (await _access(api, detailState: openingState)).target!;
        await expectLater(
          api.updateWorkItemDates(
            target,
            mode: WorkItemDatesMode.manual,
            startDate: '2026-10-04',
            dueDate: null,
            onMutationSent: () => fail('no handoff'),
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(target.consumed, isTrue);
        expect(server.mutationCount, 0);
      }
    },
  );

  test(
    'fresh mode date source rollUp and revision drift send zero mutations',
    () async {
      final changedStates = [
        const _ServerState(startDate: '2026-10-03'),
        const _ServerState(
          mode: WorkItemDatesMode.inherited,
          startDate: '2026-10-03',
          startWorkItem: 'gid://gitlab/WorkItem/201',
        ),
        const _ServerState(rollUp: true),
        _ServerState(updatedAt: _newer.toIso8601String()),
      ];
      for (final changed in changedStates) {
        final server = _DatesServer(
          initial: const _ServerState(),
          expected: [..._eeAccess, ..._eeFence],
          beforeFence: (server) => server.state = changed,
        );
        final api = _api(server);
        await expectLater(
          api.updateWorkItemDates(
            (await _access(api)).target!,
            mode: WorkItemDatesMode.manual,
            startDate: '2026-10-04',
            dueDate: null,
            onMutationSent: () => fail('no handoff'),
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(server.mutationCount, 0);
      }

      final missingWidgetServer = _DatesServer(
        initial: const _ServerState(),
        expected: [..._eeAccess, _RequestKind.base],
        beforeFence: (server) {
          server.state = server.state.copyWith(widgetPresent: false);
        },
      );
      final missingWidgetApi = _api(missingWidgetServer);
      await expectLater(
        missingWidgetApi.updateWorkItemDates(
          (await _access(missingWidgetApi)).target!,
          mode: WorkItemDatesMode.manual,
          startDate: '2026-10-04',
          dueDate: null,
          onMutationSent: () => fail('no handoff'),
        ),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(missingWidgetServer.mutationCount, 0);
    },
  );

  test(
    'stable CLOSED Work Item is writable and not API-owner closure',
    () async {
      final server = _DatesServer(
        initial: const _ServerState(state: 'CLOSED'),
        expected: _eeWrite,
      );
      final api = _api(server);
      final result = await api.updateWorkItemDates(
        (await _access(api, detailState: 'CLOSED')).target!,
        mode: WorkItemDatesMode.manual,
        startDate: '2026-10-04',
        dueDate: null,
        onMutationSent: () {},
      );
      expect(result.outcome, WorkItemDatesWriteOutcome.applied);
      expect(result.snapshot!.summary.state, 'CLOSED');
    },
  );

  test('ACK and postread state drift are uncertain after one send', () async {
    for (final driftAck in [true, false]) {
      final server = _DatesServer(
        initial: const _ServerState(state: 'OPEN'),
        expected: driftAck
            ? _eeWriteNoConfirm
            : [..._eeWriteNoConfirm, _RequestKind.base],
        mutationResponder: driftAck
            ? (server, _, widget) {
                server.applyRequested(widget);
                final wrong = server.state.copyWith(state: 'CLOSED');
                return jsonResponse(_ackEnvelope(wrong));
              }
            : null,
        beforeConfirm: driftAck
            ? null
            : (server) {
                server.state = server.state.copyWith(state: 'CLOSED');
              },
      );
      final api = _api(server);
      final result = await api.updateWorkItemDates(
        (await _access(api)).target!,
        mode: WorkItemDatesMode.manual,
        startDate: '2026-10-04',
        dueDate: null,
        onMutationSent: () {},
      );
      expect(result.outcome, WorkItemDatesWriteOutcome.writeUncertain);
      expect(server.mutationCount, 1);
    }
  });

  test(
    'actor and full identity fences reject fresh ACK and postread drift',
    () async {
      final freshCases = [
        (
          changed: const _ServerState(actor: 'gid://gitlab/User/8'),
          kind: FailureKind.cancelled,
        ),
        (
          changed: const _ServerState(itemId: 'gid://gitlab/WorkItem/101'),
          kind: FailureKind.writeUncertain,
        ),
        (
          changed: const _ServerState(iid: '16'),
          kind: FailureKind.writeUncertain,
        ),
        (
          changed: const _ServerState(projectPath: 'other/project'),
          kind: FailureKind.writeUncertain,
        ),
        (
          changed: const _ServerState(namespacePath: 'other/project'),
          kind: FailureKind.writeUncertain,
        ),
        (
          changed: const _ServerState(typeName: 'Issue'),
          kind: FailureKind.writeUncertain,
        ),
      ];
      for (final testCase in freshCases) {
        final server = _DatesServer(
          initial: const _ServerState(),
          expected: [..._eeAccess, _RequestKind.base],
          beforeFence: (server) => server.state = testCase.changed,
        );
        final api = _api(server);
        await expectLater(
          api.updateWorkItemDates(
            (await _access(api)).target!,
            mode: WorkItemDatesMode.manual,
            startDate: '2026-10-04',
            dueDate: null,
            onMutationSent: () => fail('no handoff'),
          ),
          throwsA(_failure(testCase.kind)),
        );
        expect(server.mutationCount, 0);
      }

      for (final ackState in [
        const _ServerState(itemId: 'gid://gitlab/WorkItem/101'),
        const _ServerState(iid: '16'),
        const _ServerState(projectPath: 'other/project'),
        const _ServerState(namespacePath: 'other/project'),
        const _ServerState(typeName: 'Issue'),
      ]) {
        final server = _DatesServer(
          initial: const _ServerState(),
          expected: _eeWriteNoConfirm,
          mutationResponder: (server, _, widget) {
            server.applyRequested(widget);
            return jsonResponse(
              _ackEnvelope(
                ackState.copyWith(
                  mode: server.state.mode,
                  startDate: server.state.startDate,
                  dueDate: server.state.dueDate,
                ),
              ),
            );
          },
        );
        final api = _api(server);
        final result = await api.updateWorkItemDates(
          (await _access(api)).target!,
          mode: WorkItemDatesMode.manual,
          startDate: '2026-10-04',
          dueDate: null,
          onMutationSent: () {},
        );
        expect(result.outcome, WorkItemDatesWriteOutcome.writeUncertain);
        expect(server.mutationCount, 1);
      }

      for (final postState in [
        const _ServerState(actor: 'gid://gitlab/User/8'),
        const _ServerState(itemId: 'gid://gitlab/WorkItem/101'),
        const _ServerState(namespacePath: 'other/project'),
        const _ServerState(typeName: 'Issue'),
      ]) {
        final server = _DatesServer(
          initial: const _ServerState(),
          expected: [..._eeWriteNoConfirm, _RequestKind.base],
          beforeConfirm: (server) {
            server.state = postState.copyWith(
              mode: WorkItemDatesMode.manual,
              startDate: '2026-10-04',
            );
          },
        );
        final api = _api(server);
        final result = await api.updateWorkItemDates(
          (await _access(api)).target!,
          mode: WorkItemDatesMode.manual,
          startDate: '2026-10-04',
          dueDate: null,
          onMutationSent: () {},
        );
        expect(result.outcome, WorkItemDatesWriteOutcome.writeUncertain);
        expect(server.mutationCount, 1);
      }
    },
  );

  test(
    'explicit null ACK fields clear while omitted date fields fail closed',
    () async {
      final clearServer = _DatesServer(
        initial: const _ServerState(
          startDate: '2026-10-01',
          dueDate: '2026-10-02',
        ),
        expected: _eeWrite,
      );
      final clearApi = _api(clearServer);
      final clear = await clearApi.updateWorkItemDates(
        (await _access(clearApi)).target!,
        mode: WorkItemDatesMode.manual,
        startDate: null,
        dueDate: null,
        onMutationSent: () {},
      );
      expect(clear.outcome, WorkItemDatesWriteOutcome.applied);
      expect(clear.snapshot!.startDate, isNull);
      expect(clear.snapshot!.dueDate, isNull);

      for (final omitted in ['startDate', 'dueDate', 'startSource']) {
        final server = _DatesServer(
          initial: const _ServerState(),
          expected: _eeWriteNoConfirm,
          mutationResponder: (server, _, widget) {
            server.applyRequested(widget);
            return jsonResponse(
              _ackEnvelope(
                server.state,
                omitStartDate: omitted == 'startDate',
                omitDueDate: omitted == 'dueDate',
                omitStartSource: omitted == 'startSource',
              ),
            );
          },
        );
        final api = _api(server);
        final result = await api.updateWorkItemDates(
          (await _access(api)).target!,
          mode: WorkItemDatesMode.manual,
          startDate: '2026-10-04',
          dueDate: null,
          onMutationSent: () {},
        );
        expect(result.outcome, WorkItemDatesWriteOutcome.writeUncertain);
      }
    },
  );

  test(
    'null or duplicate ACK widgets and malformed errors are uncertain',
    () async {
      final malformedBodies = <Object? Function(_ServerState)>[
        (state) => _ackEnvelope(state, widgets: null),
        (state) => _ackEnvelope(state, duplicateWidgets: true),
        (state) => {
          'data': {
            'workItemUpdate': {
              'errors': 'not-a-list',
              'workItem': _node(state, includePermissions: false),
            },
          },
        },
        (state) => {
          'data': {
            'workItemUpdate': {
              'errors': [1],
              'workItem': _node(state, includePermissions: false),
            },
          },
        },
      ];
      for (final body in malformedBodies) {
        final server = _DatesServer(
          initial: const _ServerState(),
          expected: _eeWriteNoConfirm,
          mutationResponder: (server, _, widget) {
            server.applyRequested(widget);
            return jsonResponse(body(server.state));
          },
        );
        final api = _api(server);
        final result = await api.updateWorkItemDates(
          (await _access(api)).target!,
          mode: WorkItemDatesMode.manual,
          startDate: '2026-10-04',
          dueDate: null,
          onMutationSent: () {},
        );
        expect(result.outcome, WorkItemDatesWriteOutcome.writeUncertain);
      }
    },
  );

  test('non-Boolean read and set permissions fail closed', () async {
    for (final permission in ['read', 'set']) {
      final initial = _ServerState(
        readWorkItem: permission == 'read' ? 'true' : true,
        setWorkItemMetadata: permission == 'set' ? 1 : true,
      );
      final server = _DatesServer(
        initial: initial,
        expected: [_RequestKind.base],
      );
      final api = _api(server);
      await expectLater(
        _access(api),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
    }

    for (final permission in ['read', 'set']) {
      final server = _DatesServer(
        initial: const _ServerState(),
        expected: [..._eeAccess, _RequestKind.base],
        beforeFence: (server) {
          server.state = server.state.copyWith(
            readWorkItem: permission == 'read' ? 'true' : _keep,
            setWorkItemMetadata: permission == 'set' ? 1 : _keep,
          );
        },
      );
      final api = _api(server);
      await expectLater(
        api.updateWorkItemDates(
          (await _access(api)).target!,
          mode: WorkItemDatesMode.manual,
          startDate: '2026-10-04',
          dueDate: null,
          onMutationSent: () => fail('no handoff'),
        ),
        throwsA(_failure(FailureKind.writeUncertain)),
      );
      expect(server.mutationCount, 0);
    }
  });

  test('strict-false fresh permission is zero-mutation notApplied', () async {
    for (final permission in ['read', 'set']) {
      final server = _DatesServer(
        initial: const _ServerState(),
        expected: [..._eeAccess, ..._eeFence],
        beforeFence: (server) {
          server.state = server.state.copyWith(
            readWorkItem: permission == 'read' ? false : _keep,
            setWorkItemMetadata: permission == 'set' ? false : _keep,
          );
        },
      );
      final api = _api(server);
      final result = await api.updateWorkItemDates(
        (await _access(api)).target!,
        mode: WorkItemDatesMode.manual,
        startDate: '2026-10-04',
        dueDate: null,
        onMutationSent: () => fail('no handoff'),
      );
      expect(result.outcome, WorkItemDatesWriteOutcome.notApplied);
      expect(result.mutationSent, isFalse);
      expect(server.mutationCount, 0);
    }
  });

  test('postread permissions must remain strict writable Booleans', () async {
    final cases = [
      (
        expected: [..._eeWriteNoConfirm, _RequestKind.base],
        change: (_DatesServer server) {
          server.state = server.state.copyWith(readWorkItem: false);
        },
      ),
      (
        expected: _eeWrite,
        change: (_DatesServer server) {
          server.state = server.state.copyWith(setWorkItemMetadata: false);
        },
      ),
      (
        expected: [..._eeWriteNoConfirm, _RequestKind.base],
        change: (_DatesServer server) {
          server.state = server.state.copyWith(readWorkItem: 'true');
        },
      ),
      (
        expected: [..._eeWriteNoConfirm, _RequestKind.base],
        change: (_DatesServer server) {
          server.state = server.state.copyWith(setWorkItemMetadata: 1);
        },
      ),
    ];
    for (final testCase in cases) {
      final server = _DatesServer(
        initial: const _ServerState(),
        expected: testCase.expected,
        beforeConfirm: testCase.change,
      );
      final api = _api(server);
      final result = await api.updateWorkItemDates(
        (await _access(api)).target!,
        mode: WorkItemDatesMode.manual,
        startDate: '2026-10-04',
        dueDate: null,
        onMutationSent: () {},
      );
      expect(result.outcome, WorkItemDatesWriteOutcome.writeUncertain);
      expect(result.mutationSent, isTrue);
      expect(server.mutationCount, 1);
    }
  });

  test(
    'target burns synchronously before noop validation owner/current failure',
    () async {
      final noopServer = _DatesServer(
        initial: const _ServerState(startDate: '2026-10-04'),
        expected: _eeAccess,
      );
      final noopApi = _api(noopServer);
      final noopTarget = (await _access(noopApi)).target!;
      final noopFuture = noopApi.updateWorkItemDates(
        noopTarget,
        mode: WorkItemDatesMode.manual,
        startDate: '2026-10-04',
        dueDate: null,
        onMutationSent: () => fail('no handoff'),
      );
      expect(noopTarget.consumed, isTrue);
      expect((await noopFuture).outcome, WorkItemDatesWriteOutcome.applied);

      final invalidServer = _DatesServer(
        initial: const _ServerState(),
        expected: _eeAccess,
      );
      final invalidApi = _api(invalidServer);
      final invalidTarget = (await _access(invalidApi)).target!;
      final invalidFuture = invalidApi.updateWorkItemDates(
        invalidTarget,
        mode: WorkItemDatesMode.manual,
        startDate: '2026-02-31',
        dueDate: null,
        onMutationSent: () => fail('no handoff'),
      );
      expect(invalidTarget.consumed, isTrue);
      expect(
        (await invalidFuture).outcome,
        WorkItemDatesWriteOutcome.notApplied,
      );

      final ownerServer = _DatesServer(
        initial: const _ServerState(),
        expected: _eeAccess,
      );
      final ownerApi = _api(ownerServer);
      final ownerTarget = (await _access(ownerApi)).target!;
      final otherServer = _DatesServer(
        initial: const _ServerState(),
        expected: const [],
      );
      final otherApi = _api(otherServer);
      final ownerFuture = otherApi.updateWorkItemDates(
        ownerTarget,
        mode: WorkItemDatesMode.manual,
        startDate: null,
        dueDate: null,
        onMutationSent: () => fail('no handoff'),
      );
      expect(ownerTarget.consumed, isTrue);
      await expectLater(ownerFuture, throwsA(_failure(FailureKind.validation)));

      var current = true;
      final currentServer = _DatesServer(
        initial: const _ServerState(),
        expected: _eeAccess,
      );
      final currentApi = _api(currentServer);
      final currentTarget = (await _access(
        currentApi,
        isCurrent: () => current,
      )).target!;
      current = false;
      final currentFuture = currentApi.updateWorkItemDates(
        currentTarget,
        mode: WorkItemDatesMode.manual,
        startDate: null,
        dueDate: null,
        onMutationSent: () => fail('no handoff'),
      );
      expect(currentTarget.consumed, isTrue);
      await expectLater(
        currentFuture,
        throwsA(_failure(FailureKind.cancelled)),
      );

      final closedServer = _DatesServer(
        initial: const _ServerState(),
        expected: _eeAccess,
      );
      final closedApi = _api(closedServer);
      final closedTarget = (await _access(closedApi)).target!;
      closedApi.close();
      final closedFuture = closedApi.updateWorkItemDates(
        closedTarget,
        mode: WorkItemDatesMode.manual,
        startDate: null,
        dueDate: null,
        onMutationSent: () => fail('no handoff'),
      );
      expect(closedTarget.consumed, isTrue);
      await expectLater(closedFuture, throwsA(_failure(FailureKind.cancelled)));
    },
  );

  test(
    'CE fallback is precise and CE clear sends two null keys without isFixed',
    () async {
      final server = _DatesServer(
        initial: const _ServerState(
          edition: WorkItemDatesEdition.ceFixed,
          startDate: '2026-10-01',
          dueDate: '2026-10-02',
        ),
        expected: _ceWrite,
      );
      final api = _api(server);
      final access = await _access(api);
      expect(access.snapshot.edition, WorkItemDatesEdition.ceFixed);
      expect(access.snapshot.mode, WorkItemDatesMode.manual);
      final result = await api.updateWorkItemDates(
        access.target!,
        mode: WorkItemDatesMode.manual,
        startDate: null,
        dueDate: null,
        onMutationSent: () {},
      );
      expect(result.outcome, WorkItemDatesWriteOutcome.applied);
      expect(server.sentWidgets.single.keys.toList(), ['startDate', 'dueDate']);
      expect(
        jsonEncode(server.sentWidgets.single),
        '{"startDate":null,"dueDate":null}',
      );
    },
  );

  test('EE payloads retain exact manual and inherited shapes', () async {
    final manualServer = _DatesServer(
      initial: const _ServerState(),
      expected: _eeWrite,
    );
    final manualApi = _api(manualServer);
    await manualApi.updateWorkItemDates(
      (await _access(manualApi)).target!,
      mode: WorkItemDatesMode.manual,
      startDate: '2026-10-04',
      dueDate: '2026-10-04',
      onMutationSent: () {},
    );
    expect(manualServer.sentWidgets.single, {
      'isFixed': true,
      'startDate': '2026-10-04',
      'dueDate': '2026-10-04',
    });

    final inheritedServer = _DatesServer(
      initial: const _ServerState(),
      expected: _eeWrite,
      inheritedResult: const _ServerState(mode: WorkItemDatesMode.inherited),
    );
    final inheritedApi = _api(inheritedServer);
    await inheritedApi.updateWorkItemDates(
      (await _access(inheritedApi)).target!,
      mode: WorkItemDatesMode.inherited,
      startDate: '2020-01-01',
      dueDate: '2030-01-01',
      onMutationSent: () {},
    );
    expect(inheritedServer.sentWidgets.single, {'isFixed': false});
  });

  test('imprecise probe errors never establish CE', () async {
    final server = _DatesServer(
      initial: const _ServerState(edition: WorkItemDatesEdition.ceFixed),
      expected: _eeAccess,
      probeErrors: [
        {
          'message': 'boom',
          'extensions': {'code': 'INTERNAL'},
        },
      ],
    );
    final api = _api(server);
    final access = await _access(api);
    expect(access.snapshot.edition, isNull);
    expect(access.snapshot.mode, WorkItemDatesMode.unknown);
    expect(access.target, isNull);

    final rollUpServer = _DatesServer(
      initial: const _ServerState(
        edition: WorkItemDatesEdition.ceFixed,
        rollUp: true,
      ),
      expected: _eeAccess,
    );
    final rollUpApi = _api(rollUpServer);
    final rollUp = await _access(rollUpApi);
    expect(rollUp.snapshot.edition, isNull);
    expect(rollUp.snapshot.mode, WorkItemDatesMode.unknown);
    expect(rollUp.snapshot.rollUp, isTrue);
    expect(rollUp.target, isNull);
  });

  test(
    'transport loss and malformed ACK have one handoff and no replay',
    () async {
      for (final transportLoss in [true, false]) {
        final server = _DatesServer(
          initial: const _ServerState(),
          expected: _eeWriteNoConfirm,
          mutationResponder: (server, request, widget) {
            if (transportLoss) {
              throw DioException(
                requestOptions: request,
                type: DioExceptionType.receiveTimeout,
              );
            }
            server.applyRequested(widget);
            return jsonResponse({
              'data': {
                'workItemUpdate': {'errors': <String>[], 'workItem': null},
              },
            });
          },
        );
        final api = _api(server);
        var handoffs = 0;
        final target = (await _access(api)).target!;
        final result = await api.updateWorkItemDates(
          target,
          mode: WorkItemDatesMode.manual,
          startDate: '2026-10-04',
          dueDate: null,
          onMutationSent: () => handoffs++,
        );
        expect(result.outcome, WorkItemDatesWriteOutcome.writeUncertain);
        _expectOneSend(server, handoffs);
        await expectLater(
          api.updateWorkItemDates(
            target,
            mode: WorkItemDatesMode.manual,
            startDate: '2026-10-04',
            dueDate: null,
            onMutationSent: () => fail('no replay'),
          ),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(server.mutationCount, 1);
      }
    },
  );

  test('legitimate clearReadCache does not cancel a valid write', () async {
    final server = _DatesServer(
      initial: const _ServerState(),
      expected: _eeWrite,
    );
    final api = _api(server);
    final target = (await _access(api)).target!;
    api.clearReadCache();
    final result = await api.updateWorkItemDates(
      target,
      mode: WorkItemDatesMode.manual,
      startDate: '2026-10-04',
      dueDate: null,
      onMutationSent: () {},
    );
    expect(result.outcome, WorkItemDatesWriteOutcome.applied);
    expect(server.mutationCount, 1);
  });

  test(
    'date validation is strict UTC 1000..9999 and permits equality',
    () async {
      for (final date in ['1000-01-01', '2028-02-29', '9999-12-31']) {
        final server = _DatesServer(
          initial: const _ServerState(),
          expected: _eeWrite,
        );
        final api = _api(server);
        final result = await api.updateWorkItemDates(
          (await _access(api)).target!,
          mode: WorkItemDatesMode.manual,
          startDate: date,
          dueDate: date,
          onMutationSent: () {},
        );
        expect(result.outcome, WorkItemDatesWriteOutcome.applied);
      }
      for (final dates in [
        ('2026-02-31', null),
        ('2025-02-29', null),
        ('0999-12-31', null),
        ('10000-01-01', null),
        ('2026-10-05', '2026-10-04'),
      ]) {
        final server = _DatesServer(
          initial: const _ServerState(),
          expected: _eeAccess,
        );
        final api = _api(server);
        final result = await api.updateWorkItemDates(
          (await _access(api)).target!,
          mode: WorkItemDatesMode.manual,
          startDate: dates.$1,
          dueDate: dates.$2,
          onMutationSent: () => fail('no handoff'),
        );
        expect(result.outcome, WorkItemDatesWriteOutcome.notApplied);
        expect(result.mutationSent, isFalse);
        expect(server.mutationCount, 0);
      }
    },
  );

  test(
    'missing widget is read-only unknown and does not invent mode',
    () async {
      final server = _DatesServer(
        initial: const _ServerState(widgetPresent: false),
        expected: const [_RequestKind.base],
      );
      final api = _api(server);
      final access = await _access(api);
      expect(access.snapshot.widgetPresent, isFalse);
      expect(access.snapshot.mode, WorkItemDatesMode.unknown);
      expect(access.snapshot.edition, isNull);
      expect(access.target, isNull);
    },
  );

  test('source keeps no global read epoch or strict-newer fallback', () {
    final source = File('lib/core/work_item_dates_api.dart').readAsStringSync();
    expect(source.contains('_readEpoch'), isFalse);
    expect(source.contains('.readEpoch'), isFalse);
    expect(source.contains('clearReadCache'), isFalse);
    final start = source.indexOf('_reportGraphMutationStart(onMutationSent);');
    final gate = source.indexOf('if (mayStart != null && !mayStart())');
    expect(start, greaterThanOrEqualTo(0));
    expect(gate, greaterThan(start));
    expect(source.contains('isAfter(opening.updatedAt)'), isFalse);
  });
}

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((failure) => failure.kind, 'kind', kind);

GitLabApi _api(_DatesServer server) {
  final api = testApi(server.adapter);
  addTearDown(() {
    server.verify();
    api.close();
  });
  return api;
}

Future<WorkItemDatesAccess> _access(
  GitLabApi api, {
  bool Function()? isCurrent,
  String detailState = 'OPEN',
}) => api.workItemDates(
  _detail(state: detailState),
  expectedUserId: 7,
  generation: 4,
  isCurrent: isCurrent ?? () => true,
);

void _expectOneSend(_DatesServer server, int handoffs) {
  expect(handoffs, 1);
  expect(server.mutationCount, 1);
  expect(server.mutationNonces, hasLength(1));
  expect(server.mutationNonces.toSet(), hasLength(1));
}

final class _DatesServer {
  _DatesServer({
    required _ServerState initial,
    required this.expected,
    this.inheritedResult,
    this.beforeFence,
    this.beforeConfirm,
    this.mutationResponder,
    this.applyMutation = true,
    this.probeErrors,
  }) : state = initial {
    adapter = FakeAdapter(_respond);
  }

  late final FakeAdapter adapter;
  _ServerState state;
  final List<_RequestKind> expected;
  final _ServerState? inheritedResult;
  final void Function(_DatesServer server)? beforeFence;
  final void Function(_DatesServer server)? beforeConfirm;
  final _MutationResponder? mutationResponder;
  final bool applyMutation;
  final List<Object?>? probeErrors;
  final List<Object> mutationNonces = [];
  final List<Map<String, Object?>> sentWidgets = [];
  int mutationCount = 0;
  int _consumed = 0;
  int _baseReads = 0;

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    final kind = _requestKind(request);
    expect(_consumed, lessThan(expected.length), reason: 'unexpected request');
    expect(kind, expected[_consumed], reason: 'request $_consumed order');
    _consumed += 1;
    expect(request.followRedirects, isFalse);
    expect(request.maxRedirects, 0);
    expect(request.headers['Cache-Control'], 'no-store');

    if (kind == _RequestKind.base) {
      _baseReads += 1;
      if (_baseReads == 2) beforeFence?.call(this);
      if (_baseReads == 3) beforeConfirm?.call(this);
      return jsonResponse(_readEnvelope(state, ee: false));
    }
    if (kind == _RequestKind.probe) {
      final customErrors = probeErrors;
      if (customErrors != null) return jsonResponse({'errors': customErrors});
      if (state.edition == WorkItemDatesEdition.ceFixed) {
        return jsonResponse({'errors': _ceErrors});
      }
      return jsonResponse(_readEnvelope(state, ee: true));
    }

    mutationCount += 1;
    mutationNonces.add(Object());
    final input = (_variables(request)['input'] as Map<Object?, Object?>)
        .cast<String, Object?>();
    expect(input['id'], _item);
    final widget = (input['startAndDueDateWidget'] as Map<Object?, Object?>)
        .cast<String, Object?>();
    sentWidgets.add(Map<String, Object?>.unmodifiable(widget));
    final custom = mutationResponder;
    if (custom != null) return custom(this, request, widget);
    if (applyMutation) applyRequested(widget);
    return jsonResponse(_ackEnvelope(state));
  }

  void applyRequested(Map<String, Object?> widget) {
    if (widget['isFixed'] == false) {
      state =
          inheritedResult ??
          state.copyWith(
            mode: WorkItemDatesMode.inherited,
            startWorkItem: null,
            dueWorkItem: null,
            startMilestone: null,
            dueMilestone: null,
          );
      return;
    }
    state = state.copyWith(
      mode: WorkItemDatesMode.manual,
      startDate: widget['startDate'],
      dueDate: widget['dueDate'],
      startWorkItem: null,
      dueWorkItem: null,
      startMilestone: null,
      dueMilestone: null,
    );
  }

  void verify() {
    expect(_consumed, expected.length, reason: 'all planned requests consumed');
    expect(adapter.requests, hasLength(expected.length));
  }
}

final class _ServerState {
  const _ServerState({
    this.actor = _actor,
    this.itemId = _item,
    this.iid = '15',
    this.state = 'OPEN',
    this.edition = WorkItemDatesEdition.ee,
    this.mode = WorkItemDatesMode.manual,
    this.startDate,
    this.dueDate,
    this.rollUp = false,
    this.startWorkItem,
    this.dueWorkItem,
    this.startMilestone,
    this.dueMilestone,
    this.updatedAt = _revisionText,
    this.readWorkItem = true,
    this.setWorkItemMetadata = true,
    this.widgetPresent = true,
    this.widgetDefined = true,
    this.projectId = _project,
    this.projectPath = _projectPath,
    this.namespaceId = _namespace,
    this.namespacePath = _projectPath,
    this.typeId = _type,
    this.typeName = 'Task',
  });

  final String actor;
  final String itemId;
  final String iid;
  final String state;
  final WorkItemDatesEdition edition;
  final WorkItemDatesMode mode;
  final String? startDate;
  final String? dueDate;
  final bool rollUp;
  final String? startWorkItem;
  final String? dueWorkItem;
  final String? startMilestone;
  final String? dueMilestone;
  final String updatedAt;
  final Object? readWorkItem;
  final Object? setWorkItemMetadata;
  final bool widgetPresent;
  final bool widgetDefined;
  final String projectId;
  final String projectPath;
  final String namespaceId;
  final String namespacePath;
  final String typeId;
  final String typeName;

  _ServerState copyWith({
    Object? actor = _keep,
    Object? itemId = _keep,
    Object? iid = _keep,
    Object? state = _keep,
    Object? edition = _keep,
    Object? mode = _keep,
    Object? startDate = _keep,
    Object? dueDate = _keep,
    Object? rollUp = _keep,
    Object? startWorkItem = _keep,
    Object? dueWorkItem = _keep,
    Object? startMilestone = _keep,
    Object? dueMilestone = _keep,
    Object? updatedAt = _keep,
    Object? readWorkItem = _keep,
    Object? setWorkItemMetadata = _keep,
    Object? widgetPresent = _keep,
    Object? widgetDefined = _keep,
    Object? projectId = _keep,
    Object? projectPath = _keep,
    Object? namespaceId = _keep,
    Object? namespacePath = _keep,
    Object? typeId = _keep,
    Object? typeName = _keep,
  }) => _ServerState(
    actor: identical(actor, _keep) ? this.actor : actor! as String,
    itemId: identical(itemId, _keep) ? this.itemId : itemId! as String,
    iid: identical(iid, _keep) ? this.iid : iid! as String,
    state: identical(state, _keep) ? this.state : state! as String,
    edition: identical(edition, _keep)
        ? this.edition
        : edition! as WorkItemDatesEdition,
    mode: identical(mode, _keep) ? this.mode : mode! as WorkItemDatesMode,
    startDate: identical(startDate, _keep)
        ? this.startDate
        : startDate as String?,
    dueDate: identical(dueDate, _keep) ? this.dueDate : dueDate as String?,
    rollUp: identical(rollUp, _keep) ? this.rollUp : rollUp! as bool,
    startWorkItem: identical(startWorkItem, _keep)
        ? this.startWorkItem
        : startWorkItem as String?,
    dueWorkItem: identical(dueWorkItem, _keep)
        ? this.dueWorkItem
        : dueWorkItem as String?,
    startMilestone: identical(startMilestone, _keep)
        ? this.startMilestone
        : startMilestone as String?,
    dueMilestone: identical(dueMilestone, _keep)
        ? this.dueMilestone
        : dueMilestone as String?,
    updatedAt: identical(updatedAt, _keep)
        ? this.updatedAt
        : updatedAt! as String,
    readWorkItem: identical(readWorkItem, _keep)
        ? this.readWorkItem
        : readWorkItem,
    setWorkItemMetadata: identical(setWorkItemMetadata, _keep)
        ? this.setWorkItemMetadata
        : setWorkItemMetadata,
    widgetPresent: identical(widgetPresent, _keep)
        ? this.widgetPresent
        : widgetPresent! as bool,
    widgetDefined: identical(widgetDefined, _keep)
        ? this.widgetDefined
        : widgetDefined! as bool,
    projectId: identical(projectId, _keep)
        ? this.projectId
        : projectId! as String,
    projectPath: identical(projectPath, _keep)
        ? this.projectPath
        : projectPath! as String,
    namespaceId: identical(namespaceId, _keep)
        ? this.namespaceId
        : namespaceId! as String,
    namespacePath: identical(namespacePath, _keep)
        ? this.namespacePath
        : namespacePath! as String,
    typeId: identical(typeId, _keep) ? this.typeId : typeId! as String,
    typeName: identical(typeName, _keep) ? this.typeName : typeName! as String,
  );
}

_RequestKind _requestKind(RequestOptions request) {
  final query = _query(request);
  if (query.startsWith('query MobileWorkItemDatesBase')) {
    return _RequestKind.base;
  }
  if (query.startsWith('query MobileWorkItemDatesProbe')) {
    return _RequestKind.probe;
  }
  if (query.startsWith('mutation MobileSetWorkItemDates')) {
    return _RequestKind.mutation;
  }
  throw StateError('unexpected query');
}

String _query(RequestOptions request) =>
    (request.data as Map<Object?, Object?>)['query'] as String;

Map<String, Object?> _variables(RequestOptions request) =>
    ((request.data as Map<Object?, Object?>)['variables']
            as Map<Object?, Object?>)
        .cast<String, Object?>();

Map<String, Object?> _readEnvelope(_ServerState state, {required bool ee}) => {
  'data': {
    'currentUser': {'id': state.actor},
    'workItem': _node(state, ee: ee),
  },
};

Map<String, Object?> _ackEnvelope(
  _ServerState state, {
  bool omitStartDate = false,
  bool omitDueDate = false,
  bool omitStartSource = false,
  Object? widgets = _keep,
  bool duplicateWidgets = false,
}) {
  final node = _node(
    state,
    ee: state.edition == WorkItemDatesEdition.ee,
    includePermissions: false,
    omitStartDate: omitStartDate,
    omitDueDate: omitDueDate,
    omitStartSource: omitStartSource,
    widgets: widgets,
    duplicateWidgets: duplicateWidgets,
  );
  return {
    'data': {
      'workItemUpdate': {'errors': <String>[], 'workItem': node},
    },
  };
}

Map<String, Object?> _node(
  _ServerState state, {
  bool ee = false,
  bool includePermissions = true,
  bool omitStartDate = false,
  bool omitDueDate = false,
  bool omitStartSource = false,
  Object? widgets = _keep,
  bool duplicateWidgets = false,
}) {
  final widget = <String, Object?>{
    'type': 'START_AND_DUE_DATE',
    if (!omitStartDate) 'startDate': state.startDate,
    if (!omitDueDate) 'dueDate': state.dueDate,
    'rollUp': state.rollUp,
    if (ee) 'isFixed': state.mode == WorkItemDatesMode.manual,
    if (ee && !omitStartSource)
      'startDateSourcingWorkItem': state.startWorkItem == null
          ? null
          : {'id': state.startWorkItem},
    if (ee)
      'dueDateSourcingWorkItem': state.dueWorkItem == null
          ? null
          : {'id': state.dueWorkItem},
    if (ee)
      'startDateSourcingMilestone': state.startMilestone == null
          ? null
          : {'id': state.startMilestone},
    if (ee)
      'dueDateSourcingMilestone': state.dueMilestone == null
          ? null
          : {'id': state.dueMilestone},
  };
  final Object? widgetCollection;
  if (!identical(widgets, _keep)) {
    widgetCollection = widgets;
  } else if (!state.widgetPresent) {
    widgetCollection = <Object?>[];
  } else if (duplicateWidgets) {
    widgetCollection = [widget, Map<String, Object?>.from(widget)];
  } else {
    widgetCollection = [widget];
  }
  return {
    'id': state.itemId,
    'iid': state.iid,
    'title': 'Mobile parity',
    'state': state.state,
    'createdAt': _created.toIso8601String(),
    'updatedAt': state.updatedAt,
    'project': {'id': state.projectId, 'fullPath': state.projectPath},
    'namespace': {'id': state.namespaceId, 'fullPath': state.namespacePath},
    'workItemType': {
      'id': state.typeId,
      'name': state.typeName,
      'widgetDefinitions': [
        if (state.widgetDefined) {'type': 'START_AND_DUE_DATE'},
      ],
    },
    if (includePermissions)
      'userPermissions': {
        'readWorkItem': state.readWorkItem,
        'setWorkItemMetadata': state.setWorkItemMetadata,
      },
    'widgets': widgetCollection,
  };
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

WorkItemGraphDetail _detail({String state = 'OPEN'}) => WorkItemGraphDetail(
  summary: WorkItemGraphSummary(
    id: _item,
    iid: 15,
    title: 'Mobile parity',
    state: state,
    createdAt: _created,
    updatedAt: _revision,
    project: const GraphResourceRef(id: _project, fullPath: _projectPath),
    namespace: const GraphResourceRef(id: _namespace, fullPath: _projectPath),
    type: const WorkItemGraphType(id: _type, name: 'Task'),
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
