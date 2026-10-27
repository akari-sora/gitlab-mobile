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
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_support.dart';

const _op = 'updateWorkItemLabels';
const _item = 'gid://gitlab/WorkItem/31';
int _execution = 0;
const _project = {'id': 'gid://gitlab/Project/9', 'fullPath': 'team/example-9'};
const _namespace = {
  'id': 'gid://gitlab/Namespaces::ProjectNamespace/9',
  'fullPath': 'team/example-9',
};
Map<String, Object?> _args([List<String> labels = const ['next']]) => {
  'projectId': 9,
  'iid': 3,
  'labels': labels,
};
port.AiWriteRequest _request([List<String> labels = const ['next']]) =>
    port.AiWriteRequest(
      operationId: _op,
      executionId: 'labels-${_execution++}',
      scope: mr6b3Scope,
      arguments: _args(labels),
    );
Matcher _refused(String code) =>
    isA<port.AiWriteRefused>().having((value) => value.reason, 'reason', code);
Map<String, Object?> _label(int id, String title) => {
  'id': 'gid://gitlab/ProjectLabel/$id',
  'title': title,
  'color': '#000000',
  'textColor': '#ffffff',
};

final class _Server {
  _Server({this.oauth = false}) {
    adapter = FakeAdapter(_respond);
    final dio = Dio()..httpClientAdapter = adapter;
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    api = oauth
        ? GitLabApi(
            instance: instance,
            dio: dio,
            credential: const OAuthCredential(
              accessToken: 'synthetic-access',
              refreshToken: 'synthetic-refresh',
              clientId: 'synthetic-client',
            ),
            oauth: OAuthTokenClient(
              instance: instance,
              clientId: 'synthetic-client',
              dio: dio,
            ),
            onOAuthRotated: (_) async {},
          )
        : testApi(adapter);
    writer = port.GitLabAiWritePort(api, accountKey: mr6b3Account);
  }
  final bool oauth;
  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final port.GitLabAiWritePort writer;
  final catalog = [_label(1, 'old'), _label(2, 'next')];
  final currentOnly = <Map<String, Object?>>[];
  List<String> selected = ['gid://gitlab/ProjectLabel/1'];
  final inputs = <Map<String, Object?>>[];
  final reads = <String, int>{};
  String revision = '2026-10-23T00:00:00Z';
  int actor = 7;
  bool permission = true;
  bool partialCandidates = false;
  bool partialCurrent = false;
  bool mismatchReadback = false;
  int? mutationStatus;
  int mutations = 0;
  int replayedReads = 0;
  bool _replaying = false;
  Future<void> Function()? onMutation;

  Map<String, Object?> _node({bool detail = false}) => {
    'id': _item,
    'iid': '3',
    'title': 'Synthetic labels',
    'state': 'OPEN',
    'createdAt': '2026-10-01T00:00:00Z',
    'updatedAt': revision,
    'project': _project,
    'namespace': _namespace,
    'workItemType': {
      'id': 'gid://gitlab/WorkItems::Type/9',
      'name': 'Task',
      'widgetDefinitions': [
        {'type': 'LABELS', 'allowsScopedLabels': true},
      ],
    },
    'description': null,
    'userPermissions': {
      'readWorkItem': true,
      'setWorkItemMetadata': permission,
    },
    'widgets': [
      if (!detail)
        {
          'type': 'LABELS',
          'labels': {
            'nodes': [
              for (final id in selected)
                [
                  ...catalog,
                  ...currentOnly,
                ].firstWhere((node) => node['id'] == id),
            ],
            'pageInfo': {
              'hasNextPage': partialCurrent,
              'endCursor': partialCurrent ? 'next' : null,
            },
          },
        },
    ],
  };

