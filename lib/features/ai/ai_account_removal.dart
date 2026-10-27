import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/ai/tools/gitlab_write_port.dart' as port;
import '../../core/ai/tools/write_coordinator.dart';
import '../../core/failure.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../shared/artifact_storage.dart';
import '../../shared/workspace_ui.dart';
import '../auth/recent_project.dart';
import '../auth/session_controller.dart';
import '../workspace/editor.dart';
import 'ai_account_cleanup.dart';
import 'ai_attachment_session.dart';
import 'ai_chat_controller.dart';
import 'ai_chat_session.dart';
import 'ai_run_registry.dart';
import 'ai_stores.dart';
import 'ai_write_journal.dart';

/// The dialog the removal job asks the page to show (§8 account removal).
enum AiRemovalPromptKind {
  /// Step 2: runs or proposals are still active. [AiRemovalPrompt.count] is
  /// the number of conversations that will be stopped.
  stopRuns,

  /// Step 4 when the journal still isolates writes, holds a confirmation
  /// mark or cannot be read: `confirmAction(requiredText: '@username')`.
  typeUsername,

  /// Step 4 otherwise: the existing removal confirmation.
  plainConfirm,
}

final class AiRemovalPrompt {
  const AiRemovalPrompt(this.kind, {this.count = 0, this.unreadable = false});

  final AiRemovalPromptKind kind;

  /// [AiRemovalPromptKind.stopRuns]: conversations to stop.
  /// [AiRemovalPromptKind.typeUsername]: `dispatching` and `writeUncertain`
  /// rows in the journal.
  final int count;

  /// The journal could not be read (error, time-out, `keyMissing`, unknown
  /// format, over size or `unavailable`).
  final bool unreadable;
}

enum AiRemovalStatus { removed, cancelled, notRemoved }

/// How far the job got into the account's AI data when it ended.
enum AiRemovalDataState {
  /// `clearAiAccountData` was not entered; AI data and the journal are as
  /// they were.
  untouched,

  /// `clearAiAccountData` was entered and failed; it may have partly run.
  cleanupStarted,

  /// `clearAiAccountData` finished: consent, history and the journal are gone.
  cleared,
}

/// Outcome of one removal job. [reason] is a stable code; the page maps it
/// to existing wording in [presentAiRemovalResult].
///
/// Codes: `removed`; cancelled: `stopCancelled`, `finalCancelled`,
/// `waitTimedOut` (the final dialog was cancelled after the in-flight wait
/// hit its limit), `removalCancelled` (the page went away before the final
/// confirmation), `refused` (another job holds this account); not removed:
/// `beforeAiCleanupFailed`, `retryRemovalLater` (the journal could not take
/// the removal-start mark), `aiCleanupFailed`, `accountRetained`
/// (`SessionController.remove` returned with the account still listed).
final class AiRemovalResult {
  const AiRemovalResult(this.status, this.reason, this.dataState, [this.error]);

  final AiRemovalStatus status;
  final String reason;
  final AiRemovalDataState dataState;
  final Object? error;

  /// Results a page shows; the others need no notice.
  bool get presentable =>
      status == AiRemovalStatus.notRemoved || reason == 'waitTimedOut';
}

final class _Judgment {
  const _Judgment(this.kind, {this.count = 0, this.unreadable = false});

  final AiRemovalPromptKind kind;
  final int count;
  final bool unreadable;
}

final class _RemovalChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// Process-level removal job shared by the signed-in shell and the
/// signed-out account list (§8 account removal, §12.1).
///
/// The hold ([AiRemovalJob]) belongs to the process journal, not to a page.
/// A page that goes away only requests cancellation, which takes effect
/// before the final confirmation and is ignored after it. This class never
/// calls `beginCleaning`: the hold and history cleaning are separate states.
final class AiAccountRemoval {
  AiAccountRemoval._();

  /// §12.1: connect 15 s + send 15 s + receive idle 25 s.
  static const writeWaitLimit = Duration(seconds: 55);

