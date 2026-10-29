import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/release_policy.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';

import '../../tool/mr7/sandbox_contract.dart';
import '../../tool/mr7_sandbox.dart' as sandbox;

const _sha = '0123456789abcdef0123456789abcdef01234567';

Mr7SandboxSession _session(
  Mr7SyntheticGitLab server, {
  Future<void> Function()? eventDelay,
}) => Mr7SandboxSession(
  server: server,
  nonce: 'testnonce123',
  eventDelay: eventDelay,
);

Mr7MutationPermit _starPermit(Mr7Identity identity) => Mr7MutationPermit(
  operation: 'setStar',
  paths: {'POST projects/${identity.projectId}/star'},
  resourceProjectId: identity.projectId,
)..confirmed = true;

List<Map<String, Object?>> _rows(Map<String, Object?> receipt) =>
    (receipt['scenarios']! as List).cast<Map<String, Object?>>();

Map<String, Object?> _part(Map<String, Object?> receipt, String name) =>
    (receipt[name]! as Map).cast<String, Object?>();

sandbox.Mr7Scenario _star(String id) => sandbox.Mr7Scenario(
  id: id,
  suite: 'rest',
  operation: 'setStar',
  variant: id,
  tier: 'T1',
  call: (p) => AiToolCall(
    id: id,
    name: 'setStar',
    arguments: {
      'projectId': p.projectId,
      'starred': true,
      'reason': 'Synthetic sandbox star requested.',
    },
  ),
  paths: (p) => {'POST projects/${p.projectId}/star'},
  observe: (s, p) async =>
      (await s.read('projects/${p.projectId}'))['starred'] == true,
);

Map<String, List<String>> _pageHeaders({
  required int page,
  required int total,
  int perPage = 1,
}) => {
  'x-page': ['$page'],
  'x-per-page': ['$perPage'],
  'x-total': ['$total'],
  'x-total-pages': ['${total == 0 ? 1 : (total + perPage - 1) ~/ perPage}'],
  'x-next-page': [page * perPage < total ? '${page + 1}' : ''],
};

void _hideDeletedLookup(Mr7SyntheticGitLab server) {
  server.routes['GET projects/909'] = (_) => server.cleanupWrites > 0
      ? mr7Json({}, status: 404)
      : mr7Json(server.project);
}

Map<String, Object?> _otherProject() => {
  'id': 1000,
  'path_with_namespace': 'synthetic-owner/another',
  'namespace': {'id': 70},
};

