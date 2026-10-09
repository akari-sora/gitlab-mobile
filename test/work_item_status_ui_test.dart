import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_state_models.dart';
import 'package:gitlab_mobile/core/work_item_status_models.dart';
import 'package:gitlab_mobile/features/workspace/work_item_status.dart';

import 'support/widget_settle.dart';
import 'support/work_item_status_fixture.dart';

const _edit = ValueKey('work-item-status-edit');
const _save = ValueKey('work-item-status-save');
const _result = ValueKey('work-item-status-result');
const _reopenHint = ValueKey('work-item-status-reopen-hint');
const _todo = WorkItemStatusFixture.statusTodo;
const _doing = WorkItemStatusFixture.statusDoing;
const _done = WorkItemStatusFixture.statusDone;
const _start = WorkItemStatusWritePhase.start;
const _settle = WorkItemStatusWritePhase.settle;

void main() {
  testWidgets(
    'project and group items with the same IID read and write only their exact scope',
    (tester) async {
      for (final group in [false, true]) {
        final h = await _mount(tester, group: group);
        final id = group
            ? WorkItemStatusFixture.groupItemId
            : WorkItemStatusFixture.projectItemId;
        final other = h.fixture.item(group: !group);
        final otherBefore = (
          other.updatedAt,
          other.lockVersion,
          other.assignment?.id,
          other.state,
        );
        final openingDetail = h.state.detail;
        final openingApi = h.state.api;
        final openingAccount = h.state.account;

        await _open(tester);
        expect(find.text('@ada · https://example.com/gitlab'), findsOneWidget);
        expect(
          find.text(
            group ? 'studio/group · 工作項目 #17' : 'studio/mobile · 工作項目 #17',
          ),
          findsOneWidget,
        );
        expect(h.fixture.requests.single.workItemId, id);

        await _choose(tester, _doing);
        expect(find.text('將套用：進行中'), findsOneWidget);
        await _tapSave(tester);
        await _until(tester, () => h.recorder.saved.isNotEmpty);

        expect(h.fixture.mutationInputs, [
          {
            'id': id,
            'statusWidget': {'status': _doing},
          },
        ]);
        expect(h.fixture.requests.map((request) => request.kind), [
          StatusFixtureRequestKind.read,
          StatusFixtureRequestKind.read,
          StatusFixtureRequestKind.mutation,
          StatusFixtureRequestKind.read,
        ]);
        final result = h.recorder.saved.single;
        expect(result.status, WorkItemStatusSaveStatus.success);
        expect(result.mutationSent, isTrue);
        expect(result.handoff, WorkItemStatusHandoff.started);
        expect(result.snapshot.id, id);
        expect(result.snapshot.generation, 12);
        expect(result.snapshot.assignment.id, _doing);
        expect(find.text('已確認狀態：進行中 · 開啟中'), findsOneWidget);

        _expectOneTerminal(h.recorder);
        final start = h.recorder.phases.first;
        expect(start.api, same(openingApi));
        expect(start.account, same(openingAccount));
        expect(start.detail, same(openingDetail));
        expect(start.generation, 12);
        expect(h.recorder.phases.last.api, same(openingApi));
        expect(h.recorder.phases.last.detail, same(openingDetail));
        expect((
          other.updatedAt,
          other.lockVersion,
          other.assignment?.id,
          other.state,
        ), otherBefore);
        expect(h.fixture.unhandled, isEmpty);
      }
    },
  );

  testWidgets(
    'the complete server-ordered list shows neutral unknown metadata without search or Clear',
    (tester) async {
      final fixture = WorkItemStatusFixture();
      final members = <StatusFixtureMember>[
        for (var number = 1; number <= 40; number++)
          StatusFixtureMember(
            id: WorkItemStatusFixture.customStatusId(100 + number),
            name: number == 2 ? null : '狀態 $number',
            iconName: number == 3 ? 'javascript:alert(1)' : null,
            color: switch (number) {
              4 => 'url(evil)',
              5 => '#12AB34',
              _ => null,
            },
            position: 40 - number,
            description: number == 6 ? '很長的伺服器說明' * 40 : null,
            category: number == 7 ? 'FUTURE_CATEGORY' : null,
          ),
      ];
      fixture.item(group: false)
        ..members = members
        ..assignment = members[9];
      final h = await _mount(tester, fixture: fixture);
      await _open(tester);

      expect(find.byType(EditableText), findsNothing);
      expect(find.textContaining('搜尋'), findsNothing);
      expect(find.textContaining('清除'), findsNothing);
      expect(find.textContaining('移除'), findsNothing);
      expect(find.text('目前狀態：狀態 10'), findsOneWidget);

      final seen = <String>[];
      for (var step = 0; step < 60; step++) {
        final visible = _visibleChoiceIds(tester);
        final indexes = [
          for (final id in visible) members.indexWhere((m) => m.id == id),
        ];
        for (var index = 1; index < indexes.length; index++) {
          expect(indexes[index], indexes[index - 1] + 1);
        }
        for (final id in visible) {
          if (!seen.contains(id)) seen.add(id);
        }
        if (seen.length == members.length) break;
        await tester.drag(_editorScroll(), const Offset(0, -240));
        await tester.pump();
      }
      expect(seen, [for (final member in members) member.id]);

      Finder row(int number) => find.byKey(
        ValueKey('work-item-status-choice-${members[number - 1].id}'),
      );
      await tester.scrollUntilVisible(
        row(2),
        -240,
        scrollable: _editorScroll(),
      );
      expect(
        find.descendant(of: row(2), matching: find.text('未命名狀態')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row(2), matching: find.textContaining('分類：未提供')),
        findsOneWidget,
      );
      final dot4 = tester.widget<Icon>(
        find.byKey(ValueKey('work-item-status-dot-${members[3].id}')),
      );
      final dot5 = tester.widget<Icon>(
        find.byKey(ValueKey('work-item-status-dot-${members[4].id}')),
      );
      final theme = Theme.of(tester.element(find.byKey(_save)));
      expect(dot4.color, theme.colorScheme.outline);
      expect(dot5.color, const Color(0xFF12AB34));
      await tester.scrollUntilVisible(
        row(7),
        120,
        scrollable: _editorScroll(),
      );
      expect(
        find.descendant(
          of: row(7),
          matching: find.textContaining('分類：FUTURE_CATEGORY'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('javascript'), findsNothing);
      expect(find.textContaining('url(evil)'), findsNothing);

      await _choose(tester, members.last.id!);
      await _tapSave(tester);
      await _until(tester, () => h.recorder.saved.isNotEmpty);
      expect(
        h.fixture.mutationInputs.single['statusWidget'],
        {'status': members.last.id},
      );
      expect(tester.takeException(), isNull);
      expect(h.fixture.unhandled, isEmpty);
    },
  );

  testWidgets('explicit null shows 未設定 and saves a non-null candidate', (
    tester,
  ) async {
    final fixture = WorkItemStatusFixture();
    fixture.item(group: false).assignment = null;
    final h = await _mount(tester, fixture: fixture);
    await _open(tester);
    expect(find.text('目前狀態：未設定'), findsOneWidget);
    await _choose(tester, _doing);
    await _tapSave(tester);
    await _until(tester, () => h.recorder.saved.isNotEmpty);
    final result = h.recorder.saved.single;
    expect(result.status, WorkItemStatusSaveStatus.success);
    expect(
      result.snapshot.assignment.kind,
      WorkItemStatusAssignmentKind.identified,
    );
    expect(result.snapshot.assignment.id, _doing);
    expect(h.fixture.mutations, 1);
    _expectOneTerminal(h.recorder);
  });

  testWidgets(
    'unidentified assignment, no metadata permission and an empty list keep the writer disabled',
    (tester) async {
      final cases = <String, void Function(StatusFixtureItem item)>{
        '目前狀態沒有可識別的伺服器 ID，無法安全變更。': (item) => item.assignment =
            const StatusFixtureMember(
              id: null,
              name: '舊狀態',
              category: 'LEGACY',
            ),
        '目前帳號沒有變更狀態的權限。': (item) => item.setWorkItemMetadata = false,
        '這個工作項目沒有可選擇的狀態。': (item) => item
          ..assignment = null
          ..members = const [],
      };
      for (final entry in cases.entries) {
        final fixture = WorkItemStatusFixture();
        entry.value(fixture.item(group: false));
        final h = await _mount(tester, fixture: fixture);
        await _open(tester);
        expect(find.text(entry.key), findsOneWidget, reason: entry.key);
        expect(
          tester.widget<FilledButton>(find.byKey(_save)).onPressed,
          isNull,
        );
        if (fixture.item(group: false).members!.isNotEmpty) {
          await tester.tap(
            find.byKey(const ValueKey('work-item-status-choice-$_doing')),
            warnIfMissed: false,
          );
          await tester.pump();
          expect(find.textContaining('將套用'), findsNothing);
        }
        expect(h.fixture.mutations, 0);
        expect(h.recorder.phases, isEmpty);
      }
      expect(find.text('目前狀態：未設定'), findsOneWidget);

      final unidentified = WorkItemStatusFixture();
      unidentified.item(group: false).assignment = const StatusFixtureMember(
        id: null,
        name: '舊狀態',
      );
      await _mount(tester, fixture: unidentified);
      await _open(tester);
      expect(find.text('目前狀態：識別未知（舊狀態）'), findsOneWidget);
    },
  );

  testWidgets(
    'unsupported or malformed schema stays editor-only and retry opens after repair',
    (tester) async {
      final drifts = <String, void Function(StatusFixtureItem item)>{
        'definition missing': (item) => item.statusDefinitionPresent = false,
        'duplicate definition': (item) => item.duplicateStatusDefinition = true,
        'allowed list null': (item) => item.members = null,
        'widget missing': (item) => item.statusWidgetPresent = false,
        'member without id': (item) => item.members = [
          ...WorkItemStatusFixture.defaultMembers,
          const StatusFixtureMember(id: null, name: '無識別'),
        ],
        'string permission': (item) => item.setWorkItemMetadata = 'true',
      };
      for (final entry in drifts.entries) {
        final fixture = WorkItemStatusFixture();
        entry.value(fixture.item(group: false));
        final h = await _mount(tester, fixture: fixture);
        await tester.tap(find.byKey(_edit));
        await settleNetworkWidgets(tester);
        expect(
          find.text('這個工作項目無法安全編輯狀態'),
          findsOneWidget,
          reason: entry.key,
        );
        expect(find.byKey(_save), findsNothing, reason: entry.key);
        expect(h.recorder.routes, isEmpty, reason: entry.key);
        expect(h.fixture.mutations, 0);
        expect(h.recorder.phases, isEmpty);
      }

      final fixture = WorkItemStatusFixture();
      fixture.item(group: false).statusDefinitionPresent = false;
      final h = await _mount(tester, fixture: fixture);
      await tester.tap(find.byKey(_edit));
      await settleNetworkWidgets(tester);
      fixture.item(group: false).statusDefinitionPresent = true;
      await tester.tap(find.text('重新整理'));
      await settleNetworkWidgets(tester);
      expect(find.byKey(_save), findsOneWidget);
      expect(h.recorder.routes, hasLength(1));
      expect(fixture.reads, 2);
    },
  );

  testWidgets(
    'the close or reopen warning is shown and only the authoritative read sets lifecycle',
    (tester) async {
      for (final reopen in [false, true]) {
        final fixture = WorkItemStatusFixture();
        final item = fixture.item(group: false);
        if (reopen) {
          item
            ..state = 'CLOSED'
            ..assignment = WorkItemStatusFixture.defaultMembers[2]
            ..reopensOn.add(_doing);
        }
        final h = await _mount(tester, fixture: fixture);
        await _open(tester);
        expect(
          find.text(reopen ? '目前生命週期：已關閉' : '目前生命週期：開啟中'),
          findsOneWidget,
        );
        expect(
          find.text(
            '套用狀態時，GitLab 可能會關閉或重新開啟這個工作項目。'
            '最終狀態與開啟／關閉以儲存後重新讀取的伺服器結果為準。',
          ),
          findsOneWidget,
        );
        await _choose(tester, reopen ? _doing : _done);
        expect(find.textContaining('將關閉'), findsNothing);
        expect(find.textContaining('將重新開啟'), findsNothing);
        await _tapSave(tester);
        await _until(tester, () => h.recorder.saved.isNotEmpty);
        final result = h.recorder.saved.single;
        expect(
          result.snapshot.state,
          reopen ? WorkItemState.open : WorkItemState.closed,
        );
        expect(item.state, reopen ? 'OPEN' : 'CLOSED');
        expect(
          find.text(reopen ? '已確認狀態：進行中 · 開啟中' : '已確認狀態：完成 · 已關閉'),
          findsOneWidget,
        );
      }
    },
  );

  testWidgets('a same-second acknowledgement with exact readback succeeds', (
    tester,
  ) async {
    final fixture = WorkItemStatusFixture()..advanceSeconds = 0;
    final h = await _mount(tester, fixture: fixture);
    await _open(tester);
    await _choose(tester, _doing);
    await _tapSave(tester);
    await _until(tester, () => h.recorder.saved.isNotEmpty);
    final result = h.recorder.saved.single;
    expect(result.status, WorkItemStatusSaveStatus.success);
    expect(result.snapshot.updatedAt, WorkItemStatusFixture.openedAt);
    expect(result.acknowledgement!.updatedAt, result.snapshot.updatedAt);
    expect(
      statusFixtureTimestamp(fixture.item(group: false).updatedAt),
      '2026-10-04T04:00:00Z',
    );
    expect(fixture.item(group: false).lockVersion, 9);
  });

  testWidgets('choosing the current status sends nothing and emits no phases', (
    tester,
  ) async {
    final h = await _mount(tester);
    await _open(tester);
    await _choose(tester, _todo);
    expect(find.text('已是目前狀態，儲存不會送出變更。'), findsOneWidget);
    await _tapSave(tester);
    await _until(tester, () => h.recorder.saved.isNotEmpty);
    final result = h.recorder.saved.single;
    expect(result.status, WorkItemStatusSaveStatus.noop);
    expect(result.mutationSent, isFalse);
    expect(result.handoff, WorkItemStatusHandoff.none);
    expect(h.recorder.phases, isEmpty);
    expect(h.fixture.mutations, 0);
    expect(h.fixture.reads, 2);
    expect(find.text('狀態未變更：待處理 · 開啟中'), findsOneWidget);
  });

  testWidgets(
    'APPLY and ACK holds keep START until the actual terminal and block parent probes',
    (tester) async {
      final h = await _mount(tester);
      final apply = Completer<void>();
      final ack = Completer<void>();
      h.fixture
        ..holdBeforeApply = apply
        ..holdAck = ack;
      try {
        await _open(tester);
        await _choose(tester, _doing);
        await _tapSave(tester);
        await _until(tester, () => h.fixture.awaitingApply);

        expect(_kinds(h.recorder), [_start]);
        expect(h.recorder.pendingToken, same(h.recorder.phases.first.token));
        expect(h.fixture.item(group: false).assignment!.id, _todo);
        expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
        expect(
          tester
              .widget<TextButton>(find.byKey(_edit, skipOffstage: false))
              .onPressed,
          isNull,
        );
        expect(find.text('變更中…', skipOffstage: false), findsOneWidget);
        expect(h.recorder.attemptLifecycle(), isFalse);
        expect(h.recorder.attemptRefresh(), isFalse);
        await tester.tap(find.byKey(_save), warnIfMissed: false);
        await tester.pump();
        expect(h.fixture.mutations, 1);

        apply.complete();
        await _until(tester, () => h.fixture.awaitingAck);
        expect(h.fixture.item(group: false).assignment!.id, _doing);
        expect(h.fixture.appliedMutationNonces, [1]);
        expect(_kinds(h.recorder), [_start]);
        expect(h.recorder.saved, isEmpty);
        expect(h.recorder.attemptLifecycle(), isFalse);

        ack.complete();
        await _until(tester, () => h.recorder.saved.isNotEmpty);
        _expectOneTerminal(h.recorder);
        expect(h.recorder.pendingToken, isNull);
        expect(h.recorder.attemptLifecycle(), isTrue);
        expect(h.recorder.attemptRefresh(), isTrue);
        expect(h.recorder.lifecycleAttempts, [false, false, true]);
        expect(h.recorder.refreshAttempts, [false, true]);
        final mutation = h.fixture.requests.firstWhere(
          (request) => request.kind == StatusFixtureRequestKind.mutation,
        );
        expect(h.fixture.requests.last.kind, StatusFixtureRequestKind.read);
        expect(h.fixture.requests.last.nonce, greaterThan(mutation.nonce));
        expect(
          tester.widget<TextButton>(find.byKey(_edit)).onPressed,
          isNotNull,
        );
      } finally {
        h.fixture.releaseHolds();
      }
    },
  );

  testWidgets('a lost ACK is uncertain, consumed and never replayed', (
    tester,
  ) async {
    final h = await _mount(tester);
    h.fixture.loseNextAck = true;
    await _open(tester);
    await _choose(tester, _doing);
    await _tapSave(tester);
    await _until(tester, () => h.recorder.phases.length == 2);
    await tester.pump();

    _expectOneTerminal(h.recorder);
    expect(find.text('尚未確認狀態是否已更新'), findsOneWidget);
    expect(find.textContaining('不要重複送出'), findsWidgets);
    expect(find.byKey(_reopenHint), findsOneWidget);
    expect(find.text('重新整理'), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
    expect(h.fixture.mutations, 1);
    expect(h.fixture.reads, 2);
    expect(h.fixture.item(group: false).assignment!.id, _doing);
    await tester.tap(find.byKey(_save), warnIfMissed: false);
    await tester.pump();
    expect(h.fixture.mutations, 1);
    expect(h.recorder.saved, isEmpty);

    await tester.pageBack();
    await settleNetworkWidgets(tester);
    await _open(tester);
    expect(find.text('目前狀態：進行中'), findsOneWidget);
    expect(h.fixture.mutations, 1);
  });

  testWidgets('a server rejection is a consumed validation failure', (
    tester,
  ) async {
    final h = await _mount(tester);
    h.fixture.rejectNextMutation = const ['Status transition denied'];
    await _open(tester);
    await _choose(tester, _doing);
    await _tapSave(tester);
    await _until(tester, () => h.recorder.phases.length == 2);
    await tester.pump();
    _expectOneTerminal(h.recorder);
    expect(find.text('GitLab 未接受狀態更新'), findsOneWidget);
    expect(find.textContaining('沒有重送'), findsOneWidget);
    expect(h.fixture.mutations, 1);
    expect(h.fixture.reads, 2);
    expect(h.fixture.item(group: false).assignment!.id, _todo);
    expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
    expect(h.recorder.saved, isEmpty);
  });

  testWidgets('confirm drift after an applied ACK is uncertain', (
    tester,
  ) async {
    final h = await _mount(tester);
    final ack = Completer<void>();
    h.fixture.holdAck = ack;
    try {
      await _open(tester);
      await _choose(tester, _doing);
      await _tapSave(tester);
      await _until(tester, () => h.fixture.awaitingAck);
      h.fixture.beforeNextRead = (fixture) => fixture.touch(group: false);
      ack.complete();
      await _until(tester, () => h.recorder.phases.length == 2);
      await tester.pump();
      _expectOneTerminal(h.recorder);
      expect(find.text('尚未確認狀態是否已更新'), findsOneWidget);
      expect(h.recorder.saved, isEmpty);
      expect(h.fixture.mutations, 1);
      expect(h.fixture.reads, 3);
    } finally {
      h.fixture.releaseHolds();
    }
  });

  testWidgets('every preflight drift sends zero and emits no phases', (
    tester,
  ) async {
    final drifts = <String, void Function(WorkItemStatusFixture fixture)>{
      'revision': (fixture) => fixture.touch(group: false),
      'lock version': (fixture) => fixture.item(group: false).lockVersion++,
      'assigned status': (fixture) => fixture.item(group: false).assignment =
          WorkItemStatusFixture.defaultMembers[3],
      'lifecycle': (fixture) => fixture.item(group: false).state = 'CLOSED',
      'member order': (fixture) => fixture.item(group: false).members = [
        ...WorkItemStatusFixture.defaultMembers.reversed,
      ],
      'selected member removed': (fixture) => fixture
          .item(group: false)
          .members = WorkItemStatusFixture.defaultMembers
          .where((member) => member.id != _doing)
          .toList(),
      'metadata permission': (fixture) =>
          fixture.item(group: false).setWorkItemMetadata = false,
      'actor': (fixture) => fixture.actorUserId = 8,
      'namespace scope': (fixture) => fixture.item(group: false).namespace =
          const GraphResourceRef(
            id: 'gid://gitlab/Namespaces::ProjectNamespace/99',
            fullPath: 'other/project',
          ),
      'type': (fixture) =>
          fixture.item(group: false).typeId = 'gid://gitlab/WorkItems::Type/99',
      'widget schema': (fixture) =>
          fixture.item(group: false).statusWidgetPresent = false,
      'definition schema': (fixture) =>
          fixture.item(group: false).statusDefinitionPresent = false,
    };
    for (final entry in drifts.entries) {
      final h = await _mount(tester);
      await _open(tester);
      await _choose(tester, _doing);
      h.fixture.beforeNextRead = entry.value;
      await _tapSave(tester);
      await _until(
        tester,
        () => find.byKey(_reopenHint).evaluate().isNotEmpty,
      );
      expect(h.fixture.mutations, 0, reason: entry.key);
      expect(h.fixture.reads, 2, reason: entry.key);
      expect(h.recorder.phases, isEmpty, reason: entry.key);
      expect(h.recorder.saved, isEmpty, reason: entry.key);
      expect(
        tester.widget<FilledButton>(find.byKey(_save)).onPressed,
        isNull,
        reason: entry.key,
      );
    }
  });

  testWidgets(
    'a throwing START listener sends zero and still settles from the Save Future',
    (tester) async {
      final h = await _mount(tester);
      h.recorder.throwOnStart = true;
      await _open(tester);
      await _choose(tester, _doing);
      await _tapSave(tester);
      await _until(tester, () => h.recorder.phases.length == 2);
      await tester.pump();
      _expectOneTerminal(h.recorder);
      expect(h.recorder.pendingToken, isNull);
      expect(h.fixture.mutations, 0);
      expect(h.fixture.requests.map((request) => request.kind), [
        StatusFixtureRequestKind.read,
        StatusFixtureRequestKind.read,
      ]);
      expect(find.text('狀態沒有送出'), findsOneWidget);
      expect(find.textContaining('在送出前停止'), findsOneWidget);
      expect(h.fixture.item(group: false).assignment!.id, _todo);
      expect(h.recorder.saved, isEmpty);
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
      expect(
        tester
            .widget<TextButton>(find.byKey(_edit, skipOffstage: false))
            .onPressed,
        isNotNull,
      );
    },
  );

  for (final removal in _Removal.values) {
    for (final hold in _Hold.values) {
      testWidgets(
        '${removal.name} during ${hold.name} settles once from the actual Future',
        (tester) async {
          final h = await _mount(tester);
          final gate = Completer<void>();
          if (hold == _Hold.apply) {
            h.fixture.holdBeforeApply = gate;
          } else {
            h.fixture.holdAck = gate;
          }
          try {
            await _open(tester);
            await _choose(tester, _doing);
            await _tapSave(tester);
            await _until(
              tester,
              () => hold == _Hold.apply
                  ? h.fixture.awaitingApply
                  : h.fixture.awaitingAck,
            );
            expect(_kinds(h.recorder), [_start]);
            final route = h.recorder.routes.single;
            final startToken = h.recorder.phases.single.token;

            await _remove(tester, h, removal);
            await _frames(tester);
            expect(route.isActive, isFalse);
            if (removal == _Removal.closeApi) {
              await _until(tester, () => h.recorder.phases.length == 2);
            } else {
              expect(_kinds(h.recorder), [_start]);
            }
            expect(h.fixture.mutations, 1);

            gate.complete();
            await _until(tester, () => h.recorder.phases.length == 2);
            await settleNetworkWidgets(tester);
            _expectOneTerminal(h.recorder);
            expect(h.recorder.phases.last.token, same(startToken));
            expect(h.recorder.saved, isEmpty);
            expect(find.byKey(_result), findsNothing);
            expect(find.textContaining('已確認狀態'), findsNothing);
            expect(h.fixture.item(group: false).assignment!.id, _doing);
            expect(h.fixture.mutations, 1);
            expect(tester.takeException(), isNull);
          } finally {
            h.fixture.releaseHolds();
          }
        },
      );
    }
  }

  testWidgets(
    'owner, API or session change during preflight sends zero and emits nothing',
    (tester) async {
      for (final removal in [
        _Removal.closeApi,
        _Removal.replaceApi,
        _Removal.sessionChange,
        _Removal.routeGeneration,
      ]) {
        final h = await _mount(tester);
        final read = Completer<void>();
        try {
          await _open(tester);
          await _choose(tester, _doing);
          h.fixture.holdNextRead = read;
          await _tapSave(tester);
          await _until(tester, () => h.fixture.reads == 2);
          final route = h.recorder.routes.single;
          await _remove(tester, h, removal);
          await _frames(tester);
          expect(route.isActive, isFalse, reason: removal.name);
          read.complete();
          await settleNetworkWidgets(tester);
          expect(h.fixture.mutations, 0, reason: removal.name);
          expect(h.recorder.phases, isEmpty, reason: removal.name);
          expect(h.recorder.saved, isEmpty, reason: removal.name);
          expect(find.byKey(_result), findsNothing);
        } finally {
          h.fixture.releaseHolds();
        }
      }
    },
  );

  testWidgets(
    'a pending write survives owner away and back and blocks a second editor',
    (tester) async {
      final h = await _mount(tester);
      final ack = Completer<void>();
      h.fixture.holdAck = ack;
      try {
        await _open(tester);
        await _choose(tester, _doing);
        await _tapSave(tester);
        await _until(tester, () => h.fixture.awaitingAck);
        h.state.replace(() => h.state.current = false);
        h.state.owner.ping();
        await _frames(tester);
        expect(find.byKey(_save), findsNothing);
        h.state.replace(() => h.state.current = true);
        h.state.owner.ping();
        await _frames(tester);
        expect(tester.widget<TextButton>(find.byKey(_edit)).onPressed, isNull);
        expect(h.fixture.reads, 2);
        expect(_kinds(h.recorder), [_start]);
        ack.complete();
        await _until(tester, () => h.recorder.phases.length == 2);
        await tester.pump();
        _expectOneTerminal(h.recorder);
        expect(h.recorder.saved, isEmpty);
        expect(
          tester.widget<TextButton>(find.byKey(_edit)).onPressed,
          isNotNull,
        );
        await _open(tester);
        expect(find.text('目前狀態：進行中'), findsOneWidget);
        expect(h.fixture.mutations, 1);
      } finally {
        h.fixture.releaseHolds();
      }
    },
  );

  testWidgets(
    'a newer parent revision after a successful save clears the stale result line and the matching revision keeps it',
    (tester) async {
      final h = await _mount(tester);
      await _open(tester);
      await _choose(tester, _doing);
      await _tapSave(tester);
      await _until(tester, () => h.recorder.saved.isNotEmpty);
      await settleNetworkWidgets(tester);
      final result = h.recorder.saved.single;
      expect(result.status, WorkItemStatusSaveStatus.success);
      expect(find.text('已確認狀態：進行中 · 開啟中'), findsOneWidget);

      final confirmed = h.fixture.detail(group: false);
      expect(
        confirmed.summary.updatedAt.isAtSameMomentAs(result.snapshot.updatedAt),
        isTrue,
      );
      expect(
        confirmed.summary.updatedAt,
        isNot(h.state.detail.summary.updatedAt),
      );
      h.state.replace(() => h.state.detail = confirmed);
      await _frames(tester);
      expect(find.byKey(_result), findsOneWidget);
      expect(find.text('已確認狀態：進行中 · 開啟中'), findsOneWidget);

      h.state.replace(() => h.state.detail = h.fixture.detail(group: false));
      await _frames(tester);
      expect(find.byKey(_result), findsOneWidget);
      expect(find.text('已確認狀態：進行中 · 開啟中'), findsOneWidget);

      h.fixture.touch(group: false);
      final newer = h.fixture.detail(group: false);
      expect(newer.summary.updatedAt.isAfter(result.snapshot.updatedAt), isTrue);
      h.state.replace(() => h.state.detail = newer);
      await _frames(tester);
      expect(find.byKey(_result), findsNothing);
      expect(find.textContaining('已確認狀態'), findsNothing);
      expect(find.text('已確認狀態：進行中 · 開啟中'), findsNothing);

      expect(h.recorder.saved, hasLength(1));
      _expectOneTerminal(h.recorder);
      expect(h.fixture.mutations, 1);
      expect(h.fixture.reads, 3);
      expect(h.fixture.appliedMutationNonces, [1]);
      expect(h.fixture.item(group: false).state, 'OPEN');
      expect(tester.widget<TextButton>(find.byKey(_edit)).onPressed, isNotNull);
      expect(h.fixture.unhandled, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'replacing only the write listener while the editor is open keeps START and SETTLE on the captured callback',
    (tester) async {
      final h = await _mount(tester);
      final newer = _Recorder();
      final ack = Completer<void>();
      h.fixture.holdAck = ack;
      try {
        final openingAccount = h.state.account;
        final openingApi = h.state.api;
        final openingDetail = h.state.detail;
        await _open(tester);
        final route = h.recorder.routes.single;

        h.state.replace(() => h.state.listener = newer.listen);
        await _frames(tester);
        expect(route.isActive, isTrue);
        expect(find.byKey(_save), findsOneWidget);
        expect(h.recorder.phases, isEmpty);
        expect(newer.phases, isEmpty);

        await _choose(tester, _doing);
        await _tapSave(tester);
        await _until(tester, () => h.fixture.awaitingAck);
        expect(_kinds(h.recorder), [_start]);
        expect(h.recorder.pendingToken, same(h.recorder.phases.single.token));
        expect(newer.phases, isEmpty);
        expect(newer.pendingToken, isNull);
        expect(h.recorder.attemptLifecycle(), isFalse);
        expect(h.fixture.appliedMutationNonces, [1]);
        expect(h.recorder.saved, isEmpty);

        ack.complete();
        await _until(tester, () => h.recorder.saved.isNotEmpty);
        _expectOneTerminal(h.recorder);
        final start = h.recorder.phases.first;
        expect(start.account, same(openingAccount));
        expect(start.api, same(openingApi));
        expect(start.detail, same(openingDetail));
        expect(start.generation, 12);
        expect(h.recorder.pendingToken, isNull);
        expect(h.recorder.attemptLifecycle(), isTrue);
        expect(newer.phases, isEmpty);
        expect(newer.pendingToken, isNull);

        final saved = h.recorder.saved.single;
        expect(saved.status, WorkItemStatusSaveStatus.success);
        expect(saved.mutationSent, isTrue);
        expect(saved.handoff, WorkItemStatusHandoff.started);
        expect(h.fixture.mutations, 1);
        expect(h.fixture.requests.map((request) => request.kind), [
          StatusFixtureRequestKind.read,
          StatusFixtureRequestKind.read,
          StatusFixtureRequestKind.mutation,
          StatusFixtureRequestKind.read,
        ]);
        expect(h.fixture.unhandled, isEmpty);
      } finally {
        h.fixture.releaseHolds();
      }
    },
  );

  testWidgets('a non-current owner or parent-pending write cannot open', (
    tester,
  ) async {
    final h = await _mount(tester);
    final press = tester.widget<TextButton>(find.byKey(_edit)).onPressed!;
    h.state.current = false;
    press();
    await tester.pump();
    expect(h.fixture.reads, 0);
    expect(h.recorder.routes, isEmpty);

    h.state.replace(() {
      h.state.current = true;
      h.state.parentPending = true;
    });
    await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(_edit)).onPressed, isNull);
    press();
    await tester.pump();
    expect(h.fixture.reads, 0);

    h.state.replace(() => h.state.parentPending = false);
    await tester.pump();
    final ready = tester.widget<TextButton>(find.byKey(_edit)).onPressed!;
    ready();
    ready();
    await settleNetworkWidgets(tester);
    expect(h.fixture.reads, 1);
    expect(h.recorder.routes, hasLength(1));
  });

  testWidgets(
    '320 dp, 2x text and a keyboard inset keep 48 dp rows scrollable and Save visible',
    (tester) async {
      tester.view.physicalSize = const Size(640, 1600);
      tester.view.devicePixelRatio = 2;
      tester.view.viewPadding = const FakeViewPadding(bottom: 48);
      tester.view.padding = FakeViewPadding.zero;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetPadding);

      final fixture = WorkItemStatusFixture();
      final members = <StatusFixtureMember>[
        for (var number = 1; number <= 30; number++)
          StatusFixtureMember(
            id: WorkItemStatusFixture.customStatusId(200 + number),
            name: '非常長的自訂工作流程狀態名稱 $number',
            category: number.isEven ? 'IN_PROGRESS' : null,
          ),
      ];
      fixture.item(group: false)
        ..members = members
        ..assignment = members.first;
      await _mount(tester, fixture: fixture, textScale: 2);
      await _open(tester);

      const keyboardPhysical = 640.0;
      tester.view.viewInsets = const FakeViewPadding(bottom: keyboardPhysical);
      await tester.pump();
      final ratio = tester.view.devicePixelRatio;
      final logicalHeight = tester.view.physicalSize.height / ratio;
      final logicalWidth = tester.view.physicalSize.width / ratio;
      final keyboardTop = logicalHeight - tester.view.viewInsets.bottom / ratio;
      expect(logicalWidth, 320);

      final warning = find.byKey(const ValueKey('work-item-status-warning'));
      await tester.scrollUntilVisible(
        warning,
        120,
        scrollable: _editorScroll(),
      );
      await tester.pump();
      expect(warning, findsOneWidget);
      expect(tester.getRect(warning).right, lessThanOrEqualTo(logicalWidth));

      final last = find.byKey(
        ValueKey('work-item-status-choice-${members.last.id}'),
      );
      await tester.scrollUntilVisible(
        last,
        120,
        scrollable: _editorScroll(),
        maxScrolls: 200,
      );
      await tester.pump();
      final row = tester.getRect(last);
      expect(row.height, greaterThanOrEqualTo(48));
      expect(row.left, greaterThanOrEqualTo(0));
      expect(row.right, lessThanOrEqualTo(logicalWidth));
      for (final id in _visibleChoiceIds(tester)) {
        final rect = tester.getRect(
          find.byKey(ValueKey('work-item-status-choice-$id')),
        );
        expect(rect.height, greaterThanOrEqualTo(48));
      }
      await tester.tap(last);
      await tester.pump();
      expect(find.text('將套用：非常長的自訂工作流程狀態名稱 30'), findsOneWidget);

      final save = find.byKey(_save);
      final rect = tester.getRect(save);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(logicalWidth));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(keyboardTop));
      expect(keyboardTop - rect.bottom, closeTo(16, 0.5));
      expect(rect.height, greaterThanOrEqualTo(48));
      expect(tester.hitTestOnBinding(rect.center).path, isNotEmpty);
      expect(
        tester.widget<FilledButton>(save).onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);

      tester.view.viewInsets = FakeViewPadding.zero;
      tester.view.padding = const FakeViewPadding(bottom: 48);
      await tester.pump();
      final closed = tester.getRect(save);
      final systemTop = logicalHeight - tester.view.padding.bottom / ratio;
      expect(closed.bottom, lessThanOrEqualTo(systemTop));
      expect(systemTop - closed.bottom, closeTo(16, 0.5));
      expect(tester.takeException(), isNull);
    },
  );
}

