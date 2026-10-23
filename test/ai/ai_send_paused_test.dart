import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_page.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

/// A ready conversation whose sends wait for the account's GitLab budget.
/// Like the controller, the block is read live: a stated wait that has
/// passed no longer blocks.
final class _GatedSession extends ChangeNotifier
    implements AiChatSession, AiChatSendGate {
  _GatedSession({this.reason, this.until});

  AiChatSendBlockReason? reason;
  DateTime? until;

  @override
  AiChatSendBlockReason? get sendBlockReason {
    final until = this.until;
    if (until != null && !until.isAfter(DateTime.now())) return null;
    return reason;
  }

  @override
  DateTime? get sendBlockedUntil => until;

  void update(void Function() change) {
    change();
    notifyListeners();
  }

  @override
  final String id = 'synthetic';
  @override
  final AiChatOrigin origin = AiWorkItemOrigin(
    project: Project(
      id: 3,
      name: 'Example',
      path: 'team/example',
      visibility: 'private',
      defaultBranch: 'main',
      archived: false,
    ),
    kind: AiWorkItemKind.mergeRequest,
    iid: 44,
    title: 'Synthetic change',
  );
  @override
  List<AiChatItem> items = const [];
  @override
  AiChatPhase phase = AiChatPhase.idle;
  @override
  AiChatBlocker blocker = AiChatBlocker.none;
  @override
  final List<AiProviderConfig> providers = [
    AiProviderConfig(
      id: 'one',
      name: 'Provider one',
      presetId: 'custom',
      baseUrl: 'https://provider.example/v1',
      format: AiFormat.chatCompletions,
      model: 'model-one',
      authStyle: AiAuthStyle.bearer,
      caps: const AiCaps(tokenLimitField: AiTokenLimitField.maxTokens),
      allowLanCleartext: false,
      toolsEnabled: true,
      recipientRevision: 1,
    ),
  ];
  @override
  AiProviderConfig? get provider => providers.first;
  @override
  AiConsentContract? get consentRequest => null;
  @override
  UserFacingFailure? get failure => null;
  @override
  AiRunEnd? get lastEnd => null;
  @override
  bool get offerNewConversation => false;
  @override
  bool get historySaved => false;
  @override
  bool get reportNotSaved => false;
  @override
  bool get canSend =>
      blocker == AiChatBlocker.none &&
      phase == AiChatPhase.idle &&
      sendBlockReason == null;

  final sent = <String>[];
  @override
  Future<void> send(String text) async => sent.add(text);
  @override
  void markReported(AiAssistantItem item) {}
  @override
  AiAssistantItem? currentOf(AiAssistantItem item) => item;
  @override
  Future<bool> refreshSecrets() async => true;
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
  @override
  String draftSafe(String text) => text;
}

