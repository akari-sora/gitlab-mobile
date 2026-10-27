import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/read_cache_files.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/cache/read_cache_disk_coordinator.dart';
import 'package:gitlab_mobile/features/cache/read_cache_key_store.dart';
import 'package:gitlab_mobile/features/cache/read_cache_settings_store.dart';
import 'package:gitlab_mobile/main.dart';

import 'session_test.dart' show MemoryAccountStore;

class _BlockedInitialization extends MemoryAccountStore {
  final release = Completer<void>();
  final reachedPostAccountLoad = Completer<void>();
  @override
  Future<bool> loadSignOutPending() async {
    reachedPostAccountLoad.complete();
    await release.future;
    return false;
  }
}

class _CacheStorage implements ReadCacheSecureStorage {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'history waits for the full startup decision after installing observers',
    () async {
      final root = Directory.systemTemp.createTempSync('ai-main-recovery-');
      final saved = Account(
        instance: GitLabInstance.parse('https://synthetic.example'),
        user: const GitLabUser(id: 7, username: 'synthetic', name: 'Synthetic'),
        token: 'synthetic-token',
      );
      final accounts = _BlockedInitialization()..accounts = [saved];
      final storage = _CacheStorage();
      final cache = ReadCacheDiskCoordinator(
        keys: ReadCacheKeyStore(storage),
        files: ReadCacheFileStore(root: () async => root),
        settings: ReadCacheSettingsStore(storage),
        coordinationScope: Object(),
      );
      final session = SessionController(accounts, readCache: cache);
      final store = MemoryAiStore();
      final coordinator = AiHistoryCoordinator.debugReset(
        store: store,
        files: AiHistoryFileStore(root: () async => root),
      );
      await coordinator.load(saved.key);
      final mutations = AiAccountMutationCoordinator.forStore(store);
      mutations.beginCleaning(saved.key);
      expect(mutations.isCleaning(saved.key), isTrue);
      final orphan = await coordinator.files.directory('orphan');
      orphan.createSync(recursive: true);
      final removed = Completer<void>();
      final previousRemoval = removeAiHistoryDirectory;
      removeAiHistoryDirectory = (dir) {
        dir.deleteSync(recursive: true);
        if (!removed.isCompleted) removed.complete();
      };
      addTearDown(() {
        removeAiHistoryDirectory = previousRemoval;
        session.dispose();
        coordinator.dispose();
        root.deleteSync(recursive: true);
      });
      final journal = AiWriteJournal(
        keys: MemoryAiJournalKeyStore(),
        applicationSupport: root,
        processId: 'synthetic',
      );
      final initialization = initializeSessionWithAiRecovery(
        session,
        journal: journal,
      );
      await accounts.reachedPostAccountLoad.future;
      expect(session.accountsLoaded, isTrue);
      expect(session.initializing, isTrue);
      // The member observer reopened the retained account even though the
      // marker read is still blocked and destructive recovery cannot start.
      expect(mutations.isCleaning(saved.key), isFalse);
      await pumpEventQueue();
      expect(orphan.existsSync(), isTrue);
      expect(removed.isCompleted, isFalse);
      accounts.release.complete();
      await initialization;
      await removed.future.timeout(const Duration(seconds: 5));
      expect(orphan.existsSync(), isFalse);
    },
  );
}
