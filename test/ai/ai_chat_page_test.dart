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
import 'package:gitlab_mobile/core/brand.dart';
import 'package:gitlab_mobile/features/ai/ai_report_sender.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/features/workspace/attachment_picker.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_page.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_write_ui.dart';
import 'package:gitlab_mobile/features/ai/ai_draft_preview.dart';
import 'package:gitlab_mobile/features/ai/ai_draft_target.dart';
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
  bool reportNotSaved = false;
  // Like the controller: reading the live secrets can grow the redacted set
  // (an OAuth token rotated in place) or fail.
  bool secretsReadable = true;
  String? rotatedSecret;
  var secretRefreshes = 0;
  // Holds the refresh, like a read that takes a moment.
  Completer<void>? refreshGate;
  @override
  Future<bool> refreshSecrets() async {
    secretRefreshes++;
    await refreshGate?.future;
    return secretsReadable;
  }
  // Like the controller, a rebuilt item points at its replacement.
  final successors = <AiAssistantItem, AiAssistantItem>{};
  @override
  AiAssistantItem? currentOf(AiAssistantItem item) {
    var current = item;
    for (
      var next = successors[current];
      next != null;
      next = successors[current]
    ) {
      current = next;
    }
    return items.contains(current) ? current : null;
  }

  @override
  bool get canSend =>
      blocker == AiChatBlocker.none && phase == AiChatPhase.idle;

  final sent = <String>[];
  var stops = 0;
  var rechecks = 0;
  var newConversations = 0;
  final used = <String>[];
  final reported = <AiAssistantItem>[];
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
  void markReported(AiAssistantItem item) => reported.add(item);
  @override
  set confirmCleartext(Future<bool> Function()? callback) =>
      cleartext = callback;
  // Like the controller: display text loses every control character,
  // including line breaks; draft text keeps line breaks and tabs.
  @override
  String displaySafe(String text) => text
      .replaceAll(RegExp(r'[\u0000-\u001f]'), '')
      .replaceAll('synthetic-secret', '[REDACTED]');
  @override
  String draftSafe(String text) {
    var safe = text
        .replaceAll(RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f]'), '')
        .replaceAll('synthetic-secret', '[REDACTED]');
    if ((rotatedSecret, secretRefreshes) case (final secret?, > 0)) {
      safe = safe.replaceAll(secret, '[REDACTED]');
    }
    return safe;
  }

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

/// Its answers were kept on screen from an earlier conversation.
final class _PriorConversationSession extends _FakeSession {
  _PriorConversationSession({super.items});

  @override
  AiAssistantItem? currentOf(AiAssistantItem item) => null;
}

final class _FakeWriteSession extends _FakeSession
    implements AiWriteChatSession {
  _FakeWriteSession({super.items, super.phase, this.proposals = const []});

  @override
  List<AiWriteProposal> proposals;
  @override
  AiAutonomyLevel autonomyLevel = AiAutonomyLevel.confirmEach;
  @override
  AiAutonomyLevel autonomyCeiling = AiAutonomyLevel.lowRiskAuto;
  final approved = <AiWriteProposal>[];

  @override
  Future<void> setAutonomyLevel(AiAutonomyLevel level) async =>
      update(() => autonomyLevel = level);
  @override
  Future<AiWriteOutcome> approveWrite(
    AiWriteProposal proposal, {
    String? typedName,
    String? editedText,
  }) async {
    approved.add(proposal);
    return const AiWriteOutcome(
      state: AiJournalState.succeeded,
      reasonCode: 'ok',
    );
  }

  @override
  Future<void> rejectWrite(AiWriteProposal proposal) async {}

  @override
  List<AiStoredAttachment> attachments = const [];
  @override
  bool canAttach = true;
  AiAttachStatus attachStatus = AiAttachStatus.stored;
  final picks = <AiAttachmentPick>[];
  @override
  Future<AiAttachResult> attach(AiAttachmentPick pick) async {
    picks.add(pick);
    return AiAttachResult(status: attachStatus, reasonCode: null);
  }

  @override
  void removeAttachment(String id) {}
}

AiWriteProposal _writeProposal() => AiWriteProposal(
  executionId: 'exec-1',
  operationId: 'createNote',
  tier: const AiTierDecision(
    decision: AiGateDecision.requireApproval,
    tier: AiWriteTier.t2,
    requiresTypedName: false,
    typedName: null,
    reasons: [],
  ),
  payloadDigest: 'digest',
  previewText: 'createNote !44',
  userUtterance: 'comment on it',
  modelReason: 'You asked for a comment.',
  expiresAt: DateTime(2026, 10, 22, 21, 30),
  proposalEpoch: 1,
  writePolicyRevision: 1,
  consentHash: 'hash',
  scopeRevision: 1,
  releaseName: '!44',
  fields: const {'body': 'Thanks!'},
);

