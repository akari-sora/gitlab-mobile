import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/core/work_item_dates_models.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_dates.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/widget_settle.dart';
import 'support/work_item_dates_parent_fixture.dart';
import 'support/work_item_status_fixture.dart';

// Real GraphWorkItemDetailPage + the production WorkItemDatesControl against a
// synthetic server. Observation is only through widgets, the navigator and
// the fixture ledgers; no page private is read.

const _project = Project(id: 42, name: 'mobile', path: 'studio/mobile');
const _itemX = WorkItemDatesParentFixture.itemX;
const _itemY = WorkItemDatesParentFixture.itemY;
const _canceled = WorkItemStatusFixture.statusCanceled;

const _section = ValueKey('work-item-dates-section');
const _controlSlot = ValueKey('work-item-dates-control-slot');
const _hold = ValueKey('work-item-dates-hold');
const _stale = ValueKey('work-item-dates-stale');
const _unconfirmed = ValueKey('work-item-dates-unconfirmed');
const _datesEdit = ValueKey('work-item-dates-edit');
const _datesSave = ValueKey('work-item-dates-save');
const _datesCancel = ValueKey('work-item-dates-cancel');
const _startInput = ValueKey('work-item-dates-start-input');
const _dueInput = ValueKey('work-item-dates-due-input');
const _inheritedMode = ValueKey('work-item-dates-mode-inherited');
const _blocked = ValueKey('work-item-dates-blocked');
const _feedback = ValueKey('work-item-dates-save-feedback');
const _statusEdit = ValueKey('work-item-status-edit');
const _statusSave = ValueKey('work-item-status-save');
const _statusBanner = ValueKey('work-item-status-hold-banner');
const _labelsEdit = ValueKey('work-item-labels-edit');
const _assigneesEdit = ValueKey('work-item-assignees-edit');
const _milestoneEdit = ValueKey('work-item-milestone-edit');
const _weightEdit = ValueKey('work-item-weight-edit');

const _baseOp = WorkItemDatesParentFixture.baseOp;
const _probeOp = WorkItemDatesParentFixture.probeOp;
const _eeWriteOp = WorkItemDatesParentFixture.eeMutationOp;
const _ceWriteOp = WorkItemDatesParentFixture.ceMutationOp;
const _statusReadOp = 'MobileWorkItemStatus';
const _statusWriteOp = 'MobileUpdateWorkItemStatus';
const _lifecycleWriteOp = 'MobileUpdateWorkItemState';

const _oldStart = '開始 2026/10/10';
const _oldDue = '到期 2026/10/20';
const _newStart = '開始 2026/11/02';
const _newDue = '到期 2026/11/09';

