// Real GraphWorkItemDetailPage + the production WorkItemHealthControl against a
// synthetic server. Observation is only through widgets, the navigator and
// the fixture ledgers; no page private is read.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/core/work_item_health_edit_models.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_health.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/widget_settle.dart';
import 'support/work_item_health_fixture.dart';
import 'support/work_item_health_parent_fixture.dart';
import 'support/work_item_status_fixture.dart';

const _project = Project(id: 42, name: 'mobile', path: 'studio/mobile');
const _itemX = WorkItemHealthParentFixture.itemX;
const _itemY = WorkItemHealthParentFixture.itemY;
const _canceled = WorkItemStatusFixture.statusCanceled;

const _section = ValueKey('work-item-health-section');
const _controlSlot = ValueKey('work-item-health-control-slot');
const _hold = ValueKey('work-item-health-hold');
const _stale = ValueKey('work-item-health-stale');
const _unconfirmed = ValueKey('work-item-health-unconfirmed');

const _healthEdit = ValueKey('work-item-health-edit');
const _healthSave = ValueKey('work-item-health-save');
const _healthCancel = ValueKey('work-item-health-cancel');
const _healthFeedback = ValueKey('work-item-health-feedback');
const _healthReadOnly = ValueKey('work-item-health-read-only');
const _attributeHealth = ValueKey('work-item-attribute-health');

const _datesEdit = ValueKey('work-item-dates-edit');
const _datesSave = ValueKey('work-item-dates-save');
const _statusEdit = ValueKey('work-item-status-edit');
const _statusSave = ValueKey('work-item-status-save');
const _statusBanner = ValueKey('work-item-status-hold-banner');
const _labelsEdit = ValueKey('work-item-labels-edit');
const _assigneesEdit = ValueKey('work-item-assignees-edit');
const _milestoneEdit = ValueKey('work-item-milestone-edit');
const _weightEdit = ValueKey('work-item-weight-edit');

const _healthEditOp = WorkItemHealthParentFixture.editOp;
const _healthMutationOp = WorkItemHealthParentFixture.mutationOp;
const _statusReadOp = 'MobileWorkItemStatus';
const _statusWriteOp = 'MobileUpdateWorkItemStatus';
const _lifecycleWriteOp = 'MobileUpdateWorkItemState';

