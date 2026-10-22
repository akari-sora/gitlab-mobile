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
import 'fx_coord_support.dart';

const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _sha2 = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _limit = Duration(seconds: 20);
const _operations = {
  'createBranch': {'projectId': 9, 'branch': 'feature/new', 'ref': 'main'},
  'deleteBranch': {'projectId': 9, 'branch': 'feature/old'},
  'createTag': {
    'projectId': 9,
    'tag_name': 'v2/test',
    'ref': 'main',
    'message': '  /release\n@all  ',
  },
  'deleteTag': {'projectId': 9, 'tag_name': 'v1'},
  'createRelease': {
    'projectId': 9,
    'fields': {
      'tag_name': 'v1',
      'name': 'Version One',
      'description': '  /release\nNotes  ',
    },
  },
  'updateRelease': {
    'projectId': 9,
    'tag_name': 'v1',
    'fields': {'name': 'Revised', 'description': '  /release\nRevised  '},
  },
  'deleteRelease': {'projectId': 9, 'tag_name': 'v1'},
};

port.AiWriteRequest _request(
  String op,
  Map<String, Object?> args, {
  AiWriteScope scope = coordScope,
  String execution = 'p7-execution',
}) => port.AiWriteRequest(
  operationId: op,
  executionId: execution,
  scope: scope,
  arguments: args,
);

