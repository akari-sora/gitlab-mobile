import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/exact_edit.dart' as exact;
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'p6_support.dart' show p6Args;

const mr6b2Account = 'https://example.com/gitlab#7';
const mr6b2Timeout = Duration(seconds: 20);
const mr6b2Scope = AiWriteScope(
  accountKey: mr6b2Account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 9,
      projectPath: 'team/example-9',
    ),
  ],
);

final mr6b2Head = 'a' * 40;
final mr6b2Base = 'b' * 40;

/// The production catalogue with every delivered MR6b-2 row visible except
/// snippets, whose packet is deliberately outside packet 18's matrices.
final class VisibleProductionLedger implements AiCapabilityLedger {
  const VisibleProductionLedger();

  @override
  AiCapability? find(String operationId) {
    final row = productionAiLedger.find(operationId);
    if (row == null || aiSnippetRows.contains(row)) return null;
    return AiCapability(
      operationId: row.operationId,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      modelVisible: true,
      namedMethod: row.namedMethod,
      arguments: row.arguments,
      httpCap: row.httpCap,
      readback: row.readback,
      editableField: row.editableField,
      boundary: row.boundary,
    );
  }

  @override
  List<AiCapability> get modelVisible => [
    for (final row in ProductionAiLedger.rows)
      if (!aiSnippetRows.contains(row)) find(row.operationId)!,
  ];
}

final class Mr6b2Policy {
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;
  AiAutonomyLevel ceiling = AiAutonomyLevel.bypass;
  String consentHash = 'synthetic-consent';
  int writePolicyRevision = 2;
  int scopeRevision = 1;
  int sessionGeneration = 7;
  bool toolsEnabled = true;
  bool consentValid = true;
  bool alive = true;
  bool appInForeground = true;
  bool clientMayStart = true;
  int? currentJobId;
}

/// Journal disk seam used by row 29 tests. [armBarrier] blocks exactly the
/// next durable write and exposes a bounded entry signal.
final class Mr6b2JournalFiles extends AiJournalFiles {
  Mr6b2JournalFiles(super.root);

  Completer<void>? _entered;
  Completer<void>? _release;
  int? _barrierWrite;
  bool _barrierAfterPersist = false;
  int writeCount = 0;
  bool failNextWrite = false;
  int? failWriteNumber;
  int? failAfterWriteNumber;

  Future<void> armBarrier({
    int writesBeforeBarrier = 0,
    bool afterPersist = false,
  }) {
    _entered = Completer<void>();
    _release = Completer<void>();
    _barrierWrite = writeCount + writesBeforeBarrier + 1;
    _barrierAfterPersist = afterPersist;
    return _entered!.future.timeout(mr6b2Timeout);
  }

  void releaseBarrier() {
    final release = _release;
    if (release != null && !release.isCompleted) release.complete();
  }

  @override
  Future<void> write(
    String account,
    Uint8List bytes, {
    required bool Function() mayCommit,
  }) async {
    writeCount++;
    final entered = _entered;
    final release = _release;
    final blocksThisWrite =
        entered != null && !entered.isCompleted && writeCount == _barrierWrite;
    if (blocksThisWrite && !_barrierAfterPersist) {
      entered.complete();
      await release!.future.timeout(mr6b2Timeout);
      _entered = null;
      _release = null;
      _barrierWrite = null;
    }
    if (failNextWrite ||
        failWriteNumber == writeCount ||
        (failAfterWriteNumber != null && writeCount > failAfterWriteNumber!)) {
      failNextWrite = false;
      failWriteNumber = null;
      throw const FileSystemException('syntheticJournalWriteFailure');
    }
    await super.write(account, bytes, mayCommit: mayCommit);
    if (blocksThisWrite && _barrierAfterPersist) {
      entered.complete();
      await release!.future.timeout(mr6b2Timeout);
      _entered = null;
      _release = null;
      _barrierWrite = null;
      _barrierAfterPersist = false;
    }
  }
}

