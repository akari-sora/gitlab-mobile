import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';

const _account = 'https://example.com/gitlab#7';
const _scope = AiWriteScope(
  accountKey: _account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 9,
      projectPath: 'team/example-9',
    ),
  ],
);
const _cases = <String, Map<String, Object?>>{
  'deletePackage': {'projectId': 9, 'packageId': 4},
  'deletePackageFile': {'projectId': 9, 'packageId': 4, 'fileId': 8},
  'deleteContainerRepository': {'projectId': 9, 'repositoryId': 5},
  'deleteContainerTag': {'projectId': 9, 'repositoryId': 5, 'tag': 'v1'},
  'createProject': {
    'name': 'New project',
    'path': 'new-project',
    'description': 'new description',
  },
  'editProject': {
    'projectId': 9,
    'name': 'Edited project',
    'description': 'edited description',
  },
  'deleteProject': {'projectId': 9},
  'forkProject': {'projectId': 9},
};
const _confirm = {
  'deletePackage': 'library@1.0',
  'deletePackageFile': 'library.tar',
  'deleteContainerRepository': 'team/example-9/image',
  'deleteContainerTag': 'team/example-9/image:v1',
  'createProject': 'tester/new-project',
  'editProject': 'team/example-9',
  'deleteProject': 'team/example-9',
  'forkProject': 'tester/example-9',
};
// Independently counted: (freshness, prepare, readback), logical GETs.
const _counts = <String, (int, int, int)>{
  'deletePackage': (1, 3, 1),
  'deletePackageFile': (1, 6, 3),
  'deleteContainerRepository': (1, 4, 1),
  'deleteContainerTag': (1, 5, 1),
  'createProject': (0, 1, 1),
  'editProject': (1, 2, 1),
  'deleteProject': (1, 2, 1),
  'forkProject': (1, 2, 1),
};

AiWriteRequest _request(
  String op, {
  Map<String, Object?>? args,
  AiWriteScope scope = _scope,
}) => AiWriteRequest(
  operationId: op,
  executionId: 'p12-$op',
  scope: scope,
  arguments: args ?? _cases[op]!,
);

