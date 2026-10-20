import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'main recovery starts at accountsLoaded before initialization completes',
    () async {
      final root = Directory.systemTemp.createTempSync('ai-main-recovery-');
      final accounts = _BlockedInitialization();
      final session = SessionController(accounts);
      final store = MemoryAiStore();
      final coordinator = AiHistoryCoordinator.debugReset(
        store: store,
        files: AiHistoryFileStore(root: () async => root),
      );
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
      final initialization = initializeSessionWithAiRecovery(session);
      await accounts.reachedPostAccountLoad.future;
      expect(session.accountsLoaded, isTrue);
      expect(session.initializing, isTrue);
      await removed.future.timeout(const Duration(seconds: 5));
      expect(orphan.existsSync(), isFalse);
      expect(session.initializing, isTrue);
      accounts.release.complete();
      await initialization;
    },
  );
}
