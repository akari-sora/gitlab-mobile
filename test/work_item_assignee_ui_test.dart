import 'dart:async';
import 'dart:ui' show CheckedState;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/work_item_assignee_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('does not read assignees until the edit action is opened', (
    tester,
  ) async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    expect(find.text('變更負責人'), findsOneWidget);
    expect(fixture.queries('MobileWorkItemAssignees'), 0);
    expect(fixture.projectSearches, 0);
    expect(fixture.groupSearches, 0);
  });

  testWidgets(
    'a 101 person set can remove someone and still write person 101',
    (tester) async {
      final fixture = WorkItemAssigneeFixture(userCount: 101);
      addTearDown(fixture.api.close);
      await _pump(tester, fixture);
      await _openEditor(tester, fixture);
      await _reveal(
        tester,
        find.byKey(ValueKey('work-item-assignee-row-${fixture.userId(101)}')),
      );
      expect(
        find.byKey(ValueKey('work-item-assignee-row-${fixture.userId(101)}')),
        findsOneWidget,
      );
      final first = find.byKey(
        ValueKey('work-item-assignee-row-${fixture.userId(1)}'),
      );
      for (
        var step = 0;
        step < 40 && first.hitTestable().evaluate().isEmpty;
        step++
      ) {
        await tester.drag(find.byType(Scrollable).last, const Offset(0, 500));
        await tester.pump();
      }
      expect(first.hitTestable(), findsWidgets);
      await tester.tap(
        find.byKey(ValueKey('work-item-assignee-row-${fixture.userId(1)}')),
      );
      await tester.pump();
      await _save(tester, fixture);
      expect(fixture.mutations, 1);
      expect(fixture.lastAssigneeIds, isNot(contains(fixture.userId(1))));
      expect(fixture.lastAssigneeIds, contains(fixture.userId(101)));
      expect(fixture.lastAssigneeIds, hasLength(100));
    },
  );

  testWidgets('two thousand people stay out of the parent chips', (
    tester,
  ) async {
    final fixture = WorkItemAssigneeFixture(userCount: 2000);
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    expect(find.byType(Chip), findsNWidgets(20));
    await _openEditor(tester, fixture);
    expect(find.byType(Chip), findsNWidgets(20));
    expect(find.byType(ListTile).evaluate().length, lessThanOrEqualTo(40));
    expect(find.text('人員2000'), findsNothing);
  });

  testWidgets('project and group searches stay inside their own container', (
    tester,
  ) async {
    final project = WorkItemAssigneeFixture();
    addTearDown(project.api.close);
    await _pump(tester, project);
    await _openEditor(tester, project);
    await _search(tester, '候選');
    expect(project.projectSearches, 1);
    expect(project.groupSearches, 0);

    final group = WorkItemAssigneeFixture(groupOnly: true);
    addTearDown(group.api.close);
    await _pump(tester, group, group: true);
    await _openEditor(tester, group);
    await _search(tester, '候選');
    expect(group.groupSearches, 1);
    expect(group.projectSearches, 0);
  });

  testWidgets(
    'clear, an unchanged save, and one assignee each send one write',
    (tester) async {
      final clear = WorkItemAssigneeFixture();
      addTearDown(clear.api.close);
      await _pump(tester, clear);
      await _openEditor(tester, clear);
      await tester.tap(find.byKey(const ValueKey('work-item-assignees-clear')));
      await tester.pump();
      await _save(tester, clear);
      expect(clear.mutations, 1);
      expect(clear.lastAssigneeIds, isEmpty);

      final same = WorkItemAssigneeFixture();
      addTearDown(same.api.close);
      await _pump(tester, same);
      await _openEditor(tester, same);
      await tester.tap(find.byKey(const ValueKey('work-item-assignees-save')));
      await settleNetworkWidgets(tester);
      expect(same.mutations, 0);
      expect(same.lastAssigneeIds, isEmpty);

      final single = WorkItemAssigneeFixture(allowsMultiple: false);
      addTearDown(single.api.close);
      final semantics = tester.ensureSemantics();
      await _pump(tester, single);
      await _openEditor(tester, single);
      final row = find.byKey(
        ValueKey('work-item-assignee-row-${single.userId(2)}'),
      );
      final node = tester.getSemantics(row);
      expect(node.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
      expect(node.flagsCollection.isChecked, CheckedState.isTrue);
      expect(find.byIcon(Icons.radio_button_checked), findsWidgets);
      expect(find.byIcon(Icons.check_box), findsNothing);
      await _reveal(
        tester,
        find.byKey(ValueKey('work-item-assignee-row-${single.userId(1)}')),
      );
      await tester.tap(
        find.byKey(ValueKey('work-item-assignee-row-${single.userId(1)}')),
      );
      await tester.pump();
      await _save(tester, single);
      expect(single.mutations, 1);
      expect(single.lastAssigneeIds, [single.userId(1)]);
      semantics.dispose();
    },
  );

  testWidgets('a failed candidate search can still clear the known set', (
    tester,
  ) async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);
    await _search(tester, '失敗');
    expect(find.text('搜尋沒有完成。目前名單已經完整，仍可清除全部或維持不變。'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-clear')));
    await tester.pump();
    await _save(tester, fixture);
    expect(fixture.mutations, 1);
    expect(fixture.lastAssigneeIds, isEmpty);
  });

  testWidgets('twenty candidates say the array stopped and do not page', (
    tester,
  ) async {
    final fixture = WorkItemAssigneeFixture(candidateLimit: 20);
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);
    await tester.enterText(
      find.byKey(const ValueKey('work-item-assignees-search')),
      '候',
    );
    await tester.pump();
    expect(fixture.projectSearches, 0);
    await _search(tester, '候選');
    expect(fixture.projectSearches, 1);
    expect(find.text('搜尋最多顯示 20 人，請縮小關鍵字。'), findsOneWidget);
    expect(find.text('載入更多'), findsNothing);
  });

  testWidgets('a late search reply is dropped after the query changes', (
    tester,
  ) async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);
    final first = Completer<ResponseBody>();
    fixture.heldSearches['甲'] = first;
    await tester.enterText(
      find.byKey(const ValueKey('work-item-assignees-search')),
      '甲',
    );
    await tester.tap(
      find.byKey(const ValueKey('work-item-assignees-search-submit')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('work-item-assignees-search')),
      '候選',
    );
    await tester.pump();
    await _reveal(
      tester,
      find.byKey(const ValueKey('work-item-assignees-search-submit')),
    );
    await tester.tap(
      find.byKey(const ValueKey('work-item-assignees-search-submit')),
    );
    await pumpUntil(tester, () => fixture.projectSearches == 2);
    first.complete(
      jsonResponse({
        'data': {
          'currentUser': {'id': fixture.userId(7)},
          'project': {
            'id': 'gid://gitlab/Project/42',
            'fullPath': fixture.project.path,
            'autocompleteUsers': [
              {'id': fixture.userId(50), 'name': '過期候選', 'username': 'stale'},
            ],
          },
        },
      }),
    );
    await settleNetworkWidgets(tester);
    expect(find.textContaining('過期候選'), findsNothing);
  });

  testWidgets('editing the search text ends the in-flight search', (
    tester,
  ) async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);
    final first = Completer<ResponseBody>();
    final second = Completer<ResponseBody>();
    fixture.heldSearches['甲'] = first;
    fixture.heldSearches['候'] = second;
    await tester.enterText(
      find.byKey(const ValueKey('work-item-assignees-search')),
      '甲',
    );
    await tester.tap(
      find.byKey(const ValueKey('work-item-assignees-search-submit')),
    );
    await pumpUntil(tester, () => fixture.projectSearches == 1);
    expect(find.text('搜尋中…'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('work-item-assignees-search')),
      '候',
    );
    await tester.pump();
    expect(fixture.projectSearches, 1);
    expect(find.text('搜尋中…'), findsNothing);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('work-item-assignees-search-submit')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(
      find.byKey(const ValueKey('work-item-assignees-search-submit')),
    );
    await pumpUntil(tester, () => fixture.projectSearches == 2);
    expect(find.text('搜尋中…'), findsOneWidget);
    first.complete(_staleCandidate(fixture));
    await settleNetworkWidgets(tester);
    expect(find.text('搜尋中…'), findsOneWidget);
    expect(find.textContaining('過期候選'), findsNothing);
    second.complete(_candidatePage(fixture, name: '候選1', username: 'cand1'));
    await settleNetworkWidgets(tester);
    expect(find.text('搜尋中…'), findsNothing);
    expect(find.textContaining('候選1'), findsWidgets);
    expect(find.textContaining('過期候選'), findsNothing);
    expect(find.textContaining('人員1'), findsWidgets);
  });

  testWidgets('a settled write stays unconfirmed until the fresh read', (
    tester,
  ) async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);
    await _reveal(
      tester,
      find.byKey(ValueKey('work-item-assignee-row-${fixture.userId(1)}')),
    );
    await tester.tap(
      find.byKey(ValueKey('work-item-assignee-row-${fixture.userId(1)}')),
    );
    await tester.pump();
    fixture.holdParentAssigneeRead = Completer<ResponseBody>();
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-save')));
    await pumpUntil(
      tester,
      () =>
          fixture.mutations == 1 &&
          fixture.assigneeReads >= 3 &&
          find.text('更新中').evaluate().isNotEmpty &&
          find
              .byKey(const ValueKey('work-item-assignees-save'))
              .evaluate()
              .isEmpty,
    );
    expect(find.text('尚未指派'), findsNothing);
    expect(find.byType(Chip), findsNothing);
    expect(
      find.byKey(const ValueKey('work-item-assignee-count')),
      findsNothing,
    );
    fixture.releaseParentAssigneeRead();
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('work-item-assignee-count'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.text('尚未指派'), findsNothing);
    expect(find.text('共 1 位負責人。'), findsOneWidget);
    expect(
      find.byKey(ValueKey('work-item-assignee-preview-${fixture.userId(1)}')),
      findsNothing,
    );
    expect(
      find.byKey(ValueKey('work-item-assignee-preview-${fixture.userId(2)}')),
      findsOneWidget,
    );

    final failed = WorkItemAssigneeFixture();
    addTearDown(failed.api.close);
    await _pump(tester, failed);
    await _openEditor(tester, failed);
    await tester.tap(
      find.byKey(ValueKey('work-item-assignee-row-${failed.userId(1)}')),
    );
    await tester.pump();
    final blocked = Completer<ResponseBody>();
    failed.holdParentAssigneeRead = blocked;
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-save')));
    await pumpUntil(
      tester,
      () =>
          failed.mutations == 1 &&
          find.text('更新中').evaluate().isNotEmpty &&
          find
              .byKey(const ValueKey('work-item-assignees-save'))
              .evaluate()
              .isEmpty,
    );
    blocked.complete(
      jsonResponse({
        'errors': [
          const {'message': 'read failed'},
        ],
      }, status: 500),
    );
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('work-item-assignees-unconfirmed'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.text('尚未指派'), findsNothing);
    expect(find.byType(Chip), findsNothing);
    expect(find.text('更新中'), findsNothing);
  });

  testWidgets('missing permission and a missing widget cannot write', (
    tester,
  ) async {
    final denied = WorkItemAssigneeFixture(canWrite: false);
    addTearDown(denied.api.close);
    await _pump(tester, denied);
    await _openEditor(tester, denied);
    expect(find.text('目前帳號不能變更負責人。可以查看目前名單，不能儲存。'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('work-item-assignees-save')),
          )
          .onPressed,
      isNull,
    );
    expect(denied.mutations, 0);

    final missing = WorkItemAssigneeFixture(widgetPresent: false);
    addTearDown(missing.api.close);
    await _pump(tester, missing);
    expect(
      find.byKey(const ValueKey('work-item-assignees-edit')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('work-item-assignees-save')),
      findsNothing,
    );
    expect(missing.assigneeReads, 0);
    expect(missing.mutations, 0);
  });

  testWidgets('a changed revision before send does not mutate', (tester) async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);
    fixture.conflictOnNextRead = true;
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-save')));
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('work-item-assignees-save-error'))
          .evaluate()
          .isNotEmpty,
    );
    expect(fixture.mutations, 0);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('work-item-assignees-save')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('a lost acknowledgement locks the editor and hides stale chips', (
    tester,
  ) async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    expect(find.byType(Chip), findsNWidgets(2));
    await _openEditor(tester, fixture);
    fixture.failReadsAfterMutation = true;
    fixture.holdMutation = Completer<ResponseBody>();
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-clear')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-save')));
    await pumpUntil(tester, () => fixture.mutations == 1);
    expect(find.text('更新中'), findsOneWidget);
    expect(find.byType(Chip), findsNothing);
    fixture.holdMutation!.complete(
      jsonResponse({
        'errors': [
          const {'message': 'lost'},
        ],
      }, status: 400),
    );
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('work-item-assignees-unconfirmed'))
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byType(Chip), findsNothing);
    expect(fixture.mutations, 1);
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-save')));
    await settleNetworkWidgets(tester);
    expect(fixture.mutations, 1);
  });

  testWidgets('leaving and returning does not accept the earlier save', (
    tester,
  ) async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    final current = ValueNotifier<bool>(true);
    final owner = ChangeNotifier();
    addTearDown(current.dispose);
    addTearDown(owner.dispose);
    await _pump(
      tester,
      fixture,
      isCurrent: () => current.value,
      ownerChanges: owner,
    );
    await _openEditor(tester, fixture);
    fixture.holdMutation = Completer<ResponseBody>();
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-clear')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-save')));
    await pumpUntil(tester, () => fixture.mutations == 1);
    current.value = false;
    owner.notifyListeners();
    await settleNetworkWidgets(tester);
    expect(find.text('帳號已切換，工作項目頁面已關閉。'), findsOneWidget);
    current.value = true;
    owner.notifyListeners();
    await settleNetworkWidgets(tester);
    fixture.holdMutation!.complete(jsonResponse(_lost()));
    await settleNetworkWidgets(tester);
    expect(find.text('帳號已切換，工作項目頁面已關閉。'), findsOneWidget);
    expect(find.text('目前沒有負責人。'), findsNothing);
    expect(fixture.mutations, 1);
  });

  testWidgets('an older settle does not clear the write that replaced it', (
    tester,
  ) async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    final firstApi = fixture.api;
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);
    final firstAck = Completer<ResponseBody>();
    fixture.holdMutation = firstAck;
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-clear')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-save')));
    await pumpUntil(tester, () => fixture.mutations == 1);

    final replacement = testApi(fixture.adapter);
    addTearDown(replacement.close);
    fixture.api = replacement;
    await _pump(tester, fixture);
    await pumpUntil(tester, () => find.text('變更負責人').evaluate().isNotEmpty);
    await _openEditor(tester, fixture);
    final secondAck = Completer<ResponseBody>();
    fixture.holdMutation = secondAck;
    await _search(tester, '候選');
    await _reveal(
      tester,
      find.byKey(ValueKey('work-item-assignee-row-${fixture.userId(1001)}')),
    );
    await tester.tap(
      find.byKey(ValueKey('work-item-assignee-row-${fixture.userId(1001)}')),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-save')));
    await pumpUntil(tester, () => fixture.mutations == 2);
    expect(find.text('更新中', skipOffstage: false), findsOneWidget);

    firstAck.complete(
      jsonResponse(<String, Object?>{'data': <String, Object?>{}}),
    );
    await settleNetworkWidgets(tester);
    expect(find.text('更新中', skipOffstage: false), findsOneWidget);
    expect(find.byType(Chip, skipOffstage: false), findsNothing);

    fixture.failReadsAfterMutation = true;
    secondAck.complete(jsonResponse(_lost()));
    await pumpUntil(
      tester,
      () => find
          .byKey(
            const ValueKey('work-item-assignees-unconfirmed'),
            skipOffstage: false,
          )
          .evaluate()
          .isNotEmpty,
    );
    expect(fixture.mutations, 2);
    expect(firstApi == fixture.api, isFalse);
  });

  testWidgets('a revision refresh keeps the pending write', (tester) async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);
    await _reveal(
      tester,
      find.byKey(ValueKey('work-item-assignee-row-${fixture.userId(1)}')),
    );
    await tester.tap(
      find.byKey(ValueKey('work-item-assignee-row-${fixture.userId(1)}')),
    );
    await tester.pump();
    fixture.holdMutation = Completer<ResponseBody>();
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-save')));
    await pumpUntil(tester, () => fixture.mutations == 1);
    fixture.updatedAt = '2026-10-04T04:05:06Z';
    final refresh = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.refresh).last,
    );
    refresh.onPressed!.call();
    await pumpUntil(
      tester,
      () => fixture.queries('MobileProjectWorkItem') >= 2,
    );
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('work-item-assignees-save'))
          .evaluate()
          .isEmpty,
    );
    expect(find.text('更新中', skipOffstage: false), findsOneWidget);
    expect(find.byType(Chip, skipOffstage: false), findsNothing);
    expect(find.text('尚未指派', skipOffstage: false), findsNothing);
    fixture.holdParentAssigneeRead = Completer<ResponseBody>();
    fixture.holdMutation!.complete(jsonResponse(fixture.mutationAck()));
    await pumpUntil(
      tester,
      () =>
          fixture.mutations == 1 &&
          find.text('更新中').evaluate().isNotEmpty &&
          find
              .byKey(const ValueKey('work-item-assignees-save'))
              .evaluate()
              .isEmpty,
    );
    expect(find.text('尚未指派'), findsNothing);
    expect(find.byType(Chip), findsNothing);
    fixture.releaseParentAssigneeRead();
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('work-item-assignee-count'))
          .evaluate()
          .isNotEmpty,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('work-item-assignee-count')))
          .data,
      '共 1 位負責人。',
    );
    expect(
      find.byKey(ValueKey('work-item-assignee-preview-${fixture.userId(2)}')),
      findsOneWidget,
    );
    expect(fixture.mutations, 1);
  });

  testWidgets('a revision refresh can open the editor again', (tester) async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);
    await _refreshRevision(tester, fixture);
    expect(
      find.byKey(const ValueKey('work-item-assignees-save')),
      findsNothing,
    );
    expect(find.text('變更負責人'), findsOneWidget);
    final reads = fixture.assigneeReads;
    await _openEditor(tester, fixture);
    expect(fixture.assigneeReads, greaterThan(reads));
    expect(
      find.byKey(const ValueKey('work-item-assignees-save')),
      findsOneWidget,
    );
  });

  testWidgets(
    'an older assignee read cannot clear or open over the next attempt',
    (tester) async {
      final fixture = WorkItemAssigneeFixture();
      final first = Completer<void>();
      final second = Completer<void>();
      var assigneeCalls = 0;
      final original = fixture.api;
      addTearDown(original.close);
      final gateway = FakeAdapter((request) async {
        final data = request.data;
        final query = data is Map ? '${data['query']}' : '';
        if (query.contains('MobileWorkItemAssignees')) {
          assigneeCalls++;
          if (assigneeCalls == 1) await first.future;
          if (assigneeCalls == 2) await second.future;
        }
        return fixture.adapter.respond(request);
      });
      fixture.api = testApi(gateway);
      addTearDown(fixture.api.close);
      await _pump(tester, fixture);
      await tester.tap(find.byKey(const ValueKey('work-item-assignees-edit')));
      await pumpUntil(tester, () => assigneeCalls == 1);
      expect(find.text('讀取負責人…'), findsOneWidget);
      fixture.updatedAt = '2026-10-04T04:05:06Z';
      final refresh = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.refresh).last,
      );
      final detailReads = gateway.requests
          .where(
            (request) => '${(request.data as Map)['query']}'.contains(
              'MobileProjectWorkItem',
            ),
          )
          .length;
      refresh.onPressed!.call();
      await pumpUntil(
        tester,
        () =>
            gateway.requests
                .where(
                  (request) => '${(request.data as Map)['query']}'.contains(
                    'MobileProjectWorkItem',
                  ),
                )
                .length >
            detailReads,
      );
      await pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('work-item-assignees-save'))
            .evaluate()
            .isEmpty,
      );
      expect(find.text('變更負責人'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('work-item-assignees-save')),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('work-item-assignees-edit')));
      await pumpUntil(tester, () => assigneeCalls == 2);
      expect(find.text('讀取負責人…'), findsOneWidget);
      first.complete();
      await settleNetworkWidgets(tester);
      expect(find.text('讀取負責人…'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('work-item-assignees-save')),
        findsNothing,
      );
      second.complete();
      await pumpUntil(
        tester,
        () => find
            .byKey(const ValueKey('work-item-assignees-save'))
            .evaluate()
            .isNotEmpty,
      );
      expect(fixture.assigneeReads, 2);
    },
  );

  testWidgets(
    'account away and a resource change do not leave the edit button busy',
    (tester) async {
      final away = WorkItemAssigneeFixture();
      final held = Completer<void>();
      final original = away.api;
      addTearDown(original.close);
      away.api = testApi(
        FakeAdapter((request) async {
          final data = request.data;
          final query = data is Map ? '${data['query']}' : '';
          if (query.contains('MobileWorkItemAssignees')) await held.future;
          return away.adapter.respond(request);
        }),
      );
      addTearDown(away.api.close);
      final current = ValueNotifier<bool>(true);
      final owner = ChangeNotifier();
      addTearDown(current.dispose);
      addTearDown(owner.dispose);
      await _pump(
        tester,
        away,
        isCurrent: () => current.value,
        ownerChanges: owner,
      );
      await tester.tap(find.byKey(const ValueKey('work-item-assignees-edit')));
      await pumpUntil(tester, () => find.text('讀取負責人…').evaluate().isNotEmpty);
      current.value = false;
      owner.notifyListeners();
      await settleNetworkWidgets(tester);
      expect(find.text('帳號已切換，工作項目頁面已關閉。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      held.complete();
      await settleNetworkWidgets(tester);
      expect(tester.takeException(), isNull);
      current.value = true;
      owner.notifyListeners();
      await settleNetworkWidgets(tester);
      expect(find.text('讀取負責人…'), findsNothing);

      final changed = WorkItemAssigneeFixture();
      final heldRead = Completer<void>();
      final originalChanged = changed.api;
      addTearDown(originalChanged.close);
      final gateway = FakeAdapter((request) async {
        final data = request.data;
        final query = data is Map ? '${data['query']}' : '';
        if (query.contains('MobileWorkItemAssignees')) await heldRead.future;
        return changed.adapter.respond(request);
      });
      changed.api = testApi(gateway);
      addTearDown(changed.api.close);
      await _pump(tester, changed);
      await tester.tap(find.byKey(const ValueKey('work-item-assignees-edit')));
      await pumpUntil(tester, () => find.text('讀取負責人…').evaluate().isNotEmpty);
      changed.updatedAt = '2026-10-04T04:05:06Z';
      final refresh = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.refresh).last,
      );
      final detailReads = gateway.requests
          .where(
            (request) => '${(request.data as Map)['query']}'.contains(
              'MobileProjectWorkItem',
            ),
          )
          .length;
      refresh.onPressed!.call();
      await pumpUntil(
        tester,
        () =>
            gateway.requests
                .where(
                  (request) => '${(request.data as Map)['query']}'.contains(
                    'MobileProjectWorkItem',
                  ),
                )
                .length >
            detailReads,
      );
      expect(find.text('變更負責人'), findsOneWidget);
      expect(find.text('讀取負責人…'), findsNothing);
      heldRead.complete();
      await settleNetworkWidgets(tester);
      expect(find.text('讀取負責人…'), findsNothing);
      expect(
        find.byKey(const ValueKey('work-item-assignees-save')),
        findsNothing,
      );
      await _openEditor(tester, changed);
    },
  );

  testWidgets(
    'project and group delayed APPLY survive back and block reads and B',
    (tester) async {
      for (final group in [false, true]) {
        final fixture = WorkItemAssigneeFixture(groupOnly: group);
        addTearDown(fixture.api.close);
        final apply = Completer<void>();
        final ack = Completer<ResponseBody>();
        fixture.holdMutationApply = apply;
        fixture.holdMutation = ack;
        fixture.holdParentAssigneeRead = Completer<ResponseBody>();
        addTearDown(() {
          if (!apply.isCompleted) apply.complete();
          if (!ack.isCompleted) {
            ack.complete(jsonResponse(fixture.mutationAck()));
          }
          fixture.releaseParentAssigneeRead();
        });
        await _pump(tester, fixture, group: group);
        await _openEditor(tester, fixture);
        await tester.tap(
          find.byKey(const ValueKey('work-item-assignees-clear')),
        );
        await tester.pump();
        await tester.tap(
          find.byKey(const ValueKey('work-item-assignees-save')),
        );
        await pumpUntil(tester, () => fixture.mutations == 1);
        final readsAtHandoff = fixture.assigneeReads;

        await tester.pageBack();
        await tester.pump();
        expect(find.text('更新中'), findsOneWidget);
        final edit = tester.widget<TextButton>(
          find.byKey(const ValueKey('work-item-assignees-edit')),
        );
        expect(edit.onPressed, isNull);
        expect(fixture.assigneeReads, readsAtHandoff);

        final detailReads = fixture.queries(
          group ? 'MobileNamespaceWorkItem' : 'MobileProjectWorkItem',
        );
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.refresh).last,
            )
            .onPressed!
            .call();
        await pumpUntil(
          tester,
          () =>
              fixture.queries(
                group ? 'MobileNamespaceWorkItem' : 'MobileProjectWorkItem',
              ) >
              detailReads,
        );
        expect(find.text('更新中'), findsOneWidget);
        expect(fixture.assigneeReads, readsAtHandoff);
        expect(fixture.mutations, 1);

        apply.complete();
        await tester.pump();
        expect(find.text('更新中'), findsOneWidget);
        expect(fixture.assigneeReads, readsAtHandoff);
        expect(fixture.mutations, 1);

        ack.complete(jsonResponse(fixture.mutationAck()));
        await pumpUntil(
          tester,
          () => fixture.assigneeReads == readsAtHandoff + 2,
        );
        expect(find.text('更新中'), findsOneWidget);
        expect(fixture.mutations, 1);

        fixture.releaseParentAssigneeRead();
        await pumpUntil(
          tester,
          () => find.text('目前沒有負責人。').evaluate().isNotEmpty,
        );
        expect(fixture.assigneeReads, readsAtHandoff + 2);
        expect(fixture.mutations, 1);
      }
    },
  );

  testWidgets('assignee row disposal forwards one terminal after APPLY', (
    tester,
  ) async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    final apply = Completer<void>();
    final ack = Completer<ResponseBody>();
    fixture.holdMutationApply = apply;
    fixture.holdMutation = ack;
    fixture.holdParentAssigneeRead = Completer<ResponseBody>();
    addTearDown(() {
      if (!apply.isCompleted) apply.complete();
      if (!ack.isCompleted) ack.complete(jsonResponse(fixture.mutationAck()));
      fixture.releaseParentAssigneeRead();
    });
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-clear')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-save')));
    await pumpUntil(tester, () => fixture.mutations == 1);
    final readsAtHandoff = fixture.assigneeReads;

    fixture.widgetPresent = false;
    fixture.updatedAt = '2026-10-04T04:05:06Z';
    tester
        .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.refresh).last)
        .onPressed!
        .call();
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('work-item-assignees-edit'))
          .evaluate()
          .isEmpty,
    );
    expect(fixture.assigneeReads, readsAtHandoff);
    fixture.widgetPresent = true;

    apply.complete();
    await tester.pump();
    expect(fixture.assigneeReads, readsAtHandoff);
    ack.complete(jsonResponse(fixture.mutationAck()));
    await pumpUntil(tester, () => fixture.assigneeReads == readsAtHandoff + 2);
    expect(fixture.mutations, 1);

    fixture.releaseParentAssigneeRead();
    await settleNetworkWidgets(tester);
    expect(fixture.assigneeReads, readsAtHandoff + 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a fully disposed assignee parent ignores the old terminal', (
    tester,
  ) async {
    final fixture = WorkItemAssigneeFixture();
    addTearDown(fixture.api.close);
    final apply = Completer<void>();
    final ack = Completer<ResponseBody>();
    fixture.holdMutationApply = apply;
    fixture.holdMutation = ack;
    addTearDown(() {
      if (!apply.isCompleted) apply.complete();
      if (!ack.isCompleted) ack.complete(jsonResponse(fixture.mutationAck()));
    });
    await _pump(tester, fixture);
    await _openEditor(tester, fixture);
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-clear')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-assignees-save')));
    await pumpUntil(tester, () => fixture.mutations == 1);
    final readsAtHandoff = fixture.assigneeReads;

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    apply.complete();
    await tester.pump();
    ack.complete(jsonResponse(fixture.mutationAck()));
    await settleNetworkWidgets(tester);

    expect(fixture.mutations, 1);
    expect(fixture.assigneeReads, readsAtHandoff);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save stays above the keyboard at 320 dp and double text', (
    tester,
  ) async {
    final fixture = WorkItemAssigneeFixture(allowsMultiple: true);
    addTearDown(fixture.api.close);
    await _pump(tester, fixture, textScale: 2, width: 320, height: 640);
    await _openEditor(tester, fixture);
    tester.view.viewInsets = const FakeViewPadding(bottom: 240);
    await tester.pump();
    final save = tester.getRect(
      find.byKey(const ValueKey('work-item-assignees-save')),
    );
    final search = tester.getRect(
      find.byKey(const ValueKey('work-item-assignees-search')),
    );
    expect(save.height, greaterThanOrEqualTo(48));
    expect(save.bottom, lessThanOrEqualTo(640 - 240));
    expect(search.top, greaterThanOrEqualTo(0));
    expect(search.bottom, lessThan(save.top));
    await _reveal(
      tester,
      find.byKey(ValueKey('work-item-assignee-row-${fixture.userId(1)}')),
    );
    final semantics = tester.ensureSemantics();
    final box = tester.getSemantics(
      find.byKey(ValueKey('work-item-assignee-row-${fixture.userId(1)}')),
    );
    expect(box.flagsCollection.isChecked, CheckedState.isTrue);
    expect(box.flagsCollection.isInMutuallyExclusiveGroup, isFalse);
    expect(find.byIcon(Icons.check_box), findsWidgets);
    expect(find.byIcon(Icons.radio_button_checked), findsNothing);
    semantics.dispose();
  });
}

