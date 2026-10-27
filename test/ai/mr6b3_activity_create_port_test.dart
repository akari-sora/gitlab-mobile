import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/exact_edit.dart' as exact;
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
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';

const _account = 'https://example.com/gitlab#7';
const _path = 'team/example-9';
const _workItemId = 'gid://gitlab/WorkItem/31';
const _projectId = 'gid://gitlab/Project/9';
const _namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/9';
const _anchorId = 'gid://gitlab/Note/401';
const _discussionId = 'gid://gitlab/Discussion/server-owned';
const _replyId = 'gid://gitlab/IndividualNoteDiscussion/server-owned';
const _createdId = 'gid://gitlab/DiscussionNote/501';
const _body = 'Synthetic **activity** note';
const _scope = AiWriteScope(
  accountKey: _account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.workItem,
      projectId: 9,
      projectPath: _path,
      iid: 3,
    ),
  ],
);

final _expected = WorkItemGraphSummary(
  id: _workItemId,
  iid: 3,
  title: 'Synthetic work item',
  state: 'OPEN',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 23),
  project: const GraphResourceRef(id: _projectId, fullPath: _path),
  namespace: const GraphResourceRef(id: _namespaceId, fullPath: _path),
  type: const WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/server-owned',
    name: 'Task',
  ),
);

Matcher _refusal(String reason) => isA<port.AiWriteRefused>().having(
  (error) => error.reason,
  'reason',
  reason,
);

Map<String, Object?> _pageInfo({bool next = false, String? cursor}) => {
  'hasNextPage': next,
  'endCursor': cursor,
};

Map<String, Object?> _identity({int project = 9, int iid = 3}) => {
  'id': _workItemId,
  'iid': '$iid',
  'project': {'id': 'gid://gitlab/Project/$project', 'fullPath': _path},
  'namespace': {'id': _namespaceId, 'fullPath': _path},
};

Map<String, Object?> _summary({
  int project = 9,
  int iid = 3,
  String? updatedAt,
}) => {
  ..._identity(project: project, iid: iid),
  'title': 'Synthetic work item',
  'state': 'OPEN',
  'createdAt': '2026-10-01T00:00:00Z',
  'updatedAt': updatedAt ?? '2026-10-23T00:00:00Z',
  'workItemType': {
    'id': 'gid://gitlab/WorkItems::Type/server-owned',
    'name': 'Task',
  },
};

Map<String, Object?> _detail({
  int project = 9,
  int iid = 3,
  String? updatedAt,
}) => {
  ..._summary(project: project, iid: iid, updatedAt: updatedAt),
  'description': 'Synthetic',
  'widgets': const <Object?>[],
};

Map<String, Object?> _projectDetail({
  int project = 9,
  int iid = 3,
  String? updatedAt,
}) => {
  'data': {
    'project': {
      'id': 'gid://gitlab/Project/$project',
      'fullPath': _path,
      'workItems': {
        'nodes': [_detail(project: project, iid: iid, updatedAt: updatedAt)],
        'pageInfo': _pageInfo(),
      },
    },
  },
};

Map<String, Object?> _activityNote({
  String id = _anchorId,
  String body = 'Anchor',
  String createdAt = '2026-10-01T01:02:03Z',
  String updatedAt = '2026-10-01T01:03:04Z',
  String authorId = 'gid://gitlab/User/7',
}) => {
  'id': id,
  'system': false,
  'systemNoteIconName': null,
  'body': body,
  'createdAt': createdAt,
  'updatedAt': updatedAt,
  'author': {'id': authorId, 'name': 'Synthetic User', 'username': 'tester'},
};

Map<String, Object?> _discussion({
  List<Object?> notes = const [],
  bool notesNext = false,
  String? notesCursor,
  String id = _discussionId,
  String replyId = _replyId,
  String createdAt = '2026-10-01T01:00:00Z',
}) => {
  'id': id,
  'replyId': replyId,
  'createdAt': createdAt,
  'notes': {
    'nodes': notes,
    'pageInfo': _pageInfo(next: notesNext, cursor: notesCursor),
  },
};

Map<String, Object?> _activity({
  List<Object?> discussions = const [],
  bool next = false,
  String? cursor,
}) => {
  'data': {
    'workItem': {
      ..._identity(),
      'widgets': [
        {
          'type': 'NOTES',
          'discussionLocked': false,
          'discussions': {
            'nodes': discussions,
            'pageInfo': _pageInfo(next: next, cursor: cursor),
          },
        },
      ],
    },
  },
};

Map<String, Object?> _writeNote({
  String id = _createdId,
  String body = _body,
  String author = 'gid://gitlab/User/7',
  int noteableId = 31,
  String discussion = _discussionId,
  String reply = _replyId,
}) => {
  ..._activityNote(id: id, body: body),
  'author': {'id': author, 'name': 'Synthetic User', 'username': 'tester'},
  'internal': false,
  'noteableType': 'Issue',
  'noteableId': noteableId,
  'project': {'id': _projectId, 'fullPath': _path},
  'discussion': {
    'id': discussion,
    'replyId': reply,
    'createdAt': '2026-10-01T01:00:00Z',
  },
};

