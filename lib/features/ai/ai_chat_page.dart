import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ai/ai_display.dart';
import '../../core/ai/ai_report.dart';
import '../../core/ai/quick_actions.dart';
import '../../core/brand.dart';
import '../../core/ai/runner.dart';
import '../../core/ai/tools/write_coordinator.dart' show AiWriteProposal;
import '../../core/ai/tools/write_levels.dart';
import '../../core/failure.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../../shared/external_link.dart';
import '../../shared/hub_ui.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import '../shell/build_info.dart';
import 'ai_chat_session.dart';
import 'ai_consent_dialog.dart';
import 'ai_draft_preview.dart';
import 'ai_draft_target.dart';
import 'ai_report_sender.dart';
import 'ai_report_sheet.dart';
import 'ai_run_notification_ui.dart';
import 'ai_message_body.dart';
import 'ai_attachment_session.dart';
import 'ai_scope.dart';
import 'ai_settings_page.dart';
import 'ai_write_ui.dart';

/// Opens the chat for [origin] from a page that may or may not have AI.
/// Returns false when AI is not available here (no scope or registry).
Future<bool> openAiChat(
  BuildContext context,
  AiChatOrigin origin, {
  AiDraftTarget? draftTarget,
}) async {
  final registry = AiRunRegistry.maybeOf(context);
  if (registry == null || AiScope.maybeOf(context) == null) return false;
  final AiChatSession session;
  try {
    session = registry.open(origin);
  } on StateError {
    // The account is changing; the tree above is about to be rebuilt.
    return false;
  }
  // The summary request belongs to this visit, not to the kept session.
  final summarize = origin is AiWorkItemOrigin && origin.summarize;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AiChatPage(
        session: session,
        summarize: summarize,
        draftTarget: draftTarget,
      ),
    ),
  );
  registry.release(session);
  return true;
}

/// Opens [session], the registry's own conversation a tapped run notification
/// leads to, at [proposal]'s card while it still waits. False, opening
/// nothing, when AI is not here or the registry no longer holds [session].
/// Showing the card never approves it.
Future<bool> openAiChatSession(
  BuildContext context,
  AiChatSession session, {
  AiWriteProposal? proposal,
}) async {
  final registry = AiRunRegistry.maybeOf(context);
  if (registry == null || AiScope.maybeOf(context) == null) return false;
  final AiChatSession opened;
  try {
    // Counts this page as a visit, as [openAiChat] does.
    opened = registry.open(session.origin);
  } on StateError {
    return false;
  }
  if (!identical(opened, session)) {
    registry.release(opened);
    return false;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          AiChatPage(session: session, focusProposal: proposal?.executionId),
    ),
  );
  registry.release(session);
  return true;
}

/// The title a conversation shows for its origin. [safe] cleans the GitLab
/// values (job name, title, file name) for display.
String aiOriginTitle(
  AiChatOrigin origin, {
  required String Function(String text) safe,
}) {
  final value = switch (origin) {
    AiInboxOrigin() => l10n.aiInboxChatTitle,
    AiGeneralOrigin() ||
    AiGroupWorkItemOrigin() ||
    AiProjectWorkItemFromGroupPageOrigin() => null,
    AiJobOrigin(:final jobName) => safe(jobName),
    AiWorkItemOrigin(:final title) => safe(title),
    AiFileOrigin(:final path) => safe(path.split('/').last),
  };
  // An empty value is one that could not be checked against the secrets.
  if (value == null || value.isEmpty) return l10n.aiAssistantLabel;
  return switch (origin) {
    AiInboxOrigin() => l10n.aiInboxChatTitle,
    AiGeneralOrigin() ||
    AiGroupWorkItemOrigin() ||
    AiProjectWorkItemFromGroupPageOrigin() => l10n.aiAssistantLabel,
    AiJobOrigin() => l10n.aiChatJobTitle(value),
    AiWorkItemOrigin(:final kind, :final iid) =>
      '${isolated(kind == AiWorkItemKind.mergeRequest ? '!$iid' : '#$iid')} '
          '${isolated(value)}',
    AiFileOrigin() => isolated(value),
  };
}

List<String> _suggestions(AiChatOrigin origin) => switch (origin) {
  // The Inbox conversation can only mark to-dos done; it cannot read them.
  AiInboxOrigin() => [l10n.aiSuggestInboxMarkAll],
  AiGeneralOrigin() ||
  AiGroupWorkItemOrigin() ||
  AiProjectWorkItemFromGroupPageOrigin() => const [],
  AiJobOrigin() => [l10n.aiSuggestJobWhy, l10n.aiSuggestJobFix],
  AiWorkItemOrigin(kind: AiWorkItemKind.mergeRequest) => [
    l10n.aiSuggestMrSummary,
    l10n.aiSuggestMrRisks,
  ],
  AiWorkItemOrigin() => [l10n.aiSuggestIssueSummary, l10n.aiSuggestIssueNext],
  AiFileOrigin() => [l10n.aiSuggestFileExplain, l10n.aiSuggestFileReview],
};

class AiChatPage extends StatefulWidget {
  const AiChatPage({
    super.key,
    required this.session,
    this.summarize = false,
    this.focusProposal,
    this.draftTarget,
    this.analyzeDraft = analyzeAiDraft,
    this.sendReport = sendAiReport,
    this.buildInfo = loadBuildInfo,
    this.now = DateTime.now,
  });

  final AiChatSession session;

  /// The comment draft a finished answer can be appended to; null when the
  /// origin offers none.
  final AiDraftTarget? draftTarget;

  /// Checks an answer before it is appended; tests run it in place.
  final AiDraftAnalyzer analyzeDraft;

  /// Hands a report to the mail app or the share sheet; replaced in tests.
  final Future<AiReportRoute> Function({
    required String subject,
    required String body,
    Rect? sharePositionOrigin,
  })
  sendReport;

  /// The version a report names; replaced in tests.
  final BuildInfoLoader buildInfo;

  /// The clock the send-paused card counts down with; replaced in tests.
  final DateTime Function() now;

  /// Opened from "AI summary": send the summary request once, when the empty
  /// conversation is ready.
  final bool summarize;

  /// The execution ID of the approval card a tapped notification opened this
  /// conversation at. The card is brought into view once if it still waits.
  final String? focusProposal;

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _messenger = GlobalKey<ScaffoldMessengerState>();

  /// Whether the last build showed the blocker or preparing card.
  var _showedNotice = false;
  var _insertingDraft = false;

  /// The draft is being read and checked, before the preview opens.
  var _preparingDraft = false;
  var _reporting = false;

  /// Completes when the page closes, cancelling a draft check in flight, so
  /// closing the chat stops the check instead of leaving it until its
  /// 30 s deadline.
  final _pageClosed = Completer<void>();

  /// "AI summary" sends its request once, when the empty session is ready.
  late bool _pendingSummary;

  /// The card named by [AiChatPage.focusProposal], to scroll it into view.
  final _focusCard = GlobalKey();

  AiChatSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _pendingSummary = widget.summarize && _session.items.isEmpty;
    // A summary asked for in a conversation that already has messages is
    // offered in the composer instead of being sent.
    if (widget.summarize && _session.items.isNotEmpty) {
      _input.text = l10n.aiSuggestMrSummary;
    }
    _session.confirmCleartext = _confirmCleartext;
    _input.addListener(_inputChanged);
    _session.addListener(_maybeSummarize);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeSummarize());
    if (widget.focusProposal != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealProposal());
    }
  }

  /// Scrolls the card a notification pointed to into view. A card that is
  /// gone (approved, rejected or expired) leaves the conversation as it is.
  void _revealProposal({bool retried = false}) {
    if (!mounted) return;
    final card = _focusCard.currentContext;
    if (card == null) {
      // The list builds lazily from the newest end, where waiting cards sit.
      if (!retried && _scroll.hasClients && _scroll.offset > 0) {
        _scroll.jumpTo(0);
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _revealProposal(retried: true),
        );
      }
      return;
    }
    unawaited(
      Scrollable.ensureVisible(
        card,
        alignment: 0.5,
        duration: MediaQuery.of(context).disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 250),
      ),
    );
  }

  void _maybeSummarize() {
    if (!_pendingSummary || !mounted) return;
    if (_session.items.isNotEmpty) {
      _pendingSummary = false;
    } else if (_session.canSend) {
      _pendingSummary = false;
      _send(l10n.aiSuggestMrSummary);
    }
  }

  @override
  void dispose() {
    // The run goes on without the page; a cleartext prompt cannot be shown.
    // A draft check in flight stops here rather than at its deadline.
    _pageClosed.complete();
    _session.confirmCleartext = null;
    _session.removeListener(_maybeSummarize);
    _input
      ..removeListener(_inputChanged)
      ..dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _inputChanged() => setState(() {});

  // GitLab's stated wait is over: the send button reads the budget again.
  void _sendPauseEnded() {
    if (!mounted) return;
    setState(() {});
    _maybeSummarize();
  }

  Future<void> _insertDraft(AiAssistantItem item) async {
    final target = widget.draftTarget;
    final origin = _session.origin;
    final items = _session.items;
    final index = items.indexOf(item);
    if (target == null ||
        _insertingDraft ||
        origin is! AiWorkItemOrigin ||
        item.state != AiAssistantState.done ||
        index < 0 ||
        !_canInsert(item)) {
      return;
    }
    final safe = _session.draftSafe(item.text);
    if (safe.trim().isEmpty) return;
    final String text;
    try {
      // GitLab runs a line that starts with `/` as a quick action when the
      // comment is posted; the answer must never do that.
      text = neutralizeForGitLabDraft(safe);
    } on StateError {
      // Cannot happen (every such line was just indented); refuse rather
      // than append text that was not checked.
      return;
    }
    setState(() => _insertingDraft = _preparingDraft = true);
    try {
      // Mentions are checked on what will be posted: the draft already
      // waiting there followed by the answer, as the editor joins them.
      final String existing;
      try {
        existing = await target.existingText();
      } on Object {
        _notice(l10n.aiDraftUnreadable);
        return;
      }
      final AiDraftAnalysis analysis;
      try {
        analysis = await widget.analyzeDraft(
          text,
          existing,
          cancel: _pageClosed.future,
        );
      } on Object {
        _notice(l10n.aiDraftCheckFailed);
        return;
      }
      if (!mounted) return;
      setState(() => _preparingDraft = false);
      if (!_canInsert(item)) {
        _notice(l10n.aiDraftChanged);
        return;
      }
      final before = items.take(index).toList(growable: false);
      final chosen = await showAiDraftPreview(
        context,
        target: _draftTarget(origin),
        asWritten: analysis.asWritten,
        neutralized: analysis.neutralized,
        afterExisting: existing.isNotEmpty,
        quickActionLines: quickActionLineCount(safe),
        sources: _draftSources(items, index),
        // The model saw everything read earlier in the conversation, not
        // only in this turn. Whether the target is confidential is asked
        // now, because a kept conversation can outlive a change to it.
        confidential:
            !target.confidential() &&
            before.whereType<AiToolRunItem>().any((tool) => tool.confidential),
        internal:
            before.whereType<AiToolRunItem>().any((tool) => tool.internal) ||
            before.whereType<AiUserItem>().any(
              (user) => user.chips.any((chip) => chip.internal),
            ),
      );
      if (chosen == null || !mounted) return;
      if (!_canInsert(item)) {
        _notice(l10n.aiDraftChanged);
        return;
      }
      if (chosen.split('\n').any((line) => line.startsWith('/'))) return;
      await target.insert(chosen);
    } finally {
      if (mounted) setState(() => _insertingDraft = _preparingDraft = false);
    }
  }

  /// The chat is in front, waiting, and [item] is still in the conversation.
  bool _canInsert(AiAssistantItem item) =>
      mounted &&
      (ModalRoute.of(context)?.isCurrent ?? false) &&
      _session.phase == AiChatPhase.idle &&
      _session.items.contains(item);

  var _attaching = false;

  /// Off, with the reason as its tooltip, when the conversation holds the
  /// most files or bytes it may (§3.1) or cannot take files now.
  Widget _attachButton(AiWriteChatSession writes) {
    final held = writes.attachments;
    final full =
        held.length >= AiAttachmentSession.maxCountPerConversation ||
        held.fold<int>(0, (sum, file) => sum + file.size) >=
            AiAttachmentSession.maxBytesPerConversation;
    final can = writes.canAttach && !full;
    return IconButton(
      key: const ValueKey('ai-chat-attach'),
      tooltip: full
          ? l10n.aiAttachCapacity
          : can
          ? l10n.attachFile
          : l10n.aiAttachDisabled,
      icon: const Icon(Icons.attach_file),
      onPressed: can && !_attaching ? () => _attach(writes) : null,
    );
  }

  /// Picks an image or a file to keep for this conversation. Nothing leaves
  /// the device until a write the user approves uploads it.
  Future<void> _attach(AiWriteChatSession writes) async {
    final pick = await showModalBottomSheet<AiAttachmentPick>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('ai-attach-image'),
              leading: const Icon(Icons.image_outlined),
              title: Text(l10n.attachImage),
              onTap: () => Navigator.of(context).pop(AiAttachmentPick.image),
            ),
            ListTile(
              key: const ValueKey('ai-attach-file'),
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(l10n.attachFile),
              onTap: () => Navigator.of(context).pop(AiAttachmentPick.file),
            ),
          ],
        ),
      ),
    );
    if (pick == null || !mounted) return;
    setState(() => _attaching = true);
    try {
      final result = await writes.attach(pick);
      final message = aiAttachFailureText(result.status);
      if (message != null) _notice(message);
    } on Object {
      _notice(l10n.aiAttachReadFailed);
    } finally {
      if (mounted) setState(() => _attaching = false);
    }
  }

  /// Reports [item] (plan v5 §6.7): the user picks what is wrong and sees
  /// the exact text; mail is tried first, then the share sheet. The answer is
  /// then folded away here, whether or not the user finishes sending.
  Future<void> _report(AiAssistantItem item, Rect? origin) async {
    final assistants = _session.items.whereType<AiAssistantItem>().toList();
    final number = assistants.indexOf(item) + 1;
    if (_reporting || item.reported || number == 0) return;
    setState(() => _reporting = true);
    try {
      final info = await widget.buildInfo();
      if (!mounted || _session.currentOf(item) == null) return;
      final version = info.isUnknown
          ? 'unknown'
          : '${info.version}+${info.buildNumber} (${info.commit})';
      final time = DateTime.now();
      final source = item.source;
      // Built from the answer as it is now (a redaction pass may have
      // replaced it) and redacted as a whole last, after the report's own
      // clean-up: nothing the user typed or the formatting joined escapes
      // the check. The redaction also drops the direction isolates around
      // the translated address; the plain `to:` line keeps it copyable.
      String body(AiReportChoice choice) {
        final current = _session.currentOf(item);
        if (current == null) return '';
        return _session.draftSafe(
          aiReportBody(
            AiReport(
              category: choice.category,
              description: choice.description,
              appVersion: version,
              presetId: source?.presetId ?? 'unknown',
              format: source?.format ?? 'unknown',
              model: source?.model ?? 'unknown',
              time: time,
              messageIndex: number,
              response: choice.attachResponse ? current.text : null,
            ),
            sendToLine: l10n.aiReportSendTo(aiReportEmail),
          ),
        );
      }

      // At Send the live secrets are read again, including a token OAuth
      // rotated in place, and the text is built once more. The sheet sends
      // it only when it is exactly the preview the user saw.
      Future<String?> prepare(AiReportChoice choice) async {
        if (!await _session.refreshSecrets() || !mounted) return null;
        final text = body(choice);
        return text.isEmpty ? null : text;
      }

      final result = await showAiReportSheet(
        context,
        body: body,
        prepare: prepare,
      );
      if (result == null || !mounted) return;
      final text = result.text;
      // Null when the answer is gone or the text could not be checked.
      if (text == null) {
        _notice(l10n.aiReportNotChecked);
        return;
      }
      final AiReportRoute route;
      try {
        route = await widget.sendReport(
          subject: l10n.aiReportSubject,
          body: text,
          sharePositionOrigin: origin,
        );
      } on Object {
        _notice(l10n.aiReportFailed);
        return;
      }
      if (!mounted) return;
      _session.markReported(item);
      _notice(
        route == AiReportRoute.mail
            ? l10n.aiReportMailOpened
            : l10n.aiReportShareOpened(aiReportEmail),
      );
    } finally {
      if (mounted) setState(() => _reporting = false);
    }
  }

  /// Says why nothing was appended, while the chat is in front. When another
  /// page covers it, that page is the reason, and the notice would not be
  /// seen anyway.
  void _notice(String message) {
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? false)) return;
    // The page's own messenger, which this state sits above.
    _messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  String _draftTarget(AiWorkItemOrigin origin) {
    final reference = origin.kind == AiWorkItemKind.mergeRequest
        ? '!${origin.iid}'
        : '#${origin.iid}';
    return '${isolated(origin.project.path)} · ${isolated(reference)}';
  }

  /// What the answer at [index] drew on: the context sent with its question
  /// and the tools it ran, as preview labels.
  List<String> _draftSources(List<AiChatItem> items, int index) {
    final sources = <String>[];
    for (var at = index - 1; at >= 0; at--) {
      final item = items[at];
      if (item is AiUserItem) {
        sources.insertAll(0, [
          for (final chip in item.chips)
            if (!chip.blocked) isolated(_chipName(chip)),
        ]);
        break;
      }
      if (item is AiToolRunItem && item.status == AiToolRunStatus.completed) {
        sources.insert(
          0,
          item.argsPreview.isEmpty
              ? _toolLabel(item.name)
              : '${_toolLabel(item.name)} · ${isolated(item.argsPreview)}',
        );
      }
    }
    return sources;
  }

  Future<bool> _confirmCleartext() async {
    if (!mounted) return false;
    return confirmAction(
      context,
      l10n.aiChatCleartextTitle,
      l10n.aiChatCleartextDetail,
    );
  }

  Future<void> _send([String? suggestion]) async {
    final text = (suggestion ?? _input.text).trim();
    if (text.isEmpty || !_session.canSend) return;
    // A run may go on in the background, so the first one started in this
    // process explains the notifications and asks for them; it is sent
    // whatever the answer.
    await askForAiRunNotifications(context, disclose: _discloseNoReminders);
    if (!mounted || !_session.canSend) return;
    if (suggestion == null) _input.clear();
    _toNewest();
    // The page that sends is the one that can ask about a cleartext send;
    // another page on this session may have cleared the callback on closing.
    _session.confirmCleartext = _confirmCleartext;
    await _session.send(text);
  }

  void _discloseNoReminders(String text) {
    if (!mounted) return;
    _messenger.currentState?.showSnackBar(
      SnackBar(
        key: const ValueKey('ai-run-notice-denied'),
        content: Text(text),
        duration: const Duration(seconds: 10),
        showCloseIcon: true,
      ),
    );
  }

  /// Brings the newest content (the list is reversed) back into view.
  void _toNewest() {
    if (!_scroll.hasClients || _scroll.offset <= 0) return;
    if (MediaQuery.of(context).disableAnimations) {
      _scroll.jumpTo(0);
    } else {
      unawaited(
        _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  Future<void> _openSettings() async {
    final scope = AiScope.of(context);
    final session = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(sessionProvider);
    final account = session.active;
    if (account == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AiSettingsPage(
          settings: scope.settings,
          accountKey: scope.accountKey,
          account: account,
          api: session.api,
          isAccountRetained: (key) =>
              session.accounts.any((saved) => saved.key == key),
          history: scope.history,
        ),
      ),
    );
    if (mounted) await _session.recheck();
  }

  Future<void> _reviewConsent() async {
    final contract = _session.consentRequest;
    if (contract == null) return;
    final scope = AiScope.of(context);
    // Nothing is waiting to be sent, so the button only agrees.
    await showAiConsentDialog(
      context,
      scope.settings,
      scope.accountKey,
      contract,
      agreeLabel: l10n.aiConsentAgree,
    );
    if (mounted) await _session.recheck();
  }

  /// The banner's Stop: end the run, then stop automatic writes for this
  /// conversation by dropping it to confirm-each.
  Future<void> _stopAutoWrites() async {
    if (_session.phase == AiChatPhase.running ||
        _session.phase == AiChatPhase.awaitingApproval) {
      _session.stop();
    }
    await _session.setAutonomyLevel(AiAutonomyLevel.confirmEach);
  }

  Future<void> _newConversation() async {
    if (_session.items.isNotEmpty &&
        !await confirmAction(
          context,
          l10n.aiChatNewConversation,
          l10n.aiChatNewConversationDetail,
        )) {
      return;
    }
    _session.startNewConversation();
  }

  Future<void> _switchProvider(String providerId) async {
    if (providerId == _session.provider?.id) return;
    if (_session.items.isNotEmpty &&
        !await confirmAction(
          context,
          l10n.aiChatSwitchProvider,
          l10n.aiChatSwitchProviderDetail,
        )) {
      return;
    }
    await _session.useProvider(providerId);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) {
        final provider = _session.provider;
        // Waiting for an approval is still a run: Stop ends it.
        final busy =
            _session.phase == AiChatPhase.running ||
            _session.phase == AiChatPhase.awaitingApproval ||
            _session.phase == AiChatPhase.stopping;
        // Its own messenger, so a snack bar the app shows elsewhere (such as
        // an update notice) never covers the composer.
        return ScaffoldMessenger(
          key: _messenger,
          child: Scaffold(
            appBar: AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    aiOriginTitle(_session.origin, safe: _session.displaySafe),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (provider != null)
                    Text(
                      '${isolated(provider.name)} · ${isolated(provider.model)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
              actions: [
                if (_session.autonomyCeiling != AiAutonomyLevel.readOnly)
                  AiChatLevelButton(
                    session: _session,
                    enabled: _session.phase != AiChatPhase.stopping,
                  ),
                PopupMenuButton<String>(
                  key: const ValueKey('ai-chat-menu'),
                  tooltip: l10n.moreActions,
                  enabled: !busy,
                  onSelected: (value) {
                    if (value == '#new') {
                      _newConversation();
                    } else if (value == '#settings') {
                      _openSettings();
                    } else {
                      _switchProvider(value);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: '#new',
                      child: Text(l10n.aiChatNewConversation),
                    ),
                    PopupMenuItem(
                      value: '#settings',
                      child: Text(l10n.aiChatOpenSettings),
                    ),
                    if (_session.providers.length > 1) ...[
                      const PopupMenuDivider(),
                      for (final candidate in _session.providers)
                        CheckedPopupMenuItem(
                          value: candidate.id,
                          checked: candidate.id == provider?.id,
                          child: Text(
                            '${isolated(candidate.name)} · '
                            '${isolated(candidate.model)}',
                          ),
                        ),
                    ],
                  ],
                ),
              ],
            ),
            body: Column(
              children: [
                if (AiAutoWriteBanner.shows(_session.autonomyLevel))
                  AiAutoWriteBanner(
                    level: _session.autonomyLevel,
                    onStop: _session.phase == AiChatPhase.stopping
                        ? null
                        : () => unawaited(_stopAutoWrites()),
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) => Column(
                      children: [
                        Expanded(child: _conversation(context)),
                        // A landscape phone with the keyboard up and large text
                        // can leave less room than the composer needs: it then
                        // scrolls, keeping the send button and the caret in view.
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: constraints.maxHeight,
                          ),
                          child: SingleChildScrollView(
                            reverse: true,
                            child: _Composer(
                              controller: _input,
                              busy: busy,
                              stopping: _session.phase == AiChatPhase.stopping,
                              canSend: _session.canSend,
                              onSend: _send,
                              onStop: _session.stop,
                              attach: switch (_session) {
                                final AiWriteChatSession writes
                                    when writes.autonomyCeiling !=
                                        AiAutonomyLevel.readOnly =>
                                  _attachButton(writes),
                                _ => null,
                              },
                              attachments: _session.attachments.isEmpty
                                  ? null
                                  : AiAttachmentStrip(
                                      attachments: _session.attachments,
                                      onRemove: switch (_session) {
                                        final AiWriteChatSession writes
                                            when _session.phase ==
                                                AiChatPhase.idle =>
                                          writes.removeAttachment,
                                        _ => null,
                                      },
                                    ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The focused card keeps one wrapper for the page's life, so its typed
  /// text and state survive rebuilds.
  Widget _withFocus(String executionId, Widget card) =>
      executionId == widget.focusProposal
      ? KeyedSubtree(key: _focusCard, child: card)
      : card;

  Widget _conversation(BuildContext context) {
    final items = _session.items;
    // The blocker or preparing card scrolls with the conversation, so a long
    // message at a large text size never squeezes the page.
    final (paused, pausedUntil) = switch (_session) {
      final AiChatSendGate gate
          when _session.phase == AiChatPhase.idle &&
              _session.blocker == AiChatBlocker.none =>
        (gate.sendBlockReason, gate.sendBlockedUntil),
      _ => (null, null),
    };
    final notice =
        _session.blocker != AiChatBlocker.none ||
            _session.phase == AiChatPhase.preparing
        ? _BlockerCard(
            session: _session,
            onOpenSettings: _openSettings,
            onReviewConsent: _reviewConsent,
          )
        : paused != null
        ? _SendPausedCard(
            reason: paused,
            until: pausedUntil,
            now: widget.now,
            onResume: _sendPauseEnded,
          )
        : null;
    // A card that just appeared sits by the composer; scroll it into view.
    if (notice != null && !_showedNotice) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _toNewest();
      });
    }
    _showedNotice = notice != null;
    if (items.isEmpty) {
      return _EmptyConversation(
        origin: _session.origin,
        enabled: _session.canSend,
        onSuggestion: _send,
        notice: notice,
        controller: _scroll,
      );
    }
    final children = <Widget>[
      for (final item in items)
        _ChatItemView(
          item: item,
          onInsertDraft:
              widget.draftTarget != null &&
                  _session.origin is AiWorkItemOrigin &&
                  _session.phase == AiChatPhase.idle
              ? _insertDraft
              : null,
          insertingDraft: _insertingDraft,
          preparingDraft: _preparingDraft,
          awaitingApproval: _session.phase == AiChatPhase.awaitingApproval,
          writeRow: switch (_session) {
            final AiWriteAuditSession audit => audit.writeRowFor(item),
            _ => null,
          },
          // An answer kept on screen from an earlier conversation belongs
          // to that conversation; it is not reported from this one.
          onReport:
              _reporting ||
                  (item is AiAssistantItem && _session.currentOf(item) == null)
              ? null
              : _report,
          reportNotSaved: _session.reportNotSaved,
        ),
      // What the AI asks to write waits here, under the answer that led to
      // it, until the user approves or rejects it.
      if (_session case final AiWriteChatSession writes)
        for (final proposal in writes.proposals)
          _withFocus(
            proposal.executionId,
            AiWriteProposalCard(
              key: ValueKey('ai-proposal-card-${proposal.executionId}'),
              proposal: proposal,
              session: writes,
            ),
          ),
      // Edited cards keep the user's text until a readback confirms the
      // write (§7.2).
      if (_session case final AiWriteAuditSession audit)
        for (final edited in audit.settledWriteEdits)
          AiSettledEditCard(
            key: ValueKey('ai-settled-card-${edited.executionId}'),
            proposal: edited,
            onDismiss: () => audit.dismissSettledWrite(edited),
          ),
      if (_session.phase == AiChatPhase.running &&
          !(items.last is AiAssistantItem &&
              (items.last as AiAssistantItem).state ==
                  AiAssistantState.streaming))
        const _Thinking(),
      if (_session.phase == AiChatPhase.idle) ...[
        if (_session.lastEnd case final end?
            when !const {
              AiRunEnd.done,
              AiRunEnd.failed,
              AiRunEnd.stopped,
              AiRunEnd.stoppedBySettings,
            }.contains(end))
          _EndRow(end: end),
        if (_session.failure case final failure?)
          _FailureCard(failure: failure),
        if (_session.offerNewConversation)
          _NewConversationOffer(onStart: _session.startNewConversation),
      ],
      // Last, so it sits just above the composer.
      ?notice,
    ];
    // Reversed, so the newest content stays at the bottom while it grows.
    // Each row is keyed by its position from the oldest item, which does not
    // change when content is added, so an expanded tool row stays expanded.
    return ListView.builder(
      key: const ValueKey('ai-chat-list'),
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      itemCount: children.length,
      findChildIndexCallback: (key) =>
          key is ValueKey<int> && key.value >= 0 && key.value < children.length
          ? children.length - 1 - key.value
          : null,
      itemBuilder: (context, index) {
        final position = children.length - 1 - index;
        return Padding(
          key: ValueKey<int>(position),
          padding: const EdgeInsets.only(bottom: 12),
          child: children[position],
        );
      },
    );
  }
}

class _BlockerCard extends StatelessWidget {
  const _BlockerCard({
    required this.session,
    required this.onOpenSettings,
    required this.onReviewConsent,
  });

  final AiChatSession session;
  final VoidCallback onOpenSettings;
  final VoidCallback onReviewConsent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, text, action, onAction) = switch (session.blocker) {
      // Shown only while the conversation gets ready (reading the page).
      AiChatBlocker.none => (null, l10n.aiChatPreparing, null, null),
      AiChatBlocker.settingsLoading => (null, l10n.loadingDots, null, null),
      AiChatBlocker.settingsUnavailable => (
        Icons.error_outline,
        l10n.aiSettingsReadFailure,
        l10n.aiChatOpenSettings,
        onOpenSettings,
      ),
      AiChatBlocker.noProvider => (
        Icons.add_circle_outline,
        l10n.aiChatNoProvider,
        l10n.aiAddProvider,
        onOpenSettings,
      ),
      AiChatBlocker.keyMissing => (
        Icons.key_off_outlined,
        l10n.aiChatKeyMissing,
        l10n.aiChatOpenSettings,
        onOpenSettings,
      ),
      AiChatBlocker.consentRequired => (
        Icons.verified_user_outlined,
        l10n.aiChatConsentNeeded,
        l10n.aiChatReviewConsent,
        onReviewConsent,
      ),
      AiChatBlocker.tooManyRunning => (
        Icons.hourglass_top,
        l10n.aiChatTooManyRunning('${AiRunRegistry.maxRunning}'),
        null,
        null,
      ),
      AiChatBlocker.contextUnavailable => (
        Icons.cloud_off_outlined,
        l10n.aiChatContextUnavailable,
        l10n.retryAction,
        session.recheck,
      ),
    };
    final failure = session.blocker == AiChatBlocker.contextUnavailable
        ? session.failure
        : null;
    if (failure is ApiFailure) {
      // A GitLab read failed: the app's notice names the account, instance
      // and page, keeps a 404 ambiguous and offers retry and account switch.
      return FailureNotice(
        failure,
        key: const ValueKey('ai-chat-blocker'),
        resourceLabel: aiOriginTitle(session.origin, safe: session.displaySafe),
        onRetry: () => unawaited(session.recheck()),
      );
    }
    return Card(
      key: ValueKey(
        session.blocker == AiChatBlocker.none
            ? 'ai-chat-preparing'
            : 'ai-chat-blocker',
      ),
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                icon == null
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(icon, size: 20),
                const SizedBox(width: 12),
                Expanded(child: Text(text)),
              ],
            ),
            if (failure != null) ...[
              const SizedBox(height: 8),
              _FailureCard(failure: failure),
            ],
            if (action != null && onAction != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton.tonal(
                  onPressed: onAction,
                  child: Text(action),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({
    required this.origin,
    required this.enabled,
    required this.onSuggestion,
    this.notice,
    this.controller,
  });

  final AiChatOrigin origin;
  final bool enabled;
  final ValueChanged<String> onSuggestion;
  final Widget? notice;

  /// The page's controller, so a card that appears is scrolled into view
  /// (offset 0 is the top here, where the card sits).
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggestions = _suggestions(origin);
    return ListView(
      controller: controller,
      padding: const EdgeInsets.all(24),
      children: [
        if (notice case final notice?) ...[notice, const SizedBox(height: 20)],
        Icon(Icons.auto_awesome, size: 40, color: theme.colorScheme.primary),
        const SizedBox(height: 12),
        Text(
          origin is AiGeneralOrigin
              ? l10n.aiChatEmptyGeneral
              : l10n.aiChatEmpty,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 20),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final suggestion in suggestions)
              ActionChip(
                label: Text(suggestion),
                onPressed: enabled ? () => onSuggestion(suggestion) : null,
              ),
          ],
        ),
      ],
    );
  }
}

class _ChatItemView extends StatelessWidget {
  const _ChatItemView({
    required this.item,
    this.onInsertDraft,
    this.insertingDraft = false,
    this.preparingDraft = false,
    this.onReport,
    this.reportNotSaved = false,
    this.awaitingApproval = false,
    this.writeRow,
  });

  final AiChatItem item;
  final bool reportNotSaved;

  /// The run waits for the user to approve a write card.
  final bool awaitingApproval;

  /// The item's write audit data, when it is a write row.
  final AiWriteRow? writeRow;
  final void Function(AiAssistantItem item)? onInsertDraft;

  /// An append is under way; every append button waits for it.
  final bool insertingDraft;

  /// The draft is still being checked; the buttons say so.
  final bool preparingDraft;
  final void Function(AiAssistantItem item, Rect? origin)? onReport;

  @override
  Widget build(BuildContext context) => switch (item) {
    final AiUserItem user => _UserMessage(item: user),
    final AiAssistantItem assistant when assistant.reported => _ReportedFold(
      notSaved: reportNotSaved,
      child: _AssistantMessage(item: assistant),
    ),
    final AiAssistantItem assistant => _AssistantMessage(
      item: assistant,
      onInsertDraft: onInsertDraft,
      insertingDraft: insertingDraft,
      preparingDraft: preparingDraft,
      onReport: onReport,
    ),
    final AiToolRunItem tool => _ToolRow(
      item: tool,
      awaitingApproval: awaitingApproval,
      writeRow: writeRow,
    ),
    final AiNoticeItem notice => _NoticeRow(item: notice),
  };
}

class _UserMessage extends StatelessWidget {
  const _UserMessage({required this.item});

  final AiUserItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.85,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: SelectableText(
                item.text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          ),
        ),
        if (item.chips.isNotEmpty) ...[
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 6,
            runSpacing: 6,
            children: [for (final chip in item.chips) _ContextChip(chip: chip)],
          ),
        ],
      ],
    );
  }
}