/// One deterministic GitLab instance serving the file, merge, CI and delete
/// families used by packet 18. Tests may override an exact `METHOD path`.
final class Mr6b2Server {
  Mr6b2Server() {
    adapter = FakeAdapter(_respond);
    api = testApi(adapter);
    writePort = port.GitLabAiWritePort(api, accountKey: mr6b2Account);
  }

  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final port.GitLabAiWritePort writePort;
  final overrides = <String, FutureOr<ResponseBody> Function(RequestOptions)>{};
  final contents = <String, String>{mr6b2Head: 'alpha\n'};
  final appliedSuggestions = <int>{};
  String lastCommit = mr6b2Head;
  String branch = 'work';
  String targetBranch = 'main';
  bool branchProtected = false;
  bool mergeSent = false;
  bool pipelineDeleted = false;
  bool starred = false;
  int? mutationStatus;
  Completer<void>? mutationEntered;
  Completer<void>? releaseMutation;

  Iterable<RequestOptions> get mutations => adapter.requests.where(
    (request) => !const {'GET', 'HEAD'}.contains(request.method),
  );

  int mutationCount({String? pathContains}) => mutations.where((request) {
    return pathContains == null || request.uri.path.contains(pathContains);
  }).length;

  void armMutationBarrier() {
    mutationEntered = Completer<void>();
    releaseMutation = Completer<void>();
  }

  void releaseMutationBarrier() {
    final release = releaseMutation;
    if (release != null && !release.isCompleted) release.complete();
  }