  /// §3.1: an upload's send time-out replaces the 15 s send budget.
  static final uploadWaitLimit =
      const Duration(seconds: 15 + 25) +
      port.GitLabAiWritePort.uploadMaximumSendTimeout;

  /// Reading the journal or writing its removal-start mark.
  static const journalWaitLimit = Duration(seconds: 10);

  static final Set<String> _running = <String>{};
  static final Map<String, AiRemovalResult> _results = {};
  static final _RemovalChanges _changes = _RemovalChanges();

  /// Notifies when a job starts or ends, so both entry points can disable
  /// switching, removal and sign-out and show a result the other page left.
  static Listenable get changes => _changes;

  /// True while any removal job runs (it holds its token throughout).
  static bool get anyRunning => _running.isNotEmpty;

  static bool isRunning(String accountKey) => _running.contains(accountKey);

  /// A result the job could not show because its page went away. Kept in
  /// memory only; read once.
  static AiRemovalResult? takeResult(String accountKey) =>
      _results.remove(accountKey);

  @visibleForTesting
  static void debugReset() {
    _running.clear();
    _results.clear();
  }

  /// Step 1: creates the job and takes the hold synchronously, before any
  /// dialog. Null when another job already holds this account (or a journal
  /// reset is running); the second entry point is refused. Call [run] in the
  /// same synchronous section.
  static AiRemovalJob? begin(String accountKey, {AiWriteJournal? journal}) {
    try {
      return (journal ?? writeJournalForCleanup).beginRemoval(accountKey);
    } on AiJournalException {
      return null;
    }
  }

  static bool _stopped(AiRemovalJob job) =>
      job.cancelRequestedBeforeFinalConfirm || !job.holds(job.token);

  static void _requireToken(AiRemovalJob job) {
    if (!job.holds(job.token)) {
      throw const AiJournalException('invalidRemovalToken');
    }
  }

  /// Every dialog is awaited together with the job's own cancellation:
  /// Flutter never completes `showDialog` when its Navigator is released.
  static Future<bool> _ask(
    AiRemovalJob job,
    Future<bool> Function(AiRemovalPrompt prompt) confirm,
    AiRemovalPrompt prompt,
  ) async {
    if (_stopped(job)) return false;
    final Future<bool> answer;
    try {
      answer = confirm(prompt);
    } on Object {
      return false;
    }
    final guarded = answer.then<bool>(
      (value) => value,
      onError: (Object _, StackTrace _) => false,
    );
    return Future.any<bool>([guarded, job.cancellation.then((_) => false)]);
  }

