import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'support/fake_adapter.dart';

const _deadline = Duration(seconds: 20);
const _issuePath = ['projects', '8', 'issues', '1'];
const _notesPath = ['projects', '8', 'issues', '1', 'notes'];
const _workItemId = 'gid://gitlab/WorkItem/101';
const _workItemTypeId = 'gid://gitlab/WorkItems::Type/9';
const _projectId = 'gid://gitlab/Project/8';
const _namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/8';
const _projectPath = 'team/example-8';
final _workItemUpdatedAt = DateTime.utc(2026, 10, 23, 9);

void main() {
  test(
    'newly confidential direct issue revokes old subtree reads and list snapshots',
    () async {
      final oldIssue = Completer<ResponseBody>();
      final oldNotes = Completer<ResponseBody>();
      var issueCalls = 0;
      var noteCalls = 0;
      var userListCalls = 0;
      var groupListCalls = 0;
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/8/issues/1')) {
          issueCalls++;
          if (issueCalls == 1) return oldIssue.future;
          return jsonResponse(_issue(confidential: true, title: 'private'));
        }
        if (path.endsWith('/projects/8/issues/1/notes')) {
          noteCalls++;
          if (noteCalls == 1) return oldNotes.future;
          return jsonResponse([
            {'id': 2, 'body': 'new note'},
          ]);
        }
        if (path.endsWith('/issues')) {
          if (path.endsWith('/groups/3/issues')) {
            groupListCalls++;
          } else {
            userListCalls++;
          }
          return jsonResponse([
            _issue(
              confidential: issueCalls > 1,
              title: issueCalls > 1 ? 'private' : 'public',
            ),
          ]);
        }
        throw StateError('Unexpected request: ${request.method} $path');
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      await api.cachedRecords(['issues']);
      await api.cachedRecords(['groups', '3', 'issues']);
      await api.cachedRecords(['issues']);
      await api.cachedRecords(['groups', '3', 'issues']);
      expect(userListCalls, 1);
      expect(groupListCalls, 1);

      final pendingIssue = api.cachedRecord(_issuePath);
      final pendingNotes = api.cachedRecords(_notesPath);
      await _until(() => issueCalls == 1 && noteCalls == 1);

      final current = await api.record(_issuePath).timeout(_deadline);
      expect(current['confidential'], isTrue);
      expect(current['title'], 'private');

      final issueRejected = expectLater(
        pendingIssue,
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      final notesRejected = expectLater(
        pendingNotes,
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      oldIssue.complete(jsonResponse(_issue(title: 'old issue')));
      oldNotes.complete(
        jsonResponse([
          {'id': 1, 'body': 'old note'},
        ]),
      );
      await Future.wait([issueRejected, notesRejected]).timeout(_deadline);

      expect(
        (await api.cachedRecords(['issues'])).value.items.single['title'],
        'private',
      );
      expect(
        (await api.cachedRecords([
          'groups',
          '3',
          'issues',
        ])).value.items.single['title'],
        'private',
      );
      expect(userListCalls, 2);
      expect(groupListCalls, 2);
    },
  );

  test('confidential cached issue remains displayable and reusable', () async {
    var calls = 0;
    final adapter = FakeAdapter((_) {
      calls++;
      return jsonResponse(_issue(confidential: true, title: 'private'));
    });
    final api = _boundApi(adapter);
    addTearDown(api.close);

    final first = await api.cachedRecord(_issuePath).timeout(_deadline);
    final second = await api.cachedRecord(_issuePath).timeout(_deadline);

    expect(first.value['confidential'], isTrue);
    expect(first.superseded, isFalse);
    expect(second.value['title'], 'private');
    expect(second.lineage, CacheLineage.memory);
    expect(calls, 1);
  });

  test(
    'first confidential observation keeps held notes and the public read epoch',
    () async {
      final heldNotes = Completer<ResponseBody>();
      var noteCalls = 0;
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/api/graphql')) {
          return jsonResponse(_workItemLabelsEnvelope());
        }
        if (path.endsWith('/projects/8/issues/1/notes')) {
          noteCalls++;
          return heldNotes.future;
        }
        if (path.endsWith('/projects/8/issues/1')) {
          return jsonResponse(_issue(confidential: true, title: 'private'));
        }
        throw StateError('Unexpected request: ${request.method} $path');
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);

      final before = await _readEpoch(api).timeout(_deadline);
      final notes = api.cachedRecords(_notesPath);
      final notesOutcome = notes.then<Object>(
        (value) => value,
        onError: (Object error) => error,
      );
      await _until(() => noteCalls == 1);

      final issue = await api.record(_issuePath).timeout(_deadline);
      expect(issue['confidential'], isTrue);
      heldNotes.complete(
        jsonResponse([
          {'id': 1, 'body': 'held note'},
        ]),
      );
      final outcome = await notesOutcome.timeout(_deadline);
      final after = await _readEpoch(api).timeout(_deadline);

      expect(after, before);
      expect(outcome, isA<CachedRead<ApiPage<Json>>>());
      expect(
        (outcome as CachedRead<ApiPage<Json>>).value.items.single['body'],
        'held note',
      );
      expect(noteCalls, 1);
    },
  );

  test('concurrent first-confidential lists do not retry', () async {
    final gates = List.generate(3, (_) => Completer<ResponseBody>());
    final calls = <String, int>{};
    final adapter = FakeAdapter((request) {
      final scope = request.uri.queryParameters['scope'];
      if (!request.uri.path.endsWith('/issues') || scope == null) {
        throw StateError(
          'Unexpected request: ${request.method} ${request.uri}',
        );
      }
      final count = calls.update(
        scope,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      if (count == 1) return gates[int.parse(scope.substring(1))].future;
      return jsonResponse([_issue(confidential: true, title: scope)]);
    });
    final api = _boundApi(adapter);
    addTearDown(api.close);

    final reads = [
      for (var index = 0; index < 3; index++)
        api.cachedRecords(['issues'], query: {'scope': 's$index'}),
    ];
    await _until(() => calls.values.fold(0, (sum, value) => sum + value) == 3);

    gates[0].complete(jsonResponse([_issue(confidential: true, title: 's0')]));
    await reads[0].timeout(_deadline);
    for (var index = 1; index < gates.length; index++) {
      gates[index].complete(
        jsonResponse([_issue(confidential: true, title: 's$index')]),
      );
    }
    final results = await Future.wait(reads).timeout(_deadline);

    expect(results.map((read) => read.value.items.single['confidential']), [
      true,
      true,
      true,
    ]);
    expect(calls, {'s0': 1, 's1': 1, 's2': 1});
  });

  test(
    'disk public then confidential is a real flip that revokes held notes',
    () async {
      final heldNotes = Completer<ResponseBody>();
      var noteCalls = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/api/graphql')) {
          return jsonResponse(_workItemLabelsEnvelope());
        }
        if (request.uri.path.endsWith('/projects/8/issues/1/notes')) {
          noteCalls++;
          return heldNotes.future;
        }
        if (request.uri.path.endsWith('/groups/3/issues')) {
          return jsonResponse([
            _issue(confidential: true, title: 'private network'),
          ]);
        }
        throw StateError(
          'Unexpected request: ${request.method} ${request.uri}',
        );
      });
      final now = DateTime.utc(2026, 10, 23, 10);
      final api = _boundApi(
        adapter,
        source: (uri, _) async {
          if (uri.path.endsWith('/issues')) {
            final confidential = uri.path.endsWith('/groups/3/issues');
            return CacheDiskEntry(
              value: ApiPage<Json>([
                _issue(
                  confidential: confidential,
                  title: confidential ? 'private disk' : 'public disk',
                ),
              ]),
              fetchedAt: now,
              responseBytes: 64,
            );
          }
          return null;
        },
        clock: () => now,
      );
      addTearDown(api.close);

      final before = await _readEpoch(api).timeout(_deadline);
      final public = await api.cachedRecords(['issues']).timeout(_deadline);
      expect(public.lineage, CacheLineage.disk);
      expect(public.value.items.single['confidential'], isFalse);

      final notes = api.cachedRecords(_notesPath);
      final notesOutcome = notes.then<Object>(
        (value) => value,
        onError: (Object error) => error,
      );
      await _until(() => noteCalls == 1);

      final confidential = await api
          .cachedRecords(['groups', '3', 'issues'])
          .timeout(_deadline);
      expect(confidential.lineage, CacheLineage.network);
      expect(confidential.value.items.single['confidential'], isTrue);
      heldNotes.complete(
        jsonResponse([
          {'id': 1, 'body': 'must not publish'},
        ]),
      );

      expect(
        await notesOutcome.timeout(_deadline),
        isA<ApiFailure>().having(
          (failure) => failure.kind,
          'kind',
          FailureKind.cancelled,
        ),
      );
      expect(noteCalls, 1);
      expect(await _readEpoch(api).timeout(_deadline), before);
    },
  );

  test(
    'privacy marker eviction revokes surviving public subtree state',
    () async {
      var notesCalls = 0;
      var listCalls = 0;
      var confidential = false;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/issues')) {
          listCalls++;
          return jsonResponse([_issue(confidential: confidential)]);
        }
        if (request.uri.path.endsWith('/notes')) {
          notesCalls++;
          return jsonResponse([
            {'body': 'notes $notesCalls'},
          ]);
        }
        return jsonResponse({
          ..._issue(confidential: confidential),
          'iid': int.parse(request.uri.pathSegments.last),
        });
      });
      final api = _boundApi(adapter);
      addTearDown(api.close);
      await api.record(_issuePath);
      await api.cachedRecords(['issues']);
      await api.cachedRecords(_notesPath);
      for (var iid = 2; iid <= 4098; iid++) {
        await api
            .record(['projects', '8', 'issues', '$iid'])
            .timeout(_deadline);
      }
      confidential = true;
      await api.record(_issuePath);
      await api.cachedRecords(_notesPath);
      expect(notesCalls, 2);
      expect(
        (await api.cachedRecords([
          'issues',
        ])).value.items.single['confidential'],
        isTrue,
      );
      expect(listCalls, 2);
    },
  );

  test('write-superseded response still observes confidentiality', () async {
    final issueGates = [Completer<ResponseBody>(), Completer<ResponseBody>()];
    final heldNotes = Completer<ResponseBody>();
    var issueCalls = 0;
    var noteCalls = 0;
    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (request.method != 'GET') return jsonResponse({'id': 101});
      if (path.endsWith('/projects/8/issues/1/notes')) {
        noteCalls++;
        return heldNotes.future;
      }
      if (path.endsWith('/projects/8/issues/1')) {
        issueCalls++;
        if (issueCalls == 1) return jsonResponse(_issue(title: 'public'));
        return issueGates[issueCalls - 2].future;
      }
      throw StateError('Unexpected request: ${request.method} $path');
    });
    final api = _boundApi(adapter);
    addTearDown(api.close);

    expect((await api.record(_issuePath))['confidential'], isFalse);
    final issue = api.cachedRecord(_issuePath);
    await _until(() => issueCalls == 2);

    await api.updateIssue(8, 1, {'title': 'write one'});
    issueGates[0].complete(jsonResponse(_issue(title: 'first old response')));
    await _until(() => issueCalls == 3);
    await api.updateIssue(8, 1, {'title': 'write two'});

    final notes = api.cachedRecords(_notesPath);
    final notesOutcome = notes.then<Object>(
      (value) => value,
      onError: (Object error) => error,
    );
    await _until(() => noteCalls == 1);
    issueGates[1].complete(
      jsonResponse(_issue(confidential: true, title: 'second old response')),
    );

    final superseded = await issue.timeout(_deadline);
    expect(superseded.superseded, isTrue);
    expect(superseded.value['confidential'], isTrue);
    heldNotes.complete(
      jsonResponse([
        {'id': 1, 'body': 'must not publish'},
      ]),
    );
    expect(
      await notesOutcome.timeout(_deadline),
      isA<ApiFailure>().having(
        (failure) => failure.kind,
        'kind',
        FailureKind.cancelled,
      ),
    );
    expect(issueCalls, 3);
    expect(noteCalls, 1);
  });
}