void main() {
  test(
    'P7 ledger declares seven hidden rows, closed B fields and counted caps',
    () {
      expect(
        aiRefRows.map((row) => row.operationId).toSet(),
        _operations.keys.toSet(),
      );
      for (final row in aiRefRows) {
        expect(row.namedMethod, row.operationId);
        expect(row.modelVisible, isFalse);
        expect(row.scopeClass, AiScopeClass.project);
        expect(
          row.baseTier,
          const {
                'createBranch',
                'createRelease',
                'updateRelease',
              }.contains(row.operationId)
              ? AiWriteTier.t3
              : AiWriteTier.t4,
        );
        expect(row.httpCap, row.operationId.startsWith('delete') ? 17 : 19);
        expect(row.readback, !row.operationId.startsWith('delete'));
        expect(productionAiLedger.modelVisible, isNot(contains(row)));
      }
      final create = productionAiLedger.find('createRelease')!;
      final update = productionAiLedger.find('updateRelease')!;
      expect(create.arguments['fields']!.properties.keys.toSet(), {
        'tag_name',
        'name',
        'description',
      });
      expect(update.arguments['fields']!.properties.keys.toSet(), {
        'name',
        'description',
      });
      expect(
        update.arguments['fields']!.properties['description']!.writableField,
        'releaseDescription',
      );
      expect(
        update.arguments['fields']!.properties['description']!.text,
        AiTextRole.renderedMarkdown,
      );
      expect(
        productionAiLedger.find('createTag')!.arguments['message']!.text,
        AiTextRole.plainContent,
      );
    },
  );

  for (final entry in _operations.entries) {
    test(
      'P7 ${entry.key} fixed method, encoded path, payload and readback',
      () async {
        final server = _Server();
        final adapter = FakeAdapter(server.respond);
        final api = testApi(adapter);
        addTearDown(api.close);
        final writer = port.GitLabAiWritePort(api, accountKey: coordAccount);
        final prepared = await writer.prepare(_request(entry.key, entry.value));
        expect(prepared.projectPath, 'team/example-9');
        expect(prepared.projectVisibility, 'private');
        expect(prepared.bindingDigest, matches(r'^[a-f0-9]{64}$'));
        expect(prepared.bindingTargets, isNotEmpty);
        final expectedName = switch (entry.key) {
          'deleteBranch' => 'feature/old',
          'createTag' => 'v2/test',
          'deleteTag' => 'v1',
          'deleteRelease' => 'Version One',
          _ => null,
        };
        expect(prepared.confirmName, expectedName);
        expect(
          prepared.releaseName,
          entry.key.endsWith('Release')
              ? 'team/example-9'
              : entry.value['branch'] ?? entry.value['tag_name'],
        );
        final outcome =
            await writer.commit(prepared, mayStart: () => true)
                as port.AiWriteSettled;
        expect(outcome.state, AiJournalState.succeeded);
        final write = adapter.requests.singleWhere((r) => r.method != 'GET');
        final (method, path, body) = switch (entry.key) {
          'createBranch' => (
            'POST',
            ['repository', 'branches'],
            {'branch': 'feature/new', 'ref': _sha},
          ),
          'deleteBranch' => (
            'DELETE',
            ['repository', 'branches', 'feature/old'],
            null,
          ),
          'createTag' => (
            'POST',
            ['repository', 'tags'],
            {
              'tag_name': 'v2/test',
              'ref': _sha,
              'message': '  /release\n@all  ',
            },
          ),
          'deleteTag' => ('DELETE', ['repository', 'tags', 'v1'], null),
          'createRelease' => ('POST', ['releases'], entry.value['fields']),
          'updateRelease' => ('PUT', ['releases', 'v1'], entry.value['fields']),
          _ => ('DELETE', ['releases', 'v1'], null),
        };
        expect(write.method, method);
        expect(write.uri.pathSegments, [
          'gitlab',
          'api',
          'v4',
          'projects',
          '9',
          ...path,
        ]);
        expect(write.data, body);
        expect(write.followRedirects, isFalse);
        expect(write.uri.query, isEmpty);
        expect(
          await writer.commit(prepared, mayStart: () => true),
          isA<port.AiWriteNotSent>(),
        );
        expect(adapter.requests.where((r) => r.method != 'GET'), hasLength(1));
        expect(adapter.requests.length, entry.key.startsWith('delete') ? 4 : 5);
        if (entry.key == 'createBranch') {
          expect(prepared.bindingTargets.single.kind, AiTargetKind.newBranch);
          expect(prepared.bindingTargets.single.name, 'feature/new');
          expect(prepared.bindingTargets.single.sourceRef, 'main');
        }
        if (entry.key == 'createRelease') {
          expect(prepared.writeKeys.single.parts, [
            coordAccount,
            'project:9',
            'release',
            'v1',
          ]);
          expect(prepared.dependencyKeys.single.parts, [
            coordAccount,
            'project:9',
            'ref',
            'v1',
          ]);
        }
        if (entry.key == 'updateRelease' || entry.key == 'deleteRelease') {
          expect(prepared.dependencyKeys, isEmpty);
        }
      },
    );
  }

  for (final op in ['updateRelease', 'deleteRelease']) {
    for (final absent in [false, true]) {
      test(
        'P7 $op accepts optional Release metadata ${absent ? 'absent' : 'null'}',
        () async {
          final f = await _Harness.create();
          addTearDown(f.dispose);
          final snapshot = f.server.releases['v1']!;
          for (final key in ['name', 'description']) {
            if (absent) {
              snapshot.remove(key);
            } else {
              snapshot[key] = null;
            }
          }
          final candidate = await f.propose(op, _operations[op]!);
          expect(candidate, isNotNull);
          final proposal = candidate!;
          expect(proposal.tier.typedName, op == 'deleteRelease' ? 'v1' : null);
          final outcome = await f.coordinator.approve(
            proposal,
            typedName: op == 'deleteRelease' ? 'v1' : null,
          );
          expect(outcome.state, AiJournalState.succeeded);
          expect(f.server.mutations, 1);
          if (op == 'deleteRelease') {
            expect(f.server.releases, isEmpty);
          } else {
            expect(f.server.releases['v1']!['name'], 'Revised');
          }
        },
      );
    }
  }

  for (final (op, path, reason) in [
    ('createBranch', 'repository/commits/main', 'refMissing'),
    ('createTag', 'repository/commits/main', 'refMissing'),
    ('deleteBranch', 'repository/branches/feature/old', 'refMissing'),
    ('deleteTag', 'repository/tags/v1', 'tagMissing'),
    ('createRelease', 'repository/tags/v1', 'tagMissing'),
    ('updateRelease', 'releases/v1', 'releaseMissing'),
    ('deleteRelease', 'releases/v1', 'releaseMissing'),
  ]) {
    test('P7 $op missing evidence returns $reason with zero writes', () async {
      final f = await _Harness.create();
      addTearDown(f.dispose);
      f.server.failRead = path;
      final proposal = await f.propose(op, _operations[op]!);
      expect(proposal, isNull);
      expect(f.coordinator.outcomeFor('call')!.reasonCode, reason);
      expect(f.server.mutations, 0);
    });
  }

  for (final (kind, reason) in [
    ('default', 'defaultBranch'),
    ('protected', 'protectedBranch'),
    ('projectDefault', 'defaultBranch'),
  ]) {
    test('P7 deleteBranch rejects $kind branch before any mutation', () async {
      final f = await _Harness.create();
      addTearDown(f.dispose);
      if (kind == 'projectDefault') {
        f.server.defaultBranch = 'feature/old';
      } else {
        f.server.branches['feature/old']![kind] = true;
      }
      expect(
        await f.propose('deleteBranch', _operations['deleteBranch']!),
        isNull,
      );
      expect(f.coordinator.outcomeFor('call')!.reasonCode, reason);
      expect(f.server.mutations, 0);
    });
  }

  for (final (op, forbidden) in [
    for (final key in [
      'ref',
      'assets.links',
      'assets',
      'milestones',
      'released_at',
    ])
      ('createRelease', key),
    for (final key in [
      'tag_name',
      'ref',
      'assets.links',
      'milestones',
      'released_at',
    ])
      ('updateRelease', key),
  ]) {
    test('P7 $op refuses field $forbidden before HTTP', () async {
      final server = _Server();
      final adapter = FakeAdapter(server.respond);
      final api = testApi(adapter);
      addTearDown(api.close);
      final args = {..._operations[op]!};
      args['fields'] = {...(args['fields']! as Map), forbidden: 'unapproved'};
      await expectLater(
        port.GitLabAiWritePort(
          api,
          accountKey: coordAccount,
        ).prepare(_request(op, args)),
        throwsA(isA<ApiFailure>()),
      );
      expect(adapter.requests, isEmpty);
    });
  }

  test(
    'P7 scope, identity, name and malformed snapshot checks fail closed',
    () async {
      final server = _Server();
      final adapter = FakeAdapter(server.respond);
      final api = testApi(adapter);
      addTearDown(api.close);
      final writer = port.GitLabAiWritePort(api, accountKey: coordAccount);
      for (final name in [
        '',
        'a..b',
        '../escape',
        'a\\b',
        'a b',
        'a\n',
        'a.lock',
        'a//b',
        '.hidden',
        '@',
        'a@{b',
        '-option',
      ]) {
        await expectLater(
          writer.prepare(
            _request('createBranch', {
              'projectId': 9,
              'branch': name,
              'ref': 'main',
            }),
          ),
          throwsA(isA<ApiFailure>()),
        );
      }
      expect(adapter.requests, isEmpty);
      for (final kind in [
        AiScopeKind.workItem,
        AiScopeKind.mergeRequest,
        AiScopeKind.groupWorkItem,
        AiScopeKind.accountGlobal,
      ]) {
        await expectLater(
          writer.prepare(
            _request(
              'createBranch',
              _operations['createBranch']!,
              scope: AiWriteScope(
                accountKey: coordAccount,
                grants: [AiScopeGrant(kind: kind, projectId: 9, iid: 3)],
              ),
            ),
          ),
          throwsA(isA<ApiFailure>()),
        );
      }
      expect(adapter.requests, isEmpty);
      server.actor = 8;
      await expectLater(
        writer.prepare(_request('createBranch', _operations['createBranch']!)),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.kind,
            'kind',
            FailureKind.unauthenticated,
          ),
        ),
      );
      server.actor = 7;
      server.projectId = 10;
      await expectLater(
        writer.prepare(_request('createBranch', _operations['createBranch']!)),
        throwsA(isA<ApiFailure>()),
      );
      server.projectId = 9;
      server.branches['feature/old']!.remove('protected');
      await expectLater(
        writer.prepare(_request('deleteBranch', _operations['deleteBranch']!)),
        throwsA(isA<ApiFailure>()),
      );
      server.tags['v1']!['name'] = 'foreign';
      await expectLater(
        writer.prepare(
          _request('createRelease', _operations['createRelease']!),
        ),
        throwsA(isA<ApiFailure>()),
      );
      server.sourceSha = 'not-a-commit';
      await expectLater(
        writer.prepare(_request('createBranch', _operations['createBranch']!)),
        throwsA(isA<ApiFailure>()),
      );
      expect(server.mutations, 0);
    },
  );

  test(
    'P7 source SHA binding changes and source snapshot is pinned on create',
    () async {
      final server = _Server();
      final api = testApi(FakeAdapter(server.respond));
      addTearDown(api.close);
      final writer = port.GitLabAiWritePort(api, accountKey: coordAccount);
      final before = await writer.prepare(
        _request('createBranch', _operations['createBranch']!),
      );
      server.sourceSha = _sha2;
      final after = await writer.prepare(
        _request(
          'createBranch',
          _operations['createBranch']!,
          execution: 'other',
        ),
      );
      expect(before.bindingDigest, isNot(after.bindingDigest));
      await writer.commit(before, mayStart: () => true);
      expect(server.branches['feature/new']!['commit'], {'id': _sha});
    },
  );

  test('P7 createBranch binds both new name and source ref', () async {
    final f = await _Harness.create();
    addTearDown(f.dispose);
    f.start('Create `feature/new`');
    final unbound = (await f.propose(
      'createBranch',
      _operations['createBranch']!,
    ))!;
    expect(unbound.tier.decision, AiGateDecision.requireApproval);
    expect(unbound.tier.reasons, contains(AiFixedConfirmReason.targetUnbound));
    f.start('Create `feature/new` from `main`');
    final bound = (await f.propose(
      'createBranch',
      _operations['createBranch']!,
    ))!;
    expect(bound.tier.decision, AiGateDecision.execute);
  });

  test(
    'P7 createTag always T4, requires the new tag name in conversation grant',
    () async {
      final f = await _Harness.create();
      addTearDown(f.dispose);
      final proposal = (await f.propose(
        'createTag',
        _operations['createTag']!,
      ))!;
      expect(proposal.tier.tier, AiWriteTier.t4);
      expect(proposal.tier.requiresTypedName, isTrue);
      expect(proposal.tier.typedName, 'v2/test');
      expect(f.server.mutations, 0);
      final wrong = await f.coordinator.approve(proposal, typedName: 'main');
      expect(wrong.state, AiJournalState.notExecuted);
      expect(f.server.mutations, 0);
      final result = await f.coordinator.approve(
        proposal,
        typedName: 'v2/test',
      );
      expect(result.state, AiJournalState.succeeded);
      expect(f.server.mutations, 1);
      expect(f.h.journal.entries(coordAccount).single.releaseName, 'v2/test');
    },
  );

  for (final op in [
    'createBranch',
    'createTag',
    'createRelease',
    'updateRelease',
    'deleteRelease',
  ]) {
    test('P7 $op rejects a changed preflight binding at dispatch', () async {
      final f = await _Harness.create();
      addTearDown(f.dispose);
      final proposal = (await f.propose(op, _operations[op]!))!;
      if (op == 'createBranch' || op == 'createTag') {
        f.server.sourceSha = _sha2;
      } else if (op == 'createRelease') {
        f.server.tags['v1']!['commit'] = {'id': _sha2};
      } else {
        f.server.releases['v1']!['description'] = 'edited elsewhere';
      }
      final result = await f.coordinator.approve(
        proposal,
        typedName: proposal.tier.typedName,
      );
      expect(result.reasonCode, 'targetChanged');
      expect(f.server.mutations, 0);
    });
  }

  for (final flag in ['default', 'protected']) {
    test('P7 deleteBranch rechecks $flag after approval', () async {
      final f = await _Harness.create();
      addTearDown(f.dispose);
      final proposal = (await f.propose(
        'deleteBranch',
        _operations['deleteBranch']!,
      ))!;
      f.server.branches['feature/old']![flag] = true;
      final outcome = await f.coordinator.approve(
        proposal,
        typedName: 'feature/old',
      );
      expect(outcome.state, AiJournalState.notExecuted);
      expect(f.server.mutations, 0);
    });
  }

  for (final op in ['createBranch', 'createTag']) {
    test(
      'P7 uncertain $op and same-name recreation only records observations',
      () async {
        final f = await _Harness.create();
        addTearDown(f.dispose);
        f.server.mutationStatus = 500;
        final args = {
          ..._operations[op]!,
          if (op == 'createBranch')
            'branch': 'shared'
          else
            'tag_name': 'shared',
        };
        final proposal = (await f.propose(op, args))!;
        final outcome = await f.coordinator.approve(
          proposal,
          typedName: proposal.tier.typedName,
        );
        expect(outcome.state, AiJournalState.writeUncertain);
        final entry = f.h.journal.entries(coordAccount).single;
        expect(entry.releaseName, 'shared');
        f.server.mutationStatus = null;
        f.server.tags['shared'] = _Server.tag('shared');
        f.server.branches['shared'] = _Server.branch('shared');
        f.h.journal.rereadableEntry(coordAccount, entry.executionId);
        await f.h.journal.recordObservation(
          executionId: entry.executionId,
          summary: 'sameNameObserved',
        );
        expect(
          f.h.journal.entries(coordAccount).single.state,
          AiJournalState.writeUncertain,
        );
        for (final other in ['createBranch', 'createTag']) {
          f.start('Create `shared` from `main`');
          expect(
            await f.propose(other, {
              'projectId': 9,
              'ref': 'main',
              if (other == 'createBranch')
                'branch': 'shared'
              else
                'tag_name': 'shared',
            }),
            isNull,
          );
          expect(f.coordinator.outcomeFor('call')!.reasonCode, 'isolated');
        }
        f.start('Create release for `shared`');
        expect(
          await f.propose('createRelease', {
            'projectId': 9,
            'fields': {'tag_name': 'shared', 'description': 'notes'},
          }),
          isNull,
        );
        expect(f.coordinator.outcomeFor('call')!.reasonCode, 'isolated');
        expect(f.server.mutations, 1);
      },
    );
  }

  test(
    'P7 deleteRelease confirms title but releases quarantine with project path',
    () async {
      final f = await _Harness.create();
      addTearDown(f.dispose);
      f.server.mutationStatus = 500;
      final proposal = (await f.propose(
        'deleteRelease',
        _operations['deleteRelease']!,
      ))!;
      expect(proposal.tier.typedName, 'Version One');
      await f.coordinator.approve(proposal, typedName: 'Version One');
      final entry = f.h.journal.entries(coordAccount).single;
      expect(entry.releaseName, 'team/example-9');
      await expectLater(
        f.h.journal.releaseByUser(
          executionId: entry.executionId,
          typedName: 'Version One',
        ),
        throwsA(isA<AiJournalException>()),
      );
      await f.h.journal.releaseByUser(
        executionId: entry.executionId,
        typedName: 'team/example-9',
      );
      expect(
        f.h.journal.entries(coordAccount).single.state,
        AiJournalState.resolvedByUser,
      );
    },
  );

  test(
    'P7 Release B text preserves bytes and external images force bypass confirmation',
    () async {
      final f = await _Harness.create(level: AiAutonomyLevel.bypass);
      addTearDown(f.dispose);
      const body =
          '  /release\n@all\n![remote](https://images.example/s.png)  ';
      final proposal = (await f.propose('updateRelease', {
        'projectId': 9,
        'tag_name': 'v1',
        'fields': {'description': body},
      }))!;
      expect(proposal.tier.decision, AiGateDecision.requireApproval);
      expect(
        proposal.tier.reasons,
        contains(AiFixedConfirmReason.externalMediaInRenderedMarkdown),
      );
      expect(proposal.tier.reasons, contains(AiFixedConfirmReason.massMention));
      expect(f.server.mutations, 0);
      final outcome = await f.coordinator.approve(proposal);
      expect(outcome.state, AiJournalState.succeeded);
      expect(f.server.releases['v1']!['description'], body);
    },
  );

  test(
    'P7 Release description restores only injected same-field provenance',
    () async {
      final f = await _Harness.create();
      addTearDown(f.dispose);
      const secret = '0123456789abcdef0123456789abcdef';
      const original = '  /release\n![shot](/uploads/$secret/s.png)  ';
      f.server.releases['v1']!['description'] = original;
      final provenance = text.AiFieldProvenance(
        resourceKey: const text.AiConflictKey('synthetic-release-v1'),
        fieldName: text.AiWritableField.releaseDescription,
        completeValue: true,
        projectId: 9,
        projectFullPath: 'team/example-9',
        resourceWeb: Uri.parse(
          'https://example.com/gitlab/team/example-9/-/releases/v1',
        ),
      );
      f.fresh = AiWriteFreshness(
        visibilityUnreadable: false,
        currentFields: const {'description': original},
        provenance: {'description': provenance},
      );
      final visible = f.placeholders.redactOutgoing(
        original,
        field: provenance,
      );
      expect(visible, contains('[[upload:u-1]]'));
      expect(visible, isNot(contains(secret)));
      final proposal = (await f.propose('updateRelease', {
        'projectId': 9,
        'tag_name': 'v1',
        'fields': {'description': visible},
      }))!;
      final outcome = await f.coordinator.approve(proposal);
      expect(outcome.state, AiJournalState.succeeded);
      expect(f.server.releases['v1']!['description'], original);
      f.start('Edit `v1` again');
      f.fresh = const AiWriteFreshness(visibilityUnreadable: false);
      expect(
        await f.propose('updateRelease', {
          'projectId': 9,
          'tag_name': 'v1',
          'fields': {'description': visible},
        }),
        isNull,
      );
      expect(f.server.mutations, 1);
    },
  );

  test(
    'P7 editable Release description refreshes the submitted payload',
    () async {
      final f = await _Harness.create();
      addTearDown(f.dispose);
      final proposal = (await f.propose(
        'updateRelease',
        _operations['updateRelease']!,
      ))!;
      const replacement = '  /release\nUser revised notes  ';
      final edited = await f.coordinator.approve(
        proposal,
        editedText: replacement,
      );
      expect(edited.reasonCode, 'approvalRequired');
      expect(f.server.mutations, 0);
      expect((proposal.preview as port.AiFieldsPreview).fields['fields'], {
        'name': 'Revised',
        'description': replacement,
      });
      final outcome = await f.coordinator.approve(proposal);
      expect(outcome.state, AiJournalState.succeeded);
      expect(f.server.releases['v1']!['description'], replacement);
      expect(f.server.releases['v1']!['name'], 'Revised');
    },
  );

  for (final unsafe in ['glpat-ABCDEFGHIJKLMNOPQRST', '[REDACTED]']) {
    test(
      'P7 unsafe Release content $unsafe is blocked before mutation',
      () async {
        final f = await _Harness.create();
        addTearDown(f.dispose);
        expect(
          await f.propose('updateRelease', {
            'projectId': 9,
            'tag_name': 'v1',
            'fields': {'description': unsafe},
          }),
          isNull,
        );
        expect(f.server.mutations, 0);
      },
    );
  }

  test(
    'P7 unknown operation fields and empty Release updates are rejected',
    () async {
      final server = _Server();
      final adapter = FakeAdapter(server.respond);
      final api = testApi(adapter);
      addTearDown(api.close);
      final writer = port.GitLabAiWritePort(api, accountKey: coordAccount);
      for (final args in <Map<String, Object?>>[
        {..._operations['createBranch']!, 'url': 'https://other.example'},
        {'projectId': 9, 'branch': 'new'},
      ]) {
        await expectLater(
          writer.prepare(_request('createBranch', args)),
          throwsA(isA<ApiFailure>()),
        );
      }
      await expectLater(
        writer.prepare(
          _request('updateRelease', {
            'projectId': 9,
            'tag_name': 'v1',
            'fields': <String, Object?>{},
          }),
        ),
        throwsA(isA<ApiFailure>()),
      );
      await expectLater(
        writer.prepare(
          _request('createTag', {..._operations['createTag']!, 'message': 7}),
        ),
        throwsA(isA<ApiFailure>()),
      );
      expect(adapter.requests, isEmpty);
    },
  );

  for (final mode in ['ack', 'readback', '401']) {
    test(
      'P7 malformed $mode cannot claim confirmed success or replay',
      () async {
        final server = _Server()
          ..badResult = mode == 'ack'
          ..badReadback = mode == 'readback'
          ..readback401 = mode == '401';
        final adapter = FakeAdapter(server.respond);
        final api = testApi(adapter);
        addTearDown(api.close);
        final writer = port.GitLabAiWritePort(api, accountKey: coordAccount);
        final prepared = await writer.prepare(
          _request('createRelease', _operations['createRelease']!),
        );
        final outcome =
            await writer.commit(prepared, mayStart: () => true)
                as port.AiWriteSettled;
        expect(outcome.state, AiJournalState.writeUncertain);
        expect(server.mutations, 1);
        expect(
          await writer.commit(prepared, mayStart: () => true),
          isA<port.AiWriteNotSent>(),
        );
      },
    );
  }

  for (final entry in _operations.entries) {
    test(
      'P7 ${entry.key} OAuth worst-case resource HTTP stays within ledger cap',
      () async {
        final server = _Server();
        var gets = 0;
        final adapter = FakeAdapter((r) {
          if (r.uri.path.endsWith('/oauth/token')) {
            return jsonResponse({
              'access_token': 'synthetic-access-$gets',
              'refresh_token': 'synthetic-refresh',
              'token_type': 'bearer',
              'expires_in': 7200,
            });
          }
          if (r.method == 'GET' && ++gets % 2 == 1) {
            return jsonResponse({}, status: 401);
          }
          return server.respond(r);
        });
        final dio = Dio()..httpClientAdapter = adapter;
        final instance = GitLabInstance.parse('https://example.com/gitlab');
        final api = GitLabApi(
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
        addTearDown(api.close);
        final writer = port.GitLabAiWritePort(api, accountKey: coordAccount);
        for (var pass = 0; pass < 2; pass++) {
          await api.record([
            'projects',
            '9',
          ]); // production visibility freshness
          final prepared = await writer.prepare(
            _request(entry.key, entry.value),
          );
          if (pass == 1) {
            expect(
              (await writer.commit(prepared, mayStart: () => true)
                      as port.AiWriteSettled)
                  .state,
              AiJournalState.succeeded,
            );
          }
        }
        final resourceRequests = adapter.requests
            .where((r) => r.uri.path.contains('/api/v4/'))
            .length;
        final expected = entry.key.startsWith('delete') ? 17 : 19;
        expect(resourceRequests, expected);
        expect(
          resourceRequests,
          lessThanOrEqualTo(productionAiLedger.find(entry.key)!.httpCap),
        );
        expect(server.mutations, 1);
      },
    );
  }
}

