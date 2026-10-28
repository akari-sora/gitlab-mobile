import 'release_policy_support.dart';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart'
    show UploadPlaceholderTable;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';

const _account = 'https://example.com/gitlab#7';
const _timeout = Duration(seconds: 20);

void main() {
  late _Harness h;

  setUp(() async => h = await _Harness.create());
  tearDown(() async => h.dispose());

  test('packet 12 rows are model-visible, bounded, and read back', () {
    final rows = _projectRows;
    expect(rows, hasLength(8));
    for (final row in rows) {
      expect(row.modelVisible, isTrue, reason: row.operationId);
      expect(row.httpCap, inInclusiveRange(1, 40), reason: row.operationId);
      expect(row.readback, isTrue, reason: row.operationId);
    }
  });

  test('registry proposals use server names and exact conflict keys', () async {
    final cases =
        <
          ({
            String operation,
            Map<String, Object?> args,
            String name,
            List<String> key,
          })
        >[
          (
            operation: 'deletePackage',
            args: {'projectId': 9, 'packageId': 71},
            name: 'sdk@1.2.3',
            key: [_account, 'project:9', 'packages', '71'],
          ),
          (
            operation: 'deletePackageFile',
            args: {'projectId': 9, 'packageId': 71, 'fileId': 72},
            name: 'sdk.zip',
            key: [_account, 'project:9', 'packages', '71', 'files', '72'],
          ),
          (
            operation: 'deleteContainerRepository',
            args: {'projectId': 9, 'repositoryId': 81},
            name: 'team/example-9/app',
            key: [_account, 'project:9', 'registry', '81'],
          ),
          (
            operation: 'deleteContainerTag',
            args: {'projectId': 9, 'repositoryId': 81, 'tag': 'v1'},
            name: 'team/example-9/app:v1',
            key: [_account, 'project:9', 'registry', '81', 'v1'],
          ),
        ];
    for (final value in cases) {
      h.newCoordinator();
      final proposal = await h.propose(value.operation, value.args);
      expect(proposal, isNotNull, reason: value.operation);
      expect(proposal!.tier.typedName, value.name);
      expect(proposal.tier.requiresTypedName, isTrue);
      final outcome = await h.coordinator
          .approve(proposal, typedName: value.name)
          .timeout(_timeout);
      expect(outcome.state, AiJournalState.succeeded, reason: value.operation);
      final entry = h.journal.entries(_account).last;
      expect(entry.writeKeys, {AiConflictKey(value.key)});
      expect(entry.releaseName, 'team/example-9');
      h.server.restoreDeletes();
    }
  });

  for (final value in [
    (
      operation: 'deletePackage',
      args: <String, Object?>{'projectId': 9, 'packageId': 71},
    ),
    (
      operation: 'deletePackageFile',
      args: <String, Object?>{
        'projectId': 9,
        'packageId': 71,
        'fileId': 72,
      },
    ),
    (
      operation: 'deleteContainerRepository',
      args: <String, Object?>{'projectId': 9, 'repositoryId': 81},
    ),
    (
      operation: 'deleteContainerTag',
      args: <String, Object?>{
        'projectId': 9,
        'repositoryId': 81,
        'tag': 'v1',
      },
    ),
  ]) {
    test('fix1 ${value.operation} stays unbound at bypass', () async {
      h.newCoordinator(level: AiAutonomyLevel.bypass);
      final proposal = await h.propose(value.operation, value.args);
      expect(proposal, isNotNull);
      expect(proposal!.tier.decision, AiGateDecision.requireApproval);
      expect(
        proposal.tier.reasons,
        contains(AiFixedConfirmReason.targetUnbound),
      );
      expect(h.server.mutations, isEmpty);
    });
  }

  test(
    'all project hard lines require their fresh typed name at bypass',
    () async {
      final cases =
          <({String operation, Map<String, Object?> args, String name})>[
            (
              operation: 'createProject',
              args: {'name': 'Sample', 'path': 'sample', 'description': 'Desc'},
              name: 'tester/sample',
            ),
            (
              operation: 'editProject',
              args: {'projectId': 9, 'description': 'Changed'},
              name: 'team/example-9',
            ),
            (
              operation: 'deleteProject',
              args: {'projectId': 9},
              name: 'team/example-9',
            ),
            (
              operation: 'forkProject',
              args: {'projectId': 9},
              name: 'tester/example-9',
            ),
          ];
      for (final value in cases) {
        h.newCoordinator(level: AiAutonomyLevel.bypass);
        final proposal = await h.propose(value.operation, value.args);
        expect(proposal, isNotNull, reason: value.operation);
        expect(proposal!.tier.tier, AiWriteTier.hardLine);
        expect(proposal.tier.requiresTypedName, isTrue);
        expect(proposal.tier.typedName, value.name);
        expect(proposal.releaseName, value.name);
        final before = h.server.mutations.length;
        final refused = await h.coordinator.approve(
          proposal,
          typedName: '${value.name}-stale',
        );
        expect(refused.reasonCode, 'typedNameMismatch');
        expect(h.server.mutations, hasLength(before));
        await h.coordinator.reject(proposal);
      }
    },
  );

  test('create and fork keep the fixed wrapper request shapes', () async {
    h.newCoordinator(level: AiAutonomyLevel.bypass);
    final create = (await h.propose('createProject', {
      'name': 'Sample',
      'path': 'sample',
      'description': 'Desc',
    }))!;
    expect(
      (await h.coordinator.approve(create, typedName: 'tester/sample')).state,
      AiJournalState.succeeded,
    );
    final createEntry = h.journal
        .entries(_account)
        .singleWhere((entry) => entry.operationId == 'createProject');
    expect(createEntry.writeKeys, {
      const AiConflictKey([_account, 'namespace:7', 'projects']),
    });
    expect(createEntry.releaseName, 'tester/sample');
    final createRequest = h.server.mutations.singleWhere(
      (request) =>
          request.method == 'POST' && request.uri.path.endsWith('/projects'),
    );
    expect(createRequest.data, {
      'name': 'Sample',
      'path': 'sample',
      'description': 'Desc',
      'visibility': 'private',
      'initialize_with_readme': true,
    });

    h.newCoordinator(level: AiAutonomyLevel.bypass);
    final fork = (await h.propose('forkProject', {'projectId': 9}))!;
    expect(
      (await h.coordinator.approve(fork, typedName: 'tester/example-9')).state,
      AiJournalState.succeeded,
    );
    final forkEntry = h.journal
        .entries(_account)
        .singleWhere((entry) => entry.operationId == 'forkProject');
    expect(forkEntry.writeKeys, {
      const AiConflictKey([_account, 'namespace:7', 'projects']),
    });
    expect(forkEntry.dependencyKeys, {
      const AiConflictKey([_account, 'project:9']),
    });
    expect(forkEntry.releaseName, 'tester/example-9');
    final forkRequest = h.server.mutations.singleWhere(
      (request) => request.uri.path.endsWith('/projects/9/fork'),
    );
    expect(forkRequest.data, <String, Object?>{});
  });

  test('closed schemas reject extra create fields and empty edits', () async {
    h.newCoordinator();
    final createSchema = h.coordinator.specs
        .singleWhere((spec) => spec.name == 'createProject')
        .parameters;
    expect((createSchema['properties'] as Map).keys, {
      'name',
      'path',
      'description',
      'reason',
    });
    expect(
      await h.propose('createProject', {
        'name': 'Sample',
        'path': 'sample',
        'visibility': 'public',
      }),
      isNull,
    );
    expect(h.coordinator.outcomeFor('call')?.reasonCode, 'invalidArguments');
    expect(h.adapter.requests, isEmpty);

    h.newCoordinator();
    expect(await h.propose('editProject', {'projectId': 9}), isNull);
    expect(h.coordinator.outcomeFor('call')?.reasonCode, 'validation');
    expect(h.server.mutations, isEmpty);
  });

  test('scope rejection happens before the port or adapter is used', () async {
    h.newCoordinator(scope: _scope9);
    expect(await h.propose('deleteProject', {'projectId': 10}), isNull);
    expect(h.coordinator.outcomeFor('call')?.reasonCode, 'policyDenied');
    expect(h.adapter.requests, isEmpty);
  });

  test('fresh server names invalidate an earlier approval', () async {
    h.newCoordinator(level: AiAutonomyLevel.bypass);
    final proposal = (await h.propose('editProject', {
      'projectId': 9,
      'description': 'Changed',
    }))!;
    expect(proposal.tier.typedName, 'team/example-9');
    h.server.projectPaths[9] = 'team/renamed';
    final outcome = await h.coordinator.approve(
      proposal,
      typedName: 'team/example-9',
    );
    expect(outcome.reasonCode, 'targetChanged');
    expect(h.server.mutations, isEmpty);
  });

  test('uncertain project deletion locks all project children only', () async {
    h.server.failDeleteProject = true;
    h.newCoordinator(level: AiAutonomyLevel.bypass);
    final deletion = (await h.propose('deleteProject', {'projectId': 9}))!;
    final unknown = await h.coordinator.approve(
      deletion,
      typedName: 'team/example-9',
    );
    expect(unknown.state, AiJournalState.writeUncertain);

    h.newCoordinator();
    expect(
      await h.propose('setStar', {'projectId': 9, 'starred': true}),
      isNull,
    );
    expect(h.coordinator.outcomeFor('call')?.reasonCode, 'isolated');

    h.newCoordinator();
    expect(await h.propose('forkProject', {'projectId': 9}), isNull);
    expect(h.coordinator.outcomeFor('call')?.reasonCode, 'isolated');

    h.newCoordinator();
    final other = await h.propose('setStar', {
      'projectId': 10,
      'starred': true,
    });
    expect(other, isNotNull);
    await h.coordinator.reject(other!);
  });

  test('uncertain settings edit does not lock child resources', () async {
    h.server.failEditProject = true;
    h.newCoordinator(level: AiAutonomyLevel.bypass);
    final edit = (await h.propose('editProject', {
      'projectId': 9,
      'description': 'Changed',
    }))!;
    final unknown = await h.coordinator.approve(
      edit,
      typedName: 'team/example-9',
    );
    expect(unknown.state, AiJournalState.writeUncertain);

    h.newCoordinator();
    final child = await h.propose('setStar', {'projectId': 9, 'starred': true});
    expect(child, isNotNull);
    await h.coordinator.reject(child!);
  });

  test('typed preparation failures surface packet reason codes', () async {
    h.server.packageDeletable = false;
    h.newCoordinator();
    expect(
      await h.propose('deletePackage', {'projectId': 9, 'packageId': 71}),
      isNull,
    );
    expect(h.coordinator.outcomeFor('call')?.reasonCode, 'packageNotDeletable');

    h.server.packageDeletable = true;
    h.server.accessLevel = 30;
    h.newCoordinator();
    expect(
      await h.propose('deleteContainerRepository', {
        'projectId': 9,
        'repositoryId': 81,
      }),
      isNull,
    );
    expect(h.coordinator.outcomeFor('call')?.reasonCode, 'maintainerRequired');

    h.server.accessLevel = 40;
    h.server.containerPresent = false;
    h.newCoordinator();
    expect(
      await h.propose('deleteContainerRepository', {
        'projectId': 9,
        'repositoryId': 81,
      }),
      isNull,
    );
    expect(h.coordinator.outcomeFor('call')?.reasonCode, 'containerMissing');

    h.server.containerPresent = true;
    h.server.archivedProjects.add(9);
    h.newCoordinator();
    expect(
      await h.propose('deletePackage', {'projectId': 9, 'packageId': 71}),
      isNull,
    );
    expect(h.coordinator.outcomeFor('call')?.reasonCode, 'projectArchived');

    h.server.archivedProjects.clear();
    h.server.username = 'not/a/segment';
    h.newCoordinator();
    expect(
      await h.propose('createProject', {'name': 'Sample', 'path': 'sample'}),
      isNull,
    );
    expect(
      h.coordinator.outcomeFor('call')?.reasonCode,
      'personalNamespaceUnknown',
    );
  });

  test(
    'versionless packages use the server-derived fallback identity',
    () async {
      h.server.packageVersion = '';
      h.newCoordinator();
      final proposal = await h.propose('deletePackage', {
        'projectId': 9,
        'packageId': 71,
      });
      expect(proposal, isNotNull);
      expect(proposal!.tier.typedName, 'sdk@versionless');
      await h.coordinator.reject(proposal);
    },
  );
}

