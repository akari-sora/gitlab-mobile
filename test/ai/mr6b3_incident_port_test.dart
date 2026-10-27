import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart' as coord;
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_support.dart' show Mr6b3JournalFiles;

const _account = 'https://example.com/gitlab#7';
const _path = 'team/example-9';
const _operation = 'setIncidentStatus';
const _rawRevision = '2026-10-23T00:00:00Z';
const _incidentId = 'gid://gitlab/Issue/31';
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
const _key = AiConflictKey([_account, 'project:9', 'workItem', '3']);
const _limit = Duration(seconds: 20);

port.AiWriteRequest _request({
  Object? status = 'ACKNOWLEDGED',
  AiWriteScope scope = _scope,
  Map<String, Object?> extra = const {},
}) => port.AiWriteRequest(
  operationId: _operation,
  executionId: 'p12-direct',
  scope: scope,
  arguments: {'projectId': 9, 'iid': 3, 'status': status, ...extra},
);

Matcher _refused(String reason) => isA<port.AiWriteRefused>().having(
  (failure) => failure.reason,
  'reason',
  reason,
);

Matcher _apiFailure(FailureKind kind) =>
    isA<ApiFailure>().having((failure) => failure.kind, 'kind', kind);

void main() {
  test('P12 visible T2 graph row has closed args and static cap 21', () {
    final row = aiGraphqlIncidentRows.single;
    expect(productionAiLedger.find(_operation), same(row));
    expect(row.namedMethod, _operation);
    expect(row.baseTier, AiWriteTier.t2);
    expect(row.scopeClass, AiScopeClass.workItem);
    expect(row.boundary, AiWriteBoundary.graph);
    expect(row.modelVisible, isTrue);
    expect(productionAiLedger.modelVisible, contains(row));
    expect(row.readback, isTrue);
    expect(row.arguments.keys.toSet(), {'projectId', 'iid', 'status'});
    expect(row.arguments.values.every((arg) => arg.required), isTrue);
    expect(row.arguments['projectId']!.type, AiArgType.integer);
    expect(row.arguments['iid']!.type, AiArgType.integer);
    expect(row.arguments['status']!.enumValues, [
      'TRIGGERED',
      'ACKNOWLEDGED',
      'RESOLVED',
    ]);
    // Count independently of the row, including controller freshness twice.
    const reads = 2 * (1 + 1 + 1 + 1) + 1 + 1;
    expect(reads, 10);
    expect(row.httpCap, 2 * reads + 1);
    expect(coord.aiWriteRequestAllowance(_operation), 21);
    expect(coord.aiWriteRequestAllowance(_operation, oauthReplay: false), 11);
  });

  for (final status in ['TRIGGERED', 'ACKNOWLEDGED', 'RESOLVED']) {
    test(
      'P12 $status succeeds only after exact independent readback',
      () async {
        final server = _Server()
          ..status = status == 'TRIGGERED' ? 'RESOLVED' : 'TRIGGERED';
        addTearDown(server.api.close);
        final writer = server.writer;
        final prepared = await writer.prepare(_request(status: status));
        expect(prepared.boundary, AiWriteBoundary.graph);
        expect(prepared.projectPath, _path);
        expect(prepared.releaseName, '#3');
        expect(prepared.writeKeys, {_key});
        expect(prepared.dependencyKeys, isEmpty);
        expect(prepared.bindingTargets.single.projectId, 9);
        expect(prepared.bindingTargets.single.iid, 3);
        expect(prepared.bindingDigest, matches(r'^[a-f0-9]{64}$'));
        expect(prepared.journal.updatedAt, _rawRevision);
        expect((prepared.preview as port.AiFieldsPreview).fields, {
          'status': status,
        });
        var hooks = 0;
        prepared.bindGraphBeforeMutation(() async {
          hooks++;
        });
        final outcome =
            await writer.commit(prepared, mayStart: () => true)
                as port.AiWriteSettled;
        expect(outcome.state, AiJournalState.succeeded);
        expect(outcome.readbackVerified, isTrue);
        expect(outcome.projection, {'status': status});
        expect(hooks, 1);
        expect(server.incidentReads, 3);
        expect(server.mutations, 1);
        expect(server.kinds, [
          'user',
          'workItem',
          'incident',
          'incident',
          'mutation',
          'incident',
        ]);
        final mutation = server.adapter.requests.singleWhere(
          (request) => _kind(request) == 'mutation',
        );
        expect(mutation.uri.path, '/gitlab/api/graphql');
        expect(mutation.followRedirects, isFalse);
        expect((mutation.data as Map)['variables'], {
          'input': {'projectPath': _path, 'iid': '3', 'status': status},
        });
        expect(
          await writer.commit(prepared, mayStart: () => true),
          isA<port.AiWriteNotSent>(),
        );
        expect(server.mutations, 1);
      },
    );
  }

  for (final status in <Object?>[
    'IGNORED',
    'acknowledged',
    'ACKNOWLEDGED ',
    '',
    null,
    true,
    1,
  ]) {
    test('P12 invalid status $status refuses before network', () async {
      final server = _Server();
      addTearDown(server.api.close);
      await expectLater(
        server.writer.prepare(_request(status: status)),
        throwsA(_refused('incidentInvalidStatus')),
      );
      expect(server.adapter.requests, isEmpty);
    });
  }

  for (final field in [
    'expectedUpdatedAt',
    'incidentUpdatedAt',
    'workItemGid',
    'groupId',
    'confirmName',
    'body',
  ]) {
    test('P12 rejects model-supplied $field before network', () async {
      final server = _Server();
      addTearDown(server.api.close);
      await expectLater(
        server.writer.prepare(_request(extra: {field: 'fake'})),
        throwsA(_apiFailure(FailureKind.validation)),
      );
      expect(server.adapter.requests, isEmpty);
    });
  }

  test('P12 noop never calls either hook or sends a mutation', () async {
    final server = _Server()..status = 'ACKNOWLEDGED';
    addTearDown(server.api.close);
    final writer = server.writer;
    final prepared = await writer.prepare(_request());
    prepared.bindGraphBeforeMutation(() async => fail('noop called hook'));
    expect(
      await writer.commit(prepared, mayStart: () => fail('noop accepted')),
      isA<port.AiGraphNoChange>(),
    );
    expect(server.incidentReads, 2);
    expect(server.mutations, 0);
  });

  test(
    'P12 raw revision differs from same-instant reformatted preflight',
    () async {
      final server = _Server();
      addTearDown(server.api.close);
      final writer = server.writer;
      final prepared = await writer.prepare(_request());
      server.revision = DateTime.parse(_rawRevision).toIso8601String();
      expect(server.revision, isNot(_rawRevision));
      expect(DateTime.parse(server.revision), DateTime.parse(_rawRevision));
      prepared.bindGraphBeforeMutation(
        () async => fail('conflict called hook'),
      );
      final outcome =
          await writer.commit(prepared, mayStart: () => true)
              as port.AiWriteNotSent;
      expect(outcome.reasonCode, 'incidentConflict');
      expect(server.mutations, 0);
    },
  );

  test(
    'P12 digest includes the exact incident revision, not Work Item time',
    () async {
      final server = _Server();
      addTearDown(server.api.close);
      final writer = server.writer;
      final before = await writer.prepare(_request());
      server.revision = DateTime.parse(_rawRevision).toIso8601String();
      final after = await writer.prepare(_request());
      expect(after.bindingDigest, isNot(before.bindingDigest));
      expect(after.journal.updatedAt, server.revision);
    },
  );

  for (final drift in ['actor', 'project', 'iid', 'group', 'grant']) {
    test('P12 refuses foreign $drift with zero mutations', () async {
      final server = _Server();
      addTearDown(server.api.close);
      switch (drift) {
        case 'actor':
          server.actorId = 8;
        case 'project':
          server.workItemProjectId = 10;
        case 'iid':
          server.workItemIid = 4;
        case 'group':
          server.groupWorkItem = true;
        case 'grant':
          break;
      }
      final request = _request(
        scope: drift == 'grant'
            ? const AiWriteScope(
                accountKey: _account,
                grants: [
                  AiScopeGrant(
                    kind: AiScopeKind.groupWorkItem,
                    groupId: 2,
                    groupFullPath: 'team',
                    iid: 3,
                  ),
                ],
              )
            : _scope,
      );
      await expectLater(
        server.writer.prepare(request),
        throwsA(isA<Exception>()),
      );
      expect(server.mutations, 0);
      expect(server.kinds, isNot(contains('incident')));
      if (drift == 'grant') expect(server.adapter.requests, isEmpty);
    });
  }

  for (final mode in [
    'payloadErrors',
    'mutation401',
    'mutation403',
    'mutation500',
    'malformed',
    'ackId',
    'ackStatus',
    'readbackId',
    'readbackStatus',
    'readback401',
    'readback500',
  ]) {
    test(
      'P12 accepted $mode is uncertain, isolated, and never replayed',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        final proposal = (await h.propose())!;
        h.server.mode = mode;
        h.server.onMutation = () {
          expect(
            h.journal.entries(_account).single.state,
            AiJournalState.dispatching,
          );
        };
        final outcome = await h.approve(proposal);
        expect(outcome.state, AiJournalState.writeUncertain);
        expect(outcome.mutationCount, 1);
        expect(h.server.mutations, 1);
        expect(
          h.journal.entries(_account).single.state,
          AiJournalState.writeUncertain,
        );
        expect(h.journal.isolated(_account, {_key}), isTrue);
        expect(await h.propose(id: 'after-uncertain'), isNull);
        expect(h.server.mutations, 1);
      },
    );
  }

  for (final revision in ['2026-10-23T00:00:00.000Z', '2026-10-23T00:00:01Z']) {
    test(
      'P12 dispatch revision $revision invalidates proposal via digest',
      () async {
        final h = await _Harness.create();
        addTearDown(h.dispose);
        final proposal = (await h.propose())!;
        h.server.revision = revision;
        final outcome = await h.approve(proposal);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(outcome.reasonCode, 'targetChanged');
        expect(outcome.mutationCount, 0);
        expect(h.server.incidentReads, 2);
        expect(h.server.mutations, 0);
        expect(h.journal.isolated(_account, {_key}), isFalse);
      },
    );
  }

  test(
    'P12 T2 waits for approval and persists dispatching before mutation',
    () async {
      final h = await _Harness.create(level: AiAutonomyLevel.lowRiskAuto);
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      expect(proposal.tier.tier, AiWriteTier.t2);
      expect(proposal.tier.decision.name, 'requireApproval');
      expect(h.server.mutations, 0);
      expect(h.journal.entries(_account), isEmpty);
      h.server.onMutation = () {
        expect(
          h.journal.entries(_account).single.state,
          AiJournalState.dispatching,
        );
      };
      final outcome = await h.approve(proposal);
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.readbackConfirmed, isTrue);
      expect(
        h.journal.entries(_account).single.state,
        AiJournalState.succeeded,
      );
    },
  );

  for (final message in [
    'Do not acknowledge issue #3 in team/example-9.',
    'If approved, acknowledge issue #3 in team/example-9.',
    '"Acknowledge issue #3 in team/example-9."',
    'Acknowledge issue #4 in team/example-10.',
  ]) {
    test('P12 lowRiskAuto keeps ambiguous or foreign intent approval-gated: '
        '$message', () async {
      final h = await _Harness.create(level: AiAutonomyLevel.lowRiskAuto);
      addTearDown(h.dispose);
      h.coordinator.beginRun(message);
      h.coordinator.beginTurn();
      final proposal = (await h.propose())!;
      expect(proposal.tier.decision.name, 'requireApproval');
      expect(h.server.mutations, 0);
    });
  }

  test(
    'P12 production ledger offers the operation and holds it for approval',
    () async {
      final h = await _Harness.create(ledger: productionAiLedger);
      addTearDown(h.dispose);
      final proposal = await h.propose();
      expect(proposal, isNotNull);
      expect(proposal!.tier.decision.name, 'requireApproval');
      expect(h.server.mutations, 0);
    },
  );

  test(
    'P12 coordinator noop refunds write hold and continues same round',
    () async {
      // Two full 21-request reservations isolate continuation from the
      // production 40-request boundary, which is checked separately below.
      final h = await _Harness.create(maxRequests: 42);
      addTearDown(h.dispose);
      h.server.status = 'ACKNOWLEDGED';
      final noop = await h.approve((await h.propose())!);
      expect(noop.state, AiJournalState.succeeded);
      expect(noop.noChange, isTrue);
      expect(noop.mutationCount, 0);
      expect(
        h.journal.entries(_account).single.state,
        AiJournalState.notExecuted,
      );
      expect(h.journal.conversationWriteCount(_account, 'p12'), 0);
      expect(h.journal.isolated(_account, {_key}), isFalse);
      final next = (await h.propose(status: 'RESOLVED', id: 'after-noop'))!;
      expect((await h.approve(next)).state, AiJournalState.succeeded);
      expect(h.server.mutations, 1);
      expect(h.journal.conversationWriteCount(_account, 'p12'), 1);
    },
  );

  test('P12 method preflight failure is notExecuted and unlocked', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final proposal = (await h.propose())!;
    h.server.failIncidentRead = 3;
    final outcome = await h.approve(proposal);
    expect(outcome.state, AiJournalState.notExecuted);
    expect(outcome.reasonCode, 'incidentRejected');
    expect(outcome.mutationCount, 0);
    expect(h.server.mutations, 0);
    expect(
      h.journal.entries(_account).single.state,
      AiJournalState.notExecuted,
    );
    expect(h.journal.isolated(_account, {_key}), isFalse);
  });

  test('P12 beforeMutation flush failure prevents the mutation', () async {
    final h = await _Harness.create();
    addTearDown(h.dispose);
    final proposal = (await h.propose())!;
    h.files.failWriteNumber = h.files.writeCount + 2;
    final outcome = await h.approve(proposal);
    expect(outcome.state, AiJournalState.notExecuted);
    expect(h.server.mutations, 0);
    expect(
      h.journal.entries(_account).single.state,
      isNot(AiJournalState.succeeded),
    );
  });

  test('P12 mayStart false prevents mutation after successful hook', () async {
    final server = _Server();
    addTearDown(server.api.close);
    final writer = server.writer;
    final prepared = await writer.prepare(_request());
    var hooks = 0;
    prepared.bindGraphBeforeMutation(() async {
      hooks++;
    });
    expect(
      await writer.commit(prepared, mayStart: () => false),
      isA<port.AiWriteNotSent>(),
    );
    expect(hooks, 1);
    expect(server.mutations, 0);
  });

  test('P12 cap minus one refuses before any read', () async {
    final h = await _Harness.create(maxRequests: 20);
    addTearDown(h.dispose);
    expect(await h.propose(), isNull);
    expect(
      h.coordinator.outcomeFor('p12-call')!.reasonCode,
      'httpBudgetExceeded',
    );
    expect(h.server.adapter.requests, isEmpty);
    expect(h.budget.gitLabRequests, 0);
  });

  for (final boundary in [39, 40, 41]) {
    test('P12 shared 40-request reservation boundary $boundary', () async {
      final h = await _Harness.create();
      addTearDown(h.dispose);
      expect(h.budget.reserve(requests: boundary - 21, search: false), isNull);
      final proposal = await h.propose();
      if (boundary <= 40) {
        expect(proposal, isNotNull);
        expect(h.budget.gitLabRequests, boundary);
        expect((await h.approve(proposal!)).state, AiJournalState.succeeded);
        expect(h.server.mutations, 1);
      } else {
        expect(proposal, isNull);
        expect(
          h.coordinator.outcomeFor('p12-call')!.reasonCode,
          'httpBudgetExceeded',
        );
        expect(h.server.adapter.requests, isEmpty);
      }
    });
  }

  for (final oauth in [false, true]) {
    test(
      'P12 independent HTTP counter proves L10/cap21, OAuth=$oauth',
      () async {
        final h = await _Harness.create(oauth: oauth, maxRequests: 21);
        addTearDown(h.dispose);
        final outcome = await h.approve((await h.propose())!);
        expect(outcome.state, AiJournalState.succeeded);
        expect(outcome.readbackConfirmed, isTrue);
        expect(h.server.successfulReads, 10);
        expect(
          h.server.kinds.where((kind) => kind == 'project'),
          hasLength(oauth ? 4 : 2),
        );
        expect(
          h.server.kinds.where((kind) => kind == 'user'),
          hasLength(oauth ? 4 : 2),
        );
        expect(
          h.server.kinds.where((kind) => kind == 'workItem'),
          hasLength(oauth ? 4 : 2),
        );
        expect(h.server.incidentReads, 4);
        expect(h.server.mutations, 1);
        expect(h.server.resourceRequests, oauth ? 21 : 11);
        expect(h.server.refreshes, oauth ? 10 : 0);
        expect(h.budget.gitLabRequests, 21);
      },
    );
  }

  test(
    'P12 OAuth mutation 401 does not replay or claim certain failure',
    () async {
      final h = await _Harness.create(oauth: true);
      addTearDown(h.dispose);
      final proposal = (await h.propose())!;
      h.server.mode = 'mutation401';
      expect((await h.approve(proposal)).state, AiJournalState.writeUncertain);
      expect(h.server.mutations, 1);
      // The API can refresh credentials after a mutation 401, but the
      // mutation itself is never replayed and no readback is attempted.
      expect(h.server.refreshes, 10);
      expect(h.server.resourceRequests, 19);
    },
  );
}

