import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../shared/hub_ui.dart';
import '../../shared/workspace_ui.dart';
import 'ai_write_journal.dart';
import 'ai_write_ui.dart';

/// Observation codes a user can record on an interrupted write. The journal
/// keeps the code; the page shows it in the current language.
const aiObservedDone = 'done';
const aiObservedNotDone = 'notDone';

String aiJournalStateLabel(AiJournalState state) => switch (state) {
  AiJournalState.prepared => l10n.aiJournalPrepared,
  AiJournalState.dispatching => l10n.aiJournalDispatching,
  AiJournalState.succeeded => l10n.aiWriteStatusSucceeded,
  AiJournalState.failedCertain => l10n.aiWriteStatusFailed,
  AiJournalState.writeUncertain => l10n.aiWriteStatusUncertain,
  AiJournalState.notExecuted => l10n.aiWriteStatusNotExecuted,
  AiJournalState.resolvedByUser => l10n.aiWriteStatusResolvedByUser,
};

/// The account's AI writes on this device, newest first. Interrupted writes
/// come first: the user records what GitLab shows, then releases the lock by
/// typing the target's name. Resetting the log needs the account's @name.
class AiWriteLogPage extends StatefulWidget {
  AiWriteLogPage({super.key, required this.account, AiWriteJournal? journal})
    : journal = journal ?? AiWriteJournal.instance;

  final Account account;
  final AiWriteJournal journal;

  @override
  State<AiWriteLogPage> createState() => _AiWriteLogPageState();
}

class _AiWriteLogPageState extends State<AiWriteLogPage> {
  final _messenger = GlobalKey<ScaffoldMessengerState>();
  List<AiJournalEntry>? _entries;

  /// Why the log could not be read, or null while it loads or once it has.
  /// A thrown read counts as [AiJournalKeyStatus.unavailable].
  AiJournalKeyStatus? _failure;
  var _busy = false;

