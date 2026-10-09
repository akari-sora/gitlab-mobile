import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/widget_settle.dart';
import 'support/work_item_status_fixture.dart';

// Real GraphWorkItemDetailPage + the production STATUS row. Only constructor
// arguments that already existed at 61cf7f0 are used (no sessionGeneration),
// so on the baseline sources these fail on missing UI/behaviour, not compile.

const _project = Project(id: 42, name: 'mobile', path: 'studio/mobile');
const _done = WorkItemStatusFixture.statusDone;
const _canceled = WorkItemStatusFixture.statusCanceled;

const _edit = ValueKey('work-item-status-edit');
const _save = ValueKey('work-item-status-save');
const _banner = ValueKey('work-item-status-hold-banner');
const _fieldPending = ValueKey('work-item-status-field-pending');
const _unconfirmed = ValueKey('work-item-status-field-unconfirmed');
const _stale = ValueKey('work-item-status-field-stale');
const _doing = WorkItemStatusFixture.statusDoing;
const _labelsUnconfirmed = ValueKey('work-item-labels-unconfirmed');

const _detailOp = 'MobileProjectWorkItem';
const _lifecycleOp = 'MobileWorkItemState';
const _lifecycleWriteOp = 'MobileUpdateWorkItemState';
const _statusOp = 'MobileWorkItemStatus';
const _statusWriteOp = 'MobileUpdateWorkItemStatus';
const _attributeOp = 'MobileWorkItemStatusAttribute';
const _labelsReadOp = 'MobileWorkItemLabels';
const _labelsWriteOp = 'MobileUpdateWorkItemLabels';

const _labelsEdit = ValueKey('work-item-labels-edit');
const _labelsSave = ValueKey('work-item-labels-save');
const _labelsClear = ValueKey('work-item-labels-clear');
const _labelsUpdating = ValueKey('work-item-labels-updating');
const _chip1 = ValueKey('work-item-label-chip-gid://gitlab/ProjectLabel/1');
const _weightReadOp = 'MobileWorkItemWeight';
const _weightWriteOp = 'MobileSetWorkItemWeight';
const _weightEdit = ValueKey('work-item-weight-edit');
const _weightInput = ValueKey('work-item-weight-input');
const _weightSave = ValueKey('work-item-weight-save');
const _assigneesReadOp = 'MobileWorkItemAssignees';
const _assigneesWriteOp = 'MobileSetWorkItemAssignees';
const _candidatesOp = 'MobileProjectAssigneeCandidates';
const _assigneesEdit = ValueKey('work-item-assignees-edit');
const _assigneesSave = ValueKey('work-item-assignees-save');
const _assigneesUpdating = ValueKey('work-item-assignees-updating');
const _owner = 'gid://gitlab/User/11';
const _candidate = 'gid://gitlab/User/12';
const _candidateChip = ValueKey('work-item-assignee-preview-$_candidate');
const _milestoneAttributeOp = 'MobileWorkItemMilestoneAttribute';
const _milestoneReadOp = 'MobileWorkItemMilestone';
const _milestoneChoicesOp = 'MobileProjectWorkItemMilestones';
const _milestoneWriteOp = 'MobileSetWorkItemMilestone';
const _milestoneRow = ValueKey('work-item-attribute-milestone');
const _milestoneEdit = ValueKey('work-item-milestone-edit');
const _milestoneSave = ValueKey('work-item-milestone-save');
const _october = 'gid://gitlab/Milestone/5';
const _november = 'gid://gitlab/Milestone/6';

