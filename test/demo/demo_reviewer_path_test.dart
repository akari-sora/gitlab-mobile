// The Play reviewer's path through the demo, end to end on the production
// shell: Home → project → issue → MR diff → CI job log → AI chat from a file →
// scripted answer → a comment proposed on a confirmation card → approved →
// the comment shows on the issue. Everything is answered on the device.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/demo/demo_app.dart';
import 'package:gitlab_mobile/features/demo/demo_data.dart';
import 'package:gitlab_mobile/features/demo/demo_runtime.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import '../support/widget_settle.dart';
import 'demo_test_support.dart';

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await settleNetworkWidgets(tester, maxCycles: 30);
}

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await settleNetworkWidgets(tester, maxCycles: 30);
}

void main() {
  testWidgets('the reviewer path runs on sample data, AI comment included', (
    tester,
  ) async {
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final secure = recordSecureStorage();
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = noNetwork;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    phoneView(tester);
    final runtime = (await tester.runAsync(() => DemoRuntime.start(ai: true)))!;
    addTearDown(runtime.dispose);
    expect(runtime.ai, isNotNull, reason: 'the demo assistant set up');
    var exits = 0;
    await tester.pumpWidget(
      DemoApp(
        runtime: runtime,
        onExit: () async => exits++,
        buildInfoLoader: testBuildInfo,
      ),
    );
    await settleNetworkWidgets(tester);

    // Home, with the marker every demo page carries.
    expect(find.byKey(const ValueKey('demo-banner')), findsOneWidget);
    expect(find.text(l10n.demoBanner), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);

    // Project overview with its README.
    await _tap(tester, find.text('Pocket Planner').first);
    expect(
      find.textContaining('This repository is sample data'),
      findsOneWidget,
    );

    // Issue #1 and its discussion.
    await _tap(tester, find.text('議題').last);
    await _tap(
      tester,
      find.text('Tasks with an empty title can be saved').first,
    );
    expect(
      find.textContaining('The task is saved without a title.'),
      findsOneWidget,
    );
    expect(find.text('無法開啟此資源'), findsNothing);
    await _tap(tester, find.text('討論').first);
    expect(find.text('Reproduced on Android and iOS.'), findsOneWidget);
    await _back(tester);

    // Merge request !1, its changes and the diff with a review thread.
    await _tap(tester, find.text('MR').last);
    await _tap(tester, find.text('Add due dates to tasks').first);
    await _tap(tester, find.text('變更').first);
    expect(find.text('lib/task_list.dart'), findsOneWidget);
    await _tap(tester, find.text('lib/task.dart').first);
    expect(find.textContaining('final DateTime? due;'), findsOneWidget);
    expect(
      find.textContaining('Should this be a date without a time?'),
      findsOneWidget,
    );
    await _back(tester);
    await _back(tester);

    // The pipeline, a job and its coloured log.
    await _tap(tester, find.text('CI').last);
    await _tap(tester, find.text('Pipeline #41').first);
    expect(find.text('build'), findsWidgets);
    await _tap(tester, find.text('analyze').first);
    expect(find.text('No issues found! (ran in 4.2s)'), findsOneWidget);
    await _back(tester);
    await _back(tester);

    // A file, then "Explain this file with AI".
    await _tap(tester, find.text('檔案').last);
    await _tap(tester, find.text('lib').first);
    await _tap(tester, find.text('task.dart').first);
    await _tap(tester, find.byTooltip('檔案操作'));
    await _tap(tester, find.text('請 AI 解釋這個檔案'));

    // The consent names the offline demo provider and says nothing is sent.
    await _tap(tester, find.text('檢閱並同意'));
    expect(find.byKey(const ValueKey('ai-consent-demo')), findsOneWidget);
    expect(find.text(l10n.demoConsentNotice), findsOneWidget);
    expect(find.text(l10n.demoProviderName), findsWidgets);
    await _tap(tester, find.text('同意'));

    // A scripted explanation, marked as a sample.
    await tester.tap(find.text('解釋這個檔案'));
    await pumpUntil(
      tester,
      () =>
          find.text(l10n.demoAiExplain('lib/task.dart')).evaluate().isNotEmpty,
      description: 'the scripted explanation',
    );

    // Asking for a comment brings the production confirmation card.
    await tester.enterText(find.byType(TextField).last, '請在 #1 新增一則留言');
    await tester.pump();
    await tester.tap(find.byTooltip('送出'));
    await pumpUntil(
      tester,
      () => find.text('核准').evaluate().isNotEmpty,
      description: 'the confirmation card',
    );
    expect(find.text(l10n.demoAiNoteBody), findsOneWidget);
    await tester.tap(find.text('核准').last);
    await pumpUntil(
      tester,
      () => find.text(l10n.demoAiDone).evaluate().isNotEmpty,
      description: 'the scripted confirmation',
    );
    expect(
      runtime.server.requests,
      contains('POST projects/$demoPlannerId/issues/$demoDefaultIssue/notes'),
    );

    // The new comment shows on the issue.
    await _back(tester);
    await _back(tester);
    await _back(tester);
    await _tap(tester, find.text('議題').last);
    await _tap(
      tester,
      find.text('Tasks with an empty title can be saved').first,
    );
    await _tap(tester, find.text('討論').first);
    expect(find.text(l10n.demoAiNoteBody), findsOneWidget);

    expect(runtime.server.unhandled, isEmpty);
    expect(
      secure.changes,
      isEmpty,
      reason: 'the demo writes no secure storage',
    );
    expect(exits, 0);
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