void main() {
  test(
    'D0 fixture shapes parse through production detail, access and write '
    'APIs (EE manual, EE inherited, CE fixed)',
    () async {
      for (final shape in const ['ee-manual', 'ee-inherited', 'ce-fixed']) {
        final fixture = WorkItemDatesParentFixture();
        addTearDown(fixture.closeAll);
        final state = fixture.dates[_itemX]!;
        if (shape == 'ee-inherited') {
          state
            ..isFixed = false
            ..rollUp = true
            ..startDate = WorkItemDatesParentFixture.inheritedStart
            ..dueDate = WorkItemDatesParentFixture.inheritedDue
            ..startSourceWorkItemId = 'gid://gitlab/WorkItem/700';
        }
        if (shape == 'ce-fixed') state.ceFixed = true;
        final api = fixture.primaryApi();

        final detail = await api.projectWorkItem(
          _project,
          WorkItemStatusFixture.sharedIid,
        );
        final dates = detail.dates;
        expect(dates, isNotNull, reason: shape);
        expect(
          workItemCalendarDate(dates!.startDate!),
          state.startDate!.replaceAll('-', '/'),
          reason: shape,
        );
        expect(
          workItemCalendarDate(dates.dueDate!),
          state.dueDate!.replaceAll('-', '/'),
          reason: shape,
        );
        expect(dates.rollUp, state.rollUp, reason: shape);

        final access = await api.workItemDates(
          detail,
          expectedUserId: fixture.account.user.id,
          generation: 1,
        );
        expect(access.canWrite, isTrue, reason: shape);
        expect(
          access.snapshot.edition,
          shape == 'ce-fixed'
              ? WorkItemDatesEdition.ceFixed
              : WorkItemDatesEdition.ee,
          reason: shape,
        );
        expect(
          access.snapshot.mode,
          shape == 'ee-inherited'
              ? WorkItemDatesMode.inherited
              : WorkItemDatesMode.manual,
          reason: shape,
        );

        var started = 0;
        final result = await api.updateWorkItemDates(
          access.target!,
          mode: WorkItemDatesMode.manual,
          startDate: '2026-11-02',
          dueDate: '2026-11-09',
          onMutationSent: () => started++,
        );
        expect(result.outcome, WorkItemDatesWriteOutcome.applied, reason: shape);
        expect(result.mutationSent, isTrue, reason: shape);
        expect(started, 1, reason: shape);
        expect(fixture.datesMutationRequests, 1, reason: shape);
        expect(fixture.datesApplied, 1, reason: shape);
        expect(
          fixture.count(shape == 'ce-fixed' ? _ceWriteOp : _eeWriteOp),
          1,
          reason: shape,
        );
        expect(
          fixture.mutationInputs.single['startAndDueDateWidget'],
          {
            if (shape != 'ce-fixed') 'isFixed': true,
            'startDate': '2026-11-02',
            'dueDate': '2026-11-09',
          },
          reason: shape,
        );
        expect(fixture.unhandled, isEmpty, reason: shape);
      }
    },
  );

  testWidgets(
    'D1 one Dates control inside the keyed 日期 section; zero Dates requests '
    'before a tap; read-only without a captured session generation',
    (tester) async {
      final h = await _mount(tester);
      expect(find.byKey(_section), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(_section),
          matching: find.byKey(_controlSlot),
        ),
        findsOneWidget,
      );
      expect(find.byType(WorkItemDatesControl), findsOneWidget);
      expect(find.text(_oldStart), findsOneWidget);
      expect(find.text(_oldDue), findsOneWidget);
      expect(
        find.byKey(const ValueKey('work-item-attribute-dates')),
        findsNothing,
        reason: 'no attributes date row',
      );
      expect(h.fixture.count(_baseOp), 0);
      expect(h.fixture.count(_probeOp), 0);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(h.session)],
          child: MaterialApp(
            home: GraphWorkItemDetailPage.project(
              key: const ValueKey('page-generic'),
              account: h.account,
              api: h.api,
              project: _project,
              iid: WorkItemStatusFixture.sharedIid,
              isCurrent: () => identical(h.session.api, h.api),
            ),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.text(_oldStart), findsOneWidget, reason: 'chips still read');
      expect(find.byKey(_section), findsOneWidget);
      expect(find.byKey(_datesEdit), findsNothing, reason: 'no generation');
      expect(h.fixture.count(_baseOp), 0);
      expect(h.fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'D2 applied write: State continuity through START, confirmed, exactly '
    'one parent read',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _openDates(tester);
      final editor = h.observer.pushed.last;
      final control = _controlState(tester);
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_datesSave));
      await _until(tester, () => f.awaitingApply);
      expect(identical(_controlState(tester), control), isTrue);
      expect(
        find.descendant(
          of: find.byKey(_section, skipOffstage: false),
          matching: find.byKey(_hold, skipOffstage: false),
          skipOffstage: false,
        ),
        findsOneWidget,
        reason: 'hold line inside the section',
      );
      expect(h.observer.removed, isEmpty);
      final details = _details(h);

      apply.complete();
      await settleNetworkWidgets(tester);
      expect(h.observer.popped, [editor], reason: 'popped only after applied');
      expect(h.observer.removed, isEmpty);
      expect(identical(_controlState(tester), control), isTrue);
      expect(f.datesMutationRequests, 1);
      expect(_details(h), details + 1, reason: 'exactly one parent read');
      expect(find.text(_newStart), findsOneWidget);
      expect(find.text(_newDue), findsOneWidget);
      expect(find.text(_oldStart), findsNothing);
      expect(find.byKey(_hold), findsNothing);
      expect(find.byKey(_stale), findsNothing);
      expect(find.byKey(_unconfirmed), findsNothing);
      expect(_onPressed(tester, find.byKey(_datesEdit)), isNotNull);
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    'D3 a coherent lagging fresh read keeps the stale line and hides every '
    'chip; manual refresh recovers',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _openDates(tester);
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      final details = _details(h);
      final held = Completer<void>();
      f
        ..lagNextDetail = true
        ..status.holdNextDetail = held;
      await tester.tap(find.byKey(_datesSave));
      await _until(tester, () => _details(h) == details + 1);
      await tester.pump(const Duration(seconds: 1));
      await _drain(tester);
      expect(find.byKey(_datesSave), findsNothing, reason: 'confirmed, closed');
      expect(find.byKey(_stale), findsOneWidget, reason: 'stale while held');
      expect(find.text(_newStart), findsNothing, reason: 'no requested chip');
      expect(find.text(_oldStart), findsNothing, reason: 'no pre-write chip');

      held.complete();
      await settleNetworkWidgets(tester);
      expect(f.lagNextDetail, isFalse, reason: 'the lagged read was served');
      expect(find.byKey(_stale), findsOneWidget);
      expect(find.text(_oldStart), findsNothing);
      expect(find.text(_oldDue), findsNothing);
      expect(find.text(_newStart), findsNothing);

      await tester.tap(_refreshButton());
      await settleNetworkWidgets(tester);
      expect(find.byKey(_stale), findsNothing);
      expect(find.text(_newStart), findsOneWidget);
      expect(find.text(_newDue), findsOneWidget);
      expect(f.datesMutationRequests, 1);
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    'D4 the Dates floor is independent of a confirmed Status _withSummary '
    'bump',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _expand(tester);
      await _openDates(tester);
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      f.lagNextDetail = true;
      await tester.tap(find.byKey(_datesSave));
      await settleNetworkWidgets(tester);
      expect(find.byKey(_stale), findsOneWidget, reason: 'positive control');
      expect(find.text(_oldStart), findsNothing);

      final details = _details(h);
      await _openStatus(tester);
      await _chooseStatus(tester, _canceled);
      await tester.tap(find.byKey(_statusSave));
      await settleNetworkWidgets(tester);
      expect(f.status.count(_statusWriteOp), 1);
      expect(find.text('不處理'), findsWidgets, reason: 'Status confirmed');
      expect(_details(h), details, reason: 'zero further detail reads');
      expect(find.byKey(_stale), findsOneWidget, reason: 'floor not cleared');
      expect(find.text(_oldStart), findsNothing);
      expect(find.text(_newStart), findsNothing);

      await tester.tap(_refreshButton());
      await settleNetworkWidgets(tester);
      expect(find.byKey(_stale), findsNothing);
      expect(find.text(_newStart), findsOneWidget);
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets('D5 inherited mode write', (tester) async {
    final fixture = WorkItemDatesParentFixture();
    fixture.dates[_itemX]!.rollUp = true;
    final h = await _mount(tester, fixture: fixture);
    final f = h.fixture;
    await _openDates(tester);
    final control = _controlState(tester);
    await tester.tap(find.byKey(_inheritedMode));
    await tester.pump();
    await tester.tap(find.byKey(_datesSave));
    await settleNetworkWidgets(tester);
    expect(f.mutationInputs.single['startAndDueDateWidget'], {
      'isFixed': false,
    });
    expect(h.observer.removed, isEmpty);
    expect(identical(_controlState(tester), control), isTrue);
    expect(find.text('開始 2026/09/01'), findsOneWidget);
    expect(find.text('到期 2026/12/31'), findsOneWidget);
    expect(find.text('日期由階層彙整'), findsOneWidget);
    expect(find.byKey(_unconfirmed), findsNothing);
    expect(find.byKey(_stale), findsNothing);
    expect(find.text('由子項目繼承'), findsNothing, reason: 'no mode on page');
    expect(find.text('手動日期'), findsNothing);
    expect(f.unhandled, isEmpty);
  });

  testWidgets(
    'D6 lost ACK: unknown, never retried; automatic reloads do not '
    'acknowledge',
    (tester) async {
      final h = await _mount(tester, pages: 2);
      final f = h.fixture;
      await _openDates(tester, page: 'a');
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      final details = _details(h);
      f.loseNextAck = true;
      await tester.tap(find.byKey(_datesSave));
      await settleNetworkWidgets(tester);
      expect(f.datesMutationRequests, 1);
      expect(f.datesApplied, 1);
      expect(find.byKey(_feedback), findsOneWidget);
      expect(_details(h), details + 2, reason: 'one reload per page');
      expect(_has('a', _unconfirmed), findsOneWidget);

      await tester.tap(find.byKey(_datesCancel));
      await settleNetworkWidgets(tester);
      expect(f.datesMutationRequests, 1, reason: 'never retried');

      await _expand(tester, page: 'b');
      await _openStatus(tester, page: 'b');
      await _chooseStatus(tester, _canceled);
      final reloads = _details(h);
      await tester.tap(find.byKey(_statusSave));
      await settleNetworkWidgets(tester);
      expect(f.status.count(_statusWriteOp), 1);
      expect(_details(h), reloads + 1, reason: 'A reloads on Status settle');
      expect(
        _has('a', _unconfirmed),
        findsOneWidget,
        reason: 'automatic reload keeps the line',
      );

      await tester.tap(_refreshButton(page: 'a'));
      await settleNetworkWidgets(tester);
      expect(_has('a', _unconfirmed), findsNothing);
      expect(_has('b', _unconfirmed), findsOneWidget, reason: 'A only');
      expect(f.datesMutationRequests, 1);
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    'D6b a post-SETTLE reload failure deterministically keeps the stale line '
    'and hides all chips',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _openDates(tester);
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      final details = _details(h);
      f.status.failNextDetail = true;
      await tester.tap(find.byKey(_datesSave));
      await settleNetworkWidgets(tester);
      expect(f.status.failNextDetail, isFalse, reason: 'the reload got 503');
      expect(_details(h), details + 1);
      expect(find.byKey(_datesSave), findsNothing, reason: 'confirmed, closed');
      expect(find.byKey(_section), findsOneWidget, reason: 'detail kept');
      expect(find.byKey(_stale), findsOneWidget);
      expect(find.text(_oldStart), findsNothing);
      expect(find.text(_oldDue), findsNothing);
      expect(find.text(_newStart), findsNothing);
      expect(find.text(_newDue), findsNothing);
      expect(_onPressed(tester, _refreshButton()), isNotNull);
      expect(f.datesMutationRequests, 1);
    },
  );

  testWidgets('D7 capability denial', (tester) async {
    final fixture = WorkItemDatesParentFixture();
    fixture.dates[_itemX]!.setWorkItemMetadata = false;
    final h = await _mount(tester, fixture: fixture);
    await _openDates(tester);
    expect(find.byKey(_blocked), findsOneWidget);
    expect(find.text('目前帳號不能變更日期'), findsOneWidget);
    expect(_onPressed(tester, find.byKey(_datesSave)), isNull);
    await tester.tap(find.byKey(_datesSave), warnIfMissed: false);
    await _drain(tester);
    expect(h.fixture.datesMutationRequests, 0);
    expect(find.byKey(_hold, skipOffstage: false), findsNothing);
  });

  testWidgets('D8 POST_SENT_BEFORE_APPLY same-page gates', (tester) async {
    await _sameStageGates(tester, _Stage.beforeApply);
  });

  testWidgets('D9 POST_APPLY_ACK hold keeps the same gates', (tester) async {
    await _sameStageGates(tester, _Stage.ack);
  });

  testWidgets(
    'D10 POST_ACK_CONFIRM_READ hold keeps the gates; own readback not '
    'cancelled',
    (tester) async {
      await _sameStageGates(tester, _Stage.confirmRead);
    },
  );

  testWidgets('D11a same-page Status START during a held FINAL_FENCE_READ', (
    tester,
  ) async {
    final h = await _mount(tester);
    final f = h.fixture;
    await _expand(tester);
    await _openDates(tester);
    await _enterDates(tester, '2026-11-02', '2026-11-09');
    f.armFinalFence = true;
    await tester.tap(find.byKey(_datesSave));
    await _until(tester, () => f.awaitingFinalFenceReads == 1);

    await _press(tester, _any(null, find.byKey(_statusEdit, skipOffstage: false)));
    await settleNetworkWidgets(tester);
    expect(find.byKey(_statusSave), findsOneWidget, reason: 'Status editor');
    await _chooseStatus(tester, _canceled);
    final statusApply = Completer<void>();
    f.status.holdBeforeApply = statusApply;
    await tester.tap(find.byKey(_statusSave));
    await tester.idle();
    expect(f.status.awaitingApply, isTrue, reason: 'Status held before apply');

    f.releaseFenceNonce(f.parkedFenceNonces.single);
    await tester.idle();
    expect(f.datesMutationRequests, 0, reason: 'zero Dates sends');
    await _drain(tester);
    await _drain(tester);
    expect(find.byKey(_hold, skipOffstage: false), findsNothing);

    statusApply.complete();
    await settleNetworkWidgets(tester);
    expect(f.status.count(_statusWriteOp), 1);
    expect(f.datesMutationRequests, 0);
  });

  testWidgets('D11b same-page lifecycle write during a held FINAL_FENCE_READ', (
    tester,
  ) async {
    final h = await _mount(tester);
    final f = h.fixture;
    await _openDates(tester);
    await _enterDates(tester, '2026-11-02', '2026-11-09');
    f.armFinalFence = true;
    await tester.tap(find.byKey(_datesSave));
    await _until(tester, () => f.awaitingFinalFenceReads == 1);

    final lifecycle = Completer<void>();
    f.status.holdNextLifecycleMutation = lifecycle;
    await _press(tester, _buttonWithText(null, '關閉工作項目'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('確認關閉'));
    await _until(tester, () => f.count(_lifecycleWriteOp) == 1);

    f.releaseFenceNonce(f.parkedFenceNonces.single);
    await _drain(tester);
    await _drain(tester);
    expect(f.datesMutationRequests, 0, reason: 'zero Dates sends');
    expect(find.byKey(_hold, skipOffstage: false), findsNothing);

    lifecycle.complete();
    await settleNetworkWidgets(tester);
    expect(f.datesMutationRequests, 0);
  });

  testWidgets('D11c real owner loss during a held FINAL_FENCE_READ', (
    tester,
  ) async {
    final h = await _mount(tester);
    final f = h.fixture;
    await _openDates(tester);
    await _enterDates(tester, '2026-11-02', '2026-11-09');
    f.armFinalFence = true;
    await tester.tap(find.byKey(_datesSave));
    await _until(tester, () => f.awaitingFinalFenceReads == 1);

    await tester.runAsync(() => h.session.endSession());
    await tester.runAsync(() => h.session.select(h.session.accounts.single));
    await _frames(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(_datesSave, skipOffstage: false), findsNothing);
    expect(h.observer.removed, isNotEmpty, reason: 'editor removed');

    f.releaseFenceNonce(f.parkedFenceNonces.single);
    await settleNetworkWidgets(tester);
    expect(f.datesMutationRequests, 0, reason: 'zero Dates sends');
  });

  testWidgets(
    'D12a two Dates writers A/B in the pre-START fence; release A then B; '
    'winner held before apply',
    (tester) async {
      await _twoDatesWriters(tester, winner: 'a');
    },
  );

  testWidgets(
    'D12b two Dates writers A/B in the pre-START fence; reversed release '
    '(B then A); winner held before apply',
    (tester) async {
      await _twoDatesWriters(tester, winner: 'b');
    },
  );

  testWidgets(
    'D12c mixed pre-START: Status B winner held before apply, Dates A loser '
    'released',
    (tester) async {
      await _mixedWriters(tester, datesWins: false);
    },
  );

  testWidgets(
    'D12d mixed pre-START: Dates A winner held before apply, Status B loser '
    'released',
    (tester) async {
      await _mixedWriters(tester, datesWins: true);
    },
  );

  testWidgets(
    "D13a cross-page Status START during A's held FINAL_FENCE_READ",
    (tester) async {
      final h = await _mount(tester, pages: 2);
      final f = h.fixture;
      await _expand(tester, page: 'b');
      await _openDates(tester, page: 'a');
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      f.armFinalFence = true;
      await tester.tap(find.byKey(_datesSave));
      await _until(tester, () => f.awaitingFinalFenceReads == 1);

      await _press(tester, _any('b', find.byKey(_statusEdit, skipOffstage: false)));
      await settleNetworkWidgets(tester);
      await _chooseStatus(tester, _canceled);
      final statusApply = Completer<void>();
      f.status.holdBeforeApply = statusApply;
      await tester.tap(find.byKey(_statusSave));
      await _until(tester, () => f.status.awaitingApply);

      f.releaseFenceNonce(f.parkedFenceNonces.single);
      await _drain(tester);
      await _drain(tester);
      expect(f.datesMutationRequests, 0, reason: 'A zero Dates sends');

      statusApply.complete();
      await settleNetworkWidgets(tester);
      expect(f.status.count(_statusWriteOp), 1);
      expect(f.datesMutationRequests, 0);
    },
  );

  testWidgets('D13b cross-page holds in both directions', (tester) async {
    final h = await _mount(tester, pages: 2);
    final f = h.fixture;
    await _expand(tester, page: 'b');
    await _openStatus(tester, page: 'b');
    await _chooseStatus(tester, _canceled);
    final statusApply = Completer<void>();
    f.status.holdBeforeApply = statusApply;
    await tester.tap(find.byKey(_statusSave));
    await _until(tester, () => f.status.awaitingApply);
    final aEdit = _any('a', find.byKey(_datesEdit, skipOffstage: false));
    expect(_onPressed(tester, aEdit), isNull, reason: 'A Dates edit disabled');
    await _press(tester, aEdit);
    expect(f.count(_baseOp), 0, reason: 'zero Dates reads');
    statusApply.complete();
    await settleNetworkWidgets(tester);
    expect(f.status.count(_statusWriteOp), 1);

    await _openDates(tester, page: 'a');
    await _enterDates(tester, '2026-11-02', '2026-11-09');
    final datesApply = Completer<void>();
    f.holdBeforeApply = datesApply;
    await tester.tap(find.byKey(_datesSave));
    await _until(tester, () => f.awaitingApply);
    final bEdit = _any('b', find.byKey(_statusEdit, skipOffstage: false));
    expect(_onPressed(tester, bEdit), isNull, reason: 'B Status edit disabled');
    final statusReads = f.count(_statusReadOp);
    await _press(tester, bEdit);
    expect(f.count(_statusReadOp), statusReads, reason: 'zero Status reads');
    datesApply.complete();
    await settleNetworkWidgets(tester);
    expect(f.datesMutationRequests, 1);
    expect(f.status.count(_statusWriteOp), 1);
  });

  testWidgets(
    'D14 preflight-unsent: Cancel during FINAL_FENCE_READ',
    (tester) async {
      final h = await _mount(tester, pages: 2);
      final f = h.fixture;
      await _openDates(tester, page: 'a');
      final editor = h.observer.pushed.last;
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      f.armFinalFence = true;
      await tester.tap(find.byKey(_datesSave));
      await _until(tester, () => f.awaitingFinalFenceReads == 1);
      final details = _details(h);
      await tester.tap(find.byKey(_datesCancel));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(h.observer.popped, [editor]);
      expect(_has('b', _hold), findsNothing);

      f.releaseFenceNonce(f.parkedFenceNonces.single);
      await settleNetworkWidgets(tester);
      expect(f.datesMutationRequests, 0, reason: 'zero START and sends');
      expect(_has('a', _hold), findsNothing);
      expect(_has('b', _hold), findsNothing, reason: 'observer never held');
      expect(_details(h), details, reason: 'zero extra detail reads');
    },
  );

  testWidgets(
    'D15 observer B blocked until SETTLE; concurrent four-page mount; C and '
    'D independent; attributed ledger counts',
    (tester) async {
      final h = await _mount(tester, pages: 4, height: 844);
      final f = h.fixture;
      for (final page in const ['a', 'b', 'c', 'd']) {
        expect(
          _onPressed(tester, _any(page, find.byKey(_datesEdit, skipOffstage: false))),
          isNotNull,
          reason: 'page $page enabled before START',
        );
      }
      await _openDates(tester, page: 'a');
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_datesSave));
      await _until(tester, () => f.awaitingApply);
      await _drain(tester);

      expect(_has('b', _hold), findsOneWidget, reason: 'B held');
      expect(
        _onPressed(tester, _any('b', find.byKey(_datesEdit, skipOffstage: false))),
        isNull,
      );
      expect(_onPressed(tester, _refreshButton(page: 'b')), isNull);
      expect(_has('c', _hold), findsNothing, reason: 'other item');
      expect(
        _onPressed(tester, _any('c', find.byKey(_datesEdit, skipOffstage: false))),
        isNotNull,
      );
      expect(_has('d', _hold), findsNothing, reason: 'other client');
      expect(
        _onPressed(tester, _any('d', find.byKey(_datesEdit, skipOffstage: false))),
        isNotNull,
      );
      final xPrimary = _details(h);
      final yPrimary = _details(h, item: _itemY);
      final xClientD = _details(h, tag: 'client-d');

      apply.complete();
      await settleNetworkWidgets(tester);
      expect(find.byKey(_datesSave), findsNothing, reason: 'A confirmed');
      expect(_has('b', _hold), findsNothing);
      expect(
        _onPressed(tester, _any('b', find.byKey(_datesEdit, skipOffstage: false))),
        isNotNull,
      );
      expect(_onPressed(tester, _refreshButton(page: 'b')), isNotNull);
      expect(_any('b', find.text(_newStart, skipOffstage: false)), findsOneWidget);
      for (final page in const ['a', 'b']) {
        expect(_has(page, _stale), findsNothing, reason: page);
        expect(_has(page, _unconfirmed), findsNothing, reason: page);
      }
      expect(_details(h), xPrimary + 2, reason: 'A writer + B observer');
      expect(_details(h, item: _itemY), yPrimary, reason: 'C untouched');
      expect(_details(h, tag: 'client-d'), xClientD, reason: 'D untouched');
      expect(f.datesMutationRequests, 1);
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    'D15b ACK and readback complete inside the editor exit transition '
    '(frozen clock)',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _openDates(tester);
      final editor = h.observer.pushed.last;
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_datesSave));
      await _until(tester, () => f.awaitingApply);
      await tester.tap(find.byKey(_datesCancel));
      await tester.pump();
      expect(h.observer.popped, [editor]);

      apply.complete();
      await _frozenTurns(
        tester,
        () => find.byKey(_hold, skipOffstage: false).evaluate().isEmpty,
      );
      expect(find.byKey(_hold, skipOffstage: false), findsNothing);
      expect(
        find.byKey(_datesSave, skipOffstage: false),
        findsOneWidget,
        reason: 'editor still mounted in its exit transition',
      );
      expect(h.observer.popped, [editor]);
      expect(h.observer.removed, isEmpty);
      expect(ModalRoute.of(tester.element(find.byKey(_section, skipOffstage: false)))!.isCurrent, isTrue);

      await tester.pump(const Duration(seconds: 1));
      await settleNetworkWidgets(tester);
      expect(find.byKey(const ValueKey('page-a')), findsOneWidget);
      expect(find.byKey(_unconfirmed), findsOneWidget, reason: 'no confirm');
      expect(find.byKey(_datesSave), findsNothing);
      expect(f.datesMutationRequests, 1);
    },
  );

  testWidgets(
    'D16 Cancel after START, transition completed: honest unknown via the '
    'observer',
    (tester) async {
      final h = await _mount(tester, pages: 2);
      final f = h.fixture;
      await _openDates(tester, page: 'a');
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_datesSave));
      await _until(tester, () => f.awaitingApply);
      await _popRoute(tester);
      expect(find.byKey(_datesSave, skipOffstage: false), findsNothing);
      expect(_has('b', _hold), findsOneWidget);
      expect(_onPressed(tester, _any('b', find.byKey(_datesEdit))), isNull);
      final details = _details(h);

      apply.complete();
      await settleNetworkWidgets(tester);
      for (final page in const ['a', 'b']) {
        expect(_has(page, _hold), findsNothing, reason: page);
        expect(_has(page, _unconfirmed), findsOneWidget, reason: page);
        expect(
          _onPressed(tester, _any(page, find.byKey(_datesEdit))),
          isNotNull,
          reason: page,
        );
        expect(_any(page, find.text(_newStart)), findsOneWidget, reason: page);
      }
      expect(_details(h), details + 2, reason: 'one reload per page');
      expect(f.datesMutationRequests, 1);

      await tester.tap(_refreshButton(page: 'a'));
      await settleNetworkWidgets(tester);
      expect(_has('a', _unconfirmed), findsNothing);
      expect(_has('b', _unconfirmed), findsOneWidget, reason: 'A only');
    },
  );

  testWidgets(
    'D17a page rebind before START (sessionGeneration during the fence read)',
    (tester) async {
      final h = await _mount(tester, injected: true);
      final f = h.fixture;
      await _openDates(tester);
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      f.armFinalFence = true;
      await tester.tap(find.byKey(_datesSave));
      await _until(tester, () => f.awaitingFinalFenceReads == 1);
      final details = _details(h);

      h.rebind.value = 2;
      await _frames(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(_datesSave, skipOffstage: false), findsNothing);

      f.releaseFenceNonce(f.parkedFenceNonces.single);
      await settleNetworkWidgets(tester);
      expect(f.datesMutationRequests, 0, reason: 'zero START and sends');
      expect(_details(h), details + 1, reason: 'new session detail');
      expect(find.text(_oldStart), findsOneWidget);
      expect(_onPressed(tester, find.byKey(_datesEdit)), isNotNull);
      expect(identical(h.session.api, h.api), isTrue, reason: 'same session');
    },
  );

  testWidgets(
    'D17b page rebind after START (sessionGeneration during a held write)',
    (tester) async {
      final h = await _mount(tester, injected: true);
      final f = h.fixture;
      await _openDates(tester);
      final before = _controlState(tester);
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_datesSave));
      await _until(tester, () => f.awaitingApply);
      final generation = h.session.generation;
      final details = _details(h);

      h.rebind.value = 2;
      await _frames(tester);
      await tester.pump(const Duration(seconds: 1));
      await _until(tester, () => _details(h) == details + 1);
      await _drain(tester);
      final afterInitial = _details(h);
      expect(find.byKey(_datesSave, skipOffstage: false), findsNothing);
      expect(find.byType(WorkItemDatesControl, skipOffstage: false), findsOneWidget);
      expect(identical(_controlState(tester), before), isFalse);
      expect(find.byKey(_hold), findsOneWidget, reason: 'held after rebind');
      expect(_onPressed(tester, find.byKey(_datesEdit)), isNull);
      expect(_onPressed(tester, _refreshButton()), isNull);
      expect(h.session.generation, generation, reason: 'no session change');

      apply.complete();
      await settleNetworkWidgets(tester);
      expect(find.byKey(_hold), findsNothing);
      expect(_details(h), afterInitial + 1, reason: 'one terminal reload');
      expect(find.byKey(_unconfirmed), findsOneWidget);
      expect(_onPressed(tester, find.byKey(_datesEdit)), isNotNull);
      expect(f.datesMutationRequests, 1);
    },
  );

  testWidgets('D18 owner away and back during a held write never paints', (
    tester,
  ) async {
    final h = await _mount(tester);
    final f = h.fixture;
    await _openDates(tester);
    await _enterDates(tester, '2026-11-02', '2026-11-09');
    final apply = Completer<void>();
    f.holdBeforeApply = apply;
    await tester.tap(find.byKey(_datesSave));
    await _until(tester, () => f.awaitingApply);
    final generation = h.session.generation;
    await tester.runAsync(() => h.session.endSession());
    await tester.runAsync(() => h.session.select(h.session.accounts.single));
    expect(h.session.active?.key, f.account.key);
    expect(h.session.generation, greaterThan(generation));
    apply.complete();
    await settleNetworkWidgets(tester);
    expect(f.datesMutationRequests, 1);
    expect(find.text(_newStart, skipOffstage: false), findsNothing);
    expect(find.text(_newDue, skipOffstage: false), findsNothing);
  });

  testWidgets('D19 manual refresh gate while held', (tester) async {
    final h = await _mount(tester);
    final f = h.fixture;
    await _openDates(tester);
    await _enterDates(tester, '2026-11-02', '2026-11-09');
    final apply = Completer<void>();
    f.holdBeforeApply = apply;
    await tester.tap(find.byKey(_datesSave));
    await _until(tester, () => f.awaitingApply);
    final refresh = _refreshButton();
    expect(_onPressed(tester, refresh), isNull);
    final details = _details(h);
    await _press(tester, refresh);
    expect(_details(h), details, reason: 'zero detail reads');
    apply.complete();
    await settleNetworkWidgets(tester);
    expect(_onPressed(tester, refresh), isNotNull);
  });

  testWidgets('D20 no-op save', (tester) async {
    final h = await _mount(tester);
    final f = h.fixture;
    await _openDates(tester);
    final details = _details(h);
    await tester.tap(find.byKey(_datesSave));
    await tester.pump();
    expect(find.byKey(_hold, skipOffstage: false), findsNothing);
    await settleNetworkWidgets(tester);
    expect(find.byKey(_datesSave), findsNothing, reason: 'editor closed');
    expect(find.byKey(_hold), findsNothing);
    expect(f.datesMutationRequests, 0);
    expect(f.count(_baseOp), 1, reason: 'access read only');
    expect(_details(h), details, reason: 'no reload');
  });

  testWidgets('D21 320 dp at 2.0x text scale', (tester) async {
    final h = await _mount(tester, width: 320, height: 5200, textScale: 2);
    final f = h.fixture;
    final edit = find.byKey(_datesEdit);
    await tester.ensureVisible(edit);
    await tester.pump();
    expect(tester.getSize(edit).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(edit).height, greaterThanOrEqualTo(48));
    await _openDates(tester);
    expect(tester.getSize(find.byKey(_datesCancel)).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(find.byKey(_datesSave)).height, greaterThanOrEqualTo(48));
    await _enterDates(tester, '2026-11-02', '2026-11-09');
    final apply = Completer<void>();
    f.holdBeforeApply = apply;
    await tester.tap(find.byKey(_datesSave));
    await _until(tester, () => f.awaitingApply);
    await _popRoute(tester);
    expect(find.byKey(_hold), findsOneWidget);
    expect(tester.takeException(), isNull);

    apply.complete();
    await settleNetworkWidgets(tester);
    expect(find.byKey(_unconfirmed), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(_refreshButton());
    await settleNetworkWidgets(tester);
    await _openDates(tester);
    await _enterDates(tester, '2026-12-01', '2026-12-05');
    f.lagNextDetail = true;
    await tester.tap(find.byKey(_datesSave));
    await settleNetworkWidgets(tester);
    expect(find.byKey(_stale), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('page-a')),
        matching: find.byType(TextField),
      ),
      findsNothing,
      reason: 'no page TextField',
    );
  });

  testWidgets('D22 preservation', (tester) async {
    final fixture = WorkItemDatesParentFixture()..healthWidget = true;
    fixture.dates[_itemX]!.rollUp = true;
    final h = await _mount(tester, fixture: fixture);
    expect(find.text(_oldStart), findsOneWidget);
    expect(find.text(_oldDue), findsOneWidget);
    expect(find.text('日期由階層彙整'), findsOneWidget);
    expect(find.byKey(_statusBanner), findsNothing);
    expect(find.byKey(_hold), findsNothing);
    expect(find.byKey(const ValueKey('work-item-attributes')), findsOneWidget);
    expect(find.text('伺服器提供 2 個欄位'), findsOneWidget, reason: 'STATUS+健康');
    expect(find.byKey(const ValueKey('work-item-health-edit')), findsNothing);
    expect(h.fixture.count(_baseOp), 0);
    expect(h.fixture.unhandled, isEmpty);
  });

  testWidgets(
    'D23 benign session emit while a cross-page Dates write is busy: editor '
    'closed and open pre-Save',
    (tester) async {
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final other1 = Account(
        instance: instance,
        user: const GitLabUser(id: 81, username: 'bea', name: 'Bea'),
        token: 'synthetic-other-token-1',
      );
      final other2 = Account(
        instance: instance,
        user: const GitLabUser(id: 82, username: 'cai', name: 'Cai'),
        token: 'synthetic-other-token-2',
      );
      final h = await _mount(tester, pages: 2, seeded: [other1, other2]);
      final f = h.fixture;
      final session = h.session;
      expect(session.accounts.length, 3);
      var notifications = 0;
      void count() {
        notifications++;
      }

      session.addListener(count);
      addTearDown(() => session.removeListener(count));

      // (a) A's editor closed.
      await _openDates(tester, page: 'b');
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      final applyB = Completer<void>();
      f.holdBeforeApply = applyB;
      await tester.tap(find.byKey(_datesSave));
      await _until(tester, () => f.awaitingApply);
      await _drain(tester);
      final controlA = _controlState(tester, page: 'a');
      expect(_has('a', _hold), findsOneWidget, reason: 'A adopted the hold');
      expect(session.busy, isFalse);
      expect(session.initializing, isFalse);
      expect(session.resuming, isFalse);
      var saves = h.store.accountSaves;
      final generation = session.generation;
      notifications = 0;
      await tester.runAsync(() => session.remove(other1));
      await _frames(tester);
      expect(notifications, 2);
      expect(h.store.accountSaves, saves + 1);
      expect(session.generation, generation);
      expect(session.active?.key, h.account.key);
      expect(identical(session.api, h.api), isTrue);
      expect(_has('a', _hold), findsOneWidget, reason: 'still held');

      applyB.complete();
      await settleNetworkWidgets(tester);
      expect(identical(_controlState(tester, page: 'a'), controlA), isTrue);
      expect(_has('a', _hold), findsNothing);
      final aEdit = _any('a', find.byKey(_datesEdit, skipOffstage: false));
      expect(_onPressed(tester, aEdit), isNotNull, reason: 'fence survived');
      var base = f.count(_baseOp);
      await _openDates(tester, page: 'a');
      expect(f.count(_baseOp), base + 1, reason: 'one access base read');

      // (b) A's editor open before B saves.
      await _enterDates(tester, '2026-12-01', '2026-12-05');
      await _press(tester, _any('b', find.byKey(_datesEdit, skipOffstage: false)));
      await settleNetworkWidgets(tester);
      await _enterDates(tester, '2026-11-20', '2026-11-25');
      final applyB2 = Completer<void>();
      f.holdBeforeApply = applyB2;
      await tester.tap(find.byKey(_datesSave));
      await _until(tester, () => f.awaitingApply);
      await _drain(tester);
      expect(_has('a', _hold), findsOneWidget);
      final removed = h.observer.removed.length;
      saves = h.store.accountSaves;
      notifications = 0;
      await tester.runAsync(() => session.remove(other2));
      await _frames(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(notifications, 2);
      expect(h.store.accountSaves, saves + 1);
      expect(h.observer.removed.length, removed, reason: 'A editor kept');

      applyB2.complete();
      await settleNetworkWidgets(tester);
      expect(f.datesMutationRequests, 2);
      expect(h.observer.removed.length, removed);
      expect(find.byKey(_datesSave), findsOneWidget, reason: 'A editor on top');
      base = f.count(_baseOp);
      final writes = f.datesMutationRequests;
      final ledger = f.ledger.length;
      await tester.tap(find.byKey(_datesSave));
      await settleNetworkWidgets(tester);
      final fence = f.ledger.sublist(ledger);
      expect(f.count(_baseOp), base + 1, reason: 'one A final fence read');
      expect(
        fence.where((request) => request.operation == _baseOp).single.item,
        _itemX,
      );
      expect(f.datesMutationRequests, writes, reason: '0 A START, 0 sends');
      expect(find.byKey(_feedback), findsOneWidget, reason: 'stale not sent');
    },
  );

  testWidgets(
    'D24 launcher: pop writer A while its write is held, push observer B; '
    'held until SETTLE, then one terminal reload',
    (tester) async {
      final h = await _mount(tester, launcher: true);
      final f = h.fixture;
      await tester.tap(find.text('open'));
      await settleNetworkWidgets(tester);
      expect(find.byKey(const ValueKey('page-a')), findsOneWidget);
      await _openDates(tester);
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_datesSave));
      await _until(tester, () => f.awaitingApply);
      await _popRoute(tester);
      expect(find.byKey(_datesSave), findsNothing);
      await _popRoute(tester);
      expect(find.byKey(const ValueKey('page-a')), findsNothing);

      final details = _details(h);
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await _until(tester, () => _details(h) == details + 1);
      await _drain(tester);
      final afterInitial = _details(h);
      expect(find.byKey(const ValueKey('page-b')), findsOneWidget);
      expect(find.byKey(_hold), findsOneWidget, reason: 'held while in flight');
      expect(_onPressed(tester, find.byKey(_datesEdit)), isNull);
      expect(_onPressed(tester, _refreshButton()), isNull);

      apply.complete();
      await settleNetworkWidgets(tester);
      expect(find.byKey(_hold), findsNothing);
      expect(_onPressed(tester, find.byKey(_datesEdit)), isNotNull);
      expect(_details(h), afterInitial + 1, reason: 'one terminal reload');
      expect(find.byKey(_unconfirmed), findsOneWidget);
      expect(f.datesMutationRequests, 1);
    },
  );
}