enum _Hold { apply, ack }

enum _Removal {
  popRoute,
  removeControl,
  replaceApi,
  closeApi,
  replaceAccount,
  sessionChange,
  routeGeneration,
  disposeParent,
}

Future<void> _remove(
  WidgetTester tester,
  _Mounted h,
  _Removal removal,
) async {
  switch (removal) {
    case _Removal.popRoute:
      final editor = tester.element(find.byKey(_save));
      Navigator.of(editor).removeRoute(ModalRoute.of(editor)!);
    case _Removal.removeControl:
      h.state.replace(() => h.state.show = false);
    case _Removal.replaceApi:
      h.state.replace(() => h.state.api = h.fixture.replaceApi());
    case _Removal.closeApi:
      final old = h.state.api;
      h.state.replace(() => h.state.api = h.fixture.replaceApi());
      old.close();
    case _Removal.replaceAccount:
      h.state.replace(() => h.state.account = _otherAccount);
    case _Removal.sessionChange:
      h.fixture.sessionGeneration = 13;
      h.state.owner.ping();
    case _Removal.routeGeneration:
      h.fixture.sessionGeneration = 13;
      h.state.replace(() => h.state.routeGeneration = 13);
    case _Removal.disposeParent:
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  }
}

final _otherAccount = Account(
  instance: GitLabInstance.parse('https://example.com/gitlab'),
  user: const GitLabUser(id: 8, username: 'grace', name: 'Grace'),
  token: 'synthetic-test-token',
);

