import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_fence.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

const account = 'https://synthetic.example/gitlab#7';
const other = 'https://synthetic.example/gitlab#8';
const removed = 'https://synthetic.example/gitlab#9';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late MemoryAiStore store;
  late AiHistoryCoordinator history;

  setUp(() {
    root = Directory.systemTemp.createTempSync('packet11-fence-');
    store = MemoryAiStore();
    history = AiHistoryCoordinator.debugReset(
      store: store,
      files: AiHistoryFileStore(root: () async => root),
    );
  });
  tearDown(() {
    history.dispose();
    root.deleteSync(recursive: true);
  });

  test('reports cleaning while the history coordinator cleans', () async {
    final fence = AiHistoryJournalFence(() => history);
    expect(fence.isCleaning(account), isFalse);

    final clearing = history.clearAccount(account);
    // Cleanup takes the fence synchronously, before its first await.
    expect(history.state(account), AiHistoryState.cleaning);
    expect(fence.isCleaning(account), isTrue);
    expect(fence.isCleaning(other), isFalse);

    // The journal runs its own cleanup step through the fence while the
    // account is cleaning, so run must not wait for or refuse it.
    expect(await fence.run(account, () async => 'ran'), 'ran');

    await clearing;
    expect(history.state(account), AiHistoryState.disabled);
    // The mutation fence stays closed after cleanup until it is reopened.
    expect(fence.isCleaning(account), isTrue);
    AiAccountMutationCoordinator.forStore(store).reopen(account);
    expect(fence.isCleaning(account), isFalse);
  });

  test('a loaded removal tombstone counts as cleaning', () async {
    final fence = AiHistoryJournalFence(() => history);
    await store.setTombstone(removed);
    expect(fence.isCleaning(removed), isFalse);
    await history.load(removed);
    expect(history.state(removed), AiHistoryState.cleaning);
    expect(
      AiAccountMutationCoordinator.forStore(store).isCleaning(removed),
      isFalse,
    );
    expect(fence.isCleaning(removed), isTrue);
  });

  test('the default fence follows AiHistoryCoordinator.instance', () async {
    final fence = AiHistoryJournalFence();
    expect(identical(AiHistoryCoordinator.instance, history), isTrue);
    final clearing = AiHistoryCoordinator.instance.clearAccount(account);
    expect(fence.isCleaning(account), isTrue);
    await clearing;
  });

  test('the write journal refuses to start a reset while cleaning', () async {
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      fence: AiHistoryJournalFence(() => history),
      processId: 'packet11-fence',
    );
    await journal.recoverAfterAccountsLoaded(<String>[account, other]);

    final clearing = history.clearAccount(account);
    await expectLater(
      journal.beginReset(account),
      throwsA(
        isA<AiJournalException>().having(
          (error) => error.reason,
          'reason',
          'accountBlocked',
        ),
      ),
    );
    final reset = await journal.beginReset(other);
    journal.cancelReset(reset);
    await clearing;
  });
}
