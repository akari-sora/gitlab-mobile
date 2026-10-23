import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';

import 'support/fake_adapter.dart';

const _deadline = Duration(seconds: 20);

void main() {
  test(
    'public marker saturation keeps warmed user and group lists reusable',
    () async {
      var seedCalls = 0;
      var laterCalls = 0;
      var userListCalls = 0;
      var groupListCalls = 0;
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        final batch = request.uri.queryParameters['batch'];
        if (path.endsWith('/projects/8/issues') && batch == 'seed') {
          seedCalls++;
          return jsonResponse([
            for (var iid = 1; iid <= 4096; iid++) _issue(iid),
          ]);
        }
        if (path.endsWith('/projects/8/issues') && batch == 'later') {
          laterCalls++;
          return jsonResponse([
            for (var iid = 4097; iid <= 4128; iid++) _issue(iid),
          ]);
        }
        if (path.endsWith('/groups/3/issues')) {
          groupListCalls++;
          return jsonResponse([_issue(7001)]);
        }
        if (path.endsWith('/issues')) {
          userListCalls++;
          return jsonResponse([_issue(7002)]);
        }
        throw StateError(
          'Unexpected request: ${request.method} ${request.uri}',
        );
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      await api
          .records(
            ['projects', '8', 'issues'],
            query: const {'batch': 'seed', 'per_page': '4096'},
          )
          .timeout(_deadline);
      await api.cachedRecords(['issues']).timeout(_deadline);
      await api.cachedRecords(['groups', '3', 'issues']).timeout(_deadline);
      await api.cachedRecords(['issues']).timeout(_deadline);
      await api.cachedRecords(['groups', '3', 'issues']).timeout(_deadline);

      await api
          .records(
            ['projects', '8', 'issues'],
            query: const {'batch': 'later', 'per_page': '32'},
          )
          .timeout(_deadline);

      final user = await api.cachedRecords(['issues']).timeout(_deadline);
      final group = await api
          .cachedRecords(['groups', '3', 'issues'])
          .timeout(_deadline);

      expect(user.lineage, CacheLineage.memory);
      expect(group.lineage, CacheLineage.memory);
      expect(seedCalls, 1);
      expect(laterCalls, 1);
      expect(userListCalls, 1);
      expect(groupListCalls, 1);
    },
  );

  test(
    'evicted public marker turning confidential revokes pending subtree and lists',
    () async {
      final notesGate = Completer<ResponseBody>();
      final userListGate = Completer<ResponseBody>();
      final groupListGate = Completer<ResponseBody>();
      var holdRequests = false;
      var confidential = false;
      var noteCalls = 0;
      var userListCalls = 0;
      var groupListCalls = 0;
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/8/issues/1/notes')) {
          noteCalls++;
          return holdRequests
              ? notesGate.future
              : jsonResponse([
                  {'id': 1, 'body': 'public note'},
                ]);
        }
        if (path.endsWith('/groups/3/issues')) {
          groupListCalls++;
          return holdRequests && groupListCalls == 1
              ? groupListGate.future
              : jsonResponse([_issue(1, confidential: confidential)]);
        }
        if (path.endsWith('/issues') && !path.endsWith('/projects/8/issues')) {
          userListCalls++;
          return holdRequests && userListCalls == 1
              ? userListGate.future
              : jsonResponse([_issue(1, confidential: confidential)]);
        }
        if (path.endsWith('/projects/8/issues/1')) {
          return jsonResponse(_issue(1, confidential: confidential));
        }
        if (path.endsWith('/projects/8/issues')) {
          final start = int.parse(request.uri.queryParameters['start']!);
          final count = int.parse(request.uri.queryParameters['count']!);
          return jsonResponse([
            for (var offset = 0; offset < count; offset++)
              _issue(start + offset),
          ]);
        }
        throw StateError(
          'Unexpected request: ${request.method} ${request.uri}',
        );
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      await api.record(['projects', '8', 'issues', '1']).timeout(_deadline);
      await api
          .records(
            ['projects', '8', 'issues'],
            query: const {'start': '2', 'count': '4095'},
          )
          .timeout(_deadline);
      await api
          .records(
            ['projects', '8', 'issues'],
            query: const {'start': '4097', 'count': '32'},
          )
          .timeout(_deadline);

      holdRequests = true;
      final notes = api.cachedRecords([
        'projects',
        '8',
        'issues',
        '1',
        'notes',
      ]);
      final userList = api.cachedRecords(['issues']);
      final groupList = api.cachedRecords(['groups', '3', 'issues']);
      final notesOutcome = _outcome(notes);
      final userOutcome = _outcome(userList);
      final groupOutcome = _outcome(groupList);
      await _until(
        () => noteCalls == 1 && userListCalls == 1 && groupListCalls == 1,
      );

      confidential = true;
      final privateIssue = await api
          .record(['projects', '8', 'issues', '1'])
          .timeout(_deadline);
      expect(privateIssue['confidential'], isTrue);

      notesGate.complete(
        jsonResponse([
          {'id': 2, 'body': 'must not publish'},
        ]),
      );
      userListGate.complete(jsonResponse([_issue(1)]));
      groupListGate.complete(jsonResponse([_issue(1)]));

      expect(
        await notesOutcome.timeout(_deadline),
        isA<ApiFailure>().having(
          (failure) => failure.kind,
          'kind',
          FailureKind.cancelled,
        ),
      );
      final user = await userOutcome.timeout(_deadline);
      final group = await groupOutcome.timeout(_deadline);
      expect(user, isA<CachedRead<ApiPage<Json>>>());
      expect(group, isA<CachedRead<ApiPage<Json>>>());
      expect(
        (user as CachedRead<ApiPage<Json>>).value.items.single['confidential'],
        isTrue,
      );
      expect(
        (group as CachedRead<ApiPage<Json>>).value.items.single['confidential'],
        isTrue,
      );
      expect(userListCalls, 2);
      expect(groupListCalls, 2);
    },
  );

  for (final page in [false, true]) {
    test(
      'uncached full-path ${page ? 'list' : 'detail'} observes privacy',
      () async {
        var confidential = false;
        var noteCalls = 0, userCalls = 0, groupCalls = 0;
        final adapter = FakeAdapter((request) {
          final path = request.uri.path;
          if (request.uri.pathSegments.contains('team/example-8')) {
            return jsonResponse(
              page
                  ? [_issue(1, confidential: confidential)]
                  : _issue(1, confidential: confidential),
            );
          }
          if (path.endsWith('/notes')) {
            noteCalls++;
            return jsonResponse([
              {'id': 1, 'body': 'note $noteCalls'},
            ]);
          }
          if (path.endsWith('/groups/3/issues')) {
            groupCalls++;
            return jsonResponse([_issue(1, confidential: confidential)]);
          }
          if (path.endsWith('/issues')) {
            userCalls++;
            return jsonResponse([_issue(1, confidential: confidential)]);
          }
          return jsonResponse(_issue(1, confidential: confidential));
        });
        final api = _boundApi(adapter);
        addTearDown(api.close);
        await api.record(['projects', '8', 'issues', '1']).timeout(_deadline);
        final scopes = [
          ['projects', '8', 'issues', '1', 'notes'],
          ['issues'],
          ['groups', '3', 'issues'],
        ];
        for (final path in scopes) {
          await api.cachedRecords(path).timeout(_deadline);
        }
        confidential = true;
        if (page) {
          final result = await api
              .cachedRecords(['projects', 'team/example-8', 'issues'])
              .timeout(_deadline);
          expect(result.value.items.single['confidential'], isTrue);
          expect(result.lineage, CacheLineage.network);
        } else {
          final result = await api
              .cachedRecord(['projects', 'team/example-8', 'issues', '1'])
              .timeout(_deadline);
          expect(result.value['confidential'], isTrue);
          expect(result.lineage, CacheLineage.network);
        }
        for (final path in scopes) {
          final refreshed = await api.cachedRecords(path).timeout(_deadline);
          expect(refreshed.lineage, CacheLineage.network);
          expect(
            (await api.cachedRecords(path).timeout(_deadline)).lineage,
            CacheLineage.memory,
          );
        }
        expect([noteCalls, userCalls, groupCalls], [2, 2, 2]);
      },
    );
  }

  test('retained public marker turning confidential still revokes', () async {
    final notesGate = Completer<ResponseBody>();
    var confidential = false;
    var noteCalls = 0;
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/projects/8/issues/1/notes')) {
        noteCalls++;
        return notesGate.future;
      }
      if (request.uri.path.endsWith('/projects/8/issues/1')) {
        return jsonResponse(_issue(1, confidential: confidential));
      }
      throw StateError('Unexpected request: ${request.method} ${request.uri}');
    });
    final api = _boundApi(adapter);
    addTearDown(api.close);

    await api.record(['projects', '8', 'issues', '1']).timeout(_deadline);
    final notes = api.cachedRecords(['projects', '8', 'issues', '1', 'notes']);
    final outcome = _outcome(notes);
    await _until(() => noteCalls == 1);

    confidential = true;
    await api.record(['projects', '8', 'issues', '1']).timeout(_deadline);
    notesGate.complete(
      jsonResponse([
        {'id': 2, 'body': 'must not publish'},
      ]),
    );

    expect(
      await outcome.timeout(_deadline),
      isA<ApiFailure>().having(
        (failure) => failure.kind,
        'kind',
        FailureKind.cancelled,
      ),
    );
  });

  test(
    'terminal cache clear removes the deferred privacy uncertainty',
    () async {
      final notesGate = Completer<ResponseBody>();
      var holdNotes = false;
      var confidential = false;
      var noteCalls = 0;
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/8/issues/1/notes')) {
          noteCalls++;
          return holdNotes
              ? notesGate.future
              : jsonResponse([
                  {'id': 1, 'body': 'public note'},
                ]);
        }
        if (path.endsWith('/projects/8/issues/1')) {
          return jsonResponse(_issue(1, confidential: confidential));
        }
        if (path.endsWith('/projects/8/issues')) {
          final start = int.parse(request.uri.queryParameters['start']!);
          final count = int.parse(request.uri.queryParameters['count']!);
          return jsonResponse([
            for (var offset = 0; offset < count; offset++)
              _issue(start + offset),
          ]);
        }
        throw StateError(
          'Unexpected request: ${request.method} ${request.uri}',
        );
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      await api.record(['projects', '8', 'issues', '1']).timeout(_deadline);
      await api
          .records(
            ['projects', '8', 'issues'],
            query: const {'start': '2', 'count': '4096'},
          )
          .timeout(_deadline);
      api.clearReadCache();

      holdNotes = true;
      final notes = api.cachedRecords([
        'projects',
        '8',
        'issues',
        '1',
        'notes',
      ]);
      final outcome = _outcome(notes);
      await _until(() => noteCalls == 1);

      confidential = true;
      await api.record(['projects', '8', 'issues', '1']).timeout(_deadline);
      notesGate.complete(
        jsonResponse([
          {'id': 2, 'body': 'current private note'},
        ]),
      );

      final result = await outcome.timeout(_deadline);
      expect(result, isA<CachedRead<ApiPage<Json>>>());
      expect(
        (result as CachedRead<ApiPage<Json>>).value.items.single['body'],
        'current private note',
      );
    },
  );
}

Map<String, Object?> _issue(int iid, {bool confidential = false}) => {
  'id': iid + 100000,
  'project_id': 8,
  'iid': iid,
  'title': 'Issue $iid',
  'confidential': confidential,
};

GitLabApi _boundApi(FakeAdapter adapter) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-test-token',
    dio: Dio()..httpClientAdapter = adapter,
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}

Future<Object> _outcome(Future<Object> future) =>
    future.then<Object>((value) => value, onError: (Object error) => error);

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(_deadline);
  while (!done()) {
    if (!DateTime.now().isBefore(deadline)) {
      throw TimeoutException('condition', _deadline);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
