import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/ai/exact_edit.dart' as exact;
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';

const p6Account = 'https://example.com/gitlab#7';
const p6Scope = AiWriteScope(
  accountKey: p6Account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 9,
      projectPath: 'team/example-9',
    ),
  ],
);
const p6Timeout = Duration(seconds: 20);
final p6L = 'a' * 40;
final p6NextL = 'b' * 40;

Map<String, Object?> p6Args(String op, {String path = 'src/a.txt'}) => {
  'projectId': 9,
  if (op == 'applySuggestion' || op == 'batchApplySuggestions') ...{
    'iid': 3,
    'commitMessage': 'apply synthetic change',
    if (op == 'applySuggestion') ...{
      'discussionId': 'd1',
      'noteId': 8,
      'suggestionId': 42,
    } else
      'suggestions': [p6Item(1)],
  } else ...{
    'path': path,
    'branch': 'work',
    'commitMessage': 'synthetic change',
    if (op == 'edit_file')
      'edits': [
        {'old': 'alpha', 'new': 'beta'},
      ],
    if (op == 'createFile') 'content': 'beta\n',
  },
};

Map<String, Object?> p6Item(int index) => {
  'discussionId': 'd$index',
  'noteId': 7 + index,
  'suggestionId': 41 + index,
};

port.AiWriteRequest p6Request(
  String op,
  Map<String, Object?> args, {
  String execution = 'execution',
  AiWriteScope scope = p6Scope,
}) => port.AiWriteRequest(
  operationId: op,
  executionId: execution,
  scope: scope,
  arguments: args,
);

final class P6Server {
  P6Server() {
    adapter = FakeAdapter((r) async {
      await beforeRequest?.call(r);
      return respond(r);
    });
    api = testApi(adapter);
    writePort = port.GitLabAiWritePort(api, accountKey: p6Account);
  }
  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final port.GitLabAiWritePort writePort;
  FutureOr<void> Function(RequestOptions)? beforeRequest;
  String? lastCommit = p6L;
  final contents = <String, String>{p6L: 'alpha\n', p6NextL: 'newer\n'};
  String? ciConfig = '';
  String defaultBranch = 'main';
  String branchName = 'work';
  bool protected = false;
  bool branchDefault = false;
  bool missing = false;
  bool readbackFails = false;
  bool suggestionReadbackApplied = true;
  bool suggestionAppliable = true;
  bool suggestionApplied = false;
  int projectId = 9;
  int sourceProjectId = 9;
  String mrSha = p6L;
  String mrBase = p6L;
  String? positionHead;
  String? positionType = 'text';
  Object? positionOldPath;
  bool omitPositionPaths = false;
  int noteIdOffset = 7;
  int suggestionOffset = 41;
  String suggestionPath = 'src/a.txt';
  String? suggestionOldPath;
  String suggestionBody = '';
  String suggestionBefore = 'alpha';
  String suggestionAfter = 'beta';
  int? mutationStatus;
  int mutations = 0;
  final appliedIds = <int>{};

  Iterable<RequestOptions> get writes =>
      adapter.requests.where((r) => !const {'GET', 'HEAD'}.contains(r.method));

