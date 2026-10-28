import 'release_policy_support.dart';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
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
import '../support/namespace_work_item_query.dart';
import 'mr6b2_support.dart' show VisibleProductionLedger;
import 'mr6b3_support.dart';
import 'mr6b3g_support.dart' show g0eIdentity;

const groupActivityEditStageOperations = <String>{
  'editGroupWorkItemActivityNote',
};

const _operation = 'editGroupWorkItemActivityNote';
const _scope = AiWriteScope(
  accountKey: mr6b3Account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.groupWorkItem,
      groupId: 7,
      groupFullPath: _path,
      iid: 3,
    ),
  ],
);
const _path = 'team/example-9';
const _workItem = 'gid://gitlab/WorkItem/31';
const _noteId = 'gid://gitlab/Note/401';
const _discussionId = 'gid://gitlab/Discussion/synthetic';
const _actorId = 'gid://gitlab/User/7';
const _created = '2026-10-01T01:02:03Z';
const _updated = '2026-10-01T01:03:04Z';
const _body = 'Synthetic own note\nSecond line\nThird line\nFourth line';
const _replacement = 'Edited synthetic note';
const _args = <String, Object?>{
  'groupId': 7,
  'iid': 3,
  'noteId': 401,
  'body': _replacement,
};

port.AiWriteRequest _request({
  Map<String, Object?> arguments = _args,
  AiWriteScope scope = _scope,
  String executionId = 'gp10e-edit-direct',
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
  _Server({this.oauth = false, this.withContext = true}) {
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
    writePort = port.GitLabAiWritePort(
      api,
      accountKey: mr6b3Account,
      sessionGeneration: withContext ? 7 : null,
      isCurrent: withContext ? () => live && generation == 7 : null,
    );
  }

  final bool oauth;
  final bool withContext;
  bool live = true;
  int generation = 7;
  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final port.GitLabAiWritePort writePort;
  String authorId = _actorId;
  String actorId = _actorId;
  int userId = 7;
  String body = _body;
  String expectedBody = _replacement;
  String? sentBody;
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
  bool replayReadback = false;
  bool notesContinuation = false;
  final omittedParentFields = <String>{};
  final omittedNoteFields = <String>{};
  Map<String, Object?> namespaceChanges = {};
  void Function(String kind, int count)? onRead;
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

  Map<String, Object?> identity() => <String, Object?>{
    'id': _workItem,
    'iid': '3',
    'project': null,
    'namespace': {'id': 'gid://gitlab/Group/7', 'fullPath': _path},
    ...parentChanges,
  }..removeWhere((key, _) => omittedParentFields.contains(key));

  Map<String, Object?> note() => <String, Object?>{
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
    'project': null,
    'discussion': {'id': _discussionId, 'createdAt': _created},
    'userPermissions': {'adminNote': canDelete},
    ...noteChanges,
  }..removeWhere((key, _) => omittedNoteFields.contains(key));

  Map<String, Object?> activity({required bool first}) {
    final empty = first && twoPages && !notesContinuation;
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
                        'nodes': [
                          if (notesContinuation)
                            {...note(), 'id': 'gid://gitlab/Note/402'}
                          else
                            note(),
                        ],
                        'pageInfo': _pageInfo(more: notesContinuation),
                      },
                    },
                ],
                'pageInfo': _pageInfo(
                  more: empty || (!notesContinuation && truncated),
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
      expect(query, startsWith('mutation MobileUpdateWorkItemActivityNote'));
      expect(variables, {
        'input': {'id': _noteId, 'body': expectedBody},
      });
      mutations++;
      events.add('mutation');
      onMutation?.call();
      sentBody = (variables!['input'] as Map)['body'] as String;
      body = sentBody!;
      updated = '2026-10-03T00:00:00Z';
      return jsonResponse({
        'data': {
          'updateNote': {'errors': errors, 'note': note()},
        },
      }, status: mutationStatus);
    }
    httpReads++;
    if ((replayReads ||
            (replayReadback &&
                query?.contains('MobileWorkItemActivityNoteReadback') ==
                    true)) &&
        !_awaitingReplay) {
      _awaitingReplay = true;
      return jsonResponse({}, status: 401);
    }
    _awaitingReplay = false;
    final String kind;
    if (request.uri.path.endsWith('/api/v4/user')) {
      kind = 'user';
    } else if (request.uri.path.endsWith('/api/v4/groups/7')) {
      kind = 'freshness';
    } else {
      expect(request.uri.path, '/gitlab/api/graphql');
      kind = RegExp(r'^query\s+(\w+)').firstMatch(query!)!.group(1)!;
    }
    logicalReads.update(kind, (count) => count + 1, ifAbsent: () => 1);
    events.add(kind);
    onRead?.call(kind, logicalReads[kind]!);
    switch (kind) {
      case 'user':
        return jsonResponse({'id': userId, 'username': 'synthetic'});
      case 'freshness':
        expect(request.uri.queryParameters, {'with_projects': 'false'});
        return jsonResponse({
          'id': 7,
          'full_path': _path,
          'visibility': 'private',
        });
      case 'MobileNamespaceWorkItem':
        expect(query, namespaceWorkItemQuery);
        expect(variables, {'path': _path, 'iid': '3'});
        return jsonResponse({
          'data': {
            'namespace': {
              'id': 'gid://gitlab/Group/7',
              'fullPath': _path,
              ...namespaceChanges,
              'workItem': {
                ...identity(),
                'title': 'Synthetic group task',
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
      case 'MobileWorkItemDiscussionNotes':
        expect(query, contains('project { id fullPath }'));
        expect(variables, {
          'workItemId': _workItem,
          'anchorNoteId': 'gid://gitlab/Note/402',
          'after': 'next-discussion',
        });
        return jsonResponse({
          'data': {
            'workItem': identity(),
            'anchor': {
              ...note(),
              'id': 'gid://gitlab/Note/402',
              'discussion': {
                'id': _discussionId,
                'replyId': 'gid://gitlab/IndividualNoteDiscussion/synthetic',
                'createdAt': _created,
                'notes': {
                  'nodes': [note()],
                  'pageInfo': _pageInfo(more: truncated, cursor: 'third-notes'),
                },
              },
            },
          },
        });
      case 'MobileWorkItemActivityEditAccess':
        onAccess?.call(logicalReads[kind]!);
        return jsonResponse({
          'data': {
            'currentUser': {'id': actorId},
            'workItem': identity(),
            'note': missing ? null : note(),
          },
        });
      case 'MobileWorkItemActivityNoteReadback':
        expect(variables, {'workItemId': _workItem, 'noteId': _noteId});
        return jsonResponse({
          'data':
              readback ??
              {
                'currentUser': {'id': actorId},
                'workItem': identity(),
                'note': note(),
              },
        }, status: readbackStatus);
      default:
        fail('Unexpected synthetic request: $kind');
    }
  }

  Future<port.AiWriteSettled> edit() async {
    final prepared = await writePort.prepare(_request());
    prepared.bindGraphBeforeMutation(() async {});
    return await writePort.commit(prepared, mayStart: () => true)
        as port.AiWriteSettled;
  }
}

final class _Harness {
  _Harness._(
    this.server,
    this.root,
    this.files,
    this.journal,
    this.budget,
    this.placeholders,
  );

  static Future<_Harness> create({
    bool oauth = false,
    int allowance = 40,
    Set<String> knownSecrets = const {},
    bool aiAttribution = false,
  }) async {
    final server = _Server(oauth: oauth);
    final root = Directory.systemTemp.createTempSync('gp10e-edit-');
    final files = Mr6b3JournalFiles(root);
    final journal = AiWriteJournal(
      keys: Mr6b3JournalKeyStore(),
      applicationSupport: root,
      files: files,
      processId: 'gp10e-edit',
    );
    await journal.recoverAfterAccountsLoaded([mr6b3Account]);
    await journal.ensureInitialized(mr6b3Account);
    final harness = _Harness._(
      server,
      root,
      files,
      journal,
      AiToolBudget(maxGitLabRequests: allowance),
      text.UploadPlaceholderTable(
        instance: server.api.instance,
        accountKey: mr6b3Account,
        conversationId: 'gp10e-edit',
      ),
    );
    harness.coordinator = PolicyAiWriteCoordinator(
      releasePolicy: fixtureReleasePolicy,
      snapshot: () => AiWritePolicySnapshot(
        appInForeground: true,
        scope: _scope,
        level: harness.policy.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'synthetic-consent',
        writePolicyRevision: harness.policy.revision,
        scopeRevision: 1,
        sessionGeneration: 7,
        ownerApi: server.api,
        currentResource: AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: 7,
          groupFullPath: _path,
          iid: 3,
        ),
        alive: harness.policy.alive,
        consentValid: harness.policy.consentValid,
        clientMayStart: harness.policy.clientMayStart,
        aiAttribution: aiAttribution,
      ),
      createPort: () => server.writePort,
      journal: journal,
      conversationId: 'gp10e-edit',
      budget: () => harness.budget,
      readFreshness: (_) async {
        final group = await server.api.group(7);
        expect(group['id'], 7);
        expect(group['full_path'], _path);
        return AiWriteFreshness(
          targetVisibility: 'private',
          visibilityUnreadable: true,
          sourceVisibilityUnreadable: false,
        );
      },
      placeholders: harness.placeholders,
      knownSecrets: () => knownSecrets,
      safeDisplay: (value) => value,
      ledger: const VisibleProductionLedger(),
      now: () => harness.clock,
    );
    harness.coordinator.beginRun('Edit my note 401 on #3 in $_path.');
    harness.coordinator.beginTurn();
    return harness;
  }

  final _Server server;
  final Directory root;
  final Mr6b3JournalFiles files;
  final AiWriteJournal journal;
  final AiToolBudget budget;
  final text.UploadPlaceholderTable placeholders;

  text.AiFieldProvenance noteField(int id, {int groupId = 7, int iid = 3}) =>
      text.AiFieldProvenance.groupWorkItem(
        identity: g0eIdentity(
          server.api,
          groupId: groupId,
          fullPath: _path,
          iid: iid,
          workItemGid: _workItem,
          readEpoch: server.api.captureGroupReadEpoch().readEpoch,
        ),
        completeValue: true,
        noteId: id,
      );
  final policy = Mr6b3Policy();
  DateTime clock = DateTime.utc(2026, 10, 23, 12);
  late final PolicyAiWriteCoordinator coordinator;

  Future<AiWriteProposal?> propose({
    String id = 'gp10e-edit-call',
    Map<String, Object?> arguments = _args,
  }) => coordinator.propose(
    AiToolCall(
      id: id,
      name: _operation,
      arguments: {...arguments, 'reason': 'Synthetic edit request'},
    ),
  );

  Future<AiWriteOutcome> approve(AiWriteProposal proposal) => coordinator
      .approve(proposal, typedName: '$_path#3')
      .timeout(mr6b3Timeout);

  Future<void> dispose() async {
    files.releaseBarrier();
    coordinator.stop('disposed');
    server.api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

void main() {
  setUp(() {
    aiGroupWorkItemWritesEnabledForTesting = true;
    addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
  });

  test(
    'edit row is visible T2 whole-field text with independently counted cap29',
    () {
      final row = productionAiLedger.find(_operation)!;
      expect(
        aiGroupActivityEditRows.map((row) => row.operationId).toSet(),
        groupActivityEditStageOperations,
      );
      expect(row.namedMethod, 'editWorkItemActivityNote');
      expect(row.scopeClass, AiScopeClass.groupWorkItem);
      expect(row.arguments.keys.toSet(), {'groupId', 'iid', 'noteId', 'body'});
      expect(row.arguments.values.every((arg) => arg.required), isTrue);
      expect(row.readback, isTrue);
      expect(row.baseTier, AiWriteTier.t2);
      expect(row.boundary, AiWriteBoundary.graph);
      expect(row.modelVisible, isTrue);
      expect(row.editableField, 'body');
      expect(row.arguments['body']!.text, AiTextRole.quickActionMarkdown);
      expect(row.arguments['body']!.writableField, 'note');
      const logicalReads = 2 * (1 + 1 + 1 + 2 + 1) + 1 + 1;
      expect(logicalReads, 14);
      expect(row.httpCap, 2 * logicalReads + 1);
      expect(aiWriteRequestAllowance(_operation, oauthReplay: false), 15);
    },
  );

  test('visible production row is not offered with gate override off', () {
    aiGroupWorkItemWritesEnabledForTesting = false;
    expect(aiGroupWorkItemWritesAreEnabled, isFalse);
    expect(
      fixtureAiLedger.modelVisible.map((row) => row.operationId),
      contains(_operation),
    );
    expect(toolsForScope(_scope, releasePolicy: fixtureReleasePolicy), isEmpty);
  });

  for (final context in ['missing', 'revoked', 'generation']) {
    test('$context trusted context refuses before any HTTP', () async {
      final server = _Server(withContext: context != 'missing');
      addTearDown(server.api.close);
      if (context == 'revoked') server.live = false;
      if (context == 'generation') server.generation++;
      await expectLater(
        server.writePort.prepare(_request()),
        throwsA(_refused('workItemUnverifiable')),
      );
      expect(server.adapter.requests, isEmpty);
    });
  }

  for (final phase in [
    'user',
    'MobileNamespaceWorkItem',
    'MobileWorkItemActivity',
    'MobileWorkItemActivityEditAccess',
    'MobileWorkItemDiscussionNotes',
  ]) {
    for (final change in ['session', 'epoch']) {
      test('$change invalidation during $phase stops opening', () async {
        final server = _Server()
          ..notesContinuation = phase == 'MobileWorkItemDiscussionNotes';
        addTearDown(server.api.close);
        server.onRead = (kind, _) {
          if (kind == phase) {
            if (change == 'session') {
              server.live = false;
            } else {
              server.api.clearReadCache();
            }
          }
        };
        await expectLater(
          server.writePort.prepare(_request()),
          throwsA(anyOf(isA<ApiFailure>(), isA<port.AiWriteRefused>())),
        );
        expect(server.events.last, phase);
        expect(server.mutations, 0);
      });
    }
  }

  for (final phase in [
    'MobileNamespaceWorkItem',
    'MobileWorkItemActivity',
    'MobileWorkItemActivityEditAccess',
    'MobileWorkItemDiscussionNotes',
    'MobileWorkItemActivityNoteReadback',
  ]) {
    for (final shape in [
      'missing project',
      'project descendant',
      'missing namespace',
      'foreign group',
      'wrong path',
      'same owner other iid',
      'wrong WI GID',
    ]) {
      test('$phase strictly refuses $shape owner evidence', () async {
        final server = _Server()
          ..notesContinuation = phase == 'MobileWorkItemDiscussionNotes';
        addTearDown(server.api.close);
        server.onRead = (kind, _) {
          if (kind != phase) return;
          switch (shape) {
            case 'missing project':
              server.omittedParentFields.add('project');
            case 'project descendant':
              server.parentChanges = {
                'project': {'id': 'gid://gitlab/Project/7', 'fullPath': _path},
              };
            case 'missing namespace':
              server.omittedParentFields.add('namespace');
            case 'foreign group':
              server.parentChanges = {
                'namespace': {'id': 'gid://gitlab/Group/8', 'fullPath': _path},
              };
            case 'wrong path':
              server.parentChanges = {
                'namespace': {
                  'id': 'gid://gitlab/Group/7',
                  'fullPath': 'team/other',
                },
              };
            case 'same owner other iid':
              server.parentChanges = {'iid': '4'};
            case 'wrong WI GID':
              server.parentChanges = {'id': 'gid://gitlab/Group/31'};
          }
        };
        if (phase == 'MobileWorkItemActivityNoteReadback') {
          expect((await server.edit()).state, AiJournalState.writeUncertain);
          expect(server.mutations, 1);
        } else {
          await expectLater(
            server.edit(),
            throwsA(anyOf(isA<ApiFailure>(), isA<port.AiWriteRefused>())),
          );
          expect(server.mutations, 0);
        }
      });
    }
  }

  for (final phase in [
    'MobileWorkItemActivityEditAccess',
    'MobileWorkItemActivityNoteReadback',
  ]) {
    test('$phase requires explicit project:null on the note', () async {
      final server = _Server();
      addTearDown(server.api.close);
      server.onRead = (kind, _) {
        if (kind == phase) server.omittedNoteFields.add('project');
      };
      if (phase == 'MobileWorkItemActivityNoteReadback') {
        expect((await server.edit()).state, AiJournalState.writeUncertain);
        expect(server.mutations, 1);
      } else {
        await expectLater(server.edit(), throwsA(_refused('noteChanged')));
        expect(server.mutations, 0);
      }
    });
  }

  for (final field in [
    'query',
    'variables',
    'path',
    'projectId',
    'expectedUpdatedAt',
    'confirmName',
    'workItemGid',
    'noteGid',
  ]) {
    test('unknown $field refuses before any HTTP', () async {
      final server = _Server();
      addTearDown(server.api.close);
      await expectLater(
        server.writePort.prepare(
          _request(arguments: {..._args, field: 'injected'}),
        ),
        throwsA(_failure(FailureKind.validation)),
      );
      expect(server.adapter.requests, isEmpty);
    });
  }

  for (final args in [
    {..._args, 'groupId': 8},
    {..._args, 'iid': 4},
  ]) {
    test('grant refuses sibling coordinates $args', () async {
      final server = _Server();
      addTearDown(server.api.close);
      await expectLater(
        server.writePort.prepare(_request(arguments: args)),
        throwsA(_refused('workItemUnverifiable')),
      );
      expect(server.logicalReads, {'user': 1});
      expect(server.mutations, 0);
    });
  }

  test('a project grant never authorizes a group note', () async {
    final server = _Server();
    addTearDown(server.api.close);
    await expectLater(
      server.writePort.prepare(_request(scope: mr6b3Scope)),
      throwsA(_refused('workItemUnverifiable')),
    );
    expect(server.mutations, 0);
  });

  test('locator shares two reads with the strict notes continuation', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    h.server.notesContinuation = true;
    final outcome = await h.approve((await h.propose())!);
    expect(outcome.state, AiJournalState.succeeded);
    expect(h.server.logicalReads['MobileWorkItemActivity'], 2);
    expect(h.server.logicalReads['MobileWorkItemDiscussionNotes'], 2);
    expect(h.server.reads, 14);
    expect(h.server.mutations, 1);
  });

  for (final notes in [false, true]) {
    test(
      'third ${notes ? 'notes' : 'activity'} page refuses within cap',
      () async {
        final server = _Server()
          ..notesContinuation = notes
          ..truncated = true;
        addTearDown(server.api.close);
        await expectLater(
          server.writePort.prepare(_request()),
          throwsA(_refused('activityUnverifiable')),
        );
        expect(server.reads, 4);
        expect(server.mutations, 0);
      },
    );
  }

  test('unsupported controls refuse without a legacy fallback', () async {
    final server = _Server()..unsupportedControls = true;
    addTearDown(server.api.close);
    await expectLater(
      server.writePort.prepare(_request()),
      throwsA(_failure(FailureKind.unsupported)),
    );
    expect(server.logicalReads['MobileWorkItemActivity'], 1);
    expect(server.mutations, 0);
  });

  test('cap minus one refuses before HTTP', () async {
    final h = await _Harness.create(allowance: 28);
    addTearDown(h.dispose);
    expect(await h.propose(), isNull);
    expect(h.server.adapter.requests, isEmpty);
    expect(h.server.mutations, 0);
  });

  test('cap is sufficient for proposal dispatch and strict readback', () async {
    final h = await _Harness.create(allowance: 29);
    addTearDown(h.dispose);
    expect(
      (await h.approve((await h.propose())!)).state,
      AiJournalState.succeeded,
    );
    expect(h.server.reads + h.server.mutations, 15);
    expect(h.budget.gitLabRequests, 29);
  });

  for (final drift in [
    'consent',
    'policy',
    'stop',
    'generation',
    'epoch',
    'client',
  ]) {
    test('$drift during dispatching flush prevents a mutation', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      final entered = h.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final pending = h.approve(proposal);
      await entered;
      // The dispatching file is flushed; memory publishes after write returns.
      expect(
        h.journal.entries(mr6b3Account).last.state,
        AiJournalState.prepared,
      );
      switch (drift) {
        case 'consent':
          h.policy.consentValid = false;
        case 'policy':
          h.policy.revision++;
        case 'stop':
          h.coordinator.stop();
        case 'generation':
          h.server.generation++;
        case 'epoch':
          h.server.api.clearReadCache();
        case 'client':
          h.server.api.close();
      }
      h.files.releaseBarrier();
      final outcome = await pending;
      expect(outcome.state, AiJournalState.notExecuted);
      expect(
        h.journal.entries(mr6b3Account).last.state,
        AiJournalState.notExecuted,
      );
      expect(h.journal.conversationWriteCount(mr6b3Account, 'gp10e-edit'), 0);
      expect(h.server.mutations, 0);
    });
  }

  test('old approval cannot revive after epoch change', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final proposal = (await h.propose())!;
    final reads = h.server.reads;
    h.server.api.clearReadCache();
    expect((await h.approve(proposal)).state, AiJournalState.notExecuted);
    expect(h.server.reads, reads);
    expect(h.server.mutations, 0);
  });

  test('post-send session loss stays uncertain without replay', () async {
    final server = _Server()..onMutation = null;
    addTearDown(server.api.close);
    server.onMutation = () => server.live = false;
    expect((await server.edit()).state, AiJournalState.writeUncertain);
    expect(server.mutations, 1);
    expect(server.logicalReads['MobileWorkItemActivityNoteReadback'], isNull);
  });

  test(
    'OAuth readback replay remains bound after the accepted epoch advance',
    () async {
      final h = await _Harness.create(oauth: true);
      addTearDown(h.dispose);
      h.server.replayReadback = true;
      expect(
        (await h.approve((await h.propose())!)).state,
        AiJournalState.succeeded,
      );
      expect(h.server.refreshes, 1);
      expect(h.server.reads, 14);
      expect(h.server.httpReads + h.server.mutations, 16);
      expect(h.server.mutations, 1);
    },
  );

  for (final foreign in ['group', 'iid']) {
    test(
      'placeholder for a different $foreign refuses before proposal',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        final masked = h.placeholders.redactOutgoing(
          'Keep ![screen](/uploads/abcdefabcdefabcdefabcdefabcdef01/screen.png)',
          field: h.noteField(
            401,
            groupId: foreign == 'group' ? 8 : 7,
            iid: foreign == 'iid' ? 4 : 3,
          ),
        );
        expect(await h.propose(arguments: {..._args, 'body': masked}), isNull);
        expect(
          h.coordinator.outcomeFor('gp10e-edit-call')!.reasonCode,
          text.AiTextBlockCode.rereadField,
        );
        expect(h.server.mutations, 0);
      },
    );
  }

  test('group note never substitutes a project attachment', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    expect(
      await h.propose(arguments: {..._args, 'body': '[[attachment:att-1]]'}),
      isNull,
    );
    expect(h.server.mutations, 0);
  });

  test(
    'fresh prepare carries original body, note identity and revision digest',
    () async {
      final server = _Server();
      addTearDown(server.api.close);
      final prepared = await server.writePort.prepare(_request());
      expect(prepared.currentFields, {'body': _body});
      expect(prepared.releaseName, '$_path#3');
      expect(prepared.confirmName, '$_path#3');
      expect(prepared.groupIdentity!.apiOwner, same(server.api));
      expect(prepared.groupIdentity!.generation, 7);
      expect(prepared.hasCurrentGroupIdentity, isTrue);
      expect(prepared.writeKeys.single.parts, [
        mr6b3Account,
        'group:7',
        'workItem',
        '3',
        'notes',
        '401',
      ]);
      expect(prepared.dependencyKeys.single.parts, [
        mr6b3Account,
        'group:7',
        'workItem',
        '3',
      ]);
      expect(prepared.bindingTargets.single.side, AiResourceSide.group);
      expect(prepared.bindingTargets.single.groupId, 7);
      expect(prepared.bindingTargets.single.workItemGid, _workItem);
      expect(prepared.bindingTargets.single.noteId, 401);
      expect(prepared.bindingTargets.single.parentIid, 3);
      expect(prepared.bindingDigest, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(
        prepared.journal.updatedAt,
        DateTime.parse(_updated).toIso8601String(),
      );
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
      expect(outcome.readbackVerified, isTrue);
      expect(server.events.skip(server.events.length - 4), [
        'B',
        'A',
        'mutation',
        'MobileWorkItemActivityNoteReadback',
      ]);
      expect(server.mutations, 1);
      expect(
        await server.writePort.commit(prepared, mayStart: () => true),
        isA<port.AiWriteNotSent>(),
      );
    },
  );

  for (final author in ['gid://gitlab/User/8', 'gid://gitlab/User/17']) {
    test(
      'admin permission does not authorize another author: $author',
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

  test(
    'GraphQL actor mismatch refuses despite REST account author match',
    () async {
      final server = _Server()..actorId = 'gid://gitlab/User/8';
      addTearDown(server.api.close);
      await expectLater(
        server.writePort.prepare(_request()),
        throwsA(_refused('notOwnNote')),
      );
      expect(server.mutations, 0);
    },
  );

  for (final drift in ['author', 'body', 'revision', 'parent', 'missing']) {
    test('dispatch rechecks $drift before either hook', () async {
      final server = _Server();
      addTearDown(server.api.close);
      final prepared = await server.writePort.prepare(_request());
      switch (drift) {
        case 'author':
          server.authorId = 'gid://gitlab/User/8';
        case 'body':
          server.body = 'Different current note';
        case 'revision':
          server.updated = '2026-10-04T00:00:00Z';
        case 'parent':
          server.parentChanges = {'iid': '4'};
        case 'missing':
          server.missing = true;
      }
      prepared.bindGraphBeforeMutation(
        () async => fail('drift cannot reach B'),
      );
      final outcome =
          await server.writePort.commit(
                prepared,
                mayStart: () => fail('drift cannot reach A'),
              )
              as port.AiWriteNotSent;
      expect(
        outcome.reasonCode,
        drift == 'missing' ? 'noteMissing' : 'noteChanged',
      );
      expect(server.mutations, 0);
    });
  }

  test('noop never invokes either hook and is single-use', () async {
    final server = _Server()..body = _replacement;
    addTearDown(server.api.close);
    final prepared = await server.writePort.prepare(_request());
    prepared.bindGraphBeforeMutation(() async => fail('noop cannot reach B'));
    expect(
      await server.writePort.commit(
        prepared,
        mayStart: () => fail('noop cannot reach A'),
      ),
      isA<port.AiGraphNoChange>(),
    );
    expect(server.mutations, 0);
  });

  test(
    'awaited hook finishes before cancellation fence and no transport',
    () async {
      final server = _Server();
      addTearDown(server.api.close);
      final prepared = await server.writePort.prepare(_request());
      final entered = Completer<void>();
      final release = Completer<void>();
      prepared.bindGraphBeforeMutation(() async {
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
      expect((await pending as port.AiWriteNotSent).reasonCode, 'cancelled');
      expect(server.events.skip(server.events.length - 2), [
        'B-complete',
        'A-false',
      ]);
    },
  );

  test(
    'failed journal hook propagates without acceptance or mutation',
    () async {
      final server = _Server();
      addTearDown(server.api.close);
      final prepared = await server.writePort.prepare(_request());
      prepared.bindGraphBeforeMutation(
        () async => throw StateError('synthetic flush'),
      );
      await expectLater(
        server.writePort.commit(
          prepared,
          mayStart: () => fail('failed B cannot reach A'),
        ),
        throwsStateError,
      );
      expect(server.mutations, 0);
    },
  );

  for (final status in [400, 401, 403, 409, 422, 429, 500]) {
    test('accepted HTTP $status is uncertain and not replayed', () async {
      final server = _Server()..mutationStatus = status;
      addTearDown(server.api.close);
      expect((await server.edit()).state, AiJournalState.writeUncertain);
      expect(server.mutations, 1);
    });
  }

  test(
    'independent readback failure is uncertain after one mutation',
    () async {
      final server = _Server()..readbackStatus = 401;
      addTearDown(server.api.close);
      expect((await server.edit()).state, AiJournalState.writeUncertain);
      expect(server.mutations, 1);
    },
  );

  test('PAT measures L14 under the worst group locator path', () async {
    final h = await _Harness.create();
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
      'MobileNamespaceWorkItem': 2,
      'MobileWorkItemActivity': 4,
      'MobileWorkItemActivityEditAccess': 3,
      'MobileWorkItemActivityNoteReadback': 1,
    });
    expect(h.server.reads, 14);
    expect(h.server.httpReads, 14);
    expect(h.server.refreshes, 0);
    expect(h.server.mutations, 1);
    expect(h.budget.gitLabRequests, 29);
    expect(
      h.journal.entries(mr6b3Account).last.state,
      AiJournalState.succeeded,
    );
  });

  test(
    'OAuth replay after context capture refuses an obsolete epoch',
    () async {
      final h = await _Harness.create(oauth: true);
      addTearDown(h.dispose);
      h.server.replayReads = true;
      expect(await h.propose(), isNull);
      expect(
        h.coordinator.outcomeFor('gp10e-edit-call')!.reasonCode,
        'workItemUnverifiable',
      );
      expect(h.server.httpReads, 4);
      expect(h.server.refreshes, 2);
      expect(h.server.mutations, 0);
      expect(h.server.httpReads, lessThanOrEqualTo(29));
    },
  );

  for (final drift in ['revision', 'body', 'author']) {
    test('approval reprepare rejects $drift without a write', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      switch (drift) {
        case 'revision':
          h.server.revision = '2026-10-04T00:00:00Z';
        case 'body':
          h.server.body = 'Body drift without timestamp';
        case 'author':
          h.server.authorId = 'gid://gitlab/User/8';
      }
      final outcome = await h.approve(proposal);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, 'targetChanged');
      expect(h.server.mutations, 0);
    });
  }

  test('coordinator noop settles without dispatching or mutation', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    h.server.body = _replacement;
    final outcome = await h.approve((await h.propose())!);
    expect(outcome.state, AiJournalState.succeeded);
    expect(outcome.noChange, isTrue);
    expect(
      h.journal.entries(mr6b3Account).last.state,
      AiJournalState.notExecuted,
    );
    expect(h.server.mutations, 0);
  });

  test('durable prepared and dispatching flush precede mutation', () async {
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
  });

  test(
    'failed dispatching flush never sends and settles notExecuted',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      h.files.failWriteNumber = h.files.writeCount + 2;
      expect((await h.approve(proposal)).state, AiJournalState.notExecuted);
      expect(h.server.mutations, 0);
    },
  );

  test(
    'accepted failed mutation persists writeUncertain and fail-stops',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      h.server.errors = ['Synthetic failure'];
      expect(
        (await h.approve((await h.propose())!)).state,
        AiJournalState.writeUncertain,
      );
      expect(
        h.journal.entries(mr6b3Account).last.state,
        AiJournalState.writeUncertain,
      );
      expect(await h.propose(id: 'after-uncertain'), isNull);
      expect(h.server.mutations, 1);
    },
  );

  test('closed argument schema refuses arbitrary query before I/O', () async {
    final server = _Server();
    addTearDown(server.api.close);
    await expectLater(
      server.writePort.prepare(
        _request(arguments: {..._args, 'query': 'mutation injected'}),
      ),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(server.adapter.requests, isEmpty);
  });
  for (final level in AiAutonomyLevel.values.where(
    (value) => value != AiAutonomyLevel.readOnly,
  )) {
    test(
      'fresh own note hidden-span removal fixes confirmation at $level',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        h.policy.level = level;
        h.server.body =
            'Original ![screen](/uploads/abcdefabcdefabcdefabcdefabcdef01/screen.png)';
        final proposal = (await h.propose())!;
        expect(
          proposal.tier.reasons,
          contains(AiFixedConfirmReason.wholeFieldDropsHiddenSpans),
        );
        expect(proposal.tier.decision, AiGateDecision.requireApproval);
        expect(h.server.mutations, 0);
        expect((await h.approve(proposal)).state, AiJournalState.succeeded);
        expect(h.server.sentBody, _replacement);
      },
    );
  }

  test(
    'placeholder issued for a different note is refused before proposal',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final masked = h.placeholders.redactOutgoing(
        'Keep ![screen](/uploads/abcdefabcdefabcdefabcdefabcdef01/screen.png)',
        field: h.noteField(402),
      );
      expect(masked, contains('[[upload:u-'));
      expect(await h.propose(arguments: {..._args, 'body': masked}), isNull);
      expect(
        h.coordinator.outcomeFor('gp10e-edit-call')!.reasonCode,
        text.AiTextBlockCode.rereadField,
      );
      expect(h.server.mutations, 0);
    },
  );

  test(
    'same-note placeholder restores into actual sanitized transport and card preview',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      const stored =
          'Keep ![screen](/uploads/abcdefabcdefabcdefabcdefabcdef01/screen.png)';
      final masked = h.placeholders.redactOutgoing(
        stored,
        field: h.noteField(401),
      );
      final desired = '$masked and edited';
      h.server.body = stored;
      h.server.expectedBody = '$stored and edited';
      final proposal = (await h.propose(
        arguments: {..._args, 'body': desired},
      ))!;
      expect(
        (proposal.preview as port.AiFieldsPreview).fields['body'],
        h.server.expectedBody,
      );
      expect((await h.approve(proposal)).state, AiJournalState.succeeded);
      expect(h.server.sentBody, h.server.expectedBody);
      expect(h.server.sentBody, isNot(contains('[[upload:')));
    },
  );

  test(
    'identical edits preserve same-note placeholders until plain approval',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      const stored =
          'Keep ![screen](/uploads/abcdefabcdefabcdefabcdefabcdef01/screen.png)';
      final masked = h.placeholders.redactOutgoing(
        stored,
        field: h.noteField(401),
      );
      h.server.body = stored;
      h.server.expectedBody = '$stored user edit';
      final proposal = (await h.propose())!;
      final requests = h.server.adapter.requests.length;
      for (var attempt = 0; attempt < 2; attempt++) {
        final editing = await h.coordinator.approve(
          proposal,
          editedText: '$masked user edit',
        );
        expect(editing.state, AiJournalState.notExecuted);
        expect(editing.reasonCode, 'approvalRequired');
        expect(proposal.valid, isTrue);
        expect(proposal.editedText, '$masked user edit');
        expect(h.server.adapter.requests, hasLength(requests));
        expect(h.server.mutations, 0);
        expect(h.journal.entries(mr6b3Account), isEmpty);
      }
      expect(
        (proposal.preview as port.AiFieldsPreview).fields['body'],
        h.server.expectedBody,
      );
      final outcome = await h.approve(proposal);
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.readbackConfirmed, isTrue);
      expect(h.server.sentBody, h.server.expectedBody);
      expect(h.server.mutations, 1);
      expect(h.server.logicalReads['MobileWorkItemActivityNoteReadback'], 1);
      expect(proposal.editedText, isNull);
      expect((await h.approve(proposal)).state, AiJournalState.succeeded);
      expect(h.server.mutations, 1);
    },
  );

  for (final failure in ['mutation 422', 'readback 500']) {
    test('edited note stays after $failure without replay', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      const edited = 'Updated @all note';
      final requests = h.server.adapter.requests.length;
      expect(
        (await h.coordinator.approve(proposal, editedText: edited)).reasonCode,
        'approvalRequired',
      );
      expect(h.server.adapter.requests, hasLength(requests));
      expect(h.server.mutations, 0);
      final shown =
          (proposal.preview as port.AiFieldsPreview).fields['body']! as String;
      expect(shown, isNot(edited));
      h.server.expectedBody = shown;
      if (failure == 'mutation 422') {
        h.server.mutationStatus = 422;
      } else {
        h.server.readbackStatus = 500;
      }
      // D2: errors after GraphQL acceptance remain uncertain, including 4xx.
      final outcome = await h.approve(proposal);
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(outcome.readbackConfirmed, isFalse);
      expect(h.server.sentBody, shown);
      expect(h.server.mutations, 1);
      expect(proposal.editedText, edited);
      expect(h.coordinator.settledEdits, [proposal]);
      expect((await h.approve(proposal)).state, AiJournalState.writeUncertain);
      expect(h.server.mutations, 1);
    });
  }

  for (final drift in ['revision', 'body', 'author username', 'author ID']) {
    test('edited note still rejects target $drift drift', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      const edited = 'New user words';
      expect(
        (await h.coordinator.approve(proposal, editedText: edited)).reasonCode,
        'approvalRequired',
      );
      switch (drift) {
        case 'revision':
          h.server.revision = '2026-10-04T00:00:00Z';
        case 'body':
          h.server.body = 'Concurrent server edit';
        case 'author username':
          h.server.noteChanges = {
            'author': {
              'id': _actorId,
              'name': 'Synthetic author',
              'username': 'renamed',
            },
          };
        case 'author ID':
          h.server.authorId = 'gid://gitlab/User/8';
      }
      final outcome = await h.approve(proposal);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, 'targetChanged');
      expect(h.server.mutations, 0);
      expect(proposal.editedText, edited);
    });
  }

  for (final (name, body) in [
    ('empty', ''),
    ('indented quick action', ' /close\nKeep this note'),
    ('column-zero quick action', '/merge'),
    ('later-line quick action', 'a\n/merge'),
    ('CRLF quick action', 'a\r\n/approve'),
    ('mixed-CR quick action', 'a\n\r/move x/y'),
  ]) {
    test(
      '$name edit is refused without changing the preview or writing',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        final proposal = (await h.propose())!;
        final originalPreview =
            (proposal.preview as port.AiFieldsPreview).fields;
        final originalDigest = proposal.payloadDigest;
        final requests = h.server.adapter.requests.length;

        for (var attempt = 0; attempt < 2; attempt++) {
          final edited = await h.coordinator.approve(
            proposal,
            editedText: body,
          );
          expect(edited.state, AiJournalState.notExecuted);
          expect(
            edited.reasonCode,
            body.isEmpty ? 'validation' : 'quickAction',
          );
          expect(proposal.valid, isTrue);
          expect(proposal.editedText, body);
          expect(
            (proposal.preview as port.AiFieldsPreview).fields,
            originalPreview,
          );
          expect(proposal.payloadDigest, originalDigest);
          expect(h.server.adapter.requests, hasLength(requests));
          expect(h.server.mutations, 0);
          expect(h.journal.entries(mr6b3Account), isEmpty);
        }

        final repeated = await h.approve(proposal);
        expect(repeated.state, AiJournalState.notExecuted);
        expect(
          repeated.reasonCode,
          body.isEmpty ? 'validation' : 'quickAction',
        );
        expect(h.server.adapter.requests, hasLength(requests));
        expect(h.server.mutations, 0);
        expect(h.journal.entries(mr6b3Account), isEmpty);
      },
    );
  }

  for (final (name, body) in [
    ('empty', ''),
    ('indented quick action', ' /close\nKeep this note'),
    ('column-zero quick action', '/close\nKeep this note'),
    ('later-line quick action', 'a\n/merge'),
    ('CRLF quick action', 'a\r\n/approve'),
    ('mixed-CR quick action', 'a\n\r/move x/y'),
  ]) {
    test('$name is refused before a proposal or mutation', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      expect(await h.propose(arguments: {..._args, 'body': body}), isNull);
      final outcome = h.coordinator.outcomeFor('gp10e-edit-call')!;
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, body.isEmpty ? 'validation' : 'quickAction');
      expect(outcome.mutationCount, 0);
      expect(h.server.mutations, 0);
      expect(h.journal.conversationWriteCount(mr6b3Account, 'gp10e-edit'), 0);
    });
  }

  for (final (name, body) in [
    ('empty', ''),
    ('indented quick action', ' /close'),
    ('byte limit', 'é' * (1024 * 1024 + 1)),
    ('line limit', 'x\n' * GitLabApi.maxTextLines),
  ]) {
    test('$name is refused by the port before HTTP', () async {
      final server = _Server();
      addTearDown(server.api.close);
      await expectLater(
        server.writePort.prepare(_request(arguments: {..._args, 'body': body})),
        throwsA(
          name == 'indented quick action'
              ? _refused('quickAction')
              : _failure(FailureKind.validation),
        ),
      );
      expect(server.adapter.requests, isEmpty);
      expect(server.mutations, 0);
    });
  }

  for (final (raw, normalized) in [
    ('/merge', ' /merge'),
    ('a\n/merge', 'a\n /merge'),
    ('a\r\n/approve', 'a\n /approve'),
    ('a\n\r/move x/y', 'a\n /move x/y'),
  ]) {
    test(
      'fenced note edit sends the exact prepared preview: ${raw.replaceAll('\n', r'\n').replaceAll('\r', r'\r')}',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        final proposal = (await h.propose(
          arguments: {..._args, 'body': '```text\n$raw\n```'},
        ))!;
        final shown = proposal.fields['body']!;
        expect(shown, '```text\n$normalized\n```');
        h.server.expectedBody = shown;
        final outcome = await h.approve(proposal);
        expect(
          outcome.state,
          AiJournalState.succeeded,
          reason: outcome.reasonCode,
        );
        expect(RegExp(r'(^|[\r\n])/').hasMatch(shown), isFalse);
        expect(h.server.sentBody, shown);
        expect(h.server.mutations, 1);
      },
    );
  }

  test(
    'attribution that exceeds the line limit is refused before a card',
    () async {
      final h = await _Harness.create(aiAttribution: true);
      addTearDown(h.dispose);
      final body = '${'x\n' * (GitLabApi.maxTextLines - 1)}x';
      expect(isValidWorkItemActivityEditBody(body), isTrue);
      expect(await h.propose(arguments: {..._args, 'body': body}), isNull);
      final outcome = h.coordinator.outcomeFor('gp10e-edit-call')!;
      expect(outcome.reasonCode, 'validation');
      expect(outcome.state, AiJournalState.notExecuted);
      expect(h.server.mutations, 0);
    },
  );
}
