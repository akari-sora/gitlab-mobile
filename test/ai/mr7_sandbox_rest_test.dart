import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';

import '../../tool/mr7/rest_scenarios.dart';
import '../../tool/mr7/sandbox_contract.dart';
import '../../tool/mr7_sandbox.dart';

const _sha = '2f01ba41ad1559230924e7afc3b6f8876320a55a';

List<Map<String, Object?>> _rows(Map<String, Object?> receipt) =>
    (receipt['scenarios']! as List).cast<Map<String, Object?>>();
Map<String, Object?> _part(Map<String, Object?> receipt, String name) =>
    (receipt[name]! as Map).cast<String, Object?>();
Mr7Scenario _case(String operation, String variant) => mr7RestCases()
    .singleWhere((c) => c.operation == operation && c.variant == variant)
    .scenario!;

Mr7SandboxSession _session(Mr7SyntheticGitLab server, {int requestCap = 200}) =>
    Mr7SandboxSession(
      server: server,
      nonce: 'b1syntheticnonce123',
      requestCap: requestCap,
      eventDelay: () async {},
    );

Future<Map<String, Object?>> _run(
  List<Mr7Scenario> scenarios, {
  Mr7SyntheticGitLab? server,
  Mr7Confirm? confirm,
  Mr7TypedConfirm? typedConfirm,
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
  Mr7Policy policy = Mr7Policy.candidate,
  int requestCap = 200,
}) async {
  final synthetic = server ?? Mr7SyntheticGitLab();
  if (server == null) {
    configureMr7RestFixtures(
      synthetic,
      scenario: scenarios.length == 1 ? scenarios.single : null,
    );
  }
  return runMr7Sandbox(
    policy: policy,
    releaseSha: _sha,
    suite: 'rest',
    scenarios: scenarios,
    session: _session(synthetic, requestCap: requestCap),
    level: level,
    confirm: confirm ?? (_) async => true,
    typedConfirm: typedConfirm ?? (_) async => '#1',
  );
}

/// Change one proposed input while keeping the actual runner and boundaries.
Mr7Scenario _callWith(Mr7Scenario source, Map<String, Object?> arguments) =>
    Mr7Scenario(
      id: source.id,
      suite: source.suite,
      operation: source.operation,
      variant: source.variant,
      tier: source.tier,
      call: (p) {
        final call = source.call(p);
        return AiToolCall(
          id: call.id,
          name: call.name,
          arguments: {...call.arguments! as Map<String, Object?>, ...arguments},
        );
      },
      targetKind: source.targetKind,
      paths: source.paths,
      observe: source.observe,
      freshness: source.freshness,
      utterance: source.utterance,
      resource: source.resource,
      readbackPaths: source.readbackPaths,
    );

