import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  group('MR Auto-Merge pure helpers', () {
    test('isAutoMergeEnabled returns true for either merge_when_pipeline_succeeds or auto_merge_enabled, but false if merged/closed', () {
      expect(isAutoMergeEnabled({}), isFalse);
      expect(isAutoMergeEnabled({'merge_when_pipeline_succeeds': false}), isFalse);
      expect(isAutoMergeEnabled({'auto_merge_enabled': false}), isFalse);
      expect(isAutoMergeEnabled({'merge_when_pipeline_succeeds': true}), isTrue);
      expect(isAutoMergeEnabled({'auto_merge_enabled': true}), isTrue);
      expect(isAutoMergeEnabled({'merge_when_pipeline_succeeds': true, 'auto_merge_enabled': false}), isTrue);
      expect(isAutoMergeEnabled({'merge_when_pipeline_succeeds': false, 'auto_merge_enabled': true}), isTrue);
      expect(isAutoMergeEnabled({'state': 'merged', 'merge_when_pipeline_succeeds': true}), isFalse);
      expect(isAutoMergeEnabled({'state': 'closed', 'auto_merge_enabled': true}), isFalse);
      expect(isAutoMergeEnabled({'state': 'opened', 'merge_when_pipeline_succeeds': true}), isTrue);
    });

    test('canAutoMerge identifies candidates waiting on pipelines and blocks drafts/conflicts/unmergeable', () {
      expect(canAutoMerge({}), isFalse);
      expect(canAutoMerge({'state': 'closed', 'detailed_merge_status': 'ci_still_running'}), isFalse);
      expect(canAutoMerge({'state': 'merged', 'detailed_merge_status': 'ci_still_running'}), isFalse);
      expect(canAutoMerge({'state': 'opened', 'auto_merge_enabled': true, 'detailed_merge_status': 'ci_still_running'}), isFalse);
      expect(canAutoMerge({'state': 'opened', 'detailed_merge_status': 'ci_still_running'}), isTrue);
      expect(canAutoMerge({'state': 'opened', 'detailed_merge_status': 'ci_must_pass'}), isTrue);
      for (final status in ['running', 'pending', 'created', 'waiting_for_resource', 'preparing', 'manual']) {
        expect(canAutoMerge({'state': 'opened', 'head_pipeline': {'status': status}}), isTrue);
      }
      expect(canAutoMerge({'state': 'opened', 'head_pipeline': {'status': 'success'}, 'detailed_merge_status': 'mergeable'}), isFalse);
      expect(canAutoMerge({'state': 'opened', 'head_pipeline': {'status': 'failed'}}), isFalse);

      // Blocked states: Draft, Conflicts, Cannot be merged, Need rebase, Broken, Mergeable
      expect(canAutoMerge({'state': 'opened', 'draft': true, 'head_pipeline': {'status': 'running'}}), isFalse);
      expect(canAutoMerge({'state': 'opened', 'work_in_progress': true, 'head_pipeline': {'status': 'running'}}), isFalse);
      expect(canAutoMerge({'state': 'opened', 'detailed_merge_status': 'draft_status', 'head_pipeline': {'status': 'running'}}), isFalse);
      expect(canAutoMerge({'state': 'opened', 'has_conflicts': true, 'head_pipeline': {'status': 'running'}}), isFalse);
      expect(canAutoMerge({'state': 'opened', 'detailed_merge_status': 'conflict', 'head_pipeline': {'status': 'running'}}), isFalse);
      expect(canAutoMerge({'state': 'opened', 'detailed_merge_status': 'need_rebase', 'head_pipeline': {'status': 'running'}}), isFalse);
      expect(canAutoMerge({'state': 'opened', 'detailed_merge_status': 'broken_status', 'head_pipeline': {'status': 'running'}}), isFalse);
      expect(canAutoMerge({'state': 'opened', 'merge_status': 'cannot_be_merged', 'head_pipeline': {'status': 'running'}}), isFalse);
      expect(canAutoMerge({'state': 'opened', 'detailed_merge_status': 'cannot_be_merged', 'head_pipeline': {'status': 'running'}}), isFalse);
      expect(canAutoMerge({'state': 'opened', 'detailed_merge_status': 'mergeable', 'head_pipeline': {'status': 'running'}}), isFalse);
    });

    test('mergeStatusLabel reports auto-merge author or default label', () {
      expect(mergeStatusLabel({
        'auto_merge_enabled': true,
        'merge_user': {'username': 'octocat'},
      }), '已由 @octocat 排程自動合併');

      expect(mergeStatusLabel({
        'merge_when_pipeline_succeeds': true,
        'merge_user': {'name': 'Octo Cat'},
      }), '已排程自動合併');

      expect(mergeStatusLabel({
        'auto_merge_enabled': true,
      }), '已排程自動合併');

      expect(mergeStatusLabel({
        'detailed_merge_status': 'ci_still_running',
      }), 'CI 執行中');
    });
  });

  group('workItemCard auto-merge chip', () {
    testWidgets('shows auto-merge chip on list item when enabled', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => workItemCard(
              context,
              {
                'iid': 42,
                'title': 'Feature auto-merge',
                'state': 'opened',
                'source_branch': 'feat/auto',
                'target_branch': 'main',
                'auto_merge_enabled': true,
                'head_pipeline': {'status': 'running'},
              },
              mr: true,
              onTap: () {},
            ),
          ),
        ),
      ));

      expect(find.text('自動合併'), findsOneWidget);
      expect(find.byIcon(Icons.schedule_send), findsOneWidget);
    });

    testWidgets('omits auto-merge chip on list item when disabled', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => workItemCard(
              context,
              {
                'iid': 42,
                'title': 'Feature manual merge',
                'state': 'opened',
                'source_branch': 'feat/manual',
                'target_branch': 'main',
                'auto_merge_enabled': false,
              },
              mr: true,
              onTap: () {},
            ),
          ),
        ),
      ));

      expect(find.text('自動合併'), findsNothing);
    });
  });

  group('WorkItemPage Auto-Merge Scheduling & Cancellation', () {
    Future<WorkspaceFixture> pumpMrPage(WidgetTester tester, Map<String, dynamic> mrFields) async {
      final fixture = WorkspaceFixture()..mergeFields.addAll(mrFields);
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(workspaceHost(WorkItemPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'merge_requests',
        iid: 12,
      )));
      await settleWorkspace(tester);
      return fixture;
    }

    testWidgets('schedules auto-merge when CI is running and sends auto_merge flags', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final fixture = await pumpMrPage(tester, {
          'detailed_merge_status': 'ci_still_running',
          'head_pipeline': {'id': 99, 'status': 'running'},
          'force_remove_source_branch': true,
        });

        expect(find.text('CI 執行中'), findsWidgets);
        final autoMergeButton = find.widgetWithText(FilledButton, '自動合併…');
        expect(autoMergeButton, findsOneWidget);
        expect(tester.getSize(autoMergeButton).height, greaterThanOrEqualTo(48));

        await tester.tap(autoMergeButton);
        await settleWorkspace(tester);

        expect(find.text('排程自動合併 !12？'), findsOneWidget);
        final autoSwitch = find.byKey(const ValueKey('merge-auto'));
        expect(autoSwitch, findsOneWidget);
        expect(tester.getSize(autoSwitch).height, greaterThanOrEqualTo(48));
        expect(tester.widget<SwitchListTile>(autoSwitch).value, isTrue);

        final submitBtn = find.widgetWithText(FilledButton, '排程自動合併');
        expect(submitBtn, findsOneWidget);
        expect(tester.getSize(submitBtn).height, greaterThanOrEqualTo(48));

        await tester.tap(submitBtn);
        await settleWorkspace(tester);

        final mergeReq = fixture.adapter.requests.lastWhere(
          (r) => r.method == 'PUT' && r.uri.path.endsWith('/merge'),
        );
        final body = mergeReq.data as Map<String, dynamic>;
        expect(body['sha'], WorkspaceFixture.sha);
        expect(body['auto_merge'], isTrue);
        expect(body['merge_when_pipeline_succeeds'], isTrue);
        expect(body['auto_merge_strategy'], 'merge_when_pipeline_succeeds');
        expect(body['should_remove_source_branch'], isTrue);

        expect(find.text('已排程自動合併，等待流水線完成。'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(fixture.unhandled, isEmpty);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('allows disabling auto-merge in dialog for explicit manual merge', (tester) async {
      final fixture = await pumpMrPage(tester, {
        'detailed_merge_status': 'ci_still_running',
        'head_pipeline': {'id': 99, 'status': 'running'},
      });

      await tester.tap(find.widgetWithText(FilledButton, '自動合併…'));
      await settleWorkspace(tester);

      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('merge-auto'))).value, isTrue);
      await tester.tap(find.byKey(const ValueKey('merge-auto')));
      await tester.pump();
      expect(tester.widget<SwitchListTile>(find.byKey(const ValueKey('merge-auto'))).value, isFalse);
      expect(find.text('確認'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '確認'));
      await settleWorkspace(tester);

      final mergeReq = fixture.adapter.requests.lastWhere(
        (r) => r.method == 'PUT' && r.uri.path.endsWith('/merge'),
      );
      final body = mergeReq.data as Map<String, dynamic>;
      expect(body.containsKey('auto_merge'), isFalse);
      expect(body.containsKey('merge_when_pipeline_succeeds'), isFalse);
      expect(body.containsKey('auto_merge_strategy'), isFalse);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('does not show auto-merge switch in dialog when MR is already mergeable', (tester) async {
      final fixture = await pumpMrPage(tester, {
        'detailed_merge_status': 'mergeable',
      });

      expect(find.widgetWithText(FilledButton, '合併'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '自動合併…'), findsNothing);

      await tester.tap(find.widgetWithText(FilledButton, '合併'));
      await settleWorkspace(tester);

      expect(find.text('合併 !12？'), findsOneWidget);
      expect(find.byKey(const ValueKey('merge-auto')), findsNothing);
      expect(find.byKey(const ValueKey('merge-squash')), findsOneWidget);
      expect(find.byKey(const ValueKey('merge-remove-branch')), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, '確認'));
      await settleWorkspace(tester);

      final mergeReq = fixture.adapter.requests.lastWhere(
        (r) => r.method == 'PUT' && r.uri.path.endsWith('/merge'),
      );
      final body = mergeReq.data as Map<String, dynamic>;
      expect(body['sha'], WorkspaceFixture.sha);
      expect(body.containsKey('auto_merge'), isFalse);
      expect(body.containsKey('merge_when_pipeline_succeeds'), isFalse);
      expect(body.containsKey('auto_merge_strategy'), isFalse);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('shows auto-merge status card and cancels auto-merge on user confirmation', (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final fixture = await pumpMrPage(tester, {
          'auto_merge_enabled': true,
          'merge_when_pipeline_succeeds': true,
          'merge_user': {'id': 7, 'username': 'developer', 'name': 'Developer'},
          'head_pipeline': {'id': 99, 'status': 'running'},
        });

        expect(find.text('已由 @developer 排程自動合併'), findsWidgets);
        expect(find.text('流水線通過後將自動執行合併。'), findsOneWidget);
        final cancelBtn = find.byKey(const ValueKey('cancel-auto-merge'));
        expect(cancelBtn, findsOneWidget);
        expect(tester.getSize(cancelBtn).height, greaterThanOrEqualTo(48));

        await tester.tap(cancelBtn);
        await settleWorkspace(tester);

        expect(find.text('取消自動合併？'), findsOneWidget);
        expect(find.text('取消後將不再於流水線通過時自動合併此變更。'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, '確認'));
        await settleWorkspace(tester);

        final cancelReq = fixture.adapter.requests.lastWhere(
          (r) => r.method == 'POST' && r.uri.path.endsWith('/cancel_merge_when_pipeline_succeeds'),
        );
        expect(cancelReq, isNotNull);
        expect(find.text('已取消自動合併'), findsOneWidget);

        expect(tester.takeException(), isNull);
        expect(fixture.unhandled, isEmpty);

        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('cancels auto-merge from checks tab with >= 48dp touch target', (tester) async {
      final fixture = await pumpMrPage(tester, {
        'auto_merge_enabled': true,
        'merge_when_pipeline_succeeds': true,
        'head_pipeline': {'id': 99, 'status': 'running'},
      });

      await tester.tap(find.text('檢查'));
      await settleWorkspace(tester);

      final cancelChecksBtn = find.byKey(const ValueKey('cancel-auto-merge-checks'));
      expect(cancelChecksBtn, findsOneWidget);
      expect(tester.getSize(cancelChecksBtn).height, greaterThanOrEqualTo(48));

      await tester.tap(cancelChecksBtn);
      await settleWorkspace(tester);

      expect(find.text('取消自動合併？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '確認'));
      await settleWorkspace(tester);

      final cancelReq = fixture.adapter.requests.lastWhere(
        (r) => r.method == 'POST' && r.uri.path.endsWith('/cancel_merge_when_pipeline_succeeds'),
      );
      expect(cancelReq, isNotNull);
      expect(find.text('已取消自動合併'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
