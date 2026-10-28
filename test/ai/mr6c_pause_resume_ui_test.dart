import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/execution_gate.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_background_execution.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_page.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'fx_coord_support.dart' as fx;

/// A chat session with the C5 continuation and execution capabilities.
final class _Session extends ChangeNotifier
    implements AiChatSession, AiRunContinuationSession, AiExecutionChatSession {
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
  List<AiChatItem> items = [
    AiUserItem(text: 'Inspect the file'),
    const AiAssistantItem(text: 'Reading', state: AiAssistantState.interrupted),
  ];
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
  @override
  Future<bool> refreshSecrets() async => true;
  @override
  AiAssistantItem? currentOf(AiAssistantItem item) =>
      items.contains(item) ? item : null;
  @override
  bool get canSend =>
      blocker == AiChatBlocker.none && phase == AiChatPhase.idle;

  // Continuation and execution state the controller would report.
  @override
  AiExecutionPause? executionPause;
  @override
  AiBackgroundStartResult? serviceStartResult;
  bool resumable = false;
  @override
  bool get canResumeRun => canSend && resumable;
  @override
  Set<AiRunResumeWarning> resumeWarnings = {};
  @override
  AiChatExecutionStatus executionStatus = AiChatExecutionStatus.foregroundOnly;
  @override
  int get serviceWorkCount => 0;
  @override
  int get backProtectedCount => 0;

  final sent = <String>[];
  var resumes = 0;
  var stops = 0;
  Future<bool> Function()? cleartext;

  @override
  Future<void> resumeRun() async {
    resumes++;
    // Like the controller: the same run goes on, with no new message.
    update(() {
      resumable = false;
      executionPause = null;
      phase = AiChatPhase.running;
    });
  }

  @override
  Future<void> send(String text) async => sent.add(text);
  @override
  void stop() => stops++;
  @override
  void startNewConversation() {}
  @override
  Future<void> useProvider(String providerId) async {}
  @override
  Future<void> recheck() async {}
  @override
  void markReported(AiAssistantItem item) {}
  @override
  set confirmCleartext(Future<bool> Function()? callback) =>
      cleartext = callback;
  @override
  String displaySafe(String text) => text;
  @override
  String draftSafe(String text) => text;

  void update(void Function() change) {
    change();
    notifyListeners();
  }
}

