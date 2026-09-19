import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/features/projects/repository_controller.dart';
import 'support/fake_adapter.dart';

Map<String, Object> entry(String path, {String type = 'blob'}) => {
  'name': path.split('/').last, 'path': path, 'type': type,
};

void main() {
  final sha = 'a' * 40;
  FakeAdapter fixture(Responder tree, {String? branch = 'main'}) => FakeAdapter((request) {
    if (request.uri.path.endsWith('/projects/8')) return jsonResponse(projectJson(8, branch: branch));
    if (request.uri.path.contains('/repository/branches/')) return jsonResponse({'commit': {'id': sha}});
    return tree(request);
  });

  RepositoryController create(FakeAdapter adapter) {
    final api = testApi(adapter);
    final controller = RepositoryController(api, '8');
    addTearDown(api.close); addTearDown(controller.dispose);
    return controller;
  }

  test('initial project, branch and tree stay on the resolved SHA', () async {
    final adapter = fixture((_) => jsonResponse([entry('README.md')]));
    final controller = create(adapter);
    await controller.initialize();
    expect(controller.project?.id, 8);
    expect(controller.sha, sha);
    expect(controller.entries.single.path, 'README.md');
    expect(adapter.requests.last.uri.queryParameters['ref'], sha);
    expect(controller.loading, isFalse);
    expect(controller.error, isNull);
  });

  for (final branch in [null, '']) {
    test('empty default branch ($branch) is an empty repo, not authentication failure', () async {
      final adapter = fixture((_) => throw StateError('Must not fetch tree'), branch: branch);
      final controller = create(adapter);
      await controller.initialize();
      expect(controller.isEmptyRepository, isTrue);
      expect(controller.sha, isNull);
      expect(controller.error, isNull);
      expect(adapter.requests.length, 1);
    });
  }

  test('refresh failure retains current rows, cursor and timestamp', () async {
    var failing = false;
    final adapter = fixture((_) => failing ? jsonResponse({}, status: 503)
      : jsonResponse([entry('README.md')], headers: {'x-next-page': ['2']}));
    final controller = create(adapter);
    await controller.initialize();
    final timestamp = controller.fetchedAt;
    final cursor = controller.next;
    failing = true;
    await controller.refresh();
    expect(controller.entries.single.path, 'README.md');
    expect(controller.next, cursor);
    expect(controller.fetchedAt, timestamp);
    expect(controller.error?.kind, FailureKind.server);
    expect(controller.pageError, isNull);
  });

  test('page two failure is local and does not clear first page', () async {
    final adapter = fixture((request) => request.uri.queryParameters['page'] == '2'
      ? jsonResponse({}, status: 503)
      : jsonResponse([entry('README.md')], headers: {'x-next-page': ['2']}));
    final controller = create(adapter);
    await controller.initialize(); await controller.loadMore();
    expect(controller.entries.single.path, 'README.md');
    expect(controller.error, isNull);
    expect(controller.pageError?.kind, FailureKind.server);
    expect(controller.next?.queryParameters['page'], '2');
    expect(controller.loadingMore, isFalse);
  });

  test('page two retry deduplicates by path and clears page error', () async {
    var failPage = true;
    final adapter = fixture((request) {
      if (request.uri.queryParameters['page'] == '2') {
        return failPage ? jsonResponse({}, status: 503)
          : jsonResponse([entry('README.md'), entry('lib/main.dart')]);
      }
      return jsonResponse([entry('README.md')], headers: {'x-next-page': ['2']});
    });
    final controller = create(adapter);
    await controller.initialize(); await controller.loadMore();
    failPage = false; await controller.loadMore();
    expect(controller.entries.map((item) => item.path), ['README.md', 'lib/main.dart']);
    expect(controller.pageError, isNull);
    expect(controller.next, isNull);
  });

  test('successful empty directory is different from 404', () async {
    final adapter = fixture((request) => request.uri.queryParameters['path'] == 'missing'
      ? jsonResponse({}, status: 404) : jsonResponse([]));
    final controller = create(adapter);
    await controller.initialize();
    expect(controller.entries, isEmpty); expect(controller.error, isNull);
    await controller.openDirectory('missing');
    expect(controller.error?.kind, FailureKind.invisible);
    expect(controller.entries, isEmpty);
  });

  test('returning to a visited directory restores rows and cursor without refetch', () async {
    final adapter = fixture((request) => request.uri.queryParameters['path'] == 'lib'
      ? jsonResponse([entry('lib/main.dart')])
      : jsonResponse([entry('lib', type: 'tree')], headers: {'x-next-page': ['2']}));
    final controller = create(adapter);
    await controller.initialize();
    final cursor = controller.next;
    final timestamp = controller.fetchedAt;
    await controller.openDirectory('lib');
    final count = adapter.requests.length;
    await controller.openDirectory('');
    expect(adapter.requests.length, count);
    expect(controller.entries.single.path, 'lib');
    expect(controller.next, cursor);
    expect(controller.fetchedAt, timestamp);
    expect(controller.path, '');
  });

  test('slower directory request never overwrites a newer directory', () async {
    final delayed = Completer<ResponseBody>();
    final adapter = fixture((request) => request.uri.queryParameters['path'] == 'slow'
      ? delayed.future : jsonResponse([entry('fast/result.txt')]));
    final controller = create(adapter);
    await controller.initialize();
    final old = controller.openDirectory('slow');
    await Future<void>.delayed(Duration.zero);
    await controller.openDirectory('fast');
    delayed.complete(jsonResponse([entry('slow/stale.txt')]));
    await old;
    expect(controller.path, 'fast');
    expect(controller.entries.single.path, 'fast/result.txt');
  });

  test('late page two response cannot append into another directory', () async {
    final delayed = Completer<ResponseBody>();
    final adapter = fixture((request) {
      if (request.uri.queryParameters['page'] == '2') return delayed.future;
      if (request.uri.queryParameters['path'] == 'lib') return jsonResponse([entry('lib/current.dart')]);
      return jsonResponse([entry('README.md')], headers: {'x-next-page': ['2']});
    });
    final controller = create(adapter);
    await controller.initialize();
    final old = controller.loadMore();
    await Future<void>.delayed(Duration.zero);
    await controller.openDirectory('lib');
    delayed.complete(jsonResponse([entry('stale.md')])); await old;
    expect(controller.path, 'lib');
    expect(controller.entries.single.path, 'lib/current.dart');
  });

  test('reinitialize clears old directory snapshots', () async {
    var directoryReads = 0;
    final adapter = fixture((request) {
      if (request.uri.queryParameters['path'] == 'lib') directoryReads++;
      return jsonResponse([]);
    });
    final controller = create(adapter);
    await controller.initialize(); await controller.openDirectory('lib');
    await controller.openDirectory('');
    expect(directoryReads, 1);
    await controller.initialize(); await controller.openDirectory('lib');
    expect(directoryReads, 2);
  });

  test('dispose makes a late response inert', () async {
    final delayed = Completer<ResponseBody>();
    final adapter = fixture((_) => delayed.future);
    final api = testApi(adapter); addTearDown(api.close);
    final controller = RepositoryController(api, '8');
    var notifications = 0;
    controller.addListener(() => notifications++);
    final operation = controller.initialize();
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    final before = notifications;
    delayed.complete(jsonResponse([entry('late.txt')])); await operation;
    expect(notifications, before);
    expect(controller.entries, isEmpty);
  });
}
