import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_support.dart';

const _operation = 'deleteWorkItemActivityNote';
const _path = 'team/example-9';
const _workItem = 'gid://gitlab/WorkItem/31';
const _noteId = 'gid://gitlab/Note/401';
const _discussionId = 'gid://gitlab/Discussion/synthetic';
const _actorId = 'gid://gitlab/User/7';
const _created = '2026-10-01T01:02:03Z';
const _updated = '2026-10-01T01:03:04Z';
const _body = 'Synthetic own note\nSecond line\nThird line\nFourth line';
const _args = <String, Object?>{'projectId': 9, 'iid': 3, 'noteId': 401};

port.AiWriteRequest _request({
  Map<String, Object?> arguments = _args,
  AiWriteScope scope = mr6b3Scope,
  String executionId = 'p10-direct',
}) => port.AiWriteRequest(
  operationId: _operation,
  executionId: executionId,
  scope: scope,
  arguments: arguments,
);

Matcher _refused(String reason) => isA<port.AiWriteRefused>().having(
  (error) => error.reason,
  'reason',
  reason,
);

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

Map<String, Object?> _pageInfo({bool more = false, String? cursor}) => {
  'hasNextPage': more,
  'endCursor': more ? cursor ?? 'next-discussion' : null,
};

/// Counts actual adapter traffic independently of the ledger and port.
final class _Server {
  _Server({this.oauth = false}) {
    adapter = FakeAdapter(_respond);
    if (oauth) {
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final dio = Dio()..httpClientAdapter = adapter;
      api = GitLabApi(
        instance: instance,
        dio: dio,
        credential: const OAuthCredential(
          accessToken: 'synthetic-access',
          refreshToken: 'synthetic-refresh',
          clientId: 'synthetic-app',
        ),
        oauth: OAuthTokenClient(
          instance: instance,
          clientId: 'synthetic-app',
          dio: dio,
        ),
      );
    } else {
      api = testApi(adapter);
    }
    writePort = port.GitLabAiWritePort(api, accountKey: mr6b3Account);
  }

  final bool oauth;
  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final port.GitLabAiWritePort writePort;
  String authorId = _actorId;
  String actorId = _actorId;
  int userId = 7;
  String body = _body;
  String updated = _updated;
  String revision = '2026-10-02T00:00:00Z';
  bool missing = false;
  bool canDelete = true;
  bool internal = false;
  bool system = false;
  bool twoPages = true;
  bool truncated = false;
  bool unsupportedControls = false;
  bool replayReads = false;
  bool _awaitingReplay = false;
  int mutationStatus = 200;
  int readbackStatus = 200;
  Object? errors = const <Object?>[];
  Map<String, Object?> parentChanges = {};
  Map<String, Object?> noteChanges = {};
  Map<String, Object?>? readback;
  void Function(int)? onAccess;
  void Function()? onMutation;
  int mutations = 0;
  int httpReads = 0;
  int refreshes = 0;
  final logicalReads = <String, int>{};
  final events = <String>[];

  int get reads => logicalReads.values.fold(0, (sum, count) => sum + count);

  Map<String, Object?> identity() => {
    'id': _workItem,
    'iid': '3',
    'project': {'id': 'gid://gitlab/Project/9', 'fullPath': _path},
    'namespace': {
      'id': 'gid://gitlab/Namespaces::ProjectNamespace/9',
      'fullPath': _path,
    },
    ...parentChanges,
  };

  Map<String, Object?> note() => {
    'id': _noteId,
    'system': system,
    'systemNoteIconName': null,
    'body': body,
    'createdAt': _created,
    'updatedAt': updated,
    'author': {
      'id': authorId,
      'name': 'Synthetic author',
      'username': 'synthetic',
    },
    'internal': internal,
    'noteableType': 'Issue',
    'noteableId': 31,
    'project': {'id': 'gid://gitlab/Project/9', 'fullPath': _path},
    'discussion': {'id': _discussionId, 'createdAt': _created},
    'userPermissions': {'adminNote': canDelete},
    ...noteChanges,
  };

