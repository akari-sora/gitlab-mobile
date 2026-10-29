import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_levels.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';

import '../../tool/mr7/sandbox_contract.dart';
import '../../tool/mr7_sandbox.dart' as sandbox;

const _sha = '0123456789abcdef0123456789abcdef01234567';

Mr7SandboxSession _session(Mr7SyntheticGitLab server) => Mr7SandboxSession(
  server: server,
  nonce: 'wave3testnonce',
  requestCap: 500,
  eventDelay: () async {},
);

GitLabApi _api(Mr7SandboxSession session) => GitLabApi(
  instance: GitLabInstance.parse(session.instance.toString()),
  token: 'synthetic-wave3-pat',
  dio: session.writer,
  cdnAdapter: session.writerAdapter,
);

List<Map<String, Object?>> _rows(Map<String, Object?> receipt) =>
    (receipt['scenarios']! as List).cast<Map<String, Object?>>();

Map<String, List<String>> _headers(int count, {bool incomplete = false}) => {
  'x-page': ['1'],
  'x-per-page': ['100'],
  'x-total': ['$count'],
  'x-total-pages': ['1'],
  'x-next-page': [incomplete ? '2' : ''],
};

sandbox.Mr7Scenario _star({
  String id = 'star',
  String tier = 'T1',
  bool noChange = false,
  bool? witness,
  bool stateMismatch = false,
}) => sandbox.Mr7Scenario(
  id: id,
  suite: 'rest',
  operation: 'setStar',
  variant: id,
  tier: tier,
  expectedMutations: noChange ? 0 : 1,
  freshness: noChange
      ? (session, _) async {
          if (stateMismatch) session.server.project!['starred'] = true;
          return const AiWriteFreshness(
            noChange: true,
            visibilityUnreadable: false,
            sourceVisibilityUnreadable: false,
            targetVisibility: 'private',
          );
        }
      : null,
  call: (p) => AiToolCall(
    id: id,
    name: 'setStar',
    arguments: {
      'projectId': p.projectId,
      'starred': !noChange,
      'reason': 'Synthetic star request.',
    },
  ),
  paths: (p) => {
    'POST projects/${p.projectId}/${noChange ? 'unstar' : 'star'}',
  },
  noChangeObservation: witness == null
      ? null
      : (_) => Mr7ParentStateObservation(
          parent: const Mr7Parent.project(),
          state: Mr7ParentState.starred,
          expected: witness,
        ),
  observe: (observer, p) async =>
      (await observer.read('projects/${p.projectId}'))['starred'] == true,
);

Future<Map<String, Object?>> _run(
  Mr7SyntheticGitLab server,
  List<sandbox.Mr7Scenario> scenarios, {
  Future<bool> Function(sandbox.Mr7HostProposal)? confirm,
}) => sandbox.runMr7Sandbox(
  policy: Mr7Policy.candidate,
  releaseSha: _sha,
  session: _session(server),
  scenarios: scenarios,
  confirm: confirm ?? (_) async => true,
);

