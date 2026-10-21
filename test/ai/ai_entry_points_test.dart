import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_page.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_scope.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import '../support/fake_adapter.dart';
import '../support/widget_settle.dart';
import '../support/workspace_fixture.dart';

final class _Session extends ChangeNotifier implements AiChatSession {
  _Session(this.origin);

  @override
  final AiChatOrigin origin;
  @override
  String get id => origin.key;
  @override
  List<AiChatItem> get items => const [];
  @override
  AiChatPhase get phase => AiChatPhase.idle;
  @override
  AiChatBlocker get blocker => AiChatBlocker.noProvider;
  @override
  List<AiProviderConfig> get providers => const [];
  @override
  AiProviderConfig? get provider => null;
  @override
  AiConsentContract? get consentRequest => null;
  @override
  AiFailure? get failure => null;
  @override
  AiRunEnd? get lastEnd => null;
  @override
  bool get offerNewConversation => false;
  @override
  bool get historySaved => false;
  @override
  bool get canSend => false;
  @override
  Future<void> send(String text) async {}
  @override
  void stop() {}
  @override
  void startNewConversation() {}
  @override
  Future<void> useProvider(String providerId) async {}
  @override
  Future<void> recheck() async {}
  @override
  set confirmCleartext(Future<bool> Function()? callback) {}
  @override
  String displaySafe(String text) => text;
}

final class _Registry extends ChangeNotifier implements AiRunRegistry {
  final opened = <AiChatOrigin>[];

  @override
  AiChatSession open(AiChatOrigin origin) {
    opened.add(origin);
    return _Session(origin);
  }

  final released = <AiChatSession>[];

  @override
  void release(AiChatSession session) => released.add(session);

  @override
  int get runningCount => 0;
}

/// AI sits above the app, as in AuthenticatedApp, so pushed routes see it.
Future<_Registry?> _pump(
  WidgetTester tester,
  WorkspaceFixture fixture,
  Widget page, {
  bool ai = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final app = MaterialApp(
    theme: appTheme(Brightness.light),
    locale: const Locale('zh', 'TW'),
    supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: page,
  );
  if (!ai) {
    await tester.pumpWidget(app);
    await settleNetworkWidgets(tester);
    return null;
  }
  final store = MemoryAiStore();
  final settings = AiSettingsController(store);
  final history = AiHistoryCoordinator(store: store);
  addTearDown(settings.dispose);
  addTearDown(history.dispose);
  final registry = _Registry();
  addTearDown(registry.dispose);
  await tester.pumpWidget(
    AiScope(
      controllers: AiControllers(settings: settings, history: history),
      accountKey: fixture.account.key,
      child: AiRunRegistryScope(registry: registry, child: app),
    ),
  );
  await settleNetworkWidgets(tester);
  return registry;
}

final class _FailedJobFixture extends WorkspaceFixture {
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final segments = request.uri.pathSegments;
    final path = segments.skip(segments.indexOf('v4') + 1).join('/');
    if (path == 'projects/42/jobs/601') {
      return jsonResponse(job(601, status: 'failed'));
    }
    return super.respond(request);
  }
}

Future<void> _openMenu(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  testWidgets('a failed job offers AI in its app bar', (tester) async {
    final fixture = _FailedJobFixture();
    addTearDown(fixture.api.close);
    final registry = await _pump(
      tester,
      fixture,
      JobLogPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        id: 601,
      ),
    );

    await tester.tap(find.byKey(const ValueKey('job-ai')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AiChatPage), findsOneWidget);
    final origin = registry!.opened.single as AiJobOrigin;
    expect(
      (origin.jobId, origin.jobName, origin.project.id),
      (601, 'Flutter tests', 42),
    );
  });

  testWidgets('another job offers AI in its menu only', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await _pump(
      tester,
      fixture,
      JobLogPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        id: 501,
      ),
    );

    expect(find.byKey(const ValueKey('job-ai')), findsNothing);
    await _openMenu(tester, l10n.jobActions);
    expect(find.text(l10n.aiDiscuss), findsOneWidget);
  });

  testWidgets('without AI no page shows an AI entry', (tester) async {
    final fixture = _FailedJobFixture();
    addTearDown(fixture.api.close);
    await _pump(
      tester,
      fixture,
      JobLogPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        id: 601,
      ),
      ai: false,
    );

    expect(find.byKey(const ValueKey('job-ai')), findsNothing);
    await _openMenu(tester, l10n.jobActions);
    expect(find.text(l10n.aiDiscuss), findsNothing);
  });

  testWidgets('a merge request offers an AI summary and a discussion', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final registry = await _pump(
      tester,
      fixture,
      WorkItemPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'merge_requests',
        iid: 12,
      ),
    );

    await _openMenu(tester, l10n.moreOptions);
    expect(find.text(l10n.aiDiscuss), findsOneWidget);
    await tester.tap(find.text(l10n.aiSummarize));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final origin = registry!.opened.single as AiWorkItemOrigin;
    expect(origin.kind, AiWorkItemKind.mergeRequest);
    expect(origin.iid, 12);
    expect(origin.summarize, isTrue);
    expect(origin.title, 'Improve private-project navigation');
  });

  testWidgets('an issue offers a discussion but no summary', (tester) async {
    final fixture = WorkspaceFixture();
    fixture.issues[3] = fixture.issue(3, 'Synthetic issue');
    addTearDown(fixture.api.close);
    final registry = await _pump(
      tester,
      fixture,
      WorkItemPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'issues',
        iid: 3,
      ),
    );

    await _openMenu(tester, l10n.moreOptions);
    expect(find.text(l10n.aiSummarize), findsNothing);
    await tester.tap(find.text(l10n.aiDiscuss));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final origin = registry!.opened.single as AiWorkItemOrigin;
    expect(
      (origin.kind, origin.iid, origin.summarize),
      (AiWorkItemKind.issue, 3, false),
    );
  });

  testWidgets('a text file at a commit offers an explanation', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final registry = await _pump(
      tester,
      fixture,
      RepositoryFilePage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        branch: 'main',
        sha: WorkspaceFixture.sha,
        filePath: 'README.md',
      ),
    );

    await _openMenu(tester, l10n.fileActions);
    await tester.tap(find.text(l10n.aiExplainFile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final origin = registry!.opened.single as AiFileOrigin;
    expect((origin.path, origin.sha), ('README.md', WorkspaceFixture.sha));
  });
}
