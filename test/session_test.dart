import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/auth/account_store.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'support/fake_adapter.dart';

class MemoryAccountStore implements AccountStore {
  List<Account> accounts = [];
  String? lastActive;
  bool rejectWrite = false;
  @override
  Future<List<Account>> load() async => accounts;
  @override
  Future<void> save(List<Account> value) async {
    if (rejectWrite) throw StateError('synthetic key-store failure');
    accounts = List.of(value);
  }

  @override
  Future<String?> loadLastActive() async => lastActive;
  @override
  Future<void> saveLastActive(String? key) async {
    if (rejectWrite) throw StateError('synthetic key-store failure');
    lastActive = key;
  }
}

SessionController controllerFor(
  MemoryAccountStore store,
  FakeAdapter adapter, {
  AuthorizationBrowser? browser,
  String? Function(GitLabInstance instance)? applicationIdFor,
  OAuthTokenClient Function(GitLabInstance instance, String clientId)?
  createOAuth,
}) => SessionController(
  store,
  applicationIdFor: applicationIdFor,
  browser: browser,
  createOAuth: createOAuth,
  createApi: (instance, credential) => GitLabApi(
    instance: instance,
    credential: credential,
    dio: Dio()..httpClientAdapter = adapter,
  ),
);

void main() {
  test('activates only after /user and secure-store success', () async {
    final store = MemoryAccountStore();
    final adapter = FakeAdapter(
      (_) => jsonResponse({'id': 7, 'username': 'tester'}),
    );
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.connect('https://example.com', 'synthetic-test-token');
    expect(controller.active?.user.id, 7);
    expect(store.accounts.single.user.id, 7);
  });
  test('secure-store failure never activates a session', () async {
    final store = MemoryAccountStore()..rejectWrite = true;
    final adapter = FakeAdapter(
      (_) => jsonResponse({'id': 7, 'username': 'tester'}),
    );
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.connect('https://example.com', 'synthetic-test-token');
    expect(controller.active, isNull);
    expect(store.accounts, isEmpty);
  });
  test(
    'saved token that resolves to different numeric user is rejected',
    () async {
      final store = MemoryAccountStore();
      final saved = Account(
        instance: GitLabInstance.parse('https://example.com'),
        user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
        token: 'synthetic-test-token',
      );
      store.accounts = [saved];
      final adapter = FakeAdapter(
        (_) => jsonResponse({'id': 8, 'username': 'other'}),
      );
      final controller = controllerFor(store, adapter);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.select(saved);
      expect(controller.active, isNull);
      expect(controller.message, isNotNull);
    },
  );
  test('connect 401 does not use expired-session copy', () async {
    final store = MemoryAccountStore();
    final adapter = FakeAdapter(
      (_) => jsonResponse({'message': 'unauthorized'}, status: 401),
    );
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.connect('https://example.com', 'synthetic-test-token');
    expect(controller.active, isNull);
    expect(controller.message, isNot(contains('登入已失效')));
    expect(controller.message, contains('無法驗證這個 Token'));
  });
  test(
    'select 401 keeps expired-session copy and does not drop the saved account',
    () async {
      final store = MemoryAccountStore();
      final saved = Account(
        instance: GitLabInstance.parse('https://example.com'),
        user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
        token: 'synthetic-test-token',
      );
      store.accounts = [saved];
      final adapter = FakeAdapter(
        (_) => jsonResponse({'message': 'unauthorized'}, status: 401),
      );
      final controller = controllerFor(store, adapter);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.select(saved);
      expect(controller.active, isNull);
      expect(controller.message, contains('登入已失效'));
      expect(store.accounts, hasLength(1));
    },
  );
  test(
    'remove clears the store and does not activate another account',
    () async {
      final store = MemoryAccountStore();
      final saved = Account(
        instance: GitLabInstance.parse('https://example.com'),
        user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
        token: 'synthetic-test-token',
      );
      store.accounts = [saved];
      final adapter = FakeAdapter(
        (_) => jsonResponse({'id': 7, 'username': 'tester'}),
      );
      final controller = controllerFor(store, adapter);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.remove(saved);
      expect(store.accounts, isEmpty);
      expect(controller.active, isNull);
    },
  );
  test(
    'ending session while sign-in is pending cannot later reactivate it',
    () async {
      final deferred = Completer<ResponseBody>();
      final store = MemoryAccountStore();
      final adapter = FakeAdapter((_) => deferred.future);
      final controller = controllerFor(store, adapter);
      addTearDown(controller.dispose);
      await controller.initialize();
      final connect = controller.connect(
        'https://example.com',
        'synthetic-test-token',
      );
      await Future<void>.delayed(Duration.zero);
      controller.endSession();
      deferred.complete(jsonResponse({'id': 7, 'username': 'tester'}));
      await connect;
      expect(controller.active, isNull);
      expect(store.accounts, isEmpty);
    },
  );

  Account savedAccount() => Account(
    instance: GitLabInstance.parse('https://example.com'),
    user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
    token: 'synthetic-test-token',
  );

  test('resume stored account when /user matches', () async {
    final store = MemoryAccountStore();
    final saved = savedAccount();
    store.accounts = [saved];
    store.lastActive = saved.key;
    final adapter = FakeAdapter(
      (_) => jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'}),
    );
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.active?.user.id, 7);
    expect(controller.active?.user.username, 'tester');
    expect(controller.api, isNotNull);
    expect(controller.resuming, isFalse);
    expect(controller.resumingAccount, isNull);
    expect(store.lastActive, saved.key);
  });

  test(
    'resume 401 leaves the existing message and does not activate',
    () async {
      final store = MemoryAccountStore();
      final saved = savedAccount();
      store.accounts = [saved];
      store.lastActive = saved.key;
      final adapter = FakeAdapter(
        (_) => jsonResponse({'message': 'unauthorized'}, status: 401),
      );
      final controller = controllerFor(store, adapter);
      addTearDown(controller.dispose);
      await controller.initialize();
      expect(controller.active, isNull);
      expect(controller.resuming, isFalse);
      expect(controller.message, contains('登入已失效'));
      expect(store.accounts, hasLength(1));
      expect(store.lastActive, isNull);
    },
  );

  test('resume does not activate when /user id differs', () async {
    final store = MemoryAccountStore();
    final saved = savedAccount();
    store.accounts = [saved];
    store.lastActive = saved.key;
    final adapter = FakeAdapter(
      (_) => jsonResponse({'id': 8, 'username': 'other'}),
    );
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.active, isNull);
    expect(controller.message, contains('登入已失效'));
    expect(store.lastActive, isNull);
    expect(store.accounts, hasLength(1));
  });

  test('resume ignores a stored key for an account that is not saved', () async {
    final store = MemoryAccountStore();
    store.accounts = [savedAccount()];
    store.lastActive = 'https://example.com#999';
    final adapter = FakeAdapter(
      (_) => jsonResponse({'id': 7, 'username': 'tester'}),
    );
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.active, isNull);
    expect(controller.message, isNull);
    expect(controller.resuming, isFalse);
    expect(adapter.requests, isEmpty);
    expect(store.lastActive, 'https://example.com#999');
  });

  test('endSession clears the stored last-active key', () async {
    final store = MemoryAccountStore();
    final adapter = FakeAdapter(
      (_) => jsonResponse({'id': 7, 'username': 'tester'}),
    );
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.connect('https://example.com', 'synthetic-test-token');
    expect(controller.active, isNotNull);
    expect(store.lastActive, controller.active?.key);
    controller.endSession();
    expect(controller.active, isNull);
    expect(store.lastActive, isNull);
  });

  test('endSession during resume does not activate the account', () async {
    final deferred = Completer<ResponseBody>();
    final store = MemoryAccountStore();
    final saved = savedAccount();
    store.accounts = [saved];
    store.lastActive = saved.key;
    final adapter = FakeAdapter((_) => deferred.future);
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    final pending = controller.initialize();
    for (var i = 0; i < 8 && !controller.resuming; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.resuming, isTrue);
    expect(controller.resumingAccount?.user.username, 'tester');
    controller.endSession();
    expect(controller.resuming, isFalse);
    expect(store.lastActive, isNull);
    deferred.complete(jsonResponse({'id': 7, 'username': 'tester'}));
    await pending;
    expect(controller.active, isNull);
    expect(store.lastActive, isNull);
  });
}
