import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/account_store.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
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
  List<AiChatItem> items = [];
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
  bool get reportNotSaved => false;
  @override
  AiAssistantItem? currentOf(AiAssistantItem item) =>
      items.contains(item) ? item : null;
  @override
  Future<bool> refreshSecrets() async => true;
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
  void markReported(AiAssistantItem item) {}
  @override
  set confirmCleartext(Future<bool> Function()? callback) {}
  @override
  String displaySafe(String text) => text;
  @override
  String draftSafe(String text) => text;
}

final class _Registry extends ChangeNotifier implements AiRunRegistry {
  final opened = <AiChatOrigin>[];
  String? answer;

  @override
  AiChatSession open(AiChatOrigin origin) {
    opened.add(origin);
    return _Session(origin)
      ..items = [
        if (answer != null)
          AiAssistantItem(text: answer!, state: AiAssistantState.done),
      ];
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
  SessionController? session,
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
  final owner =
      session ??
      (SessionController(SecureAccountStore())
        ..active = fixture.account
        ..api = fixture.api
        ..initializing = false);
  if (session == null) addTearDown(owner.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sessionProvider.overrideWithValue(owner)],
      child: AiScope(
        controllers: AiControllers(settings: settings, history: history),
        accountKey: fixture.account.key,
        child: AiRunRegistryScope(registry: registry, child: app),
      ),
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

/// Serves a `.env` file, a path AI never reads.
final class _SensitiveFileFixture extends WorkspaceFixture {
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final segments = request.uri.pathSegments;
    final path = segments.skip(segments.indexOf('v4') + 1).join('/');
    if (path == 'projects/42/repository/files/.env' &&
        request.method == 'HEAD') {
      return ResponseBody.fromString(
        '',
        200,
        headers: {
          'x-gitlab-size': ['10'],
          'x-gitlab-last-commit-id': [WorkspaceFixture.sha],
        },
      );
    }
    if (path == 'projects/42/repository/files/.env/raw') {
      return ResponseBody.fromString('NAME=value\n', 200);
    }
    return super.respond(request);
  }
}

/// The draft check runs on another isolate, which takes real time.
Future<void> _waitForPreview(WidgetTester tester) async {
  for (
    var tries = 0;
    tries < 100 && find.text(l10n.aiDraftPreviewTitle).evaluate().isEmpty;
    tries++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> _openMenu(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  testWidgets('MR answer opens its ordinary local comment draft without POST', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final registry = (await _pump(
      tester,
      fixture,
      WorkItemPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'merge_requests',
        iid: 12,
      ),
    ))!;
    registry.answer = 'Synthetic **answer**';
    await _openMenu(tester, l10n.moreOptions);
    await tester.tap(find.text(l10n.aiDiscuss));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.aiChatInsertDraft));
    await _waitForPreview(tester);
    // The preview opens first and writes nothing.
    expect(find.text(l10n.aiDraftPreviewTitle), findsOneWidget);
    expect(find.byType(ResourceEditor), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ai-draft-confirm')));
    await tester.pumpAndSettle();
    expect(find.byType(ResourceEditor), findsOneWidget);
    final editor = tester.widget<ResourceEditor>(find.byType(ResourceEditor));
    expect(editor.resource, 'projects/42/merge_requests/12/root/new');
    expect(editor.account.key, fixture.account.key);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      registry.answer,
    );
    expect(fixture.adapter.requests.where((r) => r.method != 'GET'), isEmpty);
    await tester.tap(find.byTooltip(l10n.keepDraftAndGoBack));
    await tester.pumpAndSettle();
    expect(find.byType(AiChatPage), findsOneWidget);
    expect(fixture.adapter.requests.where((r) => r.method != 'GET'), isEmpty);
  });

  testWidgets('the draft target reads the saved draft and the issue as loaded now', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    const waiting = 'Stack trace:\n```\nat Foo.bar()';
    FlutterSecureStorage.setMockInitialValues({
      'draft.v2.${base64Url.encode(utf8.encode(fixture.account.key))}.'
              '${base64Url.encode(utf8.encode('projects/42/issues/12/root/new'))}':
          jsonEncode({'body': waiting}),
    });
    fixture.issues[12] =
        fixture.issue(12, 'Synthetic issue', confidential: true);
    final registry = (await _pump(
      tester,
      fixture,
      WorkItemPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'issues',
        iid: 12,
      ),
    ))!;
    registry.answer = 'Answer';
    await _openMenu(tester, l10n.moreOptions);
    await tester.tap(find.text(l10n.aiDiscuss));
    await tester.pumpAndSettle();
    final target = tester.widget<AiChatPage>(find.byType(AiChatPage)).draftTarget!;
    expect(target.confidential(), isTrue);
    expect(await target.existingText(), waiting);
    // The preview is told about the waiting draft through the same key.
    await tester.tap(find.text(l10n.aiChatInsertDraft));
    await _waitForPreview(tester);
    expect(find.byKey(const ValueKey('ai-draft-after-existing')), findsOne);
    await tester.tap(find.text(l10n.cancelAction));
    await tester.pumpAndSettle();
    // The issue is made public and the page reloads while this target lives.
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pumpAndSettle();
    fixture.issues[12] = fixture.issue(12, 'Synthetic issue');
    await tester.tap(find.byTooltip(l10n.refreshAction));
    await settleNetworkWidgets(tester);
    expect(target.confidential(), isFalse);
  });

  testWidgets('a merge request is never a confidential target', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await _pump(
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
    await tester.tap(find.text(l10n.aiDiscuss));
    await tester.pumpAndSettle();
    final target = tester.widget<AiChatPage>(find.byType(AiChatPage)).draftTarget!;
    expect(target.confidential(), isFalse);
  });

  testWidgets('a changed session generation cannot insert an old AI answer', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final fixture = WorkspaceFixture();
    final owner = SessionController(SecureAccountStore())
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    fixture.issues[12] = fixture.issue(12, 'Synthetic issue');
    addTearDown(owner.dispose);
    final registry = (await _pump(
      tester,
      fixture,
      WorkItemPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'issues',
        iid: 12,
      ),
      session: owner,
    ))!;
    registry.answer = 'Old generation answer';
    await _openMenu(tester, l10n.moreOptions);
    await tester.tap(find.text(l10n.aiDiscuss));
    await tester.pumpAndSettle();
    owner.generation++;
    await tester.tap(find.text(l10n.aiChatInsertDraft));
    await _waitForPreview(tester);
    await tester.tap(find.byKey(const ValueKey('ai-draft-confirm')));
    await tester.pumpAndSettle();
    expect(find.byType(ResourceEditor), findsNothing);
    expect(await const FlutterSecureStorage().readAll(), isEmpty);
    expect(
      fixture.adapter.requests.where(
        (r) => r.method != 'GET' && r.uri != fixture.api.instance.graphQL,
      ),
      isEmpty,
    );
  });

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
    // The summary is this visit's request, handed to the page.
    final page = tester.widget<AiChatPage>(find.byType(AiChatPage));
    expect(page.summarize, isTrue);

    // Closing the page lets the registry drop a session that holds nothing.
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(registry.released, [page.session]);
  });

  testWidgets('a discussion visit does not ask for a summary', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await _pump(
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
    await tester.tap(find.text(l10n.aiDiscuss));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester.widget<AiChatPage>(find.byType(AiChatPage)).summarize,
      isFalse,
    );
  });

  testWidgets('without AI a merge request has no AI entries', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await _pump(
      tester,
      fixture,
      WorkItemPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        resource: 'merge_requests',
        iid: 12,
      ),
      ai: false,
    );

    await _openMenu(tester, l10n.moreOptions);
    expect(find.text(l10n.aiDiscuss), findsNothing);
    expect(find.text(l10n.aiSummarize), findsNothing);
  });

  testWidgets('without AI a file has no explanation entry', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await _pump(
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
      ai: false,
    );

    await _openMenu(tester, l10n.fileActions);
    expect(find.text(l10n.aiExplainFile), findsNothing);
  });

  testWidgets('a sensitive file has no explanation entry', (tester) async {
    final fixture = _SensitiveFileFixture();
    addTearDown(fixture.api.close);
    await _pump(
      tester,
      fixture,
      RepositoryFilePage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        branch: 'main',
        sha: WorkspaceFixture.sha,
        filePath: '.env',
      ),
    );

    await _openMenu(tester, l10n.fileActions);
    expect(find.text(l10n.fileHistory), findsOneWidget);
    expect(find.text(l10n.aiExplainFile), findsNothing);
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