void main() {
  test('cleanup checks every parent page before confirming deletion', () async {
    final server = Mr7SyntheticGitLab()..delayedDeletion = true;
    final session = _session(server);
    await session.initialize();
    _hideDeletedLookup(server);
    final pages = <int>[];
    server.routes['GET projects'] = (request) {
      final page = request.queryParameters['page'] as int? ?? 1;
      pages.add(page);
      return mr7Json([
        page == 1 ? _otherProject() : server.project,
      ], headers: _pageHeaders(page: page, total: 2));
    };
    await session.finish();
    expect(pages, [1, 2]);
    expect(session.cleanup['accepted'], isTrue);
    expect(session.cleanup['deletionVerified'], isFalse);
    expect(session.cleanup['status'], 'PENDING');
    expect(session.quarantined, isTrue);
  });

  test('cleanup refuses malformed or truncated parent pages', () async {
    for (final variant in [
      'nonMap',
      'missingId',
      'stringId',
      'missingNamespace',
      'emptyPath',
      'nestedPath',
      'namespaceType',
      'pathMismatch',
      'missingHeader',
      'skippedPage',
      'changedTotal',
      'shortPage',
      'duplicateId',
      'truncated',
    ]) {
      final server = Mr7SyntheticGitLab()..delayedDeletion = true;
      final session = _session(server);
      await session.initialize();
      _hideDeletedLookup(server);
      server.routes['GET projects'] = (request) {
        final page = request.queryParameters['page'] as int? ?? 1;
        Object? row = {..._otherProject(), 'id': 1000 + page};
        final headers = _pageHeaders(page: page, total: 2);
        switch (variant) {
          case 'nonMap':
            row = 'broken';
          case 'missingId':
            row = {
              'namespace': {'id': 70},
            };
          case 'stringId':
            row = {..._otherProject(), 'id': '1000'};
          case 'missingNamespace':
            row = {'id': 1000};
          case 'emptyPath':
            row = {
              ..._otherProject(),
              'path_with_namespace': 'synthetic-owner/',
            };
          case 'nestedPath':
            row = {
              ..._otherProject(),
              'path_with_namespace': 'synthetic-owner/a/b',
            };
          case 'namespaceType':
            row = {
              ..._otherProject(),
              'namespace': {'id': 70.0},
            };
          case 'pathMismatch':
            row = {..._otherProject(), 'path': 'different'};
          case 'missingHeader':
            headers.remove('x-next-page');
          case 'skippedPage':
            headers['x-next-page'] = ['3'];
          case 'changedTotal':
            if (page > 1) headers.addAll(_pageHeaders(page: page, total: 3));
          case 'duplicateId':
            row = _otherProject();
          case 'truncated':
            headers['x-next-page'] = [''];
        }
        return mr7Json(variant == 'shortPage' ? [] : [row], headers: headers);
      };
      await session.finish();
      expect(session.cleanup['accepted'], isTrue, reason: variant);
      expect(session.cleanup['deletionVerified'], isFalse, reason: variant);
      expect(session.cleanup['status'], 'NOT_VERIFIED', reason: variant);
      expect(session.quarantined, isTrue, reason: variant);
    }
  });

  test('cleanup verifies absence across complete parent pagination', () async {
    final server = Mr7SyntheticGitLab();
    final session = _session(server);
    await session.initialize();
    final pages = <int>[];
    server.routes['GET projects'] = (request) {
      final page = request.queryParameters['page'] as int? ?? 1;
      pages.add(page);
      return mr7Json([
        {..._otherProject(), 'id': 1000 + page},
      ], headers: _pageHeaders(page: page, total: 2));
    };
    await session.finish();
    expect(pages, [1, 2]);
    expect(session.cleanup['status'], 'PASS');
    expect(session.cleanup['deletionVerified'], isTrue);
    expect(session.cleanup['parentChecked'], isTrue);
  });

  test('events reject skipped pages and inconsistent totals', () async {
    for (final variant in [
      'skippedPage',
      'changedTotal',
      'wrongPage',
      'truncated',
    ]) {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      server.addEvent(target: 777);
      server.addEvent(target: 909);
      server.routes['GET users/7/events'] = (request) {
        final page = request.queryParameters['page'] as int;
        final headers = _pageHeaders(page: page, total: 3);
        if (variant == 'skippedPage' && page == 1) {
          headers['x-next-page'] = ['3'];
        } else if (variant == 'changedTotal' && page > 1) {
          headers.addAll(_pageHeaders(page: page, total: 2));
        } else if (variant == 'wrongPage') {
          headers['x-page'] = ['${page + 1}'];
        } else if (variant == 'truncated') {
          headers['x-next-page'] = [''];
        }
        return mr7Json([
          variant == 'changedTotal'
              ? server.events.first
              : server.events[page - 1],
        ], headers: headers);
      };
      await expectLater(
        session.checkIsolation(),
        throwsA(anything),
        reason: variant,
      );
      await session.finish();
      expect(session.isolation['status'], 'NOT_VERIFIED', reason: variant);
      expect(session.isolation['complete'], isFalse, reason: variant);
      expect(session.quarantined, isTrue, reason: variant);
      expect(server.cleanupWrites, 0, reason: variant);
    }
  });

  test(
    'events reject duplicate IDs within a complete pagination pass',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      server.addEvent(target: 777);
      server.routes['GET users/7/events'] = (request) => mr7Json(
        [server.events.first],
        headers: _pageHeaders(
          page: request.queryParameters['page'] as int,
          total: 2,
        ),
      );
      await expectLater(session.checkIsolation(), throwsA(anything));
      await session.finish();
      expect(session.isolation['status'], 'NOT_VERIFIED');
      expect(session.isolation['complete'], isFalse);
      expect(server.cleanupWrites, 0);
    },
  );

  test('GraphQL refuses unscoped roots and numeric target lists', () async {
    for (final document in [
      'query X { projects { nodes { id } } }',
      'query X { issues { nodes { id } } }',
      'query X { currentUser { starredProjects { nodes { id } } } }',
      r'query X($items: [ID!]!) { nodes(ids: $items) { id } }',
      r'query X($items: [ID!]!) { synthetic(input: {targetIds: $items}) { id } }',
      r'query X($path: ID!) { project(fullPath: $missing) { id } }',
    ]) {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      final vars = {
        'items': [44],
        'path': 'synthetic-owner/mr7-testnonce123',
      };
      session.observerAdapter.graphReadDocuments = {
        document: {mr7Digest(vars)},
      };
      await expectLater(
        session.observer.post<Object?>(
          '${session.instance}/api/graphql',
          data: {'query': document, 'variables': vars},
        ),
        throwsA(anything),
      );
      expect(server.requests, isNot(contains('POST /install/api/graphql')));
      await session.finish();
      expect(server.cleanupWrites, 0);
    }
  });

  test('GraphQL selection has no secondary request override', () async {
    const document = 'query Read { currentUser { id } }';
    for (final variant in ['url', 'extension']) {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      session.observerAdapter.graphReadDocuments = {
        document: {mr7Digest(null)},
      };
      await expectLater(
        session.observer.post<Object?>(
          '${session.instance}/api/graphql${variant == 'url' ? '?operationName=Write' : ''}',
          data: {
            'query': document,
            if (variant == 'extension')
              'extensions': {'operationName': 'Write'},
          },
        ),
        throwsA(anything),
      );
      expect(server.requests, isNot(contains('POST /install/api/graphql')));
      await session.finish();
    }
  });

  test(
    'GraphQL parser preserves single queries and skips quoted keywords',
    () async {
      for (final document in [
        '{ currentUser { id } }',
        'query { currentUser { id } }',
        'query Read { currentUser { id } }',
        '# mutation ignored in comment\nquery Read(\$id: ID!) { alias: synthetic(id: \$id, text: "mutation { }") { id } }',
      ]) {
        for (final client in ['observer', 'writer']) {
          final server = Mr7SyntheticGitLab();
          final session = _session(server);
          await session.initialize();
          var sends = 0;
          server.routes['POST /install/api/graphql'] = (_) {
            sends++;
            return mr7Json({'id': 909});
          };
          final vars = document.contains(r'$id')
              ? {'id': 'gid://gitlab/Project/909'}
              : null;
          session.observerAdapter.graphReadDocuments = {
            document: {mr7Digest(vars)},
          };
          await (client == 'observer' ? session.observer : session.writer)
              .post<Object?>(
                '${session.instance}/api/graphql',
                data: {'query': document, 'variables': vars},
              );
          expect(sends, 1);
          expect(
            session.requestLedger.where(
              (r) => r['operation'] != 'harnessSetup',
            ),
            isEmpty,
          );
          await session.finish();
        }
      }
    },
  );

  test('GraphQL read classification follows the selected operation', () async {
    const mixed =
        r'query Read($id: ID!) { synthetic(id: $id) { id } } '
        r'mutation Write($id: ID!) { synthetic(id: $id) { id } }';
    const vars = {'id': 'gid://gitlab/Project/909'};
    for (final client in ['observer', 'writer']) {
      for (final operationName in <String?>[null, 'Write', 'Missing', 'Read']) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        var sends = 0;
        server.routes['POST /install/api/graphql'] = (_) {
          sends++;
          return mr7Json({'id': 909});
        };
        session.observerAdapter.graphReadDocuments = {
          mixed: {mr7Digest(vars)},
        };
        final request =
            (client == 'observer' ? session.observer : session.writer)
                .post<Object?>(
                  '${session.instance}/api/graphql',
                  data: {
                    'query': mixed,
                    'variables': vars,
                    'operationName': ?operationName,
                  },
                );
        if (operationName == 'Read') {
          await request;
          expect(sends, 1);
        } else {
          await expectLater(request, throwsA(anything));
          expect(sends, 0, reason: '$client/$operationName');
        }
        expect(server.scenarioWrites, 0);
        expect(
          session.requestLedger.where((r) => r['operation'] != 'harnessSetup'),
          isEmpty,
        );
        await session.finish();
      }
    }
  });

  test(
    'GraphQL operation parsing refuses ambiguity and unsupported syntax',
    () async {
      for (final document in [
        'query Same { currentUser { id } } query Same { currentUser { id } }',
        'query { currentUser { id } } query Other { currentUser { id } }',
        'query Read { currentUser { id } } trailing',
        'query Read { currentUser { id } } fragment F on User { id }',
        'query Read { currentUser @skip(if: false) { id } }',
        'query Read(\$id: ID = "unused") { currentUser { id } }',
        'query Read { currentUser(text: """block""") { id } }',
      ]) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        final vars = <String, Object?>{};
        session.observerAdapter.graphReadDocuments = {
          document: {mr7Digest(vars)},
        };
        await expectLater(
          session.observer.post<Object?>(
            '${session.instance}/api/graphql',
            data: {
              'query': document,
              'variables': vars,
              'operationName': document.contains('query Same')
                  ? 'Same'
                  : document.contains('query Other')
                  ? 'Other'
                  : 'Read',
            },
          ),
          throwsA(anything),
        );
        expect(server.requests, isNot(contains('POST /install/api/graphql')));
        await session.finish();
      }
    },
  );

  test('GraphQL target arguments resolve aliases before dispatch', () async {
    for (final kind in ['query', 'mutation']) {
      for (final variant in [
        'owned',
        'foreignPath',
        'foreignId',
        'group',
        'nested',
      ]) {
        final field = variant == 'group' ? 'group' : 'synthetic';
        final argument = switch (variant) {
          'foreignId' => r'projectId: $destination',
          'nested' => r'input: {projectId: $destination}',
          _ => r'fullPath: $destination',
        };
        final document =
            '$kind X(\$destination: ID!) { $field($argument) { id } }';
        final vars = {
          'destination': switch (variant) {
            'foreignId' || 'nested' => 777,
            'owned' => 'synthetic-owner/mr7-testnonce123',
            _ => 'foreign/project',
          },
        };
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        var sends = 0;
        server.routes['POST /install/api/graphql'] = (_) {
          sends++;
          return mr7Json({'id': 909});
        };
        if (kind == 'query') {
          session.observerAdapter.graphReadDocuments = {
            document: {mr7Digest(vars)},
          };
        } else {
          session.permit = Mr7MutationPermit(
            operation: 'updateWorkItemState',
            paths: {'POST graphql'},
            resourceProjectId: 909,
            graphDocuments: {document},
            graphVariablesDigests: {mr7Digest(vars)},
          )..confirmed = true;
        }
        final request = (kind == 'query' ? session.observer : session.writer)
            .post<Object?>(
              '${session.instance}/api/graphql',
              data: {'query': document, 'variables': vars},
            );
        if (variant == 'owned') {
          await request;
          expect(sends, 1);
        } else {
          await expectLater(request, throwsA(anything));
          expect(sends, 0, reason: '$kind/$variant');
          expect(session.quarantined, isTrue);
        }
        await session.finish();
      }
    }
  });

  test(
    'GID binding rejects a different resource type with the same ID',
    () async {
      for (final entry in {
        'Issue': 'merge_requests/44',
        'MergeRequest': 'issues/44',
        'WorkItem': 'issues/44',
        'Note': 'issues/44',
        'Project': 'issues/44',
      }.entries) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        final path = 'projects/909/${entry.value}';
        server.routes['GET $path'] = (_) =>
            mr7Json({'id': 44, 'project_id': 909});
        await expectLater(
          session.bindGraphResource('gid://gitlab/${entry.key}/44', path: path),
          throwsA(isA<Mr7Refused>()),
        );
        expect(server.requests, isNot(contains('GET $path')));
        await session.finish();
        expect(server.cleanupWrites, 0);
        expect(session.quarantined, isTrue);
      }
    },
  );

  test(
    'selected GraphQL mutation requires and charges a write permit',
    () async {
      const document =
          r'query Read($id: ID!) { synthetic(id: $id) { id } } '
          r'mutation Write($id: ID!) { synthetic(id: $id) { id } }';
      const vars = {'id': 'gid://gitlab/Project/909'};
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      server.routes['POST /install/api/graphql'] = (_) {
        server.scenarioWrites++;
        server.addEvent(target: 909);
        return mr7Json({'id': 909});
      };
      session.observerAdapter.graphReadDocuments = {
        document: {mr7Digest(vars)},
      };
      final permit = Mr7MutationPermit(
        operation: 'updateWorkItemState',
        paths: {'POST graphql'},
        resourceProjectId: 909,
        graphDocuments: {document},
        graphVariablesDigests: {mr7Digest(vars)},
      )..confirmed = true;
      session.permit = permit;
      await session.writer.post<Object?>(
        '${session.instance}/api/graphql',
        data: {'query': document, 'variables': vars, 'operationName': 'Write'},
      );
      expect(permit.sent, 1);
      expect(server.scenarioWrites, 1);
      expect(session.requestLedger.last['operation'], 'updateWorkItemState');
      session.permit = null;
      await session.finish();
    },
  );

  test('typed GID bindings retain their exact REST resource type', () async {
    const document = r'query X($id: ID!) { node(id: $id) { id } }';
    final server = Mr7SyntheticGitLab();
    final session = _session(server);
    await session.initialize();
    var sends = 0;
    server.routes['POST /install/api/graphql'] = (_) {
      sends++;
      return mr7Json({'id': 44});
    };
    for (final entry in {
      'Issue': 'issues/4',
      'MergeRequest': 'merge_requests/4',
      'Note': 'issues/4/notes/44',
      'Label': 'labels/44',
      'Milestone': 'milestones/44',
    }.entries) {
      final gid = 'gid://gitlab/${entry.key}/44';
      final path = 'projects/909/${entry.value}';
      server.routes['GET $path'] = (_) =>
          mr7Json({'id': 44, 'project_id': 909});
      await session.bindGraphResource(gid, path: path);
      final vars = {'id': gid};
      session.observerAdapter.graphReadDocuments = {
        document: {mr7Digest(vars)},
      };
      await session.observer.post<Object?>(
        '${session.instance}/api/graphql',
        data: {'query': document, 'variables': vars},
      );
    }
    expect(sends, 5);
    await session.finish();
    expect(session.cleanup['deletionVerified'], isTrue);
  });

  test(
    'registered graph digest cannot authorize foreign nested scope',
    () async {
      const doc =
          r'mutation X($input: Input!) { synthetic(input: $input) { id } }';
      for (final vars in <Map<String, Object?>>[
        {
          'input': {'projectId': 777},
        },
        {
          'input': {'groupId': 7},
        },
        {
          'input': {'targetId': 'gid://gitlab/Project/777'},
        },
        {
          'input': {'targetId': 'gid://gitlab/Issue/44'},
        },
        {
          'input': {'id': 44},
        },
        {
          'input': {'id': '44'},
        },
      ]) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        var sends = 0;
        server.routes['POST /install/api/graphql'] = (_) {
          sends++;
          return mr7Json({'id': 909});
        };
        session.permit = Mr7MutationPermit(
          operation: 'updateWorkItemState',
          paths: {'POST graphql'},
          resourceProjectId: 909,
          graphDocuments: {doc},
          graphVariablesDigests: {mr7Digest(vars)},
        )..confirmed = true;
        await expectLater(
          session.writer.post<Object?>(
            '${session.instance}/api/graphql',
            data: {'query': doc, 'variables': vars},
          ),
          throwsA(anything),
        );
        await session.finish();
        expect(sends, 0, reason: '$vars');
        expect(server.cleanupWrites, 0, reason: '$vars');
        expect(session.quarantined, isTrue, reason: '$vars');
      }
    },
  );

  test('bound graph resource ownership is rechecked before send', () async {
    const doc = r'mutation X($id: ID!) { synthetic(id: $id) { id } }';
    const gid = 'gid://gitlab/Issue/44';
    final vars = {'id': gid};
    for (final drift in [false, true]) {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      var owner = 909;
      var reads = 0;
      var sends = 0;
      server.routes['GET projects/909/issues/44'] = (_) {
        reads++;
        return mr7Json({'id': 44, 'project_id': owner});
      };
      server.routes['POST /install/api/graphql'] = (_) {
        sends++;
        return mr7Json({'id': 44, 'project_id': 909});
      };
      await session.bindGraphResource(gid, path: 'projects/909/issues/44');
      if (drift) owner = 777;
      session.permit = Mr7MutationPermit(
        operation: 'updateWorkItemState',
        paths: {'POST graphql'},
        resourceProjectId: 909,
        graphDocuments: {doc},
        graphVariablesDigests: {mr7Digest(vars)},
      )..confirmed = true;
      final request = session.writer.post<Object?>(
        '${session.instance}/api/graphql',
        data: {'query': doc, 'variables': vars},
      );
      if (drift) {
        await expectLater(request, throwsA(anything));
        expect(session.quarantined, isTrue);
      } else {
        await request;
      }
      expect(reads, greaterThanOrEqualTo(2));
      expect(sends, drift ? 0 : 1);
      await session.finish();
      if (drift) expect(server.cleanupWrites, 0);
    }
  });

  test('numeric graph target cannot reuse a typed GID binding', () async {
    const doc = r'mutation X($id: ID!) { synthetic(id: $id) { id } }';
    for (final id in <Object>[44, '44']) {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      server.routes['GET projects/909/issues/44'] = (_) =>
          mr7Json({'id': 44, 'project_id': 909});
      await session.bindGraphResource(
        'gid://gitlab/Issue/44',
        path: 'projects/909/issues/44',
      );
      var sends = 0;
      server.routes['POST /install/api/graphql'] = (_) {
        sends++;
        return mr7Json({'id': 44, 'project_id': 909});
      };
      final variables = {'id': id};
      session.permit = Mr7MutationPermit(
        operation: 'updateWorkItemState',
        paths: {'POST graphql'},
        resourceProjectId: 909,
        graphDocuments: {doc},
        graphVariablesDigests: {mr7Digest(variables)},
      )..confirmed = true;
      await expectLater(
        session.writer.post<Object?>(
          '${session.instance}/api/graphql',
          data: {'query': doc, 'variables': variables},
        ),
        throwsA(anything),
      );
      expect(sends, 0);
      await session.finish();
      expect(server.cleanupWrites, 0);
    }
  });

  test('stopped writer and observer enforce read boundaries', () async {
    const doc = r'query X($id: ID!) { synthetic(id: $id) { id } }';
    final vars = {'id': 'gid://gitlab/Project/909'};
    for (final invalidate in [false, true]) {
      var valid = true;
      final server = Mr7SyntheticGitLab();
      final session = Mr7SandboxSession(
        server: server,
        nonce: 'testnonce123',
        boundaryValid: () => valid,
      );
      await session.initialize();
      session.observerAdapter.graphReadDocuments = {
        doc: {mr7Digest(vars)},
      };
      server.routes['POST /install/api/graphql'] = (_) => mr7Json({'id': 909});
      session.stop('test');
      if (invalidate) valid = false;
      await expectLater(
        session.writer.get<Object?>('projects/909'),
        throwsA(anything),
      );
      await expectLater(
        session.writer.post<Object?>(
          '${session.instance}/api/graphql',
          data: {'query': doc, 'variables': vars},
        ),
        throwsA(anything),
      );
      if (invalidate) {
        await expectLater(
          session.observer.get<Object?>('projects/909'),
          throwsA(anything),
        );
      } else {
        expect(
          (await session.observer.get<Object?>('projects/909')).statusCode,
          200,
        );
        expect(
          (await session.observer.get<Object?>('users/7/events')).statusCode,
          200,
        );
      }
      for (final path in ['projects/777', 'groups/7', 'users/8/events']) {
        server.routes['GET $path'] = (_) => mr7Json({'id': 777});
        await expectLater(
          session.observer.get<Object?>(path),
          throwsA(anything),
        );
        expect(server.requests, isNot(contains('GET $path')));
      }
      await session.finish();
      expect(server.cleanupWrites, 0);
    }
  });

  test('no-op and certain HTTP failure allow following scenario', () async {
    final noOp = sandbox.Mr7Scenario(
      id: 'noop',
      suite: 'rest',
      operation: 'setStar',
      variant: 'noop',
      tier: 'T1',
      expectedMutations: 0,
      freshness: (session, _) async {
        final project = await session.read('projects/909');
        return AiWriteFreshness(
          noChange: project['starred'] == false,
          visibilityUnreadable: false,
          sourceVisibilityUnreadable: false,
          targetVisibility: 'private',
        );
      },
      call: (p) => AiToolCall(
        id: 'noop',
        name: 'setStar',
        arguments: {
          'projectId': p.projectId,
          'starred': false,
          'reason': 'Synthetic no-op.',
        },
      ),
      paths: (p) => {'POST projects/${p.projectId}/unstar'},
      observe: (_, _) async => false,
    );
    final noOpServer = Mr7SyntheticGitLab();
    final noOpReceipt = await sandbox.runMr7Sandbox(
      policy: Mr7Policy.candidate,
      releaseSha: _sha,
      session: _session(noOpServer),
      scenarios: [noOp, _star('after-noop')],
      confirm: (_) async => true,
    );
    expect(
      _rows(noOpReceipt).first['status'],
      'PASS',
      reason: jsonEncode(noOpReceipt),
    );
    expect(_rows(noOpReceipt).first['outcome'], 'noChange');
    expect(
      _rows(noOpReceipt).last['status'],
      'PASS',
      reason: jsonEncode(noOpReceipt),
    );
    expect(noOpServer.scenarioWrites, 1);
    final failedServer = Mr7SyntheticGitLab();
    var sends = 0;
    failedServer.routes['POST projects/909/star'] = (_) {
      sends++;
      if (sends == 1) return mr7Json({'message': 'rejected'}, status: 400);
      failedServer.scenarioWrites++;
      failedServer.project!['starred'] = true;
      failedServer.addEvent(target: 909, action: 'updated');
      return mr7Json(failedServer.project);
    };
    final failedReceipt = await sandbox.runMr7Sandbox(
      policy: Mr7Policy.candidate,
      releaseSha: _sha,
      session: _session(failedServer),
      scenarios: [_star('rejected'), _star('after-rejected')],
      confirm: (_) async => true,
    );
    expect(
      _rows(failedReceipt).first['status'],
      'FAIL',
      reason: jsonEncode(failedReceipt),
    );
    expect(_rows(failedReceipt).first['outcome'], 'failedCertain');
    expect(
      _rows(failedReceipt).last['status'],
      'PASS',
      reason: jsonEncode(failedReceipt),
    );
    expect(sends, 2);
  });
  test(
    'production policy is the production view and candidate is never final',
    () async {
      expect(
        identical(
          mr7SandboxPolicy(Mr7Policy.production),
          productionAiReleasePolicy,
        ),
        isTrue,
      );
      final server = Mr7SyntheticGitLab();
      final receipt = await sandbox.runMr7Sandbox(
        releaseSha: _sha,
        session: _session(server),
        confirm: (_) async => true,
      );
      expect(receipt['policy'], 'production');
      expect(receipt['evidenceClass'], 'SYNTHETIC');
      expect(receipt['finalEligible'], isFalse);
      expect(receipt['live'], 'NOT_RUN');
      expect(_rows(receipt).single['status'], 'NOT_RUN');
      expect(_rows(receipt).single['reason'], 'releaseClosed');
      expect(server.scenarioWrites, 0);
    },
  );

  test(
    'candidate writes through a synthetic provider and independent observer',
    () async {
      final server = Mr7SyntheticGitLab();
      final receipt = await sandbox.runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(server),
        confirm: (_) async => true,
      );
      final row = _rows(receipt).single;
      expect(receipt['status'], 'PASS', reason: jsonEncode(receipt));
      expect(receipt['evidenceClass'], 'CANDIDATE_ONLY');
      expect(receipt['finalEligible'], isFalse);
      expect(row['status'], 'PASS');
      expect(row['readback'], 'PASS');
      expect(row['observerRequests'], greaterThan(0));
      expect(server.scenarioWrites, 1);
      expect(server.cleanupWrites, 1);
      expect(_part(receipt, 'cleanup')['deletionVerified'], isTrue);
    },
  );

  test('mismatched returned ID cannot establish readback', () async {
    final server = Mr7SyntheticGitLab()..wrongWriteReply = true;
    final receipt = await sandbox.runMr7Sandbox(
      policy: Mr7Policy.candidate,
      releaseSha: _sha,
      session: _session(server),
      confirm: (_) async => true,
    );
    expect(
      _rows(receipt).single['status'],
      'NOT_VERIFIED',
      reason: jsonEncode(receipt),
    );
    expect(server.scenarioWrites, 1);
    expect(server.cleanupWrites, 0);
    expect(receipt['quarantined'], isTrue);
  });

  test('identity drift blocks final write', () async {
    for (final field in ['id', 'path_with_namespace', 'owner']) {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      server.byPathOverride = {
        ...server.project!,
        field: switch (field) {
          'id' => 1234,
          'owner' => {'id': 44},
          _ => 'another/project',
        },
      };
      session.permit = _starPermit(session.identity!);
      await expectLater(
        session.writer.post<Object?>('projects/909/star'),
        throwsA(anything),
      );
      await session.finish();
      expect(server.scenarioWrites, 0, reason: field);
      expect(server.cleanupWrites, 0, reason: field);
      expect(session.quarantined, isTrue, reason: field);
    }
  });

  test(
    'identity drift after confirmation stops before the final transport send',
    () async {
      final server = Mr7SyntheticGitLab();
      var asked = false;
      final receipt = await sandbox.runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(server),
        confirm: (_) async {
          asked = true;
          server.byPathOverride = {
            ...server.project!,
            'owner': {'id': 44},
          };
          return true;
        },
      );
      expect(asked, isTrue, reason: jsonEncode(receipt));
      expect(server.scenarioWrites, 0, reason: jsonEncode(receipt));
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
      expect(_rows(receipt).single['status'], isNot('PASS'));
    },
  );

  test(
    'mismatched owner user and namespace refuse before sandbox setup',
    () async {
      for (final server in [
        Mr7SyntheticGitLab(userId: 8),
        Mr7SyntheticGitLab(namespace: 'other'),
      ]) {
        final session = _session(server);
        await expectLater(session.initialize(), throwsA(anything));
        await session.finish();
        expect(server.setupWrites, 0);
        expect(server.scenarioWrites, 0);
        expect(server.cleanupWrites, 0);
      }
    },
  );

  test(
    'explicit rejection and an unconfirmed permit cause zero scenario writes',
    () async {
      final rejectedServer = Mr7SyntheticGitLab();
      final result = await sandbox.runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(rejectedServer),
        confirm: (_) async => false,
      );
      expect(
        _rows(result).single['outcome'],
        'notExecuted',
        reason: jsonEncode(result),
      );
      expect(_rows(result).single['confirmation'], 'rejected');
      expect(_rows(result).single['status'], 'NOT_RUN');
      expect(rejectedServer.scenarioWrites, 0);
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      session.permit = Mr7MutationPermit(
        operation: 'setStar',
        paths: {'POST projects/909/star'},
        resourceProjectId: 909,
      );
      await expectLater(
        session.writer.post<Object?>('projects/909/star'),
        throwsA(anything),
      );
      expect(server.scenarioWrites, 0);
      await session.finish();
      expect(server.cleanupWrites, 0);
    },
  );

  test('observer client rejects all writes', () async {
    final server = Mr7SyntheticGitLab();
    final session = _session(server);
    await session.initialize();
    expect(identical(session.observerAdapter, session.writerAdapter), isFalse);
    await expectLater(
      session.observer.post<Object?>('projects/909/star'),
      throwsA(anything),
    );
    expect(server.scenarioWrites, 0);
    await session.finish();
  });

  test(
    'events baseline precedes setup and paged final window includes cleanup',
    () async {
      final server = Mr7SyntheticGitLab()..eventPageSize = 1;
      final session = _session(server);
      await session.initialize();
      session.permit = _starPermit(session.identity!);
      await session.writer.post<Object?>('projects/909/star');
      await session.checkIsolation();
      await session.finish();
      final firstEvents = server.requests.indexOf('GET users/7/events');
      final setup = server.requests.indexOf('POST projects');
      final cleanup = server.requests.indexOf('DELETE projects/909');
      final lastEvents = server.requests.lastIndexOf('GET users/7/events');
      expect(firstEvents, greaterThanOrEqualTo(0));
      expect(firstEvents, lessThan(setup));
      expect(lastEvents, greaterThan(cleanup));
      expect(session.isolation['status'], 'PASS');
      expect(session.isolation['complete'], isTrue);
      expect(session.isolation['pages'], greaterThanOrEqualTo(6));
      expect(
        session.observedEvents.map((e) => e['action']),
        containsAll(['created', 'updated', 'removed']),
      );
    },
  );

  test(
    'foreign or account-wide event prevents cleanup and isolation proof',
    () async {
      for (final int? target in [777, null]) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        server.addEvent(target: target);
        await expectLater(session.checkIsolation(), throwsA(anything));
        await session.finish();
        expect(session.isolation['status'], 'NOT_VERIFIED');
        expect(session.quarantined, isTrue);
        expect(server.cleanupWrites, 0);
      }
    },
  );

  test('incomplete or rate-limited event pages prevent setup', () async {
    for (final server in [
      Mr7SyntheticGitLab()..incompleteEvents = true,
      Mr7SyntheticGitLab()..unreadableEvents = true,
    ]) {
      final session = _session(server);
      await expectLater(session.initialize(), throwsA(anything));
      await session.finish();
      expect(server.setupWrites, 0);
      expect(session.isolation['status'], 'NOT_VERIFIED');
      expect(session.quarantined, isTrue);
    }
  });

  test('delayed second events read cannot hide a foreign event', () async {
    final server = Mr7SyntheticGitLab();
    var inject = false;
    final session = _session(
      server,
      eventDelay: () async {
        if (inject) {
          inject = false;
          server.addEvent(target: 42);
        }
      },
    );
    await session.initialize();
    inject = true;
    await expectLater(session.checkIsolation(), throwsA(anything));
    await session.finish();
    expect(session.isolation['status'], 'NOT_VERIFIED');
    expect(server.cleanupWrites, 0);
  });

  test('cleanup rejects foreign project', () async {
    final server = Mr7SyntheticGitLab();
    final session = _session(server);
    await session.initialize();
    final actual = session.identity!;
    final foreign = Mr7Identity(
      projectId: 1234,
      path: actual.path,
      userId: actual.userId,
      namespaceId: actual.namespaceId,
      namespace: actual.namespace,
      nonce: actual.nonce,
    );
    expect(session.cleanupAllowed(foreign), isFalse);
    session.identity = foreign;
    await session.finish();
    expect(server.cleanupWrites, 0);
    expect(session.cleanup['status'], 'NOT_RUN');
  });

  test('protected project ID is never eligible for sandbox cleanup', () async {
    final server = Mr7SyntheticGitLab()..projectId = mr7ProtectedProjectId;
    final session = _session(server);
    await expectLater(session.initialize(), throwsA(anything));
    await session.finish();
    expect(server.scenarioWrites, 0);
    expect(server.cleanupWrites, 0);
    expect(session.quarantined, isTrue);
  });

  test('cleanup acceptance and actual deletion are separate', () async {
    final server = Mr7SyntheticGitLab()..delayedDeletion = true;
    final session = _session(server);
    await session.initialize();
    await session.finish();
    expect(server.cleanupWrites, 1);
    expect(session.cleanup['accepted'], isTrue);
    expect(session.cleanup['status'], 'PENDING');
    expect(session.cleanup['deletionVerified'], isFalse);
    expect(session.quarantined, isTrue);
  });

  test('events failure after cleanup cannot produce isolation PASS', () async {
    final server = Mr7SyntheticGitLab();
    final session = _session(server);
    await session.initialize();
    server.routes['DELETE projects/909'] = (_) {
      server.cleanupWrites++;
      server.addEvent(target: 909, action: 'removed');
      server.project = null;
      server.incompleteEvents = true;
      return mr7Json({}, status: 202);
    };
    await session.finish();
    expect(server.cleanupWrites, 1);
    expect(session.cleanup['accepted'], isTrue);
    expect(session.isolation['status'], 'NOT_VERIFIED');
    expect(session.quarantined, isTrue);
  });

  test(
    'an event read failure stays unverified even if later reads recover',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      server.incompleteEvents = true;
      await expectLater(session.checkIsolation(), throwsA(anything));
      server.incompleteEvents = false;
      await session.finish();
      expect(session.isolation['status'], 'NOT_VERIFIED');
      expect(session.isolation['complete'], isFalse);
      expect(server.cleanupWrites, 0);
      expect(session.quarantined, isTrue);
    },
  );

  test('each mutation rechecks sandbox identity', () async {
    final server = Mr7SyntheticGitLab();
    final session = _session(server);
    await session.initialize();
    session.permit = Mr7MutationPermit(
      operation: 'setStar',
      resourceProjectId: 909,
      maxMutations: 2,
      paths: {'POST projects/909/star', 'POST projects/909/unstar'},
    )..confirmed = true;
    await session.writer.post<Object?>('projects/909/star');
    server.byPathOverride = {...server.project!, 'id': 2222};
    await expectLater(
      session.writer.post<Object?>('projects/909/unstar'),
      throwsA(anything),
    );
    await session.finish();
    expect(server.scenarioWrites, 1);
    expect(server.cleanupWrites, 0);
    expect(session.quarantined, isTrue);
  });

  test('finish while identity read is pending prevents a later send', () async {
    final server = Mr7SyntheticGitLab();
    final session = _session(server);
    await session.initialize();
    session.permit = _starPermit(session.identity!);
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    server.routes['GET projects/909'] = (_) async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
      return mr7Json(server.project);
    };
    final sending = session.writer.post<Object?>('projects/909/star');
    final failure = expectLater(sending, throwsA(anything));
    await entered.future.timeout(const Duration(seconds: 5));
    await session.finish();
    expect(server.scenarioWrites, 0);
    expect(server.cleanupWrites, 0);
    expect(session.quarantined, isTrue);
    release.complete();
    await failure;
    expect(server.scenarioWrites, 0);
    expect(server.cleanupWrites, 0);
  });

  test('fork path is forbidden even with a scoped permit', () async {
    final server = Mr7SyntheticGitLab();
    final session = _session(server);
    await session.initialize();
    session.permit = Mr7MutationPermit(
      operation: 'setStar',
      paths: {'POST projects/909/fork'},
      resourceProjectId: 909,
    )..confirmed = true;
    await expectLater(
      session.writer.post<Object?>('projects/909/fork'),
      throwsA(anything),
    );
    await session.finish();
    expect(server.requests, isNot(contains('POST projects/909/fork')));
    expect(server.cleanupWrites, 0);
    expect(session.quarantined, isTrue);
  });

  test(
    'GraphQL requires the registered document, variables and project',
    () async {
      const document = 'mutation X(\$id: ID!) { synthetic(id: \$id) { id } }';
      final variables = {'id': 'gid://gitlab/Project/909'};
      for (final variant in ['allowed', 'document', 'variables', 'project']) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        var sends = 0;
        server.routes['POST /install/api/graphql'] = (_) {
          sends++;
          return mr7Json({'id': 909});
        };
        session.permit = Mr7MutationPermit(
          operation: 'updateWorkItemState',
          paths: {'POST graphql'},
          resourceProjectId: variant == 'project' ? 777 : 909,
          graphDocuments: {document},
          graphVariablesDigests: {mr7Digest(variables)},
        )..confirmed = true;
        final request = session.writer.post<Object?>(
          '${session.instance}/api/graphql',
          data: {
            'query': variant == 'document' ? '$document ' : document,
            'variables': variant == 'variables'
                ? {'id': 'gid://gitlab/Project/777'}
                : variables,
          },
        );
        if (variant == 'allowed') {
          await request;
          expect(sends, 1);
        } else {
          await expectLater(request, throwsA(anything));
          expect(sends, 0, reason: variant);
          expect(session.quarantined, isTrue, reason: variant);
        }
        await session.finish();
        if (variant != 'allowed') {
          expect(server.cleanupWrites, 0, reason: variant);
        }
      }
    },
  );

  test(
    'request budget includes observer reads and stops further requests',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = Mr7SandboxSession(
        server: server,
        nonce: 'testnonce123',
        requestCap: 16,
      );
      await session.initialize();
      var refused = false;
      for (var i = 0; i < 20; i++) {
        try {
          await session.read('projects/909');
        } catch (_) {
          refused = true;
          break;
        }
      }
      expect(refused, isTrue);
      expect(server.requests.length, lessThanOrEqualTo(16));
      expect(session.quarantined, isTrue);
      await session.finish();
      expect(server.cleanupWrites, 0);
    },
  );

  test(
    'lost account or consent boundary stops writes and preserves sandbox',
    () async {
      var current = true;
      final server = Mr7SyntheticGitLab();
      final session = Mr7SandboxSession(
        server: server,
        nonce: 'testnonce123',
        boundaryValid: () => current,
      );
      await session.initialize();
      session.permit = _starPermit(session.identity!);
      current = false;
      await expectLater(
        session.writer.post<Object?>('projects/909/star'),
        throwsA(anything),
      );
      await session.finish();
      expect(server.scenarioWrites, 0);
      expect(server.cleanupWrites, 0);
      expect(session.quarantined, isTrue);
    },
  );

  test('owner confirmation is additional for bypass autonomy', () async {
    final server = Mr7SyntheticGitLab();
    var confirmations = 0;
    final receipt = await sandbox.runMr7Sandbox(
      policy: Mr7Policy.candidate,
      releaseSha: _sha,
      session: _session(server),
      level: AiAutonomyLevel.bypass,
      confirm: (_) async {
        confirmations++;
        return true;
      },
    );
    expect(confirmations, 1, reason: jsonEncode(receipt));
    expect(server.scenarioWrites, 1);
    expect(_rows(receipt).single['status'], 'PASS');
  });

  test('journal uncertainty alone stops later scenarios and cleanup', () async {
    final server = Mr7SyntheticGitLab();
    final session = _session(server);
    var acknowledged = 0;
    var readbacks = 0;
    String? stopAtReadback;
    server.routes['POST projects/909/issues'] = (_) {
      acknowledged++;
      server.scenarioWrites++;
      server.addEvent(target: 909);
      return mr7Json({'id': 44, 'iid': 4, 'project_id': 909}, status: 201);
    };
    server.routes['GET projects/909/issues/4'] = (_) {
      readbacks++;
      stopAtReadback = session.stopReason;
      return mr7Json({'message': 'not found'}, status: 404);
    };
    final issue = sandbox.Mr7Scenario(
      id: 'uncertain-issue',
      suite: 'rest',
      operation: 'createIssue',
      variant: 'readback-failed',
      tier: 'T1',
      utterance: (p) => 'Create an issue in ${p.path}.',
      call: (p) => AiToolCall(
        id: 'uncertain-issue',
        name: 'createIssue',
        arguments: {
          'projectId': p.projectId,
          'fields': {'title': 'synthetic issue'},
          'reason': 'The user requested this issue.',
        },
      ),
      paths: (p) => {'POST projects/${p.projectId}/issues'},
      observe: (_, _) async => false,
    );
    final receipt = await sandbox.runMr7Sandbox(
      policy: Mr7Policy.candidate,
      releaseSha: _sha,
      session: session,
      scenarios: [issue, _star('after-journal-uncertainty')],
      confirm: (_) async => true,
    );
    final rows = _rows(receipt);
    expect(acknowledged, 1, reason: jsonEncode(receipt));
    expect(readbacks, 1, reason: jsonEncode(receipt));
    expect(stopAtReadback, isNull);
    expect(
      rows.first['outcome'],
      'writeUncertain',
      reason: jsonEncode(receipt),
    );
    expect(rows.first['status'], 'writeUncertain');
    expect(rows.last['status'], 'NOT_RUN');
    expect(rows.last['mutationCount'], 0);
    expect(server.scenarioWrites, 1);
    expect(server.cleanupWrites, 0);
    expect(receipt['quarantined'], isTrue);
  });

  test('writeUncertain stops remaining scenarios', () async {
    final server = Mr7SyntheticGitLab()..lostWriteReply = true;
    final receipt = await sandbox.runMr7Sandbox(
      policy: Mr7Policy.candidate,
      releaseSha: _sha,
      session: _session(server),
      scenarios: [_star('first'), _star('second')],
      confirm: (_) async => true,
    );
    final rows = _rows(receipt);
    expect(rows.first['status'], 'writeUncertain', reason: jsonEncode(receipt));
    expect(rows.last['status'], 'NOT_RUN');
    expect(rows.last['mutationCount'], 0);
    expect(server.scenarioWrites, 1);
    expect(server.cleanupWrites, 0);
    expect(receipt['quarantined'], isTrue);
  });

  test(
    'final transport rejects a different project despite an explicit permit',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      session.permit = Mr7MutationPermit(
        operation: 'setStar',
        paths: {'POST projects/777/star'},
        resourceProjectId: 777,
      )..confirmed = true;
      await expectLater(
        session.writer.post<Object?>('projects/777/star'),
        throwsA(isA<DioException>()),
      );
      expect(server.scenarioWrites, 0);
      await session.finish();
      expect(server.cleanupWrites, 0);
    },
  );
}
