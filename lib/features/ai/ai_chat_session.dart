import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/ai/ai_display.dart';
import '../../core/ai/ai_failure.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/ai/runner.dart';
import '../../core/ai/execution_gate.dart';
import '../../core/ai/tools/write_coordinator.dart';
import 'ai_attachment_session.dart';
import 'ai_background_execution.dart';
import '../../core/failure.dart';
import '../../core/group_work_item_identity.dart';
import '../../core/models.dart';
import '../../core/work_item_graph_models.dart';

/// Where a conversation starts. It decides the first context the assistant
/// reads and the resource its read-only tools are bound to. An origin carries
/// identifiers only; the session loads and pins the content itself.
sealed class AiChatOrigin {
  const AiChatOrigin();

  /// Identity used by [AiRunRegistry.open] to return an existing session.
  String get key;
}

/// A conversation that is not about one resource (opened from Me). It has no
/// project. The Inbox specialization grants only account-global todo writes.
final class AiGeneralOrigin extends AiChatOrigin {
  const AiGeneralOrigin();

  @override
  String get key => 'general';
}

/// Opened explicitly from the current account's todo Inbox. It uses the
/// general conversation's empty context and grants only account-global todos,
/// never a project or its resources. The registry supplies account isolation.
final class AiInboxOrigin extends AiGeneralOrigin {
  const AiInboxOrigin();

  @override
  String get key => 'inbox';
}

/// A CI job and its log.
final class AiJobOrigin extends AiChatOrigin {
  const AiJobOrigin({
    required this.project,
    required this.jobId,
    required this.jobName,
  });

  final Project project;
  final int jobId;
  final String jobName;

  @override
  String get key => 'job:${project.id}:$jobId';
}

enum AiWorkItemKind { issue, mergeRequest }

/// An issue or a merge request.
final class AiWorkItemOrigin extends AiChatOrigin {
  const AiWorkItemOrigin({
    required this.project,
    required this.kind,
    required this.iid,
    required this.title,
    this.summarize = false,
  });

  final Project project;
  final AiWorkItemKind kind;
  final int iid;
  final String title;

  /// Opened through "AI summary": the page sends the summary request itself
  /// once the session is ready (MR only).
  final bool summarize;

  @override
  String get key => 'item:${project.id}:${kind.name}:$iid';
}

/// A directly Group-owned Work Item. [group] is the item's namespace, which
/// can differ from the ancestor group whose descendant list displayed it.
/// These coordinates select a fresh strict read; they are not a write grant.
final class AiGroupWorkItemOrigin extends AiChatOrigin {
  const AiGroupWorkItemOrigin({
    required this.group,
    required this.iid,
    required this.title,
  });

  final GraphResourceRef group;
  final int iid;
  final String title;

  /// Page adapters call this only with the namespace from a fresh detail.
  /// Invalid Group GIDs never reach the registry's throwing identity getter.
  static AiGroupWorkItemOrigin? tryCreate({
    required GraphResourceRef group,
    required int iid,
    required String title,
  }) => groupKeyNumericId(group.id) == null || iid <= 0
      ? null
      : AiGroupWorkItemOrigin(group: group, iid: iid, title: title);

  int get groupId =>
      groupKeyNumericId(group.id) ??
      (throw const ApiFailure(FailureKind.validation));

  @override
  String get key => 'group-item:$groupId:$iid';
}

/// A project Work Item opened from a group page. The actual project owns the
/// resource; [viewGroupId] only separates this conversation's entry point.
final class AiProjectWorkItemFromGroupPageOrigin extends AiChatOrigin {
  const AiProjectWorkItemFromGroupPageOrigin({
    required this.viewGroupId,
    required this.project,
    required this.iid,
    required this.title,
  });

  final int viewGroupId;
  final Project project;
  final int iid;
  final String title;

  @override
  String get key =>
      'group-page:$viewGroupId:project:${project.id}:workItem:$iid';
}

/// One text file at a commit.
final class AiFileOrigin extends AiChatOrigin {
  const AiFileOrigin({
    required this.project,
    required this.path,
    required this.sha,
  });

  final Project project;
  final String path;
  final String sha;

  @override
  String get key => 'file:${project.id}:$sha:$path';
}

enum AiChatPhase {
  /// Waiting for the user.
  idle,

