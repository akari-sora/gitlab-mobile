import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/release_policy.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';

import '../../tool/mr7/sandbox_contract.dart';
import '../../tool/mr7_sandbox.dart' as sandbox;
import 'mr7_sandbox_wave2_contract_test.dart' as wave2_contract;
import 'mr7_sandbox_wave2_runner_test.dart' as wave2_runner;

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

Future<({Mr7SandboxSession session, Mr7Readback observer})> _observationFixture(
  Mr7SyntheticGitLab server, {
  Object? response = const {},
  int status = 204,
  String operation = 'createNote',
  required Set<String> paths,
  Map<String, Set<String>> queries = const {},
  String mutationPath = 'projects/909/issues/3/notes',
  String method = 'POST',
  Object? body,
  Future<void> Function(Mr7SandboxSession)? beforeSend,
}) async {
  final session = _session(server, eventDelay: () async {});
  await session.initialize();
  if (beforeSend != null) await beforeSend(session);
  final permit = Mr7MutationPermit(
    operation: operation,
    resourceProjectId: 909,
    paths: {'$method ${Uri.decodeComponent(mutationPath)}'},
  )..confirmed = true;
  session.permit = permit;
  server.routes['$method ${Uri.decodeComponent(mutationPath)}'] = (_) {
    server.scenarioWrites++;
    server.addEvent(target: 909);
    return mr7Json(response, status: status);
  };
  await session.writer.request<Object?>(
    mutationPath,
    data: body,
    options: Options(method: method),
  );
  session.observerAdapter.graphReadDocuments = queries;
  return (
    session: session,
    observer: Mr7Readback(
      session,
      session.identity!,
      permit,
      paths: paths,
      graphQueries: queries,
    ),
  );
}

const _issueParent = Mr7Parent.issue(id: 300, iid: 3);
const _mrParent = Mr7Parent.mergeRequest(id: 400, iid: 4);
Map<String, Object?> _issueRow() => {'id': 300, 'iid': 3, 'project_id': 909};
Map<String, Object?> _mrRow() => {
  'id': 400,
  'iid': 4,
  'project_id': 909,
  'state': 'opened',
  'sha': _sha,
  'source_branch': 'fixture',
  'target_branch': 'main',
  'merge_when_pipeline_succeeds': true,
  'author': {'id': 7},
  'user': {'can_merge': true},
};

sandbox.Mr7Scenario _starNoChange({
  bool includeObserver = true,
  bool wrongState = false,
}) => sandbox.Mr7Scenario(
  id: 'already-unstarred',
  suite: 'rest',
  operation: 'setStar',
  variant: '304',
  tier: 'T1',
  call: (p) => AiToolCall(
    id: 'already-unstarred',
    name: 'setStar',
    arguments: {
      'projectId': p.projectId,
      'starred': false,
      'reason': 'Keep synthetic project unstarred.',
    },
  ),
  paths: (p) => {'POST projects/${p.projectId}/unstar'},
  noChangeObservation: includeObserver
      ? (_) => Mr7ParentStateObservation(
          parent: const Mr7Parent.project(),
          state: Mr7ParentState.starred,
          expected: wrongState,
        )
      : null,
  observe: (_, _) async => true,
);