typedef _Phase = ({
  WorkItemStatusWritePhase phase,
  Object token,
  Account account,
  GitLabApi api,
  WorkItemGraphDetail detail,
  int generation,
});

/// Test-only stand-in for a future parent. It records phases and models the
/// gate a parent would hold; it is not a production interface.
final class _Recorder {
  final phases = <_Phase>[];
  final saved = <WorkItemStatusSaveResult>[];
  final routes = <Route<dynamic>>[];
  final lifecycleAttempts = <bool>[];
  final refreshAttempts = <bool>[];
  Object? pendingToken;
  bool throwOnStart = false;

  void listen(
    WorkItemStatusWritePhase phase,
    Object token,
    Account account,
    GitLabApi api,
    WorkItemGraphDetail detail,
    int generation,
  ) {
    phases.add((
      phase: phase,
      token: token,
      account: account,
      api: api,
      detail: detail,
      generation: generation,
    ));
    if (phase == WorkItemStatusWritePhase.start) {
      pendingToken = token;
      if (throwOnStart) throw StateError('synthetic START rejection');
    } else if (identical(pendingToken, token)) {
      pendingToken = null;
    }
  }

  bool attemptLifecycle() {
    final allowed = pendingToken == null;
    lifecycleAttempts.add(allowed);
    return allowed;
  }