// Only this family's production row is exposed by the test ledger. Its
// boundary, enum and cap are copied intact; production visibility is unchanged.
final class _VisibleIncident implements AiCapabilityLedger {
  const _VisibleIncident();

  @override
  AiCapability? find(String operationId) {
    if (operationId != _operation) return null;
    final row = productionAiLedger.find(operationId)!;
    return AiCapability(
      operationId: row.operationId,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      namedMethod: row.namedMethod,
      boundary: row.boundary,
      arguments: row.arguments,
      httpCap: row.httpCap,
      readback: row.readback,
    );
  }

  @override
  List<AiCapability> get modelVisible => [find(_operation)!];
}

String _kind(RequestOptions request) {
  if (request.uri.path.endsWith('/oauth/token')) return 'refresh';
  if (request.method == 'GET' && request.uri.path.endsWith('/user')) {
    return 'user';
  }
  if (request.method == 'GET' && request.uri.path.endsWith('/projects/9')) {
    return 'project';
  }
  if (request.uri.path == '/gitlab/api/graphql' && request.data is Map) {
    final query = (request.data as Map)['query'] as String;
    if (query.startsWith('mutation MobileSetIncidentStatus')) return 'mutation';
    if (query.contains('query MobileIncidentStatus')) return 'incident';
    if (query.contains('query MobileProjectWorkItem(')) return 'workItem';
  }
  fail('unexpected synthetic endpoint: ${request.method} ${request.uri.path}');
}