  /// Runs steps 2–5 for [job], which the caller took with [begin].
  ///
  /// [requestCancelOnDispose] is called once before the first await; the
  /// caller arms its `dispose` there to call `job.requestCancel()` and close
  /// its dialog. [waitForInFlightWrites] stops the account's runs and waits
  /// for writes past their acceptance point to settle (it must not throw).
  /// [consultJournal] is false while this build has no process journal
  /// wired: nothing can have been written, so the plain dialog is kept.
  static Future<AiRemovalResult> run({
    required Account account,
    required AiRemovalJob job,
    required SessionController session,
    required Future<bool> Function(AiRemovalPrompt prompt) confirm,
    required Future<void> Function() waitForInFlightWrites,
    required void Function() requestCancelOnDispose,
    int runningOrPending = 0,
    ValueChanged<bool>? onWaiting,
    AiWriteJournal? journal,
    bool? consultJournal,
    Duration waitLimit = writeWaitLimit,
    Duration journalLimit = journalWaitLimit,
    Future<void> Function(Account account)? clearDrafts,
    Future<void> Function(Account account)? clearArtifacts,
    Future<void> Function(Account account)? clearRecent,
    Future<void> Function(Account account)? clearReadCacheDisk,
    Future<void> Function(Account account)? clearAi,
  }) async {
    final owner = journal ?? writeJournalForCleanup;
    final readJournal = consultJournal ?? writeJournalWired;
    var dataState = AiRemovalDataState.untouched;
    var finalShown = false;
    var accepted = false;
    var accountRemovalCommitted = false;
    var timedOut = false;

    AiRemovalResult done(
      AiRemovalStatus status,
      String reason, [
      Object? error,
    ]) {
      if (accepted && status != AiRemovalStatus.cancelled) {
        session.readCache.finishAccountRemoval(
          account.key,
          removed: accountRemovalCommitted,
        );
      }
      final result = AiRemovalResult(status, reason, dataState, error);
      if (result.presentable) {
        _results[account.key] = result;
      } else {
        _results.remove(account.key);
      }
      return result;
    }

    if (account.key != job.accountKey || !job.holds(job.token)) {
      return AiRemovalResult(
        AiRemovalStatus.cancelled,
        'refused',
        AiRemovalDataState.untouched,
      );
    }
    _running.add(account.key);
    _changes.changed();
    try {
      requestCancelOnDispose();
      // Step 2. Cancelling here leaves runs, proposals and approvals alone.
      if (runningOrPending > 0) {
        final stop = await _ask(
          job,
          confirm,
          AiRemovalPrompt(AiRemovalPromptKind.stopRuns, count: runningOrPending),
        );
        if (!stop || _stopped(job)) {
          return done(AiRemovalStatus.cancelled, 'stopCancelled');
        }
        owner.bumpProposalEpoch(account.key);
      }
      // Writes past their acceptance point finish their terminal state. A
      // cancellation takes effect once this await ends.
      onWaiting?.call(true);
      try {
        await waitForInFlightWrites().timeout(waitLimit);
      } on TimeoutException {
        timedOut = true;
      } on Object {
        // Settlement errors are outcomes of those writes; the journal reread
        // below decides what they mean for this removal.
      } finally {
        onWaiting?.call(false);
      }
      if (_stopped(job)) {
        return done(AiRemovalStatus.cancelled, 'removalCancelled');
      }
      // Step 3.
      final judgment = readJournal
          ? await _judge(owner, account.key, journalLimit)
          : const _Judgment(AiRemovalPromptKind.plainConfirm);
      if (_stopped(job)) {
        return done(AiRemovalStatus.cancelled, 'removalCancelled');
      }
      // Step 4.
      finalShown = true;
      final confirmed = await _ask(
        job,
        confirm,
        AiRemovalPrompt(
          judgment.kind,
          count: judgment.count,
          unreadable: judgment.unreadable,
        ),
      );
      if (!confirmed || _stopped(job)) {
        // Same synchronous section: epoch bump and release, no await.
        job.cancelFinal();
        return done(
          AiRemovalStatus.cancelled,
          timedOut ? 'waitTimedOut' : 'finalCancelled',
        );
      }
      job.confirmFinal();
      accepted = true;
      // From here the job runs to its end; cancellation requests are ignored.
      AiAttachmentSession.discardAccount(account.key);
      for (final step in [
        clearDrafts ?? clearSecureDrafts,
        clearArtifacts ?? clearAccountArtifacts,
        clearRecent ?? clearRecentProject,
        clearReadCacheDisk ??
            (saved) => session.readCache.clearReadCacheDisk(saved.key),
      ]) {
        _requireToken(job);
        await step(account);
        _requireToken(job);
      }
      if (readJournal) {
        try {
          await owner.markRemovalStarted(job).timeout(journalLimit);
        } on Object {
          // Key unavailable, a readable journal that cannot take the mark, or
          // no answer: this counts as a cleanup failure before AI data.
          return done(AiRemovalStatus.notRemoved, 'retryRemovalLater');
        }
        _requireToken(job);
      }
      dataState = AiRemovalDataState.cleanupStarted;
      await (clearAi ?? clearAiAccountData)(account);
      _requireToken(job);
      dataState = AiRemovalDataState.cleared;
      // A staged list is not proof of a persisted removal, especially when
      // another session operation supersedes a save that subsequently fails.
      final removal = await session.remove(account);
      accountRemovalCommitted = removal.removed;
      _requireToken(job);
      if (!removal.removed ||
          session.accounts.any((saved) => saved.key == account.key)) {
        return done(
          AiRemovalStatus.notRemoved,
          'accountRetained',
          removal.failure,
        );
      }
      return done(AiRemovalStatus.removed, 'removed');
    } on Object catch (error) {
      if (!accepted) {
        if (finalShown) job.cancelFinal();
        return done(AiRemovalStatus.cancelled, 'removalCancelled');
      }
      return done(
        AiRemovalStatus.notRemoved,
        switch (dataState) {
          AiRemovalDataState.untouched => 'beforeAiCleanupFailed',
          AiRemovalDataState.cleanupStarted => 'aiCleanupFailed',
          AiRemovalDataState.cleared => 'accountRetained',
        },
        error,
      );
    } finally {
      // Releases only this token's hold: never cleaning, a tombstone,
      // `reset_pending` or journal isolation.
      job.release(job.token);
      _running.remove(account.key);
      _changes.changed();
    }
  }