final class _Fixture {
  _Fixture(this.op, {bool oauth = false}) {
    adapter = FakeAdapter((request) {
      if (oauth && request.method == 'GET') {
        final count = getAttempts.update(
          '${request.uri}',
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        if (count.isOdd) return jsonResponse({}, status: 401);
      }
      return respond(request);
    });
    final dio = Dio()..httpClientAdapter = adapter;
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    final tokenDio = Dio()
      ..httpClientAdapter = FakeAdapter(
        (_) => jsonResponse({
          'access_token': 'synthetic-access',
          'refresh_token': 'synthetic-refresh',
          'token_type': 'bearer',
          'expires_in': 7200,
        }),
      );
    api = GitLabApi(
      instance: instance,
      dio: dio,
      token: oauth ? null : 'glpat-ABCDEFGHIJKLMNOPQRST',
      credential: oauth
          ? const OAuthCredential(
              accessToken: 'synthetic-access',
              refreshToken: 'synthetic-refresh',
              clientId: 'synthetic-client',
            )
          : null,
      oauth: oauth
          ? OAuthTokenClient(
              instance: instance,
              clientId: 'synthetic-client',
              dio: tokenDio,
            )
          : null,
      onOAuthRotated: oauth ? (_) async {} : null,
    );
    port = GitLabAiWritePort(api, accountKey: _account);
    addTearDown(() {
      api.close();
      tokenDio.close();
    });
  }
  final String op;
  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final GitLabAiWritePort port;
  final getAttempts = <String, int>{};
  Map<String, Object?> user = {'id': 7, 'username': 'tester'};
  Map<String, Object?> project = {
    ...projectJson(9),
    'path': 'example-9',
    'description': 'old description',
  };
  Map<String, Object?> package = {
    'id': 4,
    'name': 'library',
    'version': '1.0',
    '_links': {'delete_api_path': 'https://untrusted.invalid/ignored'},
  };
  Map<String, Object?> file = {
    'id': 8,
    'file_name': 'library.tar',
    'file_sha256': 'synthetic-digest',
  };
  Map<String, Object?> repository = {
    'id': 5,
    'project_id': 9,
    'path': 'team/example-9/image',
  };
  Map<String, Object?> tag = {
    'name': 'v1',
    'digest': 'digest-1',
    'revision': 'revision-1',
  };
  int access = 40;
  int pages = 1;
  int? writeStatus;
  int? readbackStatus;
  int? containerStatus;
  bool mutated = false;
  bool remains = false;
  bool movedReadback = false;
  bool duplicateFile = false;
  bool wrongReadbackId = false;
  bool wrongReadbackFields = false;

  ResponseBody respond(RequestOptions request) {
    final path = request.uri.path.substring('/gitlab/api/v4'.length);
    if (request.method != 'GET') {
      mutated = true;
      if (writeStatus != null) return jsonResponse({}, status: writeStatus!);
      if (op == 'createProject') return jsonResponse(created);
      if (op == 'forkProject') return jsonResponse(created);
      if (op == 'editProject') {
        project = {...project, ...request.data as Map<String, dynamic>};
        return jsonResponse(project);
      }
      return ResponseBody.fromString('', 204);
    }
    if (path == '/user') return jsonResponse(user);
    if (mutated && readbackStatus != null) {
      return jsonResponse({}, status: readbackStatus!);
    }
    if (path == '/projects/13') {
      return jsonResponse({
        ...created,
        if (movedReadback) 'path_with_namespace': 'other/moved',
        if (wrongReadbackId) 'id': 99,
      });
    }
    if (path == '/projects/9') {
      if (mutated && op == 'deleteProject' && !remains) {
        return jsonResponse({}, status: 404);
      }
      return jsonResponse({
        ...project,
        if (mutated && wrongReadbackFields) 'name': 'unexpected name',
      });
    }
    if (path == '/projects/9/members/all/7') {
      return jsonResponse({'access_level': access});
    }
    if (path == '/projects/9/packages/4') {
      if (mutated && op == 'deletePackage' && !remains) {
        return jsonResponse({}, status: 404);
      }
      return jsonResponse(package);
    }
    if (path == '/projects/9/packages/4/package_files') {
      final page =
          int.tryParse(request.uri.queryParameters['page'] ?? '1') ?? 1;
      return jsonResponse(
        [
          if (page == pages && (!mutated || remains)) file,
          if (page == pages && duplicateFile) file,
        ],
        headers: {
          if (page < pages) 'x-next-page': ['${page + 1}'],
        },
      );
    }
    if (path.startsWith('/projects/9/registry/repositories/5')) {
      if (containerStatus != null) {
        return jsonResponse({}, status: containerStatus!);
      }
      if (mutated && !remains) return jsonResponse({}, status: 404);
      return jsonResponse(path.contains('/tags/') ? tag : repository);
    }
    throw StateError('Unexpected synthetic request ${request.method} $path');
  }

  Map<String, Object?> get created => {
    ...projectJson(13),
    'path_with_namespace': _confirm[op],
    'name': op == 'createProject' ? 'New project' : 'Example 9',
    'description': op == 'createProject'
        ? 'new description'
        : 'old description',
  };

  Iterable<RequestOptions> get writes =>
      adapter.requests.where((request) => request.method != 'GET');
}

void main() {
  for (final op in _cases.keys) {
    test(
      '$op fixed method, read names, keys, independent readback and one shot',
      () async {
        final f = _Fixture(op);
        final row = productionAiLedger.find(op)!;
        expect(row.modelVisible, isFalse);
        expect(row.namedMethod, op);
        expect(row.readback, isTrue);
        expect(
          row.baseTier,
          op.startsWith('delete') && op != 'deleteProject'
              ? AiWriteTier.t4
              : AiWriteTier.hardLine,
        );
        expect(
          toolsForScope(_scope).map((row) => row.operationId),
          isNot(contains(op)),
        );
        final prepared = await f.port.prepare(_request(op));
        expect(prepared.confirmName, _confirm[op]);
        expect(
          prepared.releaseName,
          op == 'createProject' || op == 'forkProject'
              ? _confirm[op]
              : 'team/example-9',
        );
        final expectedKey = switch (op) {
          'deletePackage' => ['project:9', 'packages', '4'],
          'deletePackageFile' => ['project:9', 'packages', '4', 'files', '8'],
          'deleteContainerRepository' => ['project:9', 'registry', '5'],
          'deleteContainerTag' => ['project:9', 'registry', '5', 'v1'],
          'createProject' || 'forkProject' => ['namespace:7', 'projects'],
          'editProject' => ['project:9', 'settings'],
          _ => ['project:9'],
        };
        expect(prepared.writeKeys.single.parts, [_account, ...expectedKey]);
        if (op == 'forkProject') {
          expect(prepared.dependencyKeys.single.parts, [_account, 'project:9']);
        }
        expect(prepared.bindingDigest, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(f.writes, isEmpty);
        final outcome =
            await f.port.commit(prepared, mayStart: () => true)
                as AiWriteSettled;
        expect(outcome.state, AiJournalState.succeeded);
        expect(f.writes, hasLength(1));
        final write = f.writes.single;
        final expectedPath = switch (op) {
          'deletePackage' => ['projects', '9', 'packages', '4'],
          'deletePackageFile' => [
            'projects',
            '9',
            'packages',
            '4',
            'package_files',
            '8',
          ],
          'deleteContainerRepository' => [
            'projects',
            '9',
            'registry',
            'repositories',
            '5',
          ],
          'deleteContainerTag' => [
            'projects',
            '9',
            'registry',
            'repositories',
            '5',
            'tags',
            'v1',
          ],
          'createProject' => ['projects'],
          'forkProject' => ['projects', '9', 'fork'],
          _ => ['projects', '9'],
        };
        expect(write.uri.pathSegments, [
          'gitlab',
          'api',
          'v4',
          ...expectedPath,
        ]);
        expect(
          write.method,
          op == 'createProject' || op == 'forkProject'
              ? 'POST'
              : op == 'editProject'
              ? 'PUT'
              : 'DELETE',
        );
        expect(write.followRedirects, isFalse);
        expect(write.uri.queryParameters, isEmpty);
        if (op == 'createProject') {
          expect(write.data, {
            'name': 'New project',
            'path': 'new-project',
            'description': 'new description',
            'visibility': 'private',
            'initialize_with_readme': true,
          });
        }
        if (op == 'forkProject') expect(write.data, isEmpty);
        expect(
          await f.port.commit(prepared, mayStart: () => true),
          isA<AiWriteNotSent>(),
        );
        expect(f.writes, hasLength(1));
      },
    );

    test(
      '$op counted worst-case GET replay and bounded pages fit httpCap',
      () async {
        final f = _Fixture(op, oauth: true)..pages = 3;
        final (fresh, prepare, readback) = _counts[op]!;
        final cap = 2 * (2 * (fresh + prepare) + readback) + 1;
        expect(productionAiLedger.find(op)!.httpCap, cap);
        for (var pass = 0; pass < 2; pass++) {
          if (fresh > 0) await f.api.record(['projects', '9']);
          final prepared = await f.port.prepare(_request(op));
          if (pass == 1) {
            expect(
              (await f.port.commit(prepared, mayStart: () => true)
                      as AiWriteSettled)
                  .state,
              AiJournalState.succeeded,
            );
          }
        }
        expect(f.adapter.requests.length, cap);
        expect(
          f.adapter.requests.length,
          lessThanOrEqualTo(productionAiLedger.find(op)!.httpCap),
        );
        expect(f.writes, hasLength(1));
      },
    );

    for (final status in [403, 500]) {
      test('$op mutation $status classified without retry', () async {
        final f = _Fixture(op)..writeStatus = status;
        final p = await f.port.prepare(_request(op));
        final result =
            await f.port.commit(p, mayStart: () => true) as AiWriteSettled;
        expect(
          result.state,
          status == 403
              ? AiJournalState.failedCertain
              : AiJournalState.writeUncertain,
        );
        expect(f.writes, hasLength(1));
      });
    }
    test('$op unconfirmed readback retains uncertainty', () async {
      final f = _Fixture(op)
        ..remains = true
        ..movedReadback = true
        ..readbackStatus = 401;
      final p = await f.port.prepare(_request(op));
      expect(
        (await f.port.commit(p, mayStart: () => true) as AiWriteSettled).state,
        AiJournalState.writeUncertain,
      );
      expect(f.writes, hasLength(1));
    });
  }

  for (final op in _cases.keys) {
    for (final grant in [
      const AiScopeGrant(kind: AiScopeKind.workItem, projectId: 9, iid: 3),
      const AiScopeGrant(kind: AiScopeKind.accountGlobal),
      const AiScopeGrant(kind: AiScopeKind.project, projectId: 10),
    ]) {
      if (op == 'createProject' && grant.kind == AiScopeKind.project) continue;
      test(
        '$op rejects insufficient scope ${grant.kind} ${grant.projectId}',
        () async {
          final f = _Fixture(op);
          await expectLater(
            f.port.prepare(
              _request(
                op,
                scope: AiWriteScope(accountKey: _account, grants: [grant]),
              ),
            ),
            throwsA(
              isA<ApiFailure>().having(
                (e) => e.kind,
                'kind',
                FailureKind.forbidden,
              ),
            ),
          );
          expect(f.adapter.requests, isEmpty);
        },
      );
    }
  }

  for (final op in [
    'deletePackage',
    'deletePackageFile',
    'deleteContainerRepository',
    'deleteContainerTag',
  ]) {
    test('$op refuses archived projects', () async {
      final f = _Fixture(op)..project['archived'] = true;
      await expectLater(
        f.port.prepare(_request(op)),
        throwsA(
          isA<AiJournalException>().having(
            (e) => e.reason,
            'reason',
            'projectArchived',
          ),
        ),
      );
      expect(f.writes, isEmpty);
    });
  }
  for (final op in ['deletePackage', 'deletePackageFile']) {
    test('$op requires package canDelete and exact ownership', () async {
      final f = _Fixture(op)..package['_links'] = {};
      await expectLater(
        f.port.prepare(_request(op)),
        throwsA(
          isA<AiJournalException>().having(
            (e) => e.reason,
            'reason',
            'packageNotDeletable',
          ),
        ),
      );
      f.package['_links'] = {'delete_api_path': '/ignored'};
      f.package['project_id'] = 10;
      await expectLater(
        f.port.prepare(_request(op)),
        throwsA(isA<ApiFailure>()),
      );
      expect(f.writes, isEmpty);
    });
  }
  for (final op in ['deleteContainerRepository', 'deleteContainerTag']) {
    test(
      '$op requires fresh Maintainer access and matching repository',
      () async {
        final f = _Fixture(op)..access = 30;
        await expectLater(
          f.port.prepare(_request(op)),
          throwsA(
            isA<AiJournalException>().having(
              (e) => e.reason,
              'reason',
              'maintainerRequired',
            ),
          ),
        );
        f.access = 40;
        f.repository['project_id'] = 10;
        await expectLater(
          f.port.prepare(_request(op)),
          throwsA(
            isA<AiJournalException>().having(
              (e) => e.reason,
              'reason',
              'containerMissing',
            ),
          ),
        );
        f.repository['project_id'] = 9;
        f.containerStatus = 404;
        await expectLater(
          f.port.prepare(_request(op)),
          throwsA(
            isA<AiJournalException>().having(
              (e) => e.reason,
              'reason',
              'containerMissing',
            ),
          ),
        );
        expect(f.writes, isEmpty);
      },
    );
  }
  test(
    'package versionless identity and bounded complete file lookup',
    () async {
      final f = _Fixture('deletePackage')..package['version'] = '';
      expect(
        (await f.port.prepare(_request('deletePackage'))).confirmName,
        'library@versionless',
      );
      final files = _Fixture('deletePackageFile')..pages = 4;
      await expectLater(
        files.port.prepare(_request('deletePackageFile')),
        throwsA(
          isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.tooLarge),
        ),
      );
      expect(
        files.adapter.requests.where(
          (r) => r.uri.path.endsWith('/package_files'),
        ),
        hasLength(3),
      );
      expect(files.writes, isEmpty);
    },
  );
  test(
    'file ownership, duplicate IDs and missing file cannot become a proposal',
    () async {
      final f = _Fixture('deletePackageFile')..file['package_id'] = 6;
      await expectLater(
        f.port.prepare(_request('deletePackageFile')),
        throwsA(isA<ApiFailure>()),
      );
      f.file.remove('package_id');
      f.duplicateFile = true;
      await expectLater(
        f.port.prepare(_request('deletePackageFile')),
        throwsA(isA<ApiFailure>()),
      );
      f.duplicateFile = false;
      f.file['id'] = 10;
      await expectLater(
        f.port.prepare(_request('deletePackageFile')),
        throwsA(isA<ApiFailure>()),
      );
      expect(f.writes, isEmpty);
    },
  );
  for (final op in _cases.keys) {
    test('$op denies send at mayStart without a mutation', () async {
      final f = _Fixture(op);
      final p = await f.port.prepare(_request(op));
      expect(
        await f.port.commit(p, mayStart: () => false),
        isA<AiWriteNotSent>(),
      );
      expect(f.writes, isEmpty);
    });
    test('$op successful HTTP with mismatched state stays uncertain', () async {
      final f = _Fixture(op)
        ..remains = true
        ..movedReadback = true
        ..wrongReadbackFields = true;
      final p = await f.port.prepare(_request(op));
      expect(
        (await f.port.commit(p, mayStart: () => true) as AiWriteSettled).state,
        AiJournalState.writeUncertain,
      );
      expect(f.writes, hasLength(1));
    });
  }
  for (final op in ['createProject', 'forkProject']) {
    test('$op validates readback numeric identity', () async {
      final f = _Fixture(op)..wrongReadbackId = true;
      final p = await f.port.prepare(_request(op));
      expect(
        (await f.port.commit(p, mayStart: () => true) as AiWriteSettled).state,
        AiJournalState.writeUncertain,
      );
    });
  }
  test(
    'container tag is verified and encoded as exactly one path segment',
    () async {
      final f = _Fixture('deleteContainerTag')..tag['name'] = 'other';
      await expectLater(
        f.port.prepare(_request('deleteContainerTag')),
        throwsA(isA<AiJournalException>()),
      );
      const tag = 'release/v1?#';
      f.tag['name'] = tag;
      final p = await f.port.prepare(
        _request(
          'deleteContainerTag',
          args: {..._cases['deleteContainerTag']!, 'tag': tag},
        ),
      );
      expect(p.confirmName, 'team/example-9/image:$tag');
      await f.port.commit(p, mayStart: () => true);
      expect(f.writes.single.uri.pathSegments.last, tag);
      expect(f.writes.single.uri.query, isEmpty);
    },
  );
  for (final op in _cases.keys) {
    test('$op rejects unknown fields and wrong current account', () async {
      final f = _Fixture(op);
      await expectLater(
        f.port.prepare(
          _request(
            op,
            args: {..._cases[op]!, 'url': 'https://untrusted.invalid'},
          ),
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(f.adapter.requests, isEmpty);
      f.user['id'] = 8;
      await expectLater(
        f.port.prepare(_request(op)),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.kind,
            'kind',
            FailureKind.unauthenticated,
          ),
        ),
      );
      expect(f.writes, isEmpty);
    });
  }
  for (final op in ['createProject', 'forkProject']) {
    test('$op refuses unknown personal namespace', () async {
      final f = _Fixture(op)..user['username'] = '../group';
      await expectLater(
        f.port.prepare(_request(op)),
        throwsA(
          isA<AiJournalException>().having(
            (e) => e.reason,
            'reason',
            'personalNamespaceUnknown',
          ),
        ),
      );
      expect(f.writes, isEmpty);
    });
  }
  test('create and edit project closed fields and path requirements', () async {
    for (final extra in [
      {'visibility': 'public'},
      {'initialize_with_readme': false},
      {'namespace_id': 2},
      {'namespacePath': 'other'},
      {
        'fields': {'name': 'x'},
      },
    ]) {
      final f = _Fixture('createProject');
      await expectLater(
        f.port.prepare(
          _request(
            'createProject',
            args: {..._cases['createProject']!, ...extra},
          ),
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(f.adapter.requests, isEmpty);
    }
    for (final path in ['../other', 'team/name', '', 'https://example.com']) {
      final f = _Fixture('createProject');
      await expectLater(
        f.port.prepare(
          _request(
            'createProject',
            args: {..._cases['createProject']!, 'path': path},
          ),
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(f.writes, isEmpty);
    }
    final f = _Fixture('editProject');
    await expectLater(
      f.port.prepare(_request('editProject', args: {'projectId': 9})),
      throwsA(isA<ApiFailure>()),
    );
    await expectLater(
      f.port.prepare(
        _request('editProject', args: {'projectId': 9, 'path': 'rename'}),
      ),
      throwsA(isA<ApiFailure>()),
    );
    final p = await f.port.prepare(
      _request('editProject', args: {'projectId': 9, 'name': 'Just the name'}),
    );
    f.project['description'] = 'changed concurrently';
    final newer = await f.port.prepare(
      _request('editProject', args: {'projectId': 9, 'name': 'Just the name'}),
    );
    expect(newer.bindingDigest, isNot(p.bindingDigest));
    await f.port.commit(p, mayStart: () => true);
    expect(f.writes.single.data, {
      'name': 'Just the name',
      'description': 'old description',
    });
  });
  test(
    'all read identity changes bind approvals including a moved container tag',
    () async {
      final f = _Fixture('deleteContainerTag');
      final first = await f.port.prepare(_request('deleteContainerTag'));
      f.tag['digest'] = 'digest-2';
      final second = await f.port.prepare(_request('deleteContainerTag'));
      expect(second.bindingDigest, isNot(first.bindingDigest));
      f.repository['path'] = 'team/example-9/renamed';
      final third = await f.port.prepare(_request('deleteContainerTag'));
      expect(third.confirmName, isNot(second.confirmName));
      expect(third.releaseName, second.releaseName);
    },
  );
}
