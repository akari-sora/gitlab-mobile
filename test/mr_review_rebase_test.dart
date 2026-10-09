import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace;

Widget _host(Widget child) => MaterialApp(
      theme: appTheme(Brightness.light),
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: child,
    );

void _surface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('MR review card displays unresolved discussions notice when blocking discussions unresolved', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    fixture.mergeFields['blocking_discussions_resolved'] = false;

    await tester.pumpWidget(_host(Scaffold(
      body: WorkItemPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'merge_requests',
        iid: 12,
      ),
    )));
    await settleWorkspace(tester);

    expect(find.byKey(const ValueKey('unresolved-discussions-notice')), findsOneWidget);
    expect(find.text('尚有未解決的討論，解決後方可合併'), findsOneWidget);

    await _finish(tester);
  });

  testWidgets('MR review card displays rebase button when diverged commits > 0 and handles rebase action', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    fixture.mergeFields['diverged_commits_count'] = 3;
    fixture.mergeFields['has_conflicts'] = false;
    fixture.mergeFields['rebase_in_progress'] = false;

    Json? mutatedData;

    await tester.pumpWidget(_host(Scaffold(
      body: WorkItemPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'merge_requests',
        iid: 12,
        onMutated: (data) => mutatedData = data,
      ),
    )));
    await settleWorkspace(tester);

    expect(mutatedData, isNull, reason: 'Reading the overview is not a mutation');
    expect(find.byKey(const ValueKey('mr-rebase-btn')), findsOneWidget);
    expect(find.text('Rebase (落後 3)'), findsOneWidget);

    // Tap rebase button
    await tester.tap(find.byKey(const ValueKey('mr-rebase-btn')));
    await settleWorkspace(tester);

    // Confirmation dialog
    expect(find.text('Rebase 分支？'), findsOneWidget);
    expect(find.text('將此合併請求來源分支 Rebase 至目標分支。'), findsOneWidget);

    // Confirm rebase
    await tester.tap(find.text('確認'));
    // Do bounded pumps because rebase_in_progress shows CircularProgressIndicator
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('已請求 Rebase 分支'), findsOneWidget);
    expect(fixture.mergeFields['rebase_in_progress'], isTrue);
    expect(mutatedData, isNotNull, reason: 'Successful rebase readback notifies the resident feed');
    expect(mutatedData!['rebase_in_progress'], isTrue);

    await _finish(tester);
  });

  testWidgets('MR review card shows rebase in progress disabled button when rebase_in_progress is true', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    fixture.mergeFields['rebase_in_progress'] = true;

    await tester.pumpWidget(_host(Scaffold(
      body: WorkItemPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'merge_requests',
        iid: 12,
      ),
    )));
    // Bounded pumps for initial load with spinner
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const ValueKey('mr-rebase-progress-btn')), findsOneWidget);
    expect(find.text('Rebase 進行中…'), findsOneWidget);

    final btn = tester.widget<OutlinedButton>(find.byKey(const ValueKey('mr-rebase-progress-btn')));
    expect(btn.onPressed, isNull);

    await _finish(tester);
  });
}