  static Future<_Judgment> _judge(
    AiWriteJournal journal,
    String accountKey,
    Duration limit,
  ) async {
    const unreadable = _Judgment(
      AiRemovalPromptKind.typeUsername,
      unreadable: true,
    );
    try {
      final status = await journal.keyStatus(accountKey).timeout(limit);
      switch (status) {
        case AiJournalKeyStatus.uninitialized:
        case AiJournalKeyStatus.removed:
          // An earlier removal already asked for the name.
          return const _Judgment(AiRemovalPromptKind.plainConfirm);
        case AiJournalKeyStatus.found:
          final count = journal
              .entries(accountKey)
              .where(
                (entry) =>
                    entry.state == AiJournalState.dispatching ||
                    entry.state == AiJournalState.writeUncertain,
              )
              .length;
          // Conflict keys start with the account key, so this one key
          // intersects every key-level mark; it also sees "reset, confirm".
          final marked = journal.requiresConfirmation(accountKey, {
            AiConflictKey([accountKey]),
          });
          return count > 0 || marked
              ? _Judgment(AiRemovalPromptKind.typeUsername, count: count)
              : const _Judgment(AiRemovalPromptKind.plainConfirm);
        case AiJournalKeyStatus.keyMissing:
        case AiJournalKeyStatus.unavailable:
        case AiJournalKeyStatus.unknownFormat:
        case AiJournalKeyStatus.overSize:
          return unreadable;
      }
    } on Object {
      return unreadable;
    }
  }
}

enum AiSwitchChoice { proceedAndWait, switchNow, cancel }

/// §12.1 guard before switching accounts or signing out. It never takes a
/// removal hold.
final class AiSwitchGuard {
  AiSwitchGuard._();

  /// No dialog when nothing runs or waits for approval.
  static Future<AiSwitchChoice> confirmSwitch({
    required int runningOrPending,
    required Future<AiSwitchChoice> Function(int count) confirm,
  }) async {
    if (runningOrPending <= 0) return AiSwitchChoice.proceedAndWait;
    try {
      return await confirm(runningOrPending);
    } on Object {
      return AiSwitchChoice.cancel;
    }
  }

