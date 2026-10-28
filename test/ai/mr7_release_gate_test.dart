import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/release_policy.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_gate.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../../tool/mr7/candidate_release_policy.dart';
import '../support/fake_adapter.dart';
import 'fx_coord_support.dart';
import 'mr6b3_support.dart';
import 'release_policy_support.dart';

final class _Secrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => const [];
}

final class _MutableView implements AiReleasePolicyView {
  _MutableView(this.writeTargets);
  @override
  final Set<String> readNames = {};
  @override
  Map<String, Set<AiTargetKind>> writeTargets;
}

final class _FutureLedger implements AiCapabilityLedger {
  const _FutureLedger();
  static const future = AiCapability(
    operationId: 'futureWrite',
    baseTier: AiWriteTier.t1,
    scopeClass: AiScopeClass.project,
  );
  @override
  AiCapability? find(String id) =>
      id == future.operationId ? future : productionAiLedger.find(id);
  @override
  List<AiCapability> get modelVisible => [future, ...ProductionAiLedger.rows];
}

void main() {
  test('compiled flags and immutable production allowlists', () {
    expect(
      aiAssistantEnabled,
      const bool.fromEnvironment('MERGELINE_AI_ASSISTANT'),
    );
    expect(const bool.fromEnvironment('MERGELINE_AI_BACKGROUND'), isFalse);
    expect(aiReleasedReadNames, isEmpty);
    expect(aiReleasedWriteTargets, isEmpty);
    expect(() => aiReleasedReadNames.add('future'), throwsUnsupportedError);
    expect(
      () => aiReleasedWriteTargets['future'] = {AiTargetKind.issue},
      throwsUnsupportedError,
    );
    expect(productionAiLedger.modelVisible, isEmpty);
    expect(
      productionAiReleasePolicy.allowsWriteOperation('futureWrite'),
      isFalse,
    );
    expect(
      productionAiReleasePolicy.allowsWrite(
        'futureWrite',
        AiTargetKind.project,
      ),
      isFalse,
    );
    expect(toolsForScope(coordScope, ledger: const _FutureLedger()), isEmpty);
    expect(toolsForScope(coordScope, ledger: fixtureAiLedger), isEmpty);
    final policy = aiProductionWritePolicy(AiAutonomyLevel.bypass);
    expect(policy.operationIds, isEmpty);
    expect(policy.hardLineOperationIds, isEmpty);
    expect(policy.catalogueVersion, 6);
    expect(policy.policyVersion, 5);
  });

  test('candidate takes a deeply immutable snapshot', () {
    final reads = {'get_issue'};
    final targets = {AiTargetKind.issue};
    final writes = {'updateWorkItemState': targets};
    final candidate = mr7CandidateReleasePolicy(
      readNames: reads,
      writeTargets: writes,
    );
    reads.clear();
    targets.clear();
    writes.clear();
    expect(candidate.readNames, {'get_issue'});
    expect(candidate.writeTargets['updateWorkItemState'], {AiTargetKind.issue});
    expect(() => candidate.readNames.clear(), throwsUnsupportedError);
    expect(() => candidate.writeTargets.clear(), throwsUnsupportedError);
    expect(
      () => candidate.writeTargets['updateWorkItemState']!.clear(),
      throwsUnsupportedError,
    );
    expect(productionAiReleasePolicy.writeTargets, isEmpty);
  });

  test(
    'consent identity tracks targets and reads, sorts input and snapshots',
    () {
      final original = _MutableView({
        'setStar': {AiTargetKind.project, AiTargetKind.issue},
        'createNote': {AiTargetKind.issue},
      })..readNames.addAll({'get_issue', 'read_file'});
      final reordered = _MutableView({
        'createNote': {AiTargetKind.issue},
        'setStar': {AiTargetKind.issue, AiTargetKind.project},
      })..readNames.addAll({'read_file', 'get_issue'});
      final changedTarget = _MutableView({
        'setStar': {AiTargetKind.mergeRequest, AiTargetKind.issue},
        'createNote': {AiTargetKind.issue},
      })..readNames.addAll({'get_issue', 'read_file'});
      final changedRead = _MutableView({
        'setStar': {AiTargetKind.project, AiTargetKind.issue},
        'createNote': {AiTargetKind.issue},
      })..readNames.addAll({'get_issue', 'get_commit'});
      String hash(AiReleasePolicyView view) => aiConsentContractFor(
        stackProviderConfig,
        releasePolicy: view,
        writePolicy: aiProductionWritePolicy(
          AiAutonomyLevel.bypass,
          releasePolicy: view,
        ),
      ).hash;
      final contract = aiConsentContractFor(
        stackProviderConfig,
        releasePolicy: original,
        writePolicy: aiProductionWritePolicy(
          AiAutonomyLevel.bypass,
          releasePolicy: original,
        ),
      );
      final savedHash = contract.hash;
      final lateHashedContract = aiConsentContractFor(
        stackProviderConfig,
        releasePolicy: original,
        writePolicy: aiProductionWritePolicy(
          AiAutonomyLevel.bypass,
          releasePolicy: original,
        ),
      );
      final lateHashedReadOnlyContract = aiCurrentConsentContractFor(
        stackProviderConfig,
        releasePolicy: original,
      );
      final savedReadOnlyHash = aiCurrentConsentContractFor(
        stackProviderConfig,
        releasePolicy: reordered,
      ).hash;
      expect(hash(reordered), savedHash);
      expect(hash(changedTarget), isNot(savedHash));
      expect(hash(changedRead), isNot(savedHash));
      expect(
        aiCurrentConsentContractFor(
          stackProviderConfig,
          releasePolicy: changedRead,
        ).hash,
        isNot(
          aiCurrentConsentContractFor(
            stackProviderConfig,
            releasePolicy: reordered,
          ).hash,
        ),
      );
      original.readNames.clear();
      original.writeTargets['setStar']!.clear();
      expect(contract.hash, savedHash);
      expect(lateHashedContract.hash, savedHash);
      expect(lateHashedReadOnlyContract.hash, savedReadOnlyHash);
    },
  );

  test('forged production reads refuse without requests', () async {
    final adapter = FakeAdapter((_) => throw StateError('unexpected request'));
    final api = testApi(adapter);
    addTearDown(api.close);
    final catalogue = AiToolCatalogue(
      port: GitLabAiReadPort(api, 9),
      scope: const AiResourceScope(
        accountKey: coordAccount,
        instanceKey: 'https://example.com/gitlab',
        projectId: 9,
        projectPath: 'team/example-9',
        current: AiResourceRef(kind: AiResourceKind.issue, id: 3),
      ),
      redactor: Redactor(secrets: _Secrets()),
    );
    final group = AiToolCatalogue.group(
      port: GitLabAiGroupReadPort(
        api,
        instance: GitLabInstance.parse('https://example.com/gitlab'),
        actorUserId: 7,
        generation: 1,
        isCurrent: () => true,
      ),
      scope: const AiGroupResourceScope(
        accountKey: coordAccount,
        instanceKey: 'https://example.com/gitlab',
        groupId: 5,
        groupFullPath: 'fixture/group',
        iid: 3,
        workItemGid: 'gid://gitlab/WorkItem/30',
      ),
      redactor: Redactor(secrets: _Secrets()),
    );
    final budget = AiToolBudget();
    expect(catalogue.specs, isEmpty);
    expect(group.specs, isEmpty);
    for (final name in {...fixtureReleasePolicy.readNames, 'future_read'}) {
      final result = await catalogue.executeResult(
        AiToolCall(id: name, name: name, arguments: const {}),
        budget: budget,
      );
      expect(result.isError, isTrue, reason: name);
      final groupResult = await group.executeResult(
        AiToolCall(id: name, name: name, arguments: const {}),
        budget: budget,
      );
      expect(groupResult.isError, isTrue, reason: name);
    }
    expect(adapter.requests, isEmpty);
  });

  test(
    'forged production writes refuse before freshness, port or journal',
    () async {
      final h = await CoordHarness.create();
      addTearDown(h.dispose);
      for (final row in [
        const _FutureLedger().modelVisible.first,
        ...ProductionAiLedger.rows,
      ]) {
        final c = h.newCoordinator(
          releasePolicy: productionAiReleasePolicy,
          ledger: const _FutureLedger(),
        );
        c.beginRun('synthetic');
        c.beginTurn();
        expect(
          await c.propose(
            AiToolCall(
              id: row.operationId,
              name: row.operationId,
              arguments: const {},
            ),
          ),
          isNull,
          reason: row.operationId,
        );
        c.stop('done');
      }
      expect(h.adapter.requests, isEmpty);
      expect(h.freshnessReads, 0);
      expect(h.portCreations, 0);
      expect(h.journal.entries(coordAccount), isEmpty);
    },
  );

  test('target mismatch refuses before any port work', () async {
    final h = await CoordHarness.create();
    addTearDown(h.dispose);
    final view = _MutableView({
      'setStar': {AiTargetKind.issue},
    });
    final c = h.newCoordinator(releasePolicy: view);
    c.beginRun('star project');
    c.beginTurn();
    expect(await c.propose(starCall('mismatch')), isNull);
    expect(h.adapter.requests, isEmpty);
    expect(h.freshnessReads, 0);
    expect(h.portCreations, 0);
    expect(h.journal.entries(coordAccount), isEmpty);
    c.stop('done');
  });

  test('explicit fixture exercises coordinator and journal', () async {
    final h = await CoordHarness.create();
    addTearDown(h.dispose);
    h.newRun('star project');
    final proposal = await h.coordinator.propose(starCall('positive'));
    expect(proposal, isNotNull);
    final outcome = await h.coordinator.approve(
      proposal!,
      typedName: proposal.tier.typedName,
    );
    expect(outcome.state, AiJournalState.succeeded);
    expect(h.mutations, 1);
    expect(h.journal.entries(coordAccount), isNotEmpty);
  });

  for (final removeTarget in [false, true]) {
    final label = removeTarget ? 'target kind' : 'operation';
    test('REST final send rechecks $label after dispatch flush', () async {
      final h = await CoordHarness.create();
      addTearDown(h.dispose);
      final view = _MutableView({
        'setStar': {AiTargetKind.project},
      });
      final c = h.newCoordinator(releasePolicy: view);
      c.beginRun('star project');
      c.beginTurn();
      final proposal = (await c.propose(starCall('revoked')))!;
      final entered = h.files.armBarrier(
        writesBeforeBarrier: 1,
        afterPersist: true,
      );
      final pending = c.approve(proposal, typedName: proposal.tier.typedName);
      await entered;
      view.writeTargets = removeTarget
          ? {
              'setStar': {AiTargetKind.issue},
            }
          : {};
      h.files.releaseBarrier();
      final outcome = await pending;
      expect(outcome.state, AiJournalState.notExecuted);
      expect(h.mutations, 0);
      expect(
        h.journal.entries(coordAccount).single.state,
        AiJournalState.notExecuted,
      );
      c.stop('done');
    });

    test('GraphQL final send rechecks $label after dispatch flush', () async {
      final view = _MutableView({
        'updateWorkItemState': {AiTargetKind.issue},
      });
      final h = await Mr6b3Harness.create(releasePolicy: view);
      addTearDown(h.dispose);
      final proposal = (await h.proposeState())!;
      h.port.afterBeforeMutation = () {
        view.writeTargets = removeTarget
            ? {
                'updateWorkItemState': {AiTargetKind.project},
              }
            : {};
      };
      final outcome = await h.approve(proposal);
      expect(h.port.events, contains('beforeReturned'));
      expect(h.port.sends, 0);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(
        h.journal.entries(mr6b3Account).single.state,
        AiJournalState.notExecuted,
      );
    });
  }

  test('all app library dependencies exclude candidate and test fixtures', () {
    final root = Directory.current.absolute;
    final rootUri = root.uri;
    final lib = Directory.fromUri(rootUri.resolve('lib/'));
    final pending = lib
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();
    final seen = <String>{};
    final directives = RegExp(
      r'''^\s*(?:import|export|part)\s+[^;]+;''',
      multiLine: true,
    );
    final literals = RegExp(r'''['"]([^'"]+\.dart)['"]''');
    while (pending.isNotEmpty) {
      final file = pending.removeLast();
      final uri = file.absolute.uri.normalizePath();
      if (!seen.add(uri.toString())) continue;
      final relative = uri.toFilePath().substring(root.path.length + 1);
      expect(relative.startsWith('tool/mr7/'), isFalse, reason: uri.toString());
      expect(relative.startsWith('test/'), isFalse, reason: uri.toString());
      if (!file.existsSync()) continue;
      final source = file.readAsStringSync();
      for (final directive in directives.allMatches(source)) {
        for (final match in literals.allMatches(directive.group(0)!)) {
          final name = match.group(1)!;
          final Uri dependency;
          if (name.startsWith('package:gitlab_mobile/')) {
            dependency = rootUri.resolve(
              'lib/${name.substring('package:gitlab_mobile/'.length)}',
            );
          } else if (!name.contains(':')) {
            dependency = uri.resolve(name);
          } else {
            continue;
          }
          pending.add(File.fromUri(dependency.normalizePath()));
        }
      }
    }
  });
}
