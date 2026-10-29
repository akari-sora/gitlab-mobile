import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/mr7/sandbox_contract.dart';

Mr7SandboxSession _session(Mr7SyntheticGitLab server) => Mr7SandboxSession(
  server: server,
  nonce: 'testnonce123',
  eventDelay: () async {},
);

void main() {
  String todoDocument(String name) {
    final source = File('lib/core/todo_snooze_api.dart').readAsStringSync();
    final match = RegExp(
      "const $name = r'''([\\s\\S]*?)''';",
    ).firstMatch(source);
    if (match == null) throw StateError('Production Todo document missing');
    return match[1]!.replaceFirst(RegExp(r'^\n'), '');
  }

  test(
    'WorkItem binding retains its type for sealed inline-fragment reads',
    () async {
      const gid = 'gid://gitlab/WorkItem/300';
      const doc =
          r'query W($id: ID!) { workItem(id: $id) { id namespace { id fullPath } widgets { type ... on WorkItemWidgetDescription { description } } } }';
      const vars = {'id': gid};
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      server.routes['GET projects/909/issues/3'] = (_) =>
          mr7Json({'id': 300, 'iid': 3, 'project_id': 909});
      await session.bindWorkItemGraphResource(
        gid,
        path: 'projects/909/issues/3',
      );
      session.observerAdapter.graphReadDocuments = {
        doc: {mr7Digest(vars)},
      };
      var sends = 0;
      server.routes['POST /install/api/graphql'] = (_) {
        sends++;
        return mr7Json({'data': <String, Object?>{}});
      };
      await session.observer.post<Object?>(
        '${session.instance}/api/graphql',
        data: {'query': doc, 'variables': vars},
      );
      expect(sends, 1);
      // A different type with the same numeric suffix is not thereby bound.
      final foreignVars = {'id': 'gid://gitlab/Issue/300'};
      session.observerAdapter.graphReadDocuments = {
        doc: {mr7Digest(foreignVars)},
      };
      await expectLater(
        session.observer.post<Object?>(
          '${session.instance}/api/graphql',
          data: {'query': doc, 'variables': foreignVars},
        ),
        throwsA(anything),
      );
      expect(sends, 1);
      expect(session.quarantined, isTrue);
      await session.finish();
    },
  );

  test(
    'inline fragments retain nested foreign selector and namespace checks',
    () async {
      for (final fragment in [
        r'... on Widget { nested(projectId: $foreign) { id } }',
        r'... on Widget { group { id } }',
        r'... on Widget { namespace { id fullPath projects { nodes { id } } } }',
        r'... NamedFragment',
      ]) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        final doc =
            'query W(\$id: ID!, \$foreign: ID!) { synthetic(id: \$id) { $fragment } }';
        final vars = {'id': 'gid://gitlab/Project/909', 'foreign': 777};
        session.observerAdapter.graphReadDocuments = {
          doc: {mr7Digest(vars)},
        };
        var sends = 0;
        server.routes['POST /install/api/graphql'] = (_) {
          sends++;
          return mr7Json({'data': <String, Object?>{}});
        };
        await expectLater(
          session.observer.post<Object?>(
            '${session.instance}/api/graphql',
            data: {'query': doc, 'variables': vars},
          ),
          throwsA(anything),
        );
        expect(sends, 0, reason: fragment);
        await session.finish();
      }
    },
  );

  test(
    'snapshot rejects omitted project-field changes and records no body',
    () async {
      for (final changeOmitted in [false, true]) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        server.project!['description'] = 'original private fixture';
        final saved = await session.captureSnapshot([
          Mr7SnapshotSpec(
            path: 'projects/909',
            fields: {'name', 'description'},
            unchangedFields: {'description'},
          ),
        ]);
        expect(
          jsonEncode(saved.metadata),
          isNot(contains('original private fixture')),
        );
        server.routes['PUT projects/909'] = (_) {
          server.project!['name'] = 'renamed';
          if (changeOmitted) server.project!['description'] = 'tampered';
          server.scenarioWrites++;
          server.addEvent(target: 909);
          return mr7Json(server.project);
        };
        final permit =
            Mr7MutationPermit(
                operation: 'editProject',
                paths: {'PUT projects/909'},
                resourceProjectId: 909,
              )
              ..confirmed = true
              ..snapshot = saved;
        session.permit = permit;
        await session.writer.put<Object?>(
          'projects/909',
          data: {'name': 'renamed'},
        );
        final observer = Mr7Readback(
          session,
          session.identity!,
          permit,
          paths: {'projects/909'},
        );
        expect(await observer.verifySnapshot(), !changeOmitted);
        await session.finish();
      }
    },
  );

  test(
    'GraphQL snapshot requires the bound target in mutation arguments',
    () async {
      const first = 'gid://gitlab/WorkItem/300';
      const second = 'gid://gitlab/WorkItem/400';
      const doc =
          r'mutation Edit($id: ID!, $unused: ID!) { workItemUpdate(input: {id: $id}) { workItem { id } } }';
      for (final mode in ['bound', 'different', 'unused']) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        server.routes['GET projects/909/issues/3'] = (_) => mr7Json({
          'id': 300,
          'iid': 3,
          'project_id': 909,
          'description': 'preserved',
        });
        server.routes['GET projects/909/issues/4'] = (_) => mr7Json({
          'id': 400,
          'iid': 4,
          'project_id': 909,
          'description': 'other',
        });
        await session.bindWorkItemGraphResource(
          first,
          path: 'projects/909/issues/3',
        );
        await session.bindWorkItemGraphResource(
          second,
          path: 'projects/909/issues/4',
        );
        final saved = await session.captureSnapshot([
          Mr7SnapshotSpec(
            path: 'projects/909/issues/3',
            fields: {'description'},
            unchangedFields: {'description'},
          ),
        ]);
        final vars = {
          'id': mode == 'bound' ? first : second,
          'unused': mode == 'unused' ? first : second,
        };
        final permit =
            Mr7MutationPermit(
                operation: 'updateWorkItemContent',
                paths: {'POST graphql'},
                resourceProjectId: 909,
                graphDocuments: {doc},
                graphVariablesDigests: {mr7Digest(vars)},
                resultPath: ['data', 'workItemUpdate', 'workItem'],
              )
              ..confirmed = true
              ..snapshot = saved;
        session.permit = permit;
        var sends = 0;
        server.routes['POST /install/api/graphql'] = (_) {
          sends++;
          server.scenarioWrites++;
          server.addEvent(target: 909);
          return mr7Json({
            'data': {
              'workItemUpdate': {
                'workItem': {'id': first},
              },
            },
          });
        };
        final request = session.writer.post<Object?>(
          '${session.instance}/api/graphql',
          data: {'query': doc, 'variables': vars},
        );
        if (mode == 'bound') {
          await request;
          final observer = Mr7Readback(
            session,
            session.identity!,
            permit,
            paths: {'projects/909/issues/3'},
          );
          expect(await observer.verifySnapshot(), isTrue);
          expect(sends, 1);
        } else {
          await expectLater(request, throwsA(anything));
          expect(sends, 0, reason: mode);
          expect(session.quarantined, isTrue);
        }
        await session.finish();
      }
    },
  );

  test('snapshot binds original MR numeric id and iid', () async {
    final server = Mr7SyntheticGitLab();
    final session = _session(server);
    await session.initialize();
    var row = <String, Object?>{'id': 400, 'iid': 4, 'project_id': 909};
    server.routes['GET projects/909/merge_requests/4'] = (_) => mr7Json(row);
    final saved = await session.captureSnapshot([
      Mr7SnapshotSpec(path: 'projects/909/merge_requests/4', fields: {}),
    ]);
    server.routes['POST projects/909/merge_requests/4/approve'] = (_) {
      row = {'id': 401, 'iid': 4, 'project_id': 909};
      server.scenarioWrites++;
      server.addEvent(target: 909);
      return mr7Json({'id': 400, 'iid': 4, 'project_id': 909});
    };
    final permit =
        Mr7MutationPermit(
            operation: 'approveMergeRequest',
            paths: {'POST projects/909/merge_requests/4/approve'},
            resourceProjectId: 909,
          )
          ..confirmed = true
          ..snapshot = saved;
    session.permit = permit;
    await session.writer.post<Object?>('projects/909/merge_requests/4/approve');
    final observer = Mr7Readback(
      session,
      session.identity!,
      permit,
      paths: {'projects/909/merge_requests/4'},
    );
    expect(await observer.verifySnapshot(), isFalse);
    await session.finish();
  });

  test(
    'snapshot refuses MR approval when actor or original ID drifts before send',
    () async {
      for (final actorDrift in [true, false]) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        var id = 400;
        var actor = 7;
        server.routes['GET user'] = (_) =>
            mr7Json({'id': actor, 'username': 'synthetic-owner'});
        server.routes['GET projects/909/merge_requests/4'] = (_) =>
            mr7Json({'id': id, 'iid': 4, 'project_id': 909});
        final saved = await session.captureSnapshot([
          Mr7SnapshotSpec(path: 'projects/909/merge_requests/4', fields: {}),
        ]);
        if (actorDrift) {
          actor = 8;
        } else {
          id = 401;
        }
        var sends = 0;
        server.routes['POST projects/909/merge_requests/4/approve'] = (_) {
          sends++;
          return mr7Json({});
        };
        session.permit =
            Mr7MutationPermit(
                operation: 'approveMergeRequest',
                paths: {'POST projects/909/merge_requests/4/approve'},
                resourceProjectId: 909,
              )
              ..confirmed = true
              ..snapshot = saved;
        await expectLater(
          session.writer.post<Object?>('projects/909/merge_requests/4/approve'),
          throwsA(anything),
        );
        expect(sends, 0);
        expect(session.quarantined, isTrue);
        await session.finish();
      }
    },
  );

  test(
    'createTodo requires a freshly verified project-owned final target',
    () async {
      for (final owned in [true, false]) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        server.routes['GET projects/909/issues/3'] = (_) =>
            mr7Json({'id': 300, 'iid': 3, 'project_id': owned ? 909 : 808});
        var sends = 0;
        server.routes['POST projects/909/issues/3/todo'] = (_) {
          sends++;
          return mr7Json({'id': 123}, status: 201);
        };
        session.permit = Mr7MutationPermit(
          operation: 'createTodo',
          paths: {'POST projects/909/issues/3/todo'},
          resourceProjectId: 909,
        )..confirmed = true;
        final future = session.writer.post<Object?>(
          'projects/909/issues/3/todo',
        );
        if (owned) {
          await future;
          expect(sends, 1);
        } else {
          await expectLater(future, throwsA(anything));
          expect(sends, 0);
        }
        await session.finish();
      }
    },
  );

  test('markTodoDone stays closed even with a forged project permit', () async {
    final server = Mr7SyntheticGitLab();
    final session = _session(server);
    await session.initialize();
    var sends = 0;
    server.routes['POST projects/909/issues/3/todo'] = (_) {
      sends++;
      return mr7Json({}, status: 201);
    };
    session.permit = Mr7MutationPermit(
      operation: 'markTodoDone',
      paths: {'POST projects/909/issues/3/todo'},
      resourceProjectId: 909,
    )..confirmed = true;
    await expectLater(
      session.writer.post<Object?>('projects/909/issues/3/todo'),
      throwsA(anything),
    );
    expect(sends, 0);
    await session.finish();
  });

  test(
    'run-created project Todo accepts the exact production ownership read and snooze',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      server.routes['GET projects/909/issues/3'] = (_) =>
          mr7Json({'id': 300, 'iid': 3, 'project_id': 909});
      await session.bindProjectTodo(
        todoId: 123,
        parentPath: 'projects/909/issues/3',
      );
      expect(session.allowsTodoFixture('snoozeTodo'), isTrue);
      final read = todoDocument('_pendingTodosForSnoozeQuery');
      final mutation = todoDocument('_todoSnoozeMutation');
      final readVars = <String, Object?>{'first': 100, 'after': null};
      session.observerAdapter.graphReadDocuments = {
        read: {mr7Digest(readVars)},
      };
      final discovered = await session.writer.post<Object?>(
        '${session.instance}/api/graphql',
        data: {'query': read, 'variables': readVars},
      );
      final currentUser =
          ((discovered.data as Map)['data'] as Map)['currentUser'] as Map;
      expect(currentUser['id'], 'gid://gitlab/User/7');
      final todo =
          ((currentUser['todos'] as Map)['nodes'] as List).single as Map;
      expect(todo['id'], 'gid://gitlab/Todo/123');
      expect((todo['project'] as Map)['id'], 'gid://gitlab/Project/909');
      const vars = {
        'id': 'gid://gitlab/Todo/123',
        'until': '2030-01-01T00:00:00.000Z',
      };
      final permit = Mr7MutationPermit(
        operation: 'snoozeTodo',
        paths: {'POST graphql'},
        resourceProjectId: 909,
        graphDocuments: {mutation},
        graphVariablesDigests: {mr7Digest(vars)},
      )..confirmed = true;
      session.permit = permit;
      await session.writer.post<Object?>(
        '${session.instance}/api/graphql',
        data: {'query': mutation, 'variables': vars},
      );
      expect(permit.sent, 1);
      expect(server.scenarioWrites, 1);
      final observer = Mr7Readback(
        session,
        session.identity!,
        permit,
        paths: {
          'projects/909/issues/3',
          'projects/909/todos/123/mr7-observation',
        },
      );
      expect(
        await observer.observe(
          const Mr7TodoObservation(
            id: 123,
            snoozedUntil: '2030-01-01T00:00:00.000Z',
          ),
        ),
        isTrue,
      );
      final unsnooze = todoDocument('_todoUnsnoozeMutation');
      final snoozedRead = todoDocument('_snoozedTodosForUnsnoozeQuery');
      session.observerAdapter.graphReadDocuments = {
        snoozedRead: {mr7Digest(readVars)},
      };
      await session.writer.post<Object?>(
        '${session.instance}/api/graphql',
        data: {'query': snoozedRead, 'variables': readVars},
      );
      const unsnoozeVars = {'id': 'gid://gitlab/Todo/123'};
      final undoPermit = Mr7MutationPermit(
        operation: 'unsnoozeTodo',
        paths: {'POST graphql'},
        resourceProjectId: 909,
        graphDocuments: {unsnooze},
        graphVariablesDigests: {mr7Digest(unsnoozeVars)},
      )..confirmed = true;
      session.permit = undoPermit;
      await session.writer.post<Object?>(
        '${session.instance}/api/graphql',
        data: {'query': unsnooze, 'variables': unsnoozeVars},
      );
      final undoObserver = Mr7Readback(
        session,
        session.identity!,
        undoPermit,
        paths: {
          'projects/909/issues/3',
          'projects/909/todos/123/mr7-observation',
        },
      );
      expect(
        await undoObserver.observe(
          const Mr7TodoObservation(id: 123, snoozedUntil: null),
        ),
        isTrue,
      );
      await session.finish();
    },
  );

  test(
    'project Todo binding refuses foreign, group, account and actor drift',
    () async {
      for (final mode in ['foreign', 'group', 'account', 'actor']) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        var actor = 7;
        server.routes['GET user'] = (_) =>
            mr7Json({'id': actor, 'username': 'synthetic-owner'});
        server.routes['GET projects/909/issues/3'] = (_) => mr7Json({
          'id': 300,
          'iid': 3,
          'project_id': mode == 'foreign' ? 808 : 909,
        });
        if (mode == 'actor') actor = 8;
        final path = switch (mode) {
          'group' => 'groups/70/issues/3',
          'account' => 'todos/123',
          _ => 'projects/909/issues/3',
        };
        await expectLater(
          session.bindProjectTodo(todoId: 123, parentPath: path),
          throwsA(anything),
        );
        expect(session.allowsTodoFixture('snoozeTodo'), isFalse, reason: mode);
        expect(server.scenarioWrites, 0);
        await session.finish();
      }
    },
  );

  test(
    'project Todo final send refuses changed target, actor and foreign Todo',
    () async {
      for (final mode in ['actor', 'target', 'foreignTodo']) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        var actor = 7;
        var parentId = 300;
        server.routes['GET user'] = (_) =>
            mr7Json({'id': actor, 'username': 'synthetic-owner'});
        server.routes['GET projects/909/issues/3'] = (_) =>
            mr7Json({'id': parentId, 'iid': 3, 'project_id': 909});
        await session.bindProjectTodo(
          todoId: 123,
          parentPath: 'projects/909/issues/3',
        );
        if (mode == 'actor') actor = 8;
        if (mode == 'target') parentId = 301;
        final mutation = todoDocument('_todoSnoozeMutation');
        final vars = {
          'id': 'gid://gitlab/Todo/${mode == 'foreignTodo' ? 456 : 123}',
          'until': '2030-01-01T00:00:00.000Z',
        };
        session.permit = Mr7MutationPermit(
          operation: 'snoozeTodo',
          paths: {'POST graphql'},
          resourceProjectId: 909,
          graphDocuments: {mutation},
          graphVariablesDigests: {mr7Digest(vars)},
        )..confirmed = true;
        await expectLater(
          session.writer.post<Object?>(
            '${session.instance}/api/graphql',
            data: {'query': mutation, 'variables': vars},
          ),
          throwsA(anything),
        );
        expect(server.scenarioWrites, 0, reason: mode);
        await session.finish();
      }
    },
  );

  test(
    'upload observer hashes bounded actual multipart bytes independently',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      final bytes = [0, 1, 255, 13, 10, 42];
      server.routes['POST projects/909/uploads'] = (_) {
        server.scenarioWrites++;
        server.addEvent(target: 909);
        return mr7Json({'markdown': 'synthetic-placeholder'}, status: 201);
      };
      final permit = Mr7MutationPermit(
        operation: 'upload_attachment',
        paths: {'POST projects/909/uploads'},
        resourceProjectId: 909,
      )..confirmed = true;
      session.permit = permit;
      await session.writer.post<Object?>(
        'projects/909/uploads',
        data: FormData.fromMap({
          'file': MultipartFile.fromBytes(bytes, filename: 'fixture.bin'),
        }),
      );
      final hash = sha256.convert(bytes).toString();
      expect(permit.upload, {'byteCount': bytes.length, 'sha256': hash});
      final observer = Mr7Readback(
        session,
        session.identity!,
        permit,
        paths: {'projects/909/uploads/mr7-observation'},
      );
      expect(
        await observer.observe(
          Mr7UploadObservation(byteCount: bytes.length, sha256: hash),
        ),
        isTrue,
      );
      expect(
        await observer.observe(
          Mr7UploadObservation(byteCount: bytes.length, sha256: '0' * 64),
        ),
        isFalse,
      );
      await session.finish();
    },
  );
}