  /// Stops every run and, for [AiSwitchChoice.proceedAndWait], waits for the
  /// writes in flight to settle, up to [waitLimit]. With
  /// [AiSwitchChoice.switchNow] it does not wait: closing the client turns
  /// each write in flight into `cancelled`, which the coordinator records as
  /// `writeUncertain` (§7.5), so the journal keeps those keys isolated.
  /// A wait that hits its limit switches the same way. Returns false only
  /// for [AiSwitchChoice.cancel].
  static Future<bool> settle({
    required AiSwitchChoice choice,
    required List<Future<AiWriteOutcome>> Function() stopAndSnapshotWrites,
    Duration waitLimit = AiAccountRemoval.writeWaitLimit,
  }) async {
    if (choice == AiSwitchChoice.cancel) return false;
    final writes = stopAndSnapshotWrites();
    if (choice == AiSwitchChoice.switchNow || writes.isEmpty) return true;
    try {
      await _settled(writes).timeout(waitLimit);
    } on TimeoutException {
      // Same as switching now for the writes still in flight.
    }
    return true;
  }
}

Future<void> _settled(List<Future<AiWriteOutcome>> writes) => Future.wait([
  for (final write in writes)
    write.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
]);

AiChatSessionHandle _defaultChatSession({
  required AiChatOrigin origin,
  required SessionController session,
  required AiSettingsController settings,
  required int Function() runningCount,
  AiChatWireClientFactory? wireClientFactory,
}) {
  // Mirrors the registry's private default factory.
  final controller = AiChatController(
    origin: origin,
    session: session,
    settings: settings,
    runningCount: runningCount,
    wireClientFactory: wireClientFactory,
    appInForeground: aiAppInForeground,
    clientMayStart: aiClientMayStart(session),
  );
  return (
    session: controller,
    capacityChanged: controller.notifyCapacityChanged,
    dispose: controller.dispose,
  );
}

/// The live conversations of one account registry, for the stop and switch
/// dialogs. A conversation that only waits for approval counts here but not
/// toward [AiRunRegistry.maxRunning].
final class AiAccountActivity {
  final Set<AiChatSession> _live = <AiChatSession>{};
  AccountAiRunRegistry? _registry;

  /// Wraps the registry's session factory so every conversation it creates
  /// is seen until the registry disposes it.
  AiChatSessionFactory track(AiChatSessionFactory? inner) =>
      ({
        required AiChatOrigin origin,
        required SessionController session,
        required AiSettingsController settings,
        required int Function() runningCount,
        AiChatWireClientFactory? wireClientFactory,
      }) {
        final handle = (inner ?? _defaultChatSession)(
          origin: origin,
          session: session,
          settings: settings,
          runningCount: runningCount,
          wireClientFactory: wireClientFactory,
        );
        final live = handle.session;
        _live.add(live);
        return (
          session: live,
          capacityChanged: handle.capacityChanged,
          dispose: () {
            _live.remove(live);
            handle.dispose();
          },
        );
      };

  void attach(AccountAiRunRegistry registry) => _registry = registry;

  /// Conversations running, stopping, waiting for approval or holding a
  /// proposal.
  int get runningOrPending => _live.where((session) {
    final phase = session.phase;
    return phase == AiChatPhase.running ||
        phase == AiChatPhase.stopping ||
        phase == AiChatPhase.awaitingApproval ||
        session.proposals.isNotEmpty;
  }).length;

  /// The §12.1 limit; an upload in a proposal uses the §3.1 send time-out.
  /// Read it before stopping: stopping invalidates the proposals.
  Duration get waitLimit =>
      _live.any(
        (session) => session.proposals.any(
          (proposal) => proposal.operationId == 'upload_attachment',
        ),
      )
      ? AiAccountRemoval.uploadWaitLimit
      : AiAccountRemoval.writeWaitLimit;

  /// Stops every run of the registry and returns the writes still in flight.
  List<Future<AiWriteOutcome>> stopAndSnapshotWrites() {
    final registry = _registry;
    if (registry == null || registry.isDisposed) {
      return const <Future<AiWriteOutcome>>[];
    }
    return registry.stopAndSnapshotWrites();
  }

  /// Stops the runs and waits until every write in flight has settled, up to
  /// [waitLimit] as it stands just before stopping; past it this throws
  /// [TimeoutException].
  Future<void> stopAndWait() {
    final limit = waitLimit;
    return _settled(stopAndSnapshotWrites()).timeout(limit);
  }
}