  ResponseBody respond(RequestOptions r) {
    final path = r.uri.path;
    if (!const {'GET', 'HEAD'}.contains(r.method)) {
      mutations++;
      if (mutationStatus case final code?) {
        return jsonResponse({}, status: code);
      }
      final body = r.data! as Map;
      if (path.endsWith('/apply') || path.endsWith('/batch_apply')) {
        if (path.endsWith('/batch_apply')) {
          appliedIds.addAll((body['ids'] as List).cast<int>());
        } else {
          appliedIds.add(int.parse(r.uri.pathSegments.reversed.skip(1).first));
        }
        return jsonResponse({'id': 42, 'applied': true});
      }
      if (r.method == 'DELETE') return ResponseBody.fromString('', 204);
      if (r.method == 'PUT' && body['last_commit_id'] != lastCommit) {
        return jsonResponse({}, status: 409);
      }
      if (r.method == 'POST' && !missing) return jsonResponse({}, status: 400);
      missing = false;
      lastCommit = p6NextL;
      contents[p6NextL] = body['content']! as String;
      return jsonResponse({'file_path': 'src/a.txt', 'branch': 'work'});
    }
    if (readbackFails && mutations > 0) return jsonResponse({}, status: 401);
    if (path.endsWith('/user')) {
      return jsonResponse({'id': 7, 'username': 'tester'});
    }
    if (path.endsWith('/projects/9')) {
      return jsonResponse({
        ...projectJson(projectId, branch: defaultBranch),
        'ci_config_path': ciConfig,
      });
    }
    if (path.contains('/repository/branches/')) {
      return jsonResponse({
        'name': branchName,
        'protected': protected,
        'default': branchDefault,
        'commit': {'id': p6L},
      });
    }
    if (path.endsWith('/merge_requests/3')) {
      return jsonResponse({
        'iid': 3,
        'project_id': 9,
        'source_project_id': sourceProjectId,
        'source_branch': branchName,
        'sha': mrSha,
        'diff_refs': {'base_sha': mrBase, 'start_sha': p6L, 'head_sha': mrSha},
      });
    }
    if (path.contains('/discussions/')) {
      final discussion = r.uri.pathSegments.last;
      final index = int.parse(discussion.substring(1));
      final id = suggestionOffset + index;
      return jsonResponse({
        'id': discussion,
        'notes': [
          {
            'id': noteIdOffset + index,
            'body': suggestionBody,
            'position': {
              if (!omitPositionPaths) ...{
                'new_path': suggestionPath,
                'old_path':
                    positionOldPath ?? suggestionOldPath ?? suggestionPath,
              },
              'position_type': positionType,
              'base_sha': mrBase,
              'start_sha': p6L,
              'head_sha': positionHead ?? mrSha,
            },
            'suggestions': [
              {
                'id': id,
                'from_content': suggestionBefore,
                'to_content': suggestionAfter,
                'appliable': suggestionAppliable,
                'applied':
                    suggestionApplied ||
                    (suggestionReadbackApplied && appliedIds.contains(id)),
              },
            ],
          },
        ],
      });
    }
    if (path.contains('/repository/files/')) {
      if (missing) return jsonResponse({}, status: 404);
      final ref = r.uri.queryParameters['ref'];
      if (r.method == 'HEAD') {
        return ResponseBody.fromString(
          '',
          200,
          headers: {
            if (lastCommit != null) 'x-gitlab-last-commit-id': [lastCommit!],
            'x-gitlab-size': ['6'],
          },
        );
      }
      if (path.endsWith('/raw')) {
        return ResponseBody.fromString(
          contents[ref] ?? contents[lastCommit]!,
          200,
        );
      }
    }
    return jsonResponse({}, status: 404);
  }

  void close() => api.close();
}

final class P6Coordinator {
  P6Coordinator._(this.server, this.root, this.journal);
  static Future<P6Coordinator> create(
    P6Server server, {
    int budget = 40,
    AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
  }) async {
    final root = Directory.systemTemp.createTempSync('p6-journal-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'p6',
    );
    await journal.recoverAfterAccountsLoaded([p6Account]);
    await journal.ensureInitialized(p6Account);
    final harness = P6Coordinator._(server, root, journal);
    harness.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: p6Scope,
        level: level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'synthetic',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
      ),
      createPort: () => server.writePort,
      journal: journal,
      conversationId: 'p6-conversation',
      budget: () => harness.budget,
      readFreshness: (_) async =>
          const AiWriteFreshness(visibilityUnreadable: false),
      placeholders: text.UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => harness.secrets,
      safeDisplay: (value) => value,
      ledger: const P6Ledger(),
      checkFragments:
          (
            scan, {
            required knownSecrets,
            required instance,
            required visibility,
          }) {
            final checked = exact.checkFragments(
              scan,
              knownSecrets: knownSecrets,
              instance: instance,
              visibility: visibility,
            );
            return (
              blockCode: checked.blockCode,
              confirmReasons: checked.confirmReasons,
            );
          },
    );
    harness.budget = AiToolBudget(maxGitLabRequests: budget);
    harness.coordinator.beginRun(
      'Change `work` `src/a.txt` !3 in team/example-9',
    );
    harness.coordinator.beginTurn();
    return harness;
  }

  final P6Server server;
  final Directory root;
  final AiWriteJournal journal;
  late PolicyAiWriteCoordinator coordinator;
  late AiToolBudget budget;
  Set<String> secrets = {};
  void beginRun(String message) {
    budget = AiToolBudget(maxGitLabRequests: 40);
    coordinator.beginRun(message);
    coordinator.beginTurn();
  }

  Future<AiWriteProposal?> propose(
    String op, {
    Map<String, Object?>? args,
    String id = 'call',
  }) => coordinator
      .propose(
        AiToolCall(
          id: id,
          name: op,
          arguments: {...(args ?? p6Args(op)), 'reason': 'synthetic request'},
        ),
      )
      .timeout(p6Timeout);
  Future<void> dispose() async {
    coordinator.stop('testEnd');
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

final class P6Ledger implements AiCapabilityLedger {
  const P6Ledger();
  @override
  AiCapability? find(String op) {
    final row = productionAiLedger.find(op);
    if (row == null || !aiFileRows.contains(row)) return row;
    return AiCapability(
      operationId: row.operationId,
      namedMethod: row.namedMethod,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      arguments: row.arguments,
      httpCap: row.httpCap,
      readback: row.readback,
      editableField: row.editableField,
    );
  }

  @override
  List<AiCapability> get modelVisible => [
    for (final row in aiFileRows) find(row.operationId)!,
  ];
}

String p6Body(RequestOptions request) => jsonEncode(request.data);