void main() {
  testWidgets(
    'R1 Status edit re-enables after a confirmed save without another '
    'rebuild',
    (tester) async {
      final h = await _mount(tester);
      await _expand(tester);
      await _openEditor(tester);
      await _choose(tester, _canceled);
      await tester.tap(find.byKey(_save));
      await _until(tester, () => h.fixture.count(_lifecycleOp) == 2);
      await settleNetworkWidgets(tester);
      expect(h.fixture.mutations, 1);
      expect(find.text('分類：已取消'), findsOneWidget, reason: 'confirmed');
      expect(find.byKey(_save), findsNothing, reason: 'editor closed');

      expect(
        tester.widget<TextButton>(find.byKey(_edit)).onPressed,
        isNotNull,
        reason: 'lifecycle re-read ended; STATUS row must rebuild enabled',
      );
      final reads = h.fixture.count(_statusOp);
      await tester.tap(find.byKey(_edit));
      await settleNetworkWidgets(tester);
      expect(h.fixture.count(_statusOp), reads + 1);
      expect(find.byKey(_save), findsOneWidget);
      expect(h.fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'R2 held labels refetch blocks Status capability; confirmed chips and '
    'gate after release',
    (tester) async {
      final fixture = _fixture()
        ..item(group: false).labelIds = [...statusFixtureLabels.keys];
      await _mount(tester, fixture: fixture);
      expect(find.byKey(_chip1), findsOneWidget);
      await _expand(tester);
      await _openLabels(tester);
      expect(fixture.count(_labelsReadOp), 1);
      await tester.tap(find.byKey(_labelsClear));
      await tester.pump();
      fixture.holdNextDetail = Completer<void>();
      final before = fixture.requests.length;
      await tester.tap(find.byKey(_labelsSave));
      await _until(tester, () => fixture.count(_detailOp) == 2);
      await _drain(tester);
      expect(fixture.operations.sublist(before), [
        _labelsReadOp,
        _labelsWriteOp,
        _labelsReadOp,
        _detailOp,
      ]);
      expect(fixture.heldCount, 1, reason: 'only the labels refetch is held');
      expect(find.byKey(_labelsUpdating, skipOffstage: false), findsOneWidget);

      final reads = fixture.count(_statusOp);
      await _press(tester, _edit);
      expect(fixture.count(_statusOp), reads, reason: 'refetch gates STATUS');
      expect(find.byKey(_save), findsNothing);

      fixture.releaseHolds();
      await settleNetworkWidgets(tester);
      expect(find.byKey(_labelsSave), findsNothing, reason: 'sheet closed');
      expect(fixture.count(_detailOp), 2, reason: 'exactly one refetch');
      expect(fixture.count(_labelsWriteOp), 1);
      expect(fixture.item(group: false).labelIds, isEmpty);
      expect(find.byKey(_labelsUpdating), findsNothing);
      expect(find.byKey(_chip1), findsNothing);
      expect(find.text('沒有標籤'), findsOneWidget);
      await _openEditor(tester);
      expect(fixture.count(_statusOp), reads + 1);
      expect(fixture.mutations, 0);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'labels family: held Status write blocks labels save before fence and '
    'mutation',
    (tester) async {
      final fixture = _fixture()
        ..item(group: false).labelIds = [...statusFixtureLabels.keys];
      await _mount(tester, fixture: fixture);
      await _expand(tester);
      await _openLabels(tester);
      await tester.tap(find.byKey(_labelsClear));
      await tester.pump();
      final apply = Completer<void>();
      fixture.holdBeforeApply = apply;
      await _press(tester, _edit);
      await settleNetworkWidgets(tester);
      expect(fixture.count(_statusOp), 1, reason: 'positive control');
      await _choose(tester, _canceled);
      await tester.tap(find.byKey(_save));
      await _until(tester, () => fixture.awaitingApply);
      expect(fixture.mutations, 1);

      await _press(tester, _labelsSave);
      expect(fixture.count(_labelsReadOp), 1, reason: 'no fence read');
      expect(fixture.count(_labelsWriteOp), 0, reason: 'no labels mutation');
      expect(find.byKey(_labelsUpdating, skipOffstage: false), findsNothing);

      apply.complete();
      await settleNetworkWidgets(tester);
      expect(fixture.mutations, 1);
      expect(fixture.count(_labelsWriteOp), 0);
      expect(fixture.item(group: false).labelIds, hasLength(2));
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'labels family: held labels mutation blocks Status capability and save',
    (tester) async {
      final fixture = _fixture()
        ..item(group: false).labelIds = [...statusFixtureLabels.keys];
      await _mount(tester, fixture: fixture);
      await _expand(tester);
      await _openEditor(tester);
      await _choose(tester, _canceled);
      expect(fixture.count(_statusOp), 1, reason: 'positive control');

      await _press(tester, _labelsEdit);
      await settleNetworkWidgets(tester);
      expect(fixture.count(_labelsReadOp), 1);
      await tester.tap(find.byKey(_labelsClear));
      await tester.pump();
      fixture.holdNextLabelsMutation = Completer<void>();
      await tester.tap(find.byKey(_labelsSave));
      await _until(tester, () => fixture.count(_labelsWriteOp) == 1);
      await _drain(tester);
      expect(fixture.heldCount, 1);

      await _press(tester, _save);
      expect(fixture.count(_statusOp), 1, reason: 'no Status preflight');
      expect(fixture.mutations, 0);

      fixture.releaseHolds();
      await settleNetworkWidgets(tester);
      expect(fixture.count(_labelsWriteOp), 1);
      expect(fixture.count(_detailOp), 2, reason: 'one labels refetch');
      expect(fixture.mutations, 0);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'weight family: held Status write blocks weight save before preflight '
    'and mutation',
    (tester) async {
      final fixture = _weightFixture();
      await _mount(tester, fixture: fixture);
      await _expand(tester);
      await _openWeight(tester);
      final weightReads = fixture.count(_weightReadOp);
      expect(weightReads, 1, reason: 'positive control: editor read');
      await tester.enterText(find.byKey(_weightInput), '5');
      await tester.pump();
      final apply = Completer<void>();
      fixture.holdBeforeApply = apply;
      await _press(tester, _edit);
      await settleNetworkWidgets(tester);
      expect(fixture.count(_statusOp), 1, reason: 'positive control');
      await _choose(tester, _canceled);
      await tester.tap(find.byKey(_save));
      await _until(tester, () => fixture.awaitingApply);

      await _press(tester, _weightSave);
      expect(fixture.count(_weightReadOp), weightReads, reason: 'no preflight');
      expect(fixture.count(_weightWriteOp), 0);

      apply.complete();
      await settleNetworkWidgets(tester);
      expect(fixture.mutations, 1);
      expect(fixture.count(_weightWriteOp), 0);
      expect(fixture.item(group: false).weight, 3);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'weight family: held weight mutation blocks Status capability and save',
    (tester) async {
      final fixture = _weightFixture();
      await _mount(tester, fixture: fixture);
      await _expand(tester);
      await _openEditor(tester);
      await _choose(tester, _canceled);
      expect(fixture.count(_statusOp), 1, reason: 'positive control');

      await _press(tester, _weightEdit);
      await settleNetworkWidgets(tester);
      expect(find.byKey(_weightSave), findsOneWidget);
      await tester.enterText(find.byKey(_weightInput), '5');
      await tester.pump();
      fixture.holdNextWeightMutation = Completer<void>();
      await tester.tap(find.byKey(_weightSave));
      await _until(tester, () => fixture.count(_weightWriteOp) == 1);
      await _drain(tester);
      expect(fixture.heldCount, 1);

      await _press(tester, _save);
      expect(fixture.count(_statusOp), 1, reason: 'no Status preflight');
      expect(fixture.mutations, 0);

      fixture.releaseHolds();
      await settleNetworkWidgets(tester);
      expect(fixture.count(_weightWriteOp), 1);
      expect(fixture.item(group: false).weight, 5);
      expect(fixture.mutations, 0);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'assignees family: held assignees mutation blocks Status capability '
    'until the terminal settle',
    (tester) async {
      final fixture = _assigneeFixture();
      await _mount(tester, fixture: fixture);
      expect(
        find.byKey(const ValueKey('work-item-assignee-preview-$_owner')),
        findsOneWidget,
      );
      await _expand(tester);
      await _openAssignees(tester);
      expect(fixture.count(_assigneesReadOp), 1, reason: 'full roster read');
      await _addCandidate(tester);
      expect(fixture.count(_candidatesOp), 1);

      fixture.holdNextAssigneesMutation = Completer<void>();
      final before = fixture.requests.length;
      await tester.tap(find.byKey(_assigneesSave));
      await _until(tester, () => fixture.count(_assigneesWriteOp) == 1);
      await _drain(tester);
      expect(fixture.operations.sublist(before), [
        _assigneesReadOp,
        _assigneesWriteOp,
      ]);
      expect(fixture.heldCount, 1, reason: 'only the mutation is held');
      expect(_lastInput(fixture, _assigneesWriteOp), {
        'id': WorkItemStatusFixture.projectItemId,
        'assigneesWidget': {
          'assigneeIds': [_owner, _candidate],
        },
      });
      expect(
        find.byKey(_assigneesUpdating, skipOffstage: false),
        findsOneWidget,
        reason: 'START reached the parent',
      );

      await _press(tester, _edit);
      expect(fixture.count(_statusOp), 0, reason: 'no Status capability read');
      expect(find.byKey(_save), findsNothing);

      fixture.releaseHolds();
      await settleNetworkWidgets(tester);
      expect(fixture.heldCount, 0);
      expect(fixture.count(_assigneesWriteOp), 1);
      expect(
        fixture.count(_assigneesReadOp),
        4,
        reason: 'open, preflight, readback, one parent refetch',
      );
      expect(fixture.item(group: false).assigneeIds, [_owner, _candidate]);
      expect(find.byKey(_assigneesSave), findsNothing, reason: 'editor closed');
      expect(find.byKey(_assigneesUpdating), findsNothing);
      expect(find.byKey(_candidateChip), findsOneWidget);
      await _openEditor(tester);
      expect(fixture.count(_statusOp), 1, reason: 'gate reopened');
      expect(fixture.mutations, 0);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'assignees family: held Status write blocks assignees save; staged '
    'names are never confirmed',
    (tester) async {
      final fixture = _assigneeFixture();
      await _mount(tester, fixture: fixture);
      await _expand(tester);
      await _openAssignees(tester);
      await _addCandidate(tester);
      expect(fixture.count(_assigneesReadOp), 1, reason: 'positive control');

      final apply = Completer<void>();
      fixture.holdBeforeApply = apply;
      await _press(tester, _edit);
      await settleNetworkWidgets(tester);
      expect(fixture.count(_statusOp), 1, reason: 'positive control');
      await _choose(tester, _canceled);
      await tester.tap(find.byKey(_save));
      await _until(tester, () => fixture.awaitingApply);
      expect(fixture.mutations, 1);

      await _press(tester, _assigneesSave);
      expect(fixture.count(_assigneesReadOp), 1, reason: 'no preflight');
      expect(fixture.count(_assigneesWriteOp), 0, reason: 'no mutation');
      expect(find.byKey(_assigneesUpdating, skipOffstage: false), findsNothing);
      expect(
        find.byKey(_candidateChip, skipOffstage: false),
        findsNothing,
        reason: 'staged name is not painted as confirmed',
      );
      expect(fixture.item(group: false).assigneeIds, [_owner]);

      apply.complete();
      await settleNetworkWidgets(tester);
      expect(fixture.mutations, 1);
      expect(fixture.count(_assigneesWriteOp), 0);
      expect(fixture.item(group: false).assigneeIds, [_owner]);
      expect(find.byKey(_candidateChip, skipOffstage: false), findsNothing);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'milestone family: held milestone mutation blocks Status capability; '
    'one fresh row read after the settle',
    (tester) async {
      final fixture = _milestoneFixture();
      await _mount(tester, fixture: fixture);
      await _expand(tester);
      expect(fixture.count(_milestoneAttributeOp), 1);
      expect(find.text('十月里程碑'), findsOneWidget);
      await _openMilestone(tester);
      expect(fixture.count(_milestoneReadOp), 1, reason: 'capability read');
      expect(fixture.count(_milestoneChoicesOp), 1);
      await _chooseMilestone(tester);

      fixture.holdNextMilestoneMutation = Completer<void>();
      final before = fixture.requests.length;
      await tester.tap(find.byKey(_milestoneSave));
      await _until(tester, () => fixture.count(_milestoneWriteOp) == 1);
      await _drain(tester);
      expect(fixture.operations.sublist(before), [
        _milestoneReadOp,
        _milestoneWriteOp,
      ]);
      expect(fixture.heldCount, 1, reason: 'only the mutation is held');
      expect(_lastInput(fixture, _milestoneWriteOp), {
        'id': WorkItemStatusFixture.projectItemId,
        'milestoneWidget': {'milestoneId': _november},
      });
      expect(
        find.descendant(
          of: find.byKey(_milestoneRow, skipOffstage: false),
          matching: find.text('變更中…', skipOffstage: false),
        ),
        findsOneWidget,
        reason: 'START reached the row',
      );

      await _press(tester, _edit);
      expect(fixture.count(_statusOp), 0, reason: 'no Status capability read');
      expect(find.byKey(_save), findsNothing);
      final rowReads = fixture.count(_milestoneAttributeOp);

      fixture.releaseHolds();
      await settleNetworkWidgets(tester);
      expect(fixture.heldCount, 0);
      expect(fixture.count(_milestoneWriteOp), 1);
      expect(
        fixture.count(_milestoneReadOp),
        3,
        reason: 'open, preflight, readback',
      );
      expect(
        fixture.count(_milestoneAttributeOp),
        rowReads + 1,
        reason: 'one fresh row read',
      );
      expect(fixture.item(group: false).milestoneId, _november);
      expect(find.byKey(_milestoneSave), findsNothing, reason: 'picker closed');
      expect(find.text('十一月里程碑'), findsOneWidget);
      expect(find.text('十月里程碑'), findsNothing);
      await _openEditor(tester);
      expect(fixture.count(_statusOp), 1, reason: 'gate reopened');
      expect(fixture.mutations, 0);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'milestone family: held Status write blocks milestone save; staged '
    'choice is never confirmed',
    (tester) async {
      final fixture = _milestoneFixture();
      await _mount(tester, fixture: fixture);
      await _expand(tester);
      await _openMilestone(tester);
      await _chooseMilestone(tester);
      expect(fixture.count(_milestoneReadOp), 1, reason: 'positive control');

      final apply = Completer<void>();
      fixture.holdBeforeApply = apply;
      await _press(tester, _edit);
      await settleNetworkWidgets(tester);
      expect(fixture.count(_statusOp), 1, reason: 'positive control');
      await _choose(tester, _canceled);
      await tester.tap(find.byKey(_save));
      await _until(tester, () => fixture.awaitingApply);
      expect(fixture.mutations, 1);

      await _press(tester, _milestoneSave);
      expect(fixture.count(_milestoneReadOp), 1, reason: 'no preflight');
      expect(fixture.count(_milestoneWriteOp), 0, reason: 'no mutation');
      final row = find.byKey(_milestoneRow, skipOffstage: false);
      expect(
        find.descendant(
          of: row,
          matching: find.text('十一月里程碑', skipOffstage: false),
        ),
        findsNothing,
        reason: 'staged choice is not painted as confirmed',
      );
      expect(
        find.descendant(
          of: row,
          matching: find.text('十月里程碑', skipOffstage: false),
        ),
        findsOneWidget,
      );
      expect(fixture.item(group: false).milestoneId, _october);

      apply.complete();
      await settleNetworkWidgets(tester);
      expect(fixture.mutations, 1);
      expect(fixture.count(_milestoneWriteOp), 0);
      expect(fixture.item(group: false).milestoneId, _october);
      expect(
        find.descendant(
          of: row,
          matching: find.text('十一月里程碑', skipOffstage: false),
        ),
        findsNothing,
      );
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'R3 lifecycle close releases the pinned confirmed STATUS; a fresh '
    'attribute read paints the new server state',
    (tester) async {
      final h = await _mount(tester);
      await _expand(tester);
      await _openEditor(tester);
      await _choose(tester, _canceled);
      await tester.tap(find.byKey(_save));
      await _until(tester, () => h.fixture.count(_lifecycleOp) == 2);
      await settleNetworkWidgets(tester);
      expect(find.text('分類：已取消'), findsOneWidget, reason: 'confirmed');
      final attributes = h.fixture.count(_attributeOp);
      expect(attributes, 1, reason: 'positive control: one pre-save read');

      await tester.ensureVisible(find.text('關閉工作項目'));
      await tester.tap(find.text('關閉工作項目'));
      await _frames(tester);
      final server = h.fixture.item(group: false);
      server.assignment = WorkItemStatusFixture.defaultMembers[1];
      await tester.tap(find.text('確認關閉'));
      await settleNetworkWidgets(tester);
      expect(h.fixture.count(_lifecycleWriteOp), 1, reason: 'positive control');
      expect(server.state, 'CLOSED');
      expect(find.text('目前為已關閉'), findsOneWidget);
      expect(
        h.fixture.count(_attributeOp),
        attributes + 1,
        reason: 'the close releases the pin: one fresh attribute read',
      );
      expect(find.text('進行中'), findsOneWidget);
      expect(find.text('不處理'), findsNothing, reason: 'old pin released');

      final afterClose = h.fixture.count(_attributeOp);
      await tester.tap(find.text('屬性'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('屬性'));
      await settleNetworkWidgets(tester);
      expect(
        h.fixture.count(_attributeOp),
        afterClose,
        reason: 'collapse and expand reuse the loaded row; not a refresh',
      );
      expect(find.text('進行中'), findsOneWidget);
      expect(h.fixture.mutations, 1);
      expect(h.fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'R4 page A popped during a held write; reopened page B neither reads '
    'nor paints STATUS nor dispatches metadata until one fresh detail',
    (tester) async {
      final fixture = _fixture()
        ..item(group: false).labelIds = [...statusFixtureLabels.keys];
      await _mount(tester, fixture: fixture, launcher: true);
      await tester.tap(find.text('open'));
      await settleNetworkWidgets(tester);
      expect(find.byKey(const ValueKey('page-a')), findsOneWidget);
      final apply = Completer<void>();
      fixture.holdBeforeApply = apply;
      await _expand(tester);
      await _openEditor(tester);
      await _choose(tester, _canceled);
      await tester.tap(find.byKey(_save));
      await _until(tester, () => fixture.awaitingApply);
      expect(fixture.mutations, 1, reason: 'positive control: write held');
      await _popRoute(tester);
      expect(find.byKey(_save), findsNothing, reason: 'editor popped');
      await _popRoute(tester);
      expect(find.byKey(const ValueKey('page-a')), findsNothing);

      final attributes = fixture.count(_attributeOp);
      final reads = fixture.count(_statusOp);
      final labelReads = fixture.count(_labelsReadOp);
      final lifecycle = fixture.count(_lifecycleOp);
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await _drain(tester);
      expect(find.byKey(const ValueKey('page-b')), findsOneWidget);
      expect(find.text('屬性'), findsOneWidget, reason: 'B detail is shown');
      expect(find.byKey(_banner), findsOneWidget, reason: 'B sees the hold');
      expect(
        tester.widget<IconButton>(_refreshButton()).onPressed,
        isNull,
        reason: 'refresh refused while held',
      );
      await tester.tap(find.text('屬性'));
      await _drain(tester);
      expect(find.byKey(_fieldPending), findsOneWidget, reason: 'expanded');
      expect(
        tester.widget<TextButton>(find.byKey(_edit)).onPressed,
        isNull,
        reason: 'B STATUS edit disabled while held',
      );
      expect(find.byKey(_labelsEdit), findsOneWidget);
      final ledger = fixture.requests.length;
      await _press(tester, _labelsEdit);
      await _press(tester, _edit);
      expect(fixture.requests.length, ledger, reason: 'zero held reads');
      expect(fixture.heldCount, 1, reason: 'the write is still held');
      expect(fixture.awaitingApply, isTrue);
      expect(fixture.count(_attributeOp), attributes, reason: 'no STATUS read');
      expect(find.text('待處理'), findsNothing, reason: 'no pre-write paint');
      expect(fixture.count(_statusOp), reads);
      expect(fixture.count(_labelsReadOp), labelReads);
      expect(fixture.count(_lifecycleOp), lifecycle);
      expect(fixture.count(_lifecycleWriteOp), 0);

      final details = fixture.count(_detailOp);
      apply.complete();
      await _until(tester, () => find.byKey(_banner).evaluate().isEmpty);
      await settleNetworkWidgets(tester);
      expect(fixture.mutations, 1);
      expect(fixture.appliedMutationNonces, [1]);
      expect(
        fixture.count(_detailOp),
        details + 1,
        reason: 'exactly one fresh detail after the terminal settle',
      );
      expect(fixture.count(_statusOp), reads, reason: 'no capability read');
      expect(
        fixture.count(_attributeOp),
        attributes + 1,
        reason:
            'the row expanded during the hold reads once on the fresh detail',
      );
      expect(find.byKey(_edit), findsOneWidget, reason: 'still expanded');
      expect(find.text('不處理'), findsOneWidget);
      expect(find.text('待處理'), findsNothing);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets('R5 unknown future category shows the raw value in the parent '
      'row', (tester) async {
    final fixture = _futureCategoryFixture();
    await _mount(tester, fixture: fixture);
    await _expand(tester);
    expect(fixture.count(_attributeOp), 1);
    expect(find.byKey(_edit), findsOneWidget, reason: 'parent STATUS row');
    expect(find.text('未來狀態'), findsOneWidget);
    expect(find.text('分類：FUTURE_CATEGORY'), findsOneWidget);
    expect(find.textContaining('gid://'), findsNothing);
  });

  testWidgets('R5 unknown future category shows the raw value in the generic '
      'row', (tester) async {
    final fixture = _futureCategoryFixture();
    await _mount(tester, fixture: fixture, generic: true);
    await _expand(tester);
    expect(fixture.count(_attributeOp), 1);
    expect(find.byKey(_edit), findsNothing, reason: 'generic read-only row');
    expect(find.text('未來狀態'), findsOneWidget);
    expect(find.text('分類：FUTURE_CATEGORY'), findsOneWidget);
    expect(find.textContaining('gid://'), findsNothing);
  });

  testWidgets(
    'R6 manual refresh returning an older updatedAt keeps the confirmed '
    'detail and no permanent skeleton',
    (tester) async {
      final h = await _mount(tester);
      await _expand(tester);
      await _openEditor(tester);
      await _choose(tester, _canceled);
      await tester.tap(find.byKey(_save));
      await _until(tester, () => h.fixture.count(_lifecycleOp) == 2);
      await settleNetworkWidgets(tester);
      expect(find.text('分類：已取消'), findsOneWidget, reason: 'confirmed');

      final server = h.fixture.item(group: false);
      server.updatedAt = server.updatedAt.subtract(const Duration(seconds: 10));
      await tester.tap(find.byTooltip('重新整理'));
      await settleNetworkWidgets(tester);
      expect(h.fixture.count(_detailOp), 2, reason: 'refresh was sent');
      expect(
        find.byKey(const ValueKey('work-item-attributes')),
        findsOneWidget,
        reason: 'confirmed detail retained',
      );
      expect(find.text('不處理'), findsOneWidget);
      expect(find.text('分類：已取消'), findsOneWidget);
      expect(h.fixture.mutations, 1);
    },
  );

  testWidgets(
    'held mutation: refresh, lifecycle, collapse and editor reopen issue zero '
    'requests; parent unconfirmed until the terminal settle',
    (tester) async {
      final h = await _mount(tester);
      final apply = Completer<void>();
      h.fixture.holdBeforeApply = apply;
      await _expand(tester);
      expect(h.fixture.count(_attributeOp), 1);
      await _openEditor(tester);
      expect(h.fixture.count(_statusOp), 1);
      await _choose(tester, _canceled);
      await tester.tap(find.byKey(_save));
      await _until(tester, () => h.fixture.awaitingApply);

      final held = h.fixture.requests.length;
      expect(h.fixture.operations.sublist(held - 2), [
        _statusOp,
        _statusWriteOp,
      ]);
      await _popRoute(tester);
      expect(find.byKey(_save), findsNothing, reason: 'editor popped');
      expect(find.byKey(_banner), findsOneWidget);
      expect(find.byKey(_fieldPending), findsOneWidget);
      expect(find.text('不處理'), findsNothing, reason: 'nothing confirmed yet');

      await tester.tap(find.byTooltip('重新整理'), warnIfMissed: false);
      await _frames(tester);
      await tester.tap(find.text('關閉工作項目'), warnIfMissed: false);
      await _frames(tester);
      expect(find.text('確認關閉'), findsNothing);
      await tester.tap(find.byKey(_edit), warnIfMissed: false);
      await _frames(tester);
      await tester.tap(find.text('屬性'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byKey(_fieldPending), findsNothing, reason: 'row removed');
      await tester.tap(find.text('屬性'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byKey(_fieldPending), findsOneWidget, reason: 'recreated');
      await tester.tap(find.byKey(_edit), warnIfMissed: false);
      await _frames(tester);
      expect(h.fixture.requests.length, held, reason: 'no request while held');
      expect(h.fixture.mutations, 1);

      apply.complete();
      await _until(tester, () => find.byKey(_banner).evaluate().isEmpty);
      await settleNetworkWidgets(tester);
      expect(h.fixture.mutations, 1);
      expect(h.fixture.appliedMutationNonces, [1]);
      expect(h.fixture.operations.sublist(held), [_statusOp, _lifecycleOp]);
      expect(h.fixture.count(_detailOp), 1, reason: 'confirmed: no reload');
      expect(h.fixture.count(_attributeOp), 1, reason: 'confirmed row blocks');
      expect(find.text('不處理'), findsOneWidget);
      expect(find.text('分類：已取消'), findsOneWidget);
      expect(find.text('目前為開啟'), findsOneWidget, reason: 'category ≠ state');
      expect(h.fixture.unhandled, isEmpty);
    },
  );

  testWidgets('held lifecycle read blocks Status capability and open', (
    tester,
  ) async {
    final fixture = _fixture()..holdNextLifecycleRead = Completer<void>();
    final h = await _mount(tester, fixture: fixture, settle: false);
    await _until(tester, () => fixture.count(_lifecycleOp) == 1);
    await _expand(tester, settle: false);
    await _until(tester, () => fixture.count(_attributeOp) == 1);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await _frames(tester);
    expect(fixture.heldCount, 1, reason: 'only the lifecycle read is held');
    await tester.tap(find.byKey(_edit), warnIfMissed: false);
    await _frames(tester);
    expect(fixture.count(_statusOp), 0);
    expect(
      tester.widget<TextButton>(find.byKey(_edit)).onPressed,
      isNull,
      reason: 'gate closed while the lifecycle read is in flight',
    );

    fixture.releaseHolds();
    await settleNetworkWidgets(tester);
    expect(
      tester.widget<TextButton>(find.byKey(_edit)).onPressed,
      isNotNull,
      reason: 'the gate must reopen without another unrelated rebuild',
    );
    await _openEditor(tester);
    expect(fixture.count(_statusOp), 1);
    expect(h.fixture.mutations, 0);
  });

  testWidgets('held lifecycle write blocks Status save before any preflight', (
    tester,
  ) async {
    final h = await _mount(tester);
    await _expand(tester);
    await _openEditor(tester);
    await _choose(tester, _canceled);
    final close = find.ancestor(
      of: find.text('關閉工作項目', skipOffstage: false),
      matching: find.byWidgetPredicate(
        (widget) => widget is ButtonStyleButton,
        skipOffstage: false,
      ),
    );
    h.fixture.holdNextLifecycleRead = Completer<void>();
    tester.widget<ButtonStyleButton>(close.first).onPressed!();
    await _frames(tester);
    await tester.tap(find.text('確認關閉'));
    await _until(tester, () => h.fixture.count(_lifecycleOp) == 2);
    final before = h.fixture.requests.length;

    await tester.tap(find.byKey(_save));
    await _frames(tester);
    expect(h.fixture.requests.length, before);
    expect(h.fixture.count(_statusOp), 1, reason: 'capability read only');
    expect(h.fixture.mutations, 0);
    expect(h.fixture.count(_lifecycleWriteOp), 0);
    h.fixture.releaseHolds();
    await settleNetworkWidgets(tester);
  });

  testWidgets(
    'lost ACK: one fresh detail read, zero replay, stale value never painted',
    (tester) async {
      final h = await _mount(tester);
      h.fixture.loseNextAck = true;
      await _expand(tester);
      await _openEditor(tester);
      await _choose(tester, _canceled);
      final before = h.fixture.requests.length;
      await tester.tap(find.byKey(_save));
      await _until(tester, () => h.fixture.count(_detailOp) == 2);
      await settleNetworkWidgets(tester);

      expect(h.fixture.mutations, 1);
      expect(h.fixture.appliedMutationNonces, [1]);
      expect(
        h.fixture.operations.sublist(before),
        [_statusOp, _statusWriteOp, _detailOp, _lifecycleOp, _attributeOp],
        reason:
            'preflight, one write, one detail, the remounted lifecycle '
            'read, one attribute read for the still-expanded row; no '
            'capability read and no write replay',
      );
      expect(
        find.byKey(const ValueKey('work-item-status-result')),
        findsNothing,
      );
      expect(find.byKey(_edit), findsOneWidget, reason: 'row still expanded');
      expect(find.byKey(_unconfirmed), findsOneWidget);
      expect(find.text('不處理'), findsOneWidget, reason: 'fresh server truth');
      expect(find.text('待處理'), findsNothing, reason: 'stale value');
      expect(h.fixture.mutations, 1, reason: 'never replayed');
      expect(h.fixture.count(_lifecycleWriteOp), 0);
      expect(h.fixture.unhandled, isEmpty);
    },
  );

  testWidgets('DONE closes on the server: state and revision from snapshot', (
    tester,
  ) async {
    final h = await _mount(tester);
    final opened = h.fixture.item(group: false).updatedAt;
    await _expand(tester);
    await _openEditor(tester);
    await _choose(tester, _done);
    await tester.tap(find.byKey(_save));
    await _until(tester, () => h.fixture.count(_statusOp) == 3);
    await settleNetworkWidgets(tester);

    final server = h.fixture.item(group: false);
    expect(server.state, 'CLOSED');
    expect(server.updatedAt, opened.add(const Duration(seconds: 1)));
    expect(h.fixture.count(_detailOp), 1);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('分類：已完成'), findsOneWidget);
    expect(find.text('目前為已關閉'), findsOneWidget);
    expect(find.text('關閉工作項目'), findsNothing);
    expect(h.fixture.count(_lifecycleWriteOp), 0, reason: 'no client close');
  });

  testWidgets('DONE category without a server close keeps the item open', (
    tester,
  ) async {
    final fixture = _fixture();
    fixture.item(group: false).closesOn.clear();
    final h = await _mount(tester, fixture: fixture);
    await _expand(tester);
    await _openEditor(tester);
    await _choose(tester, _done);
    await tester.tap(find.byKey(_save));
    await _until(tester, () => h.fixture.count(_statusOp) == 3);
    await settleNetworkWidgets(tester);
    expect(fixture.item(group: false).state, 'OPEN');
    expect(find.text('分類：已完成'), findsOneWidget);
    expect(find.text('目前為開啟'), findsOneWidget);
  });

  testWidgets('two pages for one item cannot overlap Status writes', (
    tester,
  ) async {
    final fixture = _fixture();
    final apply = Completer<void>();
    final h = await _mount(tester, fixture: fixture, pages: 2);
    fixture.holdBeforeApply = apply;
    await _expand(tester, page: 'b');
    await _openEditor(tester, page: 'b');
    await _choose(tester, _canceled);
    await tester.tap(find.byKey(_save));
    await _until(tester, () => fixture.awaitingApply);
    await _popRoute(tester);
    expect(find.byKey(_save), findsNothing, reason: 'editor popped');
    final held = fixture.requests.length;

    await _expand(tester, page: 'a', settle: false);
    await _frames(tester);
    final editA = find.descendant(
      of: find.byKey(const ValueKey('page-a')),
      matching: find.byKey(_edit),
    );
    await tester.tap(editA, warnIfMissed: false);
    await _frames(tester);
    expect(
      fixture.operations.sublist(held).where((op) => op == _statusOp),
      isEmpty,
    );
    expect(fixture.mutations, 1);

    apply.complete();
    await settleNetworkWidgets(tester);
    expect(fixture.mutations, 1);
    expect(h.fixture.appliedMutationNonces, [1]);
  });

  testWidgets('owner away and back during a held write never paints', (
    tester,
  ) async {
    final h = await _mount(tester);
    final apply = Completer<void>();
    h.fixture.holdBeforeApply = apply;
    await _expand(tester);
    await _openEditor(tester);
    await _choose(tester, _canceled);
    await tester.tap(find.byKey(_save));
    await _until(tester, () => h.fixture.awaitingApply);
    final generation = h.session.generation;
    await tester.runAsync(() => h.session.endSession());
    await tester.runAsync(() => h.session.select(h.session.accounts.single));
    expect(h.session.active?.key, h.fixture.account.key);
    expect(h.session.generation, greaterThan(generation));
    apply.complete();
    await settleNetworkWidgets(tester);
    expect(h.fixture.mutations, 1);
    expect(find.text('分類：已取消'), findsNothing);
    expect(find.text('已確認狀態：不處理 · 開啟中'), findsNothing);
  });

  testWidgets(
    'S1 foreign confirmed write releases B own confirmed pin; a failed '
    'terminal reload never repaints it; manual refresh recovers',
    (tester) async {
      final fixture = _fixture();
      await _mount(tester, fixture: fixture, pages: 2);
      await _expand(tester, page: 'b');
      await _openEditor(tester, page: 'b');
      await _choose(tester, _canceled);
      await tester.tap(find.byKey(_save));
      await settleNetworkWidgets(tester);
      expect(fixture.mutations, 1);
      expect(
        _in('b', find.text('不處理')),
        findsOneWidget,
        reason: 'positive control: B pinned its own confirmed save',
      );

      await _expand(tester, page: 'a');
      await _openEditor(tester, page: 'a');
      await _choose(tester, _doing);
      final details = fixture.count(_detailOp);
      fixture.failNextDetail = true;
      await tester.tap(find.byKey(_save));
      await _until(tester, () => fixture.count(_detailOp) == details + 1);
      await settleNetworkWidgets(tester);
      expect(fixture.mutations, 2);
      expect(fixture.item(group: false).assignment?.id, _doing);
      expect(fixture.failNextDetail, isFalse, reason: 'B reload got the 503');
      expect(
        fixture.count(_detailOp),
        details + 1,
        reason: 'one terminal reload on B, no automatic retry',
      );
      expect(
        _in('b', find.text('不處理')),
        findsNothing,
        reason: 'superseded own pin is never painted as current',
      );
      expect(_in('a', find.text('進行中')), findsOneWidget, reason: 'writer');
      final refresh = _refreshButton(page: 'b');
      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);

      await tester.tap(refresh);
      await settleNetworkWidgets(tester);
      expect(fixture.count(_detailOp), details + 2);
      await _expand(tester, page: 'b');
      expect(_in('b', find.text('進行中')), findsOneWidget);
      expect(_in('b', find.text('不處理')), findsNothing);
      expect(fixture.mutations, 2, reason: 'never replayed');
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'S1 a STATUS row loaded before another page holds a write is dropped at '
    'hold start and never reappears after the terminal',
    (tester) async {
      final fixture = _fixture();
      await _mount(tester, fixture: fixture, pages: 2, genericIds: {'b'});
      await _expand(tester, page: 'b');
      expect(_in('b', find.byKey(_edit)), findsNothing, reason: 'generic row');
      expect(
        _in('b', find.text('待處理')),
        findsOneWidget,
        reason: 'positive control: B loaded STATUS before the hold',
      );

      final apply = Completer<void>();
      fixture.holdBeforeApply = apply;
      await _expand(tester, page: 'a');
      await _openEditor(tester, page: 'a');
      await _choose(tester, _canceled);
      await tester.tap(find.byKey(_save));
      await _until(tester, () => fixture.awaitingApply);
      await _popRoute(tester);
      expect(find.byKey(_save), findsNothing, reason: 'editor popped');
      final ledger = fixture.requests.length;
      expect(fixture.heldCount, 1, reason: 'the write is held');
      expect(_in('b', find.byKey(_banner)), findsOneWidget, reason: 'B held');
      expect(
        _in('b', find.text('待處理')),
        findsNothing,
        reason: 'the pre-write value is dropped when the hold starts',
      );
      await _drain(tester);
      expect(fixture.requests.length, ledger, reason: 'zero held reads');

      final details = fixture.count(_detailOp);
      final attributes = fixture.count(_attributeOp);
      apply.complete();
      await _until(tester, () => find.byKey(_banner).evaluate().isEmpty);
      await settleNetworkWidgets(tester);
      expect(fixture.mutations, 1);
      expect(
        _in('b', find.text('待處理')),
        findsNothing,
        reason: 'never reappears after the terminal',
      );
      expect(
        fixture.count(_detailOp),
        details + 1,
        reason: 'exactly one reload on the generic page',
      );
      expect(
        fixture.count(_attributeOp),
        attributes + 1,
        reason: 'the row expanded before the hold reads once after the reload',
      );
      expect(_in('b', find.text('不處理')), findsOneWidget);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'S2 a terminal reload older than a foreign confirmed write never paints '
    'STATUS as current; visible hint; manual refresh recovers',
    (tester) async {
      final fixture = _fixture();
      final server = fixture.item(group: false);
      final original = server.assignment;
      await _mount(tester, fixture: fixture, pages: 2);
      await _expand(tester, page: 'b');
      expect(_in('b', find.text('待處理')), findsOneWidget, reason: 'control');

      await _expand(tester, page: 'a');
      await _openEditor(tester, page: 'a');
      await _choose(tester, _canceled);
      final details = fixture.count(_detailOp);
      final attributes = fixture.count(_attributeOp);
      fixture.holdNextDetail = Completer<void>();
      await tester.tap(find.byKey(_save));
      await _until(tester, () => fixture.count(_detailOp) == details + 1);
      await _drain(tester);
      expect(fixture.mutations, 1);
      expect(fixture.heldCount, 1, reason: 'B terminal reload is held');
      final written = server.assignment;
      final revision = server.updatedAt;
      server
        ..assignment = original
        ..updatedAt = revision.subtract(const Duration(seconds: 10));
      fixture.releaseHolds();
      await _drain(tester);
      await settleNetworkWidgets(tester);
      expect(
        fixture.count(_detailOp),
        details + 1,
        reason: 'one terminal reload, no automatic retry loop',
      );

      await _expand(tester, page: 'b');
      expect(
        fixture.count(_attributeOp),
        attributes,
        reason: 'no STATUS read while the detail is below the floor',
      );
      expect(
        _in('b', find.text('待處理')),
        findsNothing,
        reason: 'lagging value is not painted as current',
      );
      expect(_in('b', find.byKey(_stale)), findsOneWidget);
      final refresh = _refreshButton(page: 'b');
      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);

      server
        ..assignment = written
        ..updatedAt = revision;
      await tester.tap(refresh);
      await settleNetworkWidgets(tester);
      expect(fixture.count(_detailOp), details + 2);
      expect(
        fixture.count(_attributeOp),
        attributes + 1,
        reason: 'the row expanded above reads once on the current detail',
      );
      expect(_in('b', find.text('不處理')), findsOneWidget);
      expect(_in('b', find.byKey(_stale)), findsNothing);
      expect(fixture.mutations, 1);
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'S2 a foreign write with an unknown outcome stays visibly unconfirmed on '
    'B until a manual refresh',
    (tester) async {
      final fixture = _fixture();
      await _mount(tester, fixture: fixture, pages: 2);
      await _expand(tester, page: 'a');
      await _openEditor(tester, page: 'a');
      await _choose(tester, _canceled);
      fixture.loseNextAck = true;
      final details = fixture.count(_detailOp);
      await tester.tap(find.byKey(_save));
      await _until(tester, () => fixture.count(_detailOp) == details + 2);
      await settleNetworkWidgets(tester);
      expect(fixture.mutations, 1);
      expect(fixture.appliedMutationNonces, [1]);
      expect(
        fixture.count(_detailOp),
        details + 2,
        reason: 'one reload on the writer, one on B',
      );

      await _expand(tester, page: 'b');
      expect(_in('b', find.text('不處理')), findsOneWidget, reason: 'read');
      expect(
        _in('b', find.byKey(_unconfirmed)),
        findsOneWidget,
        reason: 'the foreign outcome is unknown',
      );

      await tester.tap(_refreshButton(page: 'b'));
      await settleNetworkWidgets(tester);
      expect(fixture.count(_detailOp), details + 3);
      expect(_in('b', find.byKey(_edit)), findsOneWidget, reason: 'expanded');
      expect(_in('b', find.text('不處理')), findsOneWidget);
      expect(
        _in('b', find.byKey(_unconfirmed)),
        findsNothing,
        reason: 'a manual refresh acknowledges it',
      );
      expect(fixture.mutations, 1, reason: 'never replayed');
      expect(fixture.unhandled, isEmpty);
    },
  );

  testWidgets(
    'S3 a labels refetch dropped behind the confirmed STATUS revision shows '
    'the unconfirmed hint instead of endless updating',
    (tester) async {
      final fixture = _fixture()
        ..item(group: false).labelIds = [...statusFixtureLabels.keys];
      await _mount(tester, fixture: fixture);
      await _expand(tester);
      await _openEditor(tester);
      await _choose(tester, _canceled);
      await tester.tap(find.byKey(_save));
      await _until(tester, () => fixture.count(_lifecycleOp) == 2);
      await settleNetworkWidgets(tester);
      expect(find.text('分類：已取消'), findsOneWidget, reason: 'pinned');
      final server = fixture.item(group: false);
      final revision = server.updatedAt;

      await _openLabels(tester);
      await tester.tap(find.byKey(_labelsClear));
      await tester.pump();
      final details = fixture.count(_detailOp);
      fixture.holdNextDetail = Completer<void>();
      await tester.tap(find.byKey(_labelsSave));
      await _until(tester, () => fixture.count(_detailOp) == details + 1);
      await _drain(tester);
      expect(fixture.count(_labelsWriteOp), 1);
      expect(fixture.heldCount, 1, reason: 'the labels refetch is held');
      expect(find.byKey(_labelsUpdating, skipOffstage: false), findsOneWidget);

      final settled = server.updatedAt;
      server.updatedAt = revision.subtract(const Duration(seconds: 10));
      fixture.releaseHolds();
      await settleNetworkWidgets(tester);
      expect(find.byKey(_labelsSave), findsNothing);
      expect(fixture.count(_detailOp), details + 1, reason: 'no retry loop');
      expect(
        find.byKey(_labelsUpdating, skipOffstage: false),
        findsNothing,
        reason: 'nothing is running any more',
      );
      expect(find.byKey(_labelsUnconfirmed), findsOneWidget);
      expect(find.text('分類：已取消'), findsOneWidget, reason: 'own pin kept');
      final refresh = _refreshButton();
      expect(tester.widget<IconButton>(refresh).onPressed, isNotNull);

      server.updatedAt = settled;
      await tester.tap(refresh);
      await settleNetworkWidgets(tester);
      expect(fixture.count(_detailOp), details + 2);
      expect(find.byKey(_labelsUnconfirmed), findsNothing);
      expect(find.text('沒有標籤'), findsOneWidget);
      expect(fixture.count(_labelsWriteOp), 1);
      expect(fixture.unhandled, isEmpty);
    },
  );
}

Finder _refreshButton({String? page}) =>
    _in(page, find.widgetWithIcon(IconButton, Icons.refresh));

typedef _Mounted = ({
  WorkItemStatusFixture fixture,
  SessionController session,
  Account account,
  GitLabApi api,
});

WorkItemStatusFixture _fixture() => WorkItemStatusFixture()..serveParent = true;

Future<_Mounted> _mount(
  WidgetTester tester, {
  WorkItemStatusFixture? fixture,
  bool settle = true,
  int pages = 1,
  bool launcher = false,
  bool generic = false,
  Set<String> genericIds = const {},
}) async {
  final server = fixture ?? _fixture();
  final session = controllerFor(MemoryAccountStore(), server.adapter);
  // Tear-downs run last-in first-out: holds, then clients, then session.
  addTearDown(session.dispose);
  addTearDown(server.closeAll);
  addTearDown(server.releaseHolds);
  await tester.binding.setSurfaceSize(Size(pages * 420.0, 2200));
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
    ownerChanges: generic || genericIds.contains(id) ? null : session,
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
  } else if (pages == 1) {
    home = page('a');
  } else {
    home = Row(
      children: [
        Expanded(child: page('a')),
        Expanded(child: page('b')),
      ],
    );
  }
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sessionProvider.overrideWithValue(session)],
      child: MaterialApp(home: home),
    ),
  );
  if (settle) await settleNetworkWidgets(tester);
  return (fixture: server, session: session, account: account, api: api);
}

Finder _in(String? page, Finder finder) => page == null
    ? finder
    : find.descendant(of: find.byKey(ValueKey('page-$page')), matching: finder);

Future<void> _expand(
  WidgetTester tester, {
  String? page,
  bool settle = true,
}) async {
  await tester.tap(_in(page, find.text('屬性')));
  if (settle) {
    await settleNetworkWidgets(tester);
  } else {
    await _frames(tester);
  }
}

Future<void> _openEditor(WidgetTester tester, {String? page}) async {
  await tester.tap(_in(page, find.byKey(_edit)));
  await settleNetworkWidgets(tester);
  expect(find.byKey(_save), findsOneWidget);
}

Future<void> _choose(WidgetTester tester, String id) async {
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

/// Pops the top route and pumps a bounded transition: the overlay entry is
/// removed only on the frame after the pop animation completes.
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

/// Invokes the real button's own callback, including when another route
/// covers it. A disabled button is a refusal too.
Future<void> _press(WidgetTester tester, Key key) async {
  final widget = tester.widget(find.byKey(key, skipOffstage: false));
  if (widget case ButtonStyleButton(:final onPressed)) onPressed?.call();
  await _drain(tester);
}

Future<void> _openLabels(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_labelsEdit));
  await tester.pump();
  await tester.tap(find.byKey(_labelsEdit));
  await settleNetworkWidgets(tester);
  expect(find.byKey(_labelsSave), findsOneWidget);
}

Future<void> _openWeight(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_weightEdit));
  await tester.pump();
  await tester.tap(find.byKey(_weightEdit));
  await settleNetworkWidgets(tester);
  expect(find.byKey(_weightSave), findsOneWidget);
}

WorkItemStatusFixture _weightFixture() {
  final fixture = _fixture();
  fixture.item(group: false)
    ..weightWidget = true
    ..weight = 3;
  return fixture;
}

WorkItemStatusFixture _assigneeFixture() {
  final fixture = _fixture();
  fixture.item(group: false).assigneeIds = [_owner];
  return fixture;
}

WorkItemStatusFixture _milestoneFixture() {
  final fixture = _fixture();
  fixture.item(group: false)
    ..milestoneWidget = true
    ..milestoneId = _october;
  return fixture;
}

Map<String, Object?>? _lastInput(
  WorkItemStatusFixture fixture,
  String operation,
) => fixture.requests
    .lastWhere((request) => request.operation == operation)
    .input;

Future<void> _openAssignees(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_assigneesEdit));
  await tester.pump();
  await tester.tap(find.byKey(_assigneesEdit));
  await settleNetworkWidgets(tester);
  expect(find.byKey(_assigneesSave), findsOneWidget);
  expect(
    find.byKey(const ValueKey('work-item-assignee-row-$_owner')),
    findsOneWidget,
    reason: 'current assignee row',
  );
}

Future<void> _addCandidate(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('work-item-assignees-search')),
    '候選',
  );
  await tester.tap(
    find.byKey(const ValueKey('work-item-assignees-search-submit')),
  );
  await settleNetworkWidgets(tester);
  final row = find.byKey(const ValueKey('work-item-assignee-row-$_candidate'));
  expect(row, findsOneWidget, reason: 'candidate row');
  await tester.tap(row);
  await tester.pump();
  expect(find.text('已選 2 人'), findsOneWidget);
}

Future<void> _openMilestone(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(_milestoneEdit));
  await tester.pump();
  await tester.tap(find.byKey(_milestoneEdit));
  await settleNetworkWidgets(tester);
  expect(find.byKey(_milestoneSave), findsOneWidget);
  expect(
    find.byKey(const ValueKey('work-item-milestone-current')),
    findsOneWidget,
  );
}

Future<void> _chooseMilestone(WidgetTester tester) async {
  await tester.tap(
    find.byKey(const ValueKey('work-item-milestone-choice-$_november')),
  );
  await tester.pump();
  expect(
    find.byKey(const ValueKey('work-item-milestone-pending')),
    findsOneWidget,
  );
}

WorkItemStatusFixture _futureCategoryFixture() {
  const future = StatusFixtureMember(
    id: 'gid://gitlab/WorkItems::Statuses::Custom::Status/77',
    name: '未來狀態',
    iconName: 'status_todo',
    color: '#737278',
    position: 4,
    category: 'FUTURE_CATEGORY',
  );
  final fixture = _fixture();
  fixture.item(group: false)
    ..members = [...WorkItemStatusFixture.defaultMembers, future]
    ..assignment = future;
  return fixture;
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