Future<void> _pump(
  WidgetTester tester,
  WorkItemAssigneeFixture fixture, {
  bool group = false,
  bool Function()? isCurrent,
  Listenable? ownerChanges,
  double textScale = 1,
  double width = 800,
  double height = 900,
}) async {
  await tester.binding.setSurfaceSize(Size(width, height));
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(textScale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: group
          ? GraphWorkItemDetailPage.namespace(
              account: fixture.account,
              api: fixture.api,
              namespacePath: 'group/sample',
              expectedNamespaceId: WorkItemAssigneeFixture.groupNamespaceId,
              iid: 31,
              isCurrent: isCurrent,
              ownerChanges: ownerChanges,
            )
          : GraphWorkItemDetailPage.project(
              account: fixture.account,
              api: fixture.api,
              project: fixture.project,
              iid: 31,
              isCurrent: isCurrent,
              ownerChanges: ownerChanges,
            ),
    ),
  );
  await pumpUntil(tester, () => find.text('合成工作項目').evaluate().isNotEmpty);
  await settleNetworkWidgets(tester);
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isNotEmpty) {
    await tester.ensureVisible(finder);
    await tester.pump();
    if (finder.hitTestable().evaluate().isNotEmpty) return;
  }
  for (var step = 0; step < 50; step++) {
    if (finder.hitTestable().evaluate().isNotEmpty) return;
    final scrollables = find.byType(Scrollable);
    if (scrollables.evaluate().isEmpty) break;
    await tester.drag(scrollables.last, const Offset(0, -350));
    await tester.pump();
  }
  expect(finder.hitTestable(), findsWidgets);
}