void main() {
  test(
    'H0 fixture shapes parse through production detail, access and write APIs '
    '(present, absent, widgetsUnavailable, rollup)',
    () async {
      for (final shape in const ['present', 'absent', 'widgetsUnavailable', 'rollup']) {
        final fixture = WorkItemHealthParentFixture();
        addTearDown(fixture.closeAll);
        final state = fixture.health[_itemX]!;
        if (shape == 'absent') {
          state.widgets = HealthWidgetMode.absent;
          fixture.dates.healthWidget = false;
        } else if (shape == 'widgetsUnavailable') {
          state.widgets = HealthWidgetMode.unavailable;
          fixture.dates.healthWidget = false;
        } else if (shape == 'rollup') {
          state.rolledUp = const [
            {'healthStatus': 'onTrack', 'count': 2},
            {'healthStatus': 'needsAttention', 'count': 1},
          ];
        }
        final api = fixture.primaryApi();
        final detail = await api.projectWorkItem(
          _project,
          WorkItemStatusFixture.sharedIid,
        );
        if (shape == 'present' || shape == 'rollup') {
          expect(detail.widgetTypes.contains('HEALTH_STATUS'), isTrue, reason: shape);
        } else {
          expect(detail.widgetTypes.contains('HEALTH_STATUS'), isFalse, reason: shape);
        }

        final access = await api.workItemHealthEdit(
          detail,
          expectedUserId: fixture.account.user.id,
          generation: 1,
          isCurrent: () => true,
        );
        if (shape == 'present' || shape == 'rollup') {
          expect(access.canWrite, isTrue, reason: shape);
          expect(access.snapshot.value, isNotNull, reason: shape);
          if (shape == 'rollup') {
            expect(access.snapshot.rolledUp!.length, 2, reason: shape);
          }
        }

        if (access.canWrite && access.target != null) {
          var started = 0;
          final result = await api.updateWorkItemHealthStatus(
            access.target!,
            desired: WorkItemHealthEditValue.needsAttention,
            generation: 1,
            isCurrent: () => true,
            onMutationSent: () => started++,
          );
          expect(result.status, WorkItemHealthEditSaveStatus.success, reason: shape);
          expect(started, 1, reason: shape);
          expect(fixture.healthMutationRequests, 1, reason: shape);
          expect(fixture.healthApplied, 1, reason: shape);
          expect(fixture.count(_healthMutationOp), 1, reason: shape);
        }
        expect(fixture.unhandled, isEmpty, reason: shape);
      }
    },
  );

  testWidgets(
    'H1 one Health control inside keyed 健康狀態 section; zero Health requests '
    'before tap; read-only without captured session generation; omitted when widget absent',
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
      expect(find.byType(WorkItemHealthControl), findsOneWidget);
      expect(find.byKey(_healthEdit), findsOneWidget);
      expect(h.fixture.count(_healthEditOp), 0);
      expect(h.fixture.count(_healthMutationOp), 0);

      // Mount without session generation: read-only
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
      expect(find.byKey(_section), findsOneWidget);
      expect(find.byKey(_healthEdit), findsNothing, reason: 'no generation');
      expect(h.fixture.count(_healthEditOp), 0);

      // Mount with widget absent: omitted
      final absentFixture = WorkItemHealthParentFixture();
      absentFixture.health[_itemX]!.widgets = HealthWidgetMode.absent;
      absentFixture.dates.healthWidget = false;
      final hAbsent = await _mount(tester, fixture: absentFixture);
      expect(find.byKey(_section), findsNothing, reason: 'widget absent');
      expect(hAbsent.fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'H2 applied write: State continuity through START, confirmed, exactly one parent read; '
    'panel Health row is sole value readout; single-pump observable',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _expand(tester);
      await _openHealth(tester);
      final editor = h.observer.pushed.last;
      final control = _controlState(tester);
      await _chooseHealth(tester, 'needsAttention');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => f.awaitingApply);
      expect(identical(_controlState(tester), control), isTrue);
      expect(
        find.descendant(
          of: find.byKey(_section, skipOffstage: false),
          matching: find.byKey(_hold, skipOffstage: false),
          skipOffstage: false,
        ),
        findsOneWidget,
        reason: 'hold line inside section',
      );
      expect(h.observer.removed, isEmpty);
      final details = _details(h);
      final attributes = f.attributeReads();

      apply.complete();
      for (var i = 0; i < 200 && _details(h) < details + 1; i++) {
        await tester.binding.delayed(const Duration(milliseconds: 1));
      }
      expect(
        _details(h),
        details + 1,
        reason: 'SETTLE reached: writer reload dispatched before any frame',
      );
      await tester.binding.delayed(const Duration(milliseconds: 10));
      // Single pump observable: hold line gone, final confirmed state rendered
      await tester.pump();
      expect(find.byKey(_hold, skipOffstage: false), findsNothing);
      expect(find.byKey(_unconfirmed), findsNothing, reason: 'M1i own-write confirmed');

      await settleNetworkWidgets(tester);
      expect(h.observer.removed, [editor], reason: 'removed only after applied');
      expect(h.observer.popped, isEmpty);
      expect(identical(_controlState(tester), control), isTrue);
      expect(f.healthMutationRequests, 1);
      expect(_details(h), details + 1, reason: 'exactly one parent read');
      expect(f.attributeReads(), attributes + 1, reason: 'one attribute read');
      expect(find.byKey(_attributeHealth), findsOneWidget);
      expect(find.text('目前：需關注'), findsOneWidget);
      expect(find.byKey(_hold), findsNothing);
      expect(find.byKey(_stale), findsNothing);
      expect(find.byKey(_unconfirmed), findsNothing);
      expect(_onPressed(tester, find.byKey(_healthEdit)), isNotNull);
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    'H3 coherent lagging fresh read (with lagNextDetail); unconfirmed-after-confirmed retains floor',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _expand(tester);
      await _openHealth(tester);
      await _chooseHealth(tester, 'needsAttention');
      final details = _details(h);
      final held = Completer<void>();
      f
        ..lagNextDetail = true
        ..status.holdNextDetail = held;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => _details(h) == details + 1);
      await tester.pump(const Duration(seconds: 1));
      await _drain(tester);
      expect(find.byKey(_healthSave), findsOneWidget, reason: 'editor stays open on lag');
      await tester.tap(find.byKey(_healthCancel));
      await settleNetworkWidgets(tester);
      expect(find.byKey(_stale), findsOneWidget, reason: 'stale while held');
      expect(find.text('目前：需關注'), findsNothing, reason: 'panel drops loaded value');
      expect(
        find.descendant(
          of: find.byKey(_attributeHealth),
          matching: find.text('尚未確認最新健康狀態。請重新整理後再查看。'),
        ),
        findsOneWidget,
      );

      held.complete();
      await settleNetworkWidgets(tester);
      expect(f.lagNextDetail, isFalse, reason: 'lagged read served');
      expect(find.byKey(_stale), findsOneWidget);

      // Unconfirmed write following confirmed write retains floor
      await _openHealth(tester);
      await _chooseHealth(tester, 'atRisk');
      f.loseNextAck = true;
      await tester.tap(find.byKey(_healthSave));
      await settleNetworkWidgets(tester);
      expect(find.byKey(_unconfirmed), findsOneWidget);

      await tester.tap(_refreshButton());
      await settleNetworkWidgets(tester);
      expect(find.byKey(_stale), findsNothing);
      expect(find.byKey(_unconfirmed), findsNothing);
      expect(f.healthMutationRequests, 2);
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    'H4a Status _withSummary or _applyStateSnapshot bump does NOT advance '
    '_healthDetailRevision or clear Health stale',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _expand(tester);
      await _openHealth(tester);
      await _chooseHealth(tester, 'needsAttention');
      f.lagNextDetail = true;
      await tester.tap(find.byKey(_healthSave));
      await settleNetworkWidgets(tester);
      expect(find.byKey(_healthSave), findsOneWidget, reason: 'editor stays open on lag');
      await tester.tap(find.byKey(_healthCancel));
      await settleNetworkWidgets(tester);
      expect(find.byKey(_stale), findsOneWidget, reason: 'positive control stale');

      final details = _details(h);
      await _openStatus(tester);
      await _chooseStatus(tester, _canceled);
      await tester.tap(find.byKey(_statusSave));
      await settleNetworkWidgets(tester);
      expect(f.status.count(_statusWriteOp), 1);
      expect(find.text('不處理'), findsWidgets, reason: 'Status confirmed');
      expect(_details(h), details, reason: 'zero further detail reads');
      expect(find.byKey(_stale), findsOneWidget, reason: 'Health floor not cleared');
      expect(
        find.descendant(
          of: find.byKey(_attributeHealth),
          matching: find.text('尚未確認最新健康狀態。請重新整理後再查看。'),
        ),
        findsOneWidget,
      );

      await tester.tap(_refreshButton());
      await settleNetworkWidgets(tester);
      expect(find.byKey(_stale), findsNothing);
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    "H4b confirmed Dates write's post-SETTLE full detail DOES advance "
    '_healthDetailRevision and clears Health stale',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _expand(tester);
      await _openHealth(tester);
      await _chooseHealth(tester, 'needsAttention');
      f.lagNextDetail = true;
      await tester.tap(find.byKey(_healthSave));
      await settleNetworkWidgets(tester);
      expect(find.byKey(_healthSave), findsOneWidget, reason: 'editor stays open on lag');
      await tester.tap(find.byKey(_healthCancel));
      await settleNetworkWidgets(tester);
      expect(find.byKey(_stale), findsOneWidget);

      await _openDates(tester);
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      await tester.tap(find.byKey(_datesSave));
      await settleNetworkWidgets(tester);
      expect(f.dates.datesMutationRequests, 1);
      expect(find.byKey(_stale), findsNothing, reason: 'full detail reload clears Health stale');
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    'H5 clearing health status write: desired null (未設定)',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _expand(tester);
      await _openHealth(tester);
      final control = _controlState(tester);
      await _chooseHealth(tester, 'clear');
      await tester.tap(find.byKey(_healthSave));
      await settleNetworkWidgets(tester);
      final w = f.mutationInputs.single['healthStatusWidget'] as Map;
      expect(w.containsKey('healthStatus'), isTrue);
      expect(w['healthStatus'], isNull, reason: 'desired null');
      expect(h.observer.removed, isNotEmpty, reason: 'editor removed on bumped reload');
      expect(h.observer.popped, isEmpty);
      expect(identical(_controlState(tester), control), isTrue);
      expect(find.byKey(_attributeHealth), findsOneWidget);
      expect(find.text('目前：未設定'), findsOneWidget);
      expect(find.byKey(_unconfirmed), findsNothing);
      expect(find.byKey(_stale), findsNothing);
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    'H6 lost ACK: unknown outcome, never retried; automatic reloads do not acknowledge; '
    'second lost ACK shows unconfirmed again',
    (tester) async {
      final h = await _mount(tester, pages: 2);
      final f = h.fixture;
      await _openHealth(tester, page: 'a');
      await _chooseHealth(tester, 'needsAttention');
      final details = _details(h);
      f.loseNextAck = true;
      await tester.tap(find.byKey(_healthSave));
      await settleNetworkWidgets(tester);
      expect(f.healthMutationRequests, 1);
      expect(f.healthApplied, 1);
      expect(h.observer.removed, isNotEmpty, reason: 'SETTLE reload with bumped updatedAt dismissed editor');
      expect(_details(h), details + 2, reason: 'one reload per page');
      expect(_has('a', _unconfirmed), findsOneWidget);
      expect(f.healthMutationRequests, 1, reason: 'never retried');

      // Cross-page Status settle reload does not acknowledge
      await _expand(tester, page: 'b');
      await _openStatus(tester, page: 'b');
      await _chooseStatus(tester, _canceled);
      final reloads = _details(h);
      await tester.tap(find.byKey(_statusSave));
      await settleNetworkWidgets(tester);
      expect(f.status.count(_statusWriteOp), 1);
      expect(_details(h), reloads + 1);
      expect(_has('a', _unconfirmed), findsOneWidget, reason: 'automatic reload keeps unconfirmed');

      // Manual refresh on A clears A only
      await tester.tap(_refreshButton(page: 'a'));
      await settleNetworkWidgets(tester);
      expect(_has('a', _unconfirmed), findsNothing);
      expect(_has('b', _unconfirmed), findsOneWidget, reason: 'A only');

      // Second lost ACK shows unconfirmed again
      await _openHealth(tester, page: 'a');
      await _chooseHealth(tester, 'atRisk');
      f.loseNextAck = true;
      await tester.tap(find.byKey(_healthSave));
      await settleNetworkWidgets(tester);
      expect(_has('a', _unconfirmed), findsOneWidget, reason: 'shows unconfirmed again');
      expect(f.healthMutationRequests, 2);
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    'H6b post-SETTLE reload failure deterministically keeps stale line and hides chips',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _openHealth(tester);
      await _chooseHealth(tester, 'needsAttention');
      final details = _details(h);
      f.status.failNextDetail = true;
      await tester.tap(find.byKey(_healthSave));
      await settleNetworkWidgets(tester);
      expect(f.status.failNextDetail, isFalse, reason: 'reload got 503');
      expect(_details(h), details + 1);
      expect(find.byKey(_healthSave), findsOneWidget, reason: 'editor stays open on failed reload');
      await tester.tap(find.byKey(_healthCancel));
      await settleNetworkWidgets(tester);
      expect(find.byKey(_section), findsOneWidget, reason: 'detail kept');
      expect(find.byKey(_stale), findsOneWidget);
      expect(_onPressed(tester, _refreshButton()), isNotNull);
      expect(f.healthMutationRequests, 1);
    },
  );

  testWidgets(
    'H7 capability denial / read-only: unsupported or unauthorized',
    (tester) async {
      final fixture = WorkItemHealthParentFixture();
      fixture.health[_itemX]!.adminWorkItem = false;
      final h = await _mount(tester, fixture: fixture);
      await _openHealth(tester);
      expect(find.byKey(_healthReadOnly), findsOneWidget);
      expect(find.text('目前帳號沒有管理這個工作項目健康狀態的權限，僅供檢視。'), findsOneWidget);
      expect(_onPressed(tester, find.byKey(_healthSave)), isNull);
      await tester.tap(find.byKey(_healthSave), warnIfMissed: false);
      await _drain(tester);
      expect(h.fixture.healthMutationRequests, 0);
      expect(find.byKey(_hold, skipOffstage: false), findsNothing);
    },
  );

  testWidgets('H8 POST_SENT_BEFORE_APPLY same-page gates', (tester) async {
    await _sameStageGates(tester, _Stage.beforeApply);
  });

  testWidgets('H9 POST_APPLY_ACK hold keeps same gates', (tester) async {
    await _sameStageGates(tester, _Stage.ack);
  });

  testWidgets(
    'H10 POST_ACK_CONFIRM_READ hold keeps gates; own readback not cancelled',
    (tester) async {
      await _sameStageGates(tester, _Stage.confirmRead);
    },
  );

  testWidgets(
    'H11a same-page Status START during held Health FINAL_FENCE_READ',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _expand(tester);
      await _openHealth(tester);
      await _chooseHealth(tester, 'needsAttention');
      f.armFinalFence = true;
      await tester.tap(find.byKey(_healthSave));
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
      expect(f.healthMutationRequests, 0, reason: 'zero Health sends');
      await _drain(tester);
      await _drain(tester);
      expect(find.byKey(_hold, skipOffstage: false), findsNothing);
      expect(find.byKey(_unconfirmed), findsNothing);

      statusApply.complete();
      await settleNetworkWidgets(tester);
      expect(f.status.count(_statusWriteOp), 1);
      expect(f.healthMutationRequests, 0);
    },
  );

  testWidgets(
    'H11b same-page Dates START during held Health FINAL_FENCE_READ',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _openHealth(tester);
      await _chooseHealth(tester, 'needsAttention');
      f.armFinalFence = true;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => f.awaitingFinalFenceReads == 1);

      await _press(tester, _any(null, find.byKey(_datesEdit, skipOffstage: false)));
      await settleNetworkWidgets(tester);
      await _enterDates(tester, '2026-11-02', '2026-11-09');
      final datesApply = Completer<void>();
      f.dates.holdBeforeApply = datesApply;
      await tester.tap(find.byKey(_datesSave));
      await _until(tester, () => f.dates.awaitingApply);

      f.releaseFenceNonce(f.parkedFenceNonces.single);
      await _drain(tester);
      await _drain(tester);
      expect(f.healthMutationRequests, 0, reason: 'zero Health sends');
      expect(find.byKey(_hold, skipOffstage: false), findsNothing);
      expect(find.byKey(_unconfirmed), findsNothing);

      datesApply.complete();
      await settleNetworkWidgets(tester);
      expect(f.dates.datesMutationRequests, 1);
      expect(f.healthMutationRequests, 0);
    },
  );

  testWidgets(
    'H11c same-page lifecycle write during held Health FINAL_FENCE_READ',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _openHealth(tester);
      await _chooseHealth(tester, 'needsAttention');
      f.armFinalFence = true;
      await tester.tap(find.byKey(_healthSave));
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
      expect(f.healthMutationRequests, 0, reason: 'zero Health sends');
      expect(find.byKey(_hold, skipOffstage: false), findsNothing);
      expect(find.byKey(_unconfirmed), findsNothing);

      lifecycle.complete();
      await settleNetworkWidgets(tester);
      expect(f.healthMutationRequests, 0);
    },
  );

  testWidgets(
    'H11d real owner loss during held Health FINAL_FENCE_READ',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _openHealth(tester);
      await _chooseHealth(tester, 'needsAttention');
      f.armFinalFence = true;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => f.awaitingFinalFenceReads == 1);

      await tester.runAsync(() => h.session.endSession());
      await tester.runAsync(() => h.session.select(h.session.accounts.single));
      await _frames(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(_healthSave, skipOffstage: false), findsNothing);
      expect(h.observer.removed, isNotEmpty, reason: 'editor removed');

      f.releaseFenceNonce(f.parkedFenceNonces.single);
      await settleNetworkWidgets(tester);
      expect(f.healthMutationRequests, 0, reason: 'zero Health sends');
      expect(find.byKey(_unconfirmed), findsNothing);
    },
  );

  testWidgets(
    'H12a two Health writers A/B in pre-START fence; release A then B; winner held before apply',
    (tester) async {
      await _twoHealthWriters(tester, winner: 'a');
    },
  );

  testWidgets(
    'H12b two Health writers A/B in pre-START fence; reversed release (B then A); winner held before apply',
    (tester) async {
      await _twoHealthWriters(tester, winner: 'b');
    },
  );

  testWidgets(
    'H12c mixed Health/Status pre-START cross-page: Status B winner held before apply, Health A loser released',
    (tester) async {
      await _mixedHealthStatusWriters(tester, healthWins: false);
    },
  );

  testWidgets(
    'H12d mixed Health/Status pre-START cross-page: Health A winner held before apply, Status B loser released',
    (tester) async {
      await _mixedHealthStatusWriters(tester, healthWins: true);
    },
  );

  testWidgets(
    'H12e mixed Health/Dates pre-START cross-page: Dates B winner held before apply, Health A loser released',
    (tester) async {
      await _mixedHealthDatesWriters(tester, healthWins: false);
    },
  );

  testWidgets(
    'H12f mixed Health/Dates pre-START cross-page: Health A winner held before apply, Dates B loser released',
    (tester) async {
      await _mixedHealthDatesWriters(tester, healthWins: true);
    },
  );

  testWidgets(
    "H13a cross-page Status/Dates START during A's held FINAL_FENCE_READ",
    (tester) async {
      final h = await _mount(tester, pages: 2);
      final f = h.fixture;
      await _expand(tester, page: 'b');
      await _openHealth(tester, page: 'a');
      await _chooseHealth(tester, 'needsAttention');
      f.armFinalFence = true;
      await tester.tap(find.byKey(_healthSave));
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
      expect(f.healthMutationRequests, 0, reason: 'A zero Health sends');
      expect(_has('a', _unconfirmed), findsNothing);

      statusApply.complete();
      await settleNetworkWidgets(tester);
      expect(f.status.count(_statusWriteOp), 1);
      expect(f.healthMutationRequests, 0);
    },
  );

  testWidgets('H13b cross-page holds in BOTH directions', (tester) async {
    final h = await _mount(tester, pages: 2);
    final f = h.fixture;
    await _expand(tester, page: 'a');
    await _expand(tester, page: 'b');
    await _openStatus(tester, page: 'b');
    await _chooseStatus(tester, _canceled);
    final statusApply = Completer<void>();
    f.status.holdBeforeApply = statusApply;
    await tester.tap(find.byKey(_statusSave));
    await _until(tester, () => f.status.awaitingApply);
    final aEdit = _any('a', find.byKey(_healthEdit, skipOffstage: false));
    expect(_onPressed(tester, aEdit), isNull, reason: 'A Health edit disabled');
    await _press(tester, aEdit);
    expect(f.count(_healthEditOp), 0, reason: 'zero Health reads');
    statusApply.complete();
    await settleNetworkWidgets(tester);
    expect(f.status.count(_statusWriteOp), 1);

    // Hold Dates on B -> A Health edit disabled
    await _openDates(tester, page: 'b');
    await _enterDates(tester, '2026-11-02', '2026-11-09');
    final datesApply = Completer<void>();
    f.dates.holdBeforeApply = datesApply;
    await tester.tap(find.byKey(_datesSave));
    await _until(tester, () => f.dates.awaitingApply);
    expect(_onPressed(tester, aEdit), isNull, reason: 'A Health edit disabled');
    await _press(tester, aEdit);
    expect(f.count(_healthEditOp), 0);
    datesApply.complete();
    await settleNetworkWidgets(tester);
    expect(f.dates.datesMutationRequests, 1);

    // Hold Health on B -> A Status and Dates edits disabled
    await _openHealth(tester, page: 'b');
    await _chooseHealth(tester, 'needsAttention');
    final healthApply = Completer<void>();
    f.holdBeforeApply = healthApply;
    await tester.tap(find.byKey(_healthSave));
    await _until(tester, () => f.awaitingApply);
    final aStatusEdit = _any('a', find.byKey(_statusEdit, skipOffstage: false));
    final aDatesEdit = _any('a', find.byKey(_datesEdit, skipOffstage: false));
    expect(_onPressed(tester, aStatusEdit), isNull, reason: 'A Status edit disabled');
    expect(_onPressed(tester, aDatesEdit), isNull, reason: 'A Dates edit disabled');
    healthApply.complete();
    await settleNetworkWidgets(tester);
    expect(f.healthMutationRequests, 1);
  });

  testWidgets(
    'H14 preflight-unsent: Cancel / system back during FINAL_FENCE_READ',
    (tester) async {
      final h = await _mount(tester, pages: 2);
      final f = h.fixture;
      await _openHealth(tester, page: 'a');
      final editor = h.observer.pushed.last;
      await _chooseHealth(tester, 'needsAttention');
      f.armFinalFence = true;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => f.awaitingFinalFenceReads == 1);
      final details = _details(h);
      await tester.tap(find.byKey(_healthCancel));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(h.observer.popped, [editor]);
      expect(_has('b', _hold), findsNothing);

      f.releaseFenceNonce(f.parkedFenceNonces.single);
      await settleNetworkWidgets(tester);
      expect(f.healthMutationRequests, 0, reason: 'zero START and sends');
      expect(_has('a', _hold), findsNothing);
      expect(_has('b', _hold), findsNothing, reason: 'observer never held');
      expect(_has('a', _unconfirmed), findsNothing);
      expect(_details(h), details, reason: 'zero extra detail reads');
    },
  );

  testWidgets(
    'H15 observer B blocked until SETTLE; concurrent 4-page mount (A, B, C, D); '
    'C and D independence; attributed ledger counts; single pump',
    (tester) async {
      final h = await _mount(tester, pages: 4, height: 844);
      final f = h.fixture;
      for (final page in const ['a', 'b', 'c', 'd']) {
        expect(
          _onPressed(tester, _any(page, find.byKey(_healthEdit, skipOffstage: false))),
          isNotNull,
          reason: 'page $page enabled before START',
        );
      }
      await _openHealth(tester, page: 'a');
      await _chooseHealth(tester, 'needsAttention');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => f.awaitingApply);
      await _drain(tester);

      expect(_has('b', _hold), findsOneWidget, reason: 'B held');
      expect(
        _onPressed(tester, _any('b', find.byKey(_healthEdit, skipOffstage: false))),
        isNull,
      );
      expect(_onPressed(tester, _refreshButton(page: 'b')), isNull);
      expect(_has('c', _hold), findsNothing, reason: 'other item');
      expect(
        _onPressed(tester, _any('c', find.byKey(_healthEdit, skipOffstage: false))),
        isNotNull,
      );
      expect(_has('d', _hold), findsNothing, reason: 'other client');
      expect(
        _onPressed(tester, _any('d', find.byKey(_healthEdit, skipOffstage: false))),
        isNotNull,
      );
      final xPrimary = _details(h);
      final yPrimary = _details(h, item: _itemY);
      final xClientD = _details(h, tag: 'client-d');

      apply.complete();
      for (var i = 0; i < 200 && _details(h) < xPrimary + 2; i++) {
        await tester.binding.delayed(const Duration(milliseconds: 1));
      }
      expect(
        _details(h),
        xPrimary + 2,
        reason: 'SETTLE reached: writer A + observer B reload dispatched before any frame (M1n)',
      );
      await tester.binding.delayed(const Duration(milliseconds: 10));
      // Single pump assertion
      await tester.pump();
      expect(_has('b', _hold), findsNothing, reason: 'B hold line gone on single pump');

      await settleNetworkWidgets(tester);
      expect(find.byKey(_healthSave), findsNothing, reason: 'A confirmed');
      expect(_has('b', _hold), findsNothing);
      expect(
        _onPressed(tester, _any('b', find.byKey(_healthEdit, skipOffstage: false))),
        isNotNull,
      );
      expect(_onPressed(tester, _refreshButton(page: 'b')), isNotNull);
      for (final page in const ['a', 'b']) {
        expect(_has(page, _stale), findsNothing, reason: page);
        expect(_has(page, _unconfirmed), findsNothing, reason: page);
      }
      expect(_details(h), xPrimary + 2, reason: 'A writer + B observer (M1n delta 2)');
      expect(_details(h, item: _itemY), yPrimary, reason: 'C untouched');
      expect(_details(h, tag: 'client-d'), xClientD, reason: 'D untouched');
      expect(f.healthMutationRequests, 1);
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    'H15b Cancel after START with normal ACK: honest confirmed outcome inside editor exit transition (frozen clock)',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _openHealth(tester);
      final editor = h.observer.pushed.last;
      await _chooseHealth(tester, 'needsAttention');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => f.awaitingApply);
      await tester.tap(find.byKey(_healthCancel));
      await tester.pump();
      expect(h.observer.popped, [editor]);

      apply.complete();
      await _frozenTurns(
        tester,
        () => find.byKey(_hold, skipOffstage: false).evaluate().isEmpty,
      );
      expect(find.byKey(_hold, skipOffstage: false), findsNothing);
      expect(
        find.byKey(_healthSave, skipOffstage: false),
        findsOneWidget,
        reason: 'editor still mounted in exit transition',
      );
      expect(h.observer.popped, [editor]);
      expect(h.observer.removed, isEmpty);
      expect(ModalRoute.of(tester.element(find.byKey(_section, skipOffstage: false)))!.isCurrent, isTrue);

      await tester.pump(const Duration(seconds: 1));
      await settleNetworkWidgets(tester);
      expect(find.byKey(const ValueKey('page-a')), findsOneWidget);
      expect(find.byKey(_unconfirmed), findsNothing, reason: 'outcome is confirmed');
      expect(find.byKey(_healthSave), findsNothing);
      expect(f.healthMutationRequests, 1);
    },
  );

  testWidgets(
    'H16 Cancel after START, transition completed: honest confirmed via observer',
    (tester) async {
      final h = await _mount(tester, pages: 2);
      final f = h.fixture;
      await _openHealth(tester, page: 'a');
      await _chooseHealth(tester, 'needsAttention');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => f.awaitingApply);
      await _popRoute(tester);
      expect(find.byKey(_healthSave, skipOffstage: false), findsNothing);
      expect(_has('b', _hold), findsOneWidget);
      expect(_onPressed(tester, _any('b', find.byKey(_healthEdit))), isNull);
      final details = _details(h);

      apply.complete();
      await settleNetworkWidgets(tester);
      for (final page in const ['a', 'b']) {
        expect(_has(page, _hold), findsNothing, reason: page);
        expect(_has(page, _unconfirmed), findsNothing, reason: 'confirmed');
        expect(
          _onPressed(tester, _any(page, find.byKey(_healthEdit))),
          isNotNull,
          reason: page,
        );
      }
      expect(_details(h), details + 2, reason: 'one reload per page');
      expect(f.healthMutationRequests, 1);

      await tester.tap(_refreshButton(page: 'a'));
      await settleNetworkWidgets(tester);
      expect(_has('a', _unconfirmed), findsNothing);
    },
  );

  testWidgets(
    'H17a page rebind before START (didUpdateWidget sessionGeneration during fence read)',
    (tester) async {
      final h = await _mount(tester, injected: true);
      final f = h.fixture;
      await _openHealth(tester);
      await _chooseHealth(tester, 'needsAttention');
      f.armFinalFence = true;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => f.awaitingFinalFenceReads == 1);
      final details = _details(h);

      h.rebind.value = 2;
      await _frames(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(_healthSave, skipOffstage: false), findsNothing);

      f.releaseFenceNonce(f.parkedFenceNonces.single);
      await settleNetworkWidgets(tester);
      expect(f.healthMutationRequests, 0, reason: 'zero START and sends');
      expect(_details(h), details + 1, reason: 'new session detail');
      expect(_onPressed(tester, find.byKey(_healthEdit)), isNotNull);
      expect(find.byKey(_unconfirmed), findsNothing);
      expect(identical(h.session.api, h.api), isTrue);
    },
  );

  testWidgets(
    'H17b page rebind after START (didUpdateWidget sessionGeneration during held write)',
    (tester) async {
      final h = await _mount(tester, injected: true);
      final f = h.fixture;
      await _openHealth(tester);
      final before = _controlState(tester);
      await _chooseHealth(tester, 'needsAttention');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => f.awaitingApply);
      final generation = h.session.generation;
      final details = _details(h);

      h.rebind.value = 2;
      await _frames(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(h.session.generation, generation);
      expect(_details(h), details + 1, reason: 'rebound reloads once');
      expect(find.byKey(_healthSave, skipOffstage: false), findsNothing);
      expect(identical(_controlState(tester), before), isFalse);

      apply.complete();
      await settleNetworkWidgets(tester);
      expect(f.healthMutationRequests, 1);
      expect(find.byKey(_hold), findsNothing);
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    'H18 owner away and back during a held write never paints',
    (tester) async {
      final h = await _mount(tester);
      final f = h.fixture;
      await _openHealth(tester);
      await _chooseHealth(tester, 'needsAttention');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => f.awaitingApply);

      await tester.runAsync(() => h.session.endSession());
      await tester.runAsync(() => h.session.select(h.session.accounts.single));
      await _frames(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(_healthSave, skipOffstage: false), findsNothing);

      apply.complete();
      await settleNetworkWidgets(tester);
      expect(find.byKey(_attributeHealth), findsNothing);
      expect(f.healthMutationRequests, 1);
    },
  );

  testWidgets('H19 manual refresh gate while held', (tester) async {
    final h = await _mount(tester);
    final f = h.fixture;
    await _openHealth(tester);
    await _chooseHealth(tester, 'needsAttention');
    final apply = Completer<void>();
    f.holdBeforeApply = apply;
    await tester.tap(find.byKey(_healthSave));
    await _until(tester, () => f.awaitingApply);
    final refresh = _refreshButton();
    expect(_onPressed(tester, refresh), isNull, reason: 'refresh disabled while held');
    final details = _details(h);
    await _press(tester, refresh);
    expect(_details(h), details, reason: 'zero detail reads');
    apply.complete();
    await settleNetworkWidgets(tester);
    expect(_onPressed(tester, refresh), isNotNull);
  });

  testWidgets('H20 no-op save', (tester) async {
    final h = await _mount(tester);
    final f = h.fixture;
    await _openHealth(tester);
    final details = _details(h);
    // onTrack is already selected
    await tester.tap(find.byKey(_healthSave));
    await tester.pump();
    expect(find.byKey(_hold, skipOffstage: false), findsNothing);
    await settleNetworkWidgets(tester);
    expect(find.byKey(_healthSave), findsOneWidget, reason: 'editor stays open on noop');
    expect(find.text('健康狀態已是「正常」，沒有送出變更。'), findsOneWidget);
    expect(find.byKey(_hold), findsNothing);
    expect(f.healthMutationRequests, 0);
    expect(f.count(_healthEditOp), 2, reason: 'opening read + update preflight');
    expect(_details(h), details, reason: 'no reload');
  });

  testWidgets(
    'H21 320 dp at 2.0x text scale; attributes panel block text and parked read purge',
    (tester) async {
      final h = await _mount(tester, width: 320, height: 5200, textScale: 2);
      final f = h.fixture;
      final edit = find.byKey(_healthEdit);
      await tester.ensureVisible(edit);
      await tester.pump();
      expect(tester.getSize(edit).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(edit).height, greaterThanOrEqualTo(48));
      // Expand panel and park attribute read
      final parkRead = Completer<void>();
      f.holdNextAttributeRead = parkRead;
      await _expand(tester);
      expect(f.awaitingAttributeRead, isTrue);
      expect(f.healthMutationRequests, 0);

      await _openHealth(tester);
      expect(tester.getSize(find.byKey(_healthCancel)).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(find.byKey(_healthSave)).height, greaterThanOrEqualTo(48));
      await _chooseHealth(tester, 'needsAttention');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => f.awaitingApply);
      await _popRoute(tester);
      expect(f.awaitingAttributeRead, isTrue);
      expect(f.awaitingApply, isTrue);
      final readsAtRelease = f.attributeReads();
      expect(find.byKey(_hold), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'hold wraps without overflow');
      expect(find.text('健康狀態更新中：完成前不會重新整理、變更開啟狀態或其他欄位。'), findsWidgets);

      // Release parked attribute read while held -> discarded (R2), no "目前："
      parkRead.complete();
      await _until(tester, () => !f.awaitingAttributeRead);
      await tester.binding.delayed(const Duration(milliseconds: 10));
      await tester.pump();
      expect(f.awaitingApply, isTrue, reason: 'released while held');
      expect(f.attributeReads(), readsAtRelease, reason: 'no Health re-dispatch while held');
      expect(
        find.descendant(
          of: find.byKey(_attributeHealth),
          matching: find.text('健康狀態更新中：完成前不會重新整理、變更開啟狀態或其他欄位。'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(_attributeHealth),
          matching: find.textContaining('目前：'),
        ),
        findsNothing,
      );

      apply.complete();
      await settleNetworkWidgets(tester);
      expect(
        find.descendant(
          of: find.byKey(_attributeHealth),
          matching: find.text('目前：需關注'),
        ),
        findsOneWidget,
      );
      expect(find.byKey(_hold), findsNothing);
      expect(tester.takeException(), isNull);

      // Stale block text: lag keeps editor open
      f.lagNextDetail = true;
      await _openHealth(tester);
      await _chooseHealth(tester, 'atRisk');
      await tester.tap(find.byKey(_healthSave));
      await settleNetworkWidgets(tester);
      expect(find.byKey(_healthSave), findsOneWidget, reason: 'editor open on lag');
      await tester.tap(find.byKey(_healthCancel));
      await settleNetworkWidgets(tester);
      expect(find.byKey(_stale), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'stale wraps without overflow');
      expect(
        find.descendant(
          of: find.byKey(_attributeHealth),
          matching: find.text('尚未確認最新健康狀態。請重新整理後再查看。'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(_attributeHealth),
          matching: find.textContaining('目前：'),
        ),
        findsNothing,
      );

      // The stale detail predates the server, so the Health preflight refuses
      // to reopen until the visible manual refresh revalidates it
      final reopenReads = f.editReads();
      expect(_onPressed(tester, _refreshButton()), isNotNull, reason: 'refresh enabled while stale');
      await tester.tap(_refreshButton());
      await settleNetworkWidgets(tester);
      expect(find.byKey(_stale), findsNothing, reason: 'manual refresh clears stale');
      expect(find.byKey(_unconfirmed), findsNothing);
      expect(f.editReads(), reopenReads, reason: 'refresh issues no Health edit read');
      // A refresh that repaints the body rebuilds the attributes panel collapsed
      if (find.byKey(_attributeHealth).evaluate().isEmpty) await _expand(tester);
      expect(
        find.descendant(
          of: find.byKey(_attributeHealth),
          matching: find.text('目前：有風險'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(_attributeHealth),
          matching: find.text('尚未確認最新健康狀態。請重新整理後再查看。'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);

      // Unconfirmed block text: lost ACK settles and dismisses editor
      f.loseNextAck = true;
      await _openHealth(tester);
      await _chooseHealth(tester, 'onTrack');
      await tester.tap(find.byKey(_healthSave));
      await settleNetworkWidgets(tester);
      expect(find.byKey(_unconfirmed), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'unconfirmed wraps without overflow');
      expect(
        find.descendant(
          of: find.byKey(_attributeHealth),
          matching: find.text('尚未確認健康狀態是否已更新。請重新整理後再查看。'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(_attributeHealth),
          matching: find.textContaining('目前：'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('H22 preservation', (tester) async {
    final fixture = WorkItemHealthParentFixture();
    fixture.dates.dates[_itemX]!.rollUp = true;
    final h = await _mount(tester, fixture: fixture);
    expect(find.text('開始 2026/10/10'), findsOneWidget);
    expect(find.text('到期 2026/10/20'), findsOneWidget);
    expect(find.byKey(_statusBanner), findsNothing);
    expect(find.byKey(_hold), findsNothing);
    expect(find.byKey(const ValueKey('work-item-attributes')), findsOneWidget);
    expect(find.byKey(_section), findsOneWidget);
    expect(h.fixture.count(_healthMutationOp), 0);
    expect(h.fixture.unhandled, isEmpty);
  });

  testWidgets(
    'H23 benign session emit while cross-page write is busy: editor refusal leaf, '
    'and Status settle drops detail dismissing editor for both bump/no-bump',
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

      // 1. Open Page A editor before Page B START (capture editorA)
      await _expand(tester, page: 'b');
      await _openHealth(tester, page: 'a');
      final editorA = h.observer.pushed.last;
      final controlA = _controlState(tester, page: 'a');

      // 2. Push Page B editor with _press, then save B under holdBeforeApply
      await _press(tester, _any('b', find.byKey(_healthEdit, skipOffstage: false)));
      await settleNetworkWidgets(tester);
      final editorB = h.observer.pushed.last;
      expect(identical(editorA, editorB), isFalse);
      await _chooseHealth(tester, 'needsAttention');
      final applyB = Completer<void>();
      f.holdBeforeApply = applyB;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => f.awaitingApply);
      await _drain(tester);
      expect(_has('a', _hold), findsOneWidget, reason: 'A adopted the hold');

      // 3. session.remove(other1) (2 notifications)
      await tester.runAsync(() => session.remove(other1));
      await _frames(tester);
      expect(notifications, 2);
      expect(identical(_controlState(tester, page: 'a'), controlA), isTrue, reason: 'no remount');
      expect(h.observer.removed.contains(editorA), isFalse, reason: 'editorA retained across emit');

      // A's save button refused while held (refusal leaf)
      final saveAFinder = find.byKey(_healthSave, skipOffstage: false).first;
      final editReadsBefore = f.editReads();
      final mutationsBefore = f.count(_healthMutationOp);
      await _press(tester, saveAFinder);
      await _drain(tester);
      expect(f.editReads(), editReadsBefore, reason: '0 Health-edit requests on Page A');
      expect(f.count(_healthMutationOp), mutationsBefore, reason: 'zero additional mutation requests on Page A');
      expect(find.byKey(_healthFeedback, skipOffstage: false), findsNothing, reason: 'no in-progress feedback');
      expect(
        find.descendant(
          of: find.byKey(_healthCancel, skipOffstage: false).first,
          matching: find.text('取消', skipOffstage: false),
          skipOffstage: false,
        ),
        findsOneWidget,
        reason: 'Cancel label remains 取消',
      );

      // 4. Release Page B Health holdBeforeApply and settle (bump fixture)
      applyB.complete();
      await settleNetworkWidgets(tester);
      // Page A observer reload (keepForHealth: true) installs newer updatedAt, dismissing editorA
      expect(_has('a', _hold), findsNothing);
      expect(h.observer.removed, contains(editorA), reason: 'B settle dismisses editorA via bumped updatedAt');

      // 5. Reopen Page A editor
      await _openHealth(tester, page: 'a');
      final editorA2 = h.observer.pushed.last;
      expect(find.byKey(_healthSave), findsOneWidget);

      // 6. Then Page B Status write held and settled (run once with bump)
      await _press(tester, _any('b', find.byKey(_statusEdit, skipOffstage: false)));
      await settleNetworkWidgets(tester);
      await _chooseStatus(tester, _canceled);
      final statusApply = Completer<void>();
      f.status.holdBeforeApply = statusApply;
      final statusSends = f.status.count(_statusWriteOp);
      final healthSends = f.healthMutationRequests;
      await tester.tap(find.byKey(_statusSave));
      await _until(tester, () => f.status.awaitingApply);
      expect(_has('a', _statusBanner), findsOneWidget, reason: 'A held by B Status');
      expect(h.observer.removed.contains(editorA2), isFalse, reason: 'editorA2 retained while B Status busy');
      statusApply.complete();
      await settleNetworkWidgets(tester);
      expect(h.observer.removed, contains(editorA2), reason: 'Status settle dismisses Health editor');
      expect(find.byKey(_healthSave), findsNothing);
      expect(f.status.count(_statusWriteOp), statusSends + 1, reason: 'one B Status send');
      expect(f.healthMutationRequests, healthSends, reason: 'zero extra Health writes from A');

      // 7. Run again with no-bump fixture
      f.status.advanceSeconds = 0;
      await _openHealth(tester, page: 'a');
      final editorA3 = h.observer.pushed.last;
      expect(find.byKey(_healthSave), findsOneWidget);
      await _press(tester, _any('b', find.byKey(_statusEdit, skipOffstage: false)));
      await settleNetworkWidgets(tester);
      await _chooseStatus(tester, WorkItemStatusFixture.statusTodo);
      final statusApply2 = Completer<void>();
      f.status.holdBeforeApply = statusApply2;
      final statusSends2 = f.status.count(_statusWriteOp);
      final healthSends2 = f.healthMutationRequests;
      await tester.tap(find.byKey(_statusSave));
      await _until(tester, () => f.status.awaitingApply);
      expect(_has('a', _statusBanner), findsOneWidget, reason: 'A held by B Status (no bump)');
      expect(h.observer.removed.contains(editorA3), isFalse, reason: 'editorA3 retained while B Status busy');
      statusApply2.complete();
      await settleNetworkWidgets(tester);
      expect(h.observer.removed, contains(editorA3), reason: 'Status no-bump settle also dismisses Health editor');
      expect(find.byKey(_healthSave), findsNothing);
      expect(f.status.count(_statusWriteOp), statusSends2 + 1, reason: 'one B Status send (no bump)');
      expect(f.healthMutationRequests, healthSends2, reason: 'zero extra Health writes from A (no bump)');
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    'H24 launcher: push writer A, START at holdBeforeApply, pop writer A while '
    'write future is held, push observer B; distinguishes premature dispose release '
    '(M1j) from unreleased terminal stall (M1p)',
    (tester) async {
      final h = await _mount(tester, launcher: true);
      final f = h.fixture;
      await tester.tap(find.text('open'));
      await settleNetworkWidgets(tester);
      expect(find.byKey(const ValueKey('page-a')), findsOneWidget);
      await _openHealth(tester);
      await _chooseHealth(tester, 'needsAttention');
      final apply = Completer<void>();
      f.holdBeforeApply = apply;
      await tester.tap(find.byKey(_healthSave));
      await _until(tester, () => f.awaitingApply);
      await _popRoute(tester);
      expect(find.byKey(_healthSave), findsNothing);
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
      expect(find.byKey(_hold), findsOneWidget, reason: 'held while in flight (RED under M1j)');
      expect(_onPressed(tester, find.byKey(_healthEdit)), isNull);
      expect(_onPressed(tester, _refreshButton()), isNull);

      apply.complete();
      await settleNetworkWidgets(tester);
      expect(find.byKey(_hold), findsNothing, reason: 'released after SETTLE (RED under M1p)');
      expect(_onPressed(tester, find.byKey(_healthEdit)), isNotNull);
      expect(_details(h), afterInitial + 1, reason: 'one terminal reload');
      expect(f.healthMutationRequests, 1);
    },
  );

  testWidgets(
    'H25 keyed continuity: real Status banner insertion while Health editor open',
    (tester) async {
      final h = await _mount(tester, pages: 2);
      final f = h.fixture;
      await _expand(tester, page: 'b');
      await _openHealth(tester, page: 'a');
      final capturedState = _controlState(tester, page: 'a');
      final editorRoute = h.observer.pushed.last;
      expect(_has('a', _statusBanner), findsNothing);

      // Page B Status STARTs and is held at status.holdBeforeApply, dynamically
      // inserting work-item-status-hold-banner on Page A above the Health section
      await _press(tester, _any('b', find.byKey(_statusEdit, skipOffstage: false)));
      await settleNetworkWidgets(tester);
      await _chooseStatus(tester, _canceled);
      final statusApply = Completer<void>();
      f.status.holdBeforeApply = statusApply;
      await tester.tap(find.byKey(_statusSave));
      await _until(tester, () => f.status.awaitingApply);
      await _drain(tester);

      expect(_has('a', _statusBanner), findsOneWidget, reason: 'status banner inserted');
      expect(
        identical(_controlState(tester, page: 'a'), capturedState),
        isTrue,
        reason: 'State preserved across banner insertion (M1l key continuity)',
      );
      expect(find.byKey(_healthSave, skipOffstage: false), findsOneWidget, reason: 'editor route remains open');
      expect(
        h.observer.removed.contains(editorRoute),
        isFalse,
        reason: 'editorRoute not removed while banner shown',
      );

      statusApply.complete();
      await settleNetworkWidgets(tester);
      // After Status settle, Status observer reload drops detail and dismisses editor
      expect(
        h.observer.removed,
        contains(editorRoute),
        reason: 'editorRoute removed after status settle',
      );
      expect(find.byKey(_healthSave), findsNothing);
      expect(f.unhandled, isEmpty);
    },
  );

  testWidgets(
    'H26 fixture ACK with unchanged updatedAt (ack.updatedAt == preflight): '
    'stale on equal timestamp, manual refresh clears A only, writer editor stays open',
    (tester) async {
      final h = await _mount(tester, pages: 2);
      final f = h.fixture;
      f.unchangedUpdatedAtOnAck = true;

      await _expand(tester, page: 'a');
      await _expand(tester, page: 'b');
      await _openHealth(tester, page: 'a');
      final editorA = h.observer.pushed.last;
      await _chooseHealth(tester, 'needsAttention');
      await tester.tap(find.byKey(_healthSave));
      await settleNetworkWidgets(tester);

      // Writer Page A's own editor stays open through the equal timestamp reload
      expect(
        find.byKey(_healthSave),
        findsOneWidget,
        reason: 'writer editor stays open on equal timestamp',
      );
      expect(
        h.observer.removed.contains(editorA),
        isFalse,
        reason: 'editorA not removed',
      );
      expect(find.byKey(_unconfirmed), findsNothing);

      // Dismiss Page A's editor via user Cancel before interacting with Page A controls below
      await tester.tap(find.byKey(_healthCancel));
      await settleNetworkWidgets(tester);
      expect(h.observer.popped, contains(editorA), reason: 'user Cancel pops editor');

      // Both writer Page A and observer Page B show work-item-health-stale after reload
      // (stale because shown revision is not after floor, first failure for M1c strict isBefore)
      expect(_has('a', _stale), findsOneWidget);
      expect(_has('b', _stale), findsOneWidget);

      // Panel Health row drops value showing stale action text (scoped to panel row per D12/D14)
      expect(
        find.descendant(
          of: _any('a', find.byKey(_attributeHealth)),
          matching: find.text('尚未確認最新健康狀態。請重新整理後再查看。'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _any('b', find.byKey(_attributeHealth)),
          matching: find.text('尚未確認最新健康狀態。請重新整理後再查看。'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _any('a', find.byKey(_attributeHealth)),
          matching: find.textContaining('目前：'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: _any('b', find.byKey(_attributeHealth)),
          matching: find.textContaining('目前：'),
        ),
        findsNothing,
      );

      // Same-page Status write with _withSummary does NOT clear stale
      f.status.advanceSeconds = 0;
      await _openStatus(tester, page: 'a');
      await _chooseStatus(tester, _canceled);
      await tester.tap(find.byKey(_statusSave));
      await settleNetworkWidgets(tester);
      expect(_has('a', _stale), findsOneWidget, reason: 'Status write does not clear stale');
      expect(
        find.descendant(
          of: _any('a', find.byKey(_attributeHealth)),
          matching: find.text('尚未確認最新健康狀態。請重新整理後再查看。'),
        ),
        findsOneWidget,
      );

      // Manual refresh on Page A clears stale on Page A only while Page B remains stale
      await tester.tap(_refreshButton(page: 'a'));
      await settleNetworkWidgets(tester);
      expect(_has('a', _stale), findsNothing, reason: 'A cleared');
      expect(_has('b', _stale), findsOneWidget, reason: 'B remains stale');
      expect(
        find.descendant(
          of: _any('b', find.byKey(_attributeHealth)),
          matching: find.text('尚未確認最新健康狀態。請重新整理後再查看。'),
        ),
        findsOneWidget,
      );

      // Page C mounted after terminal shows stale on first install
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWithValue(h.session)],
          child: MaterialApp(
            navigatorObservers: [h.observer],
            home: GraphWorkItemDetailPage.project(
              key: const ValueKey('page-c'),
              account: h.account,
              api: h.api,
              project: _project,
              iid: WorkItemStatusFixture.sharedIid,
              isCurrent: () => identical(h.session.api, h.api),
              ownerChanges: h.session,
            ),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      await _expand(tester, page: 'c');
      expect(
        _has('c', _stale),
        findsOneWidget,
        reason: 'Page C shows stale on first install',
      );
      expect(
        find.descendant(
          of: _in('c', find.byKey(_attributeHealth)),
          matching: find.text('尚未確認最新健康狀態。請重新整理後再查看。'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _in('c', find.byKey(_attributeHealth)),
          matching: find.textContaining('目前：'),
        ),
        findsNothing,
      );
      expect(f.unhandled, isEmpty);
    },
  );
}

enum _Stage { beforeApply, ack, confirmRead }

Future<void> _sameStageGates(WidgetTester tester, _Stage stage) async {
  final fixture = WorkItemHealthParentFixture();
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
    _any(null, find.byKey(_datesEdit, skipOffstage: false)),
  ];
  final refresh = _refreshButton();
  for (final control in [...controls, refresh]) {
    expect(_onPressed(tester, control), isNotNull, reason: '$control enabled');
  }

  await _openHealth(tester);
  await _chooseHealth(tester, 'needsAttention');
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
  await tester.tap(find.byKey(_healthSave));
  await _until(tester, held);
  await _drain(tester);
  expect(find.byKey(_healthSave), findsOneWidget, reason: 'editor still open');
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
  expect(
    _onPressed(tester, find.byKey(_datesEdit, skipOffstage: false)),
    isNull,
    reason: 'Dates edit',
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
  expect(find.byKey(_healthSave), findsNothing, reason: 'confirmed, closed');
  expect(find.byKey(_attributeHealth), findsOneWidget);
  expect(find.text('目前：需關注'), findsOneWidget);
  expect(find.byKey(_unconfirmed), findsNothing);
  expect(find.byKey(_stale), findsNothing);
  expect(f.healthMutationRequests, 1);
  expect(f.unhandled, isEmpty);
}

Future<void> _twoHealthWriters(
  WidgetTester tester, {
  required String winner,
}) async {
  final h = await _mount(tester, pages: 2);
  final f = h.fixture;
  final server = f.status.item(group: false);
  await _openHealth(tester, page: 'a');
  final editorA = h.observer.pushed.last;
  await _chooseHealth(tester, 'needsAttention');
  await _press(tester, _any('b', find.byKey(_healthEdit, skipOffstage: false)));
  await settleNetworkWidgets(tester);
  final editorB = h.observer.pushed.last;
  expect(identical(editorA, editorB), isFalse);
  await _chooseHealth(tester, 'atRisk');

  f.armFinalFence = true;
  await tester.tap(find.byKey(_healthSave));
  await _until(tester, () => f.awaitingFinalFenceReads == 1);
  final nonceB = f.parkedFenceNonces.single;
  await _press(tester, find.byKey(_healthSave, skipOffstage: false).first);
  await _until(tester, () => f.awaitingFinalFenceReads == 2);
  final nonceA = f.parkedFenceNonces.last;
  expect(nonceA, isNot(nonceB));

  final revision = server.updatedAt;
  final apply = Completer<void>();
  f.holdBeforeApply = apply;
  f.releaseFenceNonce(winner == 'a' ? nonceA : nonceB);
  await _until(tester, () => f.awaitingApply);
  expect(f.awaitingApply, isTrue, reason: 'winner held before the loser');
  expect(f.healthMutationRequests, 1);
  expect(server.updatedAt, revision, reason: 'nothing applied yet');

  f.releaseFenceNonce(winner == 'a' ? nonceB : nonceA);
  await _drain(tester);
  await _drain(tester);
  expect(f.healthMutationRequests, 1, reason: 'loser refused before START');
  expect(f.awaitingApply, isTrue);

  apply.complete();
  await settleNetworkWidgets(tester);
  expect(f.healthMutationRequests, 1);
  expect(f.healthApplied, 1);
  expect(
    h.observer.removed,
    containsAll([editorA, editorB]),
    reason: 'both editors removed upon bumped reload',
  );
  expect(find.byKey(_healthSave), findsNothing, reason: 'both editors dismissed');
  expect(h.observer.popped, isEmpty);
  expect(_has('a', _hold), findsNothing);
  expect(_has('b', _hold), findsNothing);
  expect(f.unhandled, isEmpty);
}

Future<void> _mixedHealthStatusWriters(
  WidgetTester tester, {
  required bool healthWins,
}) async {
  final h = await _mount(tester, pages: 2);
  final f = h.fixture;
  await _expand(tester, page: 'b');
  await _openHealth(tester, page: 'a');
  await _chooseHealth(tester, 'needsAttention');
  f.armFinalFence = true;
  await tester.tap(find.byKey(_healthSave));
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

  if (healthWins) {
    final apply = Completer<void>();
    f.holdBeforeApply = apply;
    f.releaseFenceNonce(nonceA);
    await _until(tester, () => f.awaitingApply);
    expect(f.awaitingApply, isTrue, reason: 'Health held before B answered');
    await tester.idle();
    await tester.pump();
    final bEdit = _any('b', find.byKey(_statusEdit, skipOffstage: false));
    expect(_onPressed(tester, bEdit), isNull, reason: 'B Status edit disabled');
    preflight.complete();
    await _drain(tester);
    await _drain(tester);
    expect(f.status.count(_statusWriteOp), 0, reason: 'zero Status START');
    expect(f.healthMutationRequests, 1);
    apply.complete();
    await settleNetworkWidgets(tester);
    expect(f.healthApplied, 1);
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
    expect(f.healthMutationRequests, 0, reason: 'zero Health START');
    expect(f.status.count(_statusWriteOp), 1);
    statusApply.complete();
    await settleNetworkWidgets(tester);
    expect(f.status.appliedMutationNonces, [1]);
    expect(f.healthMutationRequests, 0);
  }
  expect(f.unhandled, isEmpty);
}

Future<void> _mixedHealthDatesWriters(
  WidgetTester tester, {
  required bool healthWins,
}) async {
  final h = await _mount(tester, pages: 2);
  final f = h.fixture;
  await _openHealth(tester, page: 'a');
  await _chooseHealth(tester, 'needsAttention');
  f.armFinalFence = true;
  await tester.tap(find.byKey(_healthSave));
  await _until(tester, () => f.awaitingFinalFenceReads == 1);
  final nonceA = f.parkedFenceNonces.single;

  await _press(tester, _any('b', find.byKey(_datesEdit, skipOffstage: false)));
  await settleNetworkWidgets(tester);
  expect(find.byKey(_datesSave), findsOneWidget);
  await _enterDates(tester, '2026-11-02', '2026-11-09');
  f.dates.armFinalFence = true;
  await tester.tap(find.byKey(_datesSave));
  await _until(tester, () => f.dates.awaitingFinalFenceReads == 1);
  final nonceB = f.dates.parkedFenceNonces.single;

  if (healthWins) {
    final apply = Completer<void>();
    f.holdBeforeApply = apply;
    f.releaseFenceNonce(nonceA);
    await _until(tester, () => f.awaitingApply);
    expect(f.awaitingApply, isTrue, reason: 'Health held before Dates B answered');
    f.dates.releaseFenceNonce(nonceB);
    await _drain(tester);
    await _drain(tester);
    expect(f.dates.datesMutationRequests, 0, reason: 'zero Dates START');
    expect(f.healthMutationRequests, 1);
    apply.complete();
    await settleNetworkWidgets(tester);
    expect(f.healthApplied, 1);
    expect(f.dates.datesMutationRequests, 0);
  } else {
    final datesApply = Completer<void>();
    f.dates.holdBeforeApply = datesApply;
    f.dates.releaseFenceNonce(nonceB);
    await _until(tester, () => f.dates.awaitingApply);
    expect(f.dates.awaitingApply, isTrue, reason: 'Dates held first');
    f.releaseFenceNonce(nonceA);
    await _drain(tester);
    await _drain(tester);
    expect(f.healthMutationRequests, 0, reason: 'zero Health START');
    expect(f.dates.datesMutationRequests, 1);
    datesApply.complete();
    await settleNetworkWidgets(tester);
    expect(f.dates.datesApplied, 1);
    expect(f.healthMutationRequests, 0);
  }
  expect(f.unhandled, isEmpty);
}

Future<_Mounted> _mount(
  WidgetTester tester, {
  WorkItemHealthParentFixture? fixture,
  int pages = 1,
  bool launcher = false,
  bool injected = false,
  List<Account> seeded = const [],
  double? width,
  double height = 2200,
  double textScale = 1,
}) async {
  final server = fixture ?? WorkItemHealthParentFixture();
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

typedef _Mounted = ({
  WorkItemHealthParentFixture fixture,
  SessionController session,
  MemoryAccountStore store,
  Account account,
  GitLabApi api,
  _Observer observer,
  ValueNotifier<int> rebind,
});

int _details(_Mounted h, {String tag = 'primary', String item = _itemX}) =>
    h.fixture.detailReads(tag: tag, item: item);

Finder _in(String? page, Finder finder) => page == null
    ? finder
    : find.descendant(of: find.byKey(ValueKey('page-$page')), matching: finder);

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
      _any(page, find.byType(WorkItemHealthControl, skipOffstage: false)),
    );

VoidCallback? _onPressed(WidgetTester tester, Finder finder) =>
    switch (tester.widget(finder)) {
      ButtonStyleButton(:final onPressed) => onPressed,
      IconButton(:final onPressed) => onPressed,
      final other => throw StateError('not a button: $other'),
    };

Future<void> _press(WidgetTester tester, Finder finder) async {
  _onPressed(tester, finder)?.call();
  await _drain(tester);
}

Future<void> _openHealth(WidgetTester tester, {String? page}) async {
  final edit = _in(page, find.byKey(_healthEdit));
  await tester.ensureVisible(edit);
  await tester.pump();
  await tester.tap(edit);
  await settleNetworkWidgets(tester);
  expect(find.byKey(_healthSave), findsOneWidget);
}

Future<void> _chooseHealth(WidgetTester tester, String choiceName) async {
  final row = find.byKey(ValueKey('work-item-health-choice-$choiceName'));
  await tester.scrollUntilVisible(
    row,
    120,
    scrollable: find.descendant(
      of: find.byKey(const ValueKey('work-item-health-scroll')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.tap(row);
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

Future<void> _openDates(WidgetTester tester, {String? page}) async {
  final edit = _in(page, find.byKey(_datesEdit));
  await tester.ensureVisible(edit);
  await tester.pump();
  await tester.tap(edit);
  await settleNetworkWidgets(tester);
  expect(find.byKey(_datesSave), findsOneWidget);
}

Future<void> _enterDates(WidgetTester tester, String start, String due) async {
  await tester.enterText(find.byKey(const ValueKey('work-item-dates-start-input')), start);
  await tester.enterText(find.byKey(const ValueKey('work-item-dates-due-input')), due);
  await tester.pump();
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> _popRoute(WidgetTester tester) async {
  await tester.pageBack();
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump();
}

Future<void> _drain(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await _frames(tester);
}

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
