// Reporting an AI answer is not blocked in the demo: Play review checks that
// in-app AI reporting works, and a demo report holds sample data plus what
// the reviewer types. The send path reaches the in-app report sender, here a
// fake, so nothing leaves the test.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_report.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_page.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_scope.dart';
import 'package:gitlab_mobile/features/demo/demo_data.dart';
import 'package:gitlab_mobile/features/demo/demo_runtime.dart';
import 'package:gitlab_mobile/features/demo/demo_scope.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/network_boundary.dart';

import '../support/widget_settle.dart';
import 'demo_test_support.dart';

void main() {
  testWidgets('回報 on a demo answer goes to the in-app report sender', (
    tester,
  ) async {
    TestWidgetsFlutterBinding.ensureInitialized()
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    recordSecureStorage();
    final network = NoNetwork();
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = network;
    addTearDown(() => HttpOverrides.global = previousOverrides);
    phoneView(tester);
    final runtime = (await tester.runAsync(() => DemoRuntime.start(ai: true)))!;
    addTearDown(runtime.dispose);
    final ai = runtime.ai!;
    final handle = runtime.aiSessionFactory!(
      origin: AiFileOrigin(
        project: const Project(
          id: demoPlannerId,
          name: 'Pocket Planner',
          path: 'mergeline-demo/pocket-planner',
        ),
        path: 'lib/task.dart',
        sha: plannerShas.emptyList,
      ),
      session: runtime.session,
      settings: ai.settings,
      runningCount: () => 0,
    );
    addTearDown(handle.dispose);
    final posted = <AiReportFormFields>[];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: runtime.container,
        child: DemoScope(
          exit: () async {},
          child: NetworkBoundary(
            mode: NetworkBoundaryMode.demo,
            child: AiScope(
              controllers: ai,
              accountKey: runtime.account.key,
              child: MaterialApp(
                home: AiChatPage(
                  session: handle.session,
                  postReport: (fields) async => posted.add(fields),
                  buildInfo: testBuildInfo,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('檢閱並同意'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('同意'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('解釋這個檔案'));
    await pumpUntil(
      tester,
      () =>
          find.text(l10n.demoAiExplain('lib/task.dart')).evaluate().isNotEmpty,
      description: 'the scripted explanation',
    );

    await tester.tap(find.text(l10n.aiReportAction).first);
    await settleNetworkWidgets(tester);
    await tester.tap(find.text(l10n.aiReportInaccurate));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byKey(const ValueKey('ai-report-send')));
    await pumpUntil(
      tester,
      () => find.text(l10n.aiReportSent).evaluate().isNotEmpty,
      description: 'the report-sent notice',
    );

    expect(posted, hasLength(1));
    expect(
      network.attempts,
      0,
      reason: 'the fake sender stands in for the form post',
    );
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
