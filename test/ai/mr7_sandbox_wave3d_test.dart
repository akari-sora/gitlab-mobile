import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_state_models.dart';

import '../../tool/mr7/sandbox_contract.dart';
import '../support/fake_adapter.dart';
import 'mr7_sandbox_wave3b_test.dart' as fixture;

const _item = 'gid://gitlab/WorkItem/300';
const _a = 'gid://gitlab/ProjectLabel/701';
const _b = 'gid://gitlab/ProjectLabel/702';
const _actor = 'gid://gitlab/User/7';
final _revision = DateTime.utc(2026, 10, 29);

Map<String, Object?> _label(String id) => {
  'id': id,
  'title': id == _a ? 'Synthetic A' : 'Synthetic B',
  'color': '#ffffff',
  'textColor': '#000000',
};

WorkItemGraphDetail _detail(String path, {String state = 'OPEN'}) =>
    WorkItemGraphDetail(
      summary: WorkItemGraphSummary(
        id: _item,
        iid: 3,
        title: 'Original title',
        state: state,
        createdAt: DateTime.utc(2026, 9, 1, 1, 2, 3),
        updatedAt: _revision,
        project: GraphResourceRef(
          id: 'gid://gitlab/Project/909',
          fullPath: path,
        ),
        namespace: GraphResourceRef(
          id: 'gid://gitlab/Namespaces::ProjectNamespace/909',
          fullPath: path,
        ),
        type: const WorkItemGraphType(
          id: 'gid://gitlab/WorkItems::Type/99',
          name: 'Issue',
        ),
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

Map<String, Object?> _node(
  String path, {
  String state = 'OPEN',
  List<String> labels = const [],
}) => {
  'id': _item,
  'iid': '3',
  'title': 'Original title',
  'state': state,
  'createdAt': '2026-09-01T01:02:03Z',
  'updatedAt': _revision.toIso8601String(),
  'project': {'id': 'gid://gitlab/Project/909', 'fullPath': path},
  'namespace': {
    'id': 'gid://gitlab/Namespaces::ProjectNamespace/909',
    'fullPath': path,
  },
  'workItemType': {
    'id': 'gid://gitlab/WorkItems::Type/99',
    'name': 'Issue',
    'widgetDefinitions': [
      {'type': 'LABELS', 'allowsScopedLabels': false},
    ],
  },
  'userPermissions': {
    'updateWorkItem': true,
    'readWorkItem': true,
    'setWorkItemMetadata': true,
  },
  'widgets': [
    {
      'type': 'LABELS',
      'labels': {
        'nodes': labels.map(_label).toList(),
        'pageInfo': {'hasNextPage': false, 'endCursor': null},
      },
    },
  ],
};

Future<Map<String, Object?>> _stateRequest(String path, bool close) async {
  final before = close ? 'OPEN' : 'CLOSED';
  final adapter = FakeAdapter((request) {
    final doc = (request.data as Map)['query'] as String;
    if (doc.startsWith('mutation')) {
      return jsonResponse({
        'errors': [
          {'message': 'synthetic capture'},
        ],
      });
    }
    return jsonResponse({
      'data': {'workItem': _node(path, state: before)},
    });
  });
  final api = testApi(adapter);
  try {
    await api.updateWorkItemState(
      _detail(path, state: before).summary,
      close ? WorkItemStateEvent.close : WorkItemStateEvent.reopen,
      expectedUpdatedAt: _revision,
    );
  } catch (_) {
    // The capture adapter rejects the write after recording it.
  } finally {
    api.close();
  }
  return Map<String, Object?>.from(
    adapter.requests
            .singleWhere(
              (r) =>
                  ((r.data as Map)['query'] as String).startsWith('mutation'),
            )
            .data
        as Map,
  );
}

Future<Map<String, Object?>> _labelRequest(String path, bool add) async {
  final before = add ? <String>[] : [_a, _b];
  final adapter = FakeAdapter((request) {
    final doc = (request.data as Map)['query'] as String;
    if (doc.startsWith('mutation')) {
      return jsonResponse({
        'errors': [
          {'message': 'synthetic capture'},
        ],
      });
    }
    if (doc.contains('LabelCandidates')) {
      return jsonResponse({
        'data': {
          'currentUser': {'id': _actor},
          'project': {
            'id': 'gid://gitlab/Project/909',
            'fullPath': path,
            'labels': {
              'nodes': [_label(_a), _label(_b)],
              'pageInfo': {'hasNextPage': false, 'endCursor': null},
            },
          },
        },
      });
    }
    return jsonResponse({
      'data': {
        'currentUser': {'id': _actor},
        'workItem': _node(path, labels: before),
      },
    });
  });
  final api = testApi(adapter);
  final target = (await api.workItemLabels(
    _detail(path),
    expectedUserId: 7,
    generation: 1,
  )).target!;
  if (add) await api.workItemLabelCandidates(target);
  try {
    await api.updateWorkItemLabels(target, desiredLabelIds: [_a]);
  } catch (_) {
    // Capture stops after the real request has been emitted.
  } finally {
    api.close();
  }
  return Map<String, Object?>.from(
    adapter.requests
            .singleWhere(
              (r) =>
                  ((r.data as Map)['query'] as String).startsWith('mutation'),
            )
            .data
        as Map,
  );
}

Future<Map<String, Object?>> _milestoneRequest(String path) async {
  final adapter = FakeAdapter(
    (_) => jsonResponse({
      'errors': [
        {'message': 'synthetic capture'},
      ],
    }),
  );
  final api = testApi(adapter);
  try {
    await api.workItemMilestone(_detail(path), expectedUserId: 7);
  } catch (_) {
    // Only the production query is needed; the response is synthetic.
  } finally {
    api.close();
  }
  return Map<String, Object?>.from(adapter.requests.single.data as Map);
}

Future<Map<String, Object?>> _milestoneMutation(
  fixture.Mr7WorkItemFixture f,
) async {
  final path = f.session.identity!.path;
  final node = {
    ..._node(path),
    'widgets': [
      {
        'type': 'MILESTONE',
        'milestone': {...f.milestoneValue, 'group': null},
      },
    ],
  };
  final adapter = FakeAdapter((request) {
    if (((request.data as Map)['query'] as String).startsWith('mutation')) {
      return jsonResponse({
        'errors': [
          {'message': 'synthetic capture'},
        ],
      });
    }
    return jsonResponse({
      'data': {
        'currentUser': {'id': _actor},
        'workItem': node,
      },
    });
  });
  final api = testApi(adapter);
  try {
    final target = (await api.workItemMilestone(
      _detail(path),
      expectedUserId: 7,
    )).target!;
    await api.updateWorkItemMilestone(target, selection: target.clearSelection);
  } catch (_) {
    // Capture rejects the production mutation after dispatch.
  } finally {
    api.close();
  }
  return Map<String, Object?>.from(
    adapter.requests
            .singleWhere(
              (r) =>
                  ((r.data as Map)['query'] as String).startsWith('mutation'),
            )
            .data
        as Map,
  );
}

Future<List<Map<String, Object?>>> _activityRequests(
  fixture.Mr7ActivityFixture f,
  bool reply,
) async {
  const old = 'gid://gitlab/Note/51';
  const created = 'gid://gitlab/Note/52';
  f.bodies[created] = 'Created';
  final adapter = FakeAdapter((request) {
    final doc = (request.data as Map)['query'] as String;
    if (doc.contains('MobileWorkItemActivityWriteAccess') ||
        doc.contains('MobileWorkItemActivityReplyPreflight')) {
      return jsonResponse({
        'data': {
          'currentUser': {'id': _actor},
          'workItem': {
            ...f.item,
            'userPermissions': {'createNote': true},
            'widgets': [
              {'type': 'NOTES', 'discussionLocked': false},
            ],
          },
          if (reply) 'anchor': f.noteDetail(old),
        },
      });
    }
    if (doc.startsWith('mutation')) {
      return jsonResponse({
        'data': {
          'createNote': {'errors': <String>[], 'note': f.noteDetail(created)},
        },
      });
    }
    if (doc.contains('MobileWorkItemActivityNoteReadback')) {
      return jsonResponse({
        'data': {'workItem': f.item, 'note': f.noteDetail(created)},
      });
    }
    return f.graph(request);
  });
  final api = testApi(adapter);
  final summary = _detail(f.session.identity!.path).summary;
  try {
    if (reply) {
      final page = await api.workItemActivity(
        summary,
        allowLegacyFallback: false,
      );
      final target = page.replyTargetsByNote[old]!;
      await api.createWorkItemActivityReply(target, 'Created');
    } else {
      final access = await api.workItemActivityWriteAccess(summary);
      await api.createWorkItemActivityComment(access.commentTarget!, 'Created');
    }
  } finally {
    api.close();
  }
  return adapter.requests
      .map((r) => Map<String, Object?>.from(r.data as Map))
      .toList();
}

void main() {
  test('production state close and reopen verify and mismatch fails', () async {
    for (final close in [true, false]) {
      for (final mismatch in [false, true]) {
        final f = fixture.Mr7WorkItemFixture.create();
        await f.initialize();
        final request = await _stateRequest(f.session.identity!.path, close);
        final event = close ? 'close' : 'reopen';
        expect(
          ((request['variables'] as Map)['input'] as Map)['stateEvent'],
          event.toUpperCase(),
        );
        f.state = mismatch
            ? (close ? 'CLOSED' : 'OPEN')
            : (close ? 'OPEN' : 'CLOSED');
        final result = await f.effect(
          operation: 'updateWorkItemState',
          args: {'stateEvent': mismatch ? (close ? 'reopen' : 'close') : event},
          input: const {},
          capturedRequest: request,
          mutate: () => f.state = mismatch
              ? (close ? 'OPEN' : 'CLOSED')
              : (close ? 'CLOSED' : 'OPEN'),
        );
        expect(result, !mismatch, reason: '$event mismatch=$mismatch');
        await f.session.finish();
      }
    }
  });

  test(
    'production labels add-only and remove-only verify complete sets',
    () async {
      for (final add in [true, false]) {
        final f = fixture.Mr7WorkItemFixture.create();
        await f.initialize();
        final request = await _labelRequest(f.session.identity!.path, add);
        final widget =
            (((request['variables'] as Map)['input'] as Map)['labelsWidget']
                as Map);
        expect(
          widget.containsKey(add ? 'removeLabelIds' : 'addLabelIds'),
          isFalse,
        );
        f.labels = add ? [] : [_label(_a), _label(_b)];
        expect(
          await f.effect(
            operation: 'updateWorkItemLabels',
            args: {
              'labels': ['Synthetic A'],
            },
            input: const {},
            capturedRequest: request,
            mutate: () => f.labels = [_label(_a)],
          ),
          isTrue,
        );
        await f.session.finish();
      }
    },
  );
  test(
    'production milestone owner projection accepts null and sandbox namespace',
    () async {
      for (final own in [false, true]) {
        final f = fixture.Mr7WorkItemFixture.create();
        await f.initialize();
        final identity = f.session.identity!;
        final request = await _milestoneRequest(identity.path);
        final document = request['query'] as String;
        expect(document, contains('group { id fullPath }'));
        f.milestone = {
          ...f.milestoneValue,
          'group': own
              ? {
                  'id': 'gid://gitlab/Group/${identity.namespaceId}',
                  'fullPath': identity.namespace,
                }
              : null,
        };
        f.session.permit = Mr7MutationPermit(
          operation: 'updateWorkItemMilestone',
          paths: {'POST graphql'},
          resourceProjectId: 909,
        )..confirmed = true;
        f.session.observerAdapter.graphReadDocuments = {
          document: {mr7Digest(request['variables'])},
        };
        final result = await f.session.writer.post<Object?>(
          '${f.session.instance}/api/graphql',
          data: request,
        );
        expect(result.statusCode, 200);
        await f.session.finish();
      }
    },
  );

  test(
    'milestone group selector and unrelated owner fields are refused',
    () async {
      for (final altered in [
        'group { id fullPath name }',
        'group(fullPath: "other") { id fullPath }',
      ]) {
        final f = fixture.Mr7WorkItemFixture.create();
        await f.initialize();
        final request = await _milestoneRequest(f.session.identity!.path);
        final document = (request['query'] as String).replaceFirst(
          'group { id fullPath }',
          altered,
        );
        request['query'] = document;
        f.session.permit = Mr7MutationPermit(
          operation: 'updateWorkItemMilestone',
          paths: {'POST graphql'},
          resourceProjectId: 909,
        )..confirmed = true;
        f.session.observerAdapter.graphReadDocuments = {
          document: {mr7Digest(request['variables'])},
        };
        await expectLater(
          f.session.writer.post<Object?>(
            '${f.session.instance}/api/graphql',
            data: request,
          ),
          throwsA(anything),
        );
        expect(
          f.server.requests.where((s) => s == 'POST /install/api/graphql'),
          isEmpty,
        );
        await f.session.finish();
      }
    },
  );

  test('milestone foreign owner response is refused', () async {
    final f = fixture.Mr7WorkItemFixture.create();
    await f.initialize();
    final request = await _milestoneRequest(f.session.identity!.path);
    f.milestone = {
      ...f.milestoneValue,
      'group': {'id': 'gid://gitlab/Group/999', 'fullPath': 'foreign'},
    };
    final document = request['query'] as String;
    f.session.permit = Mr7MutationPermit(
      operation: 'updateWorkItemMilestone',
      paths: {'POST graphql'},
      resourceProjectId: 909,
    )..confirmed = true;
    f.session.observerAdapter.graphReadDocuments = {
      document: {mr7Digest(request['variables'])},
    };
    await expectLater(
      f.session.writer.post<Object?>(
        '${f.session.instance}/api/graphql',
        data: request,
      ),
      throwsA(anything),
    );
    await f.session.finish();
  });
  test(
    'created comment and opaque reply use fresh ownership before production readback',
    () async {
      for (final reply in [false, true]) {
        final f = fixture.Mr7ActivityFixture.create()..bindCreatedNote = false;
        await f.initialize();
        final requests = await _activityRequests(f, reply);
        final mutation = requests.singleWhere(
          (r) => (r['query'] as String).startsWith('mutation'),
        );
        final readback = requests.singleWhere(
          (r) => (r['query'] as String).contains(
            'MobileWorkItemActivityNoteReadback',
          ),
        );
        final vars = mutation['variables'] as Map;
        expect((vars['input'] as Map).containsKey('discussionId'), reply);
        f.bodies.remove('gid://gitlab/Note/52');
        f.session.permit = Mr7MutationPermit(
          operation: reply
              ? 'createWorkItemActivityReply'
              : 'createWorkItemActivityComment',
          paths: {'POST graphql'},
          resourceProjectId: 909,
          graphDocuments: {mutation['query'] as String},
          graphVariablesDigests: {mr7Digest(vars)},
          resultPath: const ['data', 'createNote', 'note'],
        )..confirmed = true;
        final doc = readback['query'] as String;
        f.session.observerAdapter.graphReadDocuments = {
          doc: {mr7Digest(readback['variables'])},
        };
        final before = f.server.requests
            .where((r) => r == 'GET projects/909/issues/3/notes/52')
            .length;
        expect(before, 0, reason: 'The returned Note must not be prebound.');
        await f.session.writer.post<Object?>(
          '${f.session.instance}/api/graphql',
          data: mutation,
        );
        expect(
          f.server.requests
              .where((r) => r == 'GET projects/909/issues/3/notes/52')
              .length,
          greaterThan(before),
        );
        final response = await f.session.writer.post<Object?>(
          '${f.session.instance}/api/graphql',
          data: readback,
        );
        expect(response.statusCode, 200);
        await f.session.finish();
      }
    },
  );

  test('created note foreign author and parent fail fresh ownership', () async {
    for (final field in ['author', 'parent', 'project']) {
      final f = fixture.Mr7ActivityFixture.create()..bindCreatedNote = false;
      await f.initialize();
      final requests = await _activityRequests(f, false);
      final mutation = requests.singleWhere(
        (r) => (r['query'] as String).startsWith('mutation'),
      );
      f.bodies.remove('gid://gitlab/Note/52');
      f.server.routes['GET projects/909/issues/3/notes/52'] = (_) => mr7Json({
        'id': 52,
        'project_id': field == 'project' ? 777 : 909,
        'noteable_id': field == 'parent' ? 301 : 300,
        'author': {'id': field == 'author' ? 8 : 7},
        'internal': false,
        'system': false,
      });
      f.session.permit = Mr7MutationPermit(
        operation: 'createWorkItemActivityComment',
        paths: {'POST graphql'},
        resourceProjectId: 909,
        graphDocuments: {mutation['query'] as String},
        graphVariablesDigests: {mr7Digest(mutation['variables'])},
        resultPath: const ['data', 'createNote', 'note'],
      )..confirmed = true;
      await expectLater(
        f.session.writer.post<Object?>(
          '${f.session.instance}/api/graphql',
          data: mutation,
        ),
        throwsA(anything),
        reason: field,
      );
      await f.session.finish();
    }
  });
  test(
    'created note readback rejects uncreated and different returned ids',
    () async {
      for (final beforeCreation in [true, false]) {
        final f = fixture.Mr7ActivityFixture.create()..bindCreatedNote = false;
        await f.initialize();
        final requests = await _activityRequests(f, false);
        final mutation = requests.singleWhere(
          (r) => (r['query'] as String).startsWith('mutation'),
        );
        final original = requests.singleWhere(
          (r) => (r['query'] as String).contains(
            'MobileWorkItemActivityNoteReadback',
          ),
        );
        f.bodies.remove('gid://gitlab/Note/52');
        f.session.permit = Mr7MutationPermit(
          operation: 'createWorkItemActivityComment',
          paths: {'POST graphql'},
          resourceProjectId: 909,
          graphDocuments: {mutation['query'] as String},
          graphVariablesDigests: {mr7Digest(mutation['variables'])},
          resultPath: const ['data', 'createNote', 'note'],
        )..confirmed = true;
        final query = Map<String, Object?>.from(original);
        if (!beforeCreation) {
          await f.session.writer.post<Object?>(
            '${f.session.instance}/api/graphql',
            data: mutation,
          );
          query['variables'] = {
            'workItemId': _item,
            'noteId': 'gid://gitlab/Note/53',
          };
        }
        final doc = query['query'] as String;
        f.session.observerAdapter.graphReadDocuments = {
          doc: {mr7Digest(query['variables'])},
        };
        await expectLater(
          f.session.writer.post<Object?>(
            '${f.session.instance}/api/graphql',
            data: query,
          ),
          throwsA(anything),
        );
        await f.session.finish();
      }
    },
  );
  test(
    'created note ownership refuses a permit switch during fresh read',
    () async {
      final f = fixture.Mr7ActivityFixture.create()..bindCreatedNote = false;
      await f.initialize();
      final requests = await _activityRequests(f, false);
      final mutation = requests.singleWhere(
        (r) => (r['query'] as String).startsWith('mutation'),
      );
      f.bodies.remove('gid://gitlab/Note/52');
      final entered = Completer<void>();
      final release = Completer<void>();
      f.server.routes['GET projects/909/issues/3/notes/52'] = (_) async {
        entered.complete();
        await release.future;
        return mr7Json(f.noteRest('gid://gitlab/Note/52'));
      };
      f.session.permit = Mr7MutationPermit(
        operation: 'createWorkItemActivityComment',
        paths: {'POST graphql'},
        resourceProjectId: 909,
        graphDocuments: {mutation['query'] as String},
        graphVariablesDigests: {mr7Digest(mutation['variables'])},
        resultPath: const ['data', 'createNote', 'note'],
      )..confirmed = true;
      final pending = f.session.writer.post<Object?>(
        '${f.session.instance}/api/graphql',
        data: mutation,
      );
      final rejected = expectLater(pending, throwsA(anything));
      await entered.future;
      f.session.permit = Mr7MutationPermit(
        operation: 'createWorkItemActivityComment',
        paths: {'POST graphql'},
        resourceProjectId: 909,
      )..confirmed = true;
      release.complete();
      await rejected;
      await f.session.finish();
    },
  );
  test('empty production label deltas are refused', () async {
    for (final widget in <Map<String, Object?>>[
      {},
      {'addLabelIds': <String>[]},
      {'removeLabelIds': <String>[]},
      {'addLabelIds': <String>[], 'removeLabelIds': <String>[]},
    ]) {
      final f = fixture.Mr7WorkItemFixture.create();
      await f.initialize();
      final request = await _labelRequest(f.session.identity!.path, true);
      final variables = Map<String, Object?>.from(request['variables'] as Map);
      final input = Map<String, Object?>.from(variables['input'] as Map);
      input['labelsWidget'] = widget;
      variables['input'] = input;
      request['variables'] = variables;
      f.labels = [_label(_a)];
      expect(
        await f.effect(
          operation: 'updateWorkItemLabels',
          args: {
            'labels': ['Synthetic A'],
          },
          input: const {},
          capturedRequest: request,
          mutate: () {},
        ),
        isFalse,
        reason: '$widget',
      );
      await f.session.finish();
    }
  });

  test(
    'delayed milestone read validates owner against sent document',
    () async {
      final f = fixture.Mr7WorkItemFixture.create();
      await f.initialize();
      final request = await _milestoneRequest(f.session.identity!.path);
      f.milestone = {
        ...f.milestoneValue,
        'group': {'id': 'gid://gitlab/Group/999', 'fullPath': 'foreign'},
      };
      const other =
          r'query Safe($id: WorkItemID!) { workItem(id: $id) { id } }';
      final replacement = {
        'query': other,
        'variables': {'id': _item},
      };
      f.session.permit = Mr7MutationPermit(
        operation: 'updateWorkItemMilestone',
        paths: {'POST graphql'},
        resourceProjectId: 909,
      )..confirmed = true;
      f.session.observerAdapter.graphReadDocuments = {
        request['query'] as String: {mr7Digest(request['variables'])},
        other: {mr7Digest(replacement['variables'])},
      };
      final entered = Completer<void>();
      final release = Completer<void>();
      f.server.routes['POST /install/api/graphql'] = (options) async {
        final response = f.graph(options);
        entered.complete();
        await release.future;
        options.data = replacement;
        return response;
      };
      final pending = f.session.writer.post<Object?>(
        '${f.session.instance}/api/graphql',
        data: request,
      );
      final rejected = expectLater(pending, throwsA(anything));
      await entered.future;
      release.complete();
      await rejected;
      await f.session.finish();
    },
  );

  test(
    'create response and stream refuse a switched permit before binding',
    () async {
      for (final delayedStream in [false, true]) {
        final f = fixture.Mr7ActivityFixture.create()..bindCreatedNote = false;
        await f.initialize();
        final requests = await _activityRequests(f, false);
        final mutation = requests.singleWhere(
          (r) => (r['query'] as String).startsWith('mutation'),
        );
        f.bodies.remove('gid://gitlab/Note/52');
        final entered = Completer<void>();
        final release = Completer<void>();
        f.server.routes['POST /install/api/graphql'] = (options) async {
          final response = f.graph(options);
          if (!delayedStream) {
            entered.complete();
            await release.future;
            return response;
          }
          Stream<Uint8List> delayed() async* {
            entered.complete();
            await release.future;
            yield* response.stream;
          }

          return ResponseBody(
            delayed(),
            response.statusCode,
            headers: response.headers,
          );
        };
        Mr7MutationPermit permit() => Mr7MutationPermit(
          operation: 'createWorkItemActivityComment',
          paths: {'POST graphql'},
          resourceProjectId: 909,
          graphDocuments: {mutation['query'] as String},
          graphVariablesDigests: {mr7Digest(mutation['variables'])},
          resultPath: const ['data', 'createNote', 'note'],
        )..confirmed = true;
        f.session.permit = permit();
        final pending = f.session.writer.post<Object?>(
          '${f.session.instance}/api/graphql',
          data: mutation,
        );
        final rejected = expectLater(pending, throwsA(anything));
        await entered.future;
        final replacement = permit();
        f.session.permit = replacement;
        release.complete();
        await rejected;
        expect(replacement.returnedGlobalId, isNull);
        expect(replacement.result, isNull);
        expect(
          f.server.requests.where(
            (r) => r == 'GET projects/909/issues/3/notes/52',
          ),
          isEmpty,
        );
        await f.session.finish();
      }
    },
  );
  test(
    'delayed milestone mutation validates owner against sent document',
    () async {
      for (final delayedStream in [false, true]) {
        final f = fixture.Mr7WorkItemFixture.create();
        await f.initialize();
        f.milestone = {...f.milestoneValue, 'group': null};
        final mutation = await _milestoneMutation(f);
        final entered = Completer<void>();
        final release = Completer<void>();
        f.server.routes['POST /install/api/graphql'] = (options) async {
          final doc = (options.data as Map)['query'] as String;
          if (!doc.startsWith('mutation')) return f.graph(options);
          final response = jsonResponse({
            'data': {
              'workItemUpdate': {
                'errors': <String>[],
                'workItem': {
                  ..._node(f.session.identity!.path),
                  'widgets': [
                    {
                      'type': 'MILESTONE',
                      'milestone': {
                        ...f.milestoneValue,
                        'group': {
                          'id': 'gid://gitlab/Group/999',
                          'fullPath': 'foreign',
                        },
                      },
                    },
                  ],
                },
              },
            },
          });
          void replaceBody() {
            options.data = {
              'query':
                  r'query Safe($id: WorkItemID!) { workItem(id: $id) { id } }',
              'variables': {'id': _item},
            };
          }

          if (!delayedStream) {
            entered.complete();
            await release.future;
            replaceBody();
            return response;
          }
          Stream<Uint8List> delayed() async* {
            entered.complete();
            await release.future;
            replaceBody();
            yield* response.stream;
          }

          return ResponseBody(
            delayed(),
            response.statusCode,
            headers: response.headers,
          );
        };
        final pending = f.effect(
          operation: 'updateWorkItemMilestone',
          args: {'milestoneId': null},
          input: const {},
          capturedRequest: mutation,
          mutate: () {},
        );
        final rejected = expectLater(pending, throwsA(anything));
        await entered.future;
        release.complete();
        await rejected;
        await f.session.finish();
      }
    },
  );
}