Map<String, Object?> _access({
  bool allowed = true,
  bool locked = false,
  String actor = 'gid://gitlab/User/7',
  Object? anchor,
  int project = 9,
}) => {
  'data': {
    'currentUser': {'id': actor},
    'workItem': {
      ..._identity(project: project),
      'userPermissions': {'createNote': allowed},
      'widgets': [
        {
          'type': 'NOTES',
          'discussionLocked': locked,
          'discussions': {
            'pageInfo': {'hasNextPage': false},
          },
        },
      ],
    },
    'anchor': ?anchor,
  },
};

Map<String, Object?> _anchor({
  int noteableId = 31,
  String discussion = _discussionId,
  String reply = _replyId,
}) => _writeNote(
  id: _anchorId,
  body: 'Anchor',
  noteableId: noteableId,
  discussion: discussion,
  reply: reply,
);

final class _Server {
  int restUser = 7;
  bool allowed = true;
  bool locked = false;
  bool unsupportedControls = false;
  bool unsupportedControlsOnce = false;
  bool wrongDetailProject = false;
  bool wrongAccessProject = false;
  bool wrongActor = false;
  bool actorDriftsOnFreshPreflight = false;
  bool wrongAnchorParent = false;
  bool wrongReadbackBody = false;
  bool wrongReadbackAuthor = false;
  bool nested = false;
  bool needThirdRead = false;
  bool outerSecondPage = false;
  String workItemUpdatedAt = '2026-10-23T00:00:00Z';
  String locatedDiscussionId = _discussionId;
  String locatedReplyId = _replyId;
  String locatedDiscussionCreatedAt = '2026-10-01T01:00:00Z';
  String locatedNoteId = _anchorId;
  String locatedNoteCreatedAt = '2026-10-01T01:02:03Z';
  String locatedNoteUpdatedAt = '2026-10-01T01:03:04Z';
  String locatedNoteBody = 'Anchor';
  String locatedNoteAuthor = 'gid://gitlab/User/7';
  bool sent = false;
  int activityReads = 0;
  int accessReads = 0;
  int writes = 0;
  String? sentBody;
  String? replyPreflightAnchor;
  Completer<void>? beforeSend;

