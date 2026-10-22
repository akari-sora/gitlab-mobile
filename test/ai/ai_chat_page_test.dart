import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_page.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_message_body.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

final class _FakeSession extends ChangeNotifier implements AiChatSession {
  _FakeSession({
    AiChatOrigin? origin,
    this.items = const [],
    this.phase = AiChatPhase.idle,
    this.blocker = AiChatBlocker.none,
    List<AiProviderConfig>? providers,
  }) : origin = origin ?? _mergeRequest,
       providers = providers ?? [_provider('one'), _provider('two')];

  @override
  final String id = 'synthetic';
  @override
  final AiChatOrigin origin;
  @override
  List<AiChatItem> items;
  @override
  AiChatPhase phase;
  @override
  AiChatBlocker blocker;
  @override
  final List<AiProviderConfig> providers;
  @override
  AiProviderConfig? get provider => providers.firstOrNull;
  @override
  AiConsentContract? consentRequest;
  @override
  UserFacingFailure? failure;
  @override
  AiRunEnd? lastEnd;
  @override
  bool offerNewConversation = false;
  @override
  bool get historySaved => false;
  @override
  bool get canSend =>
      blocker == AiChatBlocker.none && phase == AiChatPhase.idle;

  final sent = <String>[];
  var stops = 0;
  var rechecks = 0;
  var newConversations = 0;
  final used = <String>[];
  Future<bool> Function()? cleartext;

  @override
  Future<void> send(String text) async => sent.add(text);
  @override
  void stop() => stops++;
  @override
  void startNewConversation() => newConversations++;
  @override
  Future<void> useProvider(String providerId) async => used.add(providerId);
  @override
  Future<void> recheck() async => rechecks++;
  @override
  set confirmCleartext(Future<bool> Function()? callback) =>
      cleartext = callback;
  @override
  String displaySafe(String text) =>
      text.replaceAll('synthetic-secret', '[REDACTED]');

  void update(void Function() change) {
    change();
    notifyListeners();
  }
}

final _project = Project(
  id: 3,
  name: 'Example',
  path: 'team/example',
  visibility: 'private',
  defaultBranch: 'main',
  archived: false,
);

final _mergeRequest = AiWorkItemOrigin(
  project: _project,
  kind: AiWorkItemKind.mergeRequest,
  iid: 44,
  title: 'Synthetic change',
);

AiProviderConfig _provider(String id) => AiProviderConfig(
  id: id,
  name: 'Provider $id',
  presetId: 'custom',
  baseUrl: 'https://provider.example/v1',
  format: AiFormat.chatCompletions,
  model: 'model-$id',
  authStyle: AiAuthStyle.bearer,
  caps: const AiCaps(tokenLimitField: AiTokenLimitField.maxTokens),
  allowLanCleartext: false,
  toolsEnabled: true,
  recipientRevision: 1,
);