const _scope9 = AiWriteScope(
  accountKey: _account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 9,
      projectPath: 'team/example-9',
    ),
  ],
);

const _scope9And10 = AiWriteScope(
  accountKey: _account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 9,
      projectPath: 'team/example-9',
    ),
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 10,
      projectPath: 'team/example-10',
    ),
  ],
);

List<AiCapability> get _projectRows => [
  for (final operation in const [
    'deletePackage',
    'deletePackageFile',
    'deleteContainerRepository',
    'deleteContainerTag',
    'createProject',
    'editProject',
    'deleteProject',
    'forkProject',
  ])
    productionAiLedger.find(operation)!,
];

AiCapability _visible(AiCapability row) => AiCapability(
  operationId: row.operationId,
  baseTier: row.baseTier,
  scopeClass: row.scopeClass,
  modelVisible: true,
  namedMethod: row.namedMethod,
  arguments: row.arguments,
  httpCap: row.httpCap,
  readback: row.readback,
  editableField: row.editableField,
);

final class _VisibleLedger implements AiCapabilityLedger {
  _VisibleLedger()
    : rows = [
        for (final row in _projectRows) _visible(row),
        productionAiLedger.find('setStar')!,
      ];

  final List<AiCapability> rows;

  @override
  AiCapability? find(String operationId) {
    for (final row in rows) {
      if (row.operationId == operationId) return row;
    }
    return null;
  }

