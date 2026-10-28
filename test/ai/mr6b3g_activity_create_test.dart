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
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import 'mr6b3_support.dart';
import 'mr6b3g_support.dart';

const groupActivityCreateStageOperations = <String>{
  'createGroupWorkItemActivityComment',
  'createGroupWorkItemActivityReply',
};
const _comment = 'createGroupWorkItemActivityComment';
const _reply = 'createGroupWorkItemActivityReply';
const _workItem = 'gid://gitlab/WorkItem/91';
const _anchor = 'gid://gitlab/Note/401';
const _discussion = 'gid://gitlab/Discussion/server-owned';
const _replyId = 'gid://gitlab/IndividualNoteDiscussion/server-owned';
const _created = 'gid://gitlab/DiscussionNote/501';
const _body = 'Synthetic **group activity** note';
final _instance = GitLabInstance.parse('https://example.com/gitlab');
const _revision = '2026-10-23T00:00:00Z';
const _root = AiConflictKey([g0eAccount, 'group:7', 'workItem', '5']);
const _notes = AiConflictKey([g0eAccount, 'group:7', 'workItem', '5', 'notes']);

Matcher _refused(String reason) => throwsA(
  isA<port.AiWriteRefused>().having((e) => e.reason, 'reason', reason),
);

Map<String, Object?> _identity() => {
  'id': _workItem,
  'iid': '5',
  'project': null,
  'namespace': {'id': 'gid://gitlab/Group/7', 'fullPath': g0ePath},
};

Map<String, Object?> _page({bool next = false, String? cursor}) => {
  'hasNextPage': next,
  'endCursor': cursor,
};

Map<String, Object?> _note({String id = _anchor, String body = 'Anchor'}) => {
  'id': id,
  'body': body,
  'system': false,
  'systemNoteIconName': null,
  'createdAt': '2026-10-01T01:02:03Z',
  'updatedAt': '2026-10-01T01:03:04Z',
  'author': {
    'id': 'gid://gitlab/User/7',
    'name': 'Synthetic User',
    'username': 'tester',
  },
};

Map<String, Object?> _thread({
  String id = _discussion,
  String replyId = _replyId,
  List<Object?>? notes,
  bool next = false,
}) => {
  'id': id,
  'replyId': replyId,
  'createdAt': '2026-10-01T01:00:00Z',
  'notes': {
    'nodes': notes ?? [_note()],
    'pageInfo': _page(next: next, cursor: next ? 'notes-2' : null),
  },
};

Map<String, Object?> _writeNote({String id = _created, String body = _body}) =>
    {
      ..._note(id: id, body: body),
      'project': null,
      'internal': false,
      'noteableType': 'Issue',
      'noteableId': 91,
      'discussion': {
        'id': _discussion,
        'replyId': _replyId,
        'createdAt': '2026-10-01T01:00:00Z',
      },
    };

Map<String, Object?> _map(Object? value) => value! as Map<String, Object?>;

final class _Server {
  final counts = <String, int>{};
  final inputs = <Map<String, Object?>>[];
  String paging = 'none';
  String revision = _revision;
  String? failPhase;
  int failStatus = 500;
  bool controls = true;
  bool locked = false;
  bool allowed = true;
  int actor = 7;
  int accessSinceNamespace = 0;
  String? sentBody;
  void Function(String phase, Map<String, Object?> data)? change;
  void Function(String phase)? afterRead;
  void Function()? onMutation;

