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

const _operation = 'editWorkItemActivityNote';
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
  'projectId': 9,
  'iid': 3,
  'noteId': 401,
  'body': _replacement,
};

port.AiWriteRequest _request({
  Map<String, Object?> arguments = _args,
  AiWriteScope scope = mr6b3Scope,
  String executionId = 'p10-edit-direct',
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
  }) async {
    final server = _Server(oauth: oauth)..replayReads = oauth;
    final root = Directory.systemTemp.createTempSync('p10-edit-');
    final files = Mr6b3JournalFiles(root);
    final journal = AiWriteJournal(
      keys: Mr6b3JournalKeyStore(),
      applicationSupport: root,
      files: files,
      processId: 'p10-edit',
    );
    await journal.recoverAfterAccountsLoaded([mr6b3Account]);
    await journal.ensureInitialized(mr6b3Account);
    final harness = _Harness._(
      server,
      root,
      files,
      journal,
      AiToolBudget(maxGitLabRequests: allowance),
      text.UploadPlaceholderTable(instance: server.api.instance),
    );
    harness.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
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
      conversationId: 'p10-edit',
      budget: () => harness.budget,
      readFreshness: (_) async {
        final project = await server.api.record(['projects', '9']);
        expect(project['id'], 9);
        return AiWriteFreshness(
          visibilityUnreadable: false,
          provenance: {'body': harness.noteField(401)},
        );
      },
      placeholders: harness.placeholders,
      knownSecrets: () => knownSecrets,
      safeDisplay: (value) => value,
      ledger: productionAiLedger,
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

  text.AiFieldProvenance noteField(int id) => text.AiFieldProvenance.gitLab(
    instance: server.api.instance,
    projectId: 9,
    projectPath: _path,
    resource: 'issues',
    iid: 3,
    noteId: id,
  );
  final policy = Mr6b3Policy();
  DateTime clock = DateTime.utc(2026, 10, 23, 12);
  late final PolicyAiWriteCoordinator coordinator;

  Future<AiWriteProposal?> propose({
    String id = 'p10-edit-call',
    Map<String, Object?> arguments = _args,
  }) => coordinator.propose(
    AiToolCall(
      id: id,
      name: _operation,
      arguments: {...arguments, 'reason': 'Synthetic edit request'},
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
    'edit row is visible T2 whole-field text with independently counted cap29',
    () {
      final row = productionAiLedger.find(_operation)!;
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

  test(
    'fresh prepare carries original body, note identity and revision digest',
    () async {
      final server = _Server();
      addTearDown(server.api.close);
      final prepared = await server.writePort.prepare(_request());
      expect(prepared.currentFields, {'body': _body});
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

  for (final oauth in [false, true]) {
    test(
      '${oauth ? 'OAuth' : 'PAT'} measures L14 under the worst locator path',
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
          'MobileWorkItemActivityNoteReadback': 1,
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
      expect(
        outcome.reasonCode,
        drift == 'author' ? 'notOwnNote' : 'targetChanged',
      );
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
      expect(masked, contains('[[upload:u-1]]'));
      expect(await h.propose(arguments: {..._args, 'body': masked}), isNull);
      expect(
        h.coordinator.outcomeFor('p10-edit-call')!.reasonCode,
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
    'editedText reapproval restores only same-note placeholder and binds processed payload',
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
      final editing = await h.coordinator.approve(
        proposal,
        editedText: '$masked user edit',
      );
      expect(editing.reasonCode, 'approvalRequired');
      expect(h.server.mutations, 0);
      expect(
        (proposal.preview as port.AiFieldsPreview).fields['body'],
        h.server.expectedBody,
      );
      expect((await h.approve(proposal)).state, AiJournalState.succeeded);
      expect(h.server.sentBody, h.server.expectedBody);
    },
  );
  test(
    'col0 slash is neutralized in card but conservative core refuses before dispatch',
    () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      const raw = '/close\nKeep this note';
      final proposal = (await h.propose(arguments: {..._args, 'body': raw}))!;
      expect(
        (proposal.preview as port.AiFieldsPreview).fields['body'],
        ' /close\nKeep this note',
      );
      expect(h.server.mutations, 0);
      h.server.onMutation = () => fail('core must refuse before transport');
      final outcome = await h.approve(proposal);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, 'validation');
      expect(outcome.mutationCount, 0);
      expect(h.server.mutations, 0);
      expect(
        h.journal.entries(mr6b3Account).last.state,
        AiJournalState.notExecuted,
      );
      expect(h.journal.conversationWriteCount(mr6b3Account, 'p10-edit'), 0);
    },
  );
}