enum _Stage { beforeApply, ack, confirmRead }

Future<void> _sameStageGates(WidgetTester tester, _Stage stage) async {
  final fixture = WorkItemDatesParentFixture();
  fixture.status.item(group: false)
    ..labelIds = [...statusFixtureLabels.keys]
    ..assigneeIds = ['gid://gitlab/User/11']
    ..milestoneWidget = true
    ..milestoneId = 'gid://gitlab/Milestone/5'
    ..weightWidget = true
    ..weight = 3;
  final h = await _mount(tester, fixture: fixture, height: 3000);
  final f = h.fixture;
  await _expand(tester);
  final controls = <Finder>[
    _any(null, find.byKey(_statusEdit, skipOffstage: false)),
    _buttonWithText(null, '關閉工作項目'),
    _any(null, find.byKey(_labelsEdit, skipOffstage: false)),
    _any(null, find.byKey(_assigneesEdit, skipOffstage: false)),
    _any(null, find.byKey(_milestoneEdit, skipOffstage: false)),
    _any(null, find.byKey(_weightEdit, skipOffstage: false)),
  ];
  final refresh = _refreshButton();
  for (final control in [...controls, refresh]) {
    expect(_onPressed(tester, control), isNotNull, reason: '$control enabled');
  }

  await _openDates(tester);
  await _enterDates(tester, '2026-11-02', '2026-11-09');
  final gate = Completer<void>();
  bool held() => switch (stage) {
    _Stage.beforeApply => f.awaitingApply,
    _Stage.ack => f.awaitingAck,
    _Stage.confirmRead => f.awaitingConfirmRead,
  };
  switch (stage) {
    case _Stage.beforeApply:
      f.holdBeforeApply = gate;
    case _Stage.ack:
      f.holdAck = gate;
    case _Stage.confirmRead:
      f.holdNextConfirmRead = gate;
  }
  await tester.tap(find.byKey(_datesSave));
  await _until(tester, held);
  await _drain(tester);
  expect(find.byKey(_datesSave), findsOneWidget, reason: 'editor still open');
  expect(
    _onPressed(tester, find.byKey(_milestoneEdit, skipOffstage: false)),
    isNull,
    reason: 'Milestone edit',
  );
  expect(
    _onPressed(tester, find.byKey(_weightEdit, skipOffstage: false)),
    isNull,
    reason: 'Weight edit',
  );

  final ledger = f.ledger.length;
  final statusMutations = f.status.mutations;
  for (final control in [...controls, refresh]) {
    await _press(tester, control);
  }
  await _drain(tester);
  expect(f.ledger.length, ledger, reason: 'zero reads and writes while held');
  expect(f.status.mutations, statusMutations);
  expect(_onPressed(tester, controls.first), isNull, reason: 'Status edit');
  expect(_onPressed(tester, refresh), isNull, reason: 'refresh');
  expect(find.byKey(_hold, skipOffstage: false), findsOneWidget);

  gate.complete();
  await settleNetworkWidgets(tester);
  expect(find.byKey(_datesSave), findsNothing, reason: 'confirmed, closed');
  expect(find.text(_newStart), findsOneWidget);
  expect(find.byKey(_unconfirmed), findsNothing);
  expect(find.byKey(_stale), findsNothing);
  expect(f.datesMutationRequests, 1);
  expect(f.count(_baseOp), 3, reason: 'access, fence and one confirm read');
  expect(f.unhandled, isEmpty);
}