Map<String, Object?> _issue({
  bool confidential = false,
  String title = 'issue',
}) => {
  'id': 101,
  'project_id': 8,
  'iid': 1,
  'title': title,
  'confidential': confidential,
};

GitLabApi _boundApi(
  FakeAdapter adapter, {
  ReadCacheSource? source,
  DateTime Function()? clock,
}) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-test-token',
    dio: Dio()..httpClientAdapter = adapter,
    readCacheSource: source,
    readCacheClock: clock,
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}

Future<int> _readEpoch(GitLabApi api) async => (await api.workItemLabels(
  _workItemDetail(),
  expectedUserId: 7,
  generation: 1,
)).snapshot.readEpoch;

WorkItemGraphDetail _workItemDetail() => WorkItemGraphDetail(
  summary: WorkItemGraphSummary(
    id: _workItemId,
    iid: 1,
    title: 'Privacy regression',
    state: 'OPEN',
    createdAt: _workItemUpdatedAt,
    updatedAt: _workItemUpdatedAt,
    project: const GraphResourceRef(id: _projectId, fullPath: _projectPath),
    namespace: const GraphResourceRef(id: _namespaceId, fullPath: _projectPath),
    type: const WorkItemGraphType(id: _workItemTypeId, name: 'Issue'),
  ),
  description: null,
  widgetsAvailable: true,
  widgetTypes: const {'LABELS'},
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

Map<String, Object?> _workItemLabelsEnvelope() => {
  'data': {
    'currentUser': {'id': 'gid://gitlab/User/7'},
    'workItem': {
      'id': _workItemId,
      'iid': '1',
      'title': 'Privacy regression',
      'state': 'OPEN',
      'createdAt': _workItemUpdatedAt.toIso8601String(),
      'updatedAt': _workItemUpdatedAt.toIso8601String(),
      'project': {'id': _projectId, 'fullPath': _projectPath},
      'namespace': {'id': _namespaceId, 'fullPath': _projectPath},
      'workItemType': {
        'id': _workItemTypeId,
        'name': 'Issue',
        'widgetDefinitions': [
          {'type': 'LABELS', 'allowsScopedLabels': false},
        ],
      },
      'userPermissions': {'readWorkItem': true, 'setWorkItemMetadata': true},
      'widgets': [
        {
          'type': 'LABELS',
          'labels': {
            'nodes': <Object>[],
            'pageInfo': {'hasNextPage': false, 'endCursor': null},
          },
        },
      ],
    },
  },
};

Future<void> _until(bool Function() done) async {
  final until = DateTime.now().add(_deadline);
  while (!done()) {
    if (!DateTime.now().isBefore(until)) {
      throw TimeoutException('condition', _deadline);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