final class _Server {
  _Server({this.oauth = false}) {
    adapter = FakeAdapter(respond);
    if (!oauth) {
      api = testApi(adapter);
    } else {
      final dio = Dio()..httpClientAdapter = adapter;
      final instance = GitLabInstance.parse('https://example.com/gitlab');
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
        onOAuthRotated: (_) async {},
      );
    }
  }

  final bool oauth;
  late final FakeAdapter adapter;
  late final GitLabApi api;
  String status = 'TRIGGERED';
  String revision = _rawRevision;
  String mode = '';
  int actorId = 7;
  int workItemProjectId = 9;
  int workItemIid = 3;
  bool groupWorkItem = false;
  int? failIncidentRead;
  int incidentReads = 0;
  int mutations = 0;
  int successfulReads = 0;
  int _readAttempts = 0;
  void Function()? onMutation;

  port.GitLabAiWritePort get writer =>
      port.GitLabAiWritePort(api, accountKey: _account);

  List<String> get kinds => adapter.requests.map(_kind).toList();
  int get refreshes => kinds.where((kind) => kind == 'refresh').length;
  int get resourceRequests => kinds.where((kind) => kind != 'refresh').length;

  Map<String, Object?> incident({String? id, String? escalationStatus}) => {
    'id': id ?? _incidentId,
    'iid': '3',
    'projectId': 9,
    'state': 'opened',
    'severity': 'HIGH',
    'escalationStatus': escalationStatus ?? status,
    'updatedAt': revision,
  };

  ResponseBody respond(RequestOptions request) {
    final kind = _kind(request);
    if (kind == 'refresh') {
      return jsonResponse({
        'access_token': 'synthetic-access-$refreshes',
        'refresh_token': 'synthetic-refresh',
        'token_type': 'bearer',
        'expires_in': 7200,
      });
    }
    if (kind != 'mutation') {
      _readAttempts++;
      if (oauth && _readAttempts.isOdd) return jsonResponse({}, status: 401);
      successfulReads++;
    }
    switch (kind) {
      case 'user':
        return jsonResponse({
          'id': actorId,
          'username': 'synthetic-user',
          'name': 'Synthetic User',
        });
      case 'project':
        return jsonResponse(projectJson(9));
      case 'workItem':
        return jsonResponse({
          'data': {
            'project': {
              'id': 'gid://gitlab/Project/9',
              'fullPath': _path,
              'workItems': {
                'nodes': [
                  {
                    'id': 'gid://gitlab/WorkItem/31',
                    'iid': '$workItemIid',
                    'title': 'Synthetic Incident',
                    'state': 'OPEN',
                    'createdAt': '2026-01-01T00:00:00Z',
                    // Deliberately unrelated to the incident's own revision.
                    'updatedAt': '2026-10-01T12:00:00Z',
                    'project': groupWorkItem
                        ? null
                        : {
                            'id': 'gid://gitlab/Project/$workItemProjectId',
                            'fullPath': _path,
                          },
                    'namespace': {
                      'id': 'gid://gitlab/Group/2',
                      'fullPath': 'team',
                    },
                    'workItemType': {
                      'id': 'gid://gitlab/WorkItems::Type/1',
                      'name': 'Incident',
                    },
                    'widgets': <Object?>[],
                  },
                ],
                'pageInfo': {'hasNextPage': false},
              },
            },
          },
        });
      case 'incident':
        incidentReads++;
        if (incidentReads == failIncidentRead ||
            (mutations > 0 && mode == 'readback500')) {
          return jsonResponse({}, status: 500);
        }
        if (mutations > 0 && mode == 'readback401') {
          return jsonResponse({}, status: 401);
        }
        return jsonResponse({
          'data': {
            'project': {
              'id': 'gid://gitlab/Project/9',
              'issues': {
                'nodes': [
                  incident(
                    id: mutations > 0 && mode == 'readbackId'
                        ? 'gid://gitlab/Issue/99'
                        : null,
                    escalationStatus: mutations > 0 && mode == 'readbackStatus'
                        ? 'RESOLVED'
                        : null,
                  ),
                ],
                'pageInfo': {'hasNextPage': false},
              },
            },
          },
        });
      case 'mutation':
        mutations++;
        onMutation?.call();
        final variables = (request.data as Map)['variables'] as Map;
        final input = variables['input'] as Map;
        expect(input.keys.toSet(), {'projectPath', 'iid', 'status'});
        expect(input['projectPath'], _path);
        expect(input['iid'], '3');
        status = input['status'] as String;
        if (mode.startsWith('mutation')) {
          return jsonResponse({}, status: int.parse(mode.substring(8)));
        }
        if (mode == 'malformed') {
          return jsonResponse({'data': <String, Object?>{}});
        }
        return jsonResponse({
          'data': {
            'issueSetEscalationStatus': {
              'errors': mode == 'payloadErrors'
                  ? ['synthetic rejection']
                  : <String>[],
              'issue': incident(
                id: mode == 'ackId' ? 'gid://gitlab/Issue/99' : null,
                escalationStatus: mode == 'ackStatus' ? 'RESOLVED' : null,
              ),
            },
          },
        });
      default:
        fail('unexpected synthetic request kind $kind');
    }
  }
}