Future<void> _twoDatesWriters(
  WidgetTester tester, {
  required String winner,
}) async {
  final h = await _mount(tester, pages: 2);
  final f = h.fixture;
  final server = f.status.item(group: false);
  await _openDates(tester, page: 'a');
  final editorA = h.observer.pushed.last;
  await _enterDates(tester, '2026-11-02', '2026-11-09');
  await _press(tester, _any('b', find.byKey(_datesEdit, skipOffstage: false)));
  await settleNetworkWidgets(tester);
  final editorB = h.observer.pushed.last;
  expect(identical(editorA, editorB), isFalse);
  await _enterDates(tester, '2026-11-03', '2026-11-10');

  f.armFinalFence = true;
  await tester.tap(find.byKey(_datesSave));
  await _until(tester, () => f.awaitingFinalFenceReads == 1);
  final nonceB = f.parkedFenceNonces.single;
  await _press(tester, find.byKey(_datesSave, skipOffstage: false).first);
  await _until(tester, () => f.awaitingFinalFenceReads == 2);
  final nonceA = f.parkedFenceNonces.last;
  expect(nonceA, isNot(nonceB));

  final revision = server.updatedAt;
  final apply = Completer<void>();
  f.holdBeforeApply = apply;
  f.releaseFenceNonce(winner == 'a' ? nonceA : nonceB);
  await _until(tester, () => f.awaitingApply);
  expect(f.awaitingApply, isTrue, reason: 'winner held before the loser');
  expect(f.datesMutationRequests, 1);
  expect(server.updatedAt, revision, reason: 'nothing applied yet');

  f.releaseFenceNonce(winner == 'a' ? nonceB : nonceA);
  await _drain(tester);
  await _drain(tester);
  expect(f.datesMutationRequests, 1, reason: 'loser refused before START');
  expect(f.awaitingApply, isTrue);

  apply.complete();
  await settleNetworkWidgets(tester);
  expect(f.datesMutationRequests, 1);
  expect(f.datesApplied, 1);
  if (winner == 'a') {
    expect(h.observer.removed, [editorA], reason: 'covered winner removed');
    expect(find.byKey(_datesSave), findsOneWidget, reason: 'B editor stays');
  } else {
    expect(h.observer.popped, contains(editorB));
    expect(h.observer.removed, isEmpty);
    expect(find.byKey(_datesSave), findsOneWidget, reason: 'A editor stays');
  }
  expect(_has('a', _hold), findsNothing);
  expect(_has('b', _hold), findsNothing);
  expect(f.unhandled, isEmpty);
}