final class _VisibleRefs implements AiCapabilityLedger {
  @override
  AiCapability? find(String operationId) {
    final row = productionAiLedger.find(operationId);
    if (row == null || !aiRefRows.contains(row)) return null;
    return AiCapability(
      operationId: row.operationId,
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
    for (final row in aiRefRows) find(row.operationId)!,
  ];
}

final class _Harness {
  _Harness(this.server, this.h, AiAutonomyLevel level) {
    placeholders = text.UploadPlaceholderTable(instance: h.api.instance);
    coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: coordScope,
        level: level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'synthetic-p7',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
      ),
      createPort: () => port.GitLabAiWritePort(h.api, accountKey: coordAccount),
      journal: h.journal,
      conversationId: 'p7-conversation',
      budget: () => h.budget,
      readFreshness: (_) async {
        await h.api.record(['projects', '9']);
        return fresh;
      },
      placeholders: placeholders,
      knownSecrets: () => {},
      safeDisplay: (v) => v,
      ledger: _VisibleRefs(),
    );
    start(
      'Use `main`, `feature/new`, `feature/old`, `v1`, `v2/test`, `shared`',
    );
  }
  static Future<_Harness> create({
    AiAutonomyLevel level = AiAutonomyLevel.conversationGrant,
  }) async {
    final server = _Server();
    return _Harness(
      server,
      await CoordHarness.create(responder: server.respond),
      level,
    );
  }

  final _Server server;
  final CoordHarness h;
  late final PolicyAiWriteCoordinator coordinator;
  late final text.UploadPlaceholderTable placeholders;
  AiWriteFreshness fresh = const AiWriteFreshness(visibilityUnreadable: false);
  void start(String message) {
    h.budget = AiToolBudget(maxGitLabRequests: 40);
    coordinator.beginRun(message);
    coordinator.beginTurn();
  }

  Future<AiWriteProposal?> propose(String op, Map<String, Object?> args) =>
      coordinator
          .propose(
            AiToolCall(
              id: 'call',
              name: op,
              arguments: {...args, 'reason': 'Synthetic user request'},
            ),
          )
          .timeout(_limit);
  Future<void> dispose() async {
    coordinator.stop('disposed');
    await h.dispose();
  }
}