  bool attemptRefresh() {
    final allowed = pendingToken == null;
    refreshAttempts.add(allowed);
    return allowed;
  }
}

List<WorkItemStatusWritePhase> _kinds(_Recorder recorder) => [
  for (final phase in recorder.phases) phase.phase,
];

void _expectOneTerminal(_Recorder recorder) {
  expect(_kinds(recorder), [_start, _settle]);
  final start = recorder.phases.first;
  final settle = recorder.phases.last;
  expect(settle.token, same(start.token));
  expect(settle.account, same(start.account));
  expect(settle.api, same(start.api));
  expect(settle.detail, same(start.detail));
  expect(settle.generation, start.generation);
}

final class _Owner extends ChangeNotifier {
  void ping() => notifyListeners();
}

typedef _Mounted = ({
  WorkItemStatusFixture fixture,
  _Recorder recorder,
  _HarnessState state,
});

Future<_Mounted> _mount(
  WidgetTester tester, {
  bool group = false,
  WorkItemStatusFixture? fixture,
  double textScale = 1,
}) async {
  final server = fixture ?? WorkItemStatusFixture();
  final recorder = _Recorder();
  addTearDown(server.releaseHolds);
  addTearDown(server.closeAll);
  await tester.pumpWidget(
    _Harness(
      key: UniqueKey(),
      fixture: server,
      recorder: recorder,
      group: group,
      textScale: textScale,
    ),
  );
  return (
    fixture: server,
    recorder: recorder,
    state: tester.state<_HarnessState>(find.byType(_Harness)),
  );
}

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    required this.fixture,
    required this.recorder,
    required this.group,
    required this.textScale,
  });

  final WorkItemStatusFixture fixture;
  final _Recorder recorder;
  final bool group;
  final double textScale;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late Account account = widget.fixture.account;
  late GitLabApi api = widget.fixture.api;
  late WorkItemGraphDetail detail = widget.fixture.detail(group: widget.group);
  late int routeGeneration = widget.fixture.sessionGeneration;
  final owner = _Owner();
  var current = true;
  var show = true;
  var parentPending = false;
  WorkItemStatusWriteListener? listener;

  void replace(VoidCallback change) => setState(change);

  bool _isCurrent() =>
      current &&
      account.user.id == 7 &&
      widget.fixture.sessionGeneration == routeGeneration;

  @override
  void dispose() {
    owner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final recorder = widget.recorder;
    return MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(widget.textScale)),
        child: child ?? const SizedBox.shrink(),
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              if (show)
                WorkItemStatusControl(
                  account: account,
                  api: api,
                  detail: detail,
                  sessionGeneration: routeGeneration,
                  isCurrent: _isCurrent,
                  ownerChanges: owner,
                  writePending: parentPending,
                  onRoute: recorder.routes.add,
                  onStatusWrite: listener ?? recorder.listen,
                  onSaved: recorder.saved.add,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(_edit));
  await settleNetworkWidgets(tester);
  expect(find.byKey(_save), findsOneWidget);
}