  @override
  List<AiCapability> get modelVisible => rows;
}

final class _Harness {
  _Harness._(this.root, this.server, this.adapter, this.api, this.journal);

  static Future<_Harness> create() async {
    final root = Directory.systemTemp.createTempSync('p12-coordinator-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'p12-coordinator-test',
    );
    await journal.recoverAfterAccountsLoaded([_account]);
    await journal.ensureInitialized(_account);
    final server = _Server();
    final adapter = FakeAdapter(server.respond);
    final api = testApi(adapter);
    return _Harness._(root, server, adapter, api, journal);
  }

  final Directory root;
  final _Server server;
  final FakeAdapter adapter;
  final GitLabApi api;
  final AiWriteJournal journal;
  PolicyAiWriteCoordinator? _coordinator;

  PolicyAiWriteCoordinator get coordinator => _coordinator!;

  void newCoordinator({
    AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
    AiWriteScope scope = _scope9And10,
  }) {
    _coordinator?.stop('superseded');
    adapter.requests.clear();
    final budget = AiToolBudget(maxGitLabRequests: 40);
    _coordinator = PolicyAiWriteCoordinator(
      releasePolicy: fixtureReleasePolicy,
      snapshot: () => AiWritePolicySnapshot(
        scope: scope,
        level: level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'p12-consent',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
        appInForeground: true,
      ),
      createPort: () => GitLabAiWritePort(api, accountKey: _account),
      journal: journal,
      conversationId: 'p12-conversation',
      budget: () => budget,
      readFreshness: (_) async => const AiWriteFreshness(
        updatedAt: '2026-10-23T00:00:00Z',
        visibilityUnreadable: false,
      ),
      placeholders: UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: _VisibleLedger(),
      now: () => DateTime.utc(2026, 10, 23, 12),
    );
    coordinator.beginRun(
      'Apply the requested change in team/example-9 and team/example-10',
    );
    coordinator.beginTurn();
  }