void main() {
  wave2_contract.main();
  wave2_runner.main();
  test(
    'sealed Graph reaction removal cannot trust a returned child alone',
    () async {
      const mutation =
          r'mutation Remove($input: AwardEmojiRemoveInput!) { awardEmojiRemove(input: $input) { awardEmoji { id } errors } }';
      const document =
          r'query Observe($id: ID!) { currentUser { id username } node(id: $id) { id project { id fullPath } awardEmoji { nodes { id note { id } } totalCount pageInfo { hasNextPage endCursor } } } }';
      const note = 'gid://gitlab/Note/71';
      final input = <String, Object?>{
        'input': {'awardableId': note, 'name': 'thumbsup'},
      };
      final variables = {'id': note};
      final queries = {
        document: {mr7Digest(variables)},
      };
      final server = Mr7SyntheticGitLab();
      server.routes['GET projects/909/issues/3'] = (_) => mr7Json(_issueRow());
      server.routes['GET projects/909/issues/3/notes/71'] = (_) =>
          mr7Json({'id': 71, 'project_id': 909, 'noteable_id': 300});
      final session = _session(server, eventDelay: () async {});
      await session.initialize();
      await session.bindGraphResource(
        note,
        path: 'projects/909/issues/3/notes/71',
      );
      server.routes['POST /install/api/graphql'] = (request) {
        if ((request.data as Map)['query'] == mutation) {
          server.scenarioWrites++;
          server.addEvent(target: 909);
          return mr7Json({
            'data': {
              'awardEmojiRemove': {
                'awardEmoji': {'id': 'gid://gitlab/AwardEmoji/90'},
                'errors': <Object?>[],
              },
            },
          });
        }
        return mr7Json({
          'data': {
            'currentUser': {
              'id': 'gid://gitlab/User/7',
              'username': 'synthetic-owner',
            },
            'node': {
              'id': note,
              'project': {
                'id': 'gid://gitlab/Project/909',
                'fullPath': 'synthetic-owner/mr7-testnonce123',
              },
              'awardEmoji': {
                'nodes': <Map<String, Object?>>[],
                'totalCount': 0,
                'pageInfo': {'hasNextPage': false, 'endCursor': null},
              },
            },
          },
        });
      };
      final permit = Mr7MutationPermit(
        operation: 'removeAwardEmoji',
        resourceProjectId: 909,
        paths: {'POST graphql'},
        graphDocuments: {mutation},
        graphVariablesDigests: {mr7Digest(input)},
        resultPath: ['data', 'awardEmojiRemove', 'awardEmoji'],
      )..confirmed = true;
      session.permit = permit;
      await session.writer.post<Object?>(
        '${session.instance}/api/graphql',
        data: {'query': mutation, 'variables': input},
      );
      expect(permit.sent, 1);
      session.observerAdapter.graphReadDocuments = queries;
      final observer = Mr7Readback(
        session,
        session.identity!,
        permit,
        paths: {'projects/909/issues/3/notes/71'},
        graphQueries: queries,
      );
      expect(observer.result.stringId, 'gid://gitlab/AwardEmoji/90');
      await expectLater(
        observer.observe(
          Mr7GraphObservation(
            document: document,
            variables: variables,
            parentId: note,
            recordPath: ['data', 'node'],
            connectionPath: ['awardEmoji'],
            expectedIds: {},
            absentIds: {'gid://gitlab/AwardEmoji/90'},
            noteId: note,
          ),
        ),
        throwsA(anything),
      );
      expect(observer.verifiedRequests, 0);
      session.stop('testObservationFailed');
      session.permit = null;
      await session.finish();
      expect(server.scenarioWrites, 1);
      expect(server.cleanupWrites, 0);
    },
  );
  test('unmapped Graph child operation cannot use parent-only witness', () async {
    const document =
        r'query Observe($id: ID!) { currentUser { id username } node(id: $id) { id project { id fullPath } } }';
    const gid = 'gid://gitlab/Issue/300';
    final variables = {'id': gid};
    final queries = {
      document: {mr7Digest(variables)},
    };
    final server = Mr7SyntheticGitLab();
    server.routes['GET projects/909/issues/3'] = (_) => mr7Json(_issueRow());
    server.routes['POST /install/api/graphql'] = (_) => mr7Json({
      'data': {
        'currentUser': {
          'id': 'gid://gitlab/User/7',
          'username': 'synthetic-owner',
        },
        'node': {
          'id': gid,
          'project': {
            'id': 'gid://gitlab/Project/909',
            'fullPath': 'synthetic-owner/mr7-testnonce123',
          },
        },
      },
    });
    final fixture = await _observationFixture(
      server,
      operation: 'createDiscussion',
      status: 201,
      response: {'id': 'discussion-1'},
      mutationPath: 'projects/909/issues/3/discussions',
      paths: {'projects/909/issues/3'},
      queries: queries,
      beforeSend: (session) =>
          session.bindGraphResource(gid, path: 'projects/909/issues/3'),
    );
    await expectLater(
      fixture.observer.observe(
        Mr7GraphObservation(
          document: document,
          variables: variables,
          recordPath: ['data', 'node'],
          parentId: gid,
        ),
      ),
      throwsA(anything),
    );
    expect(fixture.observer.verifiedRequests, 0);
    fixture.session.stop('testObservationFailed');
    await fixture.session.finish();
    expect(server.cleanupWrites, 0);
  });

  test(
    'sealed Graph note creation binds input parent and returned child',
    () async {
      const mutation =
          r'mutation Create($input: CreateNoteInput!) { createNote(input: $input) { note { id } errors } }';
      const document =
          r'query Observe($id: ID!) { currentUser { id username } node(id: $id) { id project { id fullPath } notes { nodes { id } totalCount pageInfo { hasNextPage endCursor } } } }';
      const parent = 'gid://gitlab/Issue/300';
      for (final variant in ['matching', 'differentParent', 'reboundParent']) {
        final inputParent = variant == 'differentParent'
            ? 'gid://gitlab/Issue/301'
            : parent;
        final input = <String, Object?>{
          'input': {'noteableId': inputParent, 'body': 'synthetic'},
        };
        final variables = {'id': parent};
        final queries = {
          document: {mr7Digest(variables)},
        };
        final server = Mr7SyntheticGitLab();
        server.routes['GET projects/909/issues/3'] = (_) =>
            mr7Json(_issueRow());
        server.routes['GET projects/909/issues/4'] = (_) =>
            mr7Json({'id': 301, 'iid': 4, 'project_id': 909});
        final session = _session(server, eventDelay: () async {});
        await session.initialize();
        await session.bindGraphResource(parent, path: 'projects/909/issues/3');
        await session.bindGraphResource(
          'gid://gitlab/Issue/301',
          path: 'projects/909/issues/4',
        );
        server.routes['POST /install/api/graphql'] = (request) {
          final body = request.data as Map;
          if (body['query'] == mutation) {
            server.scenarioWrites++;
            server.addEvent(target: 909);
            return mr7Json({
              'data': {
                'createNote': {
                  'note': {'id': 'gid://gitlab/Note/71'},
                  'errors': <Object?>[],
                },
              },
            });
          }
          return mr7Json({
            'data': {
              'currentUser': {
                'id': 'gid://gitlab/User/7',
                'username': 'synthetic-owner',
              },
              'node': {
                'id': parent,
                'project': {
                  'id': 'gid://gitlab/Project/909',
                  'fullPath': 'synthetic-owner/mr7-testnonce123',
                },
                'notes': {
                  'nodes': [
                    {'id': 'gid://gitlab/Note/71'},
                  ],
                  'totalCount': 1,
                  'pageInfo': {'hasNextPage': false, 'endCursor': null},
                },
              },
            },
          });
        };
        final permit = Mr7MutationPermit(
          operation: 'createNote',
          resourceProjectId: 909,
          paths: {'POST graphql'},
          graphDocuments: {mutation},
          graphVariablesDigests: {mr7Digest(input)},
          resultPath: ['data', 'createNote', 'note'],
        )..confirmed = true;
        session.permit = permit;
        await session.writer.post<Object?>(
          '${session.instance}/api/graphql',
          data: {'query': mutation, 'variables': input},
        );
        expect(permit.sent, 1);
        expect(server.scenarioWrites, 1);
        if (variant == 'reboundParent') {
          server.routes['GET projects/909/issues/4'] = (_) =>
              mr7Json({'id': 300, 'iid': 4, 'project_id': 909});
          await session.bindGraphResource(
            parent,
            path: 'projects/909/issues/4',
          );
        }
        session.observerAdapter.graphReadDocuments = queries;
        final observer = Mr7Readback(
          session,
          session.identity!,
          permit,
          paths: {'projects/909/issues/3'},
          graphQueries: queries,
        );
        expect(observer.result.stringId, 'gid://gitlab/Note/71');
        final observing = observer.observe(
          Mr7GraphObservation(
            document: document,
            variables: variables,
            parentId: parent,
            recordPath: ['data', 'node'],
            connectionPath: ['notes'],
            expectedIds: {'gid://gitlab/Note/71'},
          ),
        );
        if (variant == 'matching') {
          await observing;
          expect(observer.verifiedRequests, greaterThan(0));
        } else {
          await expectLater(observing, throwsA(anything));
          expect(observer.verifiedRequests, 0);
          session.stop('testObservationFailed');
        }
        session.permit = null;
        await session.finish();
        if (variant != 'matching') expect(server.cleanupWrites, 0);
      }
    },
  );

  for (final resource in ['issues', 'merge_requests']) {
    final issue = resource == 'issues';
    final iid = issue ? 3 : 4;
    final type = issue ? 'Issue' : 'MergeRequest';
    for (final invalid in <String, Object?>{
      'missing': null,
      'mismatched': iid + 1,
      'zero': 0,
      'negative': -1,
      'double': iid.toDouble(),
      'string': '$iid',
    }.entries) {
      test(
        'Graph $type binding rejects ${invalid.key} iid and stops later scenarios',
        () async {
          final server = Mr7SyntheticGitLab();
          final path = 'projects/909/$resource/$iid';
          final gid = 'gid://gitlab/$type/${issue ? 300 : 400}';
          server.routes['GET $path'] = (_) => mr7Json({
            'id': issue ? 300 : 400,
            'project_id': 909,
            if (invalid.value != null) 'iid': invalid.value,
          });
          final session = _session(server, eventDelay: () async {});
          final star = _star('bind-graph-resource');
          Future<void>? binding;
          final receipt = await sandbox.runMr7Sandbox(
            policy: Mr7Policy.candidate,
            releaseSha: _sha,
            session: session,
            scenarios: [
              sandbox.Mr7Scenario(
                id: star.id,
                suite: star.suite,
                operation: star.operation,
                variant: invalid.key,
                tier: star.tier,
                call: star.call,
                paths: star.paths,
                observe: (observer, identity) async {
                  binding = session.bindGraphResource(gid, path: path);
                  await binding;
                  return (await observer.read(
                        'projects/${identity.projectId}',
                      ))['starred'] ==
                      true;
                },
              ),
              _star('after-rejected-binding'),
            ],
            confirm: (_) async => true,
          );
          expect(binding, isNotNull, reason: jsonEncode(receipt));
          await expectLater(
            binding!,
            throwsA(
              isA<Mr7Refused>().having(
                (e) => e.code,
                'code',
                'foreignResource',
              ),
            ),
          );
          final rows = _rows(receipt);
          expect(rows.first['mutationCount'], 1);
          expect(rows.first['status'], 'NOT_VERIFIED');
          expect(rows.first['readback'], 'NOT_VERIFIED');
          expect(rows.last['status'], 'NOT_RUN');
          expect(rows.last['mutationCount'], 0);
          expect(session.stopReason, 'foreignResource');
          expect(receipt['quarantined'], isTrue);
          expect(server.scenarioWrites, 1);
          expect(server.cleanupWrites, 0);
        },
      );
    }
  }

  test(
    'Graph deletion trusts dispatch binding instead of returned iid and ID',
    () async {
      for (final resource in ['issues', 'merge_requests']) {
        final issue = resource == 'issues';
        final iid = issue ? 3 : 4;
        final type = issue ? 'Issue' : 'MergeRequest';
        final realId = issue ? 300 : 400;
        final target = 'gid://gitlab/$type/$realId';
        final field = issue ? 'issues' : 'mergeRequests';
        final document =
            'query Observe(\$id: ID!) { currentUser { id username } node(id: \$id) { id fullPath items: $field { nodes { id } totalCount pageInfo { hasNextPage endCursor } } } }';
        final variables = {'id': 'gid://gitlab/Project/909'};
        final queries = {
          document: {mr7Digest(variables)},
        };
        for (final variant in [
          'absent',
          'conflictingResponse',
          'missingBinding',
        ]) {
          final server = Mr7SyntheticGitLab();
          server.routes['GET projects/909/$resource/$iid'] = (_) =>
              mr7Json(issue ? _issueRow() : _mrRow());
          server.routes['POST /install/api/graphql'] = (_) => mr7Json({
            'data': {
              'currentUser': {
                'id': 'gid://gitlab/User/7',
                'username': 'synthetic-owner',
              },
              'node': {
                'id': 'gid://gitlab/Project/909',
                'fullPath': 'synthetic-owner/mr7-testnonce123',
                'items': {
                  'nodes': [
                    if (variant == 'conflictingResponse') {'id': target},
                  ],
                  'totalCount': variant == 'conflictingResponse' ? 1 : 0,
                  'pageInfo': {'hasNextPage': false, 'endCursor': null},
                },
              },
            },
          });
          final fixture = await _observationFixture(
            server,
            operation: issue ? 'deleteIssue' : 'deleteMergeRequest',
            method: 'DELETE',
            mutationPath: 'projects/909/$resource/$iid',
            response: variant == 'conflictingResponse'
                ? {'id': 999, 'iid': iid}
                : {},
            paths: {'projects/909'},
            queries: queries,
            beforeSend: variant == 'missingBinding'
                ? null
                : (session) => session.bindGraphResource(
                    target,
                    path: 'projects/909/$resource/$iid',
                  ),
          );
          if (variant == 'conflictingResponse') {
            expect(fixture.observer.result.id, 999);
            expect(fixture.observer.result.iid, iid);
          }
          final observing = fixture.observer.observe(
            Mr7GraphObservation(
              document: document,
              variables: variables,
              parentId: 'gid://gitlab/Project/909',
              recordPath: ['data', 'node'],
              connectionPath: ['items'],
              expectedIds: variant == 'conflictingResponse' ? {target} : {},
              absentIds: {
                variant == 'conflictingResponse'
                    ? 'gid://gitlab/$type/999'
                    : target,
              },
            ),
          );
          if (variant == 'absent') {
            await observing;
            expect(fixture.observer.verifiedRequests, greaterThan(0));
          } else {
            await expectLater(
              observing,
              throwsA(anything),
              reason: '$resource/$variant',
            );
            expect(fixture.observer.verifiedRequests, 0);
            fixture.session.stop('testObservationFailed');
          }
          await fixture.session.finish();
          if (variant != 'absent') expect(server.cleanupWrites, 0);
        }
      }
    },
  );

  test('Note GID binding rejects a different same-project noteable', () async {
    final server = Mr7SyntheticGitLab();
    final session = _session(server, eventDelay: () async {});
    await session.initialize();
    server.routes['GET projects/909/issues/3'] = (_) => mr7Json(_issueRow());
    server.routes['GET projects/909/issues/3/notes/71'] = (_) =>
        mr7Json({'id': 71, 'project_id': 909, 'noteable_id': 301});
    await expectLater(
      session.bindGraphResource(
        'gid://gitlab/Note/71',
        path: 'projects/909/issues/3/notes/71',
      ),
      throwsA(isA<Mr7Refused>()),
    );
    await session.finish();
    expect(session.quarantined, isTrue);
    expect(server.cleanupWrites, 0);
  });

  test(
    'issue and MR deletion compare route iid with complete list iid',
    () async {
      for (final resource in ['issues', 'merge_requests']) {
        for (final variant in [
          'absent',
          'retained',
          'missingIid',
          'duplicateIid',
        ]) {
          final issue = resource == 'issues';
          final iid = issue ? 3 : 4;
          final globalId = issue ? 300 : 400;
          final server = Mr7SyntheticGitLab();
          final rows = <Map<String, Object?>>[
            if (variant == 'retained')
              {'id': globalId, 'iid': iid, 'project_id': 909},
            if (variant == 'missingIid') {'id': 501, 'project_id': 909},
            if (variant == 'duplicateIid') ...[
              {'id': 501, 'iid': 99, 'project_id': 909},
              {'id': 502, 'iid': 99, 'project_id': 909},
            ],
          ];
          server.routes['GET projects/909/$resource'] = (_) => mr7Json(
            rows,
            headers: _pageHeaders(page: 1, total: rows.length, perPage: 100),
          );
          final fixture = await _observationFixture(
            server,
            operation: issue ? 'deleteIssue' : 'deleteMergeRequest',
            method: 'DELETE',
            mutationPath: 'projects/909/$resource/$iid',
            paths: {'projects/909', 'projects/909/$resource'},
          );
          final observed = fixture.observer.observe(
            Mr7ListObservation(
              parent: const Mr7Parent.project(),
              kind: issue ? Mr7ListKind.issues : Mr7ListKind.mergeRequests,
              expectedIds: rows.map((r) => r['id']!).toSet(),
            ),
          );
          if (variant == 'absent') {
            expect(await observed, isEmpty);
          } else {
            await expectLater(
              observed,
              throwsA(anything),
              reason: '$resource/$variant',
            );
            expect(fixture.observer.verifiedRequests, 0);
            fixture.session.stop('testObservationFailed');
          }
          await fixture.session.finish();
          if (variant != 'absent') expect(server.cleanupWrites, 0);
        }
      }
    },
  );

  test(
    'Graph deletion requires a complete bound connection and created child',
    () async {
      for (final variant in [
        'absent',
        'noConnection',
        'wrongCollection',
        'filtered',
        'retained',
        'created',
        'createdOther',
        'createdWithoutSelector',
        'wrongType',
      ]) {
        final create = variant.startsWith('created') || variant == 'wrongType';
        final document = variant == 'noConnection'
            ? r'query Observe($id: ID!) { currentUser { id username } node(id: $id) { id project { id fullPath } } }'
            : variant == 'wrongCollection'
            ? r'query Observe($id: ID!) { currentUser { id username } node(id: $id) { id project { id fullPath } items: discussions { nodes { id } totalCount pageInfo { hasNextPage endCursor } } } }'
            : variant == 'filtered'
            ? r'query Observe($id: ID!) { currentUser { id username } node(id: $id) { id project { id fullPath } items: notes(type: "DISCUSSION") { nodes { id } totalCount pageInfo { hasNextPage endCursor } } } }'
            : r'query Observe($id: ID!) { currentUser { id username } node(id: $id) { id project { id fullPath } items: notes { nodes { id } totalCount pageInfo { hasNextPage endCursor } } } }';
        final variables = {'id': 'gid://gitlab/Issue/300'};
        final queries = {
          document: {mr7Digest(variables)},
        };
        final nodes = <Map<String, Object?>>[
          if (variant == 'retained' ||
              variant == 'created' ||
              variant == 'createdWithoutSelector')
            {'id': 'gid://gitlab/Note/71'},
          if (variant == 'createdOther') {'id': 'gid://gitlab/Note/72'},
          if (variant == 'wrongType') {'id': 'gid://gitlab/Label/71'},
        ];
        final server = Mr7SyntheticGitLab();
        server.routes['GET projects/909/issues/3'] = (_) =>
            mr7Json(_issueRow());
        server.routes['POST /install/api/graphql'] = (_) => mr7Json({
          'data': {
            'currentUser': {
              'id': 'gid://gitlab/User/7',
              'username': 'synthetic-owner',
            },
            'node': {
              'id': 'gid://gitlab/Issue/300',
              'project': {
                'id': 'gid://gitlab/Project/909',
                'fullPath': 'synthetic-owner/mr7-testnonce123',
              },
              'items': {
                'nodes': nodes,
                'totalCount': nodes.length,
                'pageInfo': {'hasNextPage': false, 'endCursor': null},
              },
            },
          },
        });
        final fixture = await _observationFixture(
          server,
          operation: create ? 'createNote' : 'deleteNote',
          mutationPath: create
              ? 'projects/909/issues/3/notes'
              : 'projects/909/issues/3/notes/71',
          method: create ? 'POST' : 'DELETE',
          response: create && variant != 'createdWithoutSelector'
              ? {'id': 'gid://gitlab/Note/71'}
              : {},
          status: create ? 201 : 204,
          paths: {'projects/909/issues/3'},
          queries: queries,
        );
        await fixture.session.bindGraphResource(
          'gid://gitlab/Issue/300',
          path: 'projects/909/issues/3',
        );
        final observing = fixture.observer.observe(
          Mr7GraphObservation(
            document: document,
            variables: variables,
            parentId: 'gid://gitlab/Issue/300',
            recordPath: ['data', 'node'],
            connectionPath: variant == 'noConnection' ? null : ['items'],
            expectedIds: variant == 'noConnection'
                ? null
                : nodes.map((n) => n['id']! as String).toSet(),
            absentIds: create ? {} : {'gid://gitlab/Note/71'},
          ),
        );
        if (variant == 'absent' || variant == 'created') {
          await observing;
        } else {
          await expectLater(observing, throwsA(anything), reason: variant);
          expect(fixture.observer.verifiedRequests, 0);
          fixture.session.stop('testObservationFailed');
        }
        await fixture.session.finish();
        if (variant != 'absent' && variant != 'created') {
          expect(server.cleanupWrites, 0);
        }
      }
    },
  );

  test('unverified Graph deletion stops later scenarios and cleanup', () async {
    const document =
        r'query Observe($id: ID!) { currentUser { id username } node(id: $id) { id project { id fullPath } } }';
    final variables = {'id': 'gid://gitlab/Issue/300'};
    final server = Mr7SyntheticGitLab();
    server.routes['GET projects/909/issues/3'] = (_) => mr7Json(_issueRow());
    server.routes['GET projects/909/issues/3/notes/71'] = (_) => mr7Json({
      'id': 71,
      'project_id': 909,
      'noteable_id': 300,
      'body': 'Retained synthetic note',
      'author': {'username': 'synthetic-owner'},
    });
    server.routes['DELETE projects/909/issues/3/notes/71'] = (_) {
      server.scenarioWrites++;
      server.addEvent(target: 909);
      return mr7Json({}, status: 204);
    };
    server.routes['POST /install/api/graphql'] = (_) => mr7Json({
      'data': {
        'currentUser': {
          'id': 'gid://gitlab/User/7',
          'username': 'synthetic-owner',
        },
        'node': {
          'id': 'gid://gitlab/Issue/300',
          'project': {
            'id': 'gid://gitlab/Project/909',
            'fullPath': 'synthetic-owner/mr7-testnonce123',
          },
        },
      },
    });
    final session = _session(server, eventDelay: () async {});
    final deletion = sandbox.Mr7Scenario(
      id: 'delete-retained-note',
      suite: 'rest',
      operation: 'deleteNote',
      variant: 'missing-connection',
      tier: 'T4',
      targetKind: AiTargetKind.note,
      targetKinds: {AiTargetKind.note, AiTargetKind.issue},
      utterance: (p) => 'Delete #note_71 from issue #3 in ${p.path}.',
      resource: (_) => const AiResourceRef(kind: AiResourceKind.issue, id: 3),
      call: (p) => AiToolCall(
        id: 'delete-retained-note',
        name: 'deleteNote',
        arguments: {
          'projectId': p.projectId,
          'resource': 'issues',
          'iid': 3,
          'noteId': 71,
          'reason': 'The user explicitly requested deletion.',
        },
      ),
      paths: (p) => {'DELETE projects/${p.projectId}/issues/3/notes/71'},
      readbackPaths: (p, _) => {'projects/${p.projectId}/issues/3'},
      observerQueries: (_, _) => {
        document: {mr7Digest(variables)},
      },
      observe: (observer, _) async {
        await session.bindGraphResource(
          'gid://gitlab/Issue/300',
          path: 'projects/909/issues/3',
        );
        await observer.observe(
          Mr7GraphObservation(
            document: document,
            variables: variables,
            recordPath: ['data', 'node'],
            parentId: 'gid://gitlab/Issue/300',
            absentIds: {'gid://gitlab/Note/71'},
          ),
        );
        return true;
      },
    );
    final receipt = await sandbox.runMr7Sandbox(
      policy: Mr7Policy.candidate,
      releaseSha: _sha,
      session: session,
      // The real coordinator requires both the owning issue and the prepared
      // child note target to be released by this scenario's own declaration.
      // The second scenario must never widen it or execute after quarantine.
      scenarios: [
        deletion,
        sandbox.Mr7Scenario(
          id: 'delete-owner-sentinel',
          suite: 'rest',
          operation: 'deleteNote',
          variant: 'owner-release',
          tier: 'T4',
          targetKind: AiTargetKind.issue,
          call: deletion.call,
          paths: deletion.paths,
          observe: deletion.observe,
        ),
        _star('after-unverified-delete'),
      ],
      confirm: (_) async => true,
      typedConfirm: (proposal) async => proposal.requiredTypedName,
    );
    expect(
      _rows(receipt).first['mutationCount'],
      1,
      reason: jsonEncode(receipt),
    );
    expect(
      _rows(receipt).first['status'],
      'NOT_VERIFIED',
      reason: jsonEncode(receipt),
    );
    expect(_rows(receipt).first['readback'], 'NOT_VERIFIED');
    expect(_rows(receipt)[1]['status'], 'NOT_RUN');
    expect(_rows(receipt).last['status'], 'NOT_RUN');
    expect(server.scenarioWrites, 1);
    expect(server.cleanupWrites, 0);
  });

  test('approval direction is fixed by the dispatched operation', () async {
    for (final variant in [
      'approvePresent',
      'approveAbsent',
      'approveOppositeSpec',
      'unapproveAbsent',
      'unapprovePresent',
      'unapproveOppositeSpec',
      'unsupported',
    ]) {
      final unapprove = variant.startsWith('unapprove');
      final present =
          variant == 'approvePresent' ||
          variant == 'unapprovePresent' ||
          variant == 'unsupported';
      final specApproved = variant == 'approveOppositeSpec'
          ? false
          : variant == 'unapproveOppositeSpec'
          ? true
          : !unapprove;
      final server = Mr7SyntheticGitLab();
      server.routes['GET projects/909/merge_requests/4'] = (_) =>
          mr7Json(_mrRow());
      server.routes['GET projects/909/merge_requests/4/approvals'] = (_) =>
          mr7Json({
            'id': 400,
            'iid': 4,
            'approved_by': [
              if (present)
                {
                  'user': {'id': 7},
                },
            ],
          });
      final fixture = await _observationFixture(
        server,
        operation: variant == 'unsupported'
            ? 'unknownApproval'
            : unapprove
            ? 'unapproveMergeRequest'
            : 'approveMergeRequest',
        mutationPath:
            'projects/909/merge_requests/4/${unapprove ? 'unapprove' : 'approve'}',
        paths: {
          'projects/909/merge_requests/4',
          'projects/909/merge_requests/4/approvals',
        },
      );
      final observing = fixture.observer.observe(
        Mr7ApprovalObservation(parent: _mrParent, approved: specApproved),
      );
      if (variant == 'approvePresent' || variant == 'unapproveAbsent') {
        expect(await observing, isTrue);
      } else {
        await expectLater(observing, throwsA(anything), reason: variant);
        fixture.session.stop('testObservationFailed');
      }
      await fixture.session.finish();
      if (variant != 'approvePresent' && variant != 'unapproveAbsent') {
        expect(server.cleanupWrites, 0);
      }
    }
  });

  test(
    'repository witnesses bind the dispatched branch and source ref',
    () async {
      for (final variant in [
        'correctBranch',
        'wrongBranch',
        'missingBranch',
        'branchDrift',
      ]) {
        final server = Mr7SyntheticGitLab();
        var branchReads = 0;
        server.routes['GET projects/909/repository/branches/target'] = (_) {
          branchReads++;
          return mr7Json({
            'name': 'target',
            'commit': {
              'id':
                  variant == 'wrongBranch' ||
                      (variant == 'branchDrift' && branchReads > 1)
                  ? 'b' * 40
                  : _sha,
            },
          });
        };
        server.routes['GET projects/909/repository/files/a.txt'] = (request) {
          expect(request.queryParameters['ref'], _sha);
          return mr7Json({
            'file_path': 'a.txt',
            'commit_id': _sha,
            'encoding': 'base64',
            'content': base64Encode(utf8.encode('contents')),
          });
        };
        final fixture = await _observationFixture(
          server,
          operation: 'createFile',
          mutationPath: 'projects/909/repository/files/a.txt',
          body: {
            if (variant != 'missingBranch') 'branch': 'target',
            'content': 'contents',
          },
          paths: {
            'projects/909/repository/files/a.txt',
            'projects/909/repository/branches/target',
          },
        );
        final observing = fixture.observer.observe(
          const Mr7FileObservation(
            path: 'a.txt',
            sha: _sha,
            content: 'contents',
          ),
        );
        if (variant == 'correctBranch') {
          await observing;
          expect(branchReads, 2);
        } else {
          await expectLater(observing, throwsA(anything), reason: variant);
          fixture.session.stop('testObservationFailed');
        }
        await fixture.session.finish();
      }
      for (final kind in Mr7RefKind.values) {
        final branch = kind == Mr7RefKind.branch;
        final collection = branch ? 'branches' : 'tags';
        final server = Mr7SyntheticGitLab();
        server.routes['GET projects/909/repository/$collection/target'] = (_) =>
            mr7Json({
              'name': 'target',
              'commit': {'id': _sha},
            });
        final fixture = await _observationFixture(
          server,
          operation: branch ? 'createBranch' : 'createTag',
          mutationPath: 'projects/909/repository/$collection',
          body: {branch ? 'branch' : 'tag_name': 'target', 'ref': 'b' * 40},
          paths: {'projects/909/repository/$collection/target'},
        );
        await expectLater(
          fixture.observer.observe(
            Mr7RefObservation(kind: kind, name: 'target', sha: _sha),
          ),
          throwsA(anything),
          reason: kind.name,
        );
        fixture.session.stop('testObservationFailed');
        await fixture.session.finish();
        expect(server.cleanupWrites, 0);
      }
    },
  );

  test(
    'absence cannot bless a retained target or a different same-project parent',
    () async {
      final server = Mr7SyntheticGitLab();
      server.routes['GET projects/909/issues/3'] = (_) => mr7Json(_issueRow());
      server.routes['GET projects/909/issues/4'] = (_) =>
          mr7Json({'id': 401, 'iid': 4, 'project_id': 909});
      server.routes['GET projects/909/issues/3/award_emoji'] = (_) => mr7Json([
        {
          'id': 55,
          'awardable_id': 300,
          'awardable_type': 'Issue',
          'user': {'id': 7},
        },
      ], headers: _pageHeaders(page: 1, total: 1));
      final fixture = await _observationFixture(
        server,
        operation: 'removeAwardEmoji',
        method: 'DELETE',
        mutationPath: 'projects/909/issues/3/award_emoji/55',
        paths: {
          'projects/909/issues/3',
          'projects/909/issues/4',
          'projects/909/issues/3/award_emoji',
          'projects/909/issues/4/award_emoji',
        },
      );
      await expectLater(
        fixture.observer.observe(
          Mr7ListObservation(
            parent: _issueParent,
            kind: Mr7ListKind.awards,
            expectedIds: {55},
          ),
        ),
        throwsA(anything),
      );
      await expectLater(
        fixture.observer.observe(
          Mr7ListObservation(
            parent: const Mr7Parent.issue(id: 401, iid: 4),
            kind: Mr7ListKind.awards,
            expectedIds: {},
          ),
        ),
        throwsA(anything),
      );
      expect(
        server.requests,
        isNot(contains('GET projects/909/issues/4/award_emoji')),
      );
      expect(fixture.observer.verifiedRequests, 0);
      fixture.session.stop('testObservationFailed');
      await fixture.session.finish();
    },
  );

  test(
    'created discussion cannot substitute an existing thread for a missing response ID',
    () async {
      final server = Mr7SyntheticGitLab();
      server.routes['GET projects/909/issues/3'] = (_) => mr7Json(_issueRow());
      final fixture = await _observationFixture(
        server,
        operation: 'createDiscussion',
        mutationPath: 'projects/909/issues/3/discussions',
        status: 201,
        response: {},
        paths: {
          'projects/909/issues/3',
          'projects/909/issues/3/discussions/existing',
        },
      );
      await expectLater(
        fixture.observer.observe(
          Mr7DiscussionObservation(
            parent: _issueParent,
            discussionId: 'existing',
            noteIds: {71},
            resolved: true,
          ),
        ),
        throwsA(anything),
      );
      expect(
        server.requests,
        isNot(contains('GET projects/909/issues/3/discussions/existing')),
      );
      fixture.session.stop('testObservationFailed');
      await fixture.session.finish();
    },
  );
  test(
    'runner seals observer queries after the response and retains returned selectors',
    () async {
      const document =
          r'query Observe($id: ID!) { currentUser { id username } node(id: $id) { id fullPath starred } }';
      final server = Mr7SyntheticGitLab();
      server.routes['POST /install/api/graphql'] = (_) => mr7Json({
        'data': {
          'currentUser': {
            'id': 'gid://gitlab/User/7',
            'username': 'synthetic-owner',
          },
          'node': {
            'id': 'gid://gitlab/Project/909',
            'fullPath': server.project!['path_with_namespace'],
            'starred': server.project!['starred'],
          },
        },
      });
      var sealed = false;
      final base = _star('post-response-query');
      final scenario = sandbox.Mr7Scenario(
        id: base.id,
        suite: base.suite,
        operation: base.operation,
        variant: base.variant,
        tier: base.tier,
        call: base.call,
        paths: base.paths,
        observerQueries: (_, result) {
          expect(server.scenarioWrites, 1);
          expect(result.id, 909);
          sealed = true;
          return {
            document: {
              mr7Digest({'id': 'gid://gitlab/Project/${result.id}'}),
            },
          };
        },
        observe: (observer, _) async {
          expect(sealed, isTrue);
          final row = await observer.observe(
            Mr7GraphObservation(
              document: document,
              variables: {'id': 'gid://gitlab/Project/${observer.result.id}'},
              recordPath: ['data', 'node'],
              parentId: 'gid://gitlab/Project/909',
            ),
          );
          return row['starred'] == true;
        },
      );
      final receipt = await sandbox.runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: _sha,
        session: _session(server),
        scenarios: [scenario],
        confirm: (_) async => true,
      );
      expect(
        _rows(receipt).single['status'],
        'PASS',
        reason: jsonEncode(receipt),
      );
      expect(_rows(receipt).single['observerRequests'], greaterThan(0));
    },
  );

  test(
    'Graph exact absence checks the removed note and AwardEmoji note relationship',
    () async {
      for (final variant in [
        'absent',
        'present',
        'award',
        'wrongNote',
        'wrongSpec',
      ]) {
        final server = Mr7SyntheticGitLab();
        server.routes['GET projects/909/issues/3'] = (_) =>
            mr7Json(_issueRow());
        server.routes['GET projects/909/issues/3/notes/71'] = (_) =>
            mr7Json({'id': 71, 'noteable_id': 300, 'project_id': 909});
        final award =
            variant == 'award' ||
            variant == 'wrongNote' ||
            variant == 'wrongSpec';
        final document = award
            ? r'query Observe($id: ID!) { currentUser { id username } node(id: $id) { id project { id fullPath } items: awardEmoji { nodes { id note { id } } totalCount pageInfo { hasNextPage endCursor } } } }'
            : r'query Observe($id: ID!) { currentUser { id username } node(id: $id) { id project { id fullPath } items: notes { nodes { id } totalCount pageInfo { hasNextPage endCursor } } } }';
        final parentId = award
            ? 'gid://gitlab/Note/71'
            : 'gid://gitlab/Issue/300';
        final variables = {'id': parentId};
        final queries = {
          document: {mr7Digest(variables)},
        };
        server.routes['POST /install/api/graphql'] = (_) => mr7Json({
          'data': {
            'currentUser': {
              'id': 'gid://gitlab/User/7',
              'username': 'synthetic-owner',
            },
            'node': {
              'id': parentId,
              'project': {
                'id': 'gid://gitlab/Project/909',
                'fullPath': 'synthetic-owner/mr7-testnonce123',
              },
              'items': {
                'nodes': [
                  if (variant != 'absent')
                    {
                      'id': award
                          ? 'gid://gitlab/AwardEmoji/90'
                          : 'gid://gitlab/Note/71',
                      if (award)
                        'note': {
                          'id': variant == 'wrongNote' || variant == 'wrongSpec'
                              ? 'gid://gitlab/Note/72'
                              : 'gid://gitlab/Note/71',
                        },
                    },
                ],
                'totalCount': variant == 'absent' ? 0 : 1,
                'pageInfo': {'hasNextPage': false, 'endCursor': null},
              },
            },
          },
        });
        final fixture = await _observationFixture(
          server,
          operation: award ? 'addAwardEmoji' : 'deleteNote',
          mutationPath: award
              ? 'projects/909/issues/3/notes/71/award_emoji'
              : 'projects/909/issues/3/notes/71',
          method: award ? 'POST' : 'DELETE',
          response: award ? {'id': 'gid://gitlab/AwardEmoji/90'} : {},
          status: award ? 201 : 204,
          paths: {'projects/909/issues/3', 'projects/909/issues/3/notes/71'},
          queries: queries,
        );
        await fixture.session.bindGraphResource(
          parentId,
          path: award
              ? 'projects/909/issues/3/notes/71'
              : 'projects/909/issues/3',
        );
        final observing = fixture.observer.observe(
          Mr7GraphObservation(
            document: document,
            variables: variables,
            parentId: parentId,
            recordPath: ['data', 'node'],
            connectionPath: ['items'],
            expectedIds: variant == 'absent'
                ? {}
                : {
                    award
                        ? 'gid://gitlab/AwardEmoji/90'
                        : 'gid://gitlab/Note/71',
                  },
            absentIds: award ? {} : {'gid://gitlab/Note/71'},
            noteId: award
                ? 'gid://gitlab/Note/${variant == 'wrongSpec' ? 72 : 71}'
                : null,
          ),
        );
        if (variant == 'absent' || variant == 'award') {
          await observing;
        } else {
          await expectLater(observing, throwsA(anything));
          fixture.session.stop('testObservationFailed');
        }
        await fixture.session.finish();
      }
    },
  );

  test(
    'observer identity reuses import and path fences after the response',
    () async {
      for (final variant in ['import', 'path']) {
        final server = Mr7SyntheticGitLab();
        final fixture = await _observationFixture(
          server,
          operation: 'setStar',
          mutationPath: 'projects/909/unstar',
          paths: {'projects/909'},
        );
        if (variant == 'import') {
          server.project!['import_url'] = 'https://outside.invalid/repo';
        } else {
          server.byPathOverride = {...server.project!, 'id': 1000};
        }
        await expectLater(
          fixture.observer.observe(
            const Mr7ParentStateObservation(
              parent: Mr7Parent.project(),
              state: Mr7ParentState.starred,
              expected: false,
            ),
          ),
          throwsA(anything),
        );
        expect(fixture.observer.verifiedRequests, 0);
        await fixture.session.finish();
        expect(server.cleanupWrites, 0);
      }
    },
  );
  test(
    '409 core noChange needs one attempt and complete auto-merge state',
    () async {
      for (final variant in [
        'verified',
        'enabled',
        'contradictory',
        'missing',
      ]) {
        final server = Mr7SyntheticGitLab();
        var sent = false;
        server.routes['GET projects/909/merge_requests/4'] = (_) => mr7Json({
          ..._mrRow(),
          'merge_when_pipeline_succeeds': !sent || variant == 'enabled',
          'auto_merge_enabled':
              !sent || variant == 'enabled' || variant == 'contradictory',
        });
        server.routes['POST projects/909/merge_requests/4/cancel_auto_merge'] =
            (_) {
              sent = true;
              server.scenarioWrites++;
              return mr7Json({'message': 'already canceled'}, status: 409);
            };
        final scenario = sandbox.Mr7Scenario(
          id: 'cancel-409',
          suite: 'advanced',
          operation: 'cancelAutoMerge',
          variant: variant,
          tier: 'T3',
          targetKind: AiTargetKind.mergeRequest,
          resource: (_) =>
              const AiResourceRef(kind: AiResourceKind.mergeRequest, id: 4),
          call: (p) => AiToolCall(
            id: 'cancel-409',
            name: 'cancelAutoMerge',
            arguments: {'projectId': p.projectId, 'iid': 4},
          ),
          paths: (p) => {
            'POST projects/${p.projectId}/merge_requests/4/cancel_auto_merge',
          },
          readbackPaths: (p, _) => {'projects/${p.projectId}/merge_requests/4'},
          noChangeObservation: variant == 'missing'
              ? null
              : (_) => const Mr7ParentStateObservation(
                  parent: _mrParent,
                  state: Mr7ParentState.autoMerge,
                  expected: false,
                ),
          observe: (_, _) async => true,
        );
        final receipt = await sandbox.runMr7Sandbox(
          policy: Mr7Policy.candidate,
          releaseSha: _sha,
          session: _session(server),
          confirm: (_) async => true,
          scenarios: [scenario, _star('after-409')],
        );
        final row = _rows(receipt).first;
        expect(row['mutationCount'], 1, reason: jsonEncode(receipt));
        expect(row['coreOutcome'], 'succeeded');
        expect(row['coreNoChange'], isTrue);
        expect(
          server.requests
              .where(
                (r) =>
                    r == 'POST projects/909/merge_requests/4/cancel_auto_merge',
              )
              .length,
          1,
        );
        if (variant == 'verified') {
          expect(
            row['classification'],
            'verifiedNoOp',
            reason: jsonEncode(receipt),
          );
          expect(row['status'], 'PASS');
          expect(_rows(receipt).last['status'], 'PASS');
        } else {
          expect(row['status'], 'NOT_VERIFIED');
          expect(_rows(receipt).last['status'], 'NOT_RUN');
          expect(receipt['quarantined'], isTrue);
          expect(server.cleanupWrites, 0);
        }
      }
    },
  );

  test(
    'subscription 304 requires the exact parent and requested state',
    () async {
      for (final resource in ['issues', 'merge_requests']) {
        final issue = resource == 'issues';
        final parent = issue ? _issueParent : _mrParent;
        final iid = issue ? 3 : 4;
        final server = Mr7SyntheticGitLab();
        server.routes['GET projects/909/$resource/$iid'] = (_) =>
            mr7Json({...(issue ? _issueRow() : _mrRow()), 'subscribed': true});
        server.routes['POST projects/909/$resource/$iid/subscribe'] = (_) {
          server.scenarioWrites++;
          return mr7Json({}, status: 304);
        };
        final scenario = sandbox.Mr7Scenario(
          id: 'subscription-304',
          suite: 'rest',
          operation: 'setSubscribed',
          variant: resource,
          tier: 'T1',
          targetKind: issue ? AiTargetKind.issue : AiTargetKind.mergeRequest,
          resource: (_) => AiResourceRef(
            kind: issue ? AiResourceKind.issue : AiResourceKind.mergeRequest,
            id: iid,
          ),
          call: (p) => AiToolCall(
            id: 'subscription-304',
            name: 'setSubscribed',
            arguments: {
              'projectId': p.projectId,
              'resource': resource,
              'iid': iid,
              'subscribed': true,
              'reason': 'Keep synthetic subscription enabled.',
            },
          ),
          paths: (p) => {
            'POST projects/${p.projectId}/$resource/$iid/subscribe',
          },
          readbackPaths: (p, _) => {'projects/${p.projectId}/$resource/$iid'},
          noChangeObservation: (_) => Mr7ParentStateObservation(
            parent: parent,
            state: Mr7ParentState.subscribed,
            expected: true,
          ),
          observe: (_, _) async => true,
        );
        final receipt = await sandbox.runMr7Sandbox(
          policy: Mr7Policy.candidate,
          releaseSha: _sha,
          session: _session(server),
          confirm: (_) async => true,
          scenarios: [scenario, _star('after-subscription')],
        );
        expect(
          _rows(receipt).first['classification'],
          'verifiedNoOp',
          reason: jsonEncode(receipt),
        );
        expect(_rows(receipt).first['mutationCount'], 1);
        expect(_rows(receipt).last['status'], 'PASS');
      }
    },
  );
  test(
    'file ref and release observers bind exact names SHAs and content',
    () async {
      final server = Mr7SyntheticGitLab();
      final file = <String, Object?>{
        'file_path': 'dir/a b.txt',
        'commit_id': _sha,
        'encoding': 'base64',
        'content': base64Encode(utf8.encode('exact\n bytes ')),
      };
      server.routes['GET projects/909/repository/files/dir/a b.txt'] =
          (request) {
            expect(request.queryParameters['ref'], _sha);
            return mr7Json(file);
          };
      server.routes['GET projects/909/repository/branches/fixture/branch'] =
          (_) => mr7Json({
            'name': 'fixture/branch',
            'commit': {'id': _sha},
          });
      server.routes['GET projects/909/repository/tags/v-test'] = (_) =>
          mr7Json({
            'name': 'v-test',
            'commit': {'id': _sha},
          });
      server.routes['GET projects/909/releases/v-test'] = (_) => mr7Json({
        'tag_name': 'v-test',
        'name': 'Synthetic release',
        'commit': {'id': _sha},
      });
      final fixture = await _observationFixture(
        server,
        operation: 'createFile',
        mutationPath: 'projects/909/repository/files/dir%2Fa%20b.txt',
        body: {'branch': 'fixture/branch', 'content': 'exact\n bytes '},
        paths: {
          'projects/909/repository/files/dir%2Fa%20b.txt',
          'projects/909/repository/branches/fixture%2Fbranch',
          'projects/909/repository/tags/v-test',
          'projects/909/releases/v-test',
        },
      );
      await fixture.observer.observe(
        const Mr7FileObservation(
          path: 'dir/a b.txt',
          sha: _sha,
          content: 'exact\n bytes ',
        ),
      );
      final branch = await _observationFixture(
        Mr7SyntheticGitLab()
          ..routes['GET projects/909/repository/branches/fixture/branch'] = server
              .routes['GET projects/909/repository/branches/fixture/branch']!,
        operation: 'createBranch',
        mutationPath: 'projects/909/repository/branches',
        body: {'branch': 'fixture/branch', 'ref': _sha},
        paths: {'projects/909/repository/branches/fixture%2Fbranch'},
      );
      await branch.observer.observe(
        const Mr7RefObservation(
          kind: Mr7RefKind.branch,
          name: 'fixture/branch',
          sha: _sha,
        ),
      );
      final tag = await _observationFixture(
        Mr7SyntheticGitLab()
          ..routes['GET projects/909/repository/tags/v-test'] =
              server.routes['GET projects/909/repository/tags/v-test']!,
        operation: 'createTag',
        mutationPath: 'projects/909/repository/tags',
        body: {'tag_name': 'v-test', 'ref': _sha},
        paths: {'projects/909/repository/tags/v-test'},
      );
      await tag.observer.observe(
        const Mr7RefObservation(
          kind: Mr7RefKind.tag,
          name: 'v-test',
          sha: _sha,
        ),
      );
      final release = await _observationFixture(
        Mr7SyntheticGitLab()
          ..routes['GET projects/909/releases/v-test'] =
              server.routes['GET projects/909/releases/v-test']!,
        operation: 'createRelease',
        mutationPath: 'projects/909/releases',
        body: {'tag_name': 'v-test', 'name': 'Synthetic release'},
        paths: {'projects/909/releases/v-test'},
      );
      await release.observer.observe(
        const Mr7ReleaseObservation(
          tag: 'v-test',
          name: 'Synthetic release',
          sha: _sha,
        ),
      );
      for (final bad in [
        const Mr7FileObservation(
          path: 'dir/a b.txt',
          sha: _sha,
          content: 'exact\n bytes',
        ),
        Mr7FileObservation(
          path: 'dir/a b.txt',
          sha: 'b' * 40,
          content: 'exact\n bytes ',
        ),
        const Mr7FileObservation(path: '../elsewhere', sha: _sha, content: ''),
        const Mr7RefObservation(kind: Mr7RefKind.tag, name: 'other', sha: _sha),
        const Mr7ReleaseObservation(
          tag: 'v-test',
          name: 'wrong name',
          sha: _sha,
        ),
      ]) {
        await expectLater(fixture.observer.observe(bad), throwsA(anything));
      }
      await fixture.session.finish();
      await branch.session.finish();
      await tag.session.finish();
      await release.session.finish();
    },
  );

  test(
    'snippet raw bytes require exact project file set and revision before and after',
    () async {
      for (final variant in [
        'exact',
        'wrongBytes',
        'wrongRevision',
        'foreignProject',
        'extraFile',
        'foreignUrl',
        'lateRevision',
      ]) {
        final server = Mr7SyntheticGitLab();
        var metadataReads = 0;
        server.routes['GET projects/909/snippets/60'] = (_) {
          metadataReads++;
          return mr7Json({
            'id': 60,
            'project_id': variant == 'foreignProject' ? 1000 : 909,
            'visibility': 'private',
            'updated_at':
                variant == 'wrongRevision' ||
                    (variant == 'lateRevision' && metadataReads > 1)
                ? 'later'
                : 'revision-one',
            'files': [
              {
                'path': 'dir/raw.bin',
                'raw_url': variant == 'foreignUrl'
                    ? 'https://outside.invalid/raw'
                    : 'https://gitlab.invalid/install/synthetic-owner/mr7-testnonce123/-/snippets/60/raw/ref-one/dir/raw.bin',
              },
              if (variant == 'extraFile')
                {'path': 'extra', 'raw_url': 'unused'},
            ],
          });
        };
        server.routes['GET projects/909/snippets/60/files/ref-one/dir/raw.bin/raw'] =
            (_) => ResponseBody.fromBytes(
              variant == 'wrongBytes' ? [0, 255, 2] : [0, 255, 1],
              200,
            );
        final fixture = await _observationFixture(
          server,
          operation: 'createSnippet',
          mutationPath: 'projects/909/snippets',
          response: {'id': 60, 'project_id': 909},
          status: 201,
          paths: {
            'projects/909/snippets/60',
            'projects/909/snippets/60/files/ref-one/dir%2Fraw.bin/raw',
          },
        );
        final observing = fixture.observer.observe(
          Mr7SnippetObservation(
            id: 60,
            revision: 'revision-one',
            files: {
              'dir/raw.bin': Mr7SnippetFile(ref: 'ref-one', bytes: [0, 255, 1]),
            },
          ),
        );
        if (variant == 'exact') {
          expect((await observing)['dir/raw.bin'], [0, 255, 1]);
          expect(metadataReads, 2);
        } else {
          await expectLater(observing, throwsA(anything), reason: variant);
          expect(fixture.observer.verifiedRequests, 0);
          fixture.session.stop('testObservationFailed');
        }
        expect(
          server.requests.any((r) => r.contains('outside.invalid')),
          isFalse,
        );
        await fixture.session.finish();
      }
    },
  );

  test(
    'rebase observes bounded completion after acknowledgement without resend',
    () async {
      for (final variant in [
        'complete',
        'immediate',
        'pendingUnchanged',
        'pending',
        'error',
        'late',
        'wrongSha',
        'idle',
      ]) {
        final server = Mr7SyntheticGitLab();
        var polls = 0;
        server.routes['GET projects/909/merge_requests/4'] = (request) async {
          if (server.scenarioWrites == 0) {
            return mr7Json({
              ..._mrRow(),
              'sha': variant == 'immediate' || variant == 'complete'
                  ? 'a' * 40
                  : _sha,
              'merge_error': null,
            });
          }
          polls++;
          expect(request.queryParameters['include_rebase_in_progress'], true);
          if (variant == 'late') {
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
          return mr7Json({
            ..._mrRow(),
            if (request.queryParameters['include_rebase_in_progress'] == true)
              'rebase_in_progress':
                  variant == 'pending' ||
                  (polls == 1 && variant != 'idle' && variant != 'immediate'),
            'merge_error': variant == 'error' ? 'synthetic error' : null,
            'sha': variant == 'wrongSha' ? 'b' * 40 : _sha,
          });
        };
        final fixture = await _observationFixture(
          server,
          operation: 'rebaseMergeRequest',
          mutationPath: 'projects/909/merge_requests/4/rebase',
          method: 'PUT',
          status: 202,
          paths: {'projects/909/merge_requests/4'},
        );
        final observing = fixture.observer.observe(
          Mr7RebaseObservation(
            parent: _mrParent,
            sha: _sha,
            maxAttempts: 3,
            interval: Duration.zero,
            timeout: Duration(milliseconds: variant == 'late' ? 5 : 500),
          ),
        );
        if (variant == 'complete' || variant == 'immediate') {
          expect((await observing)['rebase_in_progress'], isFalse);
          expect(polls, variant == 'complete' ? 2 : 1);
        } else {
          await expectLater(observing, throwsA(anything), reason: variant);
          fixture.session.stop('testObservationFailed');
          if (variant == 'late') {
            await Future<void>.delayed(const Duration(milliseconds: 60));
          }
          expect(polls, variant == 'late' ? 1 : 3);
          expect(fixture.observer.verifiedRequests, 0);
        }
        expect(server.scenarioWrites, 1);
        await fixture.session.finish();
        if (variant != 'complete' && variant != 'immediate') {
          expect(server.cleanupWrites, 0);
        }
      }
    },
  );

  test(
    'typed observers cannot escape sandbox even with an allowlisted foreign path',
    () async {
      final server = Mr7SyntheticGitLab();
      final fixture = await _observationFixture(
        server,
        response: {'id': 20},
        paths: {'projects/1000', 'projects/1000/milestones/20'},
      );
      await expectLater(
        fixture.observer.read('projects/1000'),
        throwsA(anything),
      );
      await expectLater(
        fixture.session.observer.get<Object?>('projects/1000'),
        throwsA(anything),
      );
      expect(server.requests, isNot(contains('GET projects/1000')));
      expect(fixture.session.quarantined, isTrue);
      await fixture.session.finish();
      expect(server.cleanupWrites, 0);
    },
  );

  test(
    'Graph observer uses response IDs separately from its complete parent connection',
    () async {
      const doc =
          r'query Observe($id: ID!, $after: String) { currentUser { id username } node(id: $id) { id project { id fullPath } notes(after: $after) { nodes { id } totalCount pageInfo { hasNextPage endCursor } } } }';
      const gid = 'gid://gitlab/Issue/300';
      for (final variant in [
        'complete',
        '404',
        'errors',
        'foreignParent',
        'foreignActor',
        'missingSeal',
        'truncated',
        'duplicate',
        'presentInsteadOfAbsent',
      ]) {
        final server = Mr7SyntheticGitLab();
        server.routes['GET projects/909/issues/3'] = (_) =>
            mr7Json(_issueRow());
        server.routes['POST /install/api/graphql'] = (request) {
          final variables = (request.data as Map)['variables'] as Map;
          final second = variables['after'] == 'cursor-one';
          return mr7Json({
            'data': {
              'currentUser': {
                'id': variant == 'foreignActor'
                    ? 'gid://gitlab/User/8'
                    : 'gid://gitlab/User/7',
                'username': 'synthetic-owner',
              },
              'node': {
                'id': gid,
                'project': {
                  'id':
                      'gid://gitlab/Project/${variant == 'foreignParent' ? 1000 : 909}',
                  'fullPath': 'synthetic-owner/mr7-testnonce123',
                },
                'notes': {
                  'nodes': [
                    {
                      'id':
                          'gid://gitlab/Note/${second && variant != 'duplicate' ? 72 : 71}',
                    },
                  ],
                  'totalCount': 2,
                  'pageInfo': {
                    'hasNextPage': !second && variant != 'truncated',
                    'endCursor': second ? 'cursor-two' : 'cursor-one',
                  },
                },
              },
            },
            if (variant == 'errors')
              'errors': [
                {'message': 'incomplete'},
              ],
          }, status: variant == '404' ? 404 : 200);
        };
        final variables = <String, Object?>{'id': gid, 'after': null};
        final queries = {
          doc: {
            mr7Digest(variables),
            if (variant != 'missingSeal')
              mr7Digest({...variables, 'after': 'cursor-one'}),
          },
        };
        final fixture = await _observationFixture(
          server,
          response: {'id': 'gid://gitlab/Note/71'},
          status: 201,
          paths: {'projects/909/issues/3'},
          queries: queries,
        );
        expect(fixture.observer.result.stringId, 'gid://gitlab/Note/71');
        await fixture.session.bindGraphResource(
          gid,
          path: 'projects/909/issues/3',
        );
        final observing = fixture.observer.observe(
          Mr7GraphObservation(
            document: doc,
            variables: variables,
            parentId: gid,
            recordPath: ['data', 'node'],
            connectionPath: ['notes'],
            expectedIds: variant == 'presentInsteadOfAbsent'
                ? {}
                : {'gid://gitlab/Note/71', 'gid://gitlab/Note/72'},
          ),
        );
        if (variant == 'complete') {
          await observing;
          expect(
            server.requests
                .where((r) => r == 'POST /install/api/graphql')
                .length,
            2,
          );
          expect(fixture.observer.verifiedRequests, greaterThan(0));
        } else {
          await expectLater(observing, throwsA(anything), reason: variant);
          expect(fixture.observer.verifiedRequests, 0);
          fixture.session.stop('testObservationFailed');
        }
        await fixture.session.finish();
      }
    },
  );
  test(
    '304 no-op requires bound parent-state observer before continuing',
    () async {
      for (final variant in ['verified', 'missing', 'wrongState', 'mismatch']) {
        final server = Mr7SyntheticGitLab();
        server.routes['POST projects/909/unstar'] = (_) {
          server.scenarioWrites++;
          if (variant == 'mismatch') server.project!['starred'] = true;
          return mr7Json({}, status: 304);
        };
        final receipt = await sandbox.runMr7Sandbox(
          policy: Mr7Policy.candidate,
          releaseSha: _sha,
          session: _session(server),
          confirm: (_) async => true,
          scenarios: [
            _starNoChange(
              includeObserver: variant != 'missing',
              wrongState: variant == 'wrongState',
            ),
            _star('after-304'),
          ],
        );
        final first = _rows(receipt).first;
        expect(first['mutationCount'], 1);
        expect(first['coreOutcome'], 'succeeded');
        if (variant == 'verified') {
          expect(first['status'], 'PASS', reason: jsonEncode(receipt));
          expect(first['classification'], 'verifiedNoOp');
          expect(first['parentStateVerified'], isTrue);
          expect(first['observerRequests'], greaterThan(0));
          expect(_rows(receipt).last['status'], 'PASS');
          expect(server.cleanupWrites, 1);
        } else {
          expect(first['status'], 'NOT_VERIFIED', reason: variant);
          expect(_rows(receipt).last['status'], 'NOT_RUN');
          expect(server.scenarioWrites, 1);
          expect(server.cleanupWrites, 0);
          expect(receipt['quarantined'], isTrue);
        }
      }
    },
  );

  test(
    'complete absence refuses a lone 404 and truncated or foreign pages',
    () async {
      for (final variant in [
        'empty',
        '404',
        'truncated',
        'present',
        'foreignActor',
        'foreignParent',
        'foreignAward',
      ]) {
        final server = Mr7SyntheticGitLab();
        server.routes['GET projects/909/issues/3'] = (_) =>
            mr7Json(_issueRow());
        server.routes['GET projects/909/issues/3/award_emoji'] = (_) =>
            variant == '404'
            ? mr7Json({}, status: 404)
            : mr7Json(
                [
                  if (variant == 'present' || variant == 'foreignAward')
                    {
                      'id': 55,
                      'awardable_id': variant == 'foreignAward' ? 301 : 300,
                      'awardable_type': 'Issue',
                      'user': {'id': 7},
                    },
                ],
                headers: variant == 'truncated'
                    ? {}
                    : _pageHeaders(
                        page: 1,
                        total: variant == 'present' || variant == 'foreignAward'
                            ? 1
                            : 0,
                      ),
              );
        final fixture = await _observationFixture(
          server,
          operation: 'removeAwardEmoji',
          mutationPath: 'projects/909/issues/3/award_emoji/55',
          method: 'DELETE',
          paths: {'projects/909/issues/3', 'projects/909/issues/3/award_emoji'},
        );
        if (variant == 'foreignActor') {
          server.routes['GET user'] = (_) =>
              mr7Json({'id': 8, 'username': 'other'});
        }
        if (variant == 'foreignParent') {
          server.routes['GET projects/909/issues/3'] = (_) =>
              mr7Json({..._issueRow(), 'project_id': 1000});
        }
        final observing = fixture.observer.observe(
          Mr7ListObservation(
            parent: _issueParent,
            kind: Mr7ListKind.awards,
            expectedIds: {},
          ),
        );
        if (variant == 'empty') {
          expect(await observing, isEmpty);
          expect(fixture.observer.verifiedRequests, greaterThan(0));
        } else {
          await expectLater(observing, throwsA(anything), reason: variant);
          expect(fixture.observer.verifiedRequests, 0);
          fixture.session.stop('testObservationFailed');
        }
        await fixture.session.finish();
      }
    },
  );

  test('complete list checks every page and exact note membership', () async {
    final server = Mr7SyntheticGitLab();
    final pages = <int>[];
    server.routes['GET projects/909/issues/3'] = (_) => mr7Json(_issueRow());
    server.routes['GET projects/909/issues/3/notes'] = (request) {
      final page = request.queryParameters['page'] as int;
      pages.add(page);
      return mr7Json([
        {'id': page + 70, 'noteable_id': 300},
      ], headers: _pageHeaders(page: page, total: 2));
    };
    final fixture = await _observationFixture(
      server,
      paths: {'projects/909/issues/3', 'projects/909/issues/3/notes'},
    );
    await fixture.observer.observe(
      Mr7ListObservation(
        parent: _issueParent,
        kind: Mr7ListKind.notes,
        expectedIds: {71, 72},
      ),
    );
    expect(pages, [1, 2]);
    await expectLater(
      fixture.observer.observe(
        Mr7ListObservation(
          parent: _issueParent,
          kind: Mr7ListKind.notes,
          expectedIds: {71},
        ),
      ),
      throwsA(anything),
    );
    await fixture.session.finish();
  });

  test(
    'typed discussion binds string ID, parent, exact notes and resolution',
    () async {
      final server = Mr7SyntheticGitLab();
      server.routes['GET projects/909/issues/3'] = (_) => mr7Json(_issueRow());
      final discussion = <String, Object?>{
        'id': 'opaque-thread',
        'notes': [
          {'id': 71, 'noteable_id': 300, 'resolved': true},
          {'id': 72, 'noteable_id': 300, 'resolved': true},
        ],
      };
      server.routes['GET projects/909/issues/3/discussions/opaque-thread'] =
          (_) => mr7Json(discussion);
      final fixture = await _observationFixture(
        server,
        operation: 'createDiscussion',
        mutationPath: 'projects/909/issues/3/discussions',
        response: {'id': 'opaque-thread'},
        status: 201,
        paths: {
          'projects/909/issues/3',
          'projects/909/issues/3/discussions/opaque-thread',
        },
      );
      expect(fixture.observer.result.stringId, 'opaque-thread');
      await fixture.observer.observe(
        Mr7DiscussionObservation(
          parent: _issueParent,
          discussionId: 'opaque-thread',
          noteIds: {71, 72},
          resolved: true,
        ),
      );
      for (final spec in [
        Mr7DiscussionObservation(
          parent: _issueParent,
          discussionId: 'other',
          noteIds: {71, 72},
          resolved: true,
        ),
        Mr7DiscussionObservation(
          parent: _issueParent,
          discussionId: 'opaque-thread',
          noteIds: {71},
          resolved: true,
        ),
        Mr7DiscussionObservation(
          parent: _issueParent,
          discussionId: 'opaque-thread',
          noteIds: {71, 72},
          resolved: false,
        ),
      ]) {
        await expectLater(fixture.observer.observe(spec), throwsA(anything));
      }
      await fixture.session.finish();
    },
  );

  test('milestone uses global ID while preserving a distinct iid', () async {
    final server = Mr7SyntheticGitLab();
    server.routes['GET projects/909/milestones/500'] = (_) =>
        mr7Json({'id': 500, 'iid': 5, 'project_id': 909});
    final fixture = await _observationFixture(
      server,
      operation: 'createMilestone',
      mutationPath: 'projects/909/milestones',
      response: {'id': 500, 'iid': 5, 'project_id': 909},
      status: 201,
      paths: {'projects/909/milestones/500', 'projects/909/milestones/5'},
    );
    expect(
      (await fixture.observer.observe(
        const Mr7MilestoneObservation(id: 500, iid: 5),
      ))['id'],
      500,
    );
    expect(
      (await fixture.observer.read('projects/909/milestones/500'))['iid'],
      5,
    );
    await expectLater(
      fixture.observer.read('projects/909/milestones/5'),
      throwsA(anything),
    );
    expect(server.requests, isNot(contains('GET projects/909/milestones/5')));
    await fixture.session.finish();
  });

  test(
    'approval observer verifies approved_by against the bound actor and MR',
    () async {
      final server = Mr7SyntheticGitLab();
      server.routes['GET projects/909/merge_requests/4'] = (_) =>
          mr7Json(_mrRow());
      final approvals = <String, Object?>{
        'id': 400,
        'iid': 4,
        'approved_by': [
          {
            'user': {'id': 7},
          },
        ],
      };
      server.routes['GET projects/909/merge_requests/4/approvals'] = (_) =>
          mr7Json(approvals);
      final fixture = await _observationFixture(
        server,
        operation: 'approveMergeRequest',
        mutationPath: 'projects/909/merge_requests/4/approve',
        paths: {
          'projects/909/merge_requests/4',
          'projects/909/merge_requests/4/approvals',
        },
      );
      expect(
        await fixture.observer.observe(
          const Mr7ApprovalObservation(parent: _mrParent, approved: true),
        ),
        isTrue,
      );
      await expectLater(
        fixture.observer.observe(
          const Mr7ApprovalObservation(parent: _mrParent, approved: false),
        ),
        throwsA(anything),
      );
      approvals['approved_by'] = [];
      await expectLater(
        fixture.observer.observe(
          const Mr7ApprovalObservation(parent: _mrParent, approved: false),
        ),
        throwsA(anything),
      );
      await fixture.session.finish();
    },
  );
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
        'numericNoteable',
        'invalidNoteable',
        'numericAwardable',
        'invalidAwardable',
        'literalNoteable',
        'literalAwardable',
      ]) {
        final field = variant == 'group' ? 'group' : 'synthetic';
        final argument = switch (variant) {
          'foreignId' => r'projectId: $destination',
          'nested' => r'input: {projectId: $destination}',
          'numericNoteable' ||
          'invalidNoteable' => r'input: {noteableId: $destination}',
          'numericAwardable' ||
          'invalidAwardable' => r'input: {awardableId: $destination}',
          'literalNoteable' =>
            'input: {noteableId: "gid://gitlab/Project/909"}',
          'literalAwardable' =>
            'input: {awardableId: "gid://gitlab/Project/909"}',
          _ => r'fullPath: $destination',
        };
        final document =
            '$kind X(\$destination: ID!) { $field($argument) { id } }';
        final vars = {
          'destination': switch (variant) {
            'foreignId' || 'nested' => 777,
            'numericNoteable' || 'numericAwardable' => 42,
            'literalNoteable' ||
            'literalAwardable' => 'gid://gitlab/Project/909',
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
      server.routes['GET $path'] = (_) => mr7Json({
        'id': 44,
        'project_id': 909,
        if (entry.key == 'Issue' || entry.key == 'MergeRequest') 'iid': 4,
        if (entry.key == 'Note') 'noteable_id': 44,
      });
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
        return mr7Json({'id': 44, 'iid': 44, 'project_id': owner});
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
          mr7Json({'id': 44, 'iid': 44, 'project_id': 909});
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