  /// Loading settings, keys or the starting context before the first send.
  preparing,

  /// A run is in progress (model request, streaming or a tool read).
  running,

  /// The model run is paused until the user accepts or rejects a write.
  awaitingApproval,

  /// Stop was requested; the run is ending.
  stopping,
}

/// Why the user cannot send right now. The page shows the matching action.
enum AiChatBlocker {
  none,

  /// Settings are still loading.
  settingsLoading,

  /// Settings could not be read; the page offers to open AI settings.
  settingsUnavailable,

  /// No provider is configured; the page offers to add one.
  noProvider,

  /// The selected provider needs a key that is not stored.
  keyMissing,

  /// The current account has not agreed to [AiChatSession.consentRequest].
  consentRequired,

  /// Three conversations are already running for this account. Reported
  /// while idle whenever capacity is full, so the page can say why it cannot
  /// send; it clears by itself when a run ends.
  tooManyRunning,

  /// The starting context could not be loaded; [AiChatSession.failure] says
  /// why and [AiChatSession.recheck] retries.
  contextUnavailable,
}

/// Why a ready conversation still cannot send: the account's GitLab request
/// budget, not the conversation, is the limit.
enum AiChatSendBlockReason {
  /// GitLab's remaining requests are critically low until the bucket resets.
  criticalRateBudget,

  /// GitLab asked the app to wait (a 429 cooldown).
  serverCooldown,

  /// Every run lease of the account is still held.
  runBudgetUnavailable,
}

/// A session whose sends also wait for the account's GitLab request budget.
abstract interface class AiChatSendGate {
  /// Why sending is paused, or null when the budget allows a send.
  AiChatSendBlockReason? get sendBlockReason;

  /// When the pause is known to end; null when GitLab gave no time.
  DateTime? get sendBlockedUntil;
}

/// One conversation as the chat page sees it. Implementations notify at most
/// every 100 ms while a reply streams.
abstract interface class AiChatSession implements Listenable {
  String get id;
  AiChatOrigin get origin;

  /// Display items, oldest first. Already redacted.
  List<AiChatItem> get items;

  AiChatPhase get phase;
  AiChatBlocker get blocker;

  /// Providers the user can switch to, in their saved order.
  List<AiProviderConfig> get providers;

  /// The provider this conversation uses, or null when none is configured.
  AiProviderConfig? get provider;

  /// The contract to show in the consent dialog when [blocker] is
  /// [AiChatBlocker.consentRequired].
  AiConsentContract? get consentRequest;

  /// The failure that ended the last run, or that blocks the start. Reading
  /// GitLab keeps its [ApiFailure] (a 404 stays ambiguous); provider errors
  /// are [AiFailure].
  UserFacingFailure? get failure;

  /// Why the last run ended; null before the first run and while one runs.
  /// The page shows an end row for every reason except [AiRunEnd.done].
  AiRunEnd? get lastEnd;

  /// The last run ended because the conversation reached its limit; the page
  /// offers a new conversation.
  bool get offerNewConversation;

  /// Whether this conversation's latest display snapshot was saved.
  bool get historySaved;

  /// A reported answer could not be saved with history enabled: retries were
  /// exhausted or saving needs a new snapshot/state. Clears after a save.
  bool get reportNotSaved;

  bool get canSend;

  /// Sends [text] and runs the assistant. Rejected (no effect) unless
  /// [canSend].
  Future<void> send(String text);

  /// Marks [item] as reported, keeping it in the conversation and saving the
  /// flag when history is enabled. Follows rebuilt items; no-op when there is
  /// no current descendant.
  void markReported(AiAssistantItem item);

  /// The current descendant of [item] after display rebuilds, or null when
  /// its chain no longer reaches an item in this conversation.
  AiAssistantItem? currentOf(AiAssistantItem item);

  /// Reads the live secrets again, including a GitLab token that OAuth
  /// rotated in place, and redacts what is shown when the set grew. False
  /// when they could not be read; text must not leave the device then.
  Future<bool> refreshSecrets();

  /// Stops the current run. The partial reply stays, marked as interrupted.
  void stop();

  /// Starts a new conversation with the same origin and provider.
  void startNewConversation();

  /// Starts a new conversation with [providerId].
  Future<void> useProvider(String providerId);

