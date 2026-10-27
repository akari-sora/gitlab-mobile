import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/auth/recent_project.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'session_test.dart' show MemoryAccountStore;

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('SecureRecentProjectStore v2 LRU', () {
    test('round-trips multiple projects maintaining recency order', () async {
      final store = SecureRecentProjectStore();
      const p1 = RecentProject(id: 1, name: 'Alpha', path: 'group/alpha');
      const p2 = RecentProject(id: 2, name: 'Beta', path: 'group/beta');
      const p3 = RecentProject(id: 3, name: 'Gamma', path: 'group/gamma');

      await store.touch('acct-1', p1);
      await store.touch('acct-1', p2);
      await store.touch('acct-1', p3);

      final list = await store.readList('acct-1');
      expect(list.length, 3);
      expect(list[0], p3);
      expect(list[1], p2);
      expect(list[2], p1);

      // read() returns the MRU project
      expect(await store.read('acct-1'), p3);
    });

    test('touching existing project promotes it to index 0 without duplicates', () async {
      final store = SecureRecentProjectStore();
      const p1 = RecentProject(id: 1, name: 'Alpha');
      const p2 = RecentProject(id: 2, name: 'Beta');
      const p3 = RecentProject(id: 3, name: 'Gamma');

      await store.touch('acct-1', p1);
      await store.touch('acct-1', p2);
      await store.touch('acct-1', p3);

      // Touch p1 again with updated path
      const p1Updated = RecentProject(id: 1, name: 'Alpha', path: 'new/alpha');
      await store.touch('acct-1', p1Updated);

      final list = await store.readList('acct-1');
      expect(list.length, 3);
      expect(list[0], p1Updated);
      expect(list[1], p3);
      expect(list[2], p2);
    });

    test('caps at 10 items and evicts oldest', () async {
      final store = SecureRecentProjectStore();
      for (var i = 1; i <= 12; i++) {
        await store.touch('acct-1', RecentProject(id: i, name: 'Project $i'));
      }

      final list = await store.readList('acct-1');
      expect(list.length, 10);
      expect(list.first.id, 12);
      expect(list.last.id, 3);
      expect(list.any((p) => p.id == 1 || p.id == 2), isFalse);
    });

    test('migrates from v1 to v2 and removes v1 key', () async {
      const v1Project = RecentProject(id: 42, name: 'Legacy Project');
      FlutterSecureStorage.setMockInitialValues({
        SecureRecentProjectStore.storageKey('legacy-acct'): v1Project.encode(),
      });

      final store = SecureRecentProjectStore();
      final list = await store.readList('legacy-acct');
      expect(list.length, 1);
      expect(list.first.id, 42);
      expect(list.first.name, 'Legacy Project');

      // Check that v1 key is deleted and v2 key exists
      final v1Raw = await const FlutterSecureStorage().read(
        key: SecureRecentProjectStore.storageKey('legacy-acct'),
      );
      expect(v1Raw, isNull);

      final v2Raw = await const FlutterSecureStorage().read(
        key: SecureRecentProjectStore.v2StorageKey('legacy-acct'),
      );
      expect(v2Raw, isNotNull);
      final decoded = jsonDecode(v2Raw!);
      expect(decoded['version'], 2);
    });

    test('clear removes both v1 and v2 records', () async {
      final store = SecureRecentProjectStore();
      await store.touch('acct-1', const RecentProject(id: 1, name: 'One'));

      expect((await store.readList('acct-1')).isNotEmpty, isTrue);

      await store.clear('acct-1');

      expect((await store.readList('acct-1')).isEmpty, isTrue);
      expect(await store.read('acct-1'), isNull);
    });

    test('clear wins over in-flight touches', () async {
      final store = SecureRecentProjectStore();
      final firstTouch = store.touch('acct-1', const RecentProject(id: 1, name: 'One'));
      final clearFuture = store.clear('acct-1');
      final secondTouch = store.touch('acct-1', const RecentProject(id: 2, name: 'Two'));

      await Future.wait([firstTouch, clearFuture, secondTouch]);

      final list = await store.readList('acct-1');
      // Second touch was queued after clear, so it can persist, but firstTouch before clear must be wiped
      expect(list.any((p) => p.id == 1), isFalse);
    });

    test('handles corrupted v2 storage by returning empty without crashing', () async {
      FlutterSecureStorage.setMockInitialValues({
        SecureRecentProjectStore.v2StorageKey('corrupt-acct'): '{ not valid json',
      });

      final store = SecureRecentProjectStore();
      final list = await store.readList('corrupt-acct');
      expect(list, isEmpty);
    });

    test('isolates different accounts', () async {
      final store = SecureRecentProjectStore();
      await store.touch('user1@instance1', const RecentProject(id: 10, name: 'P10'));
      await store.touch('user1@instance2', const RecentProject(id: 20, name: 'P20'));

      final list1 = await store.readList('user1@instance1');
      final list2 = await store.readList('user1@instance2');

      expect(list1.map((p) => p.id), [10]);
      expect(list2.map((p) => p.id), [20]);
    });
  });

  group('RecentProjectsController', () {
    test('loads and tracks items bound to session generation', () async {
      final accountStore = MemoryAccountStore();
      final session = SessionController(accountStore, readCache: accountStore.readCache);
      final projectStore = SecureRecentProjectStore();
      final controller = RecentProjectsController(store: projectStore, session: session);

      // Signed out: items empty
      await controller.load();
      expect(controller.items, isEmpty);

      // Sign in account A
      final accountA = Account(
        instance: GitLabInstance.parse('https://example.com'),
        user: const GitLabUser(id: 1, username: 'alice', name: 'Alice'),
        token: 'tokenA',
      );
      session.active = accountA;
      session.generation = 1;

      final project = Project.fromJson({
        'id': 100,
        'name': 'Project Alpha',
        'path': 'alpha',
        'path_with_namespace': 'alice/alpha',
        'default_branch': 'main',
        'visibility': 'private',
      });

      await controller.remember(project);
      expect(controller.items.length, 1);
      expect(controller.items.first.id, 100);

      // Switch to account B
      final accountB = Account(
        instance: GitLabInstance.parse('https://example.com'),
        user: const GitLabUser(id: 2, username: 'bob', name: 'Bob'),
        token: 'tokenB',
      );
      session.active = accountB;
      session.generation = 2;

      controller.clearVisible();
      expect(controller.items, isEmpty);

      await controller.load();
      expect(controller.items, isEmpty); // Bob has no recent projects yet
    });
  });
}
