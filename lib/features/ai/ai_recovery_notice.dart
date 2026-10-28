import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../security/app_lock.dart';
import 'ai_write_journal.dart';

final Expando<ValueNotifier<int>> _passes = Expando<ValueNotifier<int>>(
  'aiJournalRecoveryPasses',
);

/// Counts finished start-up recovery passes of [journal]; the notice waits
/// for one before reading anything.
ValueListenable<int> aiJournalRecoveryPasses(AiWriteJournal journal) =>
    _passes[journal] ??= ValueNotifier<int>(0);

/// Called by start-up after each completed recovery pass of [journal].
void markAiJournalRecovered(AiWriteJournal journal) {
  final passes = _passes[journal] ??= ValueNotifier<int>(0);
  passes.value++;
}

/// Tells the signed-in account, once, that AI writes were cut off when the
/// app last closed (C7). It only reads the journal's content-free summary
/// after a finished recovery pass, waits until the app lock is open, and
/// acknowledges that exact summary only after the person dismisses the
/// notice. Nothing is resent, resumed or approved from here; unreadable
/// journals keep using the existing retry and reset entries in settings.
class AiRecoveryNotice extends StatefulWidget {
  const AiRecoveryNotice({
    super.key,
    required this.journal,
    required this.accountKey,
    this.lock,
    required this.child,
  });

  final AiWriteJournal journal;
  final String accountKey;
  final AppLockController? lock;
  final Widget child;

  @override
  State<AiRecoveryNotice> createState() => _AiRecoveryNoticeState();
}

class _AiRecoveryNoticeState extends State<AiRecoveryNotice> {
  late ValueListenable<int> _passes;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    _passes = aiJournalRecoveryPasses(widget.journal)..addListener(_check);
    widget.lock?.addListener(_check);
    _check();
  }

  @override
  void didUpdateWidget(AiRecoveryNotice old) {
    super.didUpdateWidget(old);
    if (!identical(old.journal, widget.journal)) {
      _passes.removeListener(_check);
      _passes = aiJournalRecoveryPasses(widget.journal)..addListener(_check);
    }
    if (!identical(old.lock, widget.lock)) {
      old.lock?.removeListener(_check);
      widget.lock?.addListener(_check);
    }
    _check();
  }

  @override
  void dispose() {
    _passes.removeListener(_check);
    widget.lock?.removeListener(_check);
    super.dispose();
  }

  bool _checkScheduled = false;

  /// Checks after the current frame: notifications and widget updates can
  /// arrive while the tree builds, and a dialog cannot open then.
  void _check() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _checkScheduled = false;
        _checkNow();
      })
      ..ensureVisualUpdate();
  }

  void _checkNow() {
    if (!mounted || _showing || _passes.value == 0) return;
    final lock = widget.lock;
    if (lock != null && lock.covering) return;
    // Read again right before showing; acknowledge only this summary.
    final result = widget.journal.recoveryResult(widget.accountKey);
    final count = result.interruptedWrites;
    if (!result.mayNotifyInterruption || count == null) return;
    _showing = true;
    unawaited(_show(result, count));
  }

  Future<void> _show(AiJournalRecoveryResult result, int count) async {
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          key: const ValueKey('ai-recovery-notice'),
          icon: const Icon(Icons.history_toggle_off),
          title: Text(l10n.aiRecoveryTitle),
          content: SingleChildScrollView(
            child: Text(l10n.aiRecoveryInterrupted('$count')),
          ),
          actions: [
            FilledButton(
              key: const ValueKey('ai-recovery-ok'),
              onPressed: () => Navigator.pop(context),
              child: Text(l10n.aiRecoveryOk),
            ),
          ],
        ),
      );
      // Seen and dismissed: only now is this summary acknowledged.
      if (mounted) {
        widget.journal.acknowledgeRecovery(widget.accountKey, result);
      }
    } finally {
      _showing = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