  Future<ResponseBody> _respond(RequestOptions request) async {
    if (request.uri.path.endsWith('/oauth/token')) {
      return jsonResponse({
        'access_token': 'synthetic-rotated-$replayedReads',
        'refresh_token': 'synthetic-refresh',
        'token_type': 'bearer',
        'expires_in': 7200,
      });
    }
    final data = request.data;
    final query = data is Map ? data['query'] as String? : null;
    final mutation = query?.startsWith('mutation ') ?? false;
    if (!mutation && oauth) {
      if (!_replaying) {
        _replaying = true;
        replayedReads++;
        return jsonResponse({}, status: 401);
      }
      _replaying = false;
    }
    if (mutation) {
      expect(query, startsWith('mutation MobileUpdateWorkItemLabels('));
      mutations++;
      final input = ((data as Map)['variables'] as Map)['input'] as Map;
      inputs.add(input.cast<String, Object?>());
      await onMutation?.call();
      if (mutationStatus != null) {
        return jsonResponse({}, status: mutationStatus!);
      }
      if (!mismatchReadback) {
        final widget = input['labelsWidget'] as Map;
        final removed = (widget['removeLabelIds'] as List?) ?? [];
        final added = (widget['addLabelIds'] as List?) ?? [];
        selected = [
          ...selected.where((id) => !removed.contains(id)),
          ...added.cast<String>(),
        ];
      }
      revision = '2026-10-23T00:01:00Z';
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': <String>[],
            'workItem': {'id': _item, 'updatedAt': revision},
          },
        },
      });
    }
    final operation = request.method == 'GET'
        ? request.uri.path.endsWith('/user')
              ? 'user'
              : 'freshness'
        : RegExp(r'^query (\w+)').firstMatch(query!)!.group(1)!;
    reads.update(operation, (value) => value + 1, ifAbsent: () => 1);
    switch (operation) {
      case 'user':
        return jsonResponse({
          'id': 7,
          'username': 'synthetic',
          'name': 'Synthetic',
        });
      case 'freshness':
        return jsonResponse(projectJson(9));
      case 'MobileProjectWorkItem':
        return jsonResponse({
          'data': {
            'project': {
              ..._project,
              'workItems': {
                'nodes': [_node(detail: true)],
                'pageInfo': {'hasNextPage': false},
              },
            },
          },
        });
      case 'MobileWorkItemLabels':
        expect((data as Map)['variables'], {'id': _item, 'after': null});
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/$actor'},
            'workItem': _node(),
          },
        });
      case 'MobileProjectWorkItemLabelCandidates':
        expect(query, isNot(contains('search')));
        expect(query, contains('first: 100'));
        expect((data as Map)['variables'], {'fullPath': 'team/example-9'});
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/$actor'},
            'project': {
              ..._project,
              'labels': {
                'nodes': catalog,
                'pageInfo': {
                  'hasNextPage': partialCandidates,
                  'endCursor': partialCandidates ? 'next' : null,
                },
              },
            },
          },
        });
      default:
        throw StateError('Unexpected request: $operation');
    }
  }

  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    Future<void> Function()? before,
    bool Function()? mayStart,
  }) {
    prepared.bindGraphBeforeMutation(before ?? () async {});
    return writer.commit(prepared, mayStart: mayStart ?? () => true);
  }

  int get resourceRequests => adapter.requests
      .where((request) => !request.uri.path.endsWith('/oauth/token'))
      .length;
}

final class _Harness {
  _Harness(this.server);
  final _Server server;
  late final Directory root;
  late final Mr6b3JournalFiles files;
  late final Mr6b3JournalKeyStore keys;
  late final AiWriteJournal journal;
  late final PolicyAiWriteCoordinator coordinator;
  late final AiToolBudget budget;
  bool alive = true;
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;