  /// Re-evaluates [blocker] after the user returns from settings or the
  /// consent dialog.
  Future<void> recheck();

  /// Asked before sending to a cleartext LAN endpoint; the page shows a
  /// confirmation. Null means refuse.
  set confirmCleartext(Future<bool> Function()? callback);

  /// [text] as it may be shown on screen: control and bidirectional
  /// characters removed first, then the live secrets redacted. For GitLab
  /// values the page shows outside [items], such as the title. Never throws:
  /// text that cannot be checked comes back empty.
  String displaySafe(String text);

  /// [text] as it may go into a GitLab comment draft: like [displaySafe], but
  /// line breaks and tabs are kept, so paragraphs, lists and code survive.
  /// Carriage returns are dropped first, as GitLab drops them, so they cannot
  /// split a secret past the redaction.
  /// Never throws: text that cannot be checked comes back empty.
  String draftSafe(String text);
}

/// What the audit row of one write shows besides its run item (§7.7: time,
/// target, result and a GitLab link from the verified instance and ids).
final class AiWriteRow {
  const AiWriteRow({
    required this.operationId,
    this.target = '',
    this.link,
    this.outcome,
    this.settledAt,
  });

  /// The ledger operation; a write row is always a write.
  final String operationId;

  /// The target summary (`#5`, `!12`, a project path, a file name). Empty
  /// until the write's pre-read named it. Redacted.
  final String target;

  /// GitLab page of the target; never a model-supplied URL.
  final Uri? link;

  /// Null while the write waits or runs.
  final AiWriteOutcome? outcome;
  final DateTime? settledAt;
}

/// What a write-capable conversation keeps for its rows and cards: the
/// audit data of each write row and the edited cards that did not run
/// (§7.2, §7.7). The chat controller implements it; small fakes need not.
abstract interface class AiWriteAuditSession {
  /// Cards whose text the user edited, kept after rejection, certain
  /// failure, an unknown result or expiry so the edit is not lost.
  List<AiWriteProposal> get settledWriteEdits;
  void dismissSettledWrite(AiWriteProposal proposal);

  /// The audit data of [item] when it is a write row, else null.
  AiWriteRow? writeRowFor(AiChatItem item);
}

/// Optional write controls implemented only by write-capable conversations.
abstract interface class AiWriteChatSession {
  List<AiWriteProposal> get proposals;
  AiAutonomyLevel get autonomyLevel;

  /// The highest level this conversation may use: the account's ceiling,
  /// capped by what the user agreed to in the consent.
  AiAutonomyLevel get autonomyCeiling;
  Future<void> setAutonomyLevel(AiAutonomyLevel level);

  /// Runs [proposal] once the user approves it. With [editedText] the text
  /// is replaced and checked again, and the outcome asks for a second
  /// approval. [typedName] answers a proposal that needs the name typed.
  Future<AiWriteOutcome> approveWrite(
    AiWriteProposal proposal, {
    String? typedName,
    String? editedText,
  });
  Future<void> rejectWrite(AiWriteProposal proposal);

  /// Files picked for this conversation, oldest first. They stay on the
  /// device until a write uploads one; the model sees only their names,
  /// types and sizes.
  List<AiStoredAttachment> get attachments;

  /// Whether this conversation can take attachments now: its segment offers
  /// the upload tool and the conversation is idle.
  bool get canAttach;

  /// Picks one image or file and keeps it for this conversation.
  Future<AiAttachResult> attach(AiAttachmentPick pick);

  /// Drops an attachment. A proposal that would upload it becomes invalid.
  void removeAttachment(String id);
}

/// Safe defaults keep read-only sessions and small test fakes source-compatible.
extension AiWriteChatSessionAccess on AiChatSession {
  List<AiWriteProposal> get proposals => switch (this) {
    AiWriteChatSession(:final proposals) => proposals,
    _ => const <AiWriteProposal>[],
  };

  AiAutonomyLevel get autonomyLevel => switch (this) {
    AiWriteChatSession(:final autonomyLevel) => autonomyLevel,
    _ => AiAutonomyLevel.readOnly,
  };

  AiAutonomyLevel get autonomyCeiling => switch (this) {
    AiWriteChatSession(:final autonomyCeiling) => autonomyCeiling,
    _ => AiAutonomyLevel.readOnly,
  };

