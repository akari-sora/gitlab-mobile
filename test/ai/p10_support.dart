import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';

const p10Account = 'https://example.com/gitlab#7';
const p10Scope = AiWriteScope(
  accountKey: p10Account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 9,
      projectPath: 'team/example-9',
    ),
  ],
);
const p10Timeout = Duration(seconds: 20);

Map<String, Object?> p10Args(String op, {String? path}) => switch (op) {
  'createSnippet' => {
    'projectId': 9,
    'title': 'Snippet',
    'description': '',
    'visibility': 'private',
    'path': path ?? 'a.txt',
    'content': 'alpha\n',
  },
  'updateSnippetMetadata' => {
    'projectId': 9,
    'snippetId': 12,
    'fields': {
      'title': 'Updated snippet',
      'description': '',
      'visibility': 'private',
    },
  },
  'updateSnippet' => {
    'projectId': 9,
    'snippetId': 12,
    'edits': [
      {'old': 'alpha', 'new': 'beta'},
    ],
  },
  'updateSnippetFiles' => {
    'projectId': 9,
    'snippetId': 12,
    'actions': [
      {'action': 'create', 'file_path': path ?? 'new.txt', 'content': 'beta\n'},
    ],
  },
  'deleteSnippetFile' => {
    'projectId': 9,
    'snippetId': 12,
    'path': path ?? 'a.txt',
  },
  'deleteSnippet' => {'projectId': 9, 'snippetId': 12},
  _ => {'projectId': 9, 'snippetId': 12},
};

port.AiWriteRequest p10Request(
  String op,
  Map<String, Object?> args, {
  String execution = 'execution',
  AiWriteScope scope = p10Scope,
}) => port.AiWriteRequest(
  operationId: op,
  executionId: execution,
  scope: scope,
  arguments: args,
);

final class P10Server {
  P10Server({Map<String, String>? initialContents, this.oauthReplay = false})
    : contents = <String, String>{'a.txt': 'alpha\n', ...?initialContents},
      record = <String, Object?>{
        'id': 12,
        'project_id': 9,
        'title': 'Snippet',
        'description': '',
        'visibility': 'private',
        'updated_at': '2026-10-23T00:00:00Z',
        'file_name': 'a.txt',
      } {
    _syncFiles();
    adapter = FakeAdapter((request) async {
      await beforeRequest?.call(request);
      if (request.uri.path.endsWith('/oauth/token')) {
        refreshes++;
        return jsonResponse({
          'access_token': 'synthetic-access-$refreshes',
          'refresh_token': 'synthetic-refresh-$refreshes',
          'token_type': 'bearer',
        });
      }
      if (oauthReplay && request.method == 'GET') {
        _replayNext = !_replayNext;
        if (_replayNext) return jsonResponse({}, status: 401);
      }
      return respond(request);
    });
    if (oauthReplay) {
      final dio = Dio()..httpClientAdapter = adapter;
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      api = GitLabApi(
        instance: instance,
        credential: const OAuthCredential(
          accessToken: 'synthetic-access',
          refreshToken: 'synthetic-refresh',
          clientId: 'synthetic-client',
        ),
        dio: dio,
        oauth: OAuthTokenClient(
          instance: instance,
          clientId: 'synthetic-client',
          dio: dio,
        ),
      );
    } else {
      api = testApi(adapter);
    }
    writePort = port.GitLabAiWritePort(api, accountKey: p10Account);
  }

  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final port.GitLabAiWritePort writePort;
  FutureOr<void> Function(RequestOptions)? beforeRequest;

  final Map<String, Object?> record;
  final Map<String, String> contents;
  final bool oauthReplay;
  int actorId = 7;
  int projectId = 9;
  String projectPath = 'team/example-9';
  int mutations = 0;
  int refreshes = 0;
  int? mutationStatus;
  int? readbackStatus;
  bool corruptReadback = false;
  bool deleted = false;
  bool _replayNext = false;
  int _revision = 0;

  int get snippetProjectId => record['project_id']! as int;
  set snippetProjectId(int value) => record['project_id'] = value;

  Iterable<RequestOptions> get writes => adapter.requests.where(
    (request) =>
        !const {'GET', 'HEAD'}.contains(request.method) &&
        !request.uri.path.endsWith('/oauth/token'),
  );

  String _rawUrl(String path) =>
      'https://example.com/gitlab/team/example-9/-/snippets/12/raw/main/$path';

  void _syncFiles() {
    record['files'] = <Map<String, Object?>>[
      for (final path in contents.keys)
        {'path': path, 'raw_url': _rawUrl(path)},
    ];
    if (contents.isNotEmpty) record['file_name'] = contents.keys.first;
  }

  Map<String, Object?> _recordResponse() {
    if (!corruptReadback || mutations == 0) return {...record};
    return {...record, 'project_id': snippetProjectId + 1};
  }

