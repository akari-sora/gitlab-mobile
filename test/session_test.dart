import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/auth/account_store.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'support/fake_adapter.dart';

class MemoryAccountStore implements AccountStore {
  List<Account> accounts = [];
  bool rejectWrite = false;
  @override
  Future<List<Account>> load() async => accounts;
  @override
  Future<void> save(List<Account> value) async {
    if (rejectWrite) throw StateError('synthetic key-store failure');
    accounts = List.of(value);
  }
}

SessionController controllerFor(MemoryAccountStore store, FakeAdapter adapter) => SessionController(
  store, createApi: (instance, token) => GitLabApi(instance: instance, token: token,
    dio: Dio()..httpClientAdapter = adapter));

void main() {
  test('activates only after /user and secure-store success', () async {
    final store = MemoryAccountStore();
    final adapter = FakeAdapter((_) => jsonResponse({'id': 7, 'username': 'tester'}));
    final controller = controllerFor(store, adapter); addTearDown(controller.dispose);
    await controller.initialize();
    await controller.connect('https://example.com', 'synthetic-test-token');
    expect(controller.active?.user.id, 7); expect(store.accounts.single.user.id, 7);
  });
  test('secure-store failure never activates a session', () async {
    final store = MemoryAccountStore()..rejectWrite = true;
    final adapter = FakeAdapter((_) => jsonResponse({'id': 7, 'username': 'tester'}));
    final controller = controllerFor(store, adapter); addTearDown(controller.dispose);
    await controller.initialize(); await controller.connect('https://example.com', 'synthetic-test-token');
    expect(controller.active, isNull); expect(store.accounts, isEmpty);
  });
  test('saved token that resolves to different numeric user is rejected', () async {
    final store = MemoryAccountStore();
    final saved = Account(instance: GitLabInstance.parse('https://example.com'),
      user: const GitLabUser(id: 7, username: 'tester', name: 'Test'), token: 'synthetic-test-token');
    store.accounts = [saved];
    final adapter = FakeAdapter((_) => jsonResponse({'id': 8, 'username': 'other'}));
    final controller = controllerFor(store, adapter); addTearDown(controller.dispose);
    await controller.initialize(); await controller.select(saved);
    expect(controller.active, isNull); expect(controller.message, isNotNull);
  });
  test('connect 401 does not use expired-session copy', () async {
    final store = MemoryAccountStore();
    final adapter = FakeAdapter((_) => jsonResponse({'message': 'unauthorized'}, status: 401));
    final controller = controllerFor(store, adapter); addTearDown(controller.dispose);
    await controller.initialize();
    await controller.connect('https://example.com', 'synthetic-test-token');
    expect(controller.active, isNull);
    expect(controller.message, isNot(contains('登入已失效')));
    expect(controller.message, contains('無法驗證這個 Token'));
  });
  test('select 401 keeps expired-session copy and does not drop the saved account', () async {
    final store = MemoryAccountStore();
    final saved = Account(instance: GitLabInstance.parse('https://example.com'),
      user: const GitLabUser(id: 7, username: 'tester', name: 'Test'), token: 'synthetic-test-token');
    store.accounts = [saved];
    final adapter = FakeAdapter((_) => jsonResponse({'message': 'unauthorized'}, status: 401));
    final controller = controllerFor(store, adapter); addTearDown(controller.dispose);
    await controller.initialize(); await controller.select(saved);
    expect(controller.active, isNull);
    expect(controller.message, contains('登入已失效'));
    expect(store.accounts, hasLength(1));
  });
  test('remove clears the store and does not activate another account', () async {
    final store = MemoryAccountStore();
    final saved = Account(instance: GitLabInstance.parse('https://example.com'),
      user: const GitLabUser(id: 7, username: 'tester', name: 'Test'), token: 'synthetic-test-token');
    store.accounts = [saved];
    final adapter = FakeAdapter((_) => jsonResponse({'id': 7, 'username': 'tester'}));
    final controller = controllerFor(store, adapter); addTearDown(controller.dispose);
    await controller.initialize();
    await controller.remove(saved);
    expect(store.accounts, isEmpty);
    expect(controller.active, isNull);
  });
  test('ending session while sign-in is pending cannot later reactivate it', () async {
    final deferred = Completer<ResponseBody>();
    final store = MemoryAccountStore();
    final adapter = FakeAdapter((_) => deferred.future);
    final controller = controllerFor(store, adapter); addTearDown(controller.dispose);
    await controller.initialize();
    final connect = controller.connect('https://example.com', 'synthetic-test-token');
    await Future<void>.delayed(Duration.zero);
    controller.endSession();
    deferred.complete(jsonResponse({'id': 7, 'username': 'tester'})); await connect;
    expect(controller.active, isNull); expect(store.accounts, isEmpty);
  });
}