  List<AiStoredAttachment> get attachments => switch (this) {
    AiWriteChatSession(:final attachments) => attachments,
    _ => const <AiStoredAttachment>[],
  };

  Future<void> setAutonomyLevel(AiAutonomyLevel level) => switch (this) {
    AiWriteChatSession() => (this as AiWriteChatSession).setAutonomyLevel(
      level,
    ),
    _ => Future<void>.value(),
  };
}

enum AiRunNotificationKind { needsApproval, completed, failed, interrupted }

/// Routing metadata only. Content and proposal authority stay in the session.
final class AiRunNotificationEvent {
  const AiRunNotificationEvent({
    required this.kind,
    required this.conversationId,
    required this.generation,
  });

  final AiRunNotificationKind kind;
  final String conversationId;
  final int generation;
}

abstract interface class AiRunNotificationSource {
  Stream<AiRunNotificationEvent> get notificationEvents;
}

/// Independent of the page phase so C5 can add explicit continuation UI.
enum AiChatExecutionStatus {
  foregroundOnly,
  starting,
  active,
  released,
  invalidated,
  unavailable,
  paused,
}

abstract interface class AiExecutionChatSession {
  int get serviceWorkCount;
  int get backProtectedCount;
  AiChatExecutionStatus get executionStatus;
}

enum AiRunResumeWarning { possibleDuplicate, possibleRebilling }

/// Optional continuation capability. Resuming is a visible user action and
/// never appends another user message or resets the logical run's budgets.
abstract interface class AiRunContinuationSession {
  AiExecutionPause? get executionPause;
  AiBackgroundStartResult? get serviceStartResult;
  AiBackgroundCleanupConfirmation get cleanupConfirmation;
  bool get canResumeRun;
  Set<AiRunResumeWarning> get resumeWarnings;
  Future<void> resumeRun();
}

extension AiRunContinuationAccess on AiChatSession {
  bool get canResumeRun => switch (this) {
    AiRunContinuationSession session => session.canResumeRun,
    _ => false,
  };

  Future<void> resumeRun() => switch (this) {
    AiRunContinuationSession session => session.resumeRun(),
    _ => Future<void>.value(),
  };
}

/// Optional capability keeps existing read-only registries source-compatible.
abstract interface class AiExecutionRunRegistry
    implements AiRunNotificationSource {
  AiChatSession? sessionForConversation(String conversationId, int generation);
  int get serviceWorkCount;
  int get backProtectedCount;
}

extension AiRunRegistryExecutionAccess on AiRunRegistry {
  AiChatSession? sessionForConversation(
    String conversationId,
    int generation,
  ) => switch (this) {
    AiExecutionRunRegistry registry => registry.sessionForConversation(
      conversationId,
      generation,
    ),
    _ => null,
  };

  Stream<AiRunNotificationEvent> get notificationEvents => switch (this) {
    AiRunNotificationSource source => source.notificationEvents,
    _ => const Stream<AiRunNotificationEvent>.empty(),
  };

  int get serviceWorkCount => switch (this) {
    AiExecutionRunRegistry registry => registry.serviceWorkCount,
    _ => runningCount,
  };

  int get backProtectedCount => switch (this) {
    AiExecutionRunRegistry registry => registry.backProtectedCount,
    _ => runningCount,
  };
}

/// The account's conversations. Lives above the navigator, so a run keeps
/// going after the chat page closes; a new account generation stops them all.
abstract interface class AiRunRegistry implements Listenable {
  static const maxRunning = 3;

  /// The session for [origin]: the existing one for the same key, or a new
  /// one.
  AiChatSession open(AiChatOrigin origin);

  /// Called when the page for [session] closes. A session that is idle and has
  /// no items is dropped, so the next visit reads the page again; any other
  /// session is kept.
  void release(AiChatSession session);

  int get runningCount;

  static AiRunRegistry? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<AiRunRegistryScope>()
      ?.registry;
}

class AiRunRegistryScope extends InheritedWidget {
  const AiRunRegistryScope({
    super.key,
    required this.registry,
    required super.child,
  });

  final AiRunRegistry registry;

  @override
  bool updateShouldNotify(AiRunRegistryScope oldWidget) =>
      !identical(registry, oldWidget.registry);
}