  static Future<_Harness> create({bool oauth = false}) async {
    final h = _Harness(_Server(oauth: oauth));
    h.root = Directory.systemTemp.createTempSync('mr6b3-labels-');
    h.files = Mr6b3JournalFiles(h.root);
    h.keys = Mr6b3JournalKeyStore();
    h.journal = AiWriteJournal(
      keys: h.keys,
      applicationSupport: h.root,
      files: h.files,
      processId: 'labels-family',
    );
    await h.journal.recoverAfterAccountsLoaded([mr6b3Account]);
    await h.journal.ensureInitialized(mr6b3Account);
    h.budget = AiToolBudget(maxGitLabRequests: 80);
    h.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: mr6b3Scope,
        level: h.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'labels-consent',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 1,
        alive: h.alive,
        consentValid: true,
        clientMayStart: true,
      ),
      createPort: () => h.server.writer,
      journal: h.journal,
      conversationId: 'labels-conversation',
      budget: () => h.budget,
      readFreshness: (_) async {
        await h.server.api.record(['projects', '9']);
        return const AiWriteFreshness(visibilityUnreadable: false);
      },
      placeholders: text.UploadPlaceholderTable(
        instance: h.server.api.instance,
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
    );
    h.coordinator.beginRun('Update labels on issue #3 in team/example-9.');
    h.coordinator.beginTurn();
    addTearDown(h.dispose);
    return h;
  }

  Future<AiWriteProposal?> propose([List<String> labels = const ['next']]) =>
      coordinator.propose(
        AiToolCall(
          id: 'labels-call',
          name: _op,
          arguments: {..._args(labels), 'reason': 'synthetic labels update'},
        ),
      );
  Future<void> dispose() async {
    files.releaseBarrier();
    coordinator.stop('disposed');
    server.api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

void main() {
  test('labels row is visible T2 graph with bounded exact-title schema', () {
    final row = productionAiLedger.find(_op)!;
    expect(row.modelVisible, isTrue);
    expect(row.baseTier, AiWriteTier.t2);
    expect(row.boundary, AiWriteBoundary.graph);
    expect(row.httpCap, 25);
    expect(row.arguments.keys, unorderedEquals(['projectId', 'iid', 'labels']));
    expect(aiWriteRequestAllowance(_op), 25);
    expect(aiWriteRequestAllowance(_op, oauthReplay: false), 13);
  });

  test(
    'complete search-free catalog registers selection and verifies mutation',
    () async {
      final s = _Server();
      addTearDown(s.api.close);
      final prepared = await s.writer.prepare(_request());
      expect(prepared.bindingTargets.single.kind, AiTargetKind.issue);
      expect((prepared.preview as port.AiFieldsPreview).fields, {
        'labels': ['next'],
      });
      var hooks = 0;
      final outcome =
          await s.commit(
                prepared,
                before: () async {
                  hooks++;
                },
              )
              as port.AiWriteSettled;
      expect(outcome.state, AiJournalState.succeeded);
      expect(outcome.readbackVerified, isTrue);
      expect(hooks, 1);
      expect(s.reads['MobileProjectWorkItemLabelCandidates'], 1);
      expect(s.reads['MobileWorkItemLabels'], 3);
      expect(s.inputs.single, {
        'id': _item,
        'labelsWidget': {
          'addLabelIds': ['gid://gitlab/ProjectLabel/2'],
          'removeLabelIds': ['gid://gitlab/ProjectLabel/1'],
        },
      });
    },
  );

  test('explicit empty selection clears labels', () async {
    final s = _Server();
    addTearDown(s.api.close);
    final prepared = await s.writer.prepare(_request([]));
    expect(
      (await s.commit(prepared) as port.AiWriteSettled).state,
      AiJournalState.succeeded,
    );
    expect(s.inputs.single['labelsWidget'], {
      'removeLabelIds': ['gid://gitlab/ProjectLabel/1'],
    });
  });

  for (final fault in ['unknown', 'partial', 'ambiguous', 'currentAmbiguous']) {
    test('$fault candidates refuse before mutation', () async {
      final s = _Server();
      addTearDown(s.api.close);
      var labels = ['next'];
      if (fault == 'unknown') labels = ['unseen'];
      if (fault == 'partial') {
        s.catalog.addAll([for (var i = 3; i <= 21; i++) _label(i, 'label$i')]);
        s.partialCandidates = true;
      }
      if (fault == 'ambiguous') s.catalog.add(_label(3, 'next'));
      if (fault == 'currentAmbiguous') {
        s.currentOnly.add(s.catalog.removeAt(0));
        s.catalog.add(_label(3, 'old'));
        labels = ['old'];
      }
      await expectLater(
        s.writer.prepare(_request(labels)),
        throwsA(_refused(fault == 'partial' ? 'unsupported' : 'labelUnknown')),
      );
      expect(s.mutations, 0);
      expect(s.reads['MobileProjectWorkItemLabelCandidates'], 1);
    });
  }

  test(
    'current label absent from candidates can be kept while adding',
    () async {
      final s = _Server();
      addTearDown(s.api.close);
      s.currentOnly.add(s.catalog.removeAt(0));
      final prepared = await s.writer.prepare(_request(['old', 'next']));
      expect(
        (await s.commit(prepared) as port.AiWriteSettled).state,
        AiJournalState.succeeded,
      );
      expect(s.inputs.single['labelsWidget'], {
        'addLabelIds': ['gid://gitlab/ProjectLabel/2'],
      });
      expect(s.selected, contains('gid://gitlab/ProjectLabel/1'));
      expect(s.reads['MobileProjectWorkItemLabelCandidates'], 1);
    },
  );

  for (final count in [21, 100]) {
    test(
      'complete catalog of $count candidates succeeds in one read',
      () async {
        final s = _Server();
        addTearDown(s.api.close);
        s.catalog.addAll([
          for (var i = 3; i <= count; i++) _label(i, 'label$i'),
        ]);
        final prepared = await s.writer.prepare(_request(['label$count']));
        expect(
          (await s.commit(prepared) as port.AiWriteSettled).state,
          AiJournalState.succeeded,
        );
        expect(s.selected, ['gid://gitlab/ProjectLabel/$count']);
        expect(s.reads['MobileProjectWorkItemLabelCandidates'], 1);
      },
    );
  }

  test('catalog over 100 candidates is refused before mutation', () async {
    final s = _Server();
    addTearDown(s.api.close);
    s.catalog.addAll([for (var i = 3; i <= 101; i++) _label(i, 'label$i')]);
    await expectLater(
      s.writer.prepare(_request()),
      throwsA(_refused('unsupported')),
    );
    expect(s.reads['MobileProjectWorkItemLabelCandidates'], 1);
    expect(s.mutations, 0);
  });

  test('clearing succeeds with 21 complete candidates in one read', () async {
    final s = _Server();
    addTearDown(s.api.close);
    s.catalog.addAll([for (var i = 3; i <= 21; i++) _label(i, 'label$i')]);
    final prepared = await s.writer.prepare(_request([]));
    expect(
      (await s.commit(prepared) as port.AiWriteSettled).state,
      AiJournalState.succeeded,
    );
    expect(s.selected, isEmpty);
    expect(s.reads['MobileProjectWorkItemLabelCandidates'], 1);
  });

  for (final labels in [
    List.generate(11, (i) => 'label$i'),
    ['next', 'next'],
    [''],
    ['bad\u0000'],
  ]) {
    test(
      'invalid label proposal ${labels.length} refuses before HTTP',
      () async {
        final s = _Server();
        addTearDown(s.api.close);
        await expectLater(
          s.writer.prepare(_request(labels)),
          throwsA(_refused('validation')),
        );
        expect(s.adapter.requests, isEmpty);
      },
    );
  }

  test('ten labels are allowed and resolve in one catalog read', () async {
    final s = _Server();
    addTearDown(s.api.close);
    s.catalog.addAll([for (var i = 3; i <= 10; i++) _label(i, 'label$i')]);
    final names = s.catalog.map((label) => label['title']! as String).toList();
    final prepared = await s.writer.prepare(_request(names));
    expect(
      (await s.commit(prepared) as port.AiWriteSettled).state,
      AiJournalState.succeeded,
    );
    expect(s.selected, hasLength(10));
    expect(s.reads['MobileProjectWorkItemLabelCandidates'], 1);
  });

  test(
    'partial current-label page refuses without following continuation',
    () async {
      final s = _Server()..partialCurrent = true;
      addTearDown(s.api.close);
      await expectLater(
        s.writer.prepare(_request()),
        throwsA(_refused('unsupported')),
      );
      expect(s.reads['MobileWorkItemLabels'], 1);
      expect(s.reads['MobileProjectWorkItemLabelCandidates'], isNull);
    },
  );

  test('scoped labels cannot conflict within a proposal', () async {
    final s = _Server();
    addTearDown(s.api.close);
    s.catalog.addAll([_label(3, 'priority::one'), _label(4, 'priority::two')]);
    await expectLater(
      s.writer.prepare(_request(['priority::one', 'priority::two'])),
      throwsA(_refused('validation')),
    );
    expect(s.mutations, 0);
  });

  test('revision and catalog identity changes alter binding digest', () async {
    final s = _Server();
    addTearDown(s.api.close);
    final first = await s.writer.prepare(_request());
    s.revision = '2026-10-23T00:00:01Z';
    final second = await s.writer.prepare(_request());
    expect(second.bindingDigest, isNot(first.bindingDigest));
    s.catalog[1] = _label(3, 'next');
    final third = await s.writer.prepare(_request());
    expect(third.bindingDigest, isNot(second.bindingDigest));
  });

  for (final fault in ['revision', 'permission', 'actor', 'value']) {
    test('preflight $fault refuses before hook', () async {
      final s = _Server();
      addTearDown(s.api.close);
      final prepared = await s.writer.prepare(_request());
      if (fault == 'revision') s.revision = '2026-10-23T00:00:01Z';
      if (fault == 'permission') s.permission = false;
      if (fault == 'actor') s.actor = 8;
      if (fault == 'value') s.selected = [];
      var hooks = 0;
      final outcome =
          await s.commit(
                prepared,
                before: () async {
                  hooks++;
                },
              )
              as port.AiWriteNotSent;
      expect(
        outcome.reasonCode,
        fault == 'permission'
            ? 'forbidden'
            : fault == 'actor'
            ? 'cancelled'
            : 'targetChanged',
      );
      expect(hooks, 0);
      expect(s.mutations, 0);
    });
  }

  test('noop does not invoke hooks', () async {
    final s = _Server();
    addTearDown(s.api.close);
    final prepared = await s.writer.prepare(_request(['old']));
    expect(
      await s.commit(
        prepared,
        before: () async {
          fail('noop hook');
        },
      ),
      isA<port.AiGraphNoChange>(),
    );
    expect(s.mutations, 0);
  });

  test('failed final gate is not sent and hook failure propagates', () async {
    final s = _Server();
    addTearDown(s.api.close);
    final prepared = await s.writer.prepare(_request());
    expect(
      await s.commit(prepared, mayStart: () => false),
      isA<port.AiWriteNotSent>(),
    );
    final second = await s.writer.prepare(_request());
    await expectLater(
      s.commit(
        second,
        before: () async {
          throw StateError('hook failed');
        },
      ),
      throwsStateError,
    );
    expect(s.mutations, 0);
  });

  for (final fault in ['401', '500', 'readback']) {
    test(
      'accepted $fault is uncertain and mutation is never replayed',
      () async {
        final s = _Server();
        addTearDown(s.api.close);
        s.mutationStatus = int.tryParse(fault);
        s.mismatchReadback = fault == 'readback';
        final prepared = await s.writer.prepare(_request());
        final outcome = await s.commit(prepared) as port.AiWriteSettled;
        expect(outcome.state, AiJournalState.writeUncertain);
        expect(outcome.readbackVerified, isFalse);
        expect(s.mutations, 1);
      },
    );
  }

  for (final oauth in [false, true]) {
    test(
      'coordinator measured ${oauth ? 'OAuth' : 'PAT'} cap includes both preparation passes',
      () async {
        final h = await _Harness.create(oauth: oauth);
        final proposal = (await h.propose())!;
        final outcome = await h.coordinator.approve(proposal);
        expect(outcome.state, AiJournalState.succeeded);
        // F=1, P=4 each pass, then one preflight and readback: L=12.
        expect(h.server.resourceRequests, oauth ? 25 : 13);
        expect(h.server.replayedReads, oauth ? 12 : 0);
        expect(h.server.mutations, 1);
      },
    );
  }

  test(
    'journal records prepared, dispatching and succeeded at the real boundary',
    () async {
      final h = await _Harness.create();
      final proposal = (await h.propose())!;
      // Proposal itself does not claim a durable write yet.
      h.server.onMutation = () async {
        expect(
          h.journal.entries(mr6b3Account).single.state,
          AiJournalState.dispatching,
        );
      };
      final entered = h.files.armBarrier(writesBeforeBarrier: 1);
      final approving = h.coordinator.approve(proposal);
      await entered;
      expect(
        h.journal.entries(mr6b3Account).single.state,
        AiJournalState.prepared,
      );
      expect(h.server.mutations, 0);
      h.files.releaseBarrier();
      final outcome = await approving;
      expect(outcome.state, AiJournalState.succeeded);
      expect(
        h.journal.entries(mr6b3Account).single.state,
        AiJournalState.succeeded,
      );
    },
  );

  test('coordinator noop ends notExecuted without dispatching', () async {
    final h = await _Harness.create();
    final proposal = (await h.propose(['old']))!;
    final outcome = await h.coordinator.approve(proposal);
    expect(outcome.state, AiJournalState.succeeded);
    expect(outcome.noChange, isTrue);
    expect(
      h.journal.entries(mr6b3Account).single.state,
      AiJournalState.notExecuted,
    );
    expect(h.server.mutations, 0);
  });

  test(
    'coordinator catalog drift refuses target before journal dispatch',
    () async {
      final h = await _Harness.create();
      final proposal = (await h.propose())!;
      h.server.catalog[1] = _label(3, 'next');
      final outcome = await h.coordinator.approve(proposal);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, 'targetChanged');
      expect(h.server.mutations, 0);
    },
  );

  test('journal settles accepted failure as writeUncertain', () async {
    final h = await _Harness.create();
    final proposal = (await h.propose())!;
    h.server.mutationStatus = 500;
    final outcome = await h.coordinator.approve(proposal);
    expect(outcome.state, AiJournalState.writeUncertain);
    expect(
      h.journal.entries(mr6b3Account).single.state,
      AiJournalState.writeUncertain,
    );
    expect(h.server.mutations, 1);
  });

  test('journal flush failure prevents mutation', () async {
    final h = await _Harness.create();
    final proposal = (await h.propose())!;
    h.files.failWriteNumber = h.files.writeCount + 2;
    final outcome = await h.coordinator.approve(proposal);
    expect(outcome.state, AiJournalState.notExecuted);
    expect(h.server.mutations, 0);
  });
}