Future<void> _choose(WidgetTester tester, String id) async {
  final row = find.byKey(ValueKey('work-item-status-choice-$id'));
  await tester.scrollUntilVisible(row, 120, scrollable: _editorScroll());
  await tester.tap(row);
  await tester.pump();
}

Future<void> _tapSave(WidgetTester tester) async {
  await tester.tap(find.byKey(_save));
  await tester.pump();
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  await pumpUntil(
    tester,
    ready,
    step: const Duration(milliseconds: 1),
    realDelay: const Duration(milliseconds: 1),
  );
  await tester.pump();
}

Finder _editorScroll() => find.byElementPredicate((Element element) {
  if (element.widget is! Scrollable) return false;
  final view = element.findAncestorWidgetOfExactType<CustomScrollView>();
  return view?.key == const ValueKey<String>('work-item-status-scroll');
}, description: 'status editor body scroll');

/// Choice IDs currently laid out, ordered top to bottom.
List<String> _visibleChoiceIds(WidgetTester tester) {
  const prefix = 'work-item-status-choice-';
  final rows = <({String id, double top})>[];
  for (final element in find
      .byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(prefix),
      )
      .evaluate()) {
    final key = element.widget.key! as ValueKey<String>;
    rows.add((
      id: key.value.substring(prefix.length),
      top: tester.getTopLeft(find.byKey(key)).dy,
    ));
  }
  rows.sort((left, right) => left.top.compareTo(right.top));
  return [for (final row in rows) row.id];
}
