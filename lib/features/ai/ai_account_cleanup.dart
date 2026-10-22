import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/models.dart';
import 'ai_history.dart';
import 'ai_journal_key_store.dart';
import 'ai_write_journal.dart';

/// Test seam. Production cleanup uses [AiWriteJournal.instance].
@visibleForTesting
AiWriteJournal? debugWriteJournalForCleanup;

/// The journal that owns removal holds and the tombstone journal step.
AiWriteJournal get writeJournalForCleanup =>
    debugWriteJournalForCleanup ?? AiWriteJournal.instance;

bool _processJournalWired = false;

/// Wires the process journal. Hosts call this instead of
/// `AiWriteJournal.instance.configure`, so account removal knows that the
/// journal can hold writes and reads it before the final confirmation. A
/// journal configured earlier stays in force and counts as wired.
void wireAiWriteJournal({
  required AiJournalKeyStore keys,
  required Directory applicationSupport,
  required AiJournalAccountFence fence,
}) {
  try {
    AiWriteJournal.instance.configure(
      keys: keys,
      applicationSupport: applicationSupport,
      fence: fence,
    );
  } on AiJournalException catch (error) {
    if (error.reason != 'alreadyConfigured') rethrow;
  }
  _processJournalWired = true;
}

/// False while this build has no write journal: no AI write can have been
/// recorded, so removal keeps its plain confirmation. An unconfigured journal
/// reports its accounts as `unknownFormat`, which must not ask for a name.
bool get writeJournalWired =>
    debugWriteJournalForCleanup != null || _processJournalWired;

/// Unconditional account-removal boundary, also when AI is disabled by the gate.
Future<void> clearAiAccountData(Account account) =>
    AiHistoryCoordinator.instance.clearAccount(account.key);

/// Journal step of the tombstone flow (§8 account removal, last paragraph).
/// [AiHistoryCoordinator] runs it after `setTombstone` and before any history
/// step, so removal, start-up recovery and the settings retry all pass here.
///
/// Rows still isolating after the removal-start mark (or with no mark) keep
/// the journal and the tombstone and throw `retryAccountRemoval` while the
/// account is listed: only the named removal flow may release them. For an
/// account that is no longer listed nothing can use those locks; the journal
/// is left to the start-up inventory and orphan cleanup and history cleanup
/// goes on. An unavailable journal throws `unavailable` and is retried later.
Future<void> deleteWriteJournalForTombstone(
  String accountKey, {
  required bool accountListed,
}) async {
  final journal = writeJournalForCleanup;
  try {
    if (!await journal.mayCleanupTombstone(accountKey)) {
      if (accountListed) {
        throw const AiJournalException('retryAccountRemoval');
      }
      return;
    }
    await journal.clearForRemoval(accountKey);
  } on AiJournalException catch (error) {
    if (error.reason == 'notConfigured') return;
    if (!accountListed && error.reason == 'retryAccountRemoval') return;
    rethrow;
  }
}