Future<void> _mixedWriters(
  WidgetTester tester, {
  required bool datesWins,
}) async {
  final h = await _mount(tester, pages: 2);
  final f = h.fixture;
  await _expand(tester, page: 'b');
  await _openDates(tester, page: 'a');
  await _enterDates(tester, '2026-11-02', '2026-11-09');
  f.armFinalFence = true;
  await tester.tap(find.byKey(_datesSave));
  await _until(tester, () => f.awaitingFinalFenceReads == 1);
  final nonceA = f.parkedFenceNonces.single;

  await _press(tester, _any('b', find.byKey(_statusEdit, skipOffstage: false)));
  await settleNetworkWidgets(tester);
  expect(find.byKey(_statusSave), findsOneWidget, reason: 'B Status editor');
  await _chooseStatus(tester, _canceled);
  final preflight = Completer<void>();
  f.status.holdNextRead = preflight;
  final reads = f.status.count(_statusReadOp);
  await tester.tap(find.byKey(_statusSave));
  await _until(tester, () => f.status.count(_statusReadOp) == reads + 1);
  await _drain(tester);
  expect(f.status.heldCount, 1, reason: 'B Status in its pre-START read');

  if (datesWins) {
    final apply = Completer<void>();
    f.holdBeforeApply = apply;
    f.releaseFenceNonce(nonceA);
    await _until(tester, () => f.awaitingApply);
    expect(f.awaitingApply, isTrue, reason: 'Dates held before B answered');
    await tester.idle();
    await tester.pump();
    final bEdit = _any('b', find.byKey(_statusEdit, skipOffstage: false));
    expect(_onPressed(tester, bEdit), isNull, reason: 'B Status edit disabled');
    preflight.complete();
    await _drain(tester);
    await _drain(tester);
    expect(f.status.count(_statusWriteOp), 0, reason: 'zero Status START');
    expect(f.datesMutationRequests, 1);
    apply.complete();
    await settleNetworkWidgets(tester);
    expect(f.datesApplied, 1);
    expect(f.status.count(_statusWriteOp), 0);
  } else {
    final statusApply = Completer<void>();
    f.status.holdBeforeApply = statusApply;
    preflight.complete();
    await _until(tester, () => f.status.awaitingApply);
    expect(f.status.awaitingApply, isTrue, reason: 'Status held first');
    f.releaseFenceNonce(nonceA);
    await _drain(tester);
    await _drain(tester);
    expect(f.datesMutationRequests, 0, reason: 'zero Dates START');
    expect(f.status.count(_statusWriteOp), 1);
    statusApply.complete();
    await settleNetworkWidgets(tester);
    expect(f.status.appliedMutationNonces, [1]);
    expect(f.datesMutationRequests, 0);
  }
  expect(f.unhandled, isEmpty);
}

