import 'package:flutter/widgets.dart';

import '../../core/ai/ai_display.dart';
import '../../core/ai/ai_failure.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/models.dart';

/// Where a conversation starts. It decides the first context the assistant
/// reads and the project its read-only tools are bound to. An origin carries
/// identifiers only; the session loads and pins the content itself.
sealed class AiChatOrigin {
  const AiChatOrigin();

  /// Identity used by [AiRunRegistry.open] to return an existing session.
  String get key;
}

/// A conversation that is not about one resource (opened from Me). It has no
/// project and therefore no tools.
final class AiGeneralOrigin extends AiChatOrigin {
  const AiGeneralOrigin();

  @override
  String get key => 'general';
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

  /// Three conversations are already running for this account.
  tooManyRunning,

  /// The starting context could not be loaded; [AiChatSession.failure] says
  /// why and [AiChatSession.recheck] retries.
  contextUnavailable,
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

  /// The failure that ended the last run, or that blocks the start.
  AiFailure? get failure;

  /// The last run ended because the conversation reached its limit; the page
  /// offers a new conversation.
  bool get offerNewConversation;

  /// Whether this conversation's history is being saved for the account.
  bool get historySaved;

  bool get canSend;

  /// Sends [text] and runs the assistant. Rejected (no effect) unless
  /// [canSend].
  Future<void> send(String text);

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
}

/// The account's conversations. Lives above the navigator, so a run keeps
/// going after the chat page closes; a new account generation stops them all.
abstract interface class AiRunRegistry implements Listenable {
  static const maxRunning = 3;

  /// The session for [origin]: the existing one for the same key, or a new
  /// one.
  AiChatSession open(AiChatOrigin origin);

  int get runningCount;

  static AiRunRegistry? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AiRunRegistryScope>()
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
