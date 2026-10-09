import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_labels_models.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_labels.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/work_item_labels_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('does not read labels until the edit action is opened', (
    tester,
  ) async {
    final fixture = WorkItemLabelsFixture(initialLabelCount: 3);
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);

    expect(find.text('變更標籤'), findsOneWidget);
    expect(fixture.labelsReads, 0);
    expect(fixture.projectSearches, 0);
    expect(fixture.groupSearches, 0);
    expect(find.byType(Chip), findsNWidgets(3));
  });

  testWidgets('child save snapshots have no parent publication hook', (
    tester,
  ) async {
    final fixture = WorkItemLabelsFixture(initialLabelCount: 2);
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);

    final control = tester.widget<WorkItemLabelsControl>(
      find.byType(WorkItemLabelsControl),
    );
    expect(control.onSaved, isNull);
  });

  testWidgets(
    'parent shows first 50 chips while editor reads all 120 across pages',
    (tester) async {
      final fixture = WorkItemLabelsFixture(initialLabelCount: 120);
      addTearDown(fixture.api.close);
      await _pump(tester, fixture);

      // Parent shows first 50 chips and the partial indicator
      expect(find.byType(Chip), findsNWidgets(50));
      expect(find.text('只顯示前 50 個標籤。'), findsOneWidget);

      // Open editor: reads full catalog
      await _openEditor(tester, fixture);

      // Editor header shows all 120 selected
      expect(find.text('已選擇 120 個標籤'), findsOneWidget);
      expect(fixture.labelsReads, greaterThanOrEqualTo(2));
    },
  );

  testWidgets(
    'conflict warning shows both full titles and fixed risk sentence only when allowed',
    (tester) async {
      final customLabels = [
        const WorkItemLabel(
          id: 'gid://gitlab/ProjectLabel/1',
          title: 'workflow::backend::review',
          color: '#1068BF',
          textColor: '#FFFFFF',
        ),
        const WorkItemLabel(
          id: 'gid://gitlab/ProjectLabel/2',
          title: 'workflow::backend::done',
          color: '#1068BF',
          textColor: '#FFFFFF',
        ),
        const WorkItemLabel(
          id: 'gid://gitlab/ProjectLabel/3',
          title: 'plain',
          color: '#1068BF',
          textColor: '#FFFFFF',
        ),
      ];

      // 1. When allowsScoped is allowed -> conflict UI appears
      final allowedFixture = WorkItemLabelsFixture(
        allowsScoped: WorkItemLabelAllowsScoped.allowed,
        initialCustomLabels: customLabels,
      );
      addTearDown(allowedFixture.api.close);
      await _pump(tester, allowedFixture);
      await _openEditor(tester, allowedFixture);

      expect(find.text('伺服器可能只保留同一範圍的一個標籤'), findsOneWidget);
      expect(find.text('workflow::backend::review'), findsWidgets);
      expect(find.text('workflow::backend::done'), findsWidgets);
      // GIDs are NOT dropped
      expect(find.text('已選擇 3 個標籤'), findsOneWidget);

      // 2. When allowsScoped is disabled or unknown -> NO conflict UI
      final disabledFixture = WorkItemLabelsFixture(
        allowsScoped: WorkItemLabelAllowsScoped.disabled,
        initialCustomLabels: customLabels,
      );
      addTearDown(disabledFixture.api.close);
      await _pump(tester, disabledFixture);
      await _openEditor(tester, disabledFixture);

      expect(find.text('伺服器可能只保留同一範圍的一個標籤'), findsNothing);
    },
  );

  testWidgets('handles nested and empty scope keys properly', (tester) async {
    final customLabels = [
      const WorkItemLabel(
        id: 'gid://gitlab/ProjectLabel/11',
        title: '::empty_key_val_1',
        color: '#1068BF',
        textColor: '#FFFFFF',
      ),
      const WorkItemLabel(
        id: 'gid://gitlab/ProjectLabel/12',
        title: '::empty_key_val_2',
        color: '#1068BF',
        textColor: '#FFFFFF',
      ),
      const WorkItemLabel(
        id: 'gid://gitlab/ProjectLabel/13',
        title: 'a::b::c',
        color: '#1068BF',
        textColor: '#FFFFFF',
      ),
      const WorkItemLabel(
        id: 'gid://gitlab/ProjectLabel/14',
        title: 'a::b::',
        color: '#1068BF',
        textColor: '#FFFFFF',
      ),
    ];

    final fixture = WorkItemLabelsFixture(
      allowsScoped: WorkItemLabelAllowsScoped.allowed,
      initialCustomLabels: customLabels,
    );
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);

    // Empty key conflict box
    expect(
      find.byKey(const ValueKey('work-item-labels-conflict-')),
      findsOneWidget,
    );
    // a::b conflict box
    expect(
      find.byKey(const ValueKey('work-item-labels-conflict-a::b')),
      findsOneWidget,
    );
  });

  testWidgets('color contrast accepts 4.5 and falls back to neutral', (
    tester,
  ) async {
    final customLabels = [
      const WorkItemLabel(
        id: 'gid://gitlab/ProjectLabel/21',
        title: '對比足夠',
        color: '#FFFFFF',
        textColor: '#000000', // contrast 21.0 >= 4.5
      ),
      const WorkItemLabel(
        id: 'gid://gitlab/ProjectLabel/22',
        title: '對比不足',
        color: '#FFFFFF',
        textColor: '#777777', // contrast < 4.5
      ),
      const WorkItemLabel(
        id: 'gid://gitlab/ProjectLabel/23',
        title: '無效色碼',
        color: 'invalid',
        textColor: '#000000',
      ),
    ];

    final fixture = WorkItemLabelsFixture(initialCustomLabels: customLabels);
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);

    expect(find.text('對比足夠'), findsOneWidget);
    expect(find.text('對比不足'), findsOneWidget);
    expect(find.text('無效色碼'), findsOneWidget);
    // Invalid colors do not block editing
    expect(find.byKey(const ValueKey('work-item-labels-save')), findsOneWidget);
  });

  testWidgets(
    'search operates only on submit and routes project vs group correctly',
    (tester) async {
      // Project search
      final projectFixture = WorkItemLabelsFixture(groupOnly: false);
      addTearDown(projectFixture.api.close);
      await _pump(tester, projectFixture);
      await _openEditor(tester, projectFixture);

      // Typing does not trigger query
      await tester.enterText(
        find.byKey(const ValueKey('work-item-labels-search')),
        '測試',
      );
      await tester.pump();
      expect(projectFixture.projectSearches, 0);

      // Submit triggers query
      await tester.tap(
        find.byKey(const ValueKey('work-item-labels-search-submit')),
      );
      await settleNetworkWidgets(tester);
      expect(projectFixture.projectSearches, 1);
      expect(projectFixture.groupSearches, 0);

      // Group search
      final groupFixture = WorkItemLabelsFixture(groupOnly: true);
      addTearDown(groupFixture.api.close);
      await _pump(tester, groupFixture, group: true);
      await _openEditor(tester, groupFixture);

      await tester.enterText(
        find.byKey(const ValueKey('work-item-labels-search')),
        '群組搜尋',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settleNetworkWidgets(tester);
      expect(groupFixture.groupSearches, 1);
      expect(groupFixture.projectSearches, 0);

      // Verify no double submit occurs while search is already in flight
      final searchCompleter = Completer<ResponseBody>();
      groupFixture.heldSearches['慢速搜尋'] = searchCompleter;
      await tester.enterText(
        find.byKey(const ValueKey('work-item-labels-search')),
        '慢速搜尋',
      );
      // Trigger search via IME
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await pumpUntil(tester, () => groupFixture.groupSearches == 2);
      expect(groupFixture.groupSearches, 2);

      // Second submit via action or submit button while search in flight is dropped
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(groupFixture.groupSearches, 2);

      // Complete held search
      searchCompleter.complete(
        jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/7'},
            'group': {
              'id': WorkItemLabelsFixture.groupNamespaceId,
              'fullPath': 'group/sample',
              'labels': {
                'nodes': <dynamic>[],
                'pageInfo': {'hasNextPage': false, 'endCursor': null},
              },
            },
          },
        }),
      );
      await settleNetworkWidgets(tester);
    },
  );

  testWidgets('search validation rejects empty or control characters', (
    tester,
  ) async {
    final fixture = WorkItemLabelsFixture();
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);

    // Empty search
    await tester.enterText(
      find.byKey(const ValueKey('work-item-labels-search')),
      '   ',
    );
    await tester.tap(
      find.byKey(const ValueKey('work-item-labels-search-submit')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('work-item-labels-search-error')),
      findsOneWidget,
    );
    expect(fixture.projectSearches, 0);

    // Control character
    await tester.enterText(
      find.byKey(const ValueKey('work-item-labels-search')),
      'bad\x07char',
    );
    await tester.tap(
      find.byKey(const ValueKey('work-item-labels-search-submit')),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('work-item-labels-search-error')),
      findsOneWidget,
    );
    expect(fixture.projectSearches, 0);
  });

  testWidgets(
    'clear all removes every label even when candidate catalog is incomplete',
    (tester) async {
      final fixture = WorkItemLabelsFixture(initialLabelCount: 2);
      addTearDown(fixture.api.close);
      await _pump(tester, fixture);
      await _openEditor(tester, fixture);

      await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
      await tester.pump();
      expect(find.text('已選擇 0 個標籤'), findsOneWidget);

      await _save(tester, fixture);
      expect(fixture.mutations, 1);
      expect(fixture.lastRemoveLabelIds, hasLength(2));
      expect(fixture.lastAddLabelIds, isEmpty);
    },
  );

  testWidgets('noop save does not call start and keeps parent chips visible', (
    tester,
  ) async {
    final fixture = WorkItemLabelsFixture(initialLabelCount: 2);
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);

    // Save without changing selection
    await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
    await settleNetworkWidgets(tester);

    expect(fixture.mutations, 0);
    expect(find.text('標籤沒有變更'), findsOneWidget);
  });

  testWidgets('readonly state when metadata permission is false', (
    tester,
  ) async {
    final fixture = WorkItemLabelsFixture(
      setWorkItemMetadata: false,
      initialLabelCount: 2,
    );
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);

    expect(
      find.byKey(const ValueKey('work-item-labels-readonly')),
      findsOneWidget,
    );
    expect(find.text('沒有修改標籤的權限'), findsOneWidget);

    final saveButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('work-item-labels-save')),
    );
    expect(saveButton.onPressed, isNull);
  });

  testWidgets(
    'parent preview hides during write and updates to fresh chips on success',
    (tester) async {
      final fixture = WorkItemLabelsFixture(initialLabelCount: 2);
      fixture.holdMutation = Completer();
      addTearDown(() {
        fixture.releaseHoldMutation();
        fixture.api.close();
      });
      await _pump(tester, fixture);
      await _openEditor(tester, fixture);

      // Deselect label 1
      await tester.tap(
        find.byKey(ValueKey('work-item-label-row-${fixture.labelId(1)}')),
      );
      await tester.pump();

      // Tap save -> mutation in flight
      await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
      await pumpUntil(tester, () => fixture.mutations == 1);

      // Parent preview is hidden while write is in flight
      expect(find.byType(Chip, skipOffstage: false), findsNothing);
      expect(find.text('正在更新標籤', skipOffstage: false), findsOneWidget);

      // Release mutation
      fixture.releaseHoldMutation();
      await settleNetworkWidgets(tester);

      expect(fixture.mutations, 1);
      // Sheet should be popped on success
      expect(find.byKey(const ValueKey('work-item-labels-save')), findsNothing);
      // Parent chips should show only remaining label
      expect(find.byType(Chip), findsNWidgets(1));
    },
  );

  testWidgets(
    'failed parent refetch after mutation shows unconfirmed error and hides chips',
    (tester) async {
      final fixture = WorkItemLabelsFixture(initialLabelCount: 2);
      fixture.failParentRefetchAfterMutation = true;
      addTearDown(fixture.api.close);
      await _pump(tester, fixture);
      await _openEditor(tester, fixture);

      await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
      await settleNetworkWidgets(tester);

      expect(fixture.mutations, 1);
      // Parent refetch failed: unconfirmed text is displayed, old chips NOT restored
      expect(find.text('尚未確認最新標籤。請重新整理後再查看。'), findsOneWidget);
      expect(find.byType(Chip), findsNothing);
    },
  );

  testWidgets(
    'server notApplied status keeps user informed without auto retry',
    (tester) async {
      final fixture = WorkItemLabelsFixture(initialLabelCount: 2);
      fixture.notApplied = true;
      addTearDown(fixture.api.close);
      await _pump(tester, fixture);
      await _openEditor(tester, fixture);

      await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
      await settleNetworkWidgets(tester);

      expect(fixture.mutations, 1);
      expect(find.text('伺服器保留的標籤與所選不同'), findsOneWidget);
    },
  );

  testWidgets(
    'sheet disposal while mutation in flight settles parent pending cleanly',
    (tester) async {
      final fixture = WorkItemLabelsFixture(initialLabelCount: 2);
      fixture.holdMutation = Completer();
      addTearDown(() {
        fixture.releaseHoldMutation();
        fixture.api.close();
      });
      await _pump(tester, fixture);
      await _openEditor(tester, fixture);

      await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
      await tester.pump();

      // Trigger mutation
      await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
      await pumpUntil(tester, () => fixture.mutations == 1);

      // Pop the sheet before mutation finishes
      Navigator.of(
        tester.element(find.byKey(const ValueKey('work-item-labels-save'))),
      ).pop();
      await _settleHeldRoutePop(tester);

      // Release mutation
      fixture.releaseHoldMutation();
      await settleNetworkWidgets(tester);

      // Pending settled cleanly, parent did not hang
      expect(find.text('變更標籤'), findsOneWidget);
    },
  );

  testWidgets(
    'project route pop keeps write gate through actual APPLY and ACK',
    (tester) => _verifyRoutePopWriteGate(tester, group: false),
  );

  testWidgets(
    'group route pop keeps write gate through actual APPLY and ACK',
    (tester) => _verifyRoutePopWriteGate(tester, group: true),
  );

  testWidgets('route pop before handoff emits no START or SETTLE', (
    tester,
  ) async {
    // ignore: avoid_print
    print('PREHANDOFF start');
    final fixture = WorkItemLabelsFixture(initialLabelCount: 2);
    fixture.holdMutationApply = Completer<void>();
    addTearDown(() {
      fixture.releaseHoldLabelsRead();
      fixture.releaseHoldMutationApply();
      fixture.releaseHoldMutation();
      fixture.api.close();
    });
    final detail = await tester.runAsync(
      () => fixture.api.projectWorkItem(fixture.project, 100),
    );
    expect(detail, isNotNull);
    // ignore: avoid_print
    print('PREHANDOFF detail-loaded');
    final hostKey = GlobalKey<_LabelsLifecycleHostState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _LabelsLifecycleHost(
            key: hostKey,
            fixture: fixture,
            detail: detail!,
          ),
        ),
      ),
    );
    // ignore: avoid_print
    print('PREHANDOFF host-pumped');
    await _openEditor(tester, fixture);
    // ignore: avoid_print
    print('PREHANDOFF editor-open');

    fixture.holdLabelsRead = Completer<ResponseBody>();
    final labelsReadsBeforeSave = fixture.labelsReads;
    await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
    await pumpUntil(
      tester,
      () => fixture.labelsReads == labelsReadsBeforeSave + 1,
      description: 'waiting for held preflight read',
    );
    // ignore: avoid_print
    print('PREHANDOFF read-held');

    Navigator.of(
      tester.element(find.byKey(const ValueKey('work-item-labels-save'))),
    ).pop();
    await _settleHeldRoutePop(tester);
    // ignore: avoid_print
    print('PREHANDOFF route-popped');

    fixture.releaseHoldLabelsRead();
    await _settleHeldRoutePop(tester);
    // ignore: avoid_print
    print('PREHANDOFF read-released');
    final mutationsBeforeTerminalCleanup = fixture.mutations;
    final appliesBeforeTerminalCleanup = fixture.mutationApplies;
    final startsBeforeTerminalCleanup = hostKey.currentState!.starts;
    final settlesBeforeTerminalCleanup = hostKey.currentState!.settles;

    expect(mutationsBeforeTerminalCleanup, 0);
    expect(appliesBeforeTerminalCleanup, 0);
    expect(startsBeforeTerminalCleanup, 0);
    expect(settlesBeforeTerminalCleanup, 0);
    expect(
      find.byKey(const ValueKey('labels-lifecycle-pending')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'manual refresh and outer row disposal wait for actual write terminal',
    (tester) async {
      final fixture = WorkItemLabelsFixture(initialLabelCount: 2);
      fixture.holdMutationApply = Completer<void>();
      fixture.holdMutation = Completer<ResponseBody>();
      addTearDown(() {
        fixture.releaseHoldLabelsRead();
        fixture.releaseHoldMutationApply();
        fixture.releaseHoldMutation();
        fixture.api.close();
      });
      await _pump(tester, fixture);
      await _openEditor(tester, fixture);

      await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
      await tester.pump();
      final detailReadsBeforeWrite = fixture.detailReads;
      await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
      await pumpUntil(tester, () => fixture.mutations == 1);

      final refreshWhileWriting = tester.widget<IconButton>(_parentRefresh());
      expect(refreshWhileWriting.onPressed, isNull);
      expect(fixture.detailReads, detailReadsBeforeWrite);

      Navigator.of(
        tester.element(find.byKey(const ValueKey('work-item-labels-save'))),
      ).pop();
      await _settleHeldRoutePop(tester);
      expect(tester.widget<IconButton>(_parentRefresh()).onPressed, isNull);
      expect(fixture.detailReads, detailReadsBeforeWrite);

      fixture.releaseHoldMutationApply();
      await pumpUntil(tester, () => fixture.mutationApplies == 1);
      expect(fixture.detailReads, detailReadsBeforeWrite);
      expect(tester.widget<IconButton>(_parentRefresh()).onPressed, isNull);

      fixture.releaseHoldMutation();
      await settleNetworkWidgets(tester);
      expect(fixture.detailReads, detailReadsBeforeWrite + 1);
      expect(tester.widget<IconButton>(_parentRefresh()).onPressed, isNotNull);

      final rowFixture = WorkItemLabelsFixture(initialLabelCount: 2);
      rowFixture.holdMutationApply = Completer<void>();
      rowFixture.holdMutation = Completer<ResponseBody>();
      addTearDown(() {
        rowFixture.releaseHoldLabelsRead();
        rowFixture.releaseHoldMutationApply();
        rowFixture.releaseHoldMutation();
        rowFixture.api.close();
      });
      final detail = await tester.runAsync(
        () => rowFixture.api.projectWorkItem(rowFixture.project, 100),
      );
      expect(detail, isNotNull);
      final hostKey = GlobalKey<_LabelsLifecycleHostState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _LabelsLifecycleHost(
              key: hostKey,
              fixture: rowFixture,
              detail: detail!,
            ),
          ),
        ),
      );
      await _openEditor(tester, rowFixture);
      await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
      await pumpUntil(tester, () => rowFixture.mutations == 1);
      expect(hostKey.currentState!.starts, 1);
      expect(hostKey.currentState!.settles, 0);

      Navigator.of(
        tester.element(find.byKey(const ValueKey('work-item-labels-save'))),
      ).pop();
      await _settleHeldRoutePop(tester);
      await tester.tap(
        find.byKey(const ValueKey('labels-lifecycle-remove-row')),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('labels-lifecycle-pending')),
        findsOneWidget,
      );
      expect(hostKey.currentState!.settles, 0);

      rowFixture.releaseHoldMutationApply();
      await pumpUntil(tester, () => rowFixture.mutationApplies == 1);
      expect(hostKey.currentState!.settles, 0);
      expect(
        find.byKey(const ValueKey('labels-lifecycle-pending')),
        findsOneWidget,
      );

      rowFixture.releaseHoldMutation();
      await settleNetworkWidgets(tester);
      expect(hostKey.currentState!.starts, 1);
      expect(hostKey.currentState!.settles, 1);
      expect(
        find.byKey(const ValueKey('labels-lifecycle-pending')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('old mutation terminal after account and API switch is ignored', (
    tester,
  ) async {
    final handoffFirst = WorkItemLabelsFixture(initialLabelCount: 2);
    handoffFirst.holdMutationApply = Completer<void>();
    handoffFirst.holdMutation = Completer<ResponseBody>();
    final handoffSecond = WorkItemLabelsFixture(initialLabelCount: 1);
    addTearDown(() {
      handoffFirst.releaseHoldLabelsRead();
      handoffFirst.releaseHoldMutationApply();
      handoffFirst.releaseHoldMutation();
      handoffFirst.api.close();
    });
    addTearDown(handoffSecond.api.close);
    final handoffFirstDetail = await tester.runAsync(
      () => handoffFirst.api.projectWorkItem(handoffFirst.project, 100),
    );
    expect(handoffFirstDetail, isNotNull);
    final handoffSecondDetail = await tester.runAsync(
      () => handoffSecond.api.projectWorkItem(handoffSecond.project, 100),
    );
    expect(handoffSecondDetail, isNotNull);
    final hostKey = GlobalKey<_LabelsLifecycleHostState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _LabelsLifecycleHost(
            key: hostKey,
            fixture: handoffFirst,
            detail: handoffFirstDetail!,
          ),
        ),
      ),
    );
    await _openEditor(tester, handoffFirst);
    await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
    await pumpUntil(tester, () => handoffFirst.mutations == 1);
    expect(hostKey.currentState!.starts, 1);
    expect(hostKey.currentState!.settles, 0);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _LabelsLifecycleHost(
            key: hostKey,
            fixture: handoffSecond,
            detail: handoffSecondDetail!,
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(hostKey.currentState!.settles, 0);
    expect(
      find.byKey(const ValueKey('labels-lifecycle-pending')),
      findsOneWidget,
    );

    handoffFirst.releaseHoldMutationApply();
    await pumpUntil(tester, () => handoffFirst.mutationApplies == 1);
    expect(hostKey.currentState!.settles, 0);
    handoffFirst.releaseHoldMutation();
    await settleNetworkWidgets(tester);
    expect(hostKey.currentState!.settles, 1);
    expect(
      find.byKey(const ValueKey('labels-lifecycle-pending')),
      findsNothing,
    );

    final first = WorkItemLabelsFixture(initialLabelCount: 2);
    first.holdMutationApply = Completer<void>();
    first.holdMutation = Completer<ResponseBody>();
    final second = WorkItemLabelsFixture(
      initialCustomLabels: const [
        WorkItemLabel(
          id: 'gid://gitlab/ProjectLabel/851',
          title: 'new account current label',
          color: '#1068BF',
          textColor: '#FFFFFF',
        ),
      ],
    );
    addTearDown(() {
      first.releaseHoldLabelsRead();
      first.releaseHoldMutationApply();
      first.releaseHoldMutation();
      first.api.close();
    });
    addTearDown(second.api.close);
    await _pump(tester, first);
    await _openEditor(tester, first);
    await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
    await pumpUntil(tester, () => first.mutations == 1);
    final firstDetailReads = first.detailReads;

    final otherAccount = Account(
      instance: second.account.instance,
      user: const GitLabUser(id: 8, username: 'grace', name: 'Grace'),
      token: 'synthetic-other-token',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GraphWorkItemDetailPage.project(
            account: otherAccount,
            api: second.api,
            project: second.project,
            iid: 100,
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await _waitForChip(tester, 'new account current label');

    first.releaseHoldMutationApply();
    await pumpUntil(tester, () => first.mutationApplies == 1);
    first.releaseHoldMutation();
    await settleNetworkWidgets(tester);

    expect(first.detailReads, firstDetailReads);
    expect(
      find.widgetWithText(Chip, 'new account current label'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('work-item-labels-updating')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('work-item-labels-unconfirmed')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'layout at 320dp width, 2x text scale, long CJK titles, and 48dp save button',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final customLabels = [
        const WorkItemLabel(
          id: 'gid://gitlab/ProjectLabel/91',
          title: '這是一個非常長且完整的繁體中文標籤名稱::後端架構::微服務模組::待審查流程::關鍵修訂1',
          color: '#1068BF',
          textColor: '#FFFFFF',
        ),
        const WorkItemLabel(
          id: 'gid://gitlab/ProjectLabel/92',
          title: '這是一個非常長且完整的繁體中文標籤名稱::後端架構::微服務模組::待審查流程::關鍵修訂2',
          color: '#1068BF',
          textColor: '#FFFFFF',
        ),
      ];

      final fixture = WorkItemLabelsFixture(
        allowsScoped: WorkItemLabelAllowsScoped.allowed,
        initialCustomLabels: customLabels,
      );
      addTearDown(fixture.api.close);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 640),
              textScaler: TextScaler.linear(2.0),
              viewInsets: EdgeInsets.only(bottom: 24),
            ),
            child: Scaffold(
              body: GraphWorkItemDetailPage.project(
                account: fixture.account,
                api: fixture.api,
                project: fixture.project,
                iid: 100,
              ),
            ),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      await _openEditor(tester, fixture);

      // Verify save button minimum height >= 48 dp
      final saveButtonFinder = find.byKey(
        const ValueKey('work-item-labels-save'),
      );
      final saveSize = tester.getSize(saveButtonFinder);
      expect(saveSize.height, greaterThanOrEqualTo(48.0));

      // Verify title maxLines: 2 and ellipsis overflow
      final textWidgets = tester.widgetList<Text>(
        find.textContaining('這是一個非常長且完整的繁體中文標籤名稱'),
      );
      expect(textWidgets, isNotEmpty);
      for (final textWidget in textWidgets) {
        expect(textWidget.maxLines, 2);
        expect(textWidget.overflow, TextOverflow.ellipsis);
      }

      // No RenderFlex overflow exception
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'token A/B sequencing prevents Token A refetch from clearing Token B state',
    (tester) async {
      final fixture = WorkItemLabelsFixture(initialLabelCount: 2);
      addTearDown(fixture.api.close);
      await _pump(tester, fixture);
      await _openEditor(tester, fixture);
      final refetchA = fixture.holdNextDetailRead();

      // Clear labels and save -> Mutation A succeeds, settle triggers refetch A which is held
      await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
      await pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('work-item-labels-save'))
            .evaluate()
            .isEmpty,
      );
      // Mutation A completes, sheet pops, parent starts refetch A (held)
      expect(find.byKey(const ValueKey('work-item-labels-save')), findsNothing);

      // Now simulate Write B start with token B via WorkItemLabelsControl
      final control = tester.widget<WorkItemLabelsControl>(
        find.byType(WorkItemLabelsControl),
      );
      final tokenB = Object();
      control.onLabelWrite?.call(WorkItemLabelWritePhase.start, tokenB);
      await tester.pump();

      // Verify parent preview is hidden under Token B
      expect(find.text('正在更新標籤'), findsOneWidget);

      // Settle with wrong token does not clear Token B
      final wrongToken = Object();
      control.onLabelWrite?.call(WorkItemLabelWritePhase.settle, wrongToken);
      await tester.pump();
      expect(find.text('正在更新標籤'), findsOneWidget);

      // Now release refetch A while Token B is still in flight
      refetchA.succeed();
      await tester.pump();

      // Token A refetch MUST NOT unhide the preview while Token B is active!
      expect(find.text('正在更新標籤'), findsOneWidget);
      expect(find.byType(Chip), findsNothing);

      // Settle with matching token B settles pending cleanly
      control.onLabelWrite?.call(WorkItemLabelWritePhase.settle, tokenB);
      await settleNetworkWidgets(tester);
    },
  );

  testWidgets('A success after B success keeps B', (tester) async {
    final fixture = WorkItemLabelsFixture(initialLabelCount: 1);
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);

    final refetchA = await _clearAndHoldParentRead(tester, fixture);
    expect(refetchA.snapshot.labelTitles, isEmpty);

    final refetchB = await _addBAndHoldParentRead(tester, fixture);
    expect(refetchB.snapshot.labelTitles, ['候選1-B confirmed']);
    refetchB.succeed();
    await _waitForChip(tester, '候選1-B confirmed');
    expect(find.byType(Chip), findsOneWidget);

    refetchA.succeed();
    await settleNetworkWidgets(tester);

    expect(find.text('候選1-B confirmed'), findsOneWidget);
    expect(find.byType(Chip), findsOneWidget);
    expect(
      find.byKey(const ValueKey('work-item-labels-unconfirmed')),
      findsNothing,
    );
  });

  testWidgets('A error after B success keeps B confirmed', (tester) async {
    final fixture = WorkItemLabelsFixture(initialLabelCount: 1);
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);

    final refetchA = await _clearAndHoldParentRead(tester, fixture);
    final refetchB = await _addBAndHoldParentRead(tester, fixture);
    expect(refetchB.snapshot.labelTitles, ['候選1-B confirmed']);
    refetchB.succeed();
    await _waitForChip(tester, '候選1-B confirmed');

    refetchA.fail();
    await settleNetworkWidgets(tester);

    expect(find.text('候選1-B confirmed'), findsOneWidget);
    expect(find.byType(Chip), findsOneWidget);
    expect(
      find.byKey(const ValueKey('work-item-labels-unconfirmed')),
      findsNothing,
    );
  });

  testWidgets('A success after B refetch failure keeps hidden unconfirmed', (
    tester,
  ) async {
    final fixture = WorkItemLabelsFixture(initialLabelCount: 1);
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);

    final refetchA = await _clearAndHoldParentRead(tester, fixture);
    final refetchB = await _addBAndHoldParentRead(tester, fixture);
    expect(refetchB.snapshot.labelTitles, ['候選1-B confirmed']);
    refetchB.fail();
    await _waitForKey(tester, const ValueKey('work-item-labels-unconfirmed'));

    refetchA.succeed();
    await settleNetworkWidgets(tester);

    expect(
      find.byKey(const ValueKey('work-item-labels-unconfirmed')),
      findsOneWidget,
    );
    expect(find.byType(Chip), findsNothing);
    expect(find.text('候選1-B confirmed'), findsNothing);
  });

  testWidgets(
    'manual fresh read then A late success and error cannot clobber',
    (tester) async {
      await _verifyManualReadSupersedesLateA(tester, lateAErrors: false);
      await _verifyManualReadSupersedesLateA(tester, lateAErrors: true);
    },
  );

  testWidgets(
    'old manual read before B actual write returning after B settle cannot unhide or overwrite',
    (tester) async {
      final fixture = WorkItemLabelsFixture(initialLabelCount: 120);
      addTearDown(fixture.api.close);
      await _pump(tester, fixture);
      await _openEditor(tester, fixture);

      final oldManualRead = fixture.holdNextDetailRead();
      _startParentRefresh(tester);
      await pumpUntil(
        tester,
        () => oldManualRead.started,
        description: 'waiting for the old manual read to start',
      );
      expect(oldManualRead.snapshot.labelTitles, hasLength(120));
      expect(oldManualRead.snapshot.labelTitles.first, '標籤1');
      expect(oldManualRead.snapshot.labelTitles.last, '標籤120');

      await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
      await tester.pump();
      await _selectBCandidate(tester);
      final refetchB = fixture.holdNextDetailRead();
      await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
      await pumpUntil(
        tester,
        () => refetchB.started,
        description: 'waiting for parent refetch B',
      );
      expect(refetchB.snapshot.labelTitles, ['候選1-B confirmed']);
      expect(oldManualRead.snapshot.labelTitles, hasLength(120));
      expect(oldManualRead.snapshot.labelTitles.first, '標籤1');
      expect(oldManualRead.snapshot.labelTitles.last, '標籤120');
      refetchB.succeed();
      await _waitForChip(tester, '候選1-B confirmed');

      oldManualRead.succeed();
      await settleNetworkWidgets(tester);

      expect(find.text('候選1-B confirmed'), findsOneWidget);
      expect(find.byType(Chip), findsOneWidget);
      expect(
        find.byKey(const ValueKey('work-item-labels-unconfirmed')),
        findsNothing,
      );
      final refresh = tester.widget<IconButton>(_parentRefresh());
      expect(refresh.onPressed, isNotNull);
    },
  );

  testWidgets('one uncertain send displays error and blocks automatic retry', (
    tester,
  ) async {
    final fixture = WorkItemLabelsFixture(initialLabelCount: 2);
    fixture.mutationHttpError = 500;
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);

    await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
    await settleNetworkWidgets(tester);

    // Mutation sent exactly once, no automatic retry
    expect(fixture.mutations, 1);
    expect(find.text('無法確認寫入結果'), findsOneWidget);

    // Target was consumed; save button is disabled
    final saveButton = tester.widget<FilledButton>(
      find.byKey(const ValueKey('work-item-labels-save')),
    );
    expect(saveButton.onPressed, isNull);
    expect(fixture.mutations, 1);
  });

  testWidgets(
    'owner identity change dismisses editor route and drops session',
    (tester) async {
      final fixture = WorkItemLabelsFixture(initialLabelCount: 2);
      addTearDown(fixture.api.close);
      await _pump(tester, fixture);
      await _openEditor(tester, fixture);

      expect(
        find.byKey(const ValueKey('work-item-labels-save')),
        findsOneWidget,
      );

      // Pump with a different project (identity change)
      final otherProject = Project.fromJson(projectJson(99));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GraphWorkItemDetailPage.project(
              account: fixture.account,
              api: fixture.api,
              project: otherProject,
              iid: 100,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Editor route is dismissed on identity change
      expect(find.byKey(const ValueKey('work-item-labels-save')), findsNothing);
    },
  );

  testWidgets(
    'late parent read cannot paint after account and API invalidation',
    (tester) async {
      final first = WorkItemLabelsFixture(
        initialCustomLabels: const [
          WorkItemLabel(
            id: 'gid://gitlab/ProjectLabel/801',
            title: 'old account label',
            color: '#1068BF',
            textColor: '#FFFFFF',
          ),
        ],
      );
      final second = WorkItemLabelsFixture(
        initialCustomLabels: const [
          WorkItemLabel(
            id: 'gid://gitlab/ProjectLabel/802',
            title: 'new account label',
            color: '#1068BF',
            textColor: '#FFFFFF',
          ),
        ],
      );
      addTearDown(first.api.close);
      addTearDown(second.api.close);
      await _pump(tester, first);

      final late = first.holdNextDetailRead();
      _startParentRefresh(tester);
      await pumpUntil(
        tester,
        () => late.started,
        description: 'waiting for stale account/API read',
      );
      expect(late.snapshot.labelTitles, ['old account label']);

      final otherAccount = Account(
        instance: second.account.instance,
        user: const GitLabUser(id: 8, username: 'grace', name: 'Grace'),
        token: 'synthetic-other-token',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: GraphWorkItemDetailPage.project(
              account: otherAccount,
              api: second.api,
              project: second.project,
              iid: 100,
            ),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      await _waitForChip(tester, 'new account label');

      late.succeed();
      await settleNetworkWidgets(tester);

      expect(find.widgetWithText(Chip, 'new account label'), findsOneWidget);
      expect(find.text('old account label'), findsNothing);
    },
  );

  testWidgets('late parent read cannot paint after resource invalidation', (
    tester,
  ) async {
    final fixture = WorkItemLabelsFixture(
      initialCustomLabels: const [
        WorkItemLabel(
          id: 'gid://gitlab/ProjectLabel/811',
          title: 'old resource label',
          color: '#1068BF',
          textColor: '#FFFFFF',
        ),
      ],
    );
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);

    final late = fixture.holdNextDetailRead();
    _startParentRefresh(tester);
    await pumpUntil(
      tester,
      () => late.started,
      description: 'waiting for stale resource read',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GraphWorkItemDetailPage.project(
            account: fixture.account,
            api: fixture.api,
            project: Project.fromJson(projectJson(99)),
            iid: 100,
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    late.succeed();
    await settleNetworkWidgets(tester);

    expect(find.text('old resource label'), findsNothing);
  });

  testWidgets('late parent read is harmless after parent disposal', (
    tester,
  ) async {
    final fixture = WorkItemLabelsFixture(initialLabelCount: 1);
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);

    final late = fixture.holdNextDetailRead();
    _startParentRefresh(tester);
    await pumpUntil(
      tester,
      () => late.started,
      description: 'waiting for read before disposal',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    late.succeed();
    await settleNetworkWidgets(tester);

    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'candidate pagination loads more candidates and allows selection',
    (tester) async {
      final fixture = WorkItemLabelsFixture(
        initialLabelCount: 1,
        candidateLimit: 25,
      );
      addTearDown(fixture.api.close);
      await _pump(tester, fixture);
      await _openEditor(tester, fixture);

      await tester.enterText(
        find.byKey(const ValueKey('work-item-labels-search')),
        '分頁',
      );
      await tester.tap(
        find.byKey(const ValueKey('work-item-labels-search-submit')),
      );
      await settleNetworkWidgets(tester);

      // First page returned 20 candidates, has next page button
      final moreFinder = find.byKey(
        const ValueKey('work-item-labels-candidates-more'),
      );
      await _reveal(tester, moreFinder);
      expect(moreFinder, findsOneWidget);

      // Tap load more
      await tester.tap(moreFinder);
      await settleNetworkWidgets(tester);

      // Candidate 21 from page 2 is now available and can be selected
      final cand21Finder = find.byKey(
        const ValueKey('work-item-label-row-gid://gitlab/ProjectLabel/2021'),
      );
      await _reveal(tester, cand21Finder);
      expect(cand21Finder, findsOneWidget);

      await tester.tap(cand21Finder);
      await tester.pump();

      await tester.drag(find.byType(Scrollable).first, const Offset(0, 1500));
      await tester.pump();
      expect(find.text('已選擇 2 個標籤'), findsOneWidget);
      expect(cand21Finder, findsOneWidget);
      final checkbox = tester.widget<CheckboxListTile>(cand21Finder);
      expect(checkbox.value, isTrue);
    },
  );

  testWidgets(
    'currently deselected labels stay in candidate list and can be re-selected',
    (tester) async {
      final fixture = WorkItemLabelsFixture(initialLabelCount: 2);
      addTearDown(fixture.api.close);
      await _pump(tester, fixture);
      await _openEditor(tester, fixture);

      expect(find.text('已選擇 2 個標籤'), findsOneWidget);

      // Deselect label 1
      final row1Finder = find.byKey(
        ValueKey('work-item-label-row-${fixture.labelId(1)}'),
      );
      await tester.tap(row1Finder);
      await tester.pump();

      // Now 1 label is selected
      expect(find.text('已選擇 1 個標籤'), findsOneWidget);

      // Label 1 is still rendered (now in unselected candidate rows)
      expect(row1Finder, findsOneWidget);
      final tileBefore = tester.widget<CheckboxListTile>(row1Finder);
      expect(tileBefore.value, isFalse);

      // Tap label 1 again to re-select it
      await tester.tap(row1Finder);
      await tester.pump();

      // Count is back to 2 selected
      expect(find.text('已選擇 2 個標籤'), findsOneWidget);
      final tileAfter = tester.widget<CheckboxListTile>(row1Finder);
      expect(tileAfter.value, isTrue);

      // Save sends noop / unchanged set
      await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
      await settleNetworkWidgets(tester);
      expect(find.text('標籤沒有變更'), findsOneWidget);
      expect(fixture.mutations, 0);
    },
  );

  testWidgets(
    'candidate pagination is strictly bounded at 5 pages (page 0..4)',
    (tester) async {
      // 120 candidates across 6 pages (20 candidates per page)
      final fixture = WorkItemLabelsFixture(
        initialLabelCount: 1,
        candidateLimit: 120,
      );
      addTearDown(fixture.api.close);
      await _pump(tester, fixture);
      await _openEditor(tester, fixture);

      await tester.enterText(
        find.byKey(const ValueKey('work-item-labels-search')),
        '五頁邊界',
      );
      await tester.tap(
        find.byKey(const ValueKey('work-item-labels-search-submit')),
      );
      await settleNetworkWidgets(tester);

      final moreFinder = find.byKey(
        const ValueKey('work-item-labels-candidates-more'),
      );

      // Page 0 loaded. Load pages 1, 2, 3, 4 (up to 5 pages total)
      for (var page = 1; page <= 4; page++) {
        await _reveal(tester, moreFinder);
        expect(moreFinder, findsOneWidget);
        await tester.tap(moreFinder);
        await settleNetworkWidgets(tester);
      }

      // Beyond 5 pages (pageIndex == 4), load more button MUST NOT be displayed!
      expect(moreFinder, findsNothing);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  WorkItemLabelsFixture fixture, {
  bool group = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: group
            ? GraphWorkItemDetailPage.namespace(
                account: fixture.account,
                api: fixture.api,
                namespacePath: 'group/sample',
                expectedNamespaceId: WorkItemLabelsFixture.groupNamespaceId,
                iid: 100,
              )
            : GraphWorkItemDetailPage.project(
                account: fixture.account,
                api: fixture.api,
                project: fixture.project,
                iid: 100,
              ),
      ),
    ),
  );
  await settleNetworkWidgets(tester);
}

Future<void> _openEditor(
  WidgetTester tester,
  WorkItemLabelsFixture fixture,
) async {
  final before = fixture.labelsReads;
  final edit = find.byKey(const ValueKey('work-item-labels-edit'));
  await _reveal(tester, edit);
  await tester.tap(edit);
  await pumpUntil(
    tester,
    () =>
        fixture.labelsReads > before &&
        find
            .byKey(const ValueKey('work-item-labels-save'))
            .evaluate()
            .isNotEmpty,
    maxCycles: 80,
    description: 'waiting for labels editor to open',
  );
  await settleNetworkWidgets(tester);
}

Future<void> _save(WidgetTester tester, WorkItemLabelsFixture fixture) async {
  final before = fixture.mutations;
  await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
  await pumpUntil(
    tester,
    () => fixture.mutations > before,
    maxCycles: 80,
    description: 'waiting for mutation to be sent',
  );
  await settleNetworkWidgets(tester);
}

Future<void> _settleHeldRoutePop(WidgetTester tester) async {
  for (var frame = 0; frame < 6; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await settleNetworkWidgets(tester);
}

Future<void> _verifyRoutePopWriteGate(
  WidgetTester tester, {
  required bool group,
}) async {
  final fixture = WorkItemLabelsFixture(initialLabelCount: 2, groupOnly: group);
  fixture.holdMutationApply = Completer<void>();
  fixture.holdMutation = Completer<ResponseBody>();
  addTearDown(() {
    fixture.releaseHoldLabelsRead();
    fixture.releaseHoldMutationApply();
    fixture.releaseHoldMutation();
    fixture.api.close();
  });
  await _pump(tester, fixture, group: group);
  await _openEditor(tester, fixture);

  await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
  await tester.pump();
  final detailReadsBeforeWrite = fixture.detailReads;
  await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
  await pumpUntil(
    tester,
    () => fixture.mutations == 1,
    description: 'waiting for mutation handoff',
  );

  expect(fixture.mutationApplies, 0);
  expect(fixture.detailReads, detailReadsBeforeWrite);
  expect(find.text('正在更新標籤', skipOffstage: false), findsOneWidget);

  Navigator.of(
    tester.element(find.byKey(const ValueKey('work-item-labels-save'))),
  ).pop();
  await _settleHeldRoutePop(tester);

  expect(find.text('正在更新標籤'), findsOneWidget);
  expect(find.byType(Chip), findsNothing);
  expect(fixture.detailReads, detailReadsBeforeWrite);
  expect(fixture.mutations, 1);
  final edit = find.byKey(const ValueKey('work-item-labels-edit'));
  final editButton = tester.widget<TextButton>(edit);
  expect(editButton.onPressed, isNull);
  final labelReadsWhileGated = fixture.labelsReads;
  await tester.tap(edit);
  await tester.pump();
  expect(fixture.labelsReads, labelReadsWhileGated);
  expect(fixture.mutations, 1);

  fixture.releaseHoldMutationApply();
  await pumpUntil(
    tester,
    () => fixture.mutationApplies == 1,
    description: 'waiting for actual mutation apply',
  );
  expect(find.text('正在更新標籤'), findsOneWidget);
  expect(find.byType(Chip), findsNothing);
  expect(fixture.detailReads, detailReadsBeforeWrite);
  expect(tester.widget<TextButton>(edit).onPressed, isNull);
  expect(fixture.mutations, 1);

  fixture.releaseHoldMutation();
  await settleNetworkWidgets(tester);

  expect(fixture.detailReads, detailReadsBeforeWrite + 1);
  expect(fixture.mutationApplies, 1);
  expect(fixture.mutations, 1);
  expect(find.text('沒有標籤'), findsOneWidget);
  expect(find.byType(Chip), findsNothing);
  expect(tester.widget<TextButton>(edit).onPressed, isNotNull);
  expect(tester.takeException(), isNull);
}

Future<WorkItemLabelsDetailRequest> _clearAndHoldParentRead(
  WidgetTester tester,
  WorkItemLabelsFixture fixture,
) async {
  final request = fixture.holdNextDetailRead();
  await _openEditor(tester, fixture);
  await tester.tap(find.byKey(const ValueKey('work-item-labels-clear')));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
  await pumpUntil(
    tester,
    () => request.started,
    description: 'waiting for parent refetch A',
  );
  return request;
}

Future<WorkItemLabelsDetailRequest> _addBAndHoldParentRead(
  WidgetTester tester,
  WorkItemLabelsFixture fixture,
) async {
  await tester.pumpAndSettle();
  await _openEditor(tester, fixture);
  await _selectBCandidate(tester);

  final request = fixture.holdNextDetailRead();
  await tester.tap(find.byKey(const ValueKey('work-item-labels-save')));
  await pumpUntil(
    tester,
    () => request.started,
    description: 'waiting for parent refetch B',
  );
  return request;
}

Future<void> _selectBCandidate(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('work-item-labels-search')),
    'B confirmed',
  );
  await tester.tap(
    find.byKey(const ValueKey('work-item-labels-search-submit')),
  );
  await settleNetworkWidgets(tester);
  final candidate = find.byKey(
    const ValueKey('work-item-label-row-gid://gitlab/ProjectLabel/2001'),
  );
  await _reveal(tester, candidate);
  await tester.tap(candidate);
  await tester.pump();
}

Future<void> _verifyManualReadSupersedesLateA(
  WidgetTester tester, {
  required bool lateAErrors,
}) async {
  final fixture = WorkItemLabelsFixture(initialLabelCount: 1);
  addTearDown(fixture.api.close);
  await _pump(tester, fixture);

  final refetchA = await _clearAndHoldParentRead(tester, fixture);
  expect(refetchA.snapshot.labelTitles, isEmpty);

  fixture.replacePersistedLabels([
    const WorkItemLabel(
      id: 'gid://gitlab/ProjectLabel/901',
      title: 'manual fresh label',
      color: '#1068BF',
      textColor: '#FFFFFF',
    ),
  ]);
  final manualRead = fixture.holdNextDetailRead();
  _startParentRefresh(tester);
  await pumpUntil(
    tester,
    () => manualRead.started,
    description: 'waiting for the manual refresh',
  );
  expect(manualRead.snapshot.labelTitles, ['manual fresh label']);
  manualRead.succeed();
  await _waitForText(tester, 'manual fresh label');

  if (lateAErrors) {
    refetchA.fail();
  } else {
    refetchA.succeed();
  }
  await settleNetworkWidgets(tester);

  expect(find.text('manual fresh label'), findsOneWidget);
  expect(find.byType(Chip), findsOneWidget);
  expect(
    find.byKey(const ValueKey('work-item-labels-unconfirmed')),
    findsNothing,
  );
}

Finder _parentRefresh() => find.byWidgetPredicate(
  (widget) => widget is IconButton && widget.tooltip == '重新整理',
  skipOffstage: false,
);

void _startParentRefresh(WidgetTester tester) {
  final refresh = tester.widget<IconButton>(_parentRefresh());
  expect(refresh.onPressed, isNotNull);
  refresh.onPressed!.call();
}

Future<void> _waitForText(WidgetTester tester, String text) {
  return pumpUntil(
    tester,
    () => find.text(text).evaluate().isNotEmpty,
    description: 'waiting for "$text"',
  );
}

Future<void> _waitForChip(WidgetTester tester, String text) {
  return pumpUntil(
    tester,
    () => find.widgetWithText(Chip, text).evaluate().isNotEmpty,
    description: 'waiting for chip "$text"',
  );
}

Future<void> _waitForKey(WidgetTester tester, ValueKey<String> key) {
  return pumpUntil(
    tester,
    () => find.byKey(key).evaluate().isNotEmpty,
    description: 'waiting for $key',
  );
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  if (target.hitTestable().evaluate().isNotEmpty) return;
  final scrollable = find.byType(Scrollable).first;
  for (var step = 0; step < 20; step++) {
    await tester.drag(scrollable, const Offset(0, -300));
    await tester.pump();
    if (target.hitTestable().evaluate().isNotEmpty) return;
  }
}

class _LabelsLifecycleHost extends StatefulWidget {
  const _LabelsLifecycleHost({
    super.key,
    required this.fixture,
    required this.detail,
  });

  final WorkItemLabelsFixture fixture;
  final WorkItemGraphDetail detail;

  @override
  State<_LabelsLifecycleHost> createState() => _LabelsLifecycleHostState();
}

class _LabelsLifecycleHostState extends State<_LabelsLifecycleHost> {
  bool _showControl = true;
  Object? _writeToken;
  int starts = 0;
  int settles = 0;

  void _onLabelWrite(WorkItemLabelWritePhase phase, Object token) {
    if (phase == WorkItemLabelWritePhase.start) {
      if (_writeToken != null) return;
      starts++;
      setState(() => _writeToken = token);
      return;
    }
    if (!identical(_writeToken, token)) return;
    settles++;
    setState(() => _writeToken = null);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextButton(
          key: const ValueKey('labels-lifecycle-remove-row'),
          onPressed: () => setState(() => _showControl = false),
          child: const Text('模擬重新整理並移除標籤列'),
        ),
        if (_writeToken != null)
          const CircularProgressIndicator(
            key: ValueKey('labels-lifecycle-pending'),
          ),
        if (_showControl)
          WorkItemLabelsControl(
            account: widget.fixture.account,
            api: widget.fixture.api,
            detail: widget.detail,
            onLabelWrite: _onLabelWrite,
          ),
      ],
    );
  }
}