  FutureOr<ResponseBody> _respond(RequestOptions request) async {
    final segments = request.uri.pathSegments;
    final v4 = segments.indexOf('v4');
    final path = v4 < 0 ? '' : segments.skip(v4 + 1).join('/');
    final override = overrides['${request.method} $path'];
    if (override != null) return override(request);
    final isMutation = !const {'GET', 'HEAD'}.contains(request.method);
    if (isMutation) {
      final entered = mutationEntered;
      if (entered != null && !entered.isCompleted) {
        entered.complete();
        await releaseMutation!.future.timeout(mr6b2Timeout);
      }
      if (mutationStatus case final status?) {
        return jsonResponse({'message': 'synthetic'}, status: status);
      }
      if (path.contains('/suggestions/') || path.endsWith('/batch_apply')) {
        if (path.endsWith('/batch_apply')) {
          final ids = (request.data as Map)['ids'] as List;
          appliedSuggestions.addAll(ids.cast<int>());
        } else {
          appliedSuggestions.add(int.parse(segments[segments.length - 2]));
        }
        return jsonResponse({'id': 42, 'applied': true});
      }
      if (path.endsWith('/merge')) {
        mergeSent = true;
        return jsonResponse(_mergeRequest(state: 'merged'));
      }
      if (path == 'projects/9/star' && request.method == 'POST') {
        starred = true;
        return jsonResponse({...projectJson(9), 'starred': true});
      }
      if (path == 'projects/9/unstar' && request.method == 'POST') {
        starred = false;
        return jsonResponse({...projectJson(9), 'starred': false});
      }
      if (path == 'projects/9/issues/3/notes' && request.method == 'POST') {
        return jsonResponse({'id': 31, 'body': 'synthetic body'}, status: 201);
      }
      if (path.contains('/repository/files/')) {
        final body = request.data as Map;
        lastCommit = mr6b2Base;
        contents[lastCommit] = body['content'] as String? ?? 'beta\n';
        return jsonResponse({'file_path': 'src/a.txt', 'branch': branch});
      }
      if (path.endsWith('/retry') && path.contains('/jobs/')) {
        return jsonResponse(_job(id: 22));
      }
      if (path.endsWith('/play') && path.contains('/jobs/')) {
        return jsonResponse(_job());
      }
      if (path.endsWith('/retry') || path.endsWith('/cancel')) {
        return jsonResponse(_pipeline(id: 13));
      }
      if (request.method == 'DELETE' && path.contains('/pipelines/')) {
        pipelineDeleted = true;
        return ResponseBody.fromString('', 204);
      }
      if (request.method == 'DELETE' &&
          const {
            'projects/9/issues/3',
            'projects/9/merge_requests/3',
            'projects/9/issues/3/notes/8',
            'projects/9/merge_requests/3/discussions/d1/notes/8',
            'projects/9/labels/8',
            'projects/9/milestones/8',
            'projects/9/boards/8',
            'projects/9/boards/8/lists/6',
          }.contains(path)) {
        return ResponseBody.fromString('', 204);
      }
      if (path == 'todos/mark_as_done' && request.method == 'POST') {
        return ResponseBody.fromString('', 204);
      }
      throw StateError('Unexpected fake mutation: ${request.method} $path');
    }

    if (path == 'user') return jsonResponse({'id': 7, 'username': 'tester'});
    if (path == 'projects/9') {
      return jsonResponse({
        ...projectJson(9, branch: 'main'),
        'path_with_namespace': 'team/example-9',
        'visibility': 'private',
        'ci_config_path': '',
        'starred': starred,
      });
    }
    if (path.contains('/repository/branches/')) {
      final name = Uri.decodeComponent(path.split('/').last);
      return jsonResponse({
        'name': name,
        'protected': branchProtected,
        'default': name == 'main',
        'commit': {'id': mr6b2Head},
      });
    }
    if (path == 'projects/9/merge_requests/3') {
      return jsonResponse(
        _mergeRequest(state: mergeSent ? 'merged' : 'opened'),
      );
    }
    if (path.endsWith('/diffs')) {
      return jsonResponse([
        {
          'old_path': 'lib/a.dart',
          'new_path': 'lib/a.dart',
          'new_file': false,
          'deleted_file': false,
          'renamed_file': false,
        },
      ]);
    }
    if (path.endsWith('/commits')) {
      return jsonResponse([
        {'id': mr6b2Head, 'message': 'synthetic change'},
      ]);
    }
    if (path.endsWith('/closes_issues')) return jsonResponse(<Object?>[]);
    if (path.endsWith('/compare')) {
      return jsonResponse({
        'commits': [
          {'id': mr6b2Head},
        ],
        'compare_timeout': false,
      });
    }
    if (path.contains('/discussions/d1')) return jsonResponse(_discussion());
    if (path.contains('/repository/files/')) {
      if (request.method == 'HEAD') {
        return ResponseBody.fromString(
          '',
          200,
          headers: {
            'x-gitlab-last-commit-id': [lastCommit],
            'x-gitlab-size': ['6'],
          },
        );
      }
      if (path.endsWith('/raw')) {
        return ResponseBody.fromString(contents[lastCommit]!, 200);
      }
    }
    if (path == 'projects/9/pipelines/12') {
      return jsonResponse(_pipeline(), status: pipelineDeleted ? 404 : 200);
    }
    if (path == 'projects/9/jobs/21') return jsonResponse(_job());
    if (path == 'projects/9/issues/3' ||
        path == 'projects/9/merge_requests/3') {
      return jsonResponse({
        'id': 33,
        'iid': 3,
        'project_id': 9,
        'updated_at': '2026-10-23T00:00:00Z',
      });
    }
    if (path == 'projects/9/issues/3/notes/8') {
      return jsonResponse({
        'id': 8,
        'author': {'id': 7},
        'updated_at': '2026-10-23T00:00:00Z',
      });
    }
    if (path == 'projects/9/issues/3/notes/31') {
      return jsonResponse({'id': 31, 'body': 'synthetic body'});
    }
    if (path == 'projects/9/labels/8') {
      return jsonResponse({'id': 8, 'name': 'priority::high'});
    }
    if (path == 'projects/9/milestones/8') {
      return jsonResponse({
        'id': 8,
        'project_id': 9,
        'title': 'Release 1',
        'updated_at': '2026-10-23T00:00:00Z',
      });
    }
    if (path == 'projects/9/boards/8') {
      return jsonResponse({'id': 8, 'name': 'Sprint board'});
    }
    if (path == 'projects/9/boards/8/lists/6') {
      return jsonResponse({
        'id': 6,
        'label': {'id': 22, 'name': 'workflow::ready'},
      });
    }
    if (path == 'todos') {
      return jsonResponse([
        {'id': 18},
      ]);
    }
    return jsonResponse({}, status: 404);
  }

  Map<String, Object?> _mergeRequest({required String state}) => {
    'id': 33,
    'project_id': 9,
    'iid': 3,
    'state': state,
    'sha': mr6b2Head,
    'source_project_id': 9,
    'target_project_id': 9,
    'source_branch': branch,
    'target_branch': targetBranch,
    'description': '',
    'changes_count': '1',
    'diff_refs': {
      'head_sha': mr6b2Head,
      'base_sha': mr6b2Base,
      'start_sha': mr6b2Base,
    },
    'auto_merge_enabled': false,
    'author': {'id': 7},
    'user': {'can_merge': true},
  };

  Map<String, Object?> _pipeline({int id = 12}) => {
    'id': id,
    'ref': branch,
    'status': 'success',
    'source': 'push',
  };

  Map<String, Object?> _job({int id = 21}) => {
    'id': id,
    'ref': branch,
    'name': 'build',
    'stage': 'test',
    'status': 'success',
    'pipeline': {'id': 12},
  };