  Map<String, Object?> activity({required bool first}) {
    final empty = first && twoPages;
    return {
      'data': {
        'workItem': {
          ...identity(),
          'widgets': [
            {
              'type': 'NOTES',
              'discussionLocked': false,
              'discussions': {
                'nodes': [
                  if (!empty && !missing)
                    {
                      'id': _discussionId,
                      'replyId':
                          'gid://gitlab/IndividualNoteDiscussion/synthetic',
                      'createdAt': _created,
                      'notes': {
                        'nodes': [note()],
                        'pageInfo': _pageInfo(),
                      },
                    },
                ],
                'pageInfo': _pageInfo(
                  more: empty || truncated,
                  cursor: empty ? 'next-discussion' : 'third-discussion',
                ),
              },
            },
          ],
        },
      },
    };
  }

  ResponseBody _respond(RequestOptions request) {
    expect(request.followRedirects, isFalse);
    if (request.uri.path.endsWith('/oauth/token')) {
      refreshes++;
      return jsonResponse({
        'access_token': 'synthetic-rotated-access',
        'refresh_token': 'synthetic-rotated-refresh',
        'token_type': 'bearer',
        'expires_in': 7200,
      });
    }
    final data = request.data;
    final query = data is Map ? data['query'] as String? : null;
    final variables = data is Map ? data['variables'] as Map? : null;
    if (query?.startsWith('mutation ') == true) {
      expect(request.uri.path, '/gitlab/api/graphql');
      expect(query, startsWith('mutation MobileDestroyWorkItemActivityNote'));
      expect(query, isNot(contains('body')));
      expect(variables, {
        'input': {'id': _noteId},
      });
      mutations++;
      events.add('mutation');
      onMutation?.call();
      return jsonResponse({
        'data': {
          'destroyNote': {'errors': errors},
        },
      }, status: mutationStatus);
    }
    httpReads++;
    if (replayReads && !_awaitingReplay) {
      _awaitingReplay = true;
      return jsonResponse({}, status: 401);
    }
    _awaitingReplay = false;
    final String kind;
    if (request.uri.path.endsWith('/api/v4/user')) {
      kind = 'user';
    } else if (request.uri.path.endsWith('/api/v4/projects/9')) {
      kind = 'freshness';
    } else {
      expect(request.uri.path, '/gitlab/api/graphql');
      kind = RegExp(r'^query\s+(\w+)').firstMatch(query!)!.group(1)!;
    }
    logicalReads.update(kind, (count) => count + 1, ifAbsent: () => 1);
    events.add(kind);
    switch (kind) {
      case 'user':
        return jsonResponse({'id': userId, 'username': 'synthetic'});
      case 'freshness':
        return jsonResponse(projectJson(9));
      case 'MobileProjectWorkItem':
        expect(variables, {'path': _path, 'iid': '3'});
        return jsonResponse({
          'data': {
            'project': {
              'id': 'gid://gitlab/Project/9',
              'fullPath': _path,
              'workItems': {
                'nodes': [
                  {
                    ...identity(),
                    'title': 'Synthetic task',
                    'state': 'OPEN',
                    'createdAt': _created,
                    'updatedAt': revision,
                    'workItemType': {
                      'id': 'gid://gitlab/WorkItems::Type/1',
                      'name': 'Task',
                    },
                    'description': null,
                    'widgets': <Object?>[],
                  },
                ],
                'pageInfo': _pageInfo(),
              },
            },
          },
        });
      case 'MobileWorkItemActivity':
        if (unsupportedControls && query!.contains(r'$filter')) {
          return jsonResponse({
            'errors': [
              {
                'message':
                    "Field 'discussions' doesn't accept argument 'filter'",
                'extensions': {
                  'code': 'argumentNotAccepted',
                  'name': 'discussions',
                  'typeName': 'Field',
                  'argumentName': 'filter',
                },
              },
            ],
          });
        }
        return jsonResponse(activity(first: variables!['after'] == null));
      case 'MobileWorkItemActivityEditAccess':
        onAccess?.call(logicalReads[kind]!);
        return jsonResponse({
          'data': {
            'currentUser': {'id': actorId},
            'workItem': identity(),
            'note': missing ? null : note(),
          },
        });
      case 'MobileWorkItemActivityDeleteReadback':
        expect(variables, {'workItemId': _workItem, 'noteId': _noteId});
        return jsonResponse({
          'data':
              readback ??
              {
                'currentUser': {'id': actorId},
                'workItem': identity(),
                'note': null,
              },
        }, status: readbackStatus);
      default:
        fail('Unexpected synthetic request: $kind');
    }
  }