Widget _host(Widget child, {String tag = 'zh-TW', double scale = 1}) {
  final locale = switch (tag) {
    'ar' => const Locale('ar'),
    'en' => const Locale('en'),
    'de' => const Locale('de'),
    _ => const Locale('zh', 'TW'),
  };
  return MaterialApp(
    theme: appTheme(Brightness.light),
    locale: locale,
    supportedLocales: const [
      Locale('zh', 'TW'),
      Locale('ar'),
      Locale('en'),
      Locale('de'),
    ],
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

/// The draft check in place, so a test need not wait for another isolate.
Future<AiDraftAnalysis> _now(String text, String existing) async =>
    analyzeAiDraftNow(text, existing);

AiDraftTarget _target({
  String existing = '',
  bool Function()? confidential,
  Future<void> Function(String text)? insert,
}) => AiDraftTarget(
  existingText: () async => existing,
  confidential: confidential ?? () => false,
  insert: insert ?? (_) async {},
);

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
          analyzeDraft: _now,
          draftTarget: _target(
            insert: (text) {
              inserted.add(text);
              return pending.future;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.aiChatInsertDraft));
    await tester.pumpAndSettle();
    // The preview comes first; nothing is inserted until it is confirmed.
    expect(find.text(l10n.aiDraftPreviewTitle), findsOneWidget);
    expect(inserted, isEmpty);
    await tester.tap(find.byKey(const ValueKey('ai-draft-confirm')));
    await tester.pump();
    expect(inserted, [answer.text]);
    expect(session.sent, isEmpty);
    // While the editor opens the button waits instead of offering a second
    // append.
    final busy = find.byKey(const ValueKey('ai-chat-insert-draft'));
    expect(tester.widget<ButtonStyleButton>(busy).onPressed, isNull);
    pending.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<ButtonStyleButton>(busy).onPressed, isNotNull);
  });

  group('writes', () {
    testWidgets('a waiting proposal shows its card, Stop and the level', (
      tester,
    ) async {
      final proposal = _writeProposal();
      final session = _FakeWriteSession(
        phase: AiChatPhase.awaitingApproval,
        items: const [
          AiAssistantItem(
            text: 'I will add a comment.',
            state: AiAssistantState.done,
          ),
        ],
        proposals: [proposal],
      );
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.byType(AiWriteProposalCard), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-chat-stop')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-chat-send')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('ai-proposal-approve')));
      await tester.pumpAndSettle();
      expect(session.approved, [proposal]);
      await tester.tap(find.byKey(const ValueKey('ai-chat-stop')));
      expect(session.stops, 1);
      expect(find.byKey(const ValueKey('ai-chat-level')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-chat-level')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-level-lowRiskAuto')));
      await tester.pumpAndSettle();
      expect(session.autonomyLevel, AiAutonomyLevel.lowRiskAuto);
    });

    testWidgets('a write waiting for its card says so, not "reading"', (
      tester,
    ) async {
      final session = _FakeWriteSession(
        phase: AiChatPhase.awaitingApproval,
        items: const [
          AiToolRunItem(
            name: 'createNote',
            argsPreview: '',
            status: AiToolRunStatus.running,
            sizeChars: 0,
            provenance: '',
          ),
        ],
        proposals: [_writeProposal()],
      );
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pump();
      expect(find.text(aiOperationLabel('createNote')), findsWidgets);
      expect(find.text(l10n.waitingForConfirmation), findsOneWidget);
      expect(find.text(l10n.aiToolUnknown), findsNothing);
      expect(find.text(l10n.aiToolReading), findsNothing);
      // Approved: the same row is being made.
      session.update(() => session.phase = AiChatPhase.running);
      await tester.pump();
      expect(find.text(l10n.aiWriteInProgress), findsOneWidget);
    });

    testWidgets('automatic writes show a banner whose Stop ends them', (
      tester,
    ) async {
      final session = _FakeWriteSession(phase: AiChatPhase.running)
        ..autonomyCeiling = AiAutonomyLevel.bypass
        ..autonomyLevel = AiAutonomyLevel.bypass;
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pump();
      final banner = find.byKey(const ValueKey('ai-auto-write-banner'));
      expect(banner, findsOneWidget);
      expect(
        find.text(l10n.aiAutoWriteBanner(l10n.aiLevelBypass)),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('ai-auto-write-stop')));
      await tester.pump();
      expect(session.stops, 1);
      expect(session.autonomyLevel, AiAutonomyLevel.confirmEach);
      expect(banner, findsNothing);
    });

    testWidgets('only the two automatic levels show the banner', (
      tester,
    ) async {
      final session = _FakeWriteSession()
        ..autonomyCeiling = AiAutonomyLevel.bypass
        ..autonomyLevel = AiAutonomyLevel.lowRiskAuto;
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      final banner = find.byKey(const ValueKey('ai-auto-write-banner'));
      expect(banner, findsNothing);
      await session.setAutonomyLevel(AiAutonomyLevel.conversationGrant);
      await tester.pumpAndSettle();
      expect(banner, findsOneWidget);
      // Idle: Stop only drops the level; there is no run to end.
      await tester.tap(find.byKey(const ValueKey('ai-auto-write-stop')));
      await tester.pumpAndSettle();
      expect(session.stops, 0);
      expect(session.autonomyLevel, AiAutonomyLevel.confirmEach);
      expect(banner, findsNothing);
    });

    for (final tag in ['zh-TW', 'de', 'ar']) {
      testWidgets('the banner fits $tag at 2x on 320 dp with the keyboard', (
        tester,
      ) async {
        final ratio = tester.view.devicePixelRatio;
        tester.view.physicalSize = const Size(320, 640) * ratio;
        addTearDown(tester.view.reset);
        if (tag != 'zh-TW') useLanguage(languageForTag(tag)!);
        addTearDown(() => useLanguage(languageForTag('zh-TW')!));
        final session = _FakeWriteSession(
          items: const [
            AiAssistantItem(
              text: 'I will add a comment.',
              state: AiAssistantState.done,
            ),
          ],
        )
          ..autonomyCeiling = AiAutonomyLevel.bypass
          ..autonomyLevel = AiAutonomyLevel.bypass;
        await tester.pumpWidget(
          _host(AiChatPage(session: session), tag: tag, scale: 2),
        );
        await tester.pumpAndSettle();
        await tester.showKeyboard(find.byType(TextField).last);
        tester.view.viewInsets = FakeViewPadding(bottom: 280 * ratio);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final stop = tester.getRect(
          find.byKey(const ValueKey('ai-auto-write-stop')),
        );
        expect(stop.left, greaterThanOrEqualTo(0));
        expect(stop.right, lessThanOrEqualTo(320));
        expect(stop.top, greaterThanOrEqualTo(0));
        final send = tester.getRect(find.byKey(const ValueKey('ai-chat-send')));
        expect(send.bottom, lessThanOrEqualTo(640 - 280));
        expect(send.top, greaterThan(stop.bottom));
      });
    }

    testWidgets('attach is off at the file limit and says why', (
      tester,
    ) async {
      final held = AiAttachmentSession(
        accountKey: 'synthetic',
        conversationId: 'conversation-full',
      );
      addTearDown(held.discardAll);
      final files = <AiStoredAttachment>[];
      for (
        var n = 0;
        n < AiAttachmentSession.maxCountPerConversation;
        n++
      ) {
        final result = await tester.runAsync(
          () => held.reserveAndRead(
            picker: _NoPicker(),
            uploadToolInSegment: true,
            intake: AiAttachmentIntake(
              filename: 'shot-$n.png',
              length: 3,
              open: () => Stream.value([1, 2, n]),
            ),
          ),
        );
        files.add(result!.attachment!);
      }
      final session = _FakeWriteSession()..attachments = files;
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      final attach = tester.widget<IconButton>(
        find.byKey(const ValueKey('ai-chat-attach')),
      );
      expect(attach.onPressed, isNull);
      expect(attach.tooltip, l10n.aiAttachCapacity);
    });

    testWidgets('a read-only conversation has no level or attach button', (
      tester,
    ) async {
      await tester.pumpWidget(_host(AiChatPage(session: _FakeSession())));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-chat-level')), findsNothing);
      expect(find.byKey(const ValueKey('ai-chat-attach')), findsNothing);
    });

    testWidgets('attach picks an image or a file and says why it failed', (
      tester,
    ) async {
      final session = _FakeWriteSession()..attachStatus = AiAttachStatus.tooLarge;
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-attach-image')));
      await tester.pumpAndSettle();
      expect(session.picks, [AiAttachmentPick.image]);
      expect(find.text(l10n.aiAttachTooLarge), findsOneWidget);
      session.update(() => session.canAttach = false);
      await tester.pumpAndSettle();
      final attach = find.byKey(const ValueKey('ai-chat-attach'));
      expect(tester.widget<IconButton>(attach).onPressed, isNull);
    });

    testWidgets('a finished write says how it went', (tester) async {
      await tester.pumpWidget(
        _host(
          AiChatPage(
            session: _FakeSession(
              items: const [
                AiToolRunItem(
                  name: 'createNote',
                  argsPreview: '!44',
                  status: AiToolRunStatus.failed,
                  sizeChars: 0,
                  provenance: '',
                  writeStatus: AiWriteResultStatus.writeUncertain,
                ),
                AiToolRunItem(
                  name: 'setStar',
                  argsPreview: 'team/example',
                  status: AiToolRunStatus.completed,
                  sizeChars: 0,
                  provenance: '',
                  writeStatus: AiWriteResultStatus.readbackConfirmed,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining(l10n.aiOpCreateNote), findsOneWidget);
      expect(find.textContaining(l10n.aiWriteStatusUncertain), findsOneWidget);
      // An uncertain write is never called a failure.
      expect(find.textContaining(l10n.aiToolFailed), findsNothing);
      expect(find.textContaining(l10n.aiWriteStatusConfirmed), findsOneWidget);
    });
  });

  group('reporting a response', () {
    const answerText = 'It renames **one** file.';
    const source = AiAnswerSource(
      presetId: 'opencode-go',
      format: 'chatCompletions',
      model: 'glm-synthetic',
    );

    final origins = <Rect?>[];

    Future<List<({String subject, String body})>> openReport(
      WidgetTester tester,
      _FakeSession session, {
      AiReportRoute route = AiReportRoute.mail,
      bool fail = false,
      String tag = 'zh-TW',
      double scale = 1,
    }) async {
      final sent = <({String subject, String body})>[];
      origins.clear();
      await tester.pumpWidget(
        _host(
          AiChatPage(
            session: session,
            buildInfo: () async => const BuildInfo(
              version: '0.6.0',
              buildNumber: '612',
              commit: 'abc1234',
            ),
            sendReport:
                ({required subject, required body, sharePositionOrigin}) async {
              origins.add(sharePositionOrigin);
              if (fail) throw StateError('no mail, no share');
              sent.add((subject: subject, body: body));
              return route;
            },
          ),
          tag: tag,
          scale: scale,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-chat-report')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiReportTitle), findsOneWidget);
      return sent;
    }

    _FakeSession answered() => _FakeSession(
      items: const [
        AiAssistantItem(
          text: answerText,
          state: AiAssistantState.done,
          source: source,
        ),
      ],
    );

    Future<void> send(WidgetTester tester) async {
      final button = find.byKey(const ValueKey('ai-report-send'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    testWidgets('sends metadata only unless the response is attached', (
      tester,
    ) async {
      final session = answered();
      final sent = await openReport(tester, session);
      final button = find.byKey(const ValueKey('ai-report-send'));
      expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('ai-report-inaccurate')));
      await tester.pumpAndSettle();
      final preview = find.byKey(const ValueKey('ai-report-preview'));
      final shown = tester.widget<Text>(preview).data!;
      expect(shown, contains('category: inaccurate'));
      expect(shown, contains('preset: opencode-go'));
      expect(shown, contains('app: 0.6.0+612 (abc1234)'));
      expect(shown, isNot(contains('renames')));
      await tester.tap(find.byKey(const ValueKey('ai-report-attach')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(preview).data, contains(answerText));
      await send(tester);
      expect(sent.single.body, contains(answerText));
      expect(sent.single.body.split('\n').first, l10n.aiReportSendTo(aiReportEmail));
      expect(session.reported, hasLength(1));
      expect(find.text(l10n.aiReportMailOpened), findsOneWidget);
    });

    testWidgets('the text is checked again when it is sent', (tester) async {
      final session = answered();
      final sent = await openReport(tester, session);
      await tester.tap(find.byKey(const ValueKey('ai-report-inaccurate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-report-attach')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-report-description')),
        'pasted synthetic-secret by mistake',
      );
      // A redaction pass replaces the answer while the sheet is open.
      final original = session.items.single as AiAssistantItem;
      const rebuilt = AiAssistantItem(
        text: 'It renames synthetic-secret files.',
        state: AiAssistantState.done,
        source: source,
      );
      session.successors[original] = rebuilt;
      session.update(() => session.items = [rebuilt]);
      await tester.pumpAndSettle();
      await send(tester);
      final body = sent.single.body;
      expect(body, contains('It renames [REDACTED] files.'));
      expect(body, contains('description: pasted [REDACTED] by mistake'));
      expect(body, isNot(contains('synthetic-secret')));
      expect(body, isNot(contains('renames **one** file')));
      // The report is marked on the answer the user picked; the session
      // follows it to the current one.
      expect(session.reported, [original]);
    });

    testWidgets('a preview that changed at Send is shown before sending', (
      tester,
    ) async {
      final session = answered();
      final sent = await openReport(tester, session);
      await tester.tap(find.byKey(const ValueKey('ai-report-inaccurate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-report-attach')));
      await tester.pumpAndSettle();
      // The answer is rebuilt while the sheet stays as it was.
      final original = session.items.single as AiAssistantItem;
      // Long enough that the preview runs far past the screen.
      final rebuilt = AiAssistantItem(
        text: 'It renames two files.${'\nmore detail' * 120}',
        state: AiAssistantState.done,
        source: source,
      );
      session.successors[original] = rebuilt;
      session.update(() => session.items = [rebuilt]);
      await tester.pumpAndSettle();
      final preview = find.byKey(const ValueKey('ai-report-preview'));
      expect(tester.widget<Text>(preview).data, contains(answerText));
      await send(tester);
      // Nothing left; the sheet now shows the text that would go.
      expect(sent, isEmpty);
      final note = find.byKey(const ValueKey('ai-report-preview-updated'));
      expect(note, findsOne);
      // The note is on screen next to Send and is read out when it appears.
      final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(tester.getRect(note).bottom, lessThanOrEqualTo(screen.height));
      expect(tester.getRect(note).top, greaterThanOrEqualTo(0));
      expect(
        find.ancestor(
          of: note,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && (widget.properties.liveRegion ?? false),
          ),
        ),
        findsOne,
      );
      expect(tester.widget<Text>(preview).data, contains('two files'));
      await send(tester);
      expect(sent.single.body, contains('two files'));
    });

    testWidgets('a second Send while the first is checked sends once', (
      tester,
    ) async {
      final session = answered()..refreshGate = Completer<void>();
      final sent = await openReport(tester, session);
      await tester.tap(find.byKey(const ValueKey('ai-report-harmful')));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('ai-report-send'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      // The second press lands while the first is still being checked.
      await tester.tap(button);
      await tester.tap(button, warnIfMissed: false);
      expect(session.secretRefreshes, 1);
      session.refreshGate!.complete();
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(session.reported, hasLength(1));
    });

    testWidgets('changing the choice after an update clears the note', (
      tester,
    ) async {
      final session = answered()..rotatedSecret = 'synthetic-rotated-token';
      await openReport(tester, session);
      await tester.tap(find.byKey(const ValueKey('ai-report-other')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-report-description')),
        'synthetic-rotated-token',
      );
      await tester.pumpAndSettle();
      await send(tester);
      final note = find.byKey(const ValueKey('ai-report-preview-updated'));
      expect(note, findsOne);
      final attach = find.byKey(const ValueKey('ai-report-attach'));
      await tester.ensureVisible(attach);
      await tester.pumpAndSettle();
      await tester.tap(attach);
      await tester.pumpAndSettle();
      expect(note, findsNothing);
    });

    testWidgets('a token rotated in place is redacted before it goes', (
      tester,
    ) async {
      const token = 'synthetic-rotated-oauth-token';
      final session = answered()..rotatedSecret = token;
      final sent = await openReport(tester, session);
      await tester.tap(find.byKey(const ValueKey('ai-report-other')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-report-description')),
        'pasted $token here',
      );
      await tester.pumpAndSettle();
      await send(tester);
      expect(sent, isEmpty);
      final preview = find.byKey(const ValueKey('ai-report-preview'));
      expect(tester.widget<Text>(preview).data, isNot(contains(token)));
      await send(tester);
      expect(sent.single.body, contains('pasted [REDACTED] here'));
      expect(sent.single.body, isNot(contains(token)));
    });

    testWidgets('secrets that cannot be read stop the report', (tester) async {
      final session = answered()..secretsReadable = false;
      final sent = await openReport(tester, session);
      await tester.tap(find.byKey(const ValueKey('ai-report-harmful')));
      await tester.pumpAndSettle();
      await send(tester);
      expect(sent, isEmpty);
      expect(session.reported, isEmpty);
      expect(find.text(l10n.aiReportNotChecked), findsOneWidget);
    });

    testWidgets('the share sheet is anchored at the Report button', (
      tester,
    ) async {
      final session = answered();
      await openReport(tester, session, route: AiReportRoute.share);
      await tester.tap(find.byKey(const ValueKey('ai-report-other')));
      await tester.pumpAndSettle();
      await send(tester);
      expect(origins.single, isNotNull);
      expect(origins.single!.isEmpty, isFalse);
    });

    testWidgets('an answer from an earlier conversation has no Report', (
      tester,
    ) async {
      final session = _PriorConversationSession(
        items: const [
          AiAssistantItem(text: answerText, state: AiAssistantState.done),
        ],
      );
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-chat-report')), findsNothing);
    });

    testWidgets('an answer gone before sending is not sent', (tester) async {
      final session = answered();
      final sent = await openReport(tester, session);
      await tester.tap(find.byKey(const ValueKey('ai-report-other')));
      await tester.pumpAndSettle();
      session.update(() => session.items = []);
      await tester.pumpAndSettle();
      await send(tester);
      expect(sent, isEmpty);
      expect(session.reported, isEmpty);
      expect(find.text(l10n.aiReportNotChecked), findsOneWidget);
    });

    testWidgets('the address is copied with feedback on the button', (
      tester,
    ) async {
      Object? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') copied = call.arguments;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final session = answered();
      await openReport(tester, session);
      final copy = find.byKey(const ValueKey('ai-report-copy-address'));
      await tester.ensureVisible(copy);
      await tester.pumpAndSettle();
      await tester.tap(copy);
      await tester.pumpAndSettle();
      expect(copied, {'text': aiReportEmail});
      expect(
        find.descendant(
          of: copy,
          matching: find.text(l10n.aiReportAddressCopied),
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 3));
      expect(
        find.descendant(
          of: copy,
          matching: find.text(l10n.aiReportCopyAddress),
        ),
        findsOneWidget,
      );
    });

    for (final (tag, scale) in [('de', 2.0), ('en', 2.0), ('ar', 2.0)]) {
      testWidgets('the update note keeps Send in reach: $tag, ${scale}x, keyboard', (
        tester,
      ) async {
        final ratio = tester.view.devicePixelRatio;
        tester.view.physicalSize = const Size(360, 640) * ratio;
        tester.view.padding = FakeViewPadding(top: 24 * ratio, bottom: 16 * ratio);
        addTearDown(tester.view.reset);
        useLanguage(languageForTag(tag)!);
        addTearDown(() => useLanguage(languageForTag('zh-TW')!));
        const token = 'synthetic-rotated-oauth-token';
        final session = answered()..rotatedSecret = token;
        final sent = await openReport(tester, session, tag: tag, scale: scale);
        final other = find.byKey(const ValueKey('ai-report-other'));
        await tester.ensureVisible(other);
        await tester.pumpAndSettle();
        await tester.tap(other);
        await tester.pumpAndSettle();
        final description = find.byKey(const ValueKey('ai-report-description'));
        await tester.ensureVisible(description);
        await tester.pumpAndSettle();
        await tester.showKeyboard(description);
        tester.view.viewInsets = FakeViewPadding(bottom: 280 * ratio);
        await tester.enterText(description, 'pasted $token');
        await tester.pumpAndSettle();
        final button = find.byKey(const ValueKey('ai-report-send'));
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(sent, isEmpty);
        expect(find.byKey(const ValueKey('ai-report-preview-updated')), findsOne);
        // Send stays above the keyboard and part of the preview shows.
        expect(tester.getRect(button).bottom, lessThanOrEqualTo(640 - 280));
        final scroll = find.byKey(const ValueKey('ai-report-scroll'));
        expect(tester.getSize(scroll).height, greaterThan(40));
        final preview = tester.getRect(
          find.byKey(const ValueKey('ai-report-preview')),
        );
        final area = tester.getRect(scroll);
        expect(preview.top, lessThan(area.bottom));
        expect(preview.bottom, greaterThan(area.top));
      });
    }

    testWidgets('keys typed just before Send are shown before they go', (
      tester,
    ) async {
      final session = answered()..refreshGate = Completer<void>();
      final sent = await openReport(tester, session);
      await tester.tap(find.byKey(const ValueKey('ai-report-other')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-report-description')),
        'typed-just-now',
      );
      // Inside the preview's typing pause.
      final button = find.byKey(const ValueKey('ai-report-send'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      session.refreshGate!.complete();
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      expect(find.byKey(const ValueKey('ai-report-preview-updated')), findsOne);
      final preview = find.byKey(const ValueKey('ai-report-preview'));
      expect(tester.widget<Text>(preview).data, contains('typed-just-now'));
    });

    testWidgets('backing out while the text is checked keeps the chat open', (
      tester,
    ) async {
      final session = answered()..refreshGate = Completer<void>();
      final sent = await openReport(tester, session);
      await tester.tap(find.byKey(const ValueKey('ai-report-harmful')));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('ai-report-send'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pump();
      await tester.tap(find.text(l10n.cancelAction));
      await tester.pump();
      session.refreshGate!.complete();
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      expect(find.byType(AiChatPage), findsOneWidget);
    });

    testWidgets('a landscape phone with the keyboard up can still send', (
      tester,
    ) async {
      final ratio = tester.view.devicePixelRatio;
      tester.view.physicalSize = const Size(640, 360) * ratio;
      tester.view.padding = FakeViewPadding(
        top: 24 * ratio,
        bottom: 16 * ratio,
      );
      addTearDown(tester.view.reset);
      useLanguage(languageForTag('en')!);
      addTearDown(() => useLanguage(languageForTag('zh-TW')!));
      final session = answered();
      final sent = await openReport(tester, session, tag: 'en', scale: 2);
      final harmful = find.byKey(const ValueKey('ai-report-harmful'));
      await tester.ensureVisible(harmful);
      await tester.pumpAndSettle();
      await tester.tap(harmful);
      await tester.pumpAndSettle();
      await tester.showKeyboard(
        find.byKey(const ValueKey('ai-report-description')),
      );
      tester.view.viewInsets = FakeViewPadding(bottom: 220 * ratio);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // The buttons now scroll with the form, and the description field keeps
      // its focus and its connection to the keyboard.
      expect(tester.testTextInput.hasAnyClients, isTrue);
      final field = find.descendant(
        of: find.byKey(const ValueKey('ai-report-description')),
        matching: find.byType(EditableText),
      );
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
      final button = find.byKey(const ValueKey('ai-report-send'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      expect(tester.getRect(button).bottom, lessThanOrEqualTo(360 - 220));
      await tester.tap(button);
      // The keyboard goes with the sheet's text field.
      await tester.pump();
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
    });

    testWidgets('the share sheet route says where to send', (tester) async {
      final session = answered();
      final sent = await openReport(
        tester,
        session,
        route: AiReportRoute.share,
      );
      await tester.tap(find.byKey(const ValueKey('ai-report-other')));
      await tester.pumpAndSettle();
      await send(tester);
      expect(sent.single.body, isNot(contains('renames')));
      expect(find.text(l10n.aiReportShareOpened(aiReportEmail)), findsOne);
      expect(session.reported, hasLength(1));
    });

    testWidgets('a report that cannot be handed off is not marked', (
      tester,
    ) async {
      final session = answered();
      await openReport(tester, session, fail: true);
      await tester.tap(find.byKey(const ValueKey('ai-report-harmful')));
      await tester.pumpAndSettle();
      await send(tester);
      expect(session.reported, isEmpty);
      expect(find.text(l10n.aiReportFailed), findsOneWidget);
    });

    testWidgets('a reported answer is folded and can be opened', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          AiChatPage(
            session: _FakeSession(
              items: const [
                AiAssistantItem(
                  text: answerText,
                  state: AiAssistantState.done,
                  reported: true,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiReported), findsOneWidget);
      expect(find.byType(AiMessageBody), findsNothing);
      expect(find.byKey(const ValueKey('ai-chat-report')), findsNothing);
      expect(
        find.byKey(const ValueKey('ai-chat-report-not-saved')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('ai-chat-reported-toggle')));
      await tester.pumpAndSettle();
      expect(find.byType(AiMessageBody), findsOneWidget);
      // Open, the header no longer says the content is hidden.
      expect(find.text(l10n.aiReported), findsNothing);
      expect(find.text(l10n.aiReportedOpen), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-chat-reported-toggle')));
      await tester.pumpAndSettle();
      expect(find.byType(AiMessageBody), findsNothing);
    });

    testWidgets('a mark that could not be saved says so', (tester) async {
      final session = _FakeSession(
        items: const [
          AiAssistantItem(
            text: answerText,
            state: AiAssistantState.done,
            reported: true,
          ),
        ],
      )..reportNotSaved = true;
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiReportNotSaved), findsOneWidget);
      session.update(() => session.reportNotSaved = false);
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiReportNotSaved), findsNothing);
    });

    for (final (tag, size) in [
      ('zh-TW', const Size(320, 640)),
      ('ar', const Size(320, 640)),
    ]) {
      testWidgets('the fold fits $tag at 2x on ${size.width}x${size.height}', (
        tester,
      ) async {
        tester.view.physicalSize = size * tester.view.devicePixelRatio;
        addTearDown(tester.view.reset);
        if (tag != 'zh-TW') useLanguage(languageForTag(tag)!);
        addTearDown(() => useLanguage(languageForTag('zh-TW')!));
        final session = _FakeSession(
          items: const [
            AiAssistantItem(
              text: answerText,
              state: AiAssistantState.done,
              reported: true,
            ),
          ],
        )..reportNotSaved = true;
        await tester.pumpWidget(
          _host(AiChatPage(session: session), tag: tag, scale: 2),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final toggle = find.byKey(const ValueKey('ai-chat-reported-toggle'));
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text(l10n.aiReportedOpen), findsOneWidget);
      });
    }

    testWidgets('an answer still streaming cannot be reported', (tester) async {
      await tester.pumpWidget(
        _host(
          AiChatPage(
            session: _FakeSession(
              phase: AiChatPhase.running,
              items: const [
                AiAssistantItem(
                  text: 'partial',
                  state: AiAssistantState.streaming,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('ai-chat-report')), findsNothing);
    });

    for (final (tag, size) in [
      ('zh-TW', const Size(320, 640)),
      ('ar', const Size(320, 640)),
      ('en', const Size(640, 360)),
    ]) {
      testWidgets('the sheet fits $tag at 2x on ${size.width}x${size.height}', (
        tester,
      ) async {
        tester.view.physicalSize = size * tester.view.devicePixelRatio;
        tester.view.padding = FakeViewPadding(
          top: 24 * tester.view.devicePixelRatio,
          bottom: 16 * tester.view.devicePixelRatio,
        );
        addTearDown(tester.view.reset);
        if (tag != 'zh-TW') useLanguage(languageForTag(tag)!);
        addTearDown(() => useLanguage(languageForTag('zh-TW')!));
        final session = answered();
        await openReport(tester, session, tag: tag, scale: 2);
        for (final key in ['ai-report-privacy', 'ai-report-attach']) {
          await tester.ensureVisible(find.byKey(ValueKey(key)));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey(key)));
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(find.byType(BottomSheet)).top,
          greaterThanOrEqualTo(24),
        );
        await send(tester);
        expect(tester.takeException(), isNull);
        expect(session.reported, hasLength(1));
      });
    }
  });

  group('the append preview', () {
    Future<List<String>> openPreview(
      WidgetTester tester,
      _FakeSession session, {
      String tag = 'zh-TW',
      double scale = 1,
      String existing = '',
      bool Function()? confidential,
    }) async {
      final inserted = <String>[];
      await tester.pumpWidget(
        _host(
          AiChatPage(
            session: session,
            analyzeDraft: _now,
            draftTarget: _target(
              existing: existing,
              confidential: confidential,
              insert: (text) async => inserted.add(text),
            ),
          ),
          tag: tag,
          scale: scale,
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(l10n.aiChatInsertDraft));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.aiChatInsertDraft));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiDraftPreviewTitle), findsOneWidget);
      return inserted;
    }

    Future<void> confirm(WidgetTester tester) async {
      final button = find.byKey(const ValueKey('ai-draft-confirm'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    _FakeSession answer(String text, {List<AiChatItem> before = const []}) =>
        _FakeSession(
          items: [
            ...before,
            AiAssistantItem(text: text, state: AiAssistantState.done),
          ],
        );

    testWidgets('quick-action lines are disabled before the draft opens', (
      tester,
    ) async {
      final inserted = await openPreview(
        tester,
        answer('Plan:\n/merge\r\n/close\nDone'),
      );
      expect(
        find.text(l10n.aiDraftQuickActions('2')),
        findsOneWidget,
      );
      await confirm(tester);
      expect(inserted, ['Plan:\n /merge\n /close\nDone']);
      expect(
        inserted.single.split('\n').any((line) => line.startsWith('/')),
        isFalse,
      );
    });

    testWidgets('paragraphs, lists and code keep their lines', (
      tester,
    ) async {
      const text = 'Summary:\n\n- one\n- two\n\n```dart\n\tvoid main() {}\n```';
      final inserted = await openPreview(tester, answer(text));
      await confirm(tester);
      expect(inserted, [text]);
    });

    testWidgets('mentions stop notifying unless the user keeps them', (
      tester,
    ) async {
      final session = answer('Thanks @victim, see @group/sub.');
      var inserted = await openPreview(tester, session);
      expect(find.text(l10n.aiDraftMentionsOff('2')), findsOneWidget);
      await confirm(tester);
      expect(inserted, ['Thanks `@victim`, see `@group/sub`.']);

      inserted = await openPreview(tester, session);
      await tester.tap(find.byKey(const ValueKey('ai-draft-keep-mentions')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiDraftMentionsNotify('2')), findsOneWidget);
      expect(find.text('@victim'), findsOneWidget);
      await confirm(tester);
      expect(inserted, ['Thanks @victim, see @group/sub.']);
    });

    testWidgets('a mention that cannot be disabled must be acknowledged', (
      tester,
    ) async {
      // GitLab reads an HTML block as HTML, so a code span cannot be
      // verified there and the mention would still notify.
      final inserted = await openPreview(
        tester,
        answer('<div>\n@victim\n</div>'),
      );
      expect(find.text(l10n.aiDraftMentionsNotify('1')), findsOneWidget);
      final button = find.byKey(const ValueKey('ai-draft-confirm'));
      await tester.ensureVisible(button);
      expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('ai-draft-acknowledge')));
      await tester.pumpAndSettle();
      await confirm(tester);
      expect(inserted, ['<div>\n@victim\n</div>']);
    });

    testWidgets('references, sources and the confidential warning', (
      tester,
    ) async {
      await openPreview(
        tester,
        answer(
          'See #12 and !3.',
          before: [
            AiUserItem(
              text: 'Why?',
              chips: const [
                AiContextChip(
                  source: 'merge_request',
                  resource: '!44',
                  preview: '',
                  sizeChars: 10,
                ),
              ],
            ),
            const AiToolRunItem(
              name: 'get_issue',
              argsPreview: '#7',
              status: AiToolRunStatus.completed,
              sizeChars: 40,
              provenance: '',
              confidential: true,
            ),
          ],
        ),
      );
      Finder inSheet(Finder finder) =>
          find.descendant(of: find.byType(BottomSheet), matching: finder);
      expect(inSheet(find.text(l10n.aiDraftReferences('2'))), findsOneWidget);
      expect(inSheet(find.text('!44')), findsOneWidget);
      expect(
        inSheet(find.text('${l10n.aiToolGetIssue} · #7')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('ai-draft-confidential')), findsOne);
    });

    testWidgets('the target is asked whether it is confidential each time', (
      tester,
    ) async {
      // A kept conversation can outlive a change to the issue it came from.
      var targetConfidential = true;
      final session = answer(
        'Answer',
        before: const [
          AiToolRunItem(
            name: 'get_issue',
            argsPreview: '#8',
            status: AiToolRunStatus.completed,
            sizeChars: 40,
            provenance: '',
            confidential: true,
          ),
        ],
      );
      await openPreview(
        tester,
        session,
        confidential: () => targetConfidential,
      );
      expect(find.byKey(const ValueKey('ai-draft-confidential')), findsNothing);
      await tester.tap(find.text(l10n.cancelAction));
      await tester.pumpAndSettle();
      targetConfidential = false;
      await tester.tap(find.text(l10n.aiChatInsertDraft));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-draft-confidential')), findsOne);
    });

    testWidgets('internal notes warn whatever the target is', (tester) async {
      for (final before in <List<AiChatItem>>[
        const [
          AiToolRunItem(
            name: 'get_merge_request',
            argsPreview: '!3',
            status: AiToolRunStatus.completed,
            sizeChars: 40,
            provenance: '',
            internal: true,
          ),
        ],
        [
          AiUserItem(
            text: 'Why?',
            chips: const [
              AiContextChip(
                source: 'issue',
                resource: '#7',
                preview: '',
                sizeChars: 10,
                internal: true,
              ),
            ],
          ),
        ],
      ]) {
        await openPreview(
          tester,
          answer('Answer', before: before),
          confidential: () => true,
        );
        expect(find.byKey(const ValueKey('ai-draft-internal')), findsOne);
        await tester.tap(find.text(l10n.cancelAction));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('mentions are checked after the waiting draft', (
      tester,
    ) async {
      // The draft's open fence is closed by the answer's own fence, so
      // `@Override` would be ordinary text in the posted comment.
      final inserted = await openPreview(
        tester,
        answer('Fix:\n\n```\n@Override\npublic void run() {}\n```\nThanks'),
        existing: 'Stack trace:\n```\nat Foo.bar()',
      );
      expect(find.byKey(const ValueKey('ai-draft-after-existing')), findsOne);
      // Checked alone the mention is in code; after the draft it is not, so
      // it is turned off where it now stands, and keeping it would notify.
      expect(find.text(l10n.aiDraftMentionsOff('1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-draft-keep-mentions')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiDraftMentionsNotify('1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-draft-keep-mentions')));
      await tester.pumpAndSettle();
      await confirm(tester);
      expect(inserted, [
        'Fix:\n\n```\n`@Override`\npublic void run() {}\n```\nThanks',
      ]);
    });

    testWidgets('a draft that cannot be read stops before the preview', (
      tester,
    ) async {
      final inserted = <String>[];
      await tester.pumpWidget(
        _host(
          AiChatPage(
            session: answer('Answer'),
            analyzeDraft: _now,
            draftTarget: AiDraftTarget(
              existingText: () async => throw const FormatException('draft'),
              confidential: () => false,
              insert: (text) async => inserted.add(text),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.aiChatInsertDraft));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiDraftPreviewTitle), findsNothing);
      expect(find.text(l10n.aiDraftUnreadable), findsOneWidget);
      expect(inserted, isEmpty);
    });

    testWidgets('cancelling inserts nothing', (tester) async {
      final inserted = await openPreview(tester, answer('Answer'));
      await tester.tap(find.text(l10n.cancelAction));
      await tester.pumpAndSettle();
      expect(inserted, isEmpty);
      expect(find.text(l10n.aiDraftPreviewTitle), findsNothing);
    });

    testWidgets('a conversation that moved on while open inserts nothing', (
      tester,
    ) async {
      final session = answer('Answer');
      final inserted = await openPreview(tester, session);
      session.update(() => session.phase = AiChatPhase.running);
      // A running conversation animates, so the page never settles.
      await tester.tap(find.byKey(const ValueKey('ai-draft-confirm')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text(l10n.aiDraftPreviewTitle), findsNothing);
      expect(inserted, isEmpty);
      expect(find.text(l10n.aiDraftChanged), findsOneWidget);
    });

    testWidgets('a conversation replaced while open inserts nothing', (
      tester,
    ) async {
      final session = answer('Answer');
      final inserted = await openPreview(tester, session);
      session.update(
        () => session.items = const [
          AiAssistantItem(text: 'Answer', state: AiAssistantState.done),
        ],
      );
      await confirm(tester);
      expect(inserted, isEmpty);
      expect(find.text(l10n.aiDraftChanged), findsOneWidget);
    });

    testWidgets('a page pushed as the sheet closes inserts nothing', (
      tester,
    ) async {
      final inserted = await openPreview(tester, answer('Answer'));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      tester
          .widget<ButtonStyleButton>(
            find.byKey(const ValueKey('ai-draft-confirm')),
          )
          .onPressed!();
      // Before the chat page resumes, another page comes to the front.
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(builder: (_) => const Scaffold()),
        ),
      );
      await tester.pumpAndSettle();
      expect(inserted, isEmpty);
      // The chat is covered, so it says nothing there.
      expect(find.text(l10n.aiDraftChanged, skipOffstage: false), findsNothing);
    });

    testWidgets('a check that fails appends nothing and says so', (
      tester,
    ) async {
      final inserted = <String>[];
      await tester.pumpWidget(
        _host(
          AiChatPage(
            session: answer('Answer'),
            analyzeDraft: (_, _) async => throw TimeoutException('check'),
            draftTarget: _target(insert: (text) async => inserted.add(text)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.aiChatInsertDraft));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiDraftPreviewTitle), findsNothing);
      expect(find.text(l10n.aiDraftCheckFailed), findsOneWidget);
      expect(inserted, isEmpty);
    });

    testWidgets('a long answer is previewed in part and appended whole', (
      tester,
    ) async {
      // One character over what the preview shows: the note must still say
      // that the preview is cut. (A single unbroken run would be the
      // Markdown parser's slowest input; this test is about the isolate.)
      final long = '${'x ' * 3000}Z';
      final inserted = <String>[];
      await tester.pumpWidget(
        _host(
          AiChatPage(
            session: answer(long),
            draftTarget: _target(insert: (text) async => inserted.add(text)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(l10n.aiChatInsertDraft));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.aiChatInsertDraft));
      // Long drafts are checked on another isolate, which takes real time;
      // wait for the preview instead of guessing how long (a loaded machine
      // running the whole suite is slow).
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
      expect(find.text(l10n.aiDraftPreviewCut), findsOneWidget);
      await confirm(tester);
      expect(inserted, [long]);
    });

    for (final (tag, scale, size) in [
      ('zh-TW', 2.0, const Size(320, 640)),
      ('ar', 2.0, const Size(320, 640)),
      ('en', 2.0, const Size(640, 360)),
    ]) {
      testWidgets('fits $tag at ${scale}x on ${size.width}x${size.height}', (
        tester,
      ) async {
        tester.view.physicalSize = size * tester.view.devicePixelRatio;
        tester.view.padding = FakeViewPadding(
          top: 24 * tester.view.devicePixelRatio,
          bottom: 16 * tester.view.devicePixelRatio,
        );
        addTearDown(tester.view.reset);
        if (tag != 'zh-TW') useLanguage(languageForTag(tag)!);
        addTearDown(() => useLanguage(languageForTag('zh-TW')!));
        final long = List.filled(40, 'Line @user #1 /merge').join('\n');
        final inserted = await openPreview(
          tester,
          answer(
            long,
            before: const [
              AiToolRunItem(
                name: 'get_issue',
                argsPreview: '#7',
                status: AiToolRunStatus.completed,
                sizeChars: 40,
                provenance: '',
                confidential: true,
              ),
            ],
          ),
          tag: tag,
          scale: scale,
        );
        expect(tester.takeException(), isNull);
        final sheet = tester.getRect(find.byType(BottomSheet));
        expect(sheet.top, greaterThanOrEqualTo(24));
        await confirm(tester);
        expect(tester.takeException(), isNull);
        expect(inserted, hasLength(1));
      });
    }
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
            draftTarget: _target(
              insert: (_) async {
                fail('An incomplete answer must not open a draft');
              },
            ),
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
      _host(AiChatPage(session: session, draftTarget: _target())),
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

final class _NoPicker implements AttachmentPicker {
  @override
  Future<PickedAttachment?> pickImage() async => null;
  @override
  Future<PickedAttachment?> pickFile() async => null;
}