  String get _accountKey => widget.account.key;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      // Reading never creates the log: an account the AI has not written
      // for yet simply has no entries.
      final status = await widget.journal.keyStatus(_accountKey);
      if (!mounted) return;
      final entries = switch (status) {
        AiJournalKeyStatus.found => [
          ...widget.journal.entries(_accountKey),
        ]..sort((a, b) => b.sequence.compareTo(a.sequence)),
        AiJournalKeyStatus.uninitialized => <AiJournalEntry>[],
        _ => null,
      };
      setState(() {
        _entries = entries;
        _failure = entries == null ? status : null;
      });
    } on Object {
      if (mounted) setState(() => _failure = AiJournalKeyStatus.unavailable);
    }
  }

  Future<void> _retry() async {
    setState(() {
      _failure = null;
      _entries = null;
    });
    await _load();
  }

  void _say(String message) =>
      _messenger.currentState?.showSnackBar(SnackBar(content: Text(message)));

  Future<void> _act(Future<void> Function() action, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) _say(done);
    } on Object {
      if (mounted) _say(l10n.aiWriteLogActionFailed);
    } finally {
      // Busy until the list shows the result, so nothing acts on a stale row.
      await _load();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _observe(AiJournalEntry entry) async {
    final code = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l10n.aiWriteLogObserveTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            ListTile(
              key: const ValueKey('ai-write-log-observed-done'),
              leading: const Icon(Icons.check_circle_outline),
              title: Text(l10n.aiWriteLogObservedDone),
              onTap: () => Navigator.of(context).pop(aiObservedDone),
            ),
            ListTile(
              key: const ValueKey('ai-write-log-observed-not-done'),
              leading: const Icon(Icons.remove_circle_outline),
              title: Text(l10n.aiWriteLogObservedNotDone),
              onTap: () => Navigator.of(context).pop(aiObservedNotDone),
            ),
          ],
        ),
      ),
    );
    if (code == null || !mounted) return;
    await _act(
      () => widget.journal.recordObservation(
        executionId: entry.executionId,
        summary: code,
      ),
      l10n.aiWriteLogObserved,
    );
  }

  Future<void> _release(AiJournalEntry entry) async {
    final confirmed = await confirmAction(
      context,
      l10n.aiWriteLogReleaseTitle,
      l10n.aiWriteLogReleaseDetail(entry.releaseName),
      requiredText: entry.releaseName,
    );
    if (!confirmed || !mounted) return;
    await _act(
      () => widget.journal.releaseByUser(
        executionId: entry.executionId,
        typedName: entry.releaseName,
      ),
      l10n.aiWriteLogReleased,
    );
  }

  Future<void> _reset() async {
    final account = widget.account;
    final username = '@${account.user.username}';
    // Readable: count what the reset releases. Unreadable: say so, since
    // the log may hold changes in an unknown state.
    final entries = _entries;
    final releases = entries
        ?.where(
          (entry) =>
              entry.state == AiJournalState.dispatching ||
              entry.state == AiJournalState.writeUncertain,
        )
        .length;
    final confirmed = await confirmAction(
      context,
      l10n.aiWriteLogResetTitle,
      [
        l10n.aiWriteLogResetAccount(
          account.instance.key,
          username,
          '${account.user.id}',
        ),
        l10n.aiWriteLogResetDetail(username),
        releases == null
            ? l10n.aiWriteLogResetUnknown
            : l10n.aiWriteLogResetReleases('$releases'),
        l10n.aiWriteLogResetNotUndo,
      ].join('\n\n'),
      requiredText: username,
    );
    if (!confirmed || !mounted) return;
    await _act(() async {
      final reset = await widget.journal.beginReset(
        _accountKey,
        verifiedUsername: username,
      );
      try {
        await widget.journal.completeReset(reset, typedUsername: username);
      } on Object {
        widget.journal.cancelReset(reset);
        rethrow;
      }
    }, l10n.aiWriteLogResetDone);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final entries = _entries;
    final interrupted = [
      for (final entry in entries ?? const <AiJournalEntry>[])
        if (entry.state == AiJournalState.writeUncertain) entry,
    ];
    return ScaffoldMessenger(
      key: _messenger,
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.aiWriteLogTitle)),
        body: SafeArea(
          top: false,
          child: ListView(
            key: const ValueKey('ai-write-log-list'),
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(l10n.aiWriteLogIntro, style: muted),
              ),
              if (_failure case final failure?)
                _ReadFailure(
                  failure: failure,
                  busy: _busy,
                  onRetry: _retry,
                  onReset: _reset,
                )
              else if (entries == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else ...[
                if (interrupted.isNotEmpty)
                  HubSection(
                    title: l10n.aiWriteLogInterrupted,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          l10n.aiWriteLogInterruptedDetail,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      for (final entry in interrupted)
                        _InterruptedRow(
                          entry: entry,
                          busy: _busy,
                          onObserve: () => _observe(entry),
                          onRelease: () => _release(entry),
                        ),
                    ],
                  ),
                HubSection(
                  title: l10n.aiWriteLogRecent,
                  children: [
                    if (entries.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(l10n.aiWriteLogEmpty, style: muted),
                      ),
                    for (final entry in entries) _EntryRow(entry: entry),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      key: const ValueKey('ai-write-log-reset'),
                      icon: const Icon(Icons.restart_alt),
                      onPressed: _busy ? null : _reset,
                      label: Text(l10n.aiWriteLogReset),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _when(BuildContext context, DateTime? at) {
  if (at == null) return '';
  final local = at.toLocal();
  final material = MaterialLocalizations.of(context);
  return '${material.formatShortDate(local)} '
      '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

/// The log could not be read. A passing failure offers a retry; a lost key or
/// an unreadable file can only be reset, which needs the account's @name.
class _ReadFailure extends StatelessWidget {
  const _ReadFailure({
    required this.failure,
    required this.busy,
    required this.onRetry,
    required this.onReset,
  });

  final AiJournalKeyStatus failure;
  final bool busy;
  final VoidCallback onRetry;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final transient = failure == AiJournalKeyStatus.unavailable;
    return Padding(
      key: const ValueKey('ai-write-log-unavailable'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.error_outline, color: theme.colorScheme.error),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  transient
                      ? l10n.aiWriteLogUnavailable
                      : l10n.aiWriteLogUnreadable,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: transient
                ? OutlinedButton.icon(
                    key: const ValueKey('ai-write-log-retry'),
                    icon: const Icon(Icons.refresh),
                    onPressed: busy ? null : onRetry,
                    label: Text(l10n.retryAction),
                  )
                : OutlinedButton.icon(
                    key: const ValueKey('ai-write-log-reset'),
                    icon: const Icon(Icons.restart_alt),
                    onPressed: busy ? null : onReset,
                    label: Text(l10n.aiWriteLogReset),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry});

  final AiJournalEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, color) = switch (entry.state) {
      AiJournalState.succeeded => (Icons.check_circle_outline, HubColors.green),
      AiJournalState.failedCertain => (
        Icons.error_outline,
        theme.colorScheme.error,
      ),
      AiJournalState.writeUncertain => (Icons.help_outline, HubColors.orange),
      AiJournalState.resolvedByUser => (
        Icons.task_alt,
        theme.colorScheme.onSurfaceVariant,
      ),
      AiJournalState.prepared || AiJournalState.dispatching => (
        Icons.schedule,
        theme.colorScheme.onSurfaceVariant,
      ),
      AiJournalState.notExecuted => (
        Icons.remove_circle_outline,
        theme.colorScheme.onSurfaceVariant,
      ),
    };
    final when = _when(context, entry.dispatchedAt);
    return ListTile(
      key: ValueKey('ai-write-log-${entry.executionId}'),
      leading: Icon(icon, color: color),
      title: Text(aiOperationLabel(entry.operationId)),
      subtitle: Text(
        [
          isolated(entry.releaseName),
          aiJournalStateLabel(entry.state),
          if (when.isNotEmpty) when,
        ].join(' · '),
      ),
    );
  }
}

class _InterruptedRow extends StatelessWidget {
  const _InterruptedRow({
    required this.entry,
    required this.busy,
    required this.onObserve,
    required this.onRelease,
  });

  final AiJournalEntry entry;
  final bool busy;
  final VoidCallback onObserve;
  final VoidCallback onRelease;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final observation = switch (entry.observation) {
      aiObservedDone => l10n.aiWriteLogObservedDone,
      aiObservedNotDone => l10n.aiWriteLogObservedNotDone,
      _ => null,
    };
    final when = _when(context, entry.dispatchedAt);
    return Padding(
      key: ValueKey('ai-write-log-interrupted-${entry.executionId}'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.help_outline, color: HubColors.orange),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      aiOperationLabel(entry.operationId),
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      [
                        isolated(entry.releaseName),
                        if (when.isNotEmpty) when,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                    if (observation != null)
                      Text(
                        l10n.aiWriteLogObservation(observation),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 4,
            children: [
              TextButton(
                key: ValueKey('ai-write-log-observe-${entry.executionId}'),
                onPressed: busy ? null : onObserve,
                child: Text(l10n.aiWriteLogObserve),
              ),
              FilledButton.tonal(
                key: ValueKey('ai-write-log-release-${entry.executionId}'),
                onPressed: busy ? null : onRelease,
                child: Text(l10n.aiWriteLogRelease),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
