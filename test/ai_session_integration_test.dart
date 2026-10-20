import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/auth/account_store.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

final class _DelayedAccountStore implements AccountStore {
  final List<Completer<List<Account>>> loads = [];

  @override
  Future<List<Account>> load() {
    final load = Completer<List<Account>>();
    loads.add(load);
    return load.future;
  }

  @override
  Future<String?> loadLastActive() async => null;

  @override
  Future<bool> loadSignOutPending() async => false;

  @override
  Future<void> save(List<Account> accounts) async {}

  @override
  Future<void> saveLastActive(String? key) async {}

  @override
  Future<void> saveSignOutPending(bool pending) async {}
}

void main() {
  test(
    'accountsLoaded becomes true only after the current load succeeds',
    () async {
      final store = _DelayedAccountStore();
      final session = SessionController(store);
      addTearDown(session.dispose);

      expect(session.accountsLoaded, isFalse);
      final first = session.initialize();
      expect(session.accountsLoaded, isFalse);

      store.loads.single.complete(const []);
      await first;
      expect(session.accountsLoaded, isTrue);

      final second = session.initialize();
      expect(session.accountsLoaded, isFalse);
      store.loads[1].complete(const []);
      await second;
      expect(session.accountsLoaded, isTrue);
    },
  );

  test('failed account load leaves accountsLoaded false', () async {
    final store = _DelayedAccountStore();
    final session = SessionController(store);
    addTearDown(session.dispose);

    final initialization = session.initialize();
    store.loads.single.completeError(StateError('synthetic load failure'));
    await initialization;

    expect(session.accountsLoaded, isFalse);
  });

  test('a stale successful load cannot set accountsLoaded', () async {
    final store = _DelayedAccountStore();
    final session = SessionController(store);
    addTearDown(session.dispose);

    final stale = session.initialize();
    final current = session.initialize();
    store.loads.first.complete(const []);
    await stale;
    expect(session.accountsLoaded, isFalse);

    store.loads[1].complete(const []);
    await current;
    expect(session.accountsLoaded, isTrue);
  });
}