  ResponseBody respond(RequestOptions request) {
    if (request.uri.path.endsWith('/api/v4/user')) {
      return jsonResponse({'id': restUser, 'username': 'tester'});
    }
    if (request.uri.path.endsWith('/api/v4/projects/9')) {
      return jsonResponse(projectJson(9));
    }
    final data = request.data as Map;
    final query = data['query'] as String;
    if (query.startsWith('query MobileProjectWorkItem')) {
      return jsonResponse(
        _projectDetail(
          project: wrongDetailProject ? 10 : 9,
          updatedAt: workItemUpdatedAt,
        ),
      );
    }
    if (query.startsWith('query MobileWorkItemActivity(')) {
      activityReads++;
      final after = (data['variables'] as Map)['after'];
      if (unsupportedControlsOnce) {
        unsupportedControlsOnce = false;
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
      if (unsupportedControls && query.contains('NotesFilterType')) {
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
      if (needThirdRead) {
        return jsonResponse(_activity(next: true, cursor: 'outer-2'));
      }
      if (outerSecondPage && after == null) {
        return jsonResponse(_activity(next: true, cursor: 'outer-2'));
      }
      if (nested) {
        return jsonResponse(
          _activity(
            discussions: [
              _discussion(
                notes: [_activityNote(id: 'gid://gitlab/Note/400')],
                notesNext: true,
                notesCursor: 'nested-2',
              ),
            ],
          ),
        );
      }
      return jsonResponse(
        _activity(
          discussions: [
            _discussion(
              id: locatedDiscussionId,
              replyId: locatedReplyId,
              createdAt: locatedDiscussionCreatedAt,
              notes: [
                _activityNote(
                  id: locatedNoteId,
                  body: locatedNoteBody,
                  createdAt: locatedNoteCreatedAt,
                  updatedAt: locatedNoteUpdatedAt,
                  authorId: locatedNoteAuthor,
                ),
              ],
            ),
          ],
        ),
      );
    }
    if (query.startsWith('query MobileWorkItemActivityLegacy')) {
      activityReads++;
      return jsonResponse(
        _activity(
          discussions: [
            _discussion(notes: [_activityNote()]),
          ],
        ),
      );
    }
    if (query.startsWith('query MobileWorkItemActivityNext')) {
      activityReads++;
      return jsonResponse(
        _activity(
          next: needThirdRead,
          cursor: needThirdRead ? 'outer-3' : null,
        ),
      );
    }
    if (query.startsWith('query MobileWorkItemDiscussionNotes')) {
      activityReads++;
      return jsonResponse({
        'data': {
          'workItem': _identity(),
          'anchor': {
            'id': 'gid://gitlab/Note/400',
            'project': {'id': _projectId, 'fullPath': _path},
            'discussion': _discussion(notes: [_activityNote()]),
          },
        },
      });
    }
    if (query.startsWith('query MobileWorkItemActivityWriteAccess')) {
      accessReads++;
      if (query.contains('NotesFilterType') &&
          (unsupportedControls || unsupportedControlsOnce)) {
        unsupportedControlsOnce = false;
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
      return jsonResponse(
        _access(
          allowed: allowed,
          locked: locked,
          actor: wrongActor || (actorDriftsOnFreshPreflight && accessReads > 1)
              ? 'gid://gitlab/User/8'
              : 'gid://gitlab/User/7',
          project: wrongAccessProject ? 10 : 9,
        ),
      );
    }
    if (query.startsWith('query MobileWorkItemActivityReplyPreflight')) {
      accessReads++;
      replyPreflightAnchor =
          (data['variables'] as Map)['anchorNoteId'] as String?;
      return jsonResponse(
        _access(
          allowed: allowed,
          locked: locked,
          actor: wrongActor || (actorDriftsOnFreshPreflight && accessReads > 1)
              ? 'gid://gitlab/User/8'
              : 'gid://gitlab/User/7',
          anchor: _anchor(noteableId: wrongAnchorParent ? 99 : 31),
        ),
      );
    }
    if (query.startsWith('mutation ')) {
      sent = true;
      writes++;
      sentBody = ((data['variables'] as Map)['input'] as Map)['body'] as String;
      return jsonResponse({
        'data': {
          'createNote': {
            'errors': <Object?>[],
            'note': _writeNote(body: sentBody!),
          },
        },
      });
    }
    if (query.startsWith('query MobileWorkItemActivityNoteReadback')) {
      return jsonResponse({
        'data': {
          'workItem': _identity(),
          'note': _writeNote(
            body: wrongReadbackBody ? 'drifted' : sentBody!,
            author: wrongReadbackAuthor
                ? 'gid://gitlab/User/8'
                : 'gid://gitlab/User/7',
          ),
        },
      });
    }
    throw StateError('Unexpected fake query: ${query.split('\n').first}');
  }
}

final class _Rows implements AiCapabilityLedger {
  const _Rows();

  @override
  AiCapability? find(String operationId) {
    final row = productionAiLedger.find(operationId);
    if (row == null || !aiGraphqlActivityCreateRows.contains(row)) return null;
    return AiCapability(
      operationId: row.operationId,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      boundary: row.boundary,
      modelVisible: true,
      arguments: row.arguments,
      httpCap: row.httpCap,
      readback: row.readback,
      editableField: row.editableField,
    );
  }

  @override
  List<AiCapability> get modelVisible => [
    for (final row in aiGraphqlActivityCreateRows) find(row.operationId)!,
  ];
}

final class _Fixture {
  _Fixture._(
    this.server,
    this.adapter,
    this.api,
    this.writer,
    this.root,
    this.journal,
    this.files,
    this.tokenDio,
  );

  static Future<_Fixture> create({
    int maxRequests = 40,
    bool oauth = false,
  }) async {
    final server = _Server();
    final attempts = <String, int>{};
    final adapter = FakeAdapter((request) {
      final data = request.data;
      final mutation =
          data is Map && '${data['query']}'.startsWith('mutation ');
      if (oauth && !mutation) {
        final key = '${request.method} ${request.uri}';
        final count = attempts.update(
          key,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        if (count.isOdd) return jsonResponse({}, status: 401);
      }
      return server.respond(request);
    });
    final tokenDio = Dio()
      ..httpClientAdapter = FakeAdapter(
        (_) => jsonResponse({
          'access_token': 'synthetic-access',
          'refresh_token': 'synthetic-refresh',
          'token_type': 'bearer',
          'expires_in': 7200,
        }),
      );
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    final api = oauth
        ? GitLabApi(
            instance: instance,
            dio: Dio()..httpClientAdapter = adapter,
            credential: const OAuthCredential(
              accessToken: 'synthetic-access',
              refreshToken: 'synthetic-refresh',
              clientId: 'synthetic-client',
            ),
            oauth: OAuthTokenClient(
              instance: instance,
              clientId: 'synthetic-client',
              dio: tokenDio,
            ),
            onOAuthRotated: (_) async {},
          )
        : testApi(adapter);
    final root = Directory.systemTemp.createTempSync('mr6b3-p9-');
    final files = AiJournalFiles(root);
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      files: files,
      processId: 'mr6b3-p9',
    );
    await journal.recoverAfterAccountsLoaded([_account]);
    await journal.ensureInitialized(_account);
    final fixture = _Fixture._(
      server,
      adapter,
      api,
      port.GitLabAiWritePort(api, accountKey: _account),
      root,
      journal,
      files,
      tokenDio,
    );
    fixture.budget = AiToolBudget(maxGitLabRequests: maxRequests);
    fixture.coordinator = fixture._coordinator();
    fixture.beginRun();
    return fixture;
  }

  final _Server server;
  final FakeAdapter adapter;
  final GitLabApi api;
  final port.GitLabAiWritePort writer;
  final Directory root;
  final AiWriteJournal journal;
  final AiJournalFiles files;
  final Dio tokenDio;
  late AiToolBudget budget;
  late PolicyAiWriteCoordinator coordinator;
  int callId = 0;

  PolicyAiWriteCoordinator _coordinator() => PolicyAiWriteCoordinator(
    snapshot: () => const AiWritePolicySnapshot(
      scope: _scope,
      level: AiAutonomyLevel.confirmEach,
      ceiling: AiAutonomyLevel.bypass,
      consentHash: 'p9-consent',
      writePolicyRevision: 1,
      scopeRevision: 1,
      sessionGeneration: 7,
    ),
    createPort: () => writer,
    journal: journal,
    conversationId: 'mr6b3-p9',
    budget: () => budget,
    readFreshness: (_) async => const AiWriteFreshness(
      updatedAt: '2026-10-23T00:00:00Z',
      visibilityUnreadable: false,
    ),
    placeholders: text.UploadPlaceholderTable(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
    ),
    knownSecrets: () => const {},
    safeDisplay: (value) => value,
    ledger: const _Rows(),
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
    now: () => DateTime.utc(2026, 10, 23, 12),
  );

  void beginRun([String text = 'Add an activity note to issue #3.']) {
    coordinator.beginRun(text);
    coordinator.beginTurn();
  }

  port.AiWriteRequest request(
    String operation, {
    Map<String, Object?> extra = const {},
  }) => port.AiWriteRequest(
    operationId: operation,
    executionId: 'direct-${callId++}',
    scope: _scope,
    scheduleHmacKey: journal.scheduleHmacKey,
    arguments: {
      'projectId': 9,
      'iid': 3,
      if (operation == 'createWorkItemActivityReply') 'anchorNoteId': 401,
      'body': _body,
      ...extra,
    },
  );

  AiToolCall call(String operation, {Map<String, Object?> extra = const {}}) =>
      AiToolCall(
        id: 'p9-${callId++}',
        name: operation,
        arguments: {
          'projectId': 9,
          'iid': 3,
          if (operation == 'createWorkItemActivityReply') 'anchorNoteId': 401,
          'body': _body,
          'reason': 'The user asked for this activity note.',
          ...extra,
        },
      );

  Future<port.AiWriteOutcome> commit(String operation) async {
    final prepared = await writer.prepare(request(operation));
    prepared.bindGraphBeforeMutation(() async {});
    return writer.commit(prepared, mayStart: () => true);
  }

  Future<void> dispose() async {
    coordinator.stop('disposed');
    api.close();
    tokenDio.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

void main() {
  test('rows are visible, closed and independently capped', () {
    expect(aiGraphqlActivityCreateRows, hasLength(2));
    expect(aiGraphqlActivityCreateRows.map((row) => row.operationId), [
      'createWorkItemActivityComment',
      'createWorkItemActivityReply',
    ]);
    expect(aiGraphqlActivityCreateRows.map((row) => row.httpCap), [21, 29]);
    for (final row in aiGraphqlActivityCreateRows) {
      expect(row.baseTier, AiWriteTier.t2);
      expect(row.boundary, AiWriteBoundary.graph);
      expect(row.modelVisible, isTrue);
      expect(row.readback, isTrue);
      expect(row.arguments.keys, isNot(contains('discussionId')));
    }
    expect(
      productionAiLedger.modelVisible.map((row) => row.operationId),
      containsAll(aiGraphqlActivityCreateRows.map((row) => row.operationId)),
    );
  });

  for (final operation in [
    'createWorkItemActivityComment',
    'createWorkItemActivityReply',
  ]) {
    test('$operation blocks a normalized leading slash without HTTP', () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      final proposal = (await f.coordinator.propose(f.call(operation)))!;
      final requests = f.adapter.requests.length;
      for (final editedText in [' /foo/bar', ' /foo/bar', null]) {
        final outcome = await f.coordinator.approve(
          proposal,
          editedText: editedText,
        );
        expect(outcome.reasonCode, text.AiTextBlockCode.quickAction);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(f.adapter.requests, hasLength(requests));
        expect(f.server.writes, 0);
        expect(proposal.editedText, ' /foo/bar');
      }
    });

    for (final body in ['a\n/merge', 'a\r\n/approve', 'a\n\r/move x/y']) {
      test(
        '$operation refuses edited later-line quickAction before approval: ${body.replaceAll('\n', r'\n').replaceAll('\r', r'\r')}',
        () async {
          final f = await _Fixture.create();
          addTearDown(f.dispose);
          final proposal = (await f.coordinator.propose(f.call(operation)))!;
          final requests = f.adapter.requests.length;
          final digest = proposal.payloadDigest;
          for (final editedText in [body, body, null]) {
            final outcome = await f.coordinator.approve(
              proposal,
              editedText: editedText,
            );
            expect(outcome.state, AiJournalState.notExecuted);
            expect(outcome.reasonCode, 'quickAction');
            expect(f.adapter.requests, hasLength(requests));
            expect(f.server.writes, 0);
            expect(proposal.payloadDigest, digest);
          }
        },
      );
    }

    test(
      '$operation sends exactly the edited preview including whitespace',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.dispose);
        final proposal = (await f.coordinator.propose(f.call(operation)))!;
        const edited = '  Changed text  \n';
        expect(
          (await f.coordinator.approve(
            proposal,
            editedText: edited,
          )).reasonCode,
          'approvalRequired',
        );
        final shown = (proposal.preview as port.AiFieldsPreview).fields['body'];
        final outcome = await f.coordinator.approve(proposal);
        expect(outcome.state, AiJournalState.succeeded);
        expect(outcome.readbackConfirmed, isTrue);
        expect(f.server.sentBody, shown);
        expect(f.server.writes, 1);
        expect(proposal.editedText, isNull);
      },
    );

    test(
      '$operation identical edits require approval and send shown text once',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.dispose);
        final proposal = (await f.coordinator.propose(f.call(operation)))!;
        final originalDigest = proposal.payloadDigest;
        final requestsAfterProposal = f.adapter.requests.length;

        final first = await f.coordinator.approve(
          proposal,
          editedText: 'First edit',
        );
        expect(first.reasonCode, 'approvalRequired');
        expect(f.adapter.requests.length, requestsAfterProposal);
        expect(f.server.writes, 0);
        expect(proposal.payloadDigest, isNot(originalDigest));

        const edited = 'Updated for @all';
        final firstDigest = proposal.payloadDigest;
        final second = await f.coordinator.approve(
          proposal,
          editedText: edited,
        );
        expect(second.reasonCode, 'approvalRequired');
        expect(f.adapter.requests.length, requestsAfterProposal);
        expect(f.server.writes, 0);
        expect(proposal.payloadDigest, isNot(firstDigest));
        expect(proposal.tier.decision, AiGateDecision.requireApproval);
        expect(
          proposal.tier.reasons,
          contains(AiFixedConfirmReason.massMention),
        );
        final shown =
            (proposal.preview as port.AiFieldsPreview).fields['body'] as String;
        expect(shown, isNot(edited));
        expect(shown, contains('@all'));

        final editedDigest = proposal.payloadDigest;
        final repeated = await f.coordinator.approve(
          proposal,
          editedText: edited,
        );
        expect(repeated.state, AiJournalState.notExecuted);
        expect(repeated.reasonCode, 'approvalRequired');
        expect(proposal.valid, isTrue);
        expect(proposal.editedText, edited);
        expect(proposal.payloadDigest, editedDigest);
        expect(f.adapter.requests, hasLength(requestsAfterProposal));
        expect(f.server.writes, 0);
        expect(f.journal.entries(_account), isEmpty);

        final outcome = await f.coordinator.approve(proposal);
        expect(outcome.state, AiJournalState.succeeded);
        expect(outcome.readbackConfirmed, isTrue);
        expect(outcome.mutationCount, 1);
        expect(f.server.sentBody, shown);
        expect(f.server.writes, 1);
        expect(proposal.editedText, isNull);
        expect(
          f.adapter.requests.where((request) {
            final data = request.data;
            return data is Map &&
                '${data['query']}'.startsWith(
                  'query MobileWorkItemActivityNoteReadback',
                );
          }),
          hasLength(1),
        );
        await f.coordinator.approve(proposal);
        expect(f.server.writes, 1);
      },
    );

    test(
      '$operation blocks a pipeline-rejected edit without sending',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.dispose);
        final proposal = (await f.coordinator.propose(f.call(operation)))!;
        final requestsAfterProposal = f.adapter.requests.length;
        const blocked = 'glpat-ABCDEFGHIJKLMNOPQRST';
        for (final editedText in [blocked, blocked, null]) {
          final edit = await f.coordinator.approve(
            proposal,
            editedText: editedText,
          );
          expect(edit.state, AiJournalState.notExecuted);
          expect(edit.reasonCode, 'secret');
          expect(proposal.valid, isTrue);
          expect(proposal.editedText, blocked);
          expect(f.adapter.requests, hasLength(requestsAfterProposal));
          expect(f.server.writes, 0);
          expect(f.journal.entries(_account), isEmpty);
        }
      },
    );

    test('$operation blocks whitespace-only edits before journaling', () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      final proposal = (await f.coordinator.propose(f.call(operation)))!;
      final originalPreview = proposal.preview;
      final originalDigest = proposal.payloadDigest;
      final requests = f.adapter.requests.length;
      const blocked = '   \n ';
      for (final editedText in [blocked, blocked, null]) {
        final outcome = await f.coordinator.approve(
          proposal,
          editedText: editedText,
        );
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.reasonCode, 'validation');
        expect(proposal.valid, isTrue);
        expect(proposal.editedText, blocked);
        expect(proposal.preview, same(originalPreview));
        expect(proposal.payloadDigest, originalDigest);
        expect(f.adapter.requests, hasLength(requests));
        expect(f.server.writes, 0);
        expect(f.journal.entries(_account), isEmpty);
      }
    });

    test(
      '$operation keeps edited text when independent readback is uncertain',
      () async {
        final f = await _Fixture.create();
        addTearDown(f.dispose);
        final proposal = (await f.coordinator.propose(f.call(operation)))!;
        const edited = 'Retain this edit';
        expect(
          (await f.coordinator.approve(
            proposal,
            editedText: edited,
          )).reasonCode,
          'approvalRequired',
        );
        f.server.wrongReadbackBody = true;
        final outcome = await f.coordinator.approve(proposal);
        expect(outcome.state, AiJournalState.writeUncertain);
        expect(outcome.readbackConfirmed, isFalse);
        expect(f.server.sentBody, edited);
        expect(f.server.writes, 1);
        expect(proposal.editedText, edited);
      },
    );

    final drifts = <(String, void Function(_Server))>[
      (
        'revision',
        (server) => server.workItemUpdatedAt = '2026-10-24T00:00:00Z',
      ),
      if (operation == 'createWorkItemActivityReply') ...[
        ('anchor body', (server) => server.locatedNoteBody = 'changed anchor'),
        (
          'anchor author',
          (server) => server.locatedNoteAuthor = 'gid://gitlab/User/9',
        ),
        (
          'reply ID',
          (server) => server.locatedReplyId =
              'gid://gitlab/IndividualNoteDiscussion/changed',
        ),
      ],
    ];
    for (final drift in drifts) {
      test('$operation edited card rejects ${drift.$1} drift', () async {
        final f = await _Fixture.create();
        addTearDown(f.dispose);
        final proposal = (await f.coordinator.propose(f.call(operation)))!;
        expect(
          (await f.coordinator.approve(
            proposal,
            editedText: 'Changed text',
          )).reasonCode,
          'approvalRequired',
        );
        drift.$2(f.server);
        final outcome = await f.coordinator.approve(proposal);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.reasonCode, 'targetChanged');
        expect(f.server.writes, 0);
        expect(proposal.editedText, 'Changed text');
      });
    }

    test('$operation succeeds only after independent readback', () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      final outcome = await f.commit(operation);
      if (outcome case port.AiWriteNotSent(:final reasonCode)) {
        fail('unexpected not sent: $reasonCode');
      }
      expect(
        outcome,
        isA<port.AiWriteSettled>().having(
          (value) => value.state,
          'state',
          AiJournalState.succeeded,
        ),
      );
      expect(outcome.mutationCount, 1);
      expect(f.server.sentBody, _body);
      expect(f.server.writes, 1);
      expect(
        f.adapter.requests.where((request) {
          final data = request.data;
          return data is Map &&
              '${data['query']}'.startsWith(
                'query MobileWorkItemActivityNoteReadback',
              );
        }),
        hasLength(1),
      );
    });

    for (final drift in <(String, void Function(_Server))>[
      ('body', (server) => server.wrongReadbackBody = true),
      ('author', (server) => server.wrongReadbackAuthor = true),
    ]) {
      test('$operation readback ${drift.$1} mismatch is uncertain', () async {
        final f = await _Fixture.create();
        addTearDown(f.dispose);
        drift.$2(f.server);
        final outcome = await f.commit(operation);
        expect(
          outcome,
          isA<port.AiWriteSettled>().having(
            (value) => value.state,
            'state',
            AiJournalState.writeUncertain,
          ),
        );
        expect(outcome.mutationCount, 1);
        expect(f.server.writes, 1);
      });
    }

    test('$operation rejects model-only GID and extra arguments', () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      for (final extra in [
        {'discussionId': _discussionId},
        {'unexpected': true},
      ]) {
        await expectLater(
          f.writer.prepare(f.request(operation, extra: extra)),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.validation,
            ),
          ),
        );
      }
      expect(f.adapter.requests, isEmpty);
    });
  }

  test(
    'nested continuation parent drift is refused before the wrong target sends',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.server.nested = true;
      f.server.wrongAnchorParent = true;
      final prepared = await f.writer.prepare(
        f.request('createWorkItemActivityReply'),
      );
      var hooks = 0;
      prepared.bindGraphBeforeMutation(() async {
        hooks++;
      });
      final outcome = await f.writer.commit(
        prepared,
        mayStart: () {
          hooks++;
          return true;
        },
      );
      expect(
        outcome,
        isA<port.AiWriteNotSent>().having(
          (value) => value.reasonCode,
          'reason',
          'activityUnverifiable',
        ),
      );
      expect(f.server.replyPreflightAnchor, _anchorId);
      expect(f.server.activityReads, 2);
      expect(f.server.accessReads, 2);
      expect(f.server.writes, 0);
      expect(hooks, 0);
    },
  );

  test(
    'required contract: nested continuation anchor can be replied to safely',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.server.nested = true;
      final outcome = await f.commit('createWorkItemActivityReply');
      expect(
        outcome,
        isA<port.AiWriteSettled>().having(
          (value) => value.state,
          'state',
          AiJournalState.succeeded,
        ),
      );
      expect(f.server.writes, 1);
    },
  );

  test(
    'core paired boundary cancels comment and reply before mutation',
    () async {
      for (final reply in [false, true]) {
        final f = await _Fixture.create();
        var beforeCalls = 0;
        if (reply) {
          final page = await f.api.workItemActivity(_expected);
          final target = page.replyTargetsByDiscussion[_discussionId]!;
          await expectLater(
            f.api.createWorkItemActivityReply(
              target,
              _body,
              beforeMutation: () async => beforeCalls++,
              mayStart: () => false,
            ),
            throwsA(
              isA<ApiFailure>().having(
                (failure) => failure.kind,
                'kind',
                FailureKind.cancelled,
              ),
            ),
          );
        } else {
          final target = (await f.api.workItemActivityWriteAccess(
            _expected,
          )).commentTarget!;
          await expectLater(
            f.api.createWorkItemActivityComment(
              target,
              _body,
              beforeMutation: () async => beforeCalls++,
              mayStart: () => false,
            ),
            throwsA(
              isA<ApiFailure>().having(
                (failure) => failure.kind,
                'kind',
                FailureKind.cancelled,
              ),
            ),
          );
        }
        expect(beforeCalls, 1);
        expect(f.server.writes, 0);
        await f.dispose();
      }
    },
  );

  test('reply refuses a third locator read without sending', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.server.needThirdRead = true;
    await expectLater(
      f.writer.prepare(f.request('createWorkItemActivityReply')),
      throwsA(_refusal('activityUnverifiable')),
    );
    expect(f.server.activityReads, 2);
    expect(f.server.writes, 0);
  });

  test(
    'detected unsupported controls refuse without a legacy reread',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.server.unsupportedControlsOnce = true;
      await expectLater(
        f.writer.prepare(f.request('createWorkItemActivityReply')),
        throwsA(_refusal('activityUnverifiable')),
      );
      expect(f.server.activityReads, 1);
      expect(f.server.writes, 0);
    },
  );

  test(
    'pre-set unsupported-controls cache refuses before activity read',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.server.unsupportedControlsOnce = true;
      final detail = await f.api.projectWorkItem(
        Project.fromJson(projectJson(9)),
        3,
      );
      await f.api.workItemActivity(detail.summary);
      expect(f.server.activityReads, 2);
      await expectLater(
        f.writer.prepare(f.request('createWorkItemActivityReply')),
        throwsA(_refusal('activityUnverifiable')),
      );
      expect(f.server.activityReads, 2);
      expect(f.server.writes, 0);
    },
  );

  test(
    'required contract: cached unsupported controls also refuse P9a',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.server.unsupportedControlsOnce = true;
      final detail = await f.api.projectWorkItem(
        Project.fromJson(projectJson(9)),
        3,
      );
      await f.api.workItemActivity(detail.summary);
      await expectLater(
        f.writer.prepare(f.request('createWorkItemActivityComment')),
        throwsA(_refusal('activityUnverifiable')),
      );
    },
  );

  for (final entry in <(String, String, void Function(_Server))>[
    ('forbidden', 'createWorkItemActivityComment', (s) => s.allowed = false),
    ('locked', 'createWorkItemActivityComment', (s) => s.locked = true),
    (
      'creator drift',
      'createWorkItemActivityComment',
      (s) => s.actorDriftsOnFreshPreflight = true,
    ),
    (
      'creator drift',
      'createWorkItemActivityReply',
      (s) => s.actorDriftsOnFreshPreflight = true,
    ),
    (
      'parent drift',
      'createWorkItemActivityReply',
      (s) => s.wrongAnchorParent = true,
    ),
  ]) {
    test('fresh ${entry.$1} preflight refuses before send', () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      entry.$3(f.server);
      if (entry.$1 == 'forbidden' || entry.$1 == 'locked') {
        await expectLater(
          f.writer.prepare(f.request(entry.$2)),
          throwsA(isA<port.AiWriteRefused>()),
        );
      } else {
        var hooks = 0;
        final prepared = await f.writer.prepare(f.request(entry.$2));
        prepared.bindGraphBeforeMutation(() async {
          hooks++;
        });
        final outcome = await f.writer.commit(prepared, mayStart: () => true);
        expect(outcome, isA<port.AiWriteNotSent>());
        if (entry.$2 == 'createWorkItemActivityReply') {
          expect(hooks, 0, reason: 'a drifted actor must not reach a mutation');
        }
      }
      expect(f.server.writes, 0);
    });
  }

  test(
    'REST identity and project identity drift refuse during prepare',
    () async {
      for (final mutate in <void Function(_Server)>[
        (server) => server.restUser = 8,
        (server) => server.wrongDetailProject = true,
        (server) => server.wrongAccessProject = true,
      ]) {
        final f = await _Fixture.create();
        mutate(f.server);
        await expectLater(
          f.writer.prepare(f.request('createWorkItemActivityComment')),
          throwsA(_refusal('activityUnverifiable')),
        );
        expect(f.server.writes, 0);
        await f.dispose();
      }
    },
  );

  test(
    'every requested anchor tuple component binds the dispatch digest',
    () async {
      final anchorDrifts = <void Function(_Server)>[
        (server) =>
            server.locatedDiscussionId = 'gid://gitlab/Discussion/drift',
        (server) => server.locatedReplyId =
            'gid://gitlab/IndividualNoteDiscussion/drift',
        (server) => server.locatedDiscussionCreatedAt = '2026-10-01T01:00:01Z',
        (server) => server.locatedNoteCreatedAt = '2026-10-01T01:02:04Z',
        (server) => server.locatedNoteUpdatedAt = '2026-10-01T01:03:05Z',
        (server) => server.locatedNoteBody = 'Anchor drift',
        (server) => server.locatedNoteAuthor = 'gid://gitlab/User/9',
      ];
      for (final operation in [
        'createWorkItemActivityComment',
        'createWorkItemActivityReply',
      ]) {
        final stable = await _Fixture.create();
        final baseline = await stable.writer.prepare(stable.request(operation));
        final drifts = operation == 'createWorkItemActivityComment'
            ? <void Function(_Server)>[
                (server) => server.workItemUpdatedAt = '2026-10-24T00:00:00Z',
              ]
            : <void Function(_Server)>[
                (server) => server.workItemUpdatedAt = '2026-10-24T00:00:00Z',
                ...anchorDrifts,
              ];
        for (final drift in drifts) {
          final drifted = await _Fixture.create();
          drift(drifted.server);
          final prepared = await drifted.writer.prepare(
            drifted.request(operation),
          );
          expect(
            prepared.bindingDigest,
            isNot(baseline.bindingDigest),
            reason: '$operation digest must drift',
          );
          await drifted.dispose();
        }
        await stable.dispose();
      }

      final noteStable = await _Fixture.create();
      final noteBaseline = await noteStable.writer.prepare(
        noteStable.request('createWorkItemActivityReply'),
      );
      await noteStable.dispose();
      final noteDrift = await _Fixture.create();
      noteDrift.server.locatedNoteId = 'gid://gitlab/Note/402';
      final prepared = await noteDrift.writer.prepare(
        noteDrift.request(
          'createWorkItemActivityReply',
          extra: {'anchorNoteId': 402},
        ),
      );
      expect(prepared.bindingDigest, isNot(noteBaseline.bindingDigest));
      await noteDrift.dispose();
    },
  );

  test(
    'prepared conflict keys pin the work item and the anchor note',
    () async {
      final comment = await _Fixture.create();
      final commentPrepared = await comment.writer.prepare(
        comment.request('createWorkItemActivityComment'),
      );
      expect(commentPrepared.writeKeys.map((key) => key.parts), {
        [_account, 'project:9', 'workItem', '3'],
      });
      await comment.dispose();

      final reply = await _Fixture.create();
      final replyPrepared = await reply.writer.prepare(
        reply.request('createWorkItemActivityReply'),
      );
      expect(replyPrepared.writeKeys.map((key) => key.parts), {
        [_account, 'project:9', 'workItem', '3'],
        [_account, 'project:9', 'workItem', '3', 'note', '401'],
      });
      await reply.dispose();
    },
  );

  test('stable Graph actor mismatch is rejected before send', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    f.server.wrongActor = true;
    await expectLater(
      f.writer.prepare(f.request('createWorkItemActivityComment')),
      throwsA(_refusal('activityUnverifiable')),
    );
    expect(f.server.accessReads, 1);
    expect(f.server.writes, 0);
  });

  for (final oauth in [false, true]) {
    test(
      'independent F/P/Mpre/Mrb count fits ${oauth ? 'OAuth' : 'PAT'} caps',
      () async {
        for (final entry in <(String, int, int)>[
          ('createWorkItemActivityComment', 11, 21),
          ('createWorkItemActivityReply', 15, 29),
        ]) {
          final f = await _Fixture.create(oauth: oauth);
          if (entry.$1 == 'createWorkItemActivityReply') {
            f.server.outerSecondPage = true;
          }
          port.AiWritePrepared? dispatch;
          for (var pass = 0; pass < 2; pass++) {
            await f.api.record(['projects', '9']);
            final prepared = await f.writer.prepare(f.request(entry.$1));
            if (pass == 1) dispatch = prepared;
          }
          dispatch!.bindGraphBeforeMutation(() async {});
          final outcome = await f.writer.commit(dispatch, mayStart: () => true);
          expect(outcome, isA<port.AiWriteSettled>());
          expect(f.server.writes, 1);
          expect(
            f.adapter.requests.length,
            oauth ? entry.$3 : entry.$2,
            reason: entry.$1,
          );
          await f.dispose();
        }
      },
    );
  }

  test(
    'detected unsupported controls refuse comments in the access read',
    () async {
      final f = await _Fixture.create();
      addTearDown(f.dispose);
      f.server.unsupportedControlsOnce = true;
      await expectLater(
        f.writer.prepare(f.request('createWorkItemActivityComment')),
        throwsA(_refusal('activityUnverifiable')),
      );
      expect(f.server.activityReads, 0);
      expect(f.server.accessReads, 1);
      expect(f.server.writes, 0);
    },
  );

  test('coordinator uses visible clones and encrypted journal', () async {
    final f = await _Fixture.create();
    addTearDown(f.dispose);
    expect(f.coordinator.specs.map((spec) => spec.name), {
      'createWorkItemActivityComment',
      'createWorkItemActivityReply',
    });
    final call = f.call('createWorkItemActivityComment');
    final proposal = await f.coordinator.propose(call);
    expect(proposal, isNotNull);
    expect(proposal!.tier.tier, AiWriteTier.t2);
    expect(f.server.writes, 0);
    final outcome = await f.coordinator.approve(proposal);
    expect(outcome.state, AiJournalState.succeeded);
    final bytes = File(f.files.pathFor(_account)).readAsBytesSync();
    expect(String.fromCharCodes(bytes), isNot(contains(_body)));
  });

  test('cap minus one refuses before port reads for both rows', () async {
    for (final entry in [
      ('createWorkItemActivityComment', 21),
      ('createWorkItemActivityReply', 29),
    ]) {
      final f = await _Fixture.create(maxRequests: entry.$2 - 1);
      final call = f.call(entry.$1);
      final proposal = await f.coordinator.propose(call);
      expect(proposal, isNull, reason: entry.$1);
      expect(
        f.coordinator.outcomeFor(call.id)?.reasonCode,
        'httpBudgetExceeded',
        reason: entry.$1,
      );
      expect(f.adapter.requests, isEmpty);
      await f.dispose();
    }
  });

  test(
    'class-A body, placeholder and upload provenance are checked by coordinator',
    () async {
      for (final entry in [
        ('glpat-ABCDEFGHIJKLMNOPQRST', 'secret'),
        ('[REDACTED]', 'redactionMarker'),
        (
          'see uploads/0123456789abcdef0123456789abcdef/shot.png inline',
          'rawUpload',
        ),
        ('[[attachment:att-9]]', 'attachmentNotUploaded'),
        ('[[upload:u-1]]', 'rereadField'),
      ]) {
        final f = await _Fixture.create();
        final call = f.call(
          'createWorkItemActivityComment',
          extra: {'body': entry.$1},
        );
        expect(await f.coordinator.propose(call), isNull, reason: entry.$1);
        expect(
          f.coordinator.outcomeFor(call.id)?.reasonCode,
          entry.$2,
          reason: entry.$1,
        );
        expect(f.server.writes, 0, reason: entry.$1);
        await f.dispose();
      }
    },
  );
}