void main() {
  test(
    'production fragment checker accepts safe snippet and refuses redaction marker',
    () async {
      for (final content in [
        'Synthetic file text.',
        'Polluted synthetic text.',
        '[REDACTED]',
        'glpat-${'x' * 24}',
      ]) {
        final server = Mr7SyntheticGitLab();
        var confirmations = 0;
        final scenario = sandbox.Mr7Scenario(
          id: 'snippet',
          suite: 'advanced',
          operation: 'createSnippet',
          variant: 'fragment-check',
          tier: 'T2',
          freshness: content.startsWith('Polluted')
              ? (_, _) async => const AiWriteFreshness(
                  polluted: true,
                  visibilityUnreadable: false,
                  sourceVisibilityUnreadable: false,
                  targetVisibility: 'private',
                )
              : null,
          targetKind: AiTargetKind.project,
          targetKinds: {AiTargetKind.project, AiTargetKind.snippet},
          utterance: (p) => 'Create a private snippet in project ${p.path}.',
          call: (p) => AiToolCall(
            id: 'snippet',
            name: 'createSnippet',
            arguments: {
              'projectId': p.projectId,
              'title': 'Synthetic snippet',
              'description': 'Synthetic description',
              'visibility': 'private',
              'path': 'fixture.txt',
              'content': content,
            },
          ),
          paths: (p) => {'POST projects/${p.projectId}/snippets'},
          observe: (_, _) async => false,
          expectedMutations: 0,
        );
        final receipt = await _run(
          server,
          [scenario],
          confirm: (_) async {
            confirmations++;
            return false;
          },
        );
        final row = _rows(receipt).single;
        if (content.startsWith('[REDACTED') || content.startsWith('glpat-')) {
          expect(confirmations, 0, reason: jsonEncode(receipt));
          expect(
            row['reason'],
            content.startsWith('glpat-') ? 'secret' : 'redactionMarker',
            reason: jsonEncode(receipt),
          );
          expect(row['decisionProjection'], 'unavailable');
          expect(row['decisionUnavailable'], 'proposalUnavailable');
          expect(row['tier'], isNull);
          expect(row['decision'], isNull);
        } else {
          expect(confirmations, 1, reason: jsonEncode(receipt));
          expect(row['reason'], 'refused', reason: jsonEncode(receipt));
          expect(row['decisionProjection'], 'observed');
          if (content.startsWith('Polluted')) {
            expect(row['decision'], 'requireApproval');
            expect(
              row['confirmationReasons'],
              contains('confidentialOrVisibilityMix'),
            );
          }
        }
        expect(server.scenarioWrites, 0);
      }
    },
  );
  test(
    'zero dispatch noChange requires a matching independent witness',
    () async {
      for (final variant in [
        'missing',
        'mismatched',
        'stateMismatch',
        'matching',
      ]) {
        final server = Mr7SyntheticGitLab();
        final receipt = await _run(server, [
          _star(
            id: 'noop',
            noChange: true,
            witness: variant == 'missing' ? null : variant == 'mismatched',
            stateMismatch: variant == 'stateMismatch',
          ),
          _star(id: 'following'),
        ]);
        final row = _rows(receipt).first;
        expect(row['mutationCount'], 0, reason: jsonEncode(receipt));
        expect(row['coreNoChange'], isTrue, reason: jsonEncode(receipt));
        if (variant == 'matching') {
          expect(row['status'], 'PASS', reason: jsonEncode(receipt));
          expect(row['classification'], 'verifiedNoOp');
          expect(row['parentStateVerified'], true);
          expect(row['observerRequests'], greaterThan(0));
          expect(_rows(receipt).last['status'], 'PASS');
        } else {
          expect(row['status'], 'NOT_VERIFIED', reason: jsonEncode(receipt));
          expect(
            row['reason'],
            variant == 'stateMismatch' ? 'observerState' : 'noChangeUnverified',
          );
          expect(_rows(receipt).last['status'], 'NOT_RUN');
          expect(receipt['quarantined'], true);
          expect(server.cleanupWrites, 0);
        }
      }
    },
  );

  test(
    'zero-dispatch subscription binds witness to prepared numeric parent id',
    () async {
      for (final replaced in [false, true]) {
        final server = Mr7SyntheticGitLab();
        const path = 'projects/909/issues/3';
        server.routes['GET $path'] = (request) {
          final observing = request.headers.entries.any(
            (entry) =>
                entry.key.toLowerCase() == 'cache-control' &&
                '${entry.value}'.contains('no-cache'),
          );
          return mr7Json({
            'id': replaced && observing ? 999 : 300,
            'iid': 3,
            'project_id': 909,
            'subscribed': false,
            'confidential': false,
            'state': 'opened',
            'title': 'Synthetic issue',
          });
        };
        final scenario = sandbox.Mr7Scenario(
          id: 'subscription-noop',
          suite: 'rest',
          operation: 'setSubscribed',
          variant: 'no-change',
          tier: 'T1',
          targetKind: AiTargetKind.issue,
          targetKinds: {AiTargetKind.project, AiTargetKind.issue},
          expectedMutations: 0,
          freshness: (_, _) async => const AiWriteFreshness(
            noChange: true,
            visibilityUnreadable: false,
            sourceVisibilityUnreadable: false,
            targetVisibility: 'private',
          ),
          resource: (_) =>
              const AiResourceRef(kind: AiResourceKind.issue, id: 3),
          utterance: (p) => 'Keep issue #3 unsubscribed in ${p.path}.',
          call: (p) => AiToolCall(
            id: 'subscription-noop',
            name: 'setSubscribed',
            arguments: {
              'projectId': p.projectId,
              'resource': 'issues',
              'iid': 3,
              'subscribed': false,
              'reason': 'Keep this synthetic issue unsubscribed.',
            },
          ),
          paths: (_) => {'POST $path/unsubscribe'},
          readbackPaths: (_, _) => {path},
          noChangeObservation: (_) => Mr7ParentStateObservation(
            parent: Mr7Parent.issue(id: replaced ? 999 : 300, iid: 3),
            state: Mr7ParentState.subscribed,
            expected: false,
          ),
          observe: (_, _) async => false,
        );
        final receipt = await _run(server, [scenario]);
        final row = _rows(receipt).single;
        expect(row['coreNoChange'], true, reason: jsonEncode(receipt));
        expect(row['mutationCount'], 0);
        expect(
          row['status'],
          replaced ? 'NOT_VERIFIED' : 'PASS',
          reason: jsonEncode(receipt),
        );
        if (replaced) {
          expect(receipt['quarantined'], true);
          expect(server.cleanupWrites, 0);
        } else {
          expect(row['parentStateVerified'], true);
        }
      }
    },
  );

  test('bypass records the automatic execute decision', () async {
    final server = Mr7SyntheticGitLab();
    final receipt = await sandbox.runMr7Sandbox(
      policy: Mr7Policy.candidate,
      releaseSha: _sha,
      session: _session(server),
      conversationId: 'same-conversation',
      level: AiAutonomyLevel.bypass,
      scenarios: [_star(id: 'first')],
      confirm: (_) async => true,
    );
    final rows = _rows(receipt);
    expect(rows.first['status'], 'PASS', reason: jsonEncode(receipt));
    expect(rows.first['tier'], 'T1');
    expect(rows.first['decisionProjection'], 'observed');
    expect(rows.first['decision'], 'execute');
    expect(server.scenarioWrites, 1);
  });

  test('mutation ledger binds repeated operations to scenario ids', () async {
    final server = Mr7SyntheticGitLab();
    final receipt = await _run(server, [
      _star(id: 'first'),
      _star(id: 'second'),
    ]);
    expect(_rows(receipt).map((row) => row['status']), ['PASS', 'PASS']);
    final writes = (receipt['requestLedger']! as List)
        .cast<Map<String, Object?>>()
        .where((entry) => entry['operation'] == 'setStar');
    expect(writes.map((entry) => entry['scenarioId']), ['first', 'second']);
    expect(server.scenarioWrites, 2);
  });

  test(
    'observed decision is projected and mismatched tier fails before write',
    () async {
      for (final mismatch in [false, true]) {
        final server = Mr7SyntheticGitLab();
        final receipt = await _run(server, [
          _star(tier: mismatch ? 'T2' : 'T1'),
        ]);
        final row = _rows(receipt).single;
        expect(row['declaredTier'], mismatch ? 'T2' : 'T1');
        expect(row['tier'], 'T1', reason: jsonEncode(receipt));
        expect(row['decisionProjection'], 'observed');
        expect(row['decision'], isIn(['execute', 'requireApproval']));
        expect(row['confirmationReasons'], isA<List<Object?>>());
        expect(
          row['status'],
          mismatch ? 'FAIL' : 'PASS',
          reason: jsonEncode(receipt),
        );
        if (mismatch) {
          expect(row['reason'], 'tierMismatch');
          expect(row['mutationCount'], 0);
          expect(server.scenarioWrites, 0);
        }
      }
    },
  );

  test(
    'GraphQL payload stays sealed across asynchronous confirmation',
    () async {
      const document =
          r'mutation Write($id: ID!) { synthetic(id: $id) { id } }';
      for (final variant in [
        'query',
        'variables',
        'replacement',
        'nonJson',
        'cycle',
        'initialNonJson',
        'initialCycle',
        'identityNonJson',
        'identityCycle',
      ]) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        final variables = <String, Object?>{
          'id': 'gid://gitlab/Project/909',
          'title': 'Original',
        };
        final body = <String, Object?>{
          'query': document,
          'variables': variables,
        };
        final request = RequestOptions(
          path: '${session.instance}/api/graphql',
          method: 'POST',
          data: body,
          followRedirects: false,
        );
        var confirmations = 0;
        final permit =
            Mr7MutationPermit(
                operation: 'updateWorkItemState',
                paths: {'POST graphql'},
                resourceProjectId: 909,
                graphDocuments: {document},
                graphVariablesDigests: {mr7Digest(variables)},
              )
              ..confirmBeforeSend = () async {
                confirmations++;
                await Future<void>.value();
                if (variant == 'query') {
                  body['query'] = '$document ';
                } else if (variant == 'variables') {
                  variables['title'] = 'Changed';
                } else if (variant == 'nonJson') {
                  variables['title'] = Object();
                } else if (variant == 'cycle') {
                  variables['cycle'] = variables;
                } else {
                  request.data = {
                    'query': '$document ',
                    'variables': variables,
                  };
                }
                return true;
              };
        session.permit = permit;
        void invalidateBody() {
          if (variant.endsWith('Cycle')) {
            variables['cycle'] = variables;
          } else {
            variables['title'] = Object();
          }
        }

        if (variant.startsWith('initial')) {
          invalidateBody();
        } else if (variant.startsWith('identity')) {
          server.routes['GET projects/909'] = (_) {
            invalidateBody();
            return mr7Json(server.project!);
          };
        }
        var sends = 0;
        server.routes['POST /install/api/graphql'] = (_) {
          sends++;
          return mr7Json({'id': 909});
        };
        await expectLater(
          session.writerAdapter.fetch(request, null, null),
          throwsA(isA<Mr7Refused>()),
          reason: variant,
        );
        expect(
          confirmations,
          variant.startsWith('initial') || variant.startsWith('identity')
              ? 0
              : 1,
          reason: variant,
        );
        expect(sends, 0, reason: variant);
        expect(permit.sent, 0);
        expect(session.stopReason, 'unsealedGraph');
        expect(session.quarantined, true);
        await session.finish();
        expect(server.cleanupWrites, 0);
      }
    },
  );

  test(
    'HEAD file metadata stays inside project and does not dispatch a mutation',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      server.routes['HEAD projects/909/repository/files/dir/file.txt'] =
          (request) {
            expect(request.queryParameters, isEmpty);
            expect(request.uri.queryParametersAll, {
              'ref': ['main'],
            });
            return ResponseBody.fromBytes(
              [],
              200,
              headers: {
                'x-gitlab-content-sha256': ['a' * 64],
                'x-gitlab-last-commit-id': [_sha],
                'x-gitlab-size': ['42'],
              },
            );
          };
      final permit = Mr7MutationPermit(
        operation: 'edit_file',
        paths: {},
        resourceProjectId: 909,
      )..confirmed = true;
      session.permit = permit;
      int requestCount() =>
          session.receipt(
                policy: Mr7Policy.candidate,
                releaseSha: _sha,
                scenarios: [],
                releasePolicy: mr7SandboxPolicy(Mr7Policy.candidate),
              )['requestCount']!
              as int;
      final before = requestCount();
      final metadata = await _api(
        session,
      ).fileMetadata(909, 'dir/file.txt', 'main');
      expect(metadata, {'last_commit_id': _sha, 'size': 42});
      expect(requestCount(), before + 1);
      expect(permit.sent, 0);
      expect(server.scenarioWrites, 0);
      expect(
        session.requestLedger.where((e) => e['method'] == 'HEAD'),
        isEmpty,
      );
      await expectLater(
        session.writer.head<Object?>(
          'projects/777/repository/files/dir%2Ffile.txt',
          queryParameters: {'ref': 'main'},
        ),
        throwsA(anything),
      );
      expect(
        server.requests,
        isNot(contains('HEAD projects/777/repository/files/dir/file.txt')),
      );
      expect(permit.sent, 0);
      await session.finish();
    },
  );

  test('HEAD validates the final URI query and exact file route', () async {
    for (final uri in [
      'projects/909/repository/files/a.txt?ref=main&extra=value',
      'projects/909/repository/files/a.txt?ref=main&ref=other',
      'projects/909/repository/files/a.txt?ref=main&%72ef=other',
      'projects/909/repository/files/a.txt?ref=',
      'projects/909/repository/files/a.txt?ref=${'a' * 1025}',
      'projects/909/repository/files/a.txt',
      'projects/777/repository/files/a.txt?ref=main',
      'projects/909/repository/files/a.txt/raw?ref=main',
      'projects/909/boards/801?ref=main',
    ]) {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      var served = false;
      server.routes['HEAD projects/909/repository/files/a.txt'] = (_) {
        served = true;
        return ResponseBody.fromBytes([], 200);
      };
      await expectLater(
        session.writer.head<Object?>(uri),
        throwsA(anything),
        reason: uri,
      );
      expect(served, false, reason: uri);
      expect(server.requests.where((r) => r.startsWith('HEAD ')), isEmpty);
      expect(session.quarantined, true);
      expect(server.scenarioWrites, 0);
      await session.finish();
    }
  });

  test('HEAD charges the shared cap and refuses when exhausted', () async {
    final server = Mr7SyntheticGitLab();
    final session = Mr7SandboxSession(
      server: server,
      nonce: 'wave3headcap',
      requestCap: 50,
      eventDelay: () async {},
    );
    await session.initialize();
    const path = 'projects/909/repository/files/a.txt';
    server.routes['HEAD $path'] = (_) => ResponseBody.fromBytes([], 200);
    final count =
        session.receipt(
              policy: Mr7Policy.candidate,
              releaseSha: _sha,
              scenarios: [],
              releasePolicy: mr7SandboxPolicy(Mr7Policy.candidate),
            )['requestCount']!
            as int;
    expect(count, lessThan(session.requestCap));
    for (var i = count; i < session.requestCap; i++) {
      await session.writer.head<Object?>(
        path,
        queryParameters: {'ref': 'main'},
      );
    }
    final served = server.requests
        .where((request) => request == 'HEAD $path')
        .length;
    expect(served, session.requestCap - count);
    await expectLater(
      session.writer.head<Object?>(path, queryParameters: {'ref': 'main'}),
      throwsA(anything),
    );
    expect(
      server.requests.where((request) => request == 'HEAD $path').length,
      served,
    );
    expect(session.quarantined, true);
    expect(session.stopReason, 'httpBudget');
    expect(server.scenarioWrites, 0);
    await session.finish();
  });

  test('HEAD rejects bodies and stays closed during quarantine', () async {
    for (final variant in ['requestBody', 'responseBody', 'quarantine']) {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      const path = 'projects/909/repository/files/a.txt';
      server.routes['HEAD $path'] = (_) =>
          ResponseBody.fromBytes(variant == 'responseBody' ? [42] : [], 200);
      if (variant == 'quarantine') session.stop('test');
      await expectLater(
        session.writer.request<Object?>(
          path,
          data: variant == 'requestBody' ? {'unexpected': 'body'} : null,
          queryParameters: {'ref': 'main'},
          options: Options(method: 'HEAD'),
        ),
        throwsA(anything),
        reason: variant,
      );
      expect(session.quarantined, true);
      expect(server.scenarioWrites, 0);
      if (variant != 'responseBody') {
        expect(server.requests, isNot(contains('HEAD $path')));
      }
      await session.finish();
    }
  });

  for (final variant in ['absent', 'present', 'appears', 'disappears']) {
    test('draft note text update preserves body presence: $variant', () async {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      const path = 'projects/909/merge_requests/4/draft_notes/71';
      final row = <String, Object?>{
        'id': 71,
        'author_id': 7,
        'merge_request_id': 400,
        'note': 'Original',
        'commit_id': null,
        'position': null,
        if (variant == 'present' || variant == 'disappears') 'body': 'Original',
      };
      server.routes['GET $path'] = (_) => mr7Json(row);
      server.routes['GET projects/909/merge_requests/4'] = (_) =>
          mr7Json({'id': 400, 'iid': 4, 'project_id': 909});
      final saved = await session.captureSnapshot([
        Mr7SnapshotSpec.draftNote(path: path),
      ]);
      final permit =
          Mr7MutationPermit(
              operation: 'updateDraftNote',
              paths: {'PUT $path'},
              resourceProjectId: 909,
            )
            ..confirmed = true
            ..snapshot = saved;
      session.permit = permit;
      server.routes['PUT $path'] = (request) {
        expect(request.data, {'note': 'Changed'});
        row['note'] = 'Changed';
        if (variant == 'present' || variant == 'appears') {
          row['body'] = 'Changed';
        }
        if (variant == 'disappears') row.remove('body');
        server.scenarioWrites++;
        server.addEvent(target: 909);
        return mr7Json(row);
      };
      await _api(session).updateDraftNote(909, 4, 71, 'Changed');
      final observer = Mr7Readback(
        session,
        session.identity!,
        permit,
        paths: {path, 'projects/909/merge_requests/4'},
      );
      expect(
        await observer.verifySnapshot(),
        variant == 'absent' || variant == 'present',
      );
      expect(permit.sent, 1);
      await session.finish();
    });
  }

  for (final variant in ['nameOnly', 'colorDrift', 'descriptionDrift']) {
    test('production label rename verifies omitted fields: $variant', () async {
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      const path = 'projects/909/labels/701';
      final row = <String, Object?>{
        'id': 701,
        'is_project_label': true,
        'name': 'Original',
        'color': '#abcdef',
        'description': 'Preserved',
      };
      server.routes['GET $path'] = (_) => mr7Json(row);
      final saved = await session.captureSnapshot([
        Mr7SnapshotSpec.label(path: path),
      ]);
      final permit =
          Mr7MutationPermit(
              operation: 'updateLabel',
              paths: {'PUT $path'},
              resourceProjectId: 909,
            )
            ..confirmed = true
            ..snapshot = saved;
      session.permit = permit;
      server.routes['PUT $path'] = (request) {
        expect(request.data, {'new_name': 'Renamed'});
        row['name'] = (request.data as Map)['new_name'];
        if (variant == 'colorDrift') row['color'] = '#123456';
        if (variant == 'descriptionDrift') row['description'] = 'Unrequested';
        server.scenarioWrites++;
        server.addEvent(target: 909);
        return mr7Json(row);
      };
      final updated = await _api(
        session,
      ).updateLabel(909, 701, {'name': 'Renamed'});
      expect(updated['name'], 'Renamed');
      final observer = Mr7Readback(
        session,
        session.identity!,
        permit,
        paths: {path},
      );
      expect(await observer.verifySnapshot(), variant == 'nameOnly');
      expect(permit.sent, 1);
      await session.finish();
    });
  }

  for (final phase in ['capture', 'preSend', 'readback']) {
    test('typed REST identity fences hold at $phase', () async {
      for (final variant in [
        'boardProject',
        'labelId',
        'labelGroup',
        'draftAuthor',
        'draftParent',
        'draftParentProject',
        'draftParentId',
        'draftParentIid',
      ]) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        final draft = variant.startsWith('draft');
        final board = variant.startsWith('board');
        final path = draft
            ? 'projects/909/merge_requests/4/draft_notes/71'
            : board
            ? 'projects/909/boards/801'
            : 'projects/909/labels/701';
        final spec = draft
            ? Mr7SnapshotSpec.draftNote(path: path)
            : board
            ? Mr7SnapshotSpec.board(path: path)
            : Mr7SnapshotSpec.label(path: path);
        final row = <String, Object?>{
          if (draft) ...{
            'id': 71,
            'author_id': 7,
            'merge_request_id': 400,
            'note': 'Original',
            'commit_id': null,
            'position': null,
          } else if (board) ...{
            'id': 801,
            'project': {'id': 909},
            'name': 'Original',
            'hide_backlog_list': false,
            'hide_closed_list': false,
          } else ...{
            'id': 701,
            'is_project_label': true,
            'name': 'Original',
            'color': '#abcdef',
            'description': 'Preserved',
          },
        };
        final parent = <String, Object?>{
          'id': 400,
          'iid': 4,
          'project_id': 909,
        };
        server.routes['GET $path'] = (_) => mr7Json(row);
        server.routes['GET projects/909/merge_requests/4'] = (_) =>
            mr7Json(parent);
        void drift() {
          switch (variant) {
            case 'boardProject':
              row['project'] = {'id': 777};
            case 'labelId':
              row['id'] = 702;
            case 'labelGroup':
              row['is_project_label'] = false;
            case 'draftAuthor':
              row['author_id'] = 8;
            case 'draftParent':
              row['merge_request_id'] = 401;
            case 'draftParentProject':
              parent['project_id'] = 777;
            case 'draftParentId':
              parent['id'] = 401;
            case 'draftParentIid':
              parent['iid'] = 5;
          }
        }

        if (phase == 'capture') {
          drift();
          await expectLater(
            session.captureSnapshot([spec]),
            throwsA(anything),
            reason: variant,
          );
          expect(server.scenarioWrites, 0);
          await session.finish();
          continue;
        }
        final saved = await session.captureSnapshot([spec]);
        final permit =
            Mr7MutationPermit(
                operation: draft
                    ? 'updateDraftNote'
                    : board
                    ? 'renameBoard'
                    : 'updateLabel',
                paths: {'PUT $path'},
                resourceProjectId: 909,
              )
              ..confirmed = true
              ..snapshot = saved;
        session.permit = permit;
        if (phase == 'preSend') drift();
        server.routes['PUT $path'] = (_) {
          row[draft ? 'note' : 'name'] = 'Changed';
          if (phase == 'readback') drift();
          server.scenarioWrites++;
          server.addEvent(target: 909);
          return mr7Json(row);
        };
        Future<Object?> update() => session.writer.put<Object?>(
          path,
          data: {draft ? 'note' : 'name': 'Changed'},
        );
        if (phase == 'preSend') {
          await expectLater(update(), throwsA(anything), reason: variant);
          expect(permit.sent, 0, reason: variant);
          expect(server.scenarioWrites, 0, reason: variant);
        } else {
          await update();
          final observer = Mr7Readback(
            session,
            session.identity!,
            permit,
            paths: {path, if (draft) 'projects/909/merge_requests/4'},
          );
          if (variant == 'draftParentProject') {
            await expectLater(
              observer.verifySnapshot(),
              throwsA(
                isA<Mr7Refused>().having(
                  (e) => e.code,
                  'code',
                  'readbackIdentity',
                ),
              ),
            );
          } else {
            expect(await observer.verifySnapshot(), false, reason: variant);
          }
          expect(permit.sent, 1, reason: variant);
        }
        await session.finish();
      }
    });
  }

  test('typed labels refuse a foreign project route', () async {
    final server = Mr7SyntheticGitLab();
    final session = _session(server);
    await session.initialize();
    const path = 'projects/777/labels/701';
    await expectLater(
      session.captureSnapshot([Mr7SnapshotSpec.label(path: path)]),
      throwsA(anything),
    );
    expect(server.requests, isNot(contains('GET $path')));
    expect(server.scenarioWrites, 0);
    await session.finish();
  });

  test(
    'typed milestone snapshot detects omitted date drift and binds global id and iid',
    () async {
      for (final altered in [false, true]) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        final record = <String, Object?>{
          'id': 501,
          'iid': 3,
          'project_id': 909,
          'title': 'Synthetic',
          'description': 'Preserved',
          'start_date': '2026-01-01',
          'due_date': '2026-02-01',
          'state': 'active',
        };
        const path = 'projects/909/milestones/501';
        server.routes['GET $path'] = (_) => mr7Json(record);
        final saved = await session.captureSnapshot([
          Mr7SnapshotSpec.milestone(path: path),
        ]);
        expect(jsonEncode(saved.metadata), isNot(contains('Preserved')));
        server.routes['PUT $path'] = (_) {
          record['state'] = 'closed';
          if (altered) record['due_date'] = null;
          server.scenarioWrites++;
          server.addEvent(target: 909);
          return mr7Json(record);
        };
        final permit =
            Mr7MutationPermit(
                operation: 'setMilestoneState',
                paths: {'PUT $path'},
                resourceProjectId: 909,
              )
              ..confirmed = true
              ..snapshot = saved;
        session.permit = permit;
        await session.writer.put<Object?>(path, data: {'state_event': 'close'});
        final observer = Mr7Readback(
          session,
          session.identity!,
          permit,
          paths: {path},
        );
        expect(await observer.verifySnapshot(), !altered);
        await session.finish();
      }
    },
  );

  test(
    'typed snapshots reject identity and omitted-field drift before send',
    () async {
      for (final variant in [
        'iid',
        'gid',
        'id',
        'project',
        'presence',
        'parent',
      ]) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        final draft = variant == 'parent';
        final path = draft
            ? 'projects/909/merge_requests/4/draft_notes/71'
            : 'projects/909/milestones/501';
        final row = <String, Object?>{
          if (draft) ...{
            'id': 71,
            'note': 'before',
            'author_id': 7,
            'merge_request_id': 400,
          } else ...{
            'id': 501,
            'iid': 3,
            'project_id': 909,
            'global_id': 'gid://gitlab/Milestone/501',
            'title': 'before',
            'description': '',
            'state': 'active',
            'start_date': null,
          },
        };
        var parentId = 400;
        server.routes['GET $path'] = (_) => mr7Json(row);
        server.routes['GET projects/909/merge_requests/4'] = (_) =>
            mr7Json({'id': parentId, 'iid': 4, 'project_id': 909});
        final saved = await session.captureSnapshot([
          draft
              ? Mr7SnapshotSpec.draftNote(path: path)
              : Mr7SnapshotSpec.milestone(path: path),
        ]);
        switch (variant) {
          case 'iid':
            row['iid'] = 4;
          case 'gid':
            row['global_id'] = 'gid://gitlab/Milestone/777';
          case 'id':
            row['id'] = 502;
          case 'project':
            row['project_id'] = 777;
          case 'presence':
            row.remove('start_date');
          case 'parent':
            parentId = 401;
        }
        var dispatched = false;
        server.routes['PUT $path'] = (_) {
          dispatched = true;
          return mr7Json(row);
        };
        final permit =
            Mr7MutationPermit(
                operation: draft ? 'updateDraftNote' : 'updateMilestone',
                paths: {'PUT $path'},
                resourceProjectId: 909,
              )
              ..confirmed = true
              ..snapshot = saved;
        session.permit = permit;
        await expectLater(
          session.writer.put<Object?>(
            path,
            data: draft ? {'note': 'after'} : {'title': 'after'},
          ),
          throwsA(anything),
          reason: variant,
        );
        expect(dispatched, false, reason: variant);
        expect(session.quarantined, true, reason: variant);
        await session.finish();
      }
    },
  );

  test(
    'typed REST wire shapes verify updates and protect omitted fields',
    () async {
      final fixtures = [
        (
          path: 'projects/909/boards/801',
          op: 'renameBoard',
          changed: 'name',
          preserved: 'hide_closed_list',
          drift: true,
          spec: Mr7SnapshotSpec.board(path: 'projects/909/boards/801'),
          row: <String, Object?>{
            'id': 801,
            'project': {'id': 909},
            'lists': <Object?>[],
            'name': 'Board',
            'hide_backlog_list': false,
            'hide_closed_list': false,
          },
        ),
        (
          path: 'projects/909/labels/701',
          op: 'updateLabel',
          changed: 'description',
          preserved: 'color',
          drift: '#123456',
          spec: Mr7SnapshotSpec.label(path: 'projects/909/labels/701'),
          row: <String, Object?>{
            'id': 701,
            'is_project_label': true,
            'name': 'Label',
            'description': 'Original',
            'color': '#abcdef',
          },
        ),
        (
          path: 'projects/909/merge_requests/4/draft_notes/71',
          op: 'updateDraftNote',
          changed: 'note',
          preserved: 'position',
          drift: <String, Object?>{'base_sha': _sha},
          spec: Mr7SnapshotSpec.draftNote(
            path: 'projects/909/merge_requests/4/draft_notes/71',
          ),
          row: <String, Object?>{
            'id': 71,
            'note': 'Original',
            'author_id': 7,
            'merge_request_id': 400,
            'commit_id': null,
            'position': null,
          },
        ),
      ];
      for (final fixture in fixtures) {
        for (final altered in [false, true]) {
          final server = Mr7SyntheticGitLab();
          final session = _session(server);
          await session.initialize();
          server.routes['GET projects/909/merge_requests/4'] = (_) =>
              mr7Json({'id': 400, 'iid': 4, 'project_id': 909});
          final row = Map<String, Object?>.from(fixture.row);
          server.routes['GET ${fixture.path}'] = (_) => mr7Json(row);
          final saved = await session.captureSnapshot([fixture.spec]);
          server.routes['PUT ${fixture.path}'] = (request) {
            expect(request.data, {fixture.changed: 'Changed'});
            row[fixture.changed] = 'Changed';
            if (altered) row[fixture.preserved] = fixture.drift;
            server.scenarioWrites++;
            server.addEvent(target: 909);
            return mr7Json(row);
          };
          final permit =
              Mr7MutationPermit(
                  operation: fixture.op,
                  paths: {'PUT ${fixture.path}'},
                  resourceProjectId: 909,
                )
                ..confirmed = true
                ..snapshot = saved;
          session.permit = permit;
          final api = _api(session);
          switch (fixture.op) {
            case 'renameBoard':
              await api.renameBoard(909, 801, 'Changed');
            case 'updateLabel':
              await api.updateLabel(909, 701, {'description': 'Changed'});
            case 'updateDraftNote':
              await api.updateDraftNote(909, 4, 71, 'Changed');
          }
          final observer = Mr7Readback(
            session,
            session.identity!,
            permit,
            paths: {fixture.path, 'projects/909/merge_requests/4'},
          );
          expect(await observer.verifySnapshot(), !altered, reason: fixture.op);
          expect(permit.sent, 1);
          await session.finish();
        }
      }
      final server = Mr7SyntheticGitLab();
      final session = _session(server);
      await session.initialize();
      server.routes['GET projects/909/merge_requests/4'] = (_) =>
          mr7Json({'id': 400, 'iid': 4, 'project_id': 909});
      server.routes['GET projects/909/merge_requests/4/draft_notes/71'] = (_) =>
          mr7Json({'id': 71, 'author_id': 8, 'merge_request_id': 400});

      await expectLater(
        session.captureSnapshot([
          Mr7SnapshotSpec.draftNote(
            path: 'projects/909/merge_requests/4/draft_notes/71',
          ),
        ]),
        throwsA(anything),
      );
      await session.finish();
    },
  );

  test(
    'createTodo runner observes new issue and merge request todos',
    () async {
      for (final issue in [true, false]) {
        final server = Mr7SyntheticGitLab();
        final collection = issue ? 'issues' : 'merge_requests';
        final iid = issue ? 3 : 4;
        final parentId = issue ? 300 : 400;
        final parentPath = 'projects/909/$collection/$iid';
        server.routes['GET $parentPath'] = (_) => mr7Json({
          'id': parentId,
          'iid': iid,
          'project_id': 909,
          'title': 'Synthetic parent',
          'description': '',
          'confidential': false,
          'state': 'opened',
        });
        var sent = false;
        server.routes['GET projects/909/todos/mr7-observation'] = (_) {
          final list = <Map<String, Object?>>[
            if (sent)
              {
                'id': 55,
                'project_id': 909,
                'actor_id': 7,
                'author': {'id': 7},
                'target_type': issue ? 'Issue' : 'MergeRequest',
                'target_id': parentId,
                'target_iid': iid,
                'state': 'pending',
              },
          ];
          return mr7Json(list, headers: _headers(list.length));
        };
        server.routes['POST $parentPath/todo'] = (_) {
          sent = true;
          server.scenarioWrites++;
          server.addEvent(target: 909);
          return mr7Json({'id': 55, 'project_id': 909}, status: 201);
        };
        final scenario = sandbox.Mr7Scenario(
          id: 'created-todo',
          suite: 'rest',
          operation: 'createTodo',
          variant: collection,
          tier: 'T2',
          targetKind: issue ? AiTargetKind.issue : AiTargetKind.mergeRequest,
          targetKinds: {
            AiTargetKind.project,
            issue ? AiTargetKind.issue : AiTargetKind.mergeRequest,
          },
          resource: (_) => AiResourceRef(
            kind: issue ? AiResourceKind.issue : AiResourceKind.mergeRequest,
            id: iid,
          ),
          utterance: (p) =>
              'Create a todo for ${issue ? '#' : '!'}$iid in ${p.path}.',
          call: (p) => AiToolCall(
            id: 'created-todo',
            name: 'createTodo',
            arguments: {
              'projectId': p.projectId,
              'resource': collection,
              'iid': iid,
            },
          ),
          paths: (_) => {'POST $parentPath/todo'},
          readbackPaths: (_, _) => {
            parentPath,
            'projects/909/todos/mr7-observation',
          },
          observe: (observer, _) => observer.observe(
            Mr7CreatedTodoObservation(
              id: observer.result.id!,
              parent: issue
                  ? const Mr7Parent.issue(id: 300, iid: 3)
                  : const Mr7Parent.mergeRequest(id: 400, iid: 4),
            ),
          ),
        );
        final receipt = await _run(server, [scenario]);
        final row = _rows(receipt).single;
        expect(row['status'], 'PASS', reason: jsonEncode(receipt));
        expect(row['mutationCount'], 1);
        expect(row['observerRequests'], greaterThan(0));
      }
    },
  );
  test(
    'created todo requires complete project-owned actor and parent list',
    () async {
      for (final variant in [
        'issue',
        'mergeRequest',
        'foreign',
        'truncated',
        'reused',
        'wrongTarget',
        'wrongActor',
        'wrongAuthor',
        'done',
      ]) {
        final server = Mr7SyntheticGitLab();
        final session = _session(server);
        await session.initialize();
        final issue = variant != 'mergeRequest';
        final collection = issue ? 'issues' : 'merge_requests';
        final iid = issue ? 3 : 4;
        final parentId = issue ? 300 : 400;
        final parentPath = 'projects/909/$collection/$iid';
        server.routes['GET $parentPath'] = (_) =>
            mr7Json({'id': parentId, 'iid': iid, 'project_id': 909});
        var sent = false;
        Map<String, Object?> todo() => {
          'id': 55,
          'project_id': variant == 'foreign' && sent ? 777 : 909,
          'actor_id': variant == 'wrongActor' && sent ? 8 : 7,
          'author': {'id': variant == 'wrongAuthor' && sent ? 8 : 7},
          'target_type': issue ? 'Issue' : 'MergeRequest',
          'target_id': variant == 'wrongTarget' && sent ? 999 : parentId,
          'target_iid': iid,
          'state': variant == 'done' && sent ? 'done' : 'pending',
        };
        server.routes['GET projects/909/todos/mr7-observation'] = (_) {
          final list = sent || variant == 'reused'
              ? [todo()]
              : <Map<String, Object?>>[];
          return mr7Json(
            list,
            headers: _headers(
              list.length,
              incomplete: sent && variant == 'truncated',
            ),
          );
        };
        server.routes['POST $parentPath/todo'] = (_) {
          sent = true;
          server.scenarioWrites++;
          server.addEvent(target: 909);
          return mr7Json({'id': 55, 'project_id': 909}, status: 201);
        };
        final permit = Mr7MutationPermit(
          operation: 'createTodo',
          paths: {'POST $parentPath/todo'},
          resourceProjectId: 909,
        )..confirmed = true;
        session.permit = permit;
        await session.writer.post<Object?>('$parentPath/todo');
        final observer = Mr7Readback(
          session,
          session.identity!,
          permit,
          paths: {parentPath, 'projects/909/todos/mr7-observation'},
        );
        final observation = Mr7CreatedTodoObservation(
          id: 55,
          parent: issue
              ? const Mr7Parent.issue(id: 300, iid: 3)
              : const Mr7Parent.mergeRequest(id: 400, iid: 4),
        );
        if (variant == 'issue' || variant == 'mergeRequest') {
          expect(await observer.observe(observation), true, reason: variant);
        } else if (variant == 'wrongTarget' || variant == 'done') {
          expect(await observer.observe(observation), false, reason: variant);
        } else {
          await expectLater(
            observer.observe(observation),
            throwsA(anything),
            reason: variant,
          );
        }
        await session.finish();
      }
    },
  );
}