void main() {
  final cases = mr7RestCases();
  final executable = cases.where((c) => c.scenario != null).toList();

  test('REST inventory equals all 31 production T1/T2 rows', () {
    expect(
      cases.map((c) => c.operation).toSet(),
      aiT12Rows.map((r) => r.operationId).toSet(),
    );
    expect(cases.map((c) => c.operation).toSet(), hasLength(31));
    expect(cases.map((c) => c.id).toSet(), hasLength(cases.length));
    expect(mr7RestScenarios().map((s) => s.id), executable.map((c) => c.id));
    expect(mr7RestPlanRows, [8, 9, 14, 19, 20, 23, 32]);
    expect(mr7RestEvidenceGaps.keys, unorderedEquals(mr7RestPlanRows));
    for (final row in aiT12Rows.where((r) => r.editableField != null)) {
      expect(
        cases.any(
          (c) =>
              c.operation == row.operationId &&
              c.variant == 'confirmation-edited-text' &&
              c.closedReason != null,
        ),
        isTrue,
        reason: row.operationId,
      );
    }
    for (final c in cases) {
      expect(c.fixture, isNotEmpty);
      expect(c.confirmation, contains('confirmation'));
      expect(c.chain, contains('uncached observer'));
      expect(c.events, contains('cleanup'));
      expect(c.cleanup, contains('quarantine'));
      expect(c.live, 'NOT_RUN');
      if (c.scenario == null) {
        expect(c.closedReason, isNotEmpty, reason: c.id);
      } else {
        expect(c.scenario!.id, c.id);
        expect(c.scenario!.operation, c.operation);
        expect(c.scenario!.variant, c.variant);
        expect(c.scenario!.tier, c.tier);
      }
    }
    const requiredClosed = {
      'removeAwardEmoji': '204',
      'markTodoDone': '/todos',
      'createTodo': 'account todo',
      'unapproveMergeRequest': 'approvals',
      'createDiscussion': 'string',
      'createDiscussionNote': 'membership',
      'updateDiscussionNote': 'membership',
      'setDiscussionResolved': 'string',
      'createMilestone': 'iid',
      'updateMilestone': 'iid',
      'setMilestoneState': 'iid',
      'upload_attachment': 'AiAttachmentSession',
    };
    for (final entry in requiredClosed.entries) {
      final variants = cases.where((c) => c.operation == entry.key);
      expect(variants, isNotEmpty);
      for (final c in variants) {
        expect(c.scenario, isNull, reason: c.id);
        expect(
          c.closedReason,
          contains(
            c.variant == 'confirmation-edited-text'
                ? 'editedText'
                : entry.value,
          ),
          reason: c.id,
        );
      }
    }
    expect(
      cases
          .where((c) => c.operation == 'upload_attachment')
          .map((c) => c.variant),
      containsAll([
        'multipart-memory',
        'slow-timeout',
        'metadata-only-provider',
        'same-field-roundtrip',
        'crossnonce',
        'restored-history',
        'hiddenSpan',
        'picker-process-cleanup',
      ]),
    );
  });

  for (final c in executable) {
    test(
      'REST receipt ${c.id} confirms one write and independent fields',
      () async {
        final server = Mr7SyntheticGitLab();
        configureMr7RestFixtures(server, scenario: c.scenario);
        final receipt = await _run([c.scenario!], server: server);
        final row = _rows(receipt).single;
        expect(row['status'], 'PASS', reason: jsonEncode(row));
        expect(receipt['status'], 'PASS', reason: jsonEncode(receipt));
        expect(row['readback'], 'PASS');
        expect(row['observerRequests'], greaterThan(0));
        expect(row['outcome'], 'succeeded');
        expect(row['mutationCount'], 1);
        expect(row['operation'], c.operation);
        expect(row['variant'], c.variant);
        expect(
          row['tier'],
          c.tier,
        ); // Declared tier, not a product-tier receipt.
        expect(row['fixtureDigest'], matches(r'^[0-9a-f]{64}$'));
        expect(row['payloadDigest'], matches(r'^[0-9a-f]{64}$'));
        expect(row['confirmation'], 'explicitSyntheticTestHook');
        expect(
          DateTime.parse(
            row['confirmAt']! as String,
          ).isBefore(DateTime.parse(row['proposalAt']! as String)),
          isFalse,
        );
        expect(row['live'], 'NOT_RUN');
        expect(receipt['transport'], 'synthetic');
        expect(receipt['evidenceClass'], 'CANDIDATE_ONLY');
        expect(receipt['finalEligible'], isFalse);
        expect(receipt['secretLeakScan'], 'PASS');
        expect(_part(row, 'provider')['calls'], greaterThanOrEqualTo(1));
        expect(_part(row, 'provider')['secretLeakScan'], 'PASS');
        expect(_part(receipt, 'coverage')['rest'], 'SYNTHETIC');
        expect(_part(receipt, 'coverage')['graphql'], 'NOT_RUN');
        expect(_part(receipt, 'events')['status'], 'PASS');
        final events = (_part(receipt, 'events')['items']! as List)
            .cast<Map<String, Object?>>();
        expect(events, hasLength(3)); // setup, case mutation, cleanup
        expect(events.every((e) => e['projectId'] == server.projectId), isTrue);
        expect(_part(receipt, 'cleanup')['deletionVerified'], isTrue);
        expect(receipt['quarantined'], isFalse);
        expect(server.scenarioWrites, 1);
        expect(server.setupWrites, 1);
        expect(server.cleanupWrites, 1);
        final ledger = (receipt['requestLedger']! as List)
            .cast<Map<String, Object?>>();
        expect(ledger.map((r) => r['operation']), [
          'harnessSetup',
          c.operation,
          'harnessCleanup',
        ]);
        expect(ledger.every((r) => r['projectId'] == server.projectId), isTrue);
        expect(server.requests.last, startsWith('GET users/7/events'));
        expect(
          server.requests.where((r) => r.startsWith('GET projects/909')).length,
          greaterThan(3),
        );
        expect(jsonEncode(receipt), isNot(contains('synthetic-gitlab-pat')));
        expect(jsonEncode(receipt), isNot(contains('Synthetic note.')));
      },
    );
  }

  for (final level in AiAutonomyLevel.values) {
    for (final source in [
      _case('setStar', 'star'),
      _case('createNote', 'issue'),
    ]) {
      test(
        'REST ${source.operation} autonomy ${level.name} keeps sandbox confirm',
        () async {
          var confirmations = 0;
          final receipt = await _run(
            [source],
            level: level,
            confirm: (_) async {
              confirmations++;
              return true;
            },
          );
          final row = _rows(receipt).single;
          expect(
            row['mutationCount'],
            level == AiAutonomyLevel.readOnly ? 0 : 1,
          );
          expect(
            row['status'],
            level == AiAutonomyLevel.readOnly ? 'NOT_RUN' : 'PASS',
          );
          expect(
            confirmations,
            level == AiAutonomyLevel.readOnly ? 0 : greaterThan(0),
          );
          final rejected = await _run(
            [source],
            level: level,
            confirm: (_) async => false,
          );
          expect(_rows(rejected).single['mutationCount'], 0);
          expect(_rows(rejected).single['status'], isNot('PASS'));
          if (_rows(rejected).single['status'] == 'writeUncertain') {
            expect(rejected['quarantined'], isTrue);
          }
        },
      );
    }
  }

  test(
    'REST confidential lowering still requires exact typed target in bypass',
    () async {
      final source = _case('updateIssue', 'confidential-lowered');
      for (final typed in <String?>[null, 'wrong', '#1']) {
        final required = <String?>[];
        final receipt = await _run(
          [source],
          level: AiAutonomyLevel.bypass,
          typedConfirm: (proposal) async {
            required.add(proposal.requiredTypedName);
            return typed;
          },
        );
        expect(required, ['#1']);
        final row = _rows(receipt).single;
        expect(row['mutationCount'], typed == '#1' ? 1 : 0);
        expect(row['typedInputMatches'], typed == '#1');
        expect(row['status'], typed == '#1' ? 'PASS' : isNot('PASS'));
      }
    },
  );

  test(
    'REST production receipts keep every candidate operation releaseClosed',
    () async {
      var confirmations = 0;
      final receipt = await _run(
        mr7RestScenarios(),
        policy: Mr7Policy.production,
        confirm: (_) async {
          confirmations++;
          return true;
        },
      );
      expect(confirmations, 0);
      expect(_rows(receipt), hasLength(executable.length));
      for (final row in _rows(receipt)) {
        expect(row['status'], 'NOT_RUN');
        expect(row['reason'], 'releaseClosed');
        expect(row['mutationCount'], 0);
        expect(row['readback'], 'NOT_RUN');
      }
      expect(_part(receipt, 'coverage')['rest'], 'NOT_RUN');
      expect(receipt['finalEligible'], isFalse);
    },
  );

  test(
    'REST definitions compose serially with one sandbox and finalizer',
    () async {
      final server = Mr7SyntheticGitLab()..eventPageSize = 100;
      configureMr7RestFixtures(server);
      final receipt = await _run(
        mr7RestScenarios(),
        server: server,
        requestCap: 5000,
      );
      expect(receipt['status'], 'PASS', reason: jsonEncode(receipt));
      expect(_rows(receipt), hasLength(executable.length));
      for (final row in _rows(receipt)) {
        expect(row['status'], 'PASS', reason: jsonEncode(row));
        expect(row['readback'], 'PASS');
        expect(row['mutationCount'], 1);
      }
      expect(server.scenarioWrites, executable.length);
      expect(server.setupWrites, 1);
      expect(server.cleanupWrites, 1);
      expect(_part(receipt, 'cleanup')['deletionVerified'], isTrue);
      expect(_part(receipt, 'events')['status'], 'PASS');
      expect(receipt['requestCount'], lessThanOrEqualTo(5000));
    },
  );

  test(
    'REST transition variants refuse already-matching fixture states',
    () async {
      for (final source in [
        _case('setStar', 'unstar'),
        _case('setSubscribed', 'issue-off'),
        _case('setSubscribed', 'mr-off'),
        _case('updateIssue', 'reopen'),
        _case('updateMergeRequest', 'reopen'),
        _case('moveBoardCard', 'reopen'),
        _case('setBoardSystemListHidden', 'backlog-shown'),
        _case('setBoardSystemListHidden', 'closed-shown'),
      ]) {
        final server = Mr7SyntheticGitLab();
        // Deliberately omit the isolated variant selector: all these seeds
        // already match the requested final state and must not count as changes.
        configureMr7RestFixtures(server);
        final receipt = await _run([source], server: server);
        expect(
          _rows(receipt).single['status'],
          isNot('PASS'),
          reason: source.id,
        );
        expect(_rows(receipt).single['mutationCount'], 0, reason: source.id);
        expect(server.scenarioWrites, 0, reason: source.id);
      }
    },
  );

  test(
    'REST field mismatch stops later cases despite successful core outcome',
    () async {
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server);
      // Core REST readback checks transport success; this observer must check fields.
      final update = _case('updateNote', 'issue');
      server.routes['GET projects/909/issues/1/notes/301'] = (_) => mr7Json({
        'id': 301,
        'project_id': 909,
        'body': 'Synthetic original.',
        'updated_at': '2026-10-29T00:00:00.000Z',
        'author': {'id': 7},
      });
      final receipt = await _run([
        update,
        _case('setStar', 'star'),
      ], server: server);
      final rows = _rows(receipt);
      expect(rows.first['outcome'], 'succeeded');
      expect(rows.first['readback'], 'NOT_VERIFIED');
      expect(rows.first['status'], 'NOT_VERIFIED');
      expect(rows.last['status'], 'NOT_RUN');
      expect(rows.last['reason'], 'sessionStopped');
      expect(rows.last['mutationCount'], 0);
      expect(server.scenarioWrites, 1);
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
    },
  );

  for (final operation in ['setStar', 'createNote', 'createDraftNote']) {
    test('REST $operation lost reply stops without retry or cleanup', () async {
      final server = Mr7SyntheticGitLab()..lostWriteReply = true;
      configureMr7RestFixtures(server);
      final source = executable
          .firstWhere((c) => c.operation == operation)
          .scenario!;
      final receipt = await _run([
        source,
        _case('setStar', 'unstar'),
      ], server: server);
      final rows = _rows(receipt);
      expect(rows.first['status'], 'writeUncertain');
      expect(rows.first['mutationCount'], 1);
      expect(rows.first['readback'], 'NOT_RUN');
      expect(rows.last['status'], 'NOT_RUN');
      expect(rows.last['mutationCount'], 0);
      expect(rows.last['reason'], 'sessionStopped');
      expect(server.scenarioWrites, 1);
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
    });
  }

  test('REST no observer request cannot close a successful write', () async {
    final source = _case('setStar', 'star');
    final skip = Mr7Scenario(
      id: source.id,
      suite: 'rest',
      operation: source.operation,
      variant: 'unverified',
      tier: source.tier,
      call: source.call,
      paths: source.paths,
      observe: (_, _) async => true,
    );
    final receipt = await _run([skip, _case('setStar', 'unstar')]);
    expect(_rows(receipt).first['observerRequests'], 0);
    expect(_rows(receipt).first['status'], 'NOT_VERIFIED');
    expect(_rows(receipt).last['status'], 'NOT_RUN');
    expect(receipt['quarantined'], isTrue);
  });

  test(
    'REST foreign project proposal never reaches synthetic server',
    () async {
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server);
      final forged = _callWith(_case('setStar', 'star'), {
        'projectId': mr7ProtectedProjectId,
      });
      final receipt = await _run([forged], server: server);
      expect(_rows(receipt).single['status'], isNot('PASS'));
      expect(_rows(receipt).single['mutationCount'], 0);
      expect(server.scenarioWrites, 0);
      expect(
        server.requests.any((r) => r.contains('$mr7ProtectedProjectId')),
        isFalse,
      );
    },
  );

  test(
    'REST stale API version after confirmation blocks exact update',
    () async {
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server);
      final receipt = await _run(
        [_case('updateNote', 'issue')],
        server: server,
        confirm: (_) async {
          server.routes['GET projects/909/issues/1/notes/301'] = (_) =>
              mr7Json({
                'id': 301,
                'project_id': 909,
                'body': 'Concurrent synthetic edit.',
                'updated_at': '2026-10-29T00:01:00.000Z',
                'author': {'id': 7},
              });
          return true;
        },
      );
      expect(_rows(receipt).single['mutationCount'], 0);
      expect(_rows(receipt).single['reason'], 'targetChanged');
      expect(server.scenarioWrites, 0);
    },
  );

  for (final body in [
    'synthetic-provider-key',
    '![image](https://foreign.invalid/x.png)',
    '[[attachment:att-1]]',
    '[[upload:foreignnonce-1]]',
  ]) {
    test(
      'REST unsafe text ${body.split(':').first} is refused before mutation',
      () async {
        final server = Mr7SyntheticGitLab();
        configureMr7RestFixtures(server);
        final receipt = await _run([
          _callWith(_case('createNote', 'issue'), {'body': body}),
        ], server: server);
        expect(_rows(receipt).single['status'], isNot('PASS'));
        expect(_rows(receipt).single['mutationCount'], 0);
        expect(server.scenarioWrites, 0);
        expect(jsonEncode(receipt), isNot(contains(body)));
      },
    );
  }

  test(
    'REST foreign event quarantines the session and all later cases',
    () async {
      final server = Mr7SyntheticGitLab();
      configureMr7RestFixtures(server);
      final receipt = await _run(
        [_case('createNote', 'issue'), _case('setStar', 'star')],
        server: server,
        confirm: (_) async {
          server.addEvent(target: 123456);
          return true;
        },
      );
      expect(_rows(receipt).last['status'], 'NOT_RUN');
      expect(_rows(receipt).last['mutationCount'], 0);
      expect(_part(receipt, 'events')['status'], 'NOT_VERIFIED');
      expect(server.cleanupWrites, 0);
      expect(receipt['quarantined'], isTrue);
    },
  );

  test('REST measured transport cap stops subsequent cases', () async {
    final receipt = await _run([
      _case('setStar', 'star'),
      _case('createNote', 'issue'),
    ], requestCap: 20);
    expect(receipt['requestCount'], lessThanOrEqualTo(20));
    expect(receipt['quarantined'], isTrue);
    expect(_rows(receipt).last['status'], 'NOT_RUN');
    expect(_rows(receipt).last['mutationCount'], 0);
  });

  test(
    'REST ledger allowances fit production request budget without changing it',
    () {
      for (final operation in cases.map((c) => c.operation).toSet()) {
        final row = productionAiLedger.find(operation)!;
        expect(row.httpCap, inInclusiveRange(1, 40));
        expect(aiWriteRequestAllowance(operation), row.httpCap);
        expect(AiToolBudget().maxGitLabRequests, 40);
      }
    },
  );
}