  Map<String, Object?> _discussion() => {
    'id': 'd1',
    'notes': [
      {
        'id': 8,
        'body': '',
        'position': {
          'new_path': 'src/a.txt',
          'old_path': 'src/a.txt',
          'position_type': 'text',
          'base_sha': mr6b2Base,
          'start_sha': mr6b2Base,
          'head_sha': mr6b2Head,
        },
        'suggestions': [
          {
            'id': 42,
            'from_content': 'alpha',
            'to_content': 'beta',
            'appliable': true,
            'applied': appliedSuggestions.contains(42),
          },
        ],
      },
    ],
  };

  void close() => api.close();
}

final class Mr6b2Harness {
  Mr6b2Harness._({
    required this.root,
    required this.ownsRoot,
    required this.ownsServer,
    required this.server,
    required this.files,
    required this.journal,
    required this.keyStore,
    required this.policy,
    required this.scope,
    required this.conversationId,
    required this.maxGitLabRequests,
  });

  static Future<Mr6b2Harness> create({
    Mr6b2Server? server,
    AiWriteJournal? journal,
    Mr6b2JournalFiles? files,
    Directory? root,
    String conversationId = 'mr6b2-conversation',
    AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
    AiWriteScope scope = mr6b2Scope,
    int maxGitLabRequests = 40,
  }) async {
    final ownsRoot = root == null;
    final actualRoot =
        root ?? Directory.systemTemp.createTempSync('mr6b2-p18-');
    final actualFiles = files ?? Mr6b2JournalFiles(actualRoot);
    final keyStore = journal == null ? MemoryAiJournalKeyStore() : null;
    final actualJournal =
        journal ??
        AiWriteJournal(
          keys: keyStore!,
          applicationSupport: actualRoot,
          files: actualFiles,
          processId: 'mr6b2-p18',
        );
    if (journal == null) {
      await actualJournal.recoverAfterAccountsLoaded([scope.accountKey]);
      await actualJournal.ensureInitialized(scope.accountKey);
    }
    final mutablePolicy = Mr6b2Policy()..level = level;
    final harness = Mr6b2Harness._(
      root: actualRoot,
      ownsRoot: ownsRoot,
      ownsServer: server == null,
      server: server ?? Mr6b2Server(),
      files: actualFiles,
      journal: actualJournal,
      keyStore: keyStore,
      policy: mutablePolicy,
      scope: scope,
      conversationId: conversationId,
      maxGitLabRequests: maxGitLabRequests,
    );
    harness.coordinator = harness.newCoordinator();
    harness.beginRun();
    return harness;
  }

  final Directory root;
  final bool ownsRoot;
  final bool ownsServer;
  final Mr6b2Server server;
  final Mr6b2JournalFiles files;
  final AiWriteJournal journal;
  final MemoryAiJournalKeyStore? keyStore;
  final Mr6b2Policy policy;
  final AiWriteScope scope;
  final String conversationId;
  int maxGitLabRequests;
  DateTime clock = DateTime.utc(2026, 10, 23, 12);
  late AiToolBudget budget;
  late PolicyAiWriteCoordinator coordinator;
  int _callId = 0;

