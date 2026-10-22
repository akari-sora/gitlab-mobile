import 'ai_history.dart';
import 'ai_stores.dart';
import 'ai_write_journal.dart';

/// The write journal's account fence, read from the AI history owner.
///
/// An account counts as cleaning while [AiHistoryCoordinator] reports it in
/// `cleaning` (a cleanup in progress, a failed one, or a removal tombstone it
/// has loaded) or while that owner's [AiAccountMutationCoordinator] holds the
/// account's cleanup fence, which stays closed after a cleanup until it is
/// explicitly reopened.
///
/// [run] calls the action directly: neither coordinator exposes a public
/// per-account queue that takes an arbitrary action, and their private queues
/// are the ones account cleanup itself waits in, so joining them could
/// deadlock when cleanup calls into the journal. The journal serialises its
/// own per-account transactions.
final class AiHistoryJournalFence implements AiJournalAccountFence {
  /// Without [history] the fence follows [AiHistoryCoordinator.instance].
  AiHistoryJournalFence([AiHistoryCoordinator Function()? history])
    : _history = history ?? (() => AiHistoryCoordinator.instance);

  final AiHistoryCoordinator Function() _history;

  @override
  bool isCleaning(String accountKey) {
    final history = _history();
    return history.state(accountKey) == AiHistoryState.cleaning ||
        AiAccountMutationCoordinator.forStore(
          history.store,
        ).isCleaning(accountKey);
  }

  @override
  Future<T> run<T>(String accountKey, Future<T> Function() action) => action();
}