/// The existing confirm and alert dialogs for removal and switching. Owns
/// only the route it showed last, so a page can close it when it goes away.
final class AiAccountDialogs {
  AiAccountDialogs(this.context);

  final BuildContext context;
  Route<dynamic>? _route;
  NavigatorState? _navigator;

  void _own(Route<dynamic> route) {
    _route = route;
    _navigator = route.navigator;
  }

  /// Removes the dialog this page showed, if its Navigator still exists.
  void close() {
    final route = _route;
    final navigator = _navigator;
    _route = null;
    _navigator = null;
    if (route == null || navigator == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!navigator.mounted || !route.isActive) return;
      navigator.removeRoute(route);
    });
  }

  Future<bool> confirmRemoval(Account account, AiRemovalPrompt prompt) async {
    if (!context.mounted) return false;
    try {
      if (prompt.kind == AiRemovalPromptKind.stopRuns) {
        return await _stopRuns(prompt.count);
      }
      final username = '@${account.user.username}';
      final named = prompt.kind == AiRemovalPromptKind.typeUsername;
      return await confirmAction(
        context,
        l10n.removeThisAccountQuestion,
        named
            ? [
                if (prompt.unreadable)
                  l10n.aiRemoveJournalUnreadable
                else if (prompt.count > 0)
                  l10n.aiRemoveUncertainWrites('${prompt.count}'),
                l10n.aiRemoveTypeUsernameDetail(username),
              ].join('\n\n')
            : l10n.removeAccountKeepsRemoteToken,
        requiredText: named ? username : null,
        onRoute: _own,
      );
    } on Object {
      return false;
    } finally {
      _route = null;
    }
  }

  Future<bool> _stopRuns(int count) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final route = ModalRoute.of(dialogContext);
        if (route != null) _own(route);
        return AlertDialog(
          title: Text(l10n.aiRemoveStopRunsTitle),
          content: Text(l10n.aiRemoveStopRunsDetail(count)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(l10n.cancelAction),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(l10n.aiRemoveStopRunsConfirm),
            ),
          ],
        );
      },
    );
    return answer ?? false;
  }

  Future<AiSwitchChoice> confirmSwitch(int count) async {
    if (!context.mounted) return AiSwitchChoice.cancel;
    try {
      final answer = await showDialog<AiSwitchChoice>(
        context: context,
        builder: (dialogContext) {
          final route = ModalRoute.of(dialogContext);
          if (route != null) _own(route);
          return AlertDialog(
            title: Text(l10n.aiSwitchTitle),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.aiSwitchDetail(count)),
                  const SizedBox(height: 16),
                  Text(l10n.aiSwitchNowNote),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, AiSwitchChoice.cancel),
                child: Text(l10n.cancelAction),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.pop(dialogContext, AiSwitchChoice.switchNow),
                child: Text(l10n.aiSwitchNow),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  AiSwitchChoice.proceedAndWait,
                ),
                child: Text(l10n.aiSwitchWait),
              ),
            ],
          );
        },
      );
      return answer ?? AiSwitchChoice.cancel;
    } on Object {
      return AiSwitchChoice.cancel;
    } finally {
      _route = null;
    }
  }
}

/// Shows a removal result with existing wording. The reason codes without a
/// sentence of their own fall back to "the account remains, retry removal".
void presentAiRemovalResult(BuildContext context, AiRemovalResult result) {
  if (!context.mounted || !result.presentable) return;
  if (result.reason == 'waitTimedOut') {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(l10n.aiRemoveWaitTimedOut)));
    return;
  }
  final error = result.error;
  if (error != null) {
    showFailure(context, error);
    return;
  }
  if (result.reason == 'aiCleanupFailed') {
    showFailure(context, const ApiFailure(FailureKind.aiHistoryCleanup));
    return;
  }
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(l10n.accountRemainsRetryRemoval)));
}