Future<void> _refreshRevision(
  WidgetTester tester,
  WorkItemAssigneeFixture fixture,
) async {
  fixture.updatedAt = '2026-10-04T04:05:06Z';
  final refresh = tester.widget<IconButton>(
    find.widgetWithIcon(IconButton, Icons.refresh).last,
  );
  refresh.onPressed!.call();
  await pumpUntil(tester, () => fixture.queries('MobileProjectWorkItem') >= 2);
  await pumpUntil(
    tester,
    () => find
        .byKey(const ValueKey('work-item-assignees-save'))
        .evaluate()
        .isEmpty,
  );
}

Future<void> _openEditor(
  WidgetTester tester,
  WorkItemAssigneeFixture fixture,
) async {
  final before = fixture.assigneeReads;
  final edit = find.byKey(const ValueKey('work-item-assignees-edit'));
  await _reveal(tester, edit);
  await tester.tap(edit);
  await pumpUntil(
    tester,
    () =>
        fixture.assigneeReads > before &&
        find
            .byKey(const ValueKey('work-item-assignees-save'))
            .evaluate()
            .isNotEmpty,
    maxCycles: 80,
  );
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(
    find.byKey(const ValueKey('work-item-assignees-search')),
    query,
  );
  await tester.pump();
  await tester.tap(
    find.byKey(const ValueKey('work-item-assignees-search-submit')),
  );
  await settleNetworkWidgets(tester);
}