final class _Harness {
  _Harness._(this.server, this.root, this.files, this.journal, this.budget);

  static Future<_Harness> create({
    bool oauth = false,
    int maxRequests = 40,
    AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
    AiCapabilityLedger ledger = const _VisibleIncident(),
  }) async {
    final root = Directory.systemTemp.createTempSync('p12-incident-');
    final files = Mr6b3JournalFiles(root);
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      files: files,
      processId: 'p12',
    );
    await journal.recoverAfterAccountsLoaded([_account]);
    await journal.ensureInitialized(_account);
    final h = _Harness._(
      _Server(oauth: oauth),
      root,
      files,
      journal,
      AiToolBudget(maxGitLabRequests: maxRequests),
    );
    h.coordinator = coord.PolicyAiWriteCoordinator(
      snapshot: () => coord.AiWritePolicySnapshot(
        appInForeground: true,
        scope: _scope,
        level: level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'synthetic-p12-consent',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
      ),
      createPort: () => h.server.writer,
      journal: journal,
      conversationId: 'p12',
      budget: () => h.budget,
      readFreshness: (_) async {
        await h.server.api.record(['projects', '9']);
        return const coord.AiWriteFreshness(
          updatedAt: '2026-10-01T00:00:00Z',
          visibilityUnreadable: false,
        );
      },
      placeholders: text.UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: ledger,
    );
    h.coordinator.beginRun('Acknowledge issue #3 in team/example-9.');
    h.coordinator.beginTurn();
    return h;
  }

  final _Server server;
  final Directory root;
  final Mr6b3JournalFiles files;
  final AiWriteJournal journal;
  final AiToolBudget budget;
  late final coord.PolicyAiWriteCoordinator coordinator;

  Future<coord.AiWriteProposal?> propose({
    String status = 'ACKNOWLEDGED',
    String id = 'p12-call',
  }) => coordinator
      .propose(
        AiToolCall(
          id: id,
          name: _operation,
          arguments: {
            'projectId': 9,
            'iid': 3,
            'status': status,
            'reason': 'synthetic request',
          },
        ),
      )
      .timeout(_limit);

  Future<coord.AiWriteOutcome> approve(coord.AiWriteProposal proposal) =>
      coordinator
          .approve(proposal, typedName: proposal.tier.typedName)
          .timeout(_limit);

  void dispose() {
    files.releaseBarrier();
    coordinator.stop('disposed');
    server.api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}
