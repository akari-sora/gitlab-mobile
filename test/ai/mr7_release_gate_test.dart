import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/release_policy.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_gate.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../../tool/mr7/candidate_release_policy.dart';
import '../support/fake_adapter.dart';
import 'fx_coord_support.dart';
import 'mr6b3_support.dart';
import 'mr7_release_gate_support.dart';
import 'p6_support.dart';
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

/// The internal batch is normally model-hidden. A visible test-only copy
/// isolates its release gate; a separate test locks the actual hidden row.
final class _VisibleRowLedger implements AiCapabilityLedger {
  _VisibleRowLedger(AiCapability source)
    : row = AiCapability(
        operationId: source.operationId,
        baseTier: source.baseTier,
        scopeClass: source.scopeClass,
        namedMethod: source.namedMethod,
        arguments: source.arguments,
        httpCap: source.httpCap,
        readback: source.readback,
        editableField: source.editableField,
        boundary: source.boundary,
      );

  final AiCapability row;

  @override
  AiCapability? find(String id) => id == row.operationId ? row : null;

  @override
  List<AiCapability> get modelVisible => [row];
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

  test('release-gate cases cover every read and production write row', () {
    expect(mr7ReadArguments.keys.toSet(), fixtureReleasePolicy.readNames);
    expect(mr7WriteArguments.keys.toSet(), {
      for (final row in ProductionAiLedger.rows) row.operationId,
    });
  });

  for (final entry in mr7ReadArguments.entries) {
    test(
      'forged production read ${entry.key} refuses an executable call',
      () async {
        final call = AiToolCall(
          id: entry.key,
          name: entry.key,
          arguments: entry.value,
        );
        for (final view in [fixtureReleasePolicy, productionAiReleasePolicy]) {
          final released = identical(view, fixtureReleasePolicy);
          final adapter = mr7ReadAdapter();
          final api = testApi(adapter);
          addTearDown(api.close);
          final redactor = Redactor(secrets: _Secrets());
          final catalogue = entry.key == 'get_group_work_item'
              ? AiToolCatalogue.group(
                  port: GitLabAiGroupReadPort(
                    api,
                    instance: api.instance,
                    actorUserId: 7,
                    generation: 1,
                    isCurrent: () => true,
                  ),
                  scope: mr7GroupScope,
                  redactor: redactor,
                  releasePolicy: view,
                )
              : AiToolCatalogue(
                  port: GitLabAiReadPort(api, 9),
                  scope: mr7ReadScope(entry.key),
                  redactor: redactor,
                  releasePolicy: view,
                );
          final budget = AiToolBudget();
          expect(
            catalogue.specs.map((spec) => spec.name),
            released ? contains(call.name) : isEmpty,
          );
          final result = await catalogue.execute(call, budget: budget);
          expect(
            result.result.isError,
            !released,
            reason: result.result.content,
          );
          expect(adapter.requests, released ? isNotEmpty : isEmpty);
          expect(result.gitLabRequests, released ? greaterThan(0) : 0);
          expect(budget.gitLabRequests, released ? greaterThan(0) : 0);
        }
      },
    );
  }

  test('unknown project and group reads refuse without requests', () async {
    final adapter = mr7ReadAdapter();
    final api = testApi(adapter);
    addTearDown(api.close);
    final redactor = Redactor(secrets: _Secrets());
    for (final catalogue in [
      AiToolCatalogue(
        port: GitLabAiReadPort(api, 9),
        scope: mr7ReadScope('get_issue'),
        redactor: redactor,
      ),
      AiToolCatalogue.group(
        port: GitLabAiGroupReadPort(
          api,
          instance: api.instance,
          actorUserId: 7,
          generation: 1,
          isCurrent: () => true,
        ),
        scope: mr7GroupScope,
        redactor: redactor,
      ),
    ]) {
      final result = await catalogue.execute(
        AiToolCall(id: 'unknown', name: 'future_read', arguments: const {}),
        budget: AiToolBudget(),
      );
      expect(result.result.isError, isTrue);
      expect(result.gitLabRequests, 0);
    }
    expect(adapter.requests, isEmpty);
  });

  for (final row in ProductionAiLedger.rows) {
    test(
      'forged production write ${row.operationId} refuses before freshness and port',
      () async {
        final call = mr7WriteCall(row.operationId);
        for (final view in [fixtureReleasePolicy, productionAiReleasePolicy]) {
          final released = identical(view, fixtureReleasePolicy);
          final h = await CoordHarness.create(maxGitLabRequests: row.httpCap);
          addTearDown(h.dispose);
          if (row.operationId == 'upload_attachment') {
            await h.attach('shot.png', [1, 2, 3]);
          }
          final probe = Mr7WriteProbe();
          final c = h.newCoordinator(
            releasePolicy: view,
            scope: mr7WriteScope(row),
            portFactory: () => probe,
            ledger: row.modelVisible ? null : _VisibleRowLedger(row),
          );
          c.beginRun('Requested synthetic action.');
          c.beginTurn();
          expect(await c.propose(call), isNull);
          expect(
            h.freshnessReads,
            released ? 1 : 0,
            reason: c.recordedOutcomeFor(call.id)?.reasonCode,
          );
          expect(h.portCreations, released ? 1 : 0);
          expect(probe.requests, released ? hasLength(1) : isEmpty);
          if (released) {
            expect(probe.requests.single.operationId, call.name);
          } else {
            expect(
              c.recordedOutcomeFor(call.id)?.reasonCode,
              'unknownOperation',
            );
          }
          expect(h.adapter.requests, isEmpty);
          expect(h.journal.entries(coordAccount), isEmpty);
          c.stop('done');
        }
      },
    );
  }