String _chipName(AiContextChip chip) => switch (chip.resource) {
  _ when _isSummaryChip(chip) => l10n.aiChatSummaryChip,
  null => chip.source,
  final resource when chip.source == 'file' => resource.split('/').last,
  final resource => resource,
};

/// After a conversation is condensed, its summary is sent instead of the
/// page.
bool _isSummaryChip(AiContextChip chip) =>
    chip.source == 'conversation_summary';

class _ContextChip extends StatelessWidget {
  const _ContextChip({required this.chip});

  final AiContextChip chip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = chip.blocked
        ? '${isolated(chip.source)} · ${l10n.aiChatBlocked}'
        : '${isolated(_name)} · ${l10n.aiChatCharacters('${chip.sizeChars}')}';
    final color = chip.blocked
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onSurface;
    // A pill that shortens its label instead of overflowing a narrow screen.
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.85,
      ),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        shape: StadiumBorder(
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: chip.blocked ? null : () => _showSent(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  chip.blocked ? Icons.block : Icons.description_outlined,
                  size: 16,
                  color: color,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(color: color),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The page the content came from: a file name, `!iid`, `#iid` or the job
  /// name. Older chips without one show their source tag.
  String get _name => _chipName(chip);

  bool get _isSummary => _isSummaryChip(chip);

  void _showSent(BuildContext context) {
    final text = chip.sentText ?? chip.preview;
    final parts = _sentParts(text);
    final pinned = chip.pinnedSha;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (context, controller) {
          final theme = Theme.of(context);
          final muted = theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          );
          // Long content is laid out in pieces, a screen or so at a time.
          return ListView.builder(
            key: const ValueKey('ai-chat-sent'),
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            itemCount: parts.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.aiChatSentContent,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _isSummary
                            ? l10n.aiChatSummaryChip
                            : isolated(chip.resource ?? chip.source),
                      ),
                      Text(
                        [
                          l10n.aiChatCharacters('${chip.sizeChars}'),
                          if (pinned != null && pinned.isNotEmpty)
                            l10n.pinnedAtSha(
                              pinned.length > 8
                                  ? pinned.substring(0, 8)
                                  : pinned,
                            ),
                        ].join(' · '),
                        style: muted,
                      ),
                      if (chip.sentText == null)
                        Text(l10n.aiChatSentPreviewOnly, style: muted),
                    ],
                  ),
                );
              }
              // What was actually sent, after redaction, read left to right.
              return Directionality(
                textDirection: TextDirection.ltr,
                child: SelectableText(
                  parts[index - 1],
                  style: codeTextStyle(context),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// [text] in pieces of about 4000 characters, cut after a line break where
/// there is one and never inside a surrogate pair.
List<String> _sentParts(String text) {
  const size = 4000;
  final parts = <String>[];
  var start = 0;
  while (text.length - start > size) {
    var end = start + size;
    final newline = text.lastIndexOf('\n', end - 1);
    if (newline > start) end = newline + 1;
    final last = text.codeUnitAt(end - 1);
    if (last >= 0xd800 && last <= 0xdbff) end--;
    parts.add(text.substring(start, end));
    start = end;
  }
  parts.add(text.substring(start));
  return parts;
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({
    required this.item,
    this.onInsertDraft,
    this.insertingDraft = false,
    this.preparingDraft = false,
    this.onReport,
  });

  final AiAssistantItem item;
  final void Function(AiAssistantItem item)? onInsertDraft;
  final bool insertingDraft;
  final bool preparingDraft;
  final void Function(AiAssistantItem item, Rect? origin)? onReport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final streaming = item.state == AiAssistantState.streaming;
    if (item.state == AiAssistantState.hidden) {
      return Row(
        children: [
          Icon(Icons.visibility_off_outlined, size: 18, color: muted?.color),
          const SizedBox(width: 8),
          Expanded(child: Text(l10n.aiChatHidden, style: muted)),
        ],
      );
    }
    // Why a run ended is the end row's job; only an interruption is noted on
    // the reply itself, because it is not kept in the conversation.
    final note = item.state == AiAssistantState.interrupted
        ? l10n.aiChatInterrupted
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.auto_awesome,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                l10n.aiAssistantLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
            ),
            if (streaming) ...[
              const SizedBox(width: 8),
              const SizedBox.square(
                dimension: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        if (item.text.isNotEmpty)
          AiMessageBody(text: item.text, streaming: streaming)
        else if (streaming)
          Text(l10n.aiChatThinking, style: muted),
        if (note != null) ...[
          const SizedBox(height: 6),
          Text(note, style: muted),
        ],
        if (!streaming && item.text.isNotEmpty)
          Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
                icon: const Icon(Icons.copy_all_outlined, size: 18),
                label: Text(l10n.aiChatCopy),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: item.text));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(l10n.aiChatCopied)));
                },
              ),
              if (item.state == AiAssistantState.done &&
                  item.text.trim().isNotEmpty &&
                  onInsertDraft != null)
                TextButton.icon(
                  key: const ValueKey('ai-chat-insert-draft'),
                  // Checking a long answer can take a moment; say so in place.
                  icon: preparingDraft
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_comment_outlined, size: 18),
                  label: Text(l10n.aiChatInsertDraft),
                  onPressed: insertingDraft
                      ? null
                      : () => onInsertDraft!(item),
                ),
              if (onReport != null && !item.reported)
                // The button's own box anchors the share sheet's popover on
                // a tablet.
                Builder(
                  builder: (context) => TextButton.icon(
                    key: const ValueKey('ai-chat-report'),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      foregroundColor: theme.colorScheme.onSurfaceVariant,
                    ),
                    icon: const Icon(Icons.outlined_flag, size: 18),
                    label: Text(l10n.aiReportAction),
                    onPressed: () {
                      final box = context.findRenderObject();
                      onReport!(
                        item,
                        box is RenderBox && box.hasSize
                            ? box.localToGlobal(Offset.zero) & box.size
                            : null,
                      );
                    },
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

/// A reported answer, folded away on this device; it can be opened again.
class _ReportedFold extends StatefulWidget {
  const _ReportedFold({required this.child, this.notSaved = false});

  final Widget child;

  /// The reported flag could not be saved with the encrypted history, so the
  /// answer may show again after the app restarts.
  final bool notSaved;

  @override
  State<_ReportedFold> createState() => _ReportedFoldState();
}

class _ReportedFoldState extends State<_ReportedFold> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final toggle = TextButton(
      key: const ValueKey('ai-chat-reported-toggle'),
      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
      onPressed: () => setState(() => _open = !_open),
      child: Text(_open ? l10n.aiReportHide : l10n.aiReportShow),
    );
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.outlined_flag, size: 18, color: muted?.color),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _open ? l10n.aiReportedOpen : l10n.aiReported,
                style: muted,
              ),
            ),
            toggle,
          ],
        ),
        if (widget.notSaved)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 26),
            child: Text(
              l10n.aiReportNotSaved,
              key: const ValueKey('ai-chat-report-not-saved'),
              style: muted?.copyWith(color: theme.colorScheme.error),
            ),
          ),
      ],
    );
    if (!_open) return header;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [header, const SizedBox(height: 4), widget.child],
    );
  }
}