class _Observer extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  final popped = <Route<dynamic>>[];
  final removed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      pushed.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      popped.add(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      removed.add(route);
}

typedef _Mounted = ({
  WorkItemDatesParentFixture fixture,
  SessionController session,
  MemoryAccountStore store,
  Account account,
  GitLabApi api,
  _Observer observer,
  ValueNotifier<int> rebind,
});

Future<_Mounted> _mount(
  WidgetTester tester, {
  WorkItemDatesParentFixture? fixture,
  int pages = 1,
  bool launcher = false,
  bool injected = false,
  List<Account> seeded = const [],
  double? width,
  double height = 2200,
  double textScale = 1,
}) async {
  final server = fixture ?? WorkItemDatesParentFixture();
  final store = MemoryAccountStore()..accounts = [...seeded];
  final session = controllerFor(store, server.adapter);
  final rebind = ValueNotifier<int>(1);
  final observer = _Observer();
  // Tear-downs run last-in first-out: holds, then clients, then session.
  addTearDown(rebind.dispose);
  addTearDown(session.dispose);
  addTearDown(server.closeAll);
  addTearDown(server.releaseHolds);
  final surfaceWidth = width ?? (pages == 4 ? 1560.0 : pages * 420.0);
  await tester.binding.setSurfaceSize(Size(surfaceWidth, height));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(session.initialize);
  await tester.runAsync(
    () => session.connect('https://example.com/gitlab', 'synthetic-test-token'),
  );
  final account = session.active!;
  final api = session.api!;
  expect(account.key, server.account.key);
  bool isCurrent() =>
      session.active?.key == account.key && identical(session.api, api);
  Widget page(String id) => GraphWorkItemDetailPage.project(
    key: ValueKey('page-$id'),
    account: account,
    api: api,
    project: _project,
    iid: WorkItemStatusFixture.sharedIid,
    isCurrent: isCurrent,
    ownerChanges: session,
  );
  var opened = 0;
  final Widget home;
  if (launcher) {
    home = Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () {
            final id = String.fromCharCode(0x61 + opened++);
            unawaited(
              Navigator.of(
                context,
              ).push(MaterialPageRoute<void>(builder: (_) => page(id))),
            );
          },
          child: const Text('open'),
        ),
      ),
    );
  } else if (injected) {
    home = ValueListenableBuilder<int>(
      valueListenable: rebind,
      builder: (context, generation, child) => GraphWorkItemDetailPage.project(
        key: const ValueKey('page-a'),
        account: account,
        api: api,
        project: _project,
        iid: WorkItemStatusFixture.sharedIid,
        isCurrent: isCurrent,
        sessionGeneration: generation,
      ),
    );
  } else if (pages == 4) {
    final clientD = server.replaceApi();
    Widget sized(Widget child) => SizedBox(width: 390, child: child);
    home = Row(
      children: [
        sized(page('a')),
        sized(page('b')),
        sized(
          GraphWorkItemDetailPage.namespace(
            key: const ValueKey('page-c'),
            account: account,
            api: api,
            namespacePath: WorkItemStatusFixture.groupRef.fullPath,
            expectedNamespaceId: WorkItemStatusFixture.groupRef.id,
            iid: WorkItemStatusFixture.sharedIid,
            isCurrent: isCurrent,
            ownerChanges: session,
          ),
        ),
        sized(
          GraphWorkItemDetailPage.project(
            key: const ValueKey('page-d'),
            account: account,
            api: clientD,
            project: _project,
            iid: WorkItemStatusFixture.sharedIid,
            isCurrent: () => true,
            sessionGeneration: 1,
          ),
        ),
      ],
    );
  } else if (pages == 2) {
    home = Row(
      children: [
        Expanded(child: page('a')),
        Expanded(child: page('b')),
      ],
    );
  } else {
    home = page('a');
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sessionProvider.overrideWithValue(session)],
      child: MaterialApp(
        navigatorObservers: [observer],
        builder: textScale == 1
            ? null
            : (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
        home: home,
      ),
    ),
  );
  await settleNetworkWidgets(tester);
  return (
    fixture: server,
    session: session,
    store: store,
    account: account,
    api: api,
    observer: observer,
    rebind: rebind,
  );
}