  ResponseBody respond(RequestOptions request) {
    String phase;
    Map<String, Object?> data;
    if (request.method == 'GET') {
      if (request.uri.path.endsWith('/api/v4/user')) {
        phase = 'user';
        data = {'id': actor, 'username': 'tester'};
      } else {
        expect(request.uri.path, '/gitlab/api/v4/groups/7');
        expect(request.uri.queryParameters, {'with_projects': 'false'});
        phase = 'freshness';
        data = {'id': 7, 'full_path': g0ePath, 'visibility': 'private'};
      }
      counts.update(phase, (n) => n + 1, ifAbsent: () => 1);
      change?.call(phase, data);
      afterRead?.call(phase);
      return jsonResponse(data, status: failPhase == phase ? failStatus : 200);
    }
    expect(request.method, 'POST');
    expect(request.uri.path, '/gitlab/api/graphql');
    final payload = _map(request.data);
    final query = payload['query']! as String;
    final variables = _map(payload['variables']);
    if (query.startsWith('query MobileNamespaceWorkItem')) {
      expect(query, namespaceWorkItemQuery);
      expect(variables, {'path': g0ePath, 'iid': '5'});
      phase = 'namespace';
      accessSinceNamespace = 0;
      data = {
        'namespace': {
          'id': 'gid://gitlab/Group/7',
          'fullPath': g0ePath,
          'workItem': {
            ..._identity(),
            'title': 'Group item',
            'state': 'OPEN',
            'createdAt': '2026-10-01T00:00:00Z',
            'updatedAt': revision,
            'description': 'Synthetic description',
            'workItemType': {
              'id': 'gid://gitlab/WorkItems::Type/1',
              'name': 'Task',
            },
            'widgets': <Object?>[],
          },
        },
      };
    } else if (query.startsWith('query MobileWorkItemActivity(') ||
        query.startsWith('query MobileWorkItemActivityNext')) {
      phase = variables['after'] == null ? 'activity' : 'activityNext';
      expect(query, isNot(contains('Legacy')));
      data = {
        'workItem': {
          ..._identity(),
          'widgets': [
            {
              'type': 'NOTES',
              'discussionLocked': locked,
              'discussions': {
                'nodes': paging == 'outer' && phase == 'activity'
                    ? <Object?>[]
                    : paging == 'third' && phase == 'activityNext'
                    ? [
                        _thread(
                          id: 'gid://gitlab/Discussion/second',
                          replyId: 'gid://gitlab/Discussion/second',
                          notes: [_note(id: 'gid://gitlab/Note/400')],
                        ),
                      ]
                    : [
                        _thread(
                          notes: paging == 'nested'
                              ? [_note(id: 'gid://gitlab/Note/400')]
                              : null,
                          next: paging == 'nested',
                        ),
                      ],
                'pageInfo': _page(
                  next:
                      paging == 'third' ||
                      (paging == 'outer' && phase == 'activity'),
                  cursor: phase == 'activity' ? 'outer-2' : 'outer-3',
                ),
              },
            },
          ],
        },
      };
    } else if (query.startsWith('query MobileWorkItemDiscussionNotes')) {
      phase = 'notesNext';
      data = {
        'workItem': _identity(),
        'anchor': {
          ..._writeNote(id: 'gid://gitlab/Note/400', body: 'First'),
          'discussion': _thread(),
        },
      };
    } else if (query.startsWith('query MobileWorkItemActivityWriteAccess') ||
        query.startsWith('query MobileWorkItemActivityReplyPreflight')) {
      final reply = query.contains('ReplyPreflight');
      accessSinceNamespace++;
      phase = reply || accessSinceNamespace > 1 ? 'preflight' : 'access';
      expect(query, contains('NotesFilterType'));
      if (reply) expect(variables['anchorNoteId'], _anchor);
      data = {
        'currentUser': {'id': 'gid://gitlab/User/7'},
        'workItem': {
          ..._identity(),
          'userPermissions': {'createNote': allowed},
          'widgets': [
            {
              'type': 'NOTES',
              'discussionLocked': locked,
              'discussions': {'pageInfo': _page()},
            },
          ],
        },
        if (reply) 'anchor': _writeNote(id: _anchor, body: 'Anchor'),
      };
    } else if (query.startsWith('mutation ')) {
      phase = 'mutation';
      final input = _map(variables['input']);
      inputs.add(input);
      sentBody = input['body']! as String;
      onMutation?.call();
      data = {
        'createNote': {
          'errors': <Object?>[],
          'note': _writeNote(body: sentBody!),
        },
      };
    } else if (query.startsWith('query MobileWorkItemActivityNoteReadback')) {
      phase = 'readback';
      expect(variables, {'workItemId': _workItem, 'noteId': _created});
      data = {'workItem': _identity(), 'note': _writeNote(body: sentBody!)};
    } else {
      throw StateError('Unexpected query: ${query.split('\n').first}');
    }
    counts.update(phase, (n) => n + 1, ifAbsent: () => 1);
    change?.call(phase, data);
    afterRead?.call(phase);
    if (!controls &&
        const {'activity', 'access', 'preflight'}.contains(phase)) {
      return jsonResponse({
        'errors': [
          {
            'message': 'unsupported controls',
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
    return jsonResponse({
      'data': data,
    }, status: failPhase == phase ? failStatus : 200);
  }
}

/// This coordinator fixture isolates these rows.
final class _Rows implements AiCapabilityLedger {
  const _Rows();

  @override
  AiCapability? find(String operationId) {
    for (final row in aiGroupActivityCreateRows) {
      if (row.operationId != operationId) continue;
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
        editableField: row.editableField,
      );
    }
    return null;
  }

  @override
  List<AiCapability> get modelVisible => [
    for (final row in aiGroupActivityCreateRows) find(row.operationId)!,
  ];
}

final class _Fixture {
  _Fixture(this.base, this.server, this.adapter, this.api, this.tokens) {
    writer = port.GitLabAiWritePort(
      api,
      accountKey: g0eAccount,
      sessionGeneration: 7,
      isCurrent: () => live,
    );
  }

  static Future<_Fixture> create({
    int maxRequests = 40,
    bool oauth = false,
    int? challengeAt,
  }) async {
    final base = await Mr6b3Harness.create();
    final server = _Server();
    late FakeAdapter adapter;
    adapter = FakeAdapter((request) {
      if (oauth && adapter.requests.length == challengeAt) {
        return jsonResponse({}, status: 401);
      }
      return server.respond(request);
    });
    final tokens = FakeAdapter(
      (_) => jsonResponse({
        'access_token': 'synthetic-access',
        'refresh_token': 'synthetic-refresh',
        'token_type': 'bearer',
        'expires_in': 7200,
      }),
    );
    final api = oauth
        ? GitLabApi(
            instance: _instance,
            dio: Dio()..httpClientAdapter = adapter,
            credential: const OAuthCredential(
              accessToken: 'synthetic-access',
              refreshToken: 'synthetic-refresh',
              clientId: 'synthetic-client',
            ),
            oauth: OAuthTokenClient(
              instance: _instance,
              clientId: 'synthetic-client',
              dio: Dio()..httpClientAdapter = tokens,
            ),
            onOAuthRotated: (_) async {},
          )
        : testApi(adapter);
    final f = _Fixture(base, server, adapter, api, tokens);
    f.budget = AiToolBudget(maxGitLabRequests: maxRequests);
    f.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: g0eScope,
        level: f.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'gp9-test',
        writePolicyRevision: f.policyRevision,
        sessionGeneration: 7,
        appInForeground: true,
        alive: f.live,
        ownerApi: api,
        currentResource: AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: 7,
          groupFullPath: g0ePath,
          iid: 5,
        ),
      ),
      createPort: () => f.writer,
      journal: base.journal,
      conversationId: 'gp9-test',
      budget: () => f.budget,
      readFreshness: (_) async {
        final group = await api.record(
          ['groups', '7'],
          query: {'with_projects': 'false'},
        );
        return AiWriteFreshness(
          targetVisibility: group['visibility'] as String?,
          visibilityUnreadable: true,
          sourceVisibilityUnreadable: false,
        );
      },
      placeholders: text.UploadPlaceholderTable(
        instance: api.instance,
        accountKey: g0eAccount,
        conversationId: 'gp9-test',
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: const _Rows(),
    );
    f.coordinator.beginRun('Add a comment to this group work item.');
    f.coordinator.beginTurn();
    addTearDown(f.dispose);
    return f;
  }

  final Mr6b3Harness base;
  final _Server server;
  final FakeAdapter adapter;
  final GitLabApi api;
  final FakeAdapter tokens;
  late final port.GitLabAiWritePort writer;
  late final PolicyAiWriteCoordinator coordinator;
  late final AiToolBudget budget;
  bool live = true;
  int policyRevision = 1;
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;
  int calls = 0;

  port.AiWriteRequest request(
    String op, {
    Map<String, Object?> extra = const {},
    AiWriteScope scope = g0eScope,
  }) => port.AiWriteRequest(
    operationId: op,
    executionId: 'gp9-direct-${calls++}',
    scope: scope,
    arguments: {
      'groupId': 7,
      'iid': 5,
      if (op == _reply) 'anchorNoteId': 401,
      'body': _body,
      ...extra,
    },
  );

  AiToolCall call(String op, {Map<String, Object?> extra = const {}}) =>
      AiToolCall(
        id: 'gp9-${calls++}',
        name: op,
        arguments: {
          ...request(op, extra: extra).arguments,
          'reason': 'Requested group comment.',
        },
      );

  Future<
    ({
      AiJournalState state,
      bool readbackVerified,
      Map<String, Object?> projection,
    })
  >
  commit(
    port.AiWritePrepared prepared, {
    Future<void> Function()? before,
    bool Function()? mayStart,
  }) async {
    prepared.bindGraphBeforeMutation(before ?? () async {});
    final result = await writer.commit(
      prepared,
      mayStart: mayStart ?? () => true,
    );
    return switch (result) {
      port.AiWriteNotSent() => (
        state: AiJournalState.notExecuted,
        readbackVerified: false,
        projection: const <String, Object?>{},
      ),
      port.AiWriteSettled() => (
        state: result.state,
        readbackVerified: result.readbackVerified,
        projection: result.projection,
      ),
      port.AiGraphNoChange() => throw StateError('Create cannot return noop'),
    };
  }

  Future<void> dispose() async {
    coordinator.stop();
    api.close();
    await base.dispose();
  }
}

void _damage(Map<String, Object?> node, String kind) {
  switch (kind) {
    case 'missing project':
      node.remove('project');
    case 'project descendant':
      node['project'] = {'id': 'gid://gitlab/Project/7', 'fullPath': g0ePath};
    case 'foreign group':
      node['namespace'] = {'id': 'gid://gitlab/Group/8', 'fullPath': g0ePath};
    case 'wrong path':
      node['namespace'] = {
        'id': 'gid://gitlab/Group/7',
        'fullPath': 'team/other',
      };
    case 'missing namespace':
      node.remove('namespace');
    case 'wrong work item':
      node['id'] = 'gid://gitlab/WorkItem/92';
    case 'wrong iid':
      node['iid'] = '6';
  }
}

void main() {
  setUp(() {
    aiGroupWorkItemWritesEnabledForTesting = true;
    addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
  });

  test('fixed aliases, visible graph rows, allowlists and static caps', () {
    expect(groupActivityCreateStageOperations, {_comment, _reply});
    expect(aiGroupActivityCreateRows.map((row) => row.operationId).toSet(), {
      _comment,
      _reply,
    });
    expect(aiGroupActivityCreateRows, hasLength(2));
    for (final row in aiGroupActivityCreateRows) {
      expect(row.modelVisible, isTrue);
      expect(row.boundary, AiWriteBoundary.graph);
      expect(row.scopeClass, AiScopeClass.groupWorkItem);
      expect(row.baseTier, AiWriteTier.t2);
      expect(
        row.namedMethod,
        row.operationId == _comment
            ? 'createWorkItemActivityComment'
            : 'createWorkItemActivityReply',
      );
      expect(row.httpCap, row.operationId == _comment ? 21 : 29);
      expect(row.readback, isTrue);
      expect(row.editableField, 'body');
      expect(row.arguments.keys.toSet(), {
        'groupId',
        'iid',
        'body',
        if (row.operationId == _reply) 'anchorNoteId',
      });
      expect(row.arguments.values.every((spec) => spec.required), isTrue);
      expect(row.arguments['body']!.text, AiTextRole.quickActionMarkdown);
      expect(row.arguments['body']!.writableField, 'note');
    }
  });

  for (final op in groupActivityCreateStageOperations) {
    test('$op real prepare, strict readback and fixed keys', () async {
      final f = await _Fixture.create();
      final p = await f.writer.prepare(f.request(op));
      expect(p.groupIdentity!.apiOwner, same(f.api));
      expect(p.groupIdentity!.generation, 7);
      expect(p.hasCurrentGroupIdentity, isTrue);
      expect(p.releaseName, '$g0ePath#5');
      expect(p.writeKeys, {_root, _notes});
      expect(p.dependencyKeys, isEmpty);
      expect(p.bindingTargets.first.kind, AiTargetKind.groupWorkItem);
      expect(p.bindingTargets.first.groupId, 7);
      if (op == _reply) {
        final note = p.bindingTargets.last;
        expect(note.side, AiResourceSide.group);
        expect(note.parentIid, 5);
        expect(note.noteId, 401);
      }
      expect(p.journal.updatedAt, DateTime.parse(_revision).toIso8601String());
      expect(f.server.inputs, isEmpty);
      final outcome = await f.commit(p);
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.readbackVerified, isTrue);
      expect(outcome.projection, {'id': 501});
      expect(f.server.counts['readback'], 1);
      expect(f.server.inputs.single, {
        'noteableId': _workItem,
        'body': _body,
        'internal': false,
        if (op == _reply) 'discussionId': _replyId,
      });
    });

    test('$op requires trusted context before HTTP', () async {
      final f = await _Fixture.create();
      for (final writer in [
        port.GitLabAiWritePort(f.api, accountKey: g0eAccount),
        port.GitLabAiWritePort(
          f.api,
          accountKey: g0eAccount,
          sessionGeneration: 7,
          isCurrent: () => false,
        ),
      ]) {
        await expectLater(
          writer.prepare(f.request(op)),
          throwsA(
            isA<port.AiWriteRefused>().having(
              (e) => e.reason,
              'reason',
              'workItemUnverifiable',
            ),
          ),
        );
      }
      expect(f.adapter.requests, isEmpty);
    });

    for (final extra in <Map<String, Object?>>[
      {'projectId': 7},
      {'noteableId': _workItem},
      {'discussionId': _replyId},
      {'expectedUpdatedAt': _revision},
      {'nonce': 'new'},
      {'internal': true},
    ]) {
      test(
        '$op rejects extra field ${extra.keys.single} before HTTP',
        () async {
          final f = await _Fixture.create();
          await expectLater(
            f.writer.prepare(f.request(op, extra: extra)),
            throwsA(
              isA<ApiFailure>().having(
                (e) => e.kind,
                'kind',
                FailureKind.validation,
              ),
            ),
          );
          expect(f.adapter.requests, isEmpty);
        },
      );
    }

    for (final extra in <Map<String, Object?>>[
      {'groupId': 8},
      {'iid': 6},
      {'groupId': 0},
      {'iid': -1},
    ]) {
      test('$op refuses coordinates $extra without mutation', () async {
        final f = await _Fixture.create();
        await expectLater(
          f.writer.prepare(f.request(op, extra: extra)),
          (extra.values.single! as int) <= 0
              ? throwsA(
                  isA<ApiFailure>().having(
                    (e) => e.kind,
                    'kind',
                    FailureKind.validation,
                  ),
                )
              : _refused('activityUnverifiable'),
        );
        expect(f.server.inputs, isEmpty);
        expect(f.server.counts['namespace'], isNull);
      });
    }

    for (final phase in [
      'namespace',
      if (op == _reply) 'activity',
      'access',
      'preflight',
      'readback',
    ]) {
      for (final kind in [
        'missing project',
        'project descendant',
        'foreign group',
        'wrong path',
        'missing namespace',
        'wrong work item',
        'wrong iid',
      ]) {
        // The namespace resolver establishes the GID. Later reads must retain it.
        if (phase == 'namespace' && kind == 'wrong work item') continue;
        test(
          '$op $phase refuses $kind ${phase == 'readback' ? 'after' : 'before'} send',
          () async {
            final f = await _Fixture.create();
            f.server.change = (at, data) {
              if (at != phase) return;
              final parent = at == 'namespace'
                  ? _map(_map(data['namespace'])['workItem'])
                  : _map(data['workItem']);
              _damage(parent, kind);
            };
            if (phase == 'preflight' || phase == 'readback') {
              final p = await f.writer.prepare(f.request(op));
              final out = await f.commit(p);
              expect(
                out.state,
                phase == 'readback'
                    ? AiJournalState.writeUncertain
                    : AiJournalState.notExecuted,
              );
              expect(out.readbackVerified, isFalse);
            } else {
              await expectLater(
                f.writer.prepare(f.request(op)),
                _refused('activityUnverifiable'),
              );
            }
            expect(f.server.counts[phase], 1);
            expect(f.server.inputs.length, phase == 'readback' ? 1 : 0);
          },
        );
      }
    }

    for (final control in [
      'locked',
      'forbidden',
      'missing widget',
      'unsupported',
      'actor',
    ]) {
      test('$op $control refuses without fallback or mutation', () async {
        final f = await _Fixture.create();
        if (control == 'locked') f.server.locked = true;
        if (control == 'forbidden') f.server.allowed = false;
        if (control == 'unsupported') f.server.controls = false;
        f.server.change = (phase, data) {
          if (phase != 'access') return;
          if (control == 'missing widget') {
            _map(data['workItem'])['widgets'] = <Object?>[];
          }
          if (control == 'actor') {
            data['currentUser'] = {'id': 'gid://gitlab/User/8'};
          }
        };
        await expectLater(
          f.writer.prepare(f.request(op)),
          _refused(
            control == 'locked'
                ? 'activityLocked'
                : control == 'forbidden'
                ? 'activityForbidden'
                : 'activityUnverifiable',
          ),
        );
        // A cached controls failure is also refused, with no legacy retry.
        if (control == 'unsupported') {
          final before = f.adapter.requests.length;
          await expectLater(
            f.writer.prepare(f.request(op)),
            _refused(
              control == 'locked'
                  ? 'activityLocked'
                  : control == 'forbidden'
                  ? 'activityForbidden'
                  : 'activityUnverifiable',
            ),
          );
          expect(f.adapter.requests.length - before, 2);
        }
        expect(f.server.inputs, isEmpty);
      });
    }

    for (final phase in [
      'user',
      'namespace',
      if (op == _reply) 'activity',
      'access',
    ]) {
      test('$op context revocation after $phase stops opening', () async {
        final f = await _Fixture.create();
        f.server.afterRead = (at) {
          if (at == phase) f.live = false;
        };
        await expectLater(
          f.writer.prepare(f.request(op)),
          _refused('activityUnverifiable'),
        );
        expect(f.server.inputs, isEmpty);
        expect(f.server.counts.keys.last, phase);
      });
    }

    for (final phase in ['mutation', 'readback']) {
      for (final problem in [
        'missing note project',
        'wrong body',
        'wrong author',
        'wrong noteable',
        'wrong reply',
        'payload errors',
        'http401',
        'http500',
      ]) {
        if (problem == 'payload errors' && phase != 'mutation') continue;
        test('$op $phase $problem stays uncertain and never retries', () async {
          final f = await _Fixture.create();
          final p = await f.writer.prepare(f.request(op));
          f.server.change = (at, data) {
            if (at != phase) return;
            final note = at == 'mutation'
                ? _map(_map(data['createNote'])['note'])
                : _map(data['note']);
            switch (problem) {
              case 'missing note project':
                note.remove('project');
              case 'wrong body':
                note['body'] = 'drift';
              case 'wrong author':
                note['author'] = {
                  'id': 'gid://gitlab/User/8',
                  'name': 'Other',
                  'username': 'other',
                };
              case 'wrong noteable':
                note['noteableId'] = 92;
              case 'wrong reply':
                _map(note['discussion'])['replyId'] =
                    'gid://gitlab/Discussion/other';
              case 'payload errors':
                _map(data['createNote'])['errors'] = ['rejected'];
            }
          };
          if (problem.startsWith('http')) {
            f.server.failPhase = phase;
            f.server.failStatus = problem == 'http401' ? 401 : 500;
          }
          final out = await f.commit(p);
          expect(out.state, AiJournalState.writeUncertain);
          expect(out.readbackVerified, isFalse);
          expect(f.server.inputs, hasLength(1));
          await expectLater(
            f.writer.commit(p, mayStart: () => true),
            completion(isA<port.AiWriteNotSent>()),
          );
          expect(f.server.inputs, hasLength(1));
        });
      }
    }

    for (final control in [
      'locked',
      'forbidden',
      'missing widget',
      'unsupported',
      'actor',
    ]) {
      test('$op final preflight $control refuses before mutation', () async {
        final f = await _Fixture.create();
        final p = await f.writer.prepare(f.request(op));
        if (control == 'unsupported') f.server.controls = false;
        f.server.change = (phase, data) {
          if (phase != 'preflight') return;
          final item = _map(data['workItem']);
          if (control == 'locked') {
            _map((item['widgets']! as List).single)['discussionLocked'] = true;
          }
          if (control == 'forbidden') {
            item['userPermissions'] = {'createNote': false};
          }
          if (control == 'missing widget') item['widgets'] = <Object?>[];
          if (control == 'actor') {
            data['currentUser'] = {'id': 'gid://gitlab/User/8'};
          }
        };
        final out = await f.commit(p);
        expect(out.state, AiJournalState.notExecuted);
        expect(f.server.counts['preflight'], 1);
        expect(f.server.inputs, isEmpty);
      });
    }

    test('$op REST actor mismatch never reads namespace', () async {
      final f = await _Fixture.create();
      f.server.actor = 8;
      await expectLater(
        f.writer.prepare(f.request(op)),
        _refused('activityUnverifiable'),
      );
      expect(f.server.counts, {'user': 1});
    });

    test('$op captured read epoch cannot revive a proposal', () async {
      final f = await _Fixture.create();
      final proposal = await f.coordinator.propose(f.call(op));
      expect(proposal, isNotNull);
      f.api.clearReadCache();
      final out = await f.coordinator.approve(proposal!);
      expect(out.state, AiJournalState.notExecuted);
      expect(f.server.inputs, isEmpty);
    });

    test('$op session loss after send remains uncertain', () async {
      final f = await _Fixture.create();
      final p = await f.writer.prepare(f.request(op));
      f.server.afterRead = (phase) {
        if (phase == 'mutation') f.live = false;
      };
      expect((await f.commit(p)).state, AiJournalState.writeUncertain);
      expect(f.server.inputs, hasLength(1));
    });

    test('$op independent PAT cap through both coordinator rounds', () async {
      final f = await _Fixture.create(maxRequests: op == _comment ? 21 : 29);
      if (op == _reply) f.server.paging = 'outer';
      f.server.onMutation = () {
        final entries = f.base.journal.entries(g0eAccount);
        expect(entries.last.state, AiJournalState.dispatching);
      };
      final proposal = await f.coordinator.propose(f.call(op));
      expect(
        proposal,
        isNotNull,
        reason: f.coordinator.outcomeFor('gp9-0')?.reasonCode,
      );
      expect(f.server.inputs, isEmpty);
      final outcome = await f.coordinator.approve(proposal!);
      expect(
        outcome.state,
        AiJournalState.succeeded,
        reason: outcome.reasonCode,
      );
      expect(outcome.readbackConfirmed, isTrue);
      expect(f.adapter.requests.length, op == _comment ? 11 : 15);
      expect(f.server.counts, {
        'freshness': 2,
        'user': 2,
        'namespace': 2,
        if (op == _reply) ...{'activity': 2, 'activityNext': 2},
        'access': 2,
        'preflight': 1,
        'mutation': 1,
        'readback': 1,
      });
      expect(f.tokens.requests, isEmpty);
      final bytes = File(f.base.files.pathFor(g0eAccount)).readAsBytesSync();
      expect(String.fromCharCodes(bytes), isNot(contains(_body)));
    });

    test('$op cap minus one rejects before HTTP', () async {
      final f = await _Fixture.create(maxRequests: op == _comment ? 20 : 28);
      final call = f.call(op);
      expect(await f.coordinator.propose(call), isNull);
      expect(
        f.coordinator.outcomeFor(call.id)!.reasonCode,
        'httpBudgetExceeded',
      );
      expect(f.adapter.requests, isEmpty);
    });

    test('$op edited body is bound without changing keys', () async {
      final f = await _Fixture.create();
      final p = await f.writer.prepare(f.request(op));
      final digest = p.bindingDigest;
      p.bindPreparedText(
        port.AiWriteRequest(
          operationId: op,
          executionId: p.request.executionId,
          scope: p.request.scope,
          arguments: {...p.request.arguments, 'body': 'Edited safe body'},
        ),
      );
      expect(p.bindingDigest, isNot(digest));
      expect(p.writeKeys, {_root, _notes});
      expect((await f.commit(p)).state, AiJournalState.succeeded);
      expect(f.server.sentBody, 'Edited safe body');
    });

    test('$op dispatch revision drift cancels the old approval', () async {
      final f = await _Fixture.create();
      final proposal = await f.coordinator.propose(f.call(op));
      expect(
        proposal,
        isNotNull,
        reason: f.coordinator.outcomeFor('gp9-0')?.reasonCode,
      );
      f.server.revision = '2026-10-24T00:00:00Z';
      final out = await f.coordinator.approve(proposal!);
      expect(out.state, AiJournalState.notExecuted);
      expect(out.reasonCode, 'targetChanged');
      expect(f.server.inputs, isEmpty);
    });

    test('$op flush failure and mayStart false send nothing', () async {
      for (final flushFails in [true, false]) {
        final f = await _Fixture.create();
        final p = await f.writer.prepare(f.request(op));
        if (flushFails) {
          await expectLater(
            f.commit(
              p,
              before: () async {
                throw StateError('flush failed');
              },
            ),
            throwsStateError,
          );
        } else {
          expect(
            (await f.commit(p, mayStart: () => false)).state,
            AiJournalState.notExecuted,
          );
        }
        expect(f.server.inputs, isEmpty);
      }
    });

    test('$op policy revoked during dispatch flush sends nothing', () async {
      final f = await _Fixture.create();
      final proposal = await f.coordinator.propose(f.call(op));
      expect(
        proposal,
        isNotNull,
        reason: f.coordinator.outcomeFor('gp9-0')?.reasonCode,
      );
      final entered = f.base.files.armBarrier(writesBeforeBarrier: 1);
      final pending = f.coordinator.approve(proposal!);
      await entered;
      f.policyRevision++;
      f.base.files.releaseBarrier();
      final out = await pending;
      expect(out.state, AiJournalState.notExecuted);
      expect(f.server.inputs, isEmpty);
    });
  }

  for (final paging in ['outer', 'nested']) {
    test('reply locates anchor on $paging second page', () async {
      final f = await _Fixture.create();
      f.server.paging = paging;
      final p = await f.writer.prepare(f.request(_reply));
      expect(f.server.counts['activity'], 1);
      expect(
        f.server.counts[paging == 'outer' ? 'activityNext' : 'notesNext'],
        1,
      );
      expect((await f.commit(p)).state, AiJournalState.succeeded);
    });
  }

  for (final paging in ['outer', 'nested']) {
    for (final kind in [
      'missing project',
      'project descendant',
      'foreign group',
      'wrong path',
      'missing namespace',
      'wrong work item',
      'wrong iid',
    ]) {
      test('reply $paging continuation refuses $kind', () async {
        final f = await _Fixture.create();
        f.server.paging = paging;
        final phase = paging == 'outer' ? 'activityNext' : 'notesNext';
        f.server.change = (at, data) {
          if (at == phase) _damage(_map(data['workItem']), kind);
        };
        await expectLater(
          f.writer.prepare(f.request(_reply)),
          _refused('activityUnverifiable'),
        );
        expect(f.server.counts[phase], 1);
        expect(f.server.counts['access'], isNull);
        expect(f.server.inputs, isEmpty);
      });
    }
  }

  test(
    'reply nested continuation requires explicit anchor project null',
    () async {
      final f = await _Fixture.create();
      f.server.paging = 'nested';
      f.server.change = (phase, data) {
        if (phase == 'notesNext') _map(data['anchor']).remove('project');
      };
      await expectLater(
        f.writer.prepare(f.request(_reply)),
        _refused('activityUnverifiable'),
      );
      expect(f.server.counts['notesNext'], 1);
      expect(f.server.inputs, isEmpty);
    },
  );

  test('reply refuses third locator page without extra reads', () async {
    final f = await _Fixture.create();
    f.server.paging = 'third';
    await expectLater(
      f.writer.prepare(f.request(_reply)),
      _refused('activityUnverifiable'),
    );
    expect(f.server.counts['activity'], 1);
    expect(f.server.counts['activityNext'], 1);
    expect(f.server.counts['access'], isNull);
    expect(f.server.inputs, isEmpty);
  });

  for (final field in [
    'noteableId',
    'discussion',
    'replyId',
    'createdAt',
    'missing anchor',
  ]) {
    test('reply preflight refuses changed $field', () async {
      final f = await _Fixture.create();
      final p = await f.writer.prepare(f.request(_reply));
      f.server.change = (phase, data) {
        if (phase != 'preflight') return;
        final anchor = _map(data['anchor']);
        if (field == 'noteableId') anchor['noteableId'] = 92;
        if (field == 'discussion') {
          _map(anchor['discussion'])['id'] = 'gid://gitlab/Discussion/other';
        }
        if (field == 'replyId') {
          _map(anchor['discussion'])['replyId'] =
              'gid://gitlab/Discussion/other';
        }
        if (field == 'createdAt') {
          _map(anchor['discussion'])['createdAt'] = '2026-10-01T02:00:00Z';
        }
        if (field == 'missing anchor') data['anchor'] = null;
      };
      expect((await f.commit(p)).state, AiJournalState.notExecuted);
      expect(f.server.inputs, isEmpty);
    });
  }

  test('fixed keys ignore operation, body, anchor and execution ID', () async {
    final f = await _Fixture.create();
    final a = await f.writer.prepare(f.request(_comment));
    final b = await f.writer.prepare(
      f.request(_reply, extra: {'body': 'Different'}),
    );
    expect(a.writeKeys, b.writeKeys);
    expect(a.writeKeys, {_root, _notes});
    expect(a.writeKeys.any((key) => key.parts.contains(_body)), isFalse);
  });

  test(
    'uncertain create fences changed payload and reply in another run',
    () async {
      final f = await _Fixture.create();
      final p = await f.coordinator.propose(f.call(_comment));
      expect(p, isNotNull);
      f.server.failPhase = 'readback';
      expect(
        (await f.coordinator.approve(p!)).state,
        AiJournalState.writeUncertain,
      );
      expect(f.base.journal.isolated(g0eAccount, {_root, _notes}), isTrue);
      f.coordinator.beginRun('Reply with a different body.');
      f.coordinator.beginTurn();
      expect(
        await f.coordinator.propose(
          f.call(_reply, extra: {'body': 'Different'}),
        ),
        isNull,
      );
      expect(f.server.inputs, hasLength(1));
    },
  );

  for (final body in [
    'glpat-ABCDEFGHIJKLMNOPQRST',
    '[REDACTED]',
    '![x](https://outside.example/a.png)',
    '[[attachment:att-9]]',
    '[[upload:u-1]]',
    'a\n/merge',
  ]) {
    test('class A text refuses $body even at bypass', () async {
      final f = await _Fixture.create();
      f.level = AiAutonomyLevel.bypass;
      expect(
        await f.coordinator.propose(f.call(_comment, extra: {'body': body})),
        isNull,
      );
      expect(f.server.inputs, isEmpty);
    });
  }

  for (final op in groupActivityCreateStageOperations) {
    // Freshness occurs before capture. Each subsequent 401 refresh revokes the
    // captured epoch: that is a refusal, never a reason to bypass the fence.
    for (
      var challenge = 1;
      challenge <= (op == _comment ? 11 : 15);
      challenge++
    ) {
      test('$op OAuth replay at logical read $challenge is bounded', () async {
        final f = await _Fixture.create(oauth: true, challengeAt: challenge);
        if (op == _reply) f.server.paging = 'outer';
        final call = f.call(op);
        final proposal = await f.coordinator.propose(call);
        if (challenge == 1 || challenge >= (op == _comment ? 5 : 7)) {
          expect(
            proposal,
            isNotNull,
            reason: f.coordinator.outcomeFor(call.id)?.reasonCode,
          );
        } else {
          expect(proposal, isNull);
        }
        if (proposal != null) {
          final out = await f.coordinator.approve(proposal);
          if (challenge == 1 || challenge == (op == _comment ? 11 : 15)) {
            expect(out.state, AiJournalState.succeeded, reason: out.reasonCode);
          } else if (challenge == (op == _comment ? 10 : 14)) {
            expect(out.state, AiJournalState.writeUncertain);
          } else {
            expect(out.state, AiJournalState.notExecuted);
          }
        }
        expect(
          f.adapter.requests.length,
          lessThanOrEqualTo(op == _comment ? 21 : 29),
        );
        expect(f.tokens.requests.length, 1);
        expect(f.server.inputs.length, lessThanOrEqualTo(1));
        if (challenge != 1 && challenge < (op == _comment ? 10 : 14)) {
          expect(f.server.inputs, isEmpty);
        }
      });
    }
  }
}