  Future<port.AiWriteSettled> delete() async {
    final prepared = await writePort.prepare(_request());
    prepared.bindGraphBeforeMutation(() async {});
    return await writePort.commit(prepared, mayStart: () => true)
        as port.AiWriteSettled;
  }
}

/// Test-only visibility; the production row has been visible since P14.
final class _P10Ledger implements AiCapabilityLedger {
  const _P10Ledger();

  @override
  AiCapability? find(String operationId) {
    if (operationId != _operation) return null;
    final row = productionAiLedger.find(operationId)!;
    return AiCapability(
      operationId: row.operationId,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      boundary: row.boundary,
      modelVisible: true,
      namedMethod: row.namedMethod,
      arguments: row.arguments,
      httpCap: row.httpCap,
      readback: row.readback,
    );
  }

  @override
  List<AiCapability> get modelVisible => [find(_operation)!];
}

final class _Harness {
  _Harness._(this.server, this.root, this.files, this.journal, this.budget);

  static Future<_Harness> create({
    bool oauth = false,
    int allowance = 40,
  }) async {
    final server = _Server(oauth: oauth)..replayReads = oauth;
    final root = Directory.systemTemp.createTempSync('p10-delete-');
    final files = Mr6b3JournalFiles(root);
    final journal = AiWriteJournal(
      keys: Mr6b3JournalKeyStore(),
      applicationSupport: root,
      files: files,
      processId: 'p10-delete',
    );
    await journal.recoverAfterAccountsLoaded([mr6b3Account]);
    await journal.ensureInitialized(mr6b3Account);
    final harness = _Harness._(
      server,
      root,
      files,
      journal,
      AiToolBudget(maxGitLabRequests: allowance),
    );
    harness.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        appInForeground: true,
        scope: mr6b3Scope,
        level: harness.policy.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'synthetic-consent',
        writePolicyRevision: harness.policy.revision,
        scopeRevision: 1,
        sessionGeneration: 7,
        alive: harness.policy.alive,
        consentValid: harness.policy.consentValid,
        clientMayStart: harness.policy.clientMayStart,
      ),
      createPort: () => server.writePort,
      journal: journal,
      conversationId: 'p10-delete',
      budget: () => harness.budget,
      readFreshness: (_) async {
        final project = await server.api.record(['projects', '9']);
        expect(project['id'], 9);
        return const AiWriteFreshness(visibilityUnreadable: false);
      },
      placeholders: text.UploadPlaceholderTable(instance: server.api.instance),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: const _P10Ledger(),
      now: () => harness.clock,
    );
    harness.coordinator.beginRun('Delete my note 401 on #3 in $_path.');
    harness.coordinator.beginTurn();
    return harness;
  }

  final _Server server;
  final Directory root;
  final Mr6b3JournalFiles files;
  final AiWriteJournal journal;
  final AiToolBudget budget;
  final policy = Mr6b3Policy();
  DateTime clock = DateTime.utc(2026, 10, 23, 12);
  late final PolicyAiWriteCoordinator coordinator;

  Future<AiWriteProposal?> propose({
    String id = 'p10-call',
    Map<String, Object?> arguments = _args,
  }) => coordinator.propose(
    AiToolCall(
      id: id,
      name: _operation,
      arguments: {...arguments, 'reason': 'Synthetic delete request'},
    ),
  );

  Future<AiWriteOutcome> approve(AiWriteProposal proposal) =>
      coordinator.approve(proposal, typedName: '#3').timeout(mr6b3Timeout);

  Future<void> dispose() async {
    files.releaseBarrier();
    coordinator.stop('disposed');
    server.api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

void main() {
  test(
    'P10 row is visible graph T4 with exact numeric arguments and fixed cap',
    () {
      final row = productionAiLedger.find(_operation)!;
      expect(row.baseTier, AiWriteTier.t4);
      expect(row.scopeClass, AiScopeClass.workItem);
      expect(row.boundary, AiWriteBoundary.graph);
      expect(row.namedMethod, _operation);
      expect(row.modelVisible, isTrue);
      expect(row.readback, isTrue);
      expect(productionAiLedger.modelVisible, contains(row));
      expect(row.arguments.keys, unorderedEquals(_args.keys));
      for (final argument in row.arguments.values) {
        expect(argument.type, AiArgType.integer);
        expect(argument.required, isTrue);
      }
      const independentlyCountedReads = 2 * (1 + 1 + 1 + 2 + 1) + 1 + 1;
      expect(independentlyCountedReads, 14);
      expect(row.httpCap, 2 * independentlyCountedReads + 1);
      expect(aiWriteRequestAllowance(_operation), 29);
      expect(aiWriteRequestAllowance(_operation, oauthReplay: false), 15);
      final edit = productionAiLedger.find('editWorkItemActivityNote')!;
      expect(edit.modelVisible, isTrue);
      expect(edit.baseTier, AiWriteTier.t2);
    },
  );

  test(
    'own-note delete binds note and parent, reuses delete preview, reads note:null',
    () async {
      final server = _Server();
      addTearDown(server.api.close);
      final prepared = await server.writePort.prepare(_request());
      expect(prepared.boundary, AiWriteBoundary.graph);
      expect(prepared.releaseName, '#3');
      expect(prepared.confirmName, '#3');
      expect(prepared.projectPath, _path);
      expect(prepared.bindingDigest, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(prepared.writeKeys.single.parts, [
        mr6b3Account,
        'project:9',
        'workItem',
        '3',
        'notes',
        '401',
      ]);
      expect(prepared.bindingTargets.single.noteId, 401);
      expect(prepared.bindingTargets.single.parentIid, 3);
      final preview = prepared.preview as port.AiDeletePreview;
      expect(preview.parentName, '#3');
      expect(preview.path, _path);
      expect(preview.author, '@synthetic');
      expect(preview.excerpt, 'Synthetic own note\nSecond line\nThird line');
      expect(server.mutations, 0);
      prepared.bindGraphBeforeMutation(() async => server.events.add('B'));
      final outcome =
          await server.writePort.commit(
                prepared,
                mayStart: () {
                  server.events.add('A');
                  return true;
                },
              )
              as port.AiWriteSettled;
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.mutationCount, 1);
      expect(outcome.readbackVerified, isTrue);
      expect(outcome.projection, {..._args, 'deleted': true});
      expect(server.events.skip(server.events.length - 4), [
        'B',
        'A',
        'mutation',
        'MobileWorkItemActivityDeleteReadback',
      ]);
      final repeated = await server.writePort.commit(
        prepared,
        mayStart: () => true,
      );
      expect(repeated, isA<port.AiWriteNotSent>());
      expect(server.mutations, 1);
    },
  );

  for (final author in [
    'gid://gitlab/User/8',
    'gid://gitlab/User/17',
    'gid://gitlab/User/70',
  ]) {
    test(
      'Maintainer permission cannot delete non-own author $author',
      () async {
        final server = _Server()..authorId = author;
        addTearDown(server.api.close);
        await expectLater(
          server.writePort.prepare(_request()),
          throwsA(_refused('notOwnNote')),
        );
        expect(server.mutations, 0);
      },
    );
  }

  for (final author in [
    'gid://evil/User/7',
    'gid://gitlab/User/7?other=7',
    'prefix-gid://gitlab/User/7',
    'gid://gitlab/Group/7',
  ]) {
    test(
      'malformed author $author never matches a numeric current user',
      () async {
        final server = _Server()..authorId = author;
        addTearDown(server.api.close);
        await expectLater(
          server.writePort.prepare(_request()),
          throwsA(
            author == 'gid://gitlab/Group/7'
                ? _refused('activityUnverifiable')
                : _failure(FailureKind.invalidResponse),
          ),
        );
        expect(server.mutations, 0);
      },
    );
  }

  test('missing note is refused, never a successful noop', () async {
    final server = _Server()..missing = true;
    addTearDown(server.api.close);
    await expectLater(
      server.writePort.prepare(_request()),
      throwsA(_refused('noteMissing')),
    );
    expect(server.mutations, 0);
  });

  test(
    'missing note during access is refused before minting a delete target',
    () async {
      final server = _Server();
      addTearDown(server.api.close);
      server.onAccess = (_) {
        server.missing = true;
      };
      await expectLater(
        server.writePort.prepare(_request()),
        throwsA(_refused('noteMissing')),
      );
      expect(server.mutations, 0);
    },
  );

  test('graph actor drift during dispatch refuses before hooks', () async {
    final server = _Server();
    addTearDown(server.api.close);
    final prepared = await server.writePort.prepare(_request());
    server.actorId = 'gid://gitlab/User/8';
    prepared.bindGraphBeforeMutation(() async {
      fail('Changed actor cannot reach B');
    });
    final outcome =
        await server.writePort.commit(prepared, mayStart: () => true)
            as port.AiWriteNotSent;
    expect(outcome.reasonCode, 'cancelled');
    expect(server.mutations, 0);
  });

  test(
    'initial GraphQL actor mismatch cannot delete another actor own note',
    () async {
      // Author and GraphQL actor agree on User/8, so the access-level
      // author==actor check passes; only the REST account binding
      // (user 7) refuses the delete.
      final server = _Server()
        ..authorId = 'gid://gitlab/User/8'
        ..actorId = 'gid://gitlab/User/8';
      addTearDown(server.api.close);
      Object? result;
      try {
        final prepared = await server.writePort.prepare(_request());
        prepared.bindGraphBeforeMutation(() async {});
        result = await server.writePort.commit(prepared, mayStart: () => true);
      } on Object catch (error) {
        result = error;
      }
      expect(
        server.mutations,
        0,
        reason:
            'REST user 7 must not authorize an actor-8 owned note even '
            'when the GraphQL actor equals the author',
      );
      expect(result, _refused('notOwnNote'));
    },
  );

  for (final drift in [
    'author',
    'body',
    'revision',
    'parent',
    'discussion',
    'missing',
    'parentAndMissing',
  ]) {
    test(
      'dispatch re-verifies $drift before hooks and refuses without sending',
      () async {
        final server = _Server();
        addTearDown(server.api.close);
        final prepared = await server.writePort.prepare(_request());
        switch (drift) {
          case 'author':
            server.authorId = 'gid://gitlab/User/8';
          case 'body':
            server.body = 'Changed note';
          case 'revision':
            server.updated = '2026-10-03T00:00:00Z';
          case 'parent':
            server.parentChanges = {'iid': '4'};
          case 'discussion':
            server.noteChanges = {
              'discussion': {
                'id': 'gid://gitlab/Discussion/foreign',
                'createdAt': _created,
              },
            };
          case 'missing':
            server.missing = true;
          case 'parentAndMissing':
            server.parentChanges = {'iid': '4'};
            server.missing = true;
        }
        var beforeCalls = 0;
        var acceptanceCalls = 0;
        prepared.bindGraphBeforeMutation(() async {
          beforeCalls++;
        });
        final outcome = await server.writePort.commit(
          prepared,
          mayStart: () {
            acceptanceCalls++;
            return true;
          },
        );
        expect(outcome, isA<port.AiWriteNotSent>());
        expect(
          (outcome as port.AiWriteNotSent).reasonCode,
          drift == 'missing' ? 'noteMissing' : 'noteChanged',
        );
        expect(outcome.mutationCount, 0);
        expect(server.mutations, 0);
        expect(beforeCalls, 0);
        expect(acceptanceCalls, 0);
      },
    );
  }

  for (final deny in ['permission', 'internal', 'system', 'foreignAccount']) {
    test('$deny refuses before acceptance', () async {
      final server = _Server();
      addTearDown(server.api.close);
      switch (deny) {
        case 'permission':
          server.canDelete = false;
        case 'internal':
          server.internal = true;
        case 'system':
          server.system = true;
        case 'foreignAccount':
          server.userId = 8;
      }
      await expectLater(
        server.writePort.prepare(_request()),
        throwsA(switch (deny) {
          'system' => _refused('activityUnverifiable'),
          'foreignAccount' => _failure(FailureKind.unauthenticated),
          _ => _failure(FailureKind.forbidden),
        }),
      );
      expect(server.mutations, 0);
    });
  }

  test(
    'truncated activity cannot prove absence or authorize deletion',
    () async {
      final server = _Server()..truncated = true;
      addTearDown(server.api.close);
      await expectLater(
        server.writePort.prepare(_request()),
        throwsA(_refused('activityUnverifiable')),
      );
      expect(server.logicalReads['MobileWorkItemActivity'], 2);
      expect(server.mutations, 0);
    },
  );

  for (final preset in [false, true]) {
    test(
      'unsupported controls ${preset ? 'pre-set' : 'detected'} refuse without AI legacy read',
      () async {
        final server = _Server()..unsupportedControls = true;
        addTearDown(server.api.close);
        if (preset) {
          final detail = await server.api.projectWorkItem(
            const Project(id: 9, name: _path, path: _path),
            3,
          );
          await server.api.workItemActivity(detail.summary);
        }
        final before = server.logicalReads['MobileWorkItemActivity'] ?? 0;
        await expectLater(
          server.writePort.prepare(_request()),
          throwsA(_failure(FailureKind.unsupported)),
        );
        expect(
          server.logicalReads['MobileWorkItemActivity'] ?? 0,
          before + (preset ? 0 : 1),
        );
        expect(server.mutations, 0);
      },
    );
  }

  for (final status in [400, 401, 403, 404, 409, 422, 429, 500]) {
    test('accepted HTTP $status is uncertain and never replayed', () async {
      final server = _Server()..mutationStatus = status;
      addTearDown(server.api.close);
      final outcome = await server.delete();
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(outcome.readbackVerified, isFalse);
      expect(outcome.mutationCount, 1);
      expect(server.mutations, 1);
    });
  }

  for (final errors in <Object?>[
    ['Synthetic rejected'],
    null,
    [7],
  ]) {
    test(
      'accepted malformed/non-empty payload errors $errors stay uncertain',
      () async {
        final server = _Server()..errors = errors;
        addTearDown(server.api.close);
        expect((await server.delete()).state, AiJournalState.writeUncertain);
        expect(server.mutations, 1);
      },
    );
  }

  for (final evidence in [
    'present',
    'omitted',
    'actor',
    'parent',
    'missingParent',
    '401',
  ]) {
    test('accepted readback $evidence cannot confirm deletion', () async {
      final server = _Server();
      addTearDown(server.api.close);
      final data = <String, Object?>{
        'currentUser': {'id': _actorId},
        'workItem': server.identity(),
        'note': null,
      };
      switch (evidence) {
        case 'present':
          data['note'] = server.note();
        case 'omitted':
          data.remove('note');
        case 'actor':
          data['currentUser'] = {'id': 'gid://gitlab/User/8'};
        case 'parent':
          data['workItem'] = {...server.identity(), 'iid': '4'};
        case 'missingParent':
          data['workItem'] = null;
        case '401':
          server.readbackStatus = 401;
      }
      server.readback = data;
      final outcome = await server.delete();
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(outcome.readbackVerified, isFalse);
      expect(server.mutations, 1);
    });
  }

  test(
    'awaited B precedes synchronous A; false A remains cancelled outside try',
    () async {
      final server = _Server();
      addTearDown(server.api.close);
      final prepared = await server.writePort.prepare(_request());
      final entered = Completer<void>();
      final release = Completer<void>();
      prepared.bindGraphBeforeMutation(() async {
        expect(server.logicalReads['MobileWorkItemActivityEditAccess'], 2);
        entered.complete();
        await release.future;
        server.events.add('B-complete');
      });
      final pending = server.writePort.commit(
        prepared,
        mayStart: () {
          server.events.add('A-false');
          return false;
        },
      );
      await entered.future.timeout(mr6b3Timeout);
      expect(server.mutations, 0);
      release.complete();
      final outcome = await pending as port.AiWriteNotSent;
      expect(outcome.reasonCode, 'cancelled');
      expect(outcome.mutationCount, 0);
      expect(server.events.skip(server.events.length - 2), [
        'B-complete',
        'A-false',
      ]);
      expect(server.mutations, 0);
    },
  );

  test('failed B propagates without A or a mutation', () async {
    final server = _Server();
    addTearDown(server.api.close);
    final prepared = await server.writePort.prepare(_request());
    prepared.bindGraphBeforeMutation(() async {
      throw StateError('synthetic flush');
    });
    await expectLater(
      server.writePort.commit(
        prepared,
        mayStart: () {
          fail('A must not follow a failed hook');
        },
      ),
      throwsStateError,
    );
    expect(server.mutations, 0);
  });

  for (final arguments in <Map<String, Object?>>[
    {'projectId': 9, 'iid': 3},
    {..._args, 'noteId': '401'},
    {..._args, 'noteId': 0},
    {..._args, 'body': '/merge'},
    {..._args, 'body': '[[upload:u-1]] [[attachment:att-1]]'},
    {..._args, 'provenance': <String, Object?>{}},
    {..._args, 'query': 'mutation injected'},
    {..._args, 'noteGid': _noteId},
    {..._args, 'expectedUpdatedAt': _updated},
  ]) {
    test('closed argument schema rejects $arguments before I/O', () async {
      final server = _Server();
      addTearDown(server.api.close);
      await expectLater(
        server.writePort.prepare(_request(arguments: arguments)),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(server.adapter.requests, isEmpty);
    });
  }

  for (final grants in <List<AiScopeGrant>>[
    [],
    [const AiScopeGrant(kind: AiScopeKind.groupWorkItem, groupId: 8, iid: 3)],
    [const AiScopeGrant(kind: AiScopeKind.accountGlobal)],
    [
      const AiScopeGrant(
        kind: AiScopeKind.workItem,
        projectId: 10,
        projectPath: 'team/other',
        iid: 3,
      ),
    ],
    [
      const AiScopeGrant(
        kind: AiScopeKind.workItem,
        projectId: 9,
        projectPath: _path,
        iid: 4,
      ),
    ],
  ]) {
    test('ungranted or group coordinates never reach I/O: $grants', () async {
      final server = _Server();
      addTearDown(server.api.close);
      await expectLater(
        server.writePort.prepare(
          _request(
            scope: AiWriteScope(accountKey: mr6b3Account, grants: grants),
          ),
        ),
        throwsA(_failure(FailureKind.forbidden)),
      );
      expect(server.adapter.requests, isEmpty);
    });
  }

  test(
    'T4 requires typed parent name and sends once under double approval',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      expect(proposal.tier.tier, AiWriteTier.t4);
      expect(proposal.tier.requiresTypedName, isTrue);
      expect(proposal.tier.typedName, '#3');
      final wrong = await h.coordinator.approve(proposal, typedName: '401');
      expect(wrong.reasonCode, 'typedNameMismatch');
      expect(h.server.mutations, 0);
      final outcomes = await Future.wait([
        h.approve(proposal),
        h.approve(proposal),
      ]);
      expect(
        outcomes.every((outcome) => outcome.state == AiJournalState.succeeded),
        isTrue,
      );
      expect(h.server.mutations, 1);
    },
  );

  for (final oauth in [false, true]) {
    test(
      '${oauth ? 'OAuth' : 'PAT'} independent traffic counter proves L14 and cap29',
      () async {
        final h = await _Harness.create(oauth: oauth);
        addTearDown(h.dispose);
        h.server.onMutation = () {
          expect(
            h.journal.entries(mr6b3Account).last.state,
            AiJournalState.dispatching,
          );
        };
        final outcome = await h.approve((await h.propose())!);
        expect(outcome.state, AiJournalState.succeeded);
        expect(h.server.logicalReads, {
          'freshness': 2,
          'user': 2,
          'MobileProjectWorkItem': 2,
          'MobileWorkItemActivity': 4,
          'MobileWorkItemActivityEditAccess': 3,
          'MobileWorkItemActivityDeleteReadback': 1,
        });
        expect(h.server.reads, 14);
        expect(h.server.httpReads, oauth ? 28 : 14);
        expect(h.server.refreshes, oauth ? 14 : 0);
        expect(h.server.mutations, 1);
        expect(h.budget.gitLabRequests, 29);
        expect(
          h.journal.entries(mr6b3Account).last.state,
          AiJournalState.succeeded,
        );
      },
    );
  }

  test('OAuth mutation401 refreshes without a second mutation', () async {
    final server = _Server(oauth: true)..mutationStatus = 401;
    addTearDown(server.api.close);
    final outcome = await server.delete();
    expect(outcome.state, AiJournalState.writeUncertain);
    expect(server.refreshes, 1);
    expect(server.mutations, 1);
  });

  for (final (allowance, oauth) in [
    (28, false),
    (29, false),
    (28, true),
    (29, true),
  ]) {
    test(
      'cap boundary allowance $allowance (OAuth:$oauth) is reserved before all reads',
      () async {
        final h = await _Harness.create(allowance: allowance, oauth: oauth);
        addTearDown(h.dispose);
        final proposal = await h.propose();
        if (allowance == 28) {
          expect(proposal, isNull);
          expect(
            h.coordinator.outcomeFor('p10-call')?.reasonCode,
            'httpBudgetExceeded',
          );
          expect(h.server.adapter.requests, isEmpty);
        } else {
          expect((await h.approve(proposal!)).state, AiJournalState.succeeded);
          expect(h.server.mutations, 1);
        }
      },
    );
  }

  for (final change in [
    'revision',
    'body',
    'author',
    'missing',
    'consent',
    'expiry',
  ]) {
    test('approval re-prepare rejects $change drift before mutation', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      switch (change) {
        case 'revision':
          h.server.revision = '2026-10-03T00:00:00Z';
        case 'body':
          h.server.body = 'Changed even with identical timestamp';
        case 'author':
          h.server.authorId = 'gid://gitlab/User/8';
        case 'missing':
          h.server.missing = true;
        case 'consent':
          h.policy.consentValid = false;
        case 'expiry':
          h.clock = h.clock.add(const Duration(minutes: 31));
      }
      final outcome = await h.approve(proposal);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.mutationCount, 0);
      expect(h.server.mutations, 0);
      if (change == 'revision' || change == 'body') {
        expect(outcome.reasonCode, 'targetChanged');
      }
    });
  }

  test('uncertain delete isolates the note and fail-stops the turn', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    h.server.errors = ['Synthetic rejected'];
    final outcome = await h.approve((await h.propose())!);
    expect(outcome.state, AiJournalState.writeUncertain);
    expect(
      h.journal.entries(mr6b3Account).last.state,
      AiJournalState.writeUncertain,
    );
    final before = h.server.adapter.requests.length;
    expect(await h.propose(id: 'p10-after-uncertain'), isNull);
    expect(h.server.adapter.requests, hasLength(before));
    h.coordinator.beginRun('Delete own note again.');
    h.coordinator.beginTurn();
    expect(await h.propose(id: 'p10-new-run'), isNull);
    expect(h.server.mutations, 1);
  });

  test('dispatch waits for durable dispatching flush before sending', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final proposal = (await h.propose())!;
    final barrier = h.files.armBarrier(writesBeforeBarrier: 1);
    final pending = h.approve(proposal);
    await barrier;
    expect(h.server.mutations, 0);
    expect(h.journal.entries(mr6b3Account).last.state, AiJournalState.prepared);
    h.files.releaseBarrier();
    expect((await pending).state, AiJournalState.succeeded);
    expect(h.server.mutations, 1);
  });

  test('failed dispatching flush never sends the note deletion', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final proposal = (await h.propose())!;
    h.files.failWriteNumber = h.files.writeCount + 2;
    final outcome = await h.approve(proposal);
    expect(outcome.state, AiJournalState.notExecuted);
    expect(outcome.mutationCount, 0);
    expect(h.server.mutations, 0);
  });

  test(
    'policy change after durable B makes A refuse and refunds the write count',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      final barrier = h.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final pending = h.approve(proposal);
      await barrier;
      h.policy.clientMayStart = false;
      h.files.releaseBarrier();
      final outcome = await pending;
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.mutationCount, 0);
      expect(h.server.mutations, 0);
      expect(
        h.journal.entries(mr6b3Account).last.state,
        AiJournalState.notExecuted,
      );
      expect(h.journal.conversationWriteCount(mr6b3Account, 'p10-delete'), 0);
    },
  );
}