int _details(_Mounted h, {String tag = 'primary', String item = _itemX}) =>
    h.fixture.detailReads(tag: tag, item: item);

/// Onstage finder scoped to one page.
Finder _in(String? page, Finder finder) => page == null
    ? finder
    : find.descendant(of: find.byKey(ValueKey('page-$page')), matching: finder);

/// Finder scoped to one page that also sees content covered by a route.
Finder _any(String? page, Finder finder) => page == null
    ? finder
    : find.descendant(
        of: find.byKey(ValueKey('page-$page'), skipOffstage: false),
        matching: finder,
        skipOffstage: false,
      );

Finder _has(String page, Key key) =>
    _any(page, find.byKey(key, skipOffstage: false));

Finder _buttonWithText(String? page, String text) => _any(
  page,
  find.ancestor(
    of: find.text(text, skipOffstage: false),
    matching: find.byWidgetPredicate(
      (widget) => widget is ButtonStyleButton,
      skipOffstage: false,
    ),
  ),
);

Finder _refreshButton({String? page}) => _any(
      page,
      find.ancestor(
        of: find.byIcon(Icons.refresh, skipOffstage: false),
        matching: find.byType(IconButton, skipOffstage: false),
      ),
    );

State<StatefulWidget> _controlState(WidgetTester tester, {String? page}) =>
    tester.state<State<StatefulWidget>>(
      _any(page, find.byType(WorkItemDatesControl, skipOffstage: false)),
    );