String _toolLabel(String name) => switch (name) {
  'read_file' => l10n.aiToolReadFile,
  'list_directory' => l10n.aiToolListDirectory,
  'get_issue' => l10n.aiToolGetIssue,
  'get_merge_request' => l10n.aiToolGetMergeRequest,
  'get_merge_request_diff' => l10n.aiToolGetMergeRequestDiff,
  'get_pipeline_jobs' => l10n.aiToolGetPipelineJobs,
  'get_job_log' => l10n.aiToolGetJobLog,
  'get_commit' => l10n.aiToolGetCommit,
  'get_commit_diff' => l10n.aiToolGetCommitDiff,
  'search_project' => l10n.aiToolSearchProject,
  // Anything else came from the model, not from the app's tool list.
  _ => l10n.aiToolUnknown,
};

class _ToolRow extends StatelessWidget {
  const _ToolRow({
    required this.item,
    this.awaitingApproval = false,
    this.writeRow,
  });

  final AiToolRunItem item;

  /// A write's audit data (§7.7): when it settled, its GitLab link and any
  /// warning. Null for reads.
  final AiWriteRow? writeRow;

  /// The run waits for the user to approve a write card.
  final bool awaitingApproval;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running =
        item.status == AiToolRunStatus.pending ||
        item.status == AiToolRunStatus.running;
    final write = item.writeStatus;
    // A write row has no result until it ran; until then it waits for the
    // card or is being made, never "reading".
    final isWrite = write != null || aiIsWriteTool(item.name);
    final pendingStatus = !isWrite
        ? l10n.aiToolReading
        : awaitingApproval
        ? l10n.waitingForConfirmation
        : l10n.aiWriteInProgress;
    final muted = theme.colorScheme.onSurfaceVariant;
    final resultText = aiWriteResultText(writeRow?.outcome?.reasonCode);
    // A write says exactly how it went; an uncertain one is never shown as
    // failed, because it may have been made.
    final (IconData? icon, Color? color, String status) = switch (item.status) {
      _ when running => (null, null, pendingStatus),
      _ when write != null => (
        switch (write) {
          AiWriteResultStatus.succeeded ||
          AiWriteResultStatus.readbackConfirmed => Icons.check_circle_outline,
          AiWriteResultStatus.noChange => Icons.radio_button_unchecked,
          AiWriteResultStatus.notExecuted => Icons.remove_circle_outline,
          AiWriteResultStatus.failedCertain => Icons.error_outline,
          AiWriteResultStatus.writeUncertain => Icons.help_outline,
          AiWriteResultStatus.resolvedByUser => Icons.task_alt,
        },
        switch (write) {
          AiWriteResultStatus.succeeded ||
          AiWriteResultStatus.readbackConfirmed => HubColors.green,
          AiWriteResultStatus.failedCertain => theme.colorScheme.error,
          AiWriteResultStatus.writeUncertain => HubColors.orange,
          _ => muted,
        },
        switch (write) {
          AiWriteResultStatus.succeeded || AiWriteResultStatus.readbackConfirmed
              when resultText != null =>
            resultText,
          _ => aiWriteStatusLabel(write),
        },
      ),
      AiToolRunStatus.pending ||
      AiToolRunStatus.running => (null, null, pendingStatus),
      AiToolRunStatus.completed when item.blocked => (
        Icons.block,
        HubColors.orange,
        l10n.aiToolBlockedSensitive,
      ),
      AiToolRunStatus.completed when item.truncated => (
        Icons.content_cut,
        HubColors.orange,
        l10n.aiToolTruncated,
      ),
      AiToolRunStatus.completed => (
        Icons.check_circle_outline,
        HubColors.green,
        l10n.aiToolCompleted,
      ),
      AiToolRunStatus.failed => (
        Icons.error_outline,
        theme.colorScheme.error,
        l10n.aiToolFailed,
      ),
      AiToolRunStatus.skipped => (
        Icons.remove_circle_outline,
        theme.colorScheme.onSurfaceVariant,
        l10n.aiToolSkipped,
      ),
    };
    final label = isWrite ? aiOperationLabel(item.name) : _toolLabel(item.name);
    final details = [if (item.provenance.isNotEmpty) item.provenance];
    final audit = writeRow;
    final settledAt = switch (audit?.settledAt) {
      final at? => MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(at.toLocal())),
      null => null,
    };
    final excerpt = item.resultExcerpt.trim();
    // What was read on the first line, how it went on the second.
    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: running
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(icon, size: 18, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.argsPreview.isEmpty
                    ? label
                    : '$label · ${isolated(item.argsPreview)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                '$status'
                '${item.sizeChars > 0 && !running ? ' · ${l10n.aiChatCharacters('${item.sizeChars}')}' : ''}'
                '${settledAt == null ? '' : ' · $settledAt'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              // An automatic rerun or play may reuse stored variables; the
              // card that would have said so never appeared (§0 item 12).
              if (audit?.outcome?.auditNotice == 'storedVariablesMayApply')
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.info_outline,
                        size: 14,
                        color: HubColors.orange,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          l10n.aiPreviewStoredVariables,
                          key: const ValueKey('ai-write-row-stored-variables'),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              if (audit?.outcome?.auditNotice == uploadReadersCanFetch)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.public,
                        size: 14,
                        color: HubColors.orange,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          l10n.aiUploadReadersCanFetch,
                          key: const ValueKey('ai-write-row-warning'),
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              if (audit != null && audit.outcome != null)
                if (audit.link case final link?)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      key: const ValueKey('ai-write-row-link'),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                      onPressed: () => openExternal(context, link),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: Text(l10n.openInGitlab),
                    ),
                  ),
            ],
          ),
        ),
      ],
    );
    if (details.isEmpty && excerpt.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: header,
      );
    }
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsetsDirectional.only(start: 26, bottom: 8),
        dense: true,
        visualDensity: VisualDensity.compact,
        title: header,
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final detail in details)
            Text(
              isolated(detail),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (excerpt.isNotEmpty) ...[
            const SizedBox(height: 6),
            Directionality(
              textDirection: TextDirection.ltr,
              child: SelectableText(
                excerpt,
                style: const TextStyle(
                  fontFamily: codeFontFamily,
                  fontFamilyFallback: ['Menlo', 'monospace'],
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({required this.item});

  final AiNoticeItem item;

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (item.kind) {
      AiNoticeKind.redacted => (
        Icons.shield_outlined,
        item.count == null
            ? l10n.aiNoticeRedactedSome
            : l10n.aiNoticeRedacted('${item.count}'),
      ),
      AiNoticeKind.privateKeyWithheld => (
        Icons.key_off_outlined,
        l10n.aiNoticePrivateKeyWithheld,
      ),
      AiNoticeKind.settingsChanged => (Icons.tune, l10n.aiEndSettingsChanged),
      AiNoticeKind.segmentSummary => (
        Icons.compress,
        l10n.aiNoticeSegmentSummary,
      ),
      AiNoticeKind.historyLimit => (
        Icons.inventory_2_outlined,
        l10n.aiNoticeHistoryLimit,
      ),
      AiNoticeKind.stopped => (Icons.stop_circle_outlined, l10n.aiEndStopped),
      AiNoticeKind.notSent => (
        Icons.cancel_schedule_send,
        l10n.aiNoticeNotSent,
      ),
      AiNoticeKind.newConversation => (
        Icons.restart_alt,
        l10n.aiNoticeNewConversation,
      ),
    };
    return _MutedRow(icon: icon, text: text);
  }
}

class _EndRow extends StatelessWidget {
  const _EndRow({required this.end});

  final AiRunEnd end;

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (end) {
      AiRunEnd.maxTokens => (Icons.short_text, l10n.aiEndOutputLimit),
      AiRunEnd.toolBudget => (Icons.hourglass_bottom, l10n.aiEndToolBudget),
      AiRunEnd.toolBudgetNoAnswer => (
        Icons.hourglass_bottom,
        l10n.aiEndToolBudgetNoAnswer,
      ),
      AiRunEnd.stopped => (Icons.stop_circle_outlined, l10n.aiEndStopped),
      AiRunEnd.stoppedBySettings => (Icons.tune, l10n.aiEndSettingsChanged),
      AiRunEnd.newSecret => (
        Icons.shield_outlined,
        l10n.aiReplayProtectionStopped,
      ),
      AiRunEnd.tokenBudget => (Icons.data_usage, l10n.aiEndTokenBudget),
      AiRunEnd.contextTooLong => (Icons.notes, l10n.aiContextTooLongTitle),
      AiRunEnd.contentFilter => (
        Icons.policy_outlined,
        l10n.aiContentFilterTitle,
      ),
      AiRunEnd.refusal => (Icons.block, l10n.aiRefusalTitle),
      AiRunEnd.done || AiRunEnd.failed => (Icons.check, l10n.aiEndCompleted),
    };
    return _MutedRow(icon: icon, text: text);
  }
}

class _MutedRow extends StatelessWidget {
  const _MutedRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

class _NewConversationOffer extends StatelessWidget {
  const _NewConversationOffer({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: FilledButton.tonalIcon(
      icon: const Icon(Icons.add_comment_outlined),
      label: Text(l10n.aiChatNewConversation),
      onPressed: onStart,
    ),
  );
}

class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      const SizedBox(width: 10),
      Text(l10n.aiChatThinking, style: Theme.of(context).textTheme.bodySmall),
    ],
  );
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.busy,
    required this.stopping,
    required this.canSend,
    required this.onSend,
    required this.onStop,
    this.attach,
    this.attachments,
  });

  /// The attach button, for a conversation that can upload files.
  final Widget? attach;

  /// The files held for the next message.
  final Widget? attachments;

  final TextEditingController controller;
  final bool busy;
  final bool stopping;
  final bool canSend;
  final Future<void> Function([String?]) onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasText = controller.text.trim().isNotEmpty;
    return Material(
      color: theme.colorScheme.surface,
      elevation: 2,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(attach == null ? 12 : 4, 8, 8, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ?attachments,
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ?attach,
                  Expanded(
                    child: TextField(
                      key: const ValueKey('ai-chat-input'),
                      controller: controller,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: l10n.aiChatComposerHint,
                        // One line: a long hint at a large text size would
                        // otherwise grow the empty field to six lines.
                        hintMaxLines: 1,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  busy
                      ? IconButton.filledTonal(
                          key: const ValueKey('ai-chat-stop'),
                          tooltip: l10n.aiChatStop,
                          onPressed: stopping ? null : onStop,
                          icon: const Icon(Icons.stop_rounded),
                        )
                      : IconButton.filled(
                          key: const ValueKey('ai-chat-send'),
                          tooltip: l10n.aiChatSend,
                          onPressed: canSend && hasText ? () => onSend() : null,
                          icon: const Icon(Icons.arrow_upward_rounded),
                        ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Says why the send button is off while the account's GitLab request budget
/// pauses sending, and when that ends. It updates as the minutes pass and
/// tells the page when the stated time is over.
class _SendPausedCard extends StatefulWidget {
  const _SendPausedCard({
    required this.reason,
    required this.until,
    required this.now,
    required this.onResume,
  });

  final AiChatSendBlockReason reason;
  final DateTime? until;
  final DateTime Function() now;
  final VoidCallback onResume;

  @override
  State<_SendPausedCard> createState() => _SendPausedCardState();
}

class _SendPausedCardState extends State<_SendPausedCard> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(_SendPausedCard old) {
    super.didUpdateWidget(old);
    if (old.until != widget.until) _schedule();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Duration? get _left {
    final left = widget.until?.difference(widget.now());
    return left == null || left <= Duration.zero ? null : left;
  }

  // Wakes when the rounded-up minute count changes, and when the wait ends.
  void _schedule() {
    _tick?.cancel();
    final left = _left;
    if (left == null) return;
    final step = left.inMicroseconds % Duration.microsecondsPerMinute;
    _tick = Timer(
      Duration(
        microseconds: step == 0 ? Duration.microsecondsPerMinute : step,
      ),
      () {
        if (!mounted) return;
        if (_left == null) {
          widget.onResume();
        } else {
          setState(_schedule);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final left = _left;
    final (title, detail) = switch (widget.reason) {
      AiChatSendBlockReason.runBudgetUnavailable => (
        l10n.aiChatTooManyRunning('${AiRunRegistry.maxRunning}'),
        null,
      ),
      final reason => (
        reason == AiChatSendBlockReason.criticalRateBudget
            ? l10n.aiSendPausedBudget
            : l10n.aiSendPausedRateLimited,
        // Only a reset time GitLab actually gave is worth stating.
        left == null
            ? l10n.aiSendResumesAfterReset
            : l10n.cacheResumesInMinutes(
                (left.inMicroseconds + Duration.microsecondsPerMinute - 1) ~/
                    Duration.microsecondsPerMinute,
              ),
      ),
    };
    return Card(
      key: const ValueKey('ai-chat-send-paused'),
      margin: EdgeInsets.zero,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: MergeSemantics(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.hourglass_top, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title),
                    if (detail != null)
                      Text(
                        detail,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard({required this.failure});

  final UserFacingFailure failure;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      key: const ValueKey('ai-chat-failure'),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.error_outline,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failure.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    failure.detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