Future<void> _save(WidgetTester tester, WorkItemAssigneeFixture fixture) async {
  final before = fixture.mutations;
  await tester.tap(find.byKey(const ValueKey('work-item-assignees-save')));
  await pumpUntil(tester, () => fixture.mutations > before, maxCycles: 80);
  await settleNetworkWidgets(tester);
}

ResponseBody _staleCandidate(WorkItemAssigneeFixture fixture) {
  return jsonResponse({
    'data': {
      'currentUser': {'id': fixture.userId(7)},
      'project': {
        'id': 'gid://gitlab/Project/42',
        'fullPath': fixture.project.path,
        'autocompleteUsers': [
          {'id': fixture.userId(50), 'name': '過期候選', 'username': 'stale'},
        ],
      },
    },
  });
}

ResponseBody _candidatePage(
  WorkItemAssigneeFixture fixture, {
  required String name,
  required String username,
}) {
  return jsonResponse({
    'data': {
      'currentUser': {'id': fixture.userId(7)},
      'project': {
        'id': 'gid://gitlab/Project/42',
        'fullPath': fixture.project.path,
        'autocompleteUsers': [
          {'id': fixture.userId(1001), 'name': name, 'username': username},
        ],
      },
    },
  });
}

Map<String, Object?> _lost() => {
  'errors': [
    {'message': 'lost'},
  ],
};