VoidCallback? _onPressed(WidgetTester tester, Finder finder) =>
    switch (tester.widget(finder)) {
      ButtonStyleButton(:final onPressed) => onPressed,
      IconButton(:final onPressed) => onPressed,
      final other => throw StateError('not a button: $other'),
    };

/// Invokes the real button's own callback, including when another route
/// covers it. A disabled button is a refusal too.
Future<void> _press(WidgetTester tester, Finder finder) async {
  _onPressed(tester, finder)?.call();
  await _drain(tester);
}

Future<void> _openDates(WidgetTester tester, {String? page}) async {
  final edit = _in(page, find.byKey(_datesEdit));
  await tester.ensureVisible(edit);
  await tester.pump();
  await tester.tap(edit);
  await settleNetworkWidgets(tester);
  expect(find.byKey(_datesSave), findsOneWidget);
}

Future<void> _enterDates(WidgetTester tester, String start, String due) async {
  await tester.enterText(find.byKey(_startInput), start);
  await tester.enterText(find.byKey(_dueInput), due);
  await tester.pump();
}

Future<void> _expand(WidgetTester tester, {String? page}) async {
  final title = _in(page, find.text('屬性'));
  await tester.ensureVisible(title);
  await tester.pump();
  await tester.tap(title);
  await settleNetworkWidgets(tester);
}

Future<void> _openStatus(WidgetTester tester, {String? page}) async {
  final edit = _in(page, find.byKey(_statusEdit));
  await tester.ensureVisible(edit);
  await tester.pump();
  await tester.tap(edit);
  await settleNetworkWidgets(tester);
  expect(find.byKey(_statusSave), findsOneWidget);
}

Future<void> _chooseStatus(WidgetTester tester, String id) async {
  final row = find.byKey(ValueKey('work-item-status-choice-$id'));
  await tester.scrollUntilVisible(
    row,
    120,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey('work-item-status-scroll')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.tap(row);
  await tester.pump();
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// Pops the top route and pumps a bounded transition.
Future<void> _popRoute(WidgetTester tester) async {
  await tester.pageBack();
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}

/// Lets in-flight fake HTTP work reach the adapter without settling held
/// gates; bounded, never pumpAndSettle.
Future<void> _drain(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await _frames(tester);
}

/// Real event-loop turns with the test clock frozen: frames are produced but
/// no animation advances.
Future<void> _frozenTurns(WidgetTester tester, bool Function() done) async {
  for (var turn = 0; turn < 60 && !done(); turn++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 2)),
    );
    await tester.pump(Duration.zero);
  }
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
