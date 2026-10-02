import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_state_models.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/project_extras.dart';
import 'package:gitlab_mobile/shared/scroll_performance.dart';

import '../tool/emulator_ui.dart';
import 'support/widget_settle.dart';

void main() {
  test('QA target refuses to build without the explicit dart define', () {
    expect(
      () => buildEmulatorQaApp(qaEnabled: false),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'fixture is synthetic, deterministic, and closed to unknown endpoints',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);

      expect(fixture.api.instance.base.scheme, 'https');
      expect(fixture.api.instance.base.host, 'qa.invalid');
      expect(fixture.api.instance.base.port, 8443);
      expect(fixture.api.instance.base.path, '/gitlab');
      expect(fixture.account.user.id, 7);
      expect(fixture.project.id, 42);
      expect(fixture.todoRows, hasLength(30));
      expect(
        fixture.todoRows.first['target'],
        containsPair('title', 'Synthetic mobile QA todo 01'),
      );
      expect(fixture.environmentRows, hasLength(120));
      expect(fixture.environmentRows.first['id'], 17);
      expect(fixture.environmentRows.first['name'], 'staging/mobile');
      expect(fixture.deploymentRows, hasLength(120));

      final deploymentJob = await fixture.api.record([
        'projects',
        '42',
        'jobs',
        '5120',
      ]);
      expect(deploymentJob['id'], 5120);
      expect(
        await fixture.api.jobTrace(42, 5001),
        contains('[synthetic qa] deployment job 5001'),
      );
      await expectLater(
        fixture.api.record(['projects', '42', 'jobs', '5121']),
        throwsA(
          isA<ApiFailure>().having((failure) => failure.status, 'status', 404),
        ),
      );

      expect(await fixture.api.hasStarred(42, 'developer'), isFalse);
      final starred = await fixture.api.setStar(42, true);
      expect(starred?['star_count'], 13);
      expect(await fixture.api.hasStarred(42, 'developer'), isTrue);
      await fixture.api.playPipelineSchedule(42, 3);
      expect(fixture.playedSchedules, [3]);

      await expectLater(
        fixture.api.record(['qa-unknown-endpoint']),
        throwsA(
          isA<ApiFailure>().having((failure) => failure.status, 'status', 404),
        ),
      );
      expect(fixture.unhandled, contains('GET qa-unknown-endpoint'));
      expect(
        fixture.adapter.requests.every(
          (request) =>
              request.uri.host == 'qa.invalid' &&
              request.uri.port == 8443 &&
              request.uri.path.startsWith('/gitlab/api/v4/'),
        ),
        isTrue,
      );
    },
  );

  testWidgets('banner and QA controls persist across production routes', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var semanticsDisposed = false;
    void disposeSemantics() {
      if (semanticsDisposed) return;
      semanticsDisposed = true;
      semantics.dispose();
    }

    addTearDown(disposeSemantics);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    try {
      await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
      await tester.pumpAndSettle();

      expect(find.byType(ScrollPerformance), findsOneWidget);
      expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
      expect(find.text('重設 Session'), findsOneWidget);
      expect(find.text('結束 Session'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(find.text('環境與部署'), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.text('環境與部署'));
      await settleNetworkWidgets(tester);

      expect(find.byType(EnvironmentsPage), findsOneWidget);
      expect(
        MediaQuery.textScalerOf(
          tester.element(find.byType(EnvironmentsPage)),
        ).scale(14),
        28,
      );
      expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
      expect(find.text('staging/mobile'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('合成資料 QA.*來源 $emulatorUiQaCommit')),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('重設 Session'), findsOneWidget);
      expect(find.bySemanticsLabel('結束 Session'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('staging/mobile'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('#120'));
      await settleNetworkWidgets(tester);

      expect(find.byType(JobLogPage), findsOneWidget);
      expect(find.textContaining('deployment job 5120'), findsOneWidget);
      expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      disposeSemantics();
    }
  });

  test(
    'project and group QA state changes stay in memory and read back independently',
    () async {
      final fixture = EmulatorQaFixture();
      addTearDown(fixture.api.close);
      final project = await fixture.api.projectWorkItem(fixture.project, 31);
      final group = await fixture.api.namespaceWorkItem(
        'qa/synthetic-group',
        41,
        expectedNamespaceId: 'gid://gitlab/Group/84',
      );
      for (final item in [project, group]) {
        final before = await fixture.api.workItemState(item.summary);
        expect(before.state, WorkItemState.open);
        expect(before.canUpdate, isTrue);
        final changed = await fixture.api.updateWorkItemState(
          item.summary,
          WorkItemStateEvent.close,
          expectedUpdatedAt: before.updatedAt,
        );
        final readback = await fixture.api.workItemState(item.summary);
        expect(changed.state, WorkItemState.closed);
        expect(readback.state, WorkItemState.closed);
        expect(readback.updatedAt, changed.updatedAt);
      }
      expect(fixture.workItemStateEvents, ['CLOSE', 'CLOSE']);
      expect(fixture.unhandled, isEmpty);
      expect(
        fixture.adapter.requests.every(
          (request) =>
              request.uri.host == 'qa.invalid' &&
              request.uri.port == 8443 &&
              request.uri.path == '/gitlab/api/graphql',
        ),
        isTrue,
      );
    },
  );

  for (final group in [false, true]) {
    testWidgets(
      'scaled ${group ? 'group' : 'project'} Work Item can cancel, close, reopen and invalidate its dialog',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 1100);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
        await tester.pumpAndSettle();
        final destination = find.text(group ? '群組 Work Item' : '專案 Work Item');
        await tester.scrollUntilVisible(destination, 200);
        await tester.pumpAndSettle();
        await tester.tap(destination);
        await settleNetworkWidgets(tester);
        expect(
          find.text(
            group ? 'Synthetic group Work Item' : 'Synthetic project Work Item',
          ),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('work-item-state-control')),
          200,
        );
        await settleNetworkWidgets(tester);
        final close = find.text('關閉工作項目');
        await tester.ensureVisible(close);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.text('關閉工作項目？'), findsOneWidget);
        expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(find.text('目前為開啟'), findsOneWidget);
        await tester.tap(close);
        await tester.pumpAndSettle();
        await tester.tap(find.text('確認關閉'));
        await settleNetworkWidgets(tester);
        expect(find.text('目前為已關閉'), findsOneWidget);
        final reopen = find.text('重新開啟');
        await tester.ensureVisible(reopen);
        await tester.tap(reopen);
        await tester.pumpAndSettle();
        await tester.tap(find.text('確認重開'));
        await settleNetworkWidgets(tester);
        expect(find.text('目前為開啟'), findsOneWidget);
        await tester.ensureVisible(close);
        await tester.tap(close);
        await tester.pumpAndSettle();
        await tester.tap(find.text('結束 Session'));
        await settleNetworkWidgets(tester);
        expect(find.text('關閉工作項目？'), findsNothing);
        expect(find.text('確認關閉'), findsNothing);
        expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('compact scaled schedule confirmation keeps the QA chrome', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 900);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Pipeline 排程'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pipeline 排程'));
    await settleNetworkWidgets(tester);

    expect(
      MediaQuery.textScalerOf(
        tester.element(find.byType(PipelineSchedulesPage)),
      ).scale(14),
      28,
    );
    await tester.tap(find.byTooltip('立即執行').first);
    await tester.pumpAndSettle();

    expect(find.text('立即執行排程？'), findsOneWidget);
    expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('立即執行排程？'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'authenticated shell restores system insets and fits every tab at 320 dp with scaled text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 1100);
      tester.view.padding = const FakeViewPadding(top: 36, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 36, bottom: 24);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('主畫面與底部導航'));
      await settleNetworkWidgets(tester);

      final viewport = tester.element(
        find.byKey(const ValueKey('emulator-qa-shell-viewport')),
      );
      final media = MediaQuery.of(viewport);
      expect(media.padding.top, 36);
      expect(media.padding.bottom, 24);
      expect(media.textScaler.scale(14), 28);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '專案');

      for (final destination in ['收件匣', 'CI', '我的', '專案']) {
        await tester.tap(
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text(destination),
          ),
        );
        await settleNetworkWidgets(tester);
        if (destination == '收件匣') {
          expect(find.text('Synthetic mobile QA todo 01'), findsOneWidget);
        }
        expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
        expect(tester.takeException(), isNull, reason: destination);
      }
    },
  );

  testWidgets('end and reset discard the old authenticated QA shell', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('主畫面與底部導航'));
    await settleNetworkWidgets(tester);
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.tap(find.text('結束 Session'));
    await settleNetworkWidgets(tester);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);

    await tester.tap(find.text('重設 Session'));
    await tester.pumpAndSettle();
    expect(find.text('Emulator UI QA'), findsOneWidget);
    expect(find.text('主畫面與底部導航'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    await tester.tap(find.text('主畫面與底部導航'));
    await settleNetworkWidgets(tester);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('end and reset controls invalidate and restore the QA session', (
    tester,
  ) async {
    await tester.pumpWidget(buildEmulatorQaApp(qaEnabled: true));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Pipeline 排程'), 200);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pipeline 排程'));
    await settleNetworkWidgets(tester);
    expect(find.byType(PipelineSchedulesPage), findsOneWidget);
    expect(find.text('Nightly synthetic build'), findsOneWidget);

    await tester.tap(find.text('結束 Session'));
    await settleNetworkWidgets(tester);
    expect(find.text('Nightly synthetic build'), findsNothing);
    expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);

    await tester.tap(find.text('重設 Session'));
    await tester.pumpAndSettle();
    expect(find.text('Emulator UI QA'), findsOneWidget);
    expect(find.text('專案頁面'), findsOneWidget);
    expect(find.text('Pipeline 排程'), findsOneWidget);
    expect(find.text('合成資料 QA · 無 GitLab 連線'), findsOneWidget);
  });
}