  PolicyAiWriteCoordinator newCoordinator({
    String? conversationId,
    AiWriteScope? scope,
    Mr6b2Policy? policy,
    AiToolBudget Function()? budget,
    text.UploadPlaceholderTable? placeholders,
    AiWriteFreshnessReader? readFreshness,
    Set<String> Function()? knownSecrets,
  }) {
    final selectedScope = scope ?? this.scope;
    final selectedPolicy = policy ?? this.policy;
    return PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: selectedScope,
        level: selectedPolicy.level,
        ceiling: selectedPolicy.ceiling,
        consentHash: selectedPolicy.consentHash,
        writePolicyRevision: selectedPolicy.writePolicyRevision,
        scopeRevision: selectedPolicy.scopeRevision,
        sessionGeneration: selectedPolicy.sessionGeneration,
        toolsEnabled: selectedPolicy.toolsEnabled,
        consentValid: selectedPolicy.consentValid,
        alive: selectedPolicy.alive,
        appInForeground: selectedPolicy.appInForeground,
        clientMayStart:
            selectedPolicy.clientMayStart && server.api.mayStartRequest,
        currentJobId: selectedPolicy.currentJobId,
      ),
      createPort: () => port.GitLabAiWritePort(
        server.api,
        accountKey: selectedScope.accountKey,
      ),
      journal: journal,
      conversationId: conversationId ?? this.conversationId,
      budget: budget ?? () => this.budget,
      readFreshness:
          readFreshness ??
          (_) async => AiWriteFreshness(
            updatedAt: '2026-10-23T00:00:00Z',
            headSha: mr6b2Head,
            lastCommitId: server.lastCommit,
            visibilityUnreadable: false,
          ),
      placeholders:
          placeholders ??
          text.UploadPlaceholderTable(
            instance: GitLabInstance.parse('https://example.com/gitlab'),
          ),
      knownSecrets: knownSecrets ?? () => const {},
      safeDisplay: (value) => value,
      ledger: const VisibleProductionLedger(),
      checkFragments:
          (
            scan, {
            required knownSecrets,
            required instance,
            required visibility,
          }) {
            final result = exact.checkFragments(
              scan,
              knownSecrets: knownSecrets,
              instance: instance,
              visibility: visibility,
            );
            return (
              blockCode: result.blockCode,
              confirmReasons: result.confirmReasons,
            );
          },
      now: () => clock,
    );
  }

  void beginRun([
    String text =
        'Merge !3 from `work` to `main`, edit `src/a.txt`, apply suggestion '
        '42, retry Pipeline 12 and Job 21, and delete !3 in team/example-9.',
  ]) {
    budget = AiToolBudget(maxGitLabRequests: maxGitLabRequests);
    coordinator.beginRun(text);
    coordinator.beginTurn();
  }

  AiToolCall call(
    String operation,
    Map<String, Object?> arguments, {
    String? id,
  }) => AiToolCall(
    id: id ?? 'p18-${_callId++}',
    name: operation,
    arguments: {...arguments, 'reason': 'synthetic packet 18 request'},
  );

  Future<AiWriteProposal?> propose(
    String operation,
    Map<String, Object?> arguments, {
    String? id,
  }) => coordinator
      .propose(call(operation, arguments, id: id))
      .timeout(mr6b2Timeout);

  Future<AiWriteOutcome> approve(
    AiWriteProposal proposal, {
    String? typedName,
  }) => coordinator
      .approve(proposal, typedName: typedName ?? proposal.tier.typedName)
      .timeout(mr6b2Timeout);

  Future<port.AiWritePrepared> prepare(
    String operation,
    Map<String, Object?> arguments, {
    String executionId = 'p18-direct',
  }) => server.writePort.prepare(
    port.AiWriteRequest(
      operationId: operation,
      executionId: executionId,
      scope: scope,
      arguments: arguments,
      scheduleHmacKey: journal.scheduleHmacKey,
    ),
  );

  Future<void> waitUntil(bool Function() condition) async {
    final deadline = DateTime.now().add(mr6b2Timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException('packet 18 condition was not reached');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<Map<String, Object?>> readDurableJournal() async {
    final store = keyStore;
    if (store == null) throw StateError('The injected journal owns its keys.');
    return AiHistoryCipher.decryptJson(
      File(files.pathFor(scope.accountKey)).readAsBytesSync(),
      store.keys[scope.accountKey]!,
      scope.accountKey,
      AiJournalFiles.fileName,
    );
  }

  Future<void> dispose() async {
    files.releaseBarrier();
    server.releaseMutationBarrier();
    coordinator.stop('disposed');
    if (ownsServer) server.close();
    if (ownsRoot && root.existsSync()) root.deleteSync(recursive: true);
  }
}

Map<String, Object?> mr6b2Args(String operation) => switch (operation) {
  'mergeRequest' => {'projectId': 9, 'iid': 3},
  'deleteMergeRequest' => {'projectId': 9, 'iid': 3},
  'pipelineAction' => {'projectId': 9, 'pipelineId': 12, 'action': 'retry'},
  'jobAction' => {'projectId': 9, 'jobId': 21, 'action': 'retry'},
  'deletePipeline' => {'projectId': 9, 'pipelineId': 12},
  'setStar' => {'projectId': 9, 'starred': true},
  'createNote' => {
    'projectId': 9,
    'resource': 'issues',
    'iid': 3,
    'body': 'synthetic body',
  },
  'edit_file' || 'applySuggestion' => p6Args(operation),
  _ => throw ArgumentError.value(operation, 'operation'),
};