Widget _host(Widget child, {String tag = 'zh-TW', double scale = 1}) {
  final locale = tag == 'ar' ? const Locale('ar') : const Locale('zh', 'TW');
  return MaterialApp(
    theme: appTheme(Brightness.light),
    locale: locale,
    supportedLocales: const [Locale('zh', 'TW'), Locale('ar')],
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

const _resume = ValueKey('ai-chat-resume');
const _card = ValueKey('ai-chat-run-paused');
const _foregroundOnly = ValueKey('ai-chat-foreground-only');

void main() {
  group('explicit foreground resume', () {
    testWidgets('Continue appears only while the run can be resumed', (
      tester,
    ) async {
      final session = _Session()
        ..executionPause = const AiExecutionPause(
          AiExecutionPauseReason.permitInactive,
        );
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      // Paused, but the controller does not allow continuing yet.
      expect(find.byKey(_card), findsOneWidget);
      expect(find.text(l10n.aiRunPausedForeground), findsOneWidget);
      expect(find.byKey(_resume), findsNothing);
      session.update(() => session.resumable = true);
      await tester.pump();
      expect(find.byKey(_resume), findsOneWidget);
      // A blocker takes over: nothing can be continued.
      session.update(() => session.blocker = AiChatBlocker.keyMissing);
      await tester.pump();
      expect(find.byKey(_resume), findsNothing);
      expect(find.byKey(_card), findsNothing);
      session.update(() => session.blocker = AiChatBlocker.none);
      await tester.pump();
      // The foreground alone never continues the run.
      expect(session.resumes, 0);
    });

    testWidgets('Continue resumes the same run and sends no message', (
      tester,
    ) async {
      final session = _Session()
        ..resumable = true
        ..executionPause = const AiExecutionPause(
          AiExecutionPauseReason.foregroundRequired,
        );
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')),
        'Draft kept for later',
      );
      await tester.tap(find.byKey(_resume));
      // The run goes on (its progress indicator never settles).
      await tester.pump();
      await tester.pump();
      // No warnings: no dialog.
      expect(find.byType(AlertDialog), findsNothing);
      expect(session.resumes, 1);
      expect(session.sent, isEmpty);
      expect(session.items.whereType<AiUserItem>(), hasLength(1));
      expect(session.cleartext, isNotNull);
      // The typed text stays in the composer.
      expect(find.text('Draft kept for later'), findsOneWidget);
      expect(find.byKey(_card), findsNothing);
      expect(find.byKey(const ValueKey('ai-chat-stop')), findsOneWidget);
    });

    testWidgets('a possible duplicate and rebilling are confirmed first', (
      tester,
    ) async {
      final session = _Session()
        ..resumable = true
        ..resumeWarnings = {
          AiRunResumeWarning.possibleDuplicate,
          AiRunResumeWarning.possibleRebilling,
        }
        ..executionPause = const AiExecutionPause(
          AiExecutionPauseReason.permitInactive,
          kind: AiContinuationKind.mutation,
        );
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_resume));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(l10n.aiRunResumeTitle), findsOneWidget);
      expect(
        find.text(
          '${l10n.aiRunResumeDuplicate}\n\n${l10n.aiRunResumeRebilling}',
        ),
        findsOneWidget,
      );
      // Cancel does nothing.
      await tester.tap(find.text(l10n.cancelAction));
      await tester.pumpAndSettle();
      expect(session.resumes, 0);
      expect(session.sent, isEmpty);
      expect(find.byKey(_resume), findsOneWidget);
      // Confirm continues once.
      await tester.tap(find.byKey(_resume));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.confirmAction));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(session.resumes, 1);
      expect(session.sent, isEmpty);
    });

    for (final (warning, shown, hidden) in [
      (
        AiRunResumeWarning.possibleRebilling,
        l10n.aiRunResumeRebilling,
        l10n.aiRunResumeDuplicate,
      ),
      (
        AiRunResumeWarning.possibleDuplicate,
        l10n.aiRunResumeDuplicate,
        l10n.aiRunResumeRebilling,
      ),
    ]) {
      testWidgets('only the applicable warning is shown: ${warning.name}', (
        tester,
      ) async {
        final session = _Session()
          ..resumable = true
          ..resumeWarnings = {warning};
        await tester.pumpWidget(_host(AiChatPage(session: session)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(_resume));
        await tester.pumpAndSettle();
        expect(find.text(shown), findsOneWidget);
        expect(find.textContaining(hidden), findsNothing);
        await tester.tap(find.text(l10n.cancelAction));
        await tester.pumpAndSettle();
        expect(session.resumes, 0);
      });
    }

    testWidgets('a run gone between tap and confirmation is not resumed', (
      tester,
    ) async {
      final session = _Session()
        ..resumable = true
        ..resumeWarnings = {AiRunResumeWarning.possibleRebilling};
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_resume));
      await tester.pumpAndSettle();
      session.resumable = false;
      await tester.tap(find.text(l10n.confirmAction));
      await tester.pumpAndSettle();
      expect(session.resumes, 0);
    });
  });

  testWidgets('the page continues a real controller run without a new '
      'message', (tester) async {
    final h = (await tester.runAsync(fx.StackHarness.create))!;
    var disposed = false;
    addTearDown(() {
      if (!disposed) h.dispose();
    });
    h.provider.script.add((_) {
      // Stopped while the model answers: the same run can be continued.
      h.controller.stop();
      return fx.toolTurn('read_file', {
        'path': 'README.md',
        'revision': 'head',
      });
    });
    await tester.runAsync(() async {
      await h.controller.send('inspect the file');
      await fx.waitFor(() => h.controller.canResumeRun);
    });
    expect(h.provider.bodies, hasLength(1));
    await tester.pumpWidget(_host(AiChatPage(session: h.controller)));
    await tester.pump();
    expect(find.byKey(_resume), findsOneWidget);
    await tester.tap(find.byKey(_resume));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The provider already answered once in this run.
    expect(find.text(l10n.aiRunResumeRebilling), findsOneWidget);
    await tester.tap(find.text(l10n.confirmAction));
    for (var i = 0; i < 200 && h.controller.lastEnd != AiRunEnd.done; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(h.controller.lastEnd, AiRunEnd.done);
    expect(h.provider.bodies, hasLength(2));
    expect(h.controller.items.whereType<AiUserItem>(), hasLength(1));
    expect(find.byKey(_resume), findsNothing);
    await tester.pumpWidget(const SizedBox());
    // Timers the resumed run armed in the test zone end with the harness.
    disposed = true;
    h.dispose();
    await tester.pump(const Duration(minutes: 13));
  });

  testWidgets('a slow real service start shows the timeout reason '
      '(Codex 2, channel to controller to page)', (tester) async {
    final h = (await tester.runAsync(fx.StackHarness.create))!;
    const channel = MethodChannel('io.gitlabmobile/c5_ui_slow_start');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var starts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'startRuns':
          starts++;
          // Longer than the bridge's one-second start allowance.
          await Future<void>.delayed(const Duration(milliseconds: 1300));
          return {'version': 1, 'status': 'rejected', 'reason': 'start_denied'};
        case 'releaseRuns':
          return {'version': 1, 'status': 'released', 'didRelease': false};
        case 'stopAll':
          return {'version': 1, 'status': 'stopped'};
        case 'acquireContinuation':
          return {
            'version': 1,
            'status': 'rejected',
            'reason': 'permit_inactive',
          };
      }
      // moveTaskToBack: the handshake that seeds the operation sequence.
      return {
        'version': 1,
        'status': 'unsupported',
        'reason': 'not_implemented',
      };
    });
    final owner = AiBackgroundExecution(
      accountKey: h.account,
      generation: h.session.generation,
      ownerApi: h.session.api!,
      isCurrent: () => !h.controller.isDisposed,
      appInForeground: () => h.foreground,
      channel: channel,
    );
    var disposed = false;
    void cleanUp() {
      if (disposed) return;
      disposed = true;
      owner.dispose();
      h.dispose();
      messenger.setMockMethodCallHandler(channel, null);
    }

    addTearDown(cleanUp);
    h.controller.bindBackgroundExecution(owner);
    await tester.runAsync(() async {
      await h.controller.send('inspect the file');
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    expect(starts, 1);
    expect(
      h.controller.serviceStartResult?.disposition,
      AiBackgroundStartDisposition.invalidated,
    );
    expect(
      h.controller.serviceStartResult?.failure,
      AiBackgroundStartFailure.timeout,
    );
    expect(h.controller.executionPause, isNotNull);
    expect(h.provider.bodies, isEmpty);
    await tester.pumpWidget(_host(AiChatPage(session: h.controller)));
    await tester.pump();
    final card = find.byKey(_card);
    expect(
      find.descendant(of: card, matching: find.text(l10n.aiRunStartTimeout)),
      findsOneWidget,
    );
    expect(find.text(l10n.aiRunPausedForeground), findsNothing);
    expect(find.byKey(_foregroundOnly), findsNothing);
    await tester.pumpWidget(const SizedBox());
    cleanUp();
    await tester.pump(const Duration(minutes: 13));
  });

  group('paused and invalidated states', () {
    for (final (reason, text, icon) in [
      (
        AiExecutionPauseReason.foregroundRequired,
        () => l10n.aiRunPausedForeground,
        Icons.pause_circle_outline,
      ),
      (
        AiExecutionPauseReason.permitInactive,
        () => l10n.aiRunPausedForeground,
        Icons.pause_circle_outline,
      ),
      (
        AiExecutionPauseReason.timeout,
        () => l10n.aiRunPausedTimeout,
        Icons.timer_off_outlined,
      ),
      (
        AiExecutionPauseReason.runLimit,
        () => l10n.aiChatTooManyRunning('3'),
        Icons.hourglass_top,
      ),
      for (final internal in [
        AiExecutionPauseReason.unavailable,
        AiExecutionPauseReason.ticketExpired,
        AiExecutionPauseReason.invalidTicket,
        AiExecutionPauseReason.runChanged,
        AiExecutionPauseReason.nonceReplayed,
        AiExecutionPauseReason.nonceCapacity,
      ])
        (internal, () => l10n.aiRunPaused, Icons.pause_circle_outline),
    ]) {
      testWidgets('pause ${reason.name} shows an icon and a label', (
        tester,
      ) async {
        final session = _Session()
          ..executionStatus = AiChatExecutionStatus.paused
          ..executionPause = AiExecutionPause(
            reason,
            kind: AiContinuationKind.model,
          );
        await tester.pumpWidget(_host(AiChatPage(session: session)));
        await tester.pumpAndSettle();
        final card = find.byKey(_card);
        expect(
          find.descendant(of: card, matching: find.text(text())),
          findsOne,
        );
        expect(
          find.descendant(of: card, matching: find.byIcon(icon)),
          findsOne,
        );
        // Internal names never reach the screen.
        for (final internal in [reason.name, 'model', 'ticket', 'nonce']) {
          expect(
            find.descendant(of: card, matching: find.textContaining(internal)),
            findsNothing,
          );
        }
      });
    }

    testWidgets('an invalidated run that can continue says to keep the app '
        'open', (tester) async {
      final session = _Session()
        ..resumable = true
        ..executionStatus = AiChatExecutionStatus.invalidated;
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiRunPausedForeground), findsOneWidget);
      expect(find.byKey(_resume), findsOneWidget);
    });

    testWidgets('a stopped run that can continue offers Continue', (
      tester,
    ) async {
      final session = _Session()
        ..resumable = true
        ..lastEnd = AiRunEnd.stopped;
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiRunCanResume), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
      expect(find.byKey(_resume), findsOneWidget);
    });

    testWidgets('no card without a pause or a continuable run', (tester) async {
      final session = _Session()
        ..executionStatus = AiChatExecutionStatus.invalidated;
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.byKey(_card), findsNothing);
      // Nor while the run is going on.
      session.update(() {
        session.phase = AiChatPhase.running;
        session.resumable = true;
        session.executionPause = const AiExecutionPause(
          AiExecutionPauseReason.permitInactive,
        );
      });
      await tester.pump();
      expect(find.byKey(_card), findsNothing);
    });
  });

  group('refused background start', () {
    for (final (failure, reason) in [
      (AiBackgroundStartFailure.startDenied, () => l10n.aiRunStartDenied),
      (AiBackgroundStartFailure.securityException, () => l10n.aiRunStartDenied),
      (AiBackgroundStartFailure.timeout, () => l10n.aiRunStartTimeout),
      (
        AiBackgroundStartFailure.channelRefused,
        () => l10n.aiRunStartUnavailable,
      ),
      (
        AiBackgroundStartFailure.channelUnavailable,
        () => l10n.aiRunStartUnavailable,
      ),
    ]) {
      testWidgets('${failure.name} is explained while the run goes on', (
        tester,
      ) async {
        final session = _Session()
          ..phase = AiChatPhase.running
          ..serviceStartResult = AiBackgroundStartResult(
            AiBackgroundStartDisposition.foregroundOnly,
            failure: failure,
          );
        await tester.pumpWidget(_host(AiChatPage(session: session)));
        await tester.pump();
        final row = find.byKey(_foregroundOnly);
        expect(row, findsOneWidget);
        expect(
          find.descendant(
            of: row,
            matching: find.text(l10n.aiRunForegroundOnly),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: find.text(reason())),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.smartphone), findsOneWidget);
        // The run itself is not touched.
        expect(find.byKey(const ValueKey('ai-chat-stop')), findsOneWidget);
        expect(session.stops, 0);
      });
    }

    testWidgets('unconfirmed cleanup forbids continuing, even in the '
        'foreground (Codex 3)', (tester) async {
      final session = _Session()
        ..resumable = true
        ..executionPause = const AiExecutionPause(
          AiExecutionPauseReason.permitInactive,
        )
        ..serviceStartResult = const AiBackgroundStartResult(
          AiBackgroundStartDisposition.unavailable,
          failure: AiBackgroundStartFailure.cleanupFailed,
        );
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      final card = find.byKey(_card);
      expect(
        find.descendant(
          of: card,
          matching: find.text(l10n.aiRunCleanupPending),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text(l10n.aiRunCleanupRetry)),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.sync_problem), findsOneWidget);
      // No foreground-continuation wording and nothing to tap.
      expect(find.byKey(_resume), findsNothing);
      expect(find.byKey(_foregroundOnly), findsNothing);
      expect(find.text(l10n.aiRunForegroundOnly), findsNothing);
      expect(find.text(l10n.aiRunPausedForeground), findsNothing);
      expect(session.resumes, 0);
      // While a run still winds down there is no foreground-only row either.
      session.update(() => session.phase = AiChatPhase.awaitingApproval);
      await tester.pump();
      expect(find.byKey(_foregroundOnly), findsNothing);
      expect(find.text(l10n.aiRunForegroundOnly), findsNothing);
    });

    testWidgets('an invalidated start names its reason on the pause card '
        '(Codex 2)', (tester) async {
      final session = _Session()
        ..executionPause = const AiExecutionPause(
          AiExecutionPauseReason.permitInactive,
        )
        ..serviceStartResult = const AiBackgroundStartResult(
          AiBackgroundStartDisposition.invalidated,
          failure: AiBackgroundStartFailure.timeout,
        );
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      final card = find.byKey(_card);
      expect(
        find.descendant(of: card, matching: find.text(l10n.aiRunPaused)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text(l10n.aiRunStartTimeout)),
        findsOneWidget,
      );
      expect(find.text(l10n.aiRunPausedForeground), findsNothing);
      // Paused, not a foreground fallback.
      expect(find.byKey(_foregroundOnly), findsNothing);
      expect(find.byKey(_resume), findsNothing);
      // Continuing stays explicit when the controller allows it.
      session.update(() => session.resumable = true);
      await tester.pump();
      expect(find.byKey(_resume), findsOneWidget);
      expect(find.text(l10n.aiRunStartTimeout), findsOneWidget);
    });

    testWidgets('after the run, sending still works in the foreground', (
      tester,
    ) async {
      final session = _Session()
        ..phase = AiChatPhase.running
        ..serviceStartResult = const AiBackgroundStartResult(
          AiBackgroundStartDisposition.foregroundOnly,
          failure: AiBackgroundStartFailure.startDenied,
        );
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pump();
      expect(find.byKey(_foregroundOnly), findsOneWidget);
      // The run ended normally: the explanation goes with it.
      session.update(() {
        session.phase = AiChatPhase.idle;
        session.lastEnd = AiRunEnd.done;
      });
      await tester.pumpAndSettle();
      expect(find.byKey(_foregroundOnly), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')),
        'And the tests?',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
      await tester.pumpAndSettle();
      expect(session.sent, ['And the tests?']);
    });

    testWidgets('a paused run keeps the explanation by its card', (
      tester,
    ) async {
      final session = _Session()
        ..resumable = true
        ..executionPause = const AiExecutionPause(
          AiExecutionPauseReason.foregroundRequired,
        )
        ..serviceStartResult = const AiBackgroundStartResult(
          AiBackgroundStartDisposition.foregroundOnly,
          failure: AiBackgroundStartFailure.startDenied,
        );
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      expect(find.byKey(_foregroundOnly), findsOneWidget);
      expect(find.byKey(_card), findsOneWidget);
    });

    for (final failure in [
      AiBackgroundStartFailure.unsupported,
      AiBackgroundStartFailure.foregroundRequired,
      AiBackgroundStartFailure.runChanged,
      null,
    ]) {
      testWidgets('no explanation for ${failure?.name ?? "no failure"}', (
        tester,
      ) async {
        final session = _Session()
          ..phase = AiChatPhase.running
          ..serviceStartResult = AiBackgroundStartResult(
            AiBackgroundStartDisposition.foregroundOnly,
            failure: failure,
          );
        await tester.pumpWidget(_host(AiChatPage(session: session)));
        await tester.pump();
        expect(find.byKey(_foregroundOnly), findsNothing);
      });
    }

    testWidgets('an active or invalidated start is not a refusal', (
      tester,
    ) async {
      final session = _Session()
        ..phase = AiChatPhase.running
        ..serviceStartResult = const AiBackgroundStartResult(
          AiBackgroundStartDisposition.active,
        );
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pump();
      expect(find.byKey(_foregroundOnly), findsNothing);
      session.update(
        () => session.serviceStartResult = const AiBackgroundStartResult(
          AiBackgroundStartDisposition.invalidated,
          failure: AiBackgroundStartFailure.startDenied,
        ),
      );
      await tester.pump();
      expect(find.byKey(_foregroundOnly), findsNothing);
    });
  });

  group('layout', () {
    for (final (tag, scale) in [('zh-TW', 2.0), ('ar', 2.0), ('ar', 1.0)]) {
      testWidgets('small phone, $tag at ${scale}x', (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final session = _Session()
          ..resumable = true
          ..resumeWarnings = {
            AiRunResumeWarning.possibleDuplicate,
            AiRunResumeWarning.possibleRebilling,
          }
          ..executionPause = const AiExecutionPause(
            AiExecutionPauseReason.foregroundRequired,
          )
          ..serviceStartResult = const AiBackgroundStartResult(
            AiBackgroundStartDisposition.foregroundOnly,
            failure: AiBackgroundStartFailure.securityException,
          );
        await tester.pumpWidget(
          _host(
            AiChatPage(session: session),
            tag: tag,
            scale: scale,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (tag == 'ar') {
          expect(
            Directionality.of(tester.element(find.byKey(_card))),
            TextDirection.rtl,
          );
        }
        await tester.ensureVisible(find.byKey(_resume));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(_resume));
        await tester.pumpAndSettle();
        // The dialog's text scrolls rather than overflowing.
        expect(tester.takeException(), isNull);
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text(l10n.confirmAction));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        expect(session.resumes, 1);
      });
    }
  });
}
