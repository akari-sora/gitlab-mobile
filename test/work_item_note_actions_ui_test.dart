import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/workspace/work_item_activity.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import '../tool/emulator_ui.dart';

const _projectNoteId = 'gid://gitlab/Note/100002';

Widget _host(
  EmulatorQaFixture fixture,
  WorkItemGraphDetail detail, {
  bool Function()? isCurrent,
  Listenable? ownerChanges,
  double textScale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child: WorkItemActivityPanel(
        account: fixture.account,
        api: fixture.api,
        detail: detail,
        project: fixture.project,
        isCurrent: isCurrent,
        ownerChanges: ownerChanges,
      ),
    ),
  ),
);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await _drainAsync(tester);
}

Future<void> _drainAsync(WidgetTester tester) async {
  for (var index = 0; index < 20; index++) {
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await tester.pump();
}

Future<WorkItemGraphDetail> _openFirstNoteActions(
  WidgetTester tester,
  EmulatorQaFixture fixture, {
  double textScale = 1,
  bool Function()? isCurrent,
  Listenable? ownerChanges,
}) async {
  final detail = (await tester.runAsync(
    () => fixture.api.projectWorkItem(fixture.project, 31),
  ))!;
  await tester.pumpWidget(
    _host(
      fixture,
      detail,
      textScale: textScale,
      isCurrent: isCurrent,
      ownerChanges: ownerChanges,
    ),
  );
  await _tap(tester, find.text('活動'));
  await _tap(
    tester,
    find.byKey(
      const ValueKey('work-item-activity-note-actions:$_projectNoteId'),
    ),
  );
  return detail;
}

int _operationReads(EmulatorQaFixture fixture, String operation) => fixture
    .adapter
    .requests
    .where(
      (request) =>
          ((request.data as Map)['query'] as String).contains(operation),
    )
    .length;

void main() {
  testWidgets(
    'delete is confirmed from a fresh capability and refreshes the activity',
    (tester) async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);

      await _openFirstNoteActions(tester, fixture);
      expect(
        _operationReads(fixture, 'MobileWorkItemActivityEditAccess'),
        1,
        reason: 'Only the menu edit capability is read while opening actions.',
      );

      await _tap(
        tester,
        find.byKey(const ValueKey('work-item-activity-delete-note')),
      );
      expect(
        _operationReads(fixture, 'MobileWorkItemActivityEditAccess'),
        2,
        reason: 'Delete capability is fetched only after choosing delete.',
      );
      expect(find.text('studio/mobile-workspace · #31'), findsOneWidget);
      expect(find.text('Synthetic comment 1'), findsWidgets);
      expect(find.textContaining('刪除後無法復原'), findsOneWidget);

      await _tap(
        tester,
        find.byKey(const ValueKey('work-item-activity-confirm-delete-note')),
      );

      expect(fixture.workItemNoteDeleteEvents, [
        {'scope': 'project', 'noteId': _projectNoteId},
      ]);
      expect(find.text('Synthetic comment 1'), findsNothing);
      expect(find.text('Synthetic reply 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('uncertain delete stays one shot and asks for a refresh', (
    tester,
  ) async {
    final fixture = EmulatorQaFixture()
      ..failNextWorkItemNoteDeleteAcknowledgement = true;
    addTearDown(fixture.api.close);

    await _openFirstNoteActions(tester, fixture);
    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-delete-note')),
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-confirm-delete-note')),
    );

    expect(fixture.workItemNoteDeleteEvents, hasLength(1));
    expect(
      find.textContaining('請關閉並重新整理活動後再確認'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data)
          .whereType<String>()
          .join(' | '),
    );
    expect(
      find.byKey(const ValueKey('work-item-activity-confirm-delete-note')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending delete locks close and back until it finishes', (
    tester,
  ) async {
    final fixture = EmulatorQaFixture();
    addTearDown(fixture.api.close);

    await _openFirstNoteActions(tester, fixture);
    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-delete-note')),
    );
    await tester.tap(
      find.byKey(const ValueKey('work-item-activity-confirm-delete-note')),
    );
    await tester.pump();

    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '關閉'))
          .onPressed,
      isNull,
    );
    expect(find.text('正在刪除留言…'), findsOneWidget);

    await _drainAsync(tester);
    expect(fixture.workItemNoteDeleteEvents, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final action in ['delete', 'reaction']) {
    testWidgets('$action 404 identifies the account, instance and note', (
      tester,
    ) async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final detail = await _openFirstNoteActions(tester, fixture);

      await tester.runAsync(() async {
        final page = await fixture.api.workItemActivity(detail.summary);
        final discussion = page.snapshot.discussions.items.first;
        final note = discussion.notes.items.first;
        final access = await fixture.api.workItemActivityDeleteAccess(
          detail.summary,
          discussion,
          note,
        );
        await fixture.api.deleteWorkItemActivityNote(access.target!);
      });
      await _tap(
        tester,
        find.byKey(
          ValueKey(
            action == 'delete'
                ? 'work-item-activity-delete-note'
                : 'work-item-activity-note-reactions',
          ),
        ),
      );

      expect(find.text('無法開啟此資源'), findsOneWidget);
      expect(find.text('實例：https://qa.invalid:8443/gitlab'), findsOneWidget);
      expect(find.text('App 帳號：@developer'), findsOneWidget);
      expect(find.text('目標：studio/mobile-workspace · #31 留言'), findsOneWidget);
      expect(find.text('重新整理'), findsOneWidget);
      expect(find.text('切換帳號'), findsOneWidget);
      if (action == 'delete') {
        await tester.tap(find.text('切換帳號'));
        await tester.pump();
        expect(find.text('刪除留言'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('after a reaction, delete, close and reopen use the fresh note', (
    tester,
  ) async {
    final fixture = EmulatorQaFixture();
    addTearDown(fixture.api.close);

    await _openFirstNoteActions(tester, fixture);
    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-note-reactions')),
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-add-reaction')),
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-pick-reaction:heart')),
    );
    expect(find.text('❤️ 1'), findsOneWidget);
    // GitLab bumped updatedAt; the dialog's delete must not call the note
    // changed.
    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-delete-note')),
    );
    expect(find.text(l10n.commentHasBeenModified), findsNothing);
    expect(find.textContaining('刪除後無法復原'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('work-item-activity-confirm-delete-note')),
      findsOneWidget,
    );

    // Closing without another write still refreshes the activity, so the
    // reopened dialog loads edit and reactions from the fresh note.
    int feedReads() => fixture.adapter.requests
        .where(
          (request) => ((request.data as Map)['query'] as String).contains(
            'query MobileWorkItemActivity(',
          ),
        )
        .length;
    final activityReads = feedReads();
    await tester.tap(find.widgetWithText(TextButton, '關閉'));
    await _drainAsync(tester);
    expect(feedReads(), greaterThan(activityReads));
    await _tap(
      tester,
      find.byKey(
        const ValueKey('work-item-activity-note-actions:$_projectNoteId'),
      ),
    );
    expect(find.text(l10n.commentHasBeenModified), findsNothing);
    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-note-reactions')),
    );
    expect(find.text(l10n.commentHasBeenModified), findsNothing);
    expect(find.text('❤️ 1'), findsOneWidget);
    expect(fixture.workItemNoteDeleteEvents, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reactions add then remove when updatedAt advances', (
    tester,
  ) async {
    final fixture = EmulatorQaFixture();
    addTearDown(fixture.api.close);

    await _openFirstNoteActions(tester, fixture);
    expect(_operationReads(fixture, 'MobileWorkItemActivityReactionAccess'), 0);
    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-note-reactions')),
    );
    expect(_operationReads(fixture, 'MobileWorkItemActivityReactionAccess'), 1);
    expect(find.text('👍 1'), findsOneWidget);
    final originalUpdatedAt = fixture.workItemActivityNoteRecord(
      _projectNoteId,
      group: false,
    )!['updatedAt'];

    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-add-reaction')),
    );
    await tester.tap(
      find.byKey(const ValueKey('work-item-activity-pick-reaction:heart')),
    );
    await tester.pump();
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isFalse);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '關閉'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('work-item-activity-delete-note')),
          )
          .onPressed,
      isNull,
    );
    await _drainAsync(tester);
    expect(fixture.workItemNoteReactionEvents.single, {
      'scope': 'project',
      'noteId': _projectNoteId,
      'name': 'heart',
      'awarded': true,
    });
    expect(find.text('❤️ 1'), findsOneWidget);
    final addedUpdatedAt = fixture.workItemActivityNoteRecord(
      _projectNoteId,
      group: false,
    )!['updatedAt'];
    expect(addedUpdatedAt, isNot(originalUpdatedAt));
    expect(
      tester.widget<FilterChip>(
        find.byKey(const ValueKey('work-item-activity-reaction:heart')),
      ).selected,
      isTrue,
    );
    expect(find.text(l10n.actionResultUnconfirmed), findsNothing);
    expect(find.text(l10n.emojiReactionUnconfirmed), findsNothing);

    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-reaction:heart')),
    );
    expect(fixture.workItemNoteReactionEvents, hasLength(2));
    expect(fixture.workItemNoteReactionEvents.last['awarded'], isFalse);
    expect(find.text('❤️ 1'), findsNothing);
    expect(
      fixture.workItemActivityNoteRecord(
        _projectNoteId,
        group: false,
      )!['updatedAt'],
      isNot(addedUpdatedAt),
    );
    expect(find.text(l10n.actionResultUnconfirmed), findsNothing);
    expect(find.text(l10n.emojiReactionUnconfirmed), findsNothing);

    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-add-reaction')),
    );
    expect(
      find.bySemanticsLabel('star 表情回應'),
      findsOneWidget,
      reason: 'The Work Item picker must include the shared Star choice.',
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-pick-reaction:star')),
    );
    expect(fixture.workItemNoteReactionEvents, hasLength(3));
    expect(fixture.workItemNoteReactionEvents.last, {
      'scope': 'project',
      'noteId': _projectNoteId,
      'name': 'star',
      'awarded': true,
    });
    expect(find.text('⭐ 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('read-only reactions remain visible with disabled controls', (
    tester,
  ) async {
    final fixture = EmulatorQaFixture();
    fixture.workItemNoteReactionAllowed[false] = false;
    addTearDown(fixture.api.close);

    await _openFirstNoteActions(tester, fixture);
    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-note-reactions')),
    );

    expect(find.text('👍 1'), findsOneWidget);
    expect(find.textContaining('沒有新增或移除的權限'), findsOneWidget);
    final chip = tester.widget<FilterChip>(
      find.byKey(const ValueKey('work-item-activity-reaction:thumbsup')),
    );
    expect(chip.onSelected, isNull);
    final add = tester.widget<ActionChip>(
      find.widgetWithText(ActionChip, '新增表情回應'),
    );
    expect(add.onPressed, isNull);
    expect(fixture.workItemNoteReactionEvents, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320dp at twice text keeps every note action scrollable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 720);
    addTearDown(tester.view.reset);
    final fixture = EmulatorQaFixture();
    addTearDown(fixture.api.close);

    await _openFirstNoteActions(tester, fixture, textScale: 2);
    for (final label in [
      '編輯留言',
      '刪除留言',
      '表情回應',
      '複製留言連結',
      '以其他 App 分享',
      '關閉',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-note-reactions')),
    );
    await _tap(
      tester,
      find.byKey(const ValueKey('work-item-activity-add-reaction')),
    );
    expect(
      find.byKey(const ValueKey('work-item-activity-pick-reaction:heart')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('owner invalidation dismisses the owned note action route', (
    tester,
  ) async {
    final fixture = EmulatorQaFixture();
    addTearDown(fixture.api.close);
    final owner = ChangeNotifier();
    addTearDown(owner.dispose);
    var current = true;

    await _openFirstNoteActions(
      tester,
      fixture,
      isCurrent: () => current,
      ownerChanges: owner,
    );
    expect(find.text('留言動作'), findsOneWidget);

    current = false;
    owner.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.text('留言動作'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
