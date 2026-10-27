import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';

class _SignalledAccountStore extends MemoryAccountStore {
  final saving = Completer<void>();
  @override
  Future<void> save(List<Account> value) {
    if (!saving.isCompleted) saving.complete();
    return super.save(value);
  }
}

void main() {
  test(
    'fix3 OAuth rotation cannot re-add an account during removal commit',
    () async {
      final root = Directory.systemTemp.createTempSync('md-removal-rotation-');
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => root;
      resetMarkdownMediaStartup();
      addTearDown(() {
        artifactStorageRoot = previousRoot;
        resetMarkdownMediaStartup();
        root.deleteSync(recursive: true);
      });
      final account = Account(
        instance: GitLabInstance.parse('https://example.com'),
        user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
        credential: const OAuthCredential(
          accessToken: 'synthetic-old',
          refreshToken: 'synthetic-refresh',
          clientId: 'synthetic-app',
        ),
      );
      final store = _SignalledAccountStore()
        ..accounts = [account]
        ..lastActive = account.key;
      late Future<void> Function(OAuthCredential) rotate;
      final controller = SessionController(
        store,
        readCache: store.readCache,
        createApi: (instance, credential, oauth, onRotated) {
          rotate = onRotated;
          return GitLabApi(
            instance: instance,
            credential: credential,
            dio: Dio()
              ..httpClientAdapter = FakeAdapter(
                (_) => jsonResponse({
                  'id': 7,
                  'username': 'tester',
                  'name': 'Test',
                }),
              ),
          );
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final gate = Completer<void>();
      store.holdAccountSave = gate;
      final removal = controller.remove(account);
      await store.saving.future.timeout(const Duration(seconds: 5));
      expect(store.accountSaves, 1);
      final rotation = rotate(
        const OAuthCredential(
          accessToken: 'synthetic-new',
          refreshToken: 'synthetic-new-refresh',
          clientId: 'synthetic-app',
        ),
      );
      gate.complete();
      await removal;
      await rotation;
      expect(store.accounts, isEmpty);
      expect(controller.accounts, isEmpty);
      expect(controller.active, isNull);
    },
  );

  test(
    'fix3 queued removal commits its cutoff when another save supersedes it',
    () async {
      final root = Directory.systemTemp.createTempSync('md-queued-removal-');
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => root;
      resetMarkdownMediaStartup();
      addTearDown(() {
        artifactStorageRoot = previousRoot;
        resetMarkdownMediaStartup();
        root.deleteSync(recursive: true);
      });
      final instance = GitLabInstance.parse('https://example.com');
      const credential = OAuthCredential(
        accessToken: 'synthetic-old',
        refreshToken: 'synthetic-refresh',
        clientId: 'synthetic-app',
      );
      final removed = Account(
        instance: instance,
        user: const GitLabUser(id: 1, username: 'removed', name: 'Removed'),
        credential: const PatCredential('synthetic-pat'),
      );
      final retained = Account(
        instance: instance,
        user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
        credential: credential,
      );
      final store = MemoryAccountStore()
        ..accounts = [removed, retained]
        ..lastActive = retained.key;
      late Future<void> Function(OAuthCredential) rotate;
      final controller = SessionController(
        store,
        readCache: store.readCache,
        createApi: (instance, credential, oauth, onRotated) {
          rotate = onRotated;
          return GitLabApi(
            instance: instance,
            credential: credential,
            dio: Dio()
              ..httpClientAdapter = FakeAdapter(
                (_) => jsonResponse({
                  'id': 7,
                  'username': 'tester',
                  'name': 'Test',
                }),
              ),
          );
        },
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final gate = Completer<void>();
      store.holdAccountSave = gate;
      final first = rotate(credential);
      expect(store.accountSaves, 1);
      final removal = controller.remove(removed);
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final heldGeneration = markdownMediaAccountGeneration(removed);
      final later = rotate(credential);
      gate.complete();
      await Future.wait([first, removal, later]);
      expect(store.accounts.map((account) => account.key), [retained.key]);
      expect(
        () => usableMarkdownMediaAccountGeneration(
          removed,
          generation: heldGeneration,
        ),
        throwsA(isA<Exception>()),
      );
    },
  );
}