  ResponseBody respond(RequestOptions request) {
    final segments = request.uri.pathSegments;
    final snippetIndex = segments.indexOf('snippets');
    final isSnippet =
        snippetIndex >= 0 &&
        snippetIndex + 1 < segments.length &&
        segments[snippetIndex + 1] == '12';

    if (!const {'GET', 'HEAD'}.contains(request.method)) {
      mutations++;
      if (mutationStatus case final status?) {
        return jsonResponse({'message': 'synthetic failure'}, status: status);
      }
      if (request.method == 'DELETE' && isSnippet) {
        deleted = true;
        return ResponseBody.fromString('', 204);
      }
      final body = Map<String, Object?>.from(request.data! as Map);
      if (request.method == 'POST' && segments.last == 'snippets') {
        deleted = false;
        _applyMetadata(body);
        contents
          ..clear()
          ..addEntries(_createdFiles(body));
        _touch();
        return jsonResponse({...record}, status: 201);
      }
      if (request.method == 'PUT' && isSnippet) {
        _applyMetadata(body);
        _applyActions(body['files']);
        _touch();
        return jsonResponse({...record});
      }
      return jsonResponse({}, status: 404);
    }

    if (segments.last == 'user') {
      return jsonResponse({'id': actorId, 'username': 'tester'});
    }
    if (segments.length >= 2 &&
        segments[segments.length - 2] == 'projects' &&
        segments.last == '9') {
      return jsonResponse({
        ...projectJson(projectId),
        'path_with_namespace': projectPath,
      });
    }
    final failedReadbackStatus = readbackStatus;
    if (isSnippet && mutations > 0 && failedReadbackStatus != null) {
      return jsonResponse({
        'message': 'synthetic readback failure',
      }, status: failedReadbackStatus);
    }
    if (isSnippet && segments.last == 'raw') {
      if (deleted) return jsonResponse({}, status: 404);
      final path = _rawPath(segments, snippetIndex);
      final content = contents[path];
      if (content == null) return jsonResponse({}, status: 404);
      return ResponseBody.fromString(content, 200);
    }
    if (isSnippet && segments.length == snippetIndex + 2) {
      if (deleted) return jsonResponse({}, status: 404);
      return jsonResponse(_recordResponse());
    }
    return jsonResponse({}, status: 404);
  }

  Iterable<MapEntry<String, String>> _createdFiles(
    Map<String, Object?> body,
  ) sync* {
    final files = body['files'];
    if (files is! List) return;
    for (final raw in files) {
      if (raw is! Map) continue;
      final path = raw['file_path'];
      final content = raw['content'];
      if (path is String && content is String) yield MapEntry(path, content);
    }
  }

  void _applyMetadata(Map<String, Object?> body) {
    for (final key in const ['title', 'description', 'visibility']) {
      if (body[key] case final String value) record[key] = value;
    }
  }

  void _applyActions(Object? rawFiles) {
    if (rawFiles is! List) return;
    for (final raw in rawFiles) {
      if (raw is! Map) continue;
      final action = raw['action'];
      final path = raw['file_path'];
      if (action is! String || path is! String) continue;
      switch (action) {
        case 'create':
        case 'update':
          if (raw['content'] case final String content) {
            contents[path] = content;
          }
        case 'move':
          final previous = raw['previous_path'];
          if (previous is String) {
            final content = contents.remove(previous);
            if (content != null) contents[path] = content;
          }
        case 'delete':
          contents.remove(path);
      }
    }
  }

  String _rawPath(List<String> segments, int snippetIndex) {
    if (segments.length == snippetIndex + 3) {
      return record['file_name']! as String;
    }
    if (segments.length == snippetIndex + 6 &&
        segments[snippetIndex + 2] == 'files' &&
        segments[snippetIndex + 3] == 'main') {
      return segments[snippetIndex + 4];
    }
    return '';
  }

  void _touch() {
    _revision++;
    record['updated_at'] =
        '2026-10-23T00:00:${_revision.toString().padLeft(2, '0')}Z';
    _syncFiles();
  }

  void close() => api.close();
}

final class P10Coordinator {
  P10Coordinator._(
    this.server,
    this.root,
    this.journal,
    this.placeholders,
    this._budgetLimit,
  );

  static Future<P10Coordinator> create(
    P10Server server, {
    AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
    int budget = 40,
    AiWriteFreshnessReader? readFreshness,
  }) async {
    final root = Directory.systemTemp.createTempSync('p10-journal-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'p10',
    );
    await journal.recoverAfterAccountsLoaded([p10Account]);
    await journal.ensureInitialized(p10Account);
    final placeholders = text.UploadPlaceholderTable(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
    );
    final harness = P10Coordinator._(
      server,
      root,
      journal,
      placeholders,
      budget,
    );
    harness.budget = AiToolBudget(maxGitLabRequests: budget);
    harness.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        appInForeground: true,
        scope: p10Scope,
        level: level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'synthetic',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
      ),
      createPort: () => server.writePort,
      journal: journal,
      conversationId: 'p10-conversation',
      budget: () => harness.budget,
      readFreshness:
          readFreshness ??
          (_) async {
            await server.api.record(['projects', '9']);
            return const AiWriteFreshness(visibilityUnreadable: false);
          },
      placeholders: placeholders,
      knownSecrets: () => harness.secrets,
      safeDisplay: (value) => value,
      ledger: const P10Ledger(),
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
    harness.beginRun();
    return harness;
  }

  final P10Server server;
  final Directory root;
  final AiWriteJournal journal;
  final text.UploadPlaceholderTable placeholders;
  final int _budgetLimit;
  late PolicyAiWriteCoordinator coordinator;
  late AiToolBudget budget;
  Set<String> secrets = {};

  void beginRun([String message = 'Change snippet #12 in team/example-9']) {
    budget = AiToolBudget(maxGitLabRequests: _budgetLimit);
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
          arguments: {...(args ?? p10Args(op)), 'reason': 'synthetic request'},
        ),
      )
      .timeout(p10Timeout);

  Future<void> dispose() async {
    coordinator.stop('testEnd');
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

final class P10Ledger implements AiCapabilityLedger {
  const P10Ledger();

  @override
  AiCapability? find(String op) {
    final row = productionAiLedger.find(op);
    if (row == null || !aiSnippetRows.contains(row)) return row;
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
    for (final row in aiSnippetRows) find(row.operationId)!,
  ];
}

String p10Body(RequestOptions request) => jsonEncode(request.data);