Widget _host(Widget child, {Locale locale = const Locale('zh', 'TW')}) =>
    MaterialApp(
      theme: appTheme(Brightness.light),
      locale: locale,
      supportedLocales: const [Locale('zh', 'TW'), Locale('de'), Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: child,
    );

Finder get _card => find.byKey(const ValueKey('ai-chat-send-paused'));

IconButton _sendButton(WidgetTester tester) => tester.widget<IconButton>(
  find.byKey(const ValueKey('ai-chat-send')),
);

void main() {
  testWidgets('a critical budget says sending is paused and for how long', (
    tester,
  ) async {
    final session = _GatedSession(
      reason: AiChatSendBlockReason.criticalRateBudget,
      until: DateTime.now().add(const Duration(minutes: 3, seconds: 5)),
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.enterText(
      find.byKey(const ValueKey('ai-chat-input')),
      'Why did the pipeline fail?',
    );
    await tester.pump();

    expect(_card, findsOneWidget);
    expect(find.text(l10n.aiSendPausedBudget), findsOneWidget);
    expect(find.text(l10n.cacheResumesInMinutes(4)), findsOneWidget);
    // The typed question stays in the field; the button is off.
    expect(_sendButton(tester).onPressed, isNull);
    expect(find.text('Why did the pipeline fail?'), findsOneWidget);
  });

  testWidgets('a cooldown without a stated time says when it resumes', (
    tester,
  ) async {
    final session = _GatedSession(
      reason: AiChatSendBlockReason.serverCooldown,
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));

    expect(find.text(l10n.aiSendPausedRateLimited), findsOneWidget);
    expect(find.text(l10n.aiSendResumesAfterReset), findsOneWidget);
  });

  testWidgets('held run leases name the running conversations', (
    tester,
  ) async {
    final session = _GatedSession(
      reason: AiChatSendBlockReason.runBudgetUnavailable,
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));

    expect(
      find.text(l10n.aiChatTooManyRunning('${AiRunRegistry.maxRunning}')),
      findsOneWidget,
    );
    expect(find.text(l10n.aiSendResumesAfterReset), findsNothing);
  });

  testWidgets('the card leaves and the button returns when the budget does', (
    tester,
  ) async {
    final session = _GatedSession(
      reason: AiChatSendBlockReason.criticalRateBudget,
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.enterText(
      find.byKey(const ValueKey('ai-chat-input')),
      'Summarize it',
    );
    await tester.pump();
    expect(_card, findsOneWidget);

    session.update(() => session.reason = null);
    await tester.pump();

    expect(_card, findsNothing);
    await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
    await tester.pump();
    expect(session.sent, ['Summarize it']);
  });

  testWidgets('the minute count drops as time passes', (tester) async {
    final session = _GatedSession(
      reason: AiChatSendBlockReason.serverCooldown,
      until: DateTime.now().add(const Duration(minutes: 1, seconds: 1)),
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    expect(find.text(l10n.cacheResumesInMinutes(2)), findsOneWidget);

    // The card reads the wall clock; let a little more than a second pass.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1200)),
    );
    await tester.pump(const Duration(seconds: 2));

    expect(find.text(l10n.cacheResumesInMinutes(1)), findsOneWidget);
  });

  testWidgets('the button returns by itself when the stated wait ends', (
    tester,
  ) async {
    final session = _GatedSession(
      reason: AiChatSendBlockReason.serverCooldown,
      until: DateTime.now().add(const Duration(milliseconds: 600)),
    );
    await tester.pumpWidget(_host(AiChatPage(session: session)));
    await tester.enterText(
      find.byKey(const ValueKey('ai-chat-input')),
      'Retry now',
    );
    await tester.pump();
    expect(_sendButton(tester).onPressed, isNull);

    // No budget event arrives: only the card's own timer can bring it back.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(_card, findsNothing);
    expect(_sendButton(tester).onPressed, isNotNull);
  });

  testWidgets('a conversation blocker wins over the budget card', (
    tester,
  ) async {
    final session = _GatedSession(
      reason: AiChatSendBlockReason.criticalRateBudget,
    )..blocker = AiChatBlocker.tooManyRunning;
    await tester.pumpWidget(_host(AiChatPage(session: session)));

    expect(_card, findsNothing);
    expect(find.byKey(const ValueKey('ai-chat-blocker')), findsOneWidget);
  });

  for (final tag in const ['de', 'ar']) {
    testWidgets('fits a narrow phone at large text in $tag', (tester) async {
      useLanguage(languageForTag(tag)!);
      addTearDown(() => useLanguage(languageForTag('zh-TW')!));
      tester.view.physicalSize = const Size(640, 1400);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 700),
            textScaler: TextScaler.linear(2),
          ),
          child: _host(
            AiChatPage(
              session: _GatedSession(
                reason: AiChatSendBlockReason.criticalRateBudget,
                until: DateTime.now().add(const Duration(minutes: 12)),
              ),
            ),
            locale: Locale(tag),
          ),
        ),
      );
      await tester.pump();

      expect(_card, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
