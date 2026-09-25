import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/auth/account_store.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/shared/resume_target.dart';
import 'support/fake_adapter.dart';

class MemoryAccountStore implements AccountStore {
  List<Account> accounts = [];
  String? lastActive;
  bool signOutPending = false;
  bool rejectWrite = false;
  bool failLastActiveDelete = false;
  bool failSignOutMarker = false;
  Completer<void>? holdLastActiveWrite;
  Completer<void>? holdAccountSave;
  int lastActiveWrites = 0;
  int accountSaves = 0;
  @override
  Future<List<Account>> load() async => accounts;
  @override
  Future<void> save(List<Account> value) async {
    accountSaves++;
    final hold = holdAccountSave;
    holdAccountSave = null;
    if (hold != null) await hold.future;
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
    if (rejectWrite || failSignOutMarker) {
      throw StateError('synthetic key-store failure');
    }
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
  _resumeTargetTests();
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

  String header(RequestOptions request, String name) {
    for (final entry in request.headers.entries) {
      if (entry.key.toLowerCase() == name) return '${entry.value}';
    }
    return '';
  }

  Account accountFor(int id, String token) => Account(
    instance: GitLabInstance.parse('https://example.com'),
    user: GitLabUser(id: id, username: 'user$id', name: 'User $id'),
    token: token,
  );

  test('select does not activate a superseded account after delayed cleanup', () async {
    final hold = Completer<void>();
    final store = MemoryAccountStore()..holdLastActiveWrite = hold;
    final accountA = accountFor(7, 'token-a');
    final accountB = accountFor(8, 'token-b');
    store.accounts = [accountA, accountB];
    final adapter = FakeAdapter((request) {
      final token = header(request, 'private-token');
      final id = token == 'token-b' ? 8 : 7;
      return jsonResponse({
        'id': id,
        'username': 'user$id',
        'name': 'User $id',
      });
    });
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    final pendingA = controller.select(accountA);
    for (var i = 0; i < 20 && store.lastActiveWrites == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(store.lastActiveWrites, 1);
    final pendingB = controller.select(accountB);
    hold.complete();
    await pendingA;
    await pendingB;
    expect(controller.active?.user.id, 8);
    expect(store.lastActive, accountB.key);
    final users = adapter.requests.where(
      (request) => request.uri.path.endsWith('/user'),
    );
    expect(users, hasLength(1));
    expect(header(users.single, 'private-token'), 'token-b');
  });

  test('endSession during select cleanup does not re-arm the first account', () async {
    final hold = Completer<void>();
    final store = MemoryAccountStore()..holdLastActiveWrite = hold;
    final accountA = accountFor(7, 'token-a');
    store.accounts = [accountA];
    final adapter = FakeAdapter(
      (_) => jsonResponse({'id': 7, 'username': 'user7', 'name': 'User 7'}),
    );
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    final pendingA = controller.select(accountA);
    for (var i = 0; i < 20 && store.lastActiveWrites == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(store.lastActiveWrites, 1);
    final ending = controller.endSession();
    hold.complete();
    await pendingA;
    await ending;
    expect(controller.active, isNull);
    expect(store.lastActive, isNull);
    expect(store.signOutPending, isFalse);
    expect(
      adapter.requests.where((request) => request.uri.path.endsWith('/user')),
      isEmpty,
    );
  });

  test('sign-out still deletes the remembered key when the marker write fails', () async {
    final store = MemoryAccountStore();
    final adapter = FakeAdapter(
      (_) => jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'}),
    );
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    await controller.connect('https://example.com', 'synthetic-test-token');
    expect(store.lastActive, isNotNull);
    store.failSignOutMarker = true;
    await controller.endSession();
    expect(controller.active, isNull);
    expect(controller.pendingSignOutCleanup, isTrue);
    expect(controller.message, '無法清除自動登入記錄；請重試登出。');
    expect(store.lastActive, isNull);
    store.failSignOutMarker = false;
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

  test('a stale pre-activation rotation cannot overwrite a newer account list', () async {
    final holdSave = Completer<void>();
    final store = MemoryAccountStore()..holdAccountSave = holdSave;
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
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/oauth/token')) {
        return jsonResponse({
          'access_token': 'rotated-access',
          'refresh_token': 'rotated-refresh',
          'token_type': 'bearer',
          'expires_in': 7200,
        });
      }
      if (header(request, 'private-token') == 'synthetic-pat') {
        return jsonResponse({'id': 9, 'username': 'newer', 'name': 'Newer'});
      }
      if (header(request, 'authorization').contains('rotated-access')) {
        return jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'});
      }
      return jsonResponse({'message': 'expired'}, status: 401);
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
    final pending = controller.initialize();
    for (var i = 0; i < 40 && store.accountSaves == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(store.accountSaves, 1);
    final ending = controller.endSession();
    final connecting = controller.connect(
      'https://example.com',
      'synthetic-pat',
    );
    for (var i = 0; i < 40 && controller.accounts.every((a) => a.user.id != 9); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(controller.accounts.map((account) => account.user.id), contains(9));
    holdSave.complete();
    await pending;
    await ending;
    await connecting;
    expect(store.accounts.map((account) => account.user.id), contains(9));
    expect(controller.accounts.map((account) => account.user.id), contains(9));
    expect(controller.active?.user.id, 9);
  });

  test('a failed rotation save does not restore an account replaced by select', () async {
    final held = await heldActiveRotation();
    await held.controller.select(held.pat);
    expect(held.controller.active?.user.id, 8);
    final activeApi = held.controller.api;
    await settleWrites();
    held.store.rejectWrite = true;
    held.hold.complete();
    await held.refreshing;
    await settleWrites();
    expect(held.controller.active?.user.id, 8);
    expect(identical(held.controller.api, activeApi), isTrue);
    expect(held.controller.accounts.map((a) => a.user.id), containsAll([7, 8]));
    final stored = held.controller.accounts.firstWhere((a) => a.user.id == 7).credential as OAuthCredential;
    expect(stored.accessToken, 'old-access');
  });

  test('a failed rotation save does not restore an account after sign-out', () async {
    final held = await heldActiveRotation();
    await held.controller.endSession();
    expect(held.controller.active, isNull);
    await settleWrites();
    held.store.rejectWrite = true;
    held.hold.complete();
    await held.refreshing;
    await settleWrites();
    expect(held.controller.active, isNull);
    expect(held.controller.api, isNull);
    expect(held.controller.generation, greaterThan(0));
  });

  test('a failed rotation save does not split active from a list replaced by connect', () async {
    final held = await heldActiveRotation();
    final activeApi = held.controller.api;
    // connect stages a newer list (account 8 re-added with a new token) and
    // queues its own save behind the held rotation write.
    final connecting = held.controller.connect('https://example.com', 'synthetic-pat-c');
    bool staged() => held.controller.accounts.any(
      (a) => a.user.id == 8 && a.credential is PatCredential && (a.credential as PatCredential).token == 'synthetic-pat-c',
    );
    for (var i = 0; i < 40 && !staged(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(staged(), isTrue);
    expect(held.store.accountSaves, 1);
    held.store.rejectWrite = true;
    held.hold.complete();
    await held.refreshing;
    await connecting;
    await settleWrites();
    expect(held.controller.active?.user.id, 7);
    expect(identical(held.controller.api, activeApi), isTrue);
    final active = held.controller.active!.credential as OAuthCredential;
    expect(active.accessToken, 'rotated-access');
    final listed = held.controller.accounts.firstWhere((a) => a.user.id == 7).credential as OAuthCredential;
    expect(listed.accessToken, 'rotated-access');
    expect(held.controller.message, isNotNull);
  });

  test('a delayed initialize releases an operation still in flight', () async {
    final store = MemoryAccountStore();
    final saved = accountFor(7, 'synthetic-pat');
    store.accounts = [saved];
    final gate = Completer<ResponseBody>();
    final adapter = FakeAdapter((request) {
      if (header(request, 'private-token') == 'synthetic-pat') return gate.future;
      return jsonResponse({'message': 'nope'}, status: 401);
    });
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.initializing, isFalse);
    final selecting = controller.select(saved);
    for (var i = 0; i < 40 && adapter.requests.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(adapter.requests, hasLength(1));
    expect(controller.busy, isTrue);
    final again = controller.initialize();
    expect(controller.busy, isFalse);
    expect(controller.initializing, isTrue);
    gate.complete(jsonResponse({'id': 7, 'username': 'user7', 'name': 'User 7'}));
    await selecting;
    await again;
    expect(controller.busy, isFalse);
    expect(controller.initializing, isFalse);
    expect(controller.active, isNull);
    expect(controller.api, isNull);
  });
}

Future<void> settleWrites() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

typedef HeldRotation = ({
  SessionController controller,
  MemoryAccountStore store,
  Completer<void> hold,
  Account pat,
  Future<void> refreshing,
});

/// Resumes OAuth account 7, then expires its token so the next request
/// refreshes it; the resulting account-list save is parked behind [hold].
Future<HeldRotation> heldActiveRotation() async {
  final hold = Completer<void>();
  final store = MemoryAccountStore();
  final oauth = Account(
    instance: GitLabInstance.parse('https://example.com'),
    user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
    credential: const OAuthCredential(
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
      clientId: 'synthetic-app-id',
    ),
  );
  final pat = Account(
    instance: GitLabInstance.parse('https://example.com'),
    user: const GitLabUser(id: 8, username: 'user8', name: 'User 8'),
    token: 'synthetic-pat-b',
  );
  store.accounts = [oauth, pat];
  store.lastActive = oauth.key;
  var oldAccessUsers = 0;
  final adapter = FakeAdapter((request) {
    if (request.uri.path.endsWith('/oauth/token')) {
      return jsonResponse({
        'access_token': 'rotated-access',
        'refresh_token': 'rotated-refresh',
        'token_type': 'bearer',
        'expires_in': 7200,
      });
    }
    String header(String name) {
      for (final entry in request.headers.entries) {
        if (entry.key.toLowerCase() == name) return '${entry.value}';
      }
      return '';
    }
    // 'synthetic-pat-c' is the same user connecting again with a new token.
    if (header('private-token') == 'synthetic-pat-b' || header('private-token') == 'synthetic-pat-c') {
      return jsonResponse({'id': 8, 'username': 'user8', 'name': 'User 8'});
    }
    final authorization = header('authorization');
    if (authorization.contains('rotated-access')) {
      return jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'});
    }
    if (authorization.contains('old-access') && ++oldAccessUsers == 1) {
      return jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'});
    }
    return jsonResponse({'message': 'expired'}, status: 401);
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
  store.holdAccountSave = hold;
  final refreshing = controller.api!.currentUser().then((_) {}, onError: (Object _) {});
  for (var i = 0; i < 40 && store.accountSaves == 0; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(store.accountSaves, 1);
  final rotated = controller.active!.credential as OAuthCredential;
  expect(rotated.accessToken, 'rotated-access');
  return (controller: controller, store: store, hold: hold, pat: pat, refreshing: refreshing);
}

void _resumeTargetTests() {
  test('SessionController manages pendingResumeTarget lifecycle', () async {
    final adapter = FakeAdapter((_) => jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'}));
    final store = MemoryAccountStore();
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);

    expect(controller.pendingResumeTarget, isNull);

    const target = ResumeTarget(
      projectId: 12,
      projectPath: 'group/project',
      resource: 'issues',
      iid: 34,
    );
    controller.setPendingResumeTarget(target);
    expect(controller.pendingResumeTarget, target);

    final taken = controller.takeResumeTarget();
    expect(taken, target);
    expect(controller.pendingResumeTarget, isNull);
  });

  test('endSession with switching: true preserves pendingResumeTarget', () async {
    final adapter = FakeAdapter((_) => jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'}));
    final store = MemoryAccountStore();
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.connect('https://example.com/gitlab', 'pat-a');
    expect(controller.active, isNotNull);

    const target = ResumeTarget(
      projectPath: 'group/project',
      resource: 'merge_requests',
      iid: 5,
    );
    controller.setPendingResumeTarget(target);

    await controller.endSession(switching: true);
    expect(controller.active, isNull);
    expect(controller.pendingResumeTarget, target);
  });

  test('endSession without switching clears pendingResumeTarget', () async {
    final adapter = FakeAdapter((_) => jsonResponse({'id': 7, 'username': 'tester', 'name': 'Test'}));
    final store = MemoryAccountStore();
    final controller = controllerFor(store, adapter);
    addTearDown(controller.dispose);

    await controller.initialize();
    await controller.connect('https://example.com/gitlab', 'pat-a');

    const target = ResumeTarget(
      projectPath: 'group/project',
      resource: 'issues',
      iid: 1,
    );
    controller.setPendingResumeTarget(target);

    await controller.endSession(); // switching defaults to false
    expect(controller.active, isNull);
    expect(controller.pendingResumeTarget, isNull);
  });
}
