import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ai/ai_display.dart';
import '../../core/ai/runner.dart';
import '../../core/failure.dart';
import '../../core/providers.dart';
import '../../l10n/l10n.dart';
import '../../shared/hub_ui.dart';
import '../../shared/theme.dart';
import '../../shared/workspace_ui.dart';
import 'ai_chat_session.dart';
import 'ai_consent_dialog.dart';
import 'ai_message_body.dart';
import 'ai_scope.dart';
import 'ai_settings_page.dart';

/// Opens the chat for [origin] from a page that may or may not have AI.
/// Returns false when AI is not available here (no scope or registry).
Future<bool> openAiChat(BuildContext context, AiChatOrigin origin) async {
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
      builder: (_) => AiChatPage(session: session, summarize: summarize),
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
}) => switch (origin) {
  AiGeneralOrigin() => l10n.aiAssistantLabel,
  AiJobOrigin(:final jobName) => l10n.aiChatJobTitle(safe(jobName)),
  AiWorkItemOrigin(:final kind, :final iid, :final title) =>
    '${isolated(kind == AiWorkItemKind.mergeRequest ? '!$iid' : '#$iid')} '
        '${isolated(safe(title))}',
  AiFileOrigin(:final path) => isolated(safe(path.split('/').last)),
};

List<String> _suggestions(AiChatOrigin origin) => switch (origin) {
  AiGeneralOrigin() => const [],
  AiJobOrigin() => [l10n.aiSuggestJobWhy, l10n.aiSuggestJobFix],
  AiWorkItemOrigin(kind: AiWorkItemKind.mergeRequest) => [
    l10n.aiSuggestMrSummary,
    l10n.aiSuggestMrRisks,
  ],
  AiWorkItemOrigin() => [l10n.aiSuggestIssueSummary, l10n.aiSuggestIssueNext],
  AiFileOrigin() => [l10n.aiSuggestFileExplain, l10n.aiSuggestFileReview],
};

class AiChatPage extends StatefulWidget {
  const AiChatPage({super.key, required this.session, this.summarize = false});

  final AiChatSession session;

  /// Opened from "AI summary": send the summary request once, when the empty
  /// conversation is ready.
  final bool summarize;

  @override
  State<AiChatPage> createState() => _AiChatPageState();
}

class _AiChatPageState extends State<AiChatPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  /// Whether the last build showed the blocker or preparing card.
  var _showedNotice = false;

  /// "AI summary" sends its request once, when the empty session is ready.
  late bool _pendingSummary;

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
    _session.confirmCleartext = null;
    _session.removeListener(_maybeSummarize);
    _input
      ..removeListener(_inputChanged)
      ..dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _inputChanged() => setState(() {});

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
    if (suggestion == null) _input.clear();
    _toNewest();
    // The page that sends is the one that can ask about a cleartext send;
    // another page on this session may have cleared the callback on closing.
    _session.confirmCleartext = _confirmCleartext;
    await _session.send(text);
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
        final busy =
            _session.phase == AiChatPhase.running ||
            _session.phase == AiChatPhase.stopping;
        // Its own messenger, so a snack bar the app shows elsewhere (such as
        // an update notice) never covers the composer.
        return ScaffoldMessenger(
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
                Expanded(child: _conversation(context)),
                _Composer(
                  controller: _input,
                  busy: busy,
                  stopping: _session.phase == AiChatPhase.stopping,
                  canSend: _session.canSend,
                  onSend: _send,
                  onStop: _session.stop,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _conversation(BuildContext context) {
    final items = _session.items;
    // The blocker or preparing card scrolls with the conversation, so a long
    // message at a large text size never squeezes the page.
    final notice =
        _session.blocker != AiChatBlocker.none ||
            _session.phase == AiChatPhase.preparing
        ? _BlockerCard(
            session: _session,
            onOpenSettings: _openSettings,
            onReviewConsent: _reviewConsent,
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
      for (final item in items) _ChatItemView(item: item),
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
  const _ChatItemView({required this.item});

  final AiChatItem item;

  @override
  Widget build(BuildContext context) => switch (item) {
    final AiUserItem user => _UserMessage(item: user),
    final AiAssistantItem assistant => _AssistantMessage(item: assistant),
    final AiToolRunItem tool => _ToolRow(item: tool),
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
  String get _name => switch (chip.resource) {
    null => chip.source,
    final resource when chip.source == 'file' => resource.split('/').last,
    final resource => resource,
  };

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
                      Text(isolated(chip.resource ?? chip.source)),
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
  const _AssistantMessage({required this.item});

  final AiAssistantItem item;

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
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
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
          ),
      ],
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
  const _ToolRow({required this.item});

  final AiToolRunItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running =
        item.status == AiToolRunStatus.pending ||
        item.status == AiToolRunStatus.running;
    final (IconData? icon, Color? color, String status) = switch (item.status) {
      AiToolRunStatus.pending ||
      AiToolRunStatus.running => (null, null, l10n.aiToolReading),
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
    final details = [if (item.provenance.isNotEmpty) item.provenance];
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
                    ? _toolLabel(item.name)
                    : '${_toolLabel(item.name)} · ${isolated(item.argsPreview)}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                '$status'
                '${item.sizeChars > 0 && !running ? ' · ${l10n.aiChatCharacters('${item.sizeChars}')}' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
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
  });

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
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('ai-chat-input'),
                  controller: controller,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: l10n.aiChatComposerHint,
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