final class _Server {
  static Map<String, Object?> branch(String name, {String sha = _sha}) => {
    'name': name,
    'commit': {'id': sha},
    'default': name == 'main',
    'protected': false,
  };
  static Map<String, Object?> tag(String name) => {
    'name': name,
    'commit': {'id': _sha},
  };
  final branches = {
    'main': branch('main'),
    'feature/old': branch('feature/old'),
  };
  final tags = {'v1': tag('v1')};
  final releases = <String, Map<String, Object?>>{
    'v1': {
      'tag_name': 'v1',
      'name': 'Version One',
      'description': 'Original',
      'created_at': '2026-10-23T00:00:00Z',
    },
  };
  String sourceSha = _sha;
  String defaultBranch = 'main';
  int actor = 7;
  int projectId = 9;
  int mutations = 0;
  int? mutationStatus;
  String? failRead;
  bool badResult = false;
  bool badReadback = false;
  bool readback401 = false;

  ResponseBody respond(RequestOptions r) {
    final segments = r.uri.pathSegments;
    if (segments.last == 'user') {
      return jsonResponse({'id': actor, 'username': 'tester'});
    }
    final projectIndex = segments.indexOf('projects');
    if (projectIndex < 0 || segments[projectIndex + 1] != '9') {
      return jsonResponse({}, status: 404);
    }
    final parts = segments.skip(projectIndex + 2).toList();
    final path = parts.join('/');
    if (r.method == 'GET') {
      if (path == failRead) return jsonResponse({}, status: 404);
      if (parts.isEmpty) {
        return jsonResponse({
          ...projectJson(projectId),
          'default_branch': defaultBranch,
        });
      }
      if (mutations > 0 && readback401) return jsonResponse({}, status: 401);
      if (mutations > 0 && badReadback) {
        return jsonResponse({'tag_name': 'foreign'});
      }
      if (parts.length == 3 &&
          parts[0] == 'repository' &&
          parts[1] == 'commits') {
        return const {'main', 'v1', _sha, _sha2}.contains(parts[2])
            ? jsonResponse({'id': sourceSha})
            : jsonResponse({}, status: 404);
      }
      final value = parts.length == 2 && parts[0] == 'releases'
          ? releases[parts[1]]
          : parts.length == 3 && parts[1] == 'branches'
          ? branches[parts[2]]
          : parts.length == 3 && parts[1] == 'tags'
          ? tags[parts[2]]
          : null;
      return value == null
          ? jsonResponse({}, status: 404)
          : jsonResponse(value);
    }
    mutations++;
    if (mutationStatus != null) {
      return jsonResponse({}, status: mutationStatus!);
    }
    final body = r.data as Map?;
    Map<String, Object?>? result;
    if (r.method == 'POST' && path == 'repository/branches') {
      final name = body!['branch'] as String;
      result = branches[name] = branch(name, sha: body['ref'] as String);
    } else if (r.method == 'POST' && path == 'repository/tags') {
      final name = body!['tag_name'] as String;
      result = tags[name] = {
        ...tag(name),
        'commit': {'id': body['ref']},
        if (body.containsKey('message')) 'message': body['message'],
      };
    } else if (r.method == 'POST' && path == 'releases') {
      result = releases[body!['tag_name'] as String] =
          Map<String, Object?>.from(body);
    } else if (r.method == 'PUT' && parts[0] == 'releases') {
      result = releases[parts[1]] = {
        ...releases[parts[1]]!,
        ...Map<String, Object?>.from(body!),
      };
    } else if (r.method == 'DELETE') {
      if (parts[0] == 'releases') releases.remove(parts[1]);
      if (parts[1] == 'branches') branches.remove(parts[2]);
      if (parts[1] == 'tags') tags.remove(parts[2]);
      return ResponseBody.fromString('', 204);
    }
    return jsonResponse(
      badResult ? {} : result,
      status: r.method == 'POST' ? 201 : 200,
    );
  }
}