Widget _host(Widget child, {String tag = 'zh-TW', double scale = 1}) {
  final locale = switch (tag) {
    'ar' => const Locale('ar'),
    'en' => const Locale('en'),
    _ => const Locale('zh', 'TW'),
  };
  return MaterialApp(
    theme: appTheme(Brightness.light),
    locale: locale,
    supportedLocales: const [Locale('zh', 'TW'), Locale('ar'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: child,
  );
}

List<AiChatItem> _conversation() => [
  AiUserItem(
    text: 'What changed?',
    chips: const [
      AiContextChip(
        source: 'merge_request',
        resource: '!44',
        preview: 'diff --git a/synthetic b/synthetic',
        sizeChars: 1234,
      ),
      AiContextChip(source: '.env', preview: '', sizeChars: 0, blocked: true),
    ],
  ),
  const AiToolRunItem(
    name: 'read_file',
    argsPreview: 'lib/main.dart',
    status: AiToolRunStatus.completed,
    sizeChars: 512,
    provenance: 'team/example · a1b2c3d',
    resultExcerpt: 'void main() {}',
  ),
  const AiToolRunItem(
    name: 'get_job_log',
    argsPreview: 'job 9',
    status: AiToolRunStatus.running,
    sizeChars: 0,
    provenance: '',
  ),
  const AiNoticeItem(AiNoticeKind.redacted, count: 2),
  const AiAssistantItem(
    text: 'It renames **one** file.',
    state: AiAssistantState.done,
  ),
];

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  testWidgets('a finished work-item answer can append to its draft once', (
    tester,
  ) async {
    const answer = AiAssistantItem(
      text: ' **Answer**\n',
      state: AiAssistantState.done,
    );
    final session = _FakeSession(items: [answer]);
    final inserted = <String>[];
    final pending = Completer<void>();
    await tester.pumpWidget(
      _host(
        AiChatPage(
          session: session,
          onInsertDraft: (text) {
            inserted.add(text);
            return pending.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.aiChatInsertDraft));
    await tester.pump();
    expect(inserted, [answer.text]);
    expect(session.sent, isEmpty);
    expect(find.text(l10n.aiChatInsertDraft), findsNothing);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiChatInsertDraft), findsOneWidget);
  });

  for (final state in AiAssistantState.values.where(
    (s) => s != AiAssistantState.done,
  )) {
    testWidgets('no draft action for ${state.name} answers', (tester) async {
      final session = _FakeSession(
        items: [AiAssistantItem(text: 'partial', state: state)],
      );
      await tester.pumpWidget(
        _host(
          AiChatPage(
            session: session,
            onInsertDraft: (_) async {
              fail('An incomplete answer must not open a draft');
            },
          ),
        ),
      );
      await tester.pump();
      expect(find.text(l10n.aiChatInsertDraft), findsNothing);
    });
  }

  testWidgets('a general conversation cannot insert a resource comment', (
    tester,
  ) async {
    final session = _FakeSession(
      origin: const AiGeneralOrigin(),
      items: const [
        AiAssistantItem(text: 'answer', state: AiAssistantState.done),
      ],
    );
    await tester.pumpWidget(
      _host(AiChatPage(session: session, onInsertDraft: (_) async {})),
    );
    await tester.pump();
    expect(find.text(l10n.aiChatInsertDraft), findsNothing);
  });

  group('blockers show their action', () {
    final cases = <AiChatBlocker, String?>{
      AiChatBlocker.noProvider: 'aiAddProvider',
      AiChatBlocker.keyMissing: 'aiChatOpenSettings',
      AiChatBlocker.settingsUnavailable: 'aiChatOpenSettings',
      AiChatBlocker.consentRequired: 'aiChatReviewConsent',
      AiChatBlocker.contextUnavailable: 'retryAction',
      AiChatBlocker.tooManyRunning: null,
      AiChatBlocker.settingsLoading: null,
    };
    for (final MapEntry(key: blocker, value: action) in cases.entries) {
      testWidgets(blocker.name, (tester) async {
        final session = _FakeSession(blocker: blocker);
        await tester.pumpWidget(_host(AiChatPage(session: session)));
        await tester.pump();

        expect(find.byKey(const ValueKey('ai-chat-blocker')), findsOneWidget);
        final label = switch (action) {
          'aiAddProvider' => l10n.aiAddProvider,
          'aiChatOpenSettings' => l10n.aiChatOpenSettings,
          'aiChatReviewConsent' => l10n.aiChatReviewConsent,
          'retryAction' => l10n.retryAction,
          _ => null,
        };
        if (label == null) {
          expect(find.byType(FilledButton), findsNothing);
        } else {
          expect(find.widgetWithText(FilledButton, label), findsOneWidget);
        }
        // Nothing can be sent while blocked.
        await tester.enterText(
          find.byKey(const ValueKey('ai-chat-input')),
          'hello',
        );
        await tester.pump();
        final send = tester.widget<IconButton>(
          find.byKey(const ValueKey('ai-chat-send')),
        );
        expect(send.onPressed, isNull);
      });
    }

    testWidgets('a context failure retries through recheck', (tester) async {
      final session = _FakeSession(blocker: AiChatBlocker.contextUnavailable)
        ..failure = const AiFailure(AiFailureKind.network);
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pump();

      expect(find.text(l10n.aiNetworkTitle), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, l10n.retryAction));
      expect(session.rechecks, 1);
    });
  });

  testWidgets('an empty merge request chat offers its suggestions', (
    tester,
  ) async {
    final session = _FakeSession();
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(find.text(l10n.aiChatEmpty), findsOneWidget);
    await tester.tap(find.text(l10n.aiSuggestMrSummary));
    await tester.pump();
    expect(session.sent, [l10n.aiSuggestMrSummary]);
  });

  testWidgets('AI summary sends once, when the session is ready', (
    tester,
  ) async {
    final session = _FakeSession(
      origin: AiWorkItemOrigin(
        project: _project,
        kind: AiWorkItemKind.mergeRequest,
        iid: 44,
        title: 'Synthetic change',
        summarize: true,
      ),
      blocker: AiChatBlocker.settingsLoading,
    );
    await tester.pumpWidget(
      _host(AiChatPage(session: session, summarize: true)),
    );
    await tester.pump();
    expect(session.sent, isEmpty);

    session.update(() => session.blocker = AiChatBlocker.none);
    await tester.pump();
    expect(session.sent, [l10n.aiSuggestMrSummary]);
    session.update(() {});
    await tester.pump();
    expect(session.sent, hasLength(1));
  });

  testWidgets('the composer sends, clears and turns into stop', (tester) async {
    final session = _FakeSession();
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();
    final sendFinder = find.byKey(const ValueKey('ai-chat-send'));
    expect(tester.widget<IconButton>(sendFinder).onPressed, isNull);

    await tester.enterText(
      find.byKey(const ValueKey('ai-chat-input')),
      '  why?  ',
    );
    await tester.pump();
    await tester.tap(sendFinder);
    await tester.pump();
    expect(session.sent, ['why?']);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
          .controller!
          .text,
      isEmpty,
    );

    session.update(() => session.phase = AiChatPhase.running);
    await tester.pump();
    expect(sendFinder, findsNothing);
    await tester.tap(find.byKey(const ValueKey('ai-chat-stop')));
    expect(session.stops, 1);
    expect(find.text(l10n.aiChatThinking), findsNothing);
  });

  testWidgets('a conversation shows messages, chips, tools and notices', (
    tester,
  ) async {
    final session = _FakeSession(items: _conversation());
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(find.text('What changed?'), findsOneWidget);
    expect(find.textContaining(l10n.aiChatCharacters('1234')), findsOneWidget);
    expect(find.textContaining(l10n.aiChatBlocked), findsOneWidget);
    expect(find.textContaining(l10n.aiToolReadFile), findsOneWidget);
    expect(find.textContaining(l10n.aiToolGetJobLog), findsOneWidget);
    expect(find.text(l10n.aiNoticeRedacted('2')), findsOneWidget);
    expect(find.text(l10n.aiChatCopy), findsOneWidget);

    // The chip shows what was actually sent.
    await tester.tap(find.textContaining(l10n.aiChatCharacters('1234')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(l10n.aiChatSentContent), findsOneWidget);
    expect(find.text('diff --git a/synthetic b/synthetic'), findsOneWidget);
  });

  testWidgets('an expanded tool row stays expanded as the reply grows', (
    tester,
  ) async {
    final items = _conversation().sublist(0, 2);
    final session = _FakeSession(items: items);
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    await tester.tap(find.textContaining(l10n.aiToolReadFile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('void main() {}'), findsOneWidget);

    session.update(
      () => session.items = [
        ...items,
        const AiAssistantItem(text: 'More', state: AiAssistantState.done),
        AiUserItem(text: 'next'),
      ],
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('void main() {}'), findsOneWidget);
  });

  testWidgets('copy all puts the whole reply on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final session = _FakeSession(items: _conversation());
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    await tester.tap(find.text(l10n.aiChatCopy));
    await tester.pump();
    expect(copied, 'It renames **one** file.');
    expect(find.text(l10n.aiChatCopied), findsOneWidget);
  });

  testWidgets('a streaming reply has no copy action yet', (tester) async {
    final session = _FakeSession(
      items: [
        AiUserItem(text: 'go'),
        const AiAssistantItem(
          text: 'Partial',
          state: AiAssistantState.streaming,
        ),
      ],
      phase: AiChatPhase.running,
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(find.text(l10n.aiChatCopy), findsNothing);
    expect(find.text(l10n.aiChatThinking), findsNothing);
  });

  testWidgets('an interrupted reply says it is not kept', (tester) async {
    final session = _FakeSession(
      items: [
        AiUserItem(text: 'go'),
        const AiAssistantItem(
          text: 'Partial',
          state: AiAssistantState.interrupted,
        ),
      ],
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(find.text(l10n.aiChatInterrupted), findsOneWidget);
  });

  testWidgets('a run end and a failure are shown below the reply', (
    tester,
  ) async {
    final session = _FakeSession(items: _conversation())
      ..lastEnd = AiRunEnd.maxTokens
      ..failure = const AiFailure(AiFailureKind.server)
      ..offerNewConversation = true;
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(find.text(l10n.aiEndOutputLimit), findsOneWidget);
    expect(find.text(l10n.aiServerTitle), findsOneWidget);
    await tester.tap(
      find.widgetWithText(FilledButton, l10n.aiChatNewConversation),
    );
    expect(session.newConversations, 1);
  });

  testWidgets('switching provider asks first when there is a conversation', (
    tester,
  ) async {
    final session = _FakeSession(items: _conversation());
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    Future<void> settle() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    await tester.tap(find.byKey(const ValueKey('ai-chat-menu')));
    await settle();
    await tester.tap(find.text('Provider two · model-two').last);
    await settle();
    expect(find.text(l10n.aiChatSwitchProviderDetail), findsOneWidget);
    await tester.tap(find.text(l10n.confirmAction));
    await settle();
    expect(session.used, ['two']);
  });

  testWidgets('the page asks before a cleartext send while it is open', (
    tester,
  ) async {
    final session = _FakeSession();
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();
    expect(session.cleartext, isNotNull);

    final answer = session.cleartext!();
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiChatCleartextTitle), findsOneWidget);
    await tester.tap(find.text(l10n.cancelAction));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);

    await tester.pumpWidget(_host(const SizedBox()));
    expect(session.cleartext, isNull);
  });

  testWidgets('a progress row shows while the conversation gets ready', (
    tester,
  ) async {
    final session = _FakeSession(phase: AiChatPhase.preparing);
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(find.byKey(const ValueKey('ai-chat-preparing')), findsOneWidget);
    expect(find.text(l10n.aiChatPreparing), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-chat-blocker')), findsNothing);
    final chip = tester.widget<ActionChip>(
      find.widgetWithText(ActionChip, l10n.aiSuggestMrSummary),
    );
    expect(chip.onPressed, isNull);

    session.update(() => session.phase = AiChatPhase.idle);
    await tester.pump();
    expect(find.byKey(const ValueKey('ai-chat-preparing')), findsNothing);
  });

  testWidgets('a snack bar shown elsewhere stays off the chat', (tester) async {
    final session = _FakeSession();
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('synthetic notice'),
                      duration: Duration(days: 1),
                    ),
                  );
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => AiChatPage(session: session),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(AiChatPage), findsOneWidget);
    expect(find.text('synthetic notice'), findsNothing);
  });

  testWidgets('chips name their page and the sheet shows the full path', (
    tester,
  ) async {
    final session = _FakeSession(
      origin: AiFileOrigin(project: _project, path: 'lib/a/b.dart', sha: 'a1'),
      items: [
        AiUserItem(
          text: 'Explain',
          chips: const [
            AiContextChip(
              source: 'file',
              resource: 'lib/a/b.dart',
              preview: 'void b() {}',
              sizeChars: 11,
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(
      find.text('b.dart · ${l10n.aiChatCharacters('11')}'),
      findsOneWidget,
    );
    expect(find.textContaining('file ·'), findsNothing);
    await tester.tap(find.textContaining('b.dart ·'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('lib/a/b.dart'), findsOneWidget);
  });

  testWidgets('a tool row names what it read before it is expanded', (
    tester,
  ) async {
    final session = _FakeSession(items: _conversation());
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(find.text('${l10n.aiToolReadFile} · lib/main.dart'), findsOneWidget);
    expect(
      find.text('${l10n.aiToolCompleted} · ${l10n.aiChatCharacters('512')}'),
      findsOneWidget,
    );
  });

  testWidgets('an empty streaming reply says it is thinking, once', (
    tester,
  ) async {
    final session = _FakeSession(
      items: [
        AiUserItem(text: 'go'),
        const AiToolRunItem(
          name: 'read_file',
          argsPreview: 'pubspec.yaml',
          status: AiToolRunStatus.completed,
          sizeChars: 10,
          provenance: '',
        ),
        const AiAssistantItem(text: '', state: AiAssistantState.streaming),
      ],
      phase: AiChatPhase.running,
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(find.text(l10n.aiChatThinking), findsOneWidget);
  });

  testWidgets('the menu opens AI settings', (tester) async {
    final session = _FakeSession();
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('ai-chat-menu')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(l10n.aiChatOpenSettings), findsOneWidget);
  });

  testWidgets('a kept session opened for discussion does not summarize', (
    tester,
  ) async {
    // The session was first opened from "AI summary"; this visit is not.
    final session = _FakeSession(
      origin: AiWorkItemOrigin(
        project: _project,
        kind: AiWorkItemKind.mergeRequest,
        iid: 44,
        title: 'Synthetic change',
        summarize: true,
      ),
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();
    session.update(() {});
    await tester.pump();
    expect(session.sent, isEmpty);
  });

  testWidgets('a summary visit to a conversation offers the request', (
    tester,
  ) async {
    final session = _FakeSession(
      items: [
        AiUserItem(text: 'earlier'),
        const AiAssistantItem(text: 'reply', state: AiAssistantState.done),
      ],
    );
    await tester.pumpWidget(
      _host(AiChatPage(session: session, summarize: true)),
    );
    await tester.pump();

    expect(session.sent, isEmpty);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('ai-chat-input')))
          .controller!
          .text,
      l10n.aiSuggestMrSummary,
    );
  });

  testWidgets('the sending page is the one asked about cleartext', (
    tester,
  ) async {
    final session = _FakeSession();
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();
    // Another page on the same session closed and cleared the callback.
    session.confirmCleartext = null;
    expect(session.cleartext, isNull);

    await tester.enterText(find.byKey(const ValueKey('ai-chat-input')), 'go');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
    await tester.pump();
    expect(session.sent, ['go']);
    expect(session.cleartext, isNotNull);
  });

  testWidgets('the title shows GitLab values only after cleaning', (
    tester,
  ) async {
    final session = _FakeSession(
      origin: AiWorkItemOrigin(
        project: _project,
        kind: AiWorkItemKind.mergeRequest,
        iid: 44,
        title: 'Rotate synthetic-secret now',
      ),
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(find.text('!44 Rotate [REDACTED] now'), findsOneWidget);
    expect(find.textContaining('synthetic-secret'), findsNothing);
  });

  test('a title that cannot be checked falls back to the assistant', () {
    String hidden(String _) => '';
    for (final origin in [
      _mergeRequest,
      AiJobOrigin(project: _project, jobId: 7, jobName: 'build'),
      AiFileOrigin(project: _project, path: 'lib/a/b.dart', sha: 'a1'),
    ]) {
      expect(aiOriginTitle(origin, safe: hidden), l10n.aiAssistantLabel);
    }
    expect(
      aiOriginTitle(_mergeRequest, safe: (text) => text),
      contains('Synthetic change'),
    );
  });

  testWidgets('a GitLab read failure uses the app notice with retry', (
    tester,
  ) async {
    final session = _FakeSession(blocker: AiChatBlocker.contextUnavailable)
      ..failure = const ApiFailure(FailureKind.invisible, status: 404);
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(find.byType(FailureNotice), findsOneWidget);
    expect(find.textContaining('!44 Synthetic change'), findsWidgets);
    await tester.tap(find.text(l10n.refreshAction));
    expect(session.rechecks, 1);
  });

  testWidgets('what was sent shows the whole text in pieces', (tester) async {
    final lines = List.generate(600, (i) => 'line $i of the synthetic file');
    final session = _FakeSession(
      items: [
        AiUserItem(
          text: 'Explain',
          chips: [
            AiContextChip(
              source: 'file',
              resource: 'lib/a.dart',
              preview: lines.first,
              sentText: lines.join('\n'),
              sizeChars: lines.join('\n').length,
              pinnedSha: 'a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2',
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();
    await tester.tap(find.textContaining('a.dart ·'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byKey(const ValueKey('ai-chat-sent')), findsOneWidget);
    expect(find.textContaining(l10n.pinnedAtSha('a1b2c3d4')), findsOneWidget);
    expect(find.text(l10n.aiChatSentPreviewOnly), findsNothing);
    await tester.dragUntilVisible(
      find.textContaining('line 599 of the synthetic file'),
      find.byKey(const ValueKey('ai-chat-sent')),
      const Offset(0, -600),
    );
    expect(
      find.textContaining('line 599 of the synthetic file'),
      findsOneWidget,
    );
  });

  testWidgets('a restored chip says only its start was kept', (tester) async {
    final session = _FakeSession(
      items: [
        AiUserItem(
          text: 'Explain',
          chips: const [
            AiContextChip(source: 'file', preview: 'start', sizeChars: 900),
          ],
        ),
      ],
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();
    await tester.tap(find.textContaining('file ·'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text(l10n.aiChatSentPreviewOnly), findsOneWidget);
  });

  testWidgets('a tool name the app does not know gets a generic label', (
    tester,
  ) async {
    final session = _FakeSession(
      items: [
        AiUserItem(text: 'go'),
        const AiToolRunItem(
          name: '',
          argsPreview: '',
          status: AiToolRunStatus.failed,
          sizeChars: 0,
          provenance: '',
        ),
        const AiToolRunItem(
          name: 'Read file · README.md',
          argsPreview: '',
          status: AiToolRunStatus.failed,
          sizeChars: 0,
          provenance: '',
        ),
      ],
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(find.text(l10n.aiToolUnknown), findsNWidgets(2));
    expect(find.textContaining('README.md'), findsNothing);
  });

  testWidgets('a run ending says why once', (tester) async {
    final session = _FakeSession(
      items: [
        AiUserItem(text: 'go'),
        const AiAssistantItem(text: 'Part', state: AiAssistantState.truncated),
      ],
    )..lastEnd = AiRunEnd.maxTokens;
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(find.text(l10n.aiEndOutputLimit), findsOneWidget);
  });

  testWidgets('the new conversation notice is shown', (tester) async {
    final session = _FakeSession(
      items: [
        AiUserItem(text: 'go'),
        const AiAssistantItem(text: 'Done', state: AiAssistantState.done),
        const AiNoticeItem(AiNoticeKind.newConversation),
      ],
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();

    expect(find.text(l10n.aiNoticeNewConversation), findsOneWidget);
  });

  testWidgets('sending brings the newest content back into view', (
    tester,
  ) async {
    final session = _FakeSession(
      items: [
        for (var i = 0; i < 30; i++) ...[
          AiUserItem(text: 'question $i'),
          AiAssistantItem(
            text: 'answer $i ' * 20,
            state: AiAssistantState.done,
          ),
        ],
      ],
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey('ai-chat-list')),
      const Offset(0, 2000),
    );
    await tester.pumpAndSettle();
    final list = find.byKey(const ValueKey('ai-chat-list'));
    final position = Scrollable.of(
      tester.element(
        find.descendant(of: list, matching: find.byType(Viewport)).first,
      ),
    ).position;
    expect(position.pixels, greaterThan(0));

    await tester.enterText(find.byKey(const ValueKey('ai-chat-input')), 'next');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
    expect(session.sent, ['next']);
  });

  testWidgets('a card that appears in a scrolled empty chat comes into view', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 420);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final session = _FakeSession();
    await tester.pumpWidget(_host(AiChatPage(session: session), scale: 2));
    await tester.pump();
    final list = find.descendant(
      of: find.byType(AiChatPage),
      matching: find.byType(Scrollable),
    );
    await tester.drag(list.first, const Offset(0, -600));
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(list.first).position;
    expect(position.pixels, greaterThan(0));

    session.update(() => session.blocker = AiChatBlocker.consentRequired);
    await tester.pumpAndSettle();
    expect(position.pixels, 0);
    expect(find.byKey(const ValueKey('ai-chat-blocker')), findsOneWidget);
  });

  group('narrow screens, 2x text and long or other scripts', () {
    for (final tag in ['zh-TW', 'en', 'ar', 'de', 'ru', 'hi', 'th']) {
      testWidgets(tag, (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        useLanguage(languageForTag(tag)!);
        final session = _FakeSession(
          items: _conversation(),
          blocker: AiChatBlocker.consentRequired,
        )..lastEnd = AiRunEnd.toolBudget;
        await tester.pumpWidget(
          _host(AiChatPage(session: session), tag: tag, scale: 2),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);

        // The case that once overflowed: an empty chat with a blocker.
        final empty = _FakeSession(blocker: AiChatBlocker.consentRequired);
        await tester.pumpWidget(
          _host(AiChatPage(session: empty), tag: tag, scale: 2),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('long replies', () {
    test('splitting keeps fences whole and parts within the target', () {
      final fence =
          '```\n${List.filled(40, 'code line').join('\n')}\n\n'
          'still code\n```';
      final paragraphs = List.filled(30, 'word ' * 40).join('\n\n');
      final text = '$paragraphs\n\n$fence\n\nafter';
      final parts = splitAiMarkdown(text, target: 600);

      expect(parts.join('\n'), text);
      expect(parts.where((part) => part.contains('```')).length, 1);
      final fencePart = parts.singleWhere((part) => part.contains('```'));
      expect(fencePart, contains('still code'));
      for (final part in parts) {
        if (!part.contains('```')) {
          expect(part.length, lessThanOrEqualTo(600));
        }
      }
    });

    testWidgets('a very long reply is split, a huge block shown as text', (
      tester,
    ) async {
      final huge = 'x' * (aiMarkdownSingleViewLimit + 10);
      final text = '${'para ' * 10000}\n\n$huge';
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: SingleChildScrollView(child: AiMessageBody(text: text)),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byType(SelectableText), findsWidgets);
    });

    testWidgets('a long reply streams as plain text', (tester) async {
      final text = 'a' * (aiStreamingMarkdownLimit + 1);
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: SingleChildScrollView(
              child: AiMessageBody(text: text, streaming: true),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(SelectableText), findsOneWidget);
    });
  });
}