  test(
    'internal batch has executable arguments but remains model-hidden',
    () async {
      final server = P6Server();
      addTearDown(server.api.close);
      final row = ProductionAiLedger.rows.singleWhere(
        (row) => !row.modelVisible,
      );
      expect(row.operationId, 'batchApplySuggestions');
      final call = mr7WriteCall(row.operationId);
      final prepared = await server.writePort.prepare(
        p6Request(row.operationId, {...mr7WriteArguments[row.operationId]!}),
      );
      expect(prepared.request.operationId, row.operationId);
      expect(server.adapter.requests, isNotEmpty);
      for (final view in [fixtureReleasePolicy, productionAiReleasePolicy]) {
        final h = await CoordHarness.create();
        addTearDown(h.dispose);
        final c = h.newCoordinator(releasePolicy: view);
        c.beginRun('Apply the suggestions.');
        c.beginTurn();
        expect(await c.propose(call), isNull);
        expect(h.freshnessReads, 0);
        expect(h.portCreations, 0);
        expect(h.adapter.requests, isEmpty);
        expect(h.journal.entries(coordAccount), isEmpty);
        c.stop('done');
      }
    },
  );

  test(
    'unknown future writes refuse before freshness, port or journal',
    () async {
      final h = await CoordHarness.create();
      addTearDown(h.dispose);
      final c = h.newCoordinator(
        releasePolicy: productionAiReleasePolicy,
        ledger: const _FutureLedger(),
      );
      c.beginRun('Future operation.');
      c.beginTurn();
      expect(
        await c.propose(
          AiToolCall(
            id: 'future',
            name: 'futureWrite',
            arguments: {'reason': 'Synthetic future action.'},
          ),
        ),
        isNull,
      );
      expect(h.freshnessReads, 0);
      expect(h.portCreations, 0);
      expect(h.adapter.requests, isEmpty);
      expect(h.journal.entries(coordAccount), isEmpty);
      c.stop('done');
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

  for (final revokeAfterDispatch in [false, true]) {
    final stage = revokeAfterDispatch ? 'final send' : 'prepare';
    test(
      'prepared file target release is checked at $stage with owner allowed',
      () async {
        final server = P6Server()..missing = true;
        addTearDown(server.api.close);
        final arguments = p6Args('createFile');
        final prepared = await server.writePort.prepare(
          p6Request('createFile', arguments),
        );
        expect(prepared.bindingTargets, hasLength(1));
        expect(prepared.bindingTargets.single.kind, AiTargetKind.file);
        final h = await CoordHarness.create(responder: server.respond);
        addTearDown(h.dispose);
        final view = _MutableView({
          'createFile': {
            AiTargetKind.project,
            if (revokeAfterDispatch) AiTargetKind.file,
          },
        });
        final c = h.newCoordinator(
          releasePolicy: view,
          checkFragments: mr7FragmentChecker,
        );
        c.beginRun('Create src/a.txt in team/example-9.');
        c.beginTurn();
        final call = AiToolCall(
          id: 'bound-file',
          name: 'createFile',
          arguments: {...arguments, 'reason': 'Requested new file.'},
        );
        final proposal = await c.propose(call);
        if (revokeAfterDispatch) {
          expect(proposal, isNotNull);
          final entered = h.files.armBarrier(
            writesBeforeBarrier: 1,
            afterPersist: true,
          );
          final pending = c.approve(
            proposal!,
            typedName: proposal.tier.typedName,
          );
          await entered;
          view.writeTargets = {
            'createFile': {AiTargetKind.project},
          };
          h.files.releaseBarrier();
          expect((await pending).state, AiJournalState.notExecuted);
          expect(
            h.journal.entries(coordAccount).single.state,
            AiJournalState.notExecuted,
          );
        } else {
          expect(proposal, isNull);
          expect(c.recordedOutcomeFor(call.id)?.reasonCode, 'unknownOperation');
          expect(h.journal.entries(coordAccount), isEmpty);
        }
        expect(view.allowsWrite('createFile', AiTargetKind.project), isTrue);
        expect(view.allowsWrite('createFile', AiTargetKind.file), isFalse);
        expect(h.freshnessReads, greaterThan(0));
        expect(h.portCreations, 1);
        expect(h.adapter.requests, isNotEmpty);
        expect(server.mutations, 0);
        c.stop('done');
      },
    );
  }

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
