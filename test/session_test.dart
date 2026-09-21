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
  bool signOutPending = false;
  bool rejectWrite = false;
  bool failLastActiveDelete = false;
  Completer<void>? holdLastActiveWrite;
  int lastActiveWrites = 0;
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
    lastActiveWrites++;
    final hold = holdLastActiveWrite;
    holdLastActiveWrite = null;
    if (hold != null) await hold.future;
    if (rejectWrite) throw StateError('synthetic key-store failure');
    if (key == null && failLastActiveDelete) {
      throw StateError('synthetic key-store failure');
    }
    lastActive = key;
  }

  @override
  Future<bool> loadSignOutPending() async => signOutPending;
  @override
  Future<void> saveSignOutPending(bool pending) async {
    if (rejectWrite) throw StateError('synthetic key-store failure');
    signOutPending = pending;
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
  createApi: (instance, credential, oauth, onOAuthRotated) => GitLabApi(
    instance: instance,
    credential: credential,
    dio: Dio()..httpClientAdapter = adapter,
    oauth: oauth,
    onOAuthRotated: onOAuthRotated,
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
      final ending = controller.endSession();
      deferred.complete(jsonResponse({'id': 7, 'username': 'tester'}));
      await connect;
      await ending;
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
    await controller.endSession();
    expect(controller.active, isNull);
    expect(controller.pendingSignOutCleanup, isFalse);
    expect(store.signOutPending, isFalse);
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
    final ending = controller.endSession();
    expect(controller.resuming, isFalse);
    expect(controller.active, isNull);
    deferred.complete(jsonResponse({'id': 7, 'username': 'tester'}));
    await pending;
    await ending;
    expect(controller.active, isNull);
    expect(store.lastActive, isNull);
    expect(store.signOutPending, isFalse);
  });

  test('failed sign-out does not resume that account on the next launch', () async {
    final store = MemoryAccountStore();
    final adapter = FakeAdapter(
      (_) => jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'}),
    );
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.connect('https://example.com', 'synthetic-test-token');
    final remembered = controller.active?.key;
    expect(store.lastActive, remembered);
    store.failLastActiveDelete = true;
    await controller.endSession();
    expect(controller.active, isNull);
    expect(controller.pendingSignOutCleanup, isTrue);
    expect(controller.message, '無法清除自動登入記錄；請重試登出。');
    expect(store.lastActive, remembered);
    expect(store.signOutPending, isTrue);
    store.failLastActiveDelete = false;
    final next = controllerFor(store, adapter);
    addTearDown(next.dispose);
    await next.initialize();
    expect(next.active, isNull);
    expect(next.resuming, isFalse);
    expect(
      adapter.requests.where((request) => request.uri.path.endsWith('/user')),
      hasLength(1),
    );
  });

  test('a later sign-out overwrites an in-flight last-active write', () async {
    final hold = Completer<void>();
    final store = MemoryAccountStore()..holdLastActiveWrite = hold;
    final adapter = FakeAdapter(
      (_) => jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'}),
    );
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.connect('https://example.com', 'synthetic-test-token');
    await Future<void>.delayed(Duration.zero);
    expect(store.lastActiveWrites, 1);
    expect(store.lastActive, isNull);
    final ending = controller.endSession();
    expect(controller.active, isNull);
    await Future<void>.delayed(Duration.zero);
    expect(store.lastActiveWrites, 1);
    hold.complete();
    await ending;
    expect(store.lastActive, isNull);
    expect(store.lastActiveWrites, 2);
    expect(store.signOutPending, isFalse);
  });

  test('resume keeps the remembered key after a transient failure', () async {
    final store = MemoryAccountStore();
    final saved = savedAccount();
    store.accounts = [saved];
    store.lastActive = saved.key;
    final adapter = FakeAdapter(
      (request) => throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
      ),
    );
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.active, isNull);
    expect(controller.message, contains('無法連線'));
    expect(store.lastActive, saved.key);
    expect(store.signOutPending, isFalse);
  });

  test('resume keeps the remembered key when GitLab rate-limits', () async {
    final store = MemoryAccountStore();
    final saved = savedAccount();
    store.accounts = [saved];
    store.lastActive = saved.key;
    final adapter = FakeAdapter(
      (_) => jsonResponse({'message': 'slow down'}, status: 429),
    );
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.active, isNull);
    expect(controller.message, contains('稍後再試'));
    expect(store.lastActive, saved.key);
  });

  test('resume stores OAuth tokens rotated before activation', () async {
    final store = MemoryAccountStore();
    final saved = Account(
      instance: GitLabInstance.parse('https://example.com'),
      user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
      credential: const OAuthCredential(
        accessToken: 'old-access',
        refreshToken: 'old-refresh',
        clientId: 'synthetic-app-id',
      ),
    );
    store.accounts = [saved];
    store.lastActive = saved.key;
    var users = 0;
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/oauth/token')) {
        return jsonResponse({
          'access_token': 'rotated-access',
          'refresh_token': 'rotated-refresh',
          'token_type': 'bearer',
          'expires_in': 7200,
        });
      }
      users += 1;
      if (users == 1) {
        return jsonResponse({'message': 'expired'}, status: 401);
      }
      return jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'});
    });
    final controller = controllerFor(
      store,
      adapter,
      createOAuth: (instance, clientId) => OAuthTokenClient(
        instance: instance,
        clientId: clientId,
        dio: Dio()..httpClientAdapter = adapter,
      ),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.active?.user.id, 7);
    final stored = store.accounts.single.credential as OAuthCredential;
    expect(stored.accessToken, 'rotated-access');
    expect(stored.refreshToken, 'rotated-refresh');
    final active = controller.active!.credential as OAuthCredential;
    expect(active.accessToken, 'rotated-access');
    expect(active.refreshToken, 'rotated-refresh');
  });
}