  Future<AiWriteProposal?> propose(
    String operation,
    Map<String, Object?> arguments,
  ) => coordinator
      .propose(
        AiToolCall(
          id: 'call',
          name: operation,
          arguments: {...arguments, 'reason': 'Synthetic packet 12 request'},
        ),
      )
      .timeout(_timeout);

  Future<void> dispose() async {
    _coordinator?.stop('disposed');
    api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

final class _Server {
  final projectPaths = <int, String>{
    9: 'team/example-9',
    10: 'team/example-10',
  };
  final projectNames = <int, String>{9: 'Example 9', 10: 'Example 10'};
  final projectDescriptions = <int, String>{9: 'Original', 10: 'Other'};
  final archivedProjects = <int>{};
  final mutations = <RequestOptions>[];
  String username = 'tester';
  String? packageVersion = '1.2.3';
  bool packageDeletable = true;
  int accessLevel = 40;
  bool containerPresent = true;
  bool failDeleteProject = false;
  bool failEditProject = false;
  bool packageDeleted = false;
  bool packageFileDeleted = false;
  bool repositoryDeleted = false;
  bool tagDeleted = false;
  bool projectDeleted = false;

  void restoreDeletes() {
    packageDeleted = false;
    packageFileDeleted = false;
    repositoryDeleted = false;
    tagDeleted = false;
    projectDeleted = false;
  }

  FutureOr<ResponseBody> respond(RequestOptions request) {
    final segments = request.uri.pathSegments;
    final api = segments.indexOf('v4');
    final path = segments.skip(api + 1).join('/');
    if (request.method != 'GET' && request.method != 'HEAD') {
      mutations.add(request);
    }
    if (path == 'user' && request.method == 'GET') {
      return jsonResponse({'id': 7, 'username': username});
    }
    if (path == 'projects' && request.method == 'POST') {
      final data = request.data! as Map<String, Object?>;
      projectPaths[101] = 'tester/${data['path']}';
      projectNames[101] = data['name']! as String;
      projectDescriptions[101] = data['description']! as String;
      return jsonResponse(_project(101), status: 201);
    }
    if (path == 'projects/9/fork' && request.method == 'POST') {
      projectPaths[102] = 'tester/example-9';
      projectNames[102] = 'Example 9';
      projectDescriptions[102] = 'Original';
      return jsonResponse(_project(102), status: 201);
    }
    if (path == 'projects/9' && request.method == 'PUT') {
      if (failEditProject) throw _connectionFailure(request);
      final data = request.data! as Map<String, Object?>;
      projectNames[9] = data['name']! as String;
      projectDescriptions[9] = data['description']! as String;
      return jsonResponse(_project(9));
    }
    if (path == 'projects/9' && request.method == 'DELETE') {
      if (failDeleteProject) throw _connectionFailure(request);
      projectDeleted = true;
      return ResponseBody.fromString('', 204);
    }
    if (path == 'projects/9/packages/71' && request.method == 'DELETE') {
      packageDeleted = true;
      return ResponseBody.fromString('', 204);
    }
    if (path == 'projects/9/packages/71/package_files/72' &&
        request.method == 'DELETE') {
      packageFileDeleted = true;
      return ResponseBody.fromString('', 204);
    }
    if (path == 'projects/9/registry/repositories/81' &&
        request.method == 'DELETE') {
      repositoryDeleted = true;
      return ResponseBody.fromString('', 204);
    }
    if (path == 'projects/9/registry/repositories/81/tags/v1' &&
        request.method == 'DELETE') {
      tagDeleted = true;
      return ResponseBody.fromString('', 204);
    }
    if (request.method == 'POST' &&
        (path == 'projects/9/star' || path == 'projects/10/star')) {
      return jsonResponse({'id': int.parse(path.split('/')[1])});
    }
    if (path == 'projects/9/packages/71' && request.method == 'GET') {
      if (packageDeleted) return jsonResponse({'message': '404'}, status: 404);
      return jsonResponse({
        'id': 71,
        'project_id': 9,
        'name': 'sdk',
        'version': packageVersion,
        '_links': {if (packageDeletable) 'delete_api_path': '/ignored/by/port'},
      });
    }
    if (path == 'projects/9/packages/71/package_files' &&
        request.method == 'GET') {
      return jsonResponse(
        packageFileDeleted
            ? []
            : [
                {
                  'id': 72,
                  'package_id': 71,
                  'project_id': 9,
                  'file_name': 'sdk.zip',
                  'file_sha256': 'synthetic-sha',
                },
              ],
      );
    }
    if (path == 'projects/9/members/all/7' && request.method == 'GET') {
      return jsonResponse({'id': 7, 'access_level': accessLevel});
    }
    if (path == 'registry/repositories/81' &&
        request.method == 'GET') {
      if (repositoryDeleted || !containerPresent) {
        return jsonResponse({'message': '404'}, status: 404);
      }
      return jsonResponse({
        'id': 81,
        'project_id': 9,
        'path': 'team/example-9/app',
      });
    }
    if (path == 'projects/9/registry/repositories/81' &&
        request.method == 'GET') {
      return jsonResponse({'message': '404'}, status: 404);
    }
    if (path == 'projects/9/registry/repositories/81/tags/v1' &&
        request.method == 'GET') {
      if (tagDeleted) return jsonResponse({'message': '404'}, status: 404);
      return jsonResponse({
        'name': 'v1',
        'digest': 'sha256:synthetic',
        'revision': 'synthetic-revision',
      });
    }
    final match = RegExp(r'^projects/(\d+)$').firstMatch(path);
    if (match != null && request.method == 'GET') {
      final id = int.parse(match.group(1)!);
      if (id == 9 && projectDeleted) {
        return jsonResponse({'message': '404'}, status: 404);
      }
      if (!projectPaths.containsKey(id)) {
        return jsonResponse({'message': '404'}, status: 404);
      }
      return jsonResponse(_project(id));
    }
    throw StateError('Unexpected request: ${request.method} ${request.uri}');
  }

  Map<String, Object?> _project(int id) => {
    ...projectJson(id),
    'name': projectNames[id],
    'path': projectPaths[id]!.split('/').last,
    'path_with_namespace': projectPaths[id],
    'description': projectDescriptions[id],
    'visibility': 'private',
    'archived': archivedProjects.contains(id),
  };

  DioException _connectionFailure(RequestOptions request) => DioException(
    requestOptions: request,
    type: DioExceptionType.connectionError,
    error: const SocketException('synthetic disconnect'),
  );
}
