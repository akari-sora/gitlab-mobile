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
    // v0.6.0 releases every read and every model-visible write (owner,
    // 2026-10-30); the internal suggestion batch stays hidden.
    final visible = {
      for (final row in ProductionAiLedger.rows)
        if (row.modelVisible) row.operationId,
    };
    expect(aiReleasedReadNames, fixtureReleasePolicy.readNames);
    expect(aiReleasedWriteTargets.keys.toSet(), visible);
    expect(aiReleasedWriteTargets, isNot(contains('batchApplySuggestions')));
    for (final targets in aiReleasedWriteTargets.values) {
      expect(targets, AiTargetKind.values.toSet());
      expect(() => targets.clear(), throwsUnsupportedError);
    }
    expect(() => aiReleasedReadNames.add('future'), throwsUnsupportedError);
    expect(
      () => aiReleasedWriteTargets['future'] = {AiTargetKind.issue},
      throwsUnsupportedError,
    );
    expect(
      productionAiLedger.modelVisible.map((row) => row.operationId).toSet(),
      visible,
    );
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
    final futureTools = toolsForScope(
      coordScope,
      ledger: const _FutureLedger(),
    ).map((row) => row.operationId);
    expect(futureTools, isNot(contains('futureWrite')));
    expect(futureTools, isNot(contains('batchApplySuggestions')));
    expect(toolsForScope(coordScope, ledger: fixtureAiLedger), isNotEmpty);
    final policy = aiProductionWritePolicy(AiAutonomyLevel.bypass);
    expect(policy.operationIds, isNotEmpty);
    expect(policy.operationIds, everyElement(isIn(visible)));
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
    expect(
      identical(productionAiReleasePolicy.writeTargets, aiReleasedWriteTargets),
      isTrue,
    );
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
      'production read ${entry.key} is released and executes',
      () async {
        final call = AiToolCall(
          id: entry.key,
          name: entry.key,
          arguments: entry.value,
        );
        for (final view in [fixtureReleasePolicy, productionAiReleasePolicy]) {
          final released = view.allowsRead(entry.key);
          expect(released, isTrue);
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
      'production write ${row.operationId} follows the release policy',
      () async {
        final call = mr7WriteCall(row.operationId);
        for (final view in [fixtureReleasePolicy, productionAiReleasePolicy]) {
          final released = view.allowsWriteOperation(row.operationId);
          expect(
            released,
            identical(view, fixtureReleasePolicy) || row.modelVisible,
          );
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

  test('placeholder issue fields count as not set (gpt-4o-mini)', () async {
    final row = productionAiLedger.find('updateIssue')!;
    final h = await CoordHarness.create(maxGitLabRequests: row.httpCap);
    addTearDown(h.dispose);
    final probe = Mr7WriteProbe();
    final c = h.newCoordinator(
      scope: mr7WriteScope(row),
      portFactory: () => probe,
    );
    c.beginRun('Close issue 3.');
    c.beginTurn();
    final call = AiToolCall(
      id: 'placeholders',
      name: 'updateIssue',
      arguments: {
        ...mr7WriteArguments['updateIssue']!,
        'fields': {
          'title': 'synthetic',
          'description': '',
          'labels': '',
          'assignee_ids': <int>[],
          'milestone_id': 0,
          'confidential': false,
        },
        'reason': 'Requested synthetic action.',
      },
    );
    expect(await c.propose(call), isNull);
    expect(probe.requests.single.arguments['fields'], {
      'title': 'synthetic',
      'confidential': false,
    });
    c.stop('done');
  });

  for (final item in <({
    String operation,
    Map<String, Object?> extra,
    void Function(Map<String, Object?>) verify,
  })>[
    (
      operation: 'addAwardEmoji',
      extra: {'name': 'thumbsup', 'noteId': 0},
      verify: (args) {
        expect(args['name'], 'thumbsup');
        expect(args, isNot(contains('noteId')));
      },
    ),
    (
      operation: 'removeAwardEmoji',
      extra: {'awardId': 8, 'noteId': 0},
      verify: (args) {
        expect(args['awardId'], 8);
        expect(args, isNot(contains('noteId')));
      },
    ),
    (
      operation: 'updateMergeRequest',
      extra: {
        'fields': {
          'title': 'synthetic',
          'description': '',
          'labels': '',
          'assignee_ids': <int>[0],
          'reviewer_ids': <int>[0],
          'milestone_id': 0,
        },
      },
      verify: (args) => expect(args['fields'], {'title': 'synthetic'}),
    ),
    (
      operation: 'createDiscussion',
      extra: {
        'body': 'synthetic',
        'position': {
          'position_type': 'text',
          'base_sha': mr7Base,
          'start_sha': mr7Base,
          'head_sha': mr7Head,
          'old_path': 'README.md',
          'new_path': 'README.md',
          'old_line': 0,
          'new_line': 3,
        },
      },
      verify: (args) {
        expect(args['body'], 'synthetic');
        expect(args['position'], {
          'position_type': 'text',
          'base_sha': mr7Base,
          'start_sha': mr7Base,
          'head_sha': mr7Head,
          'old_path': 'README.md',
          'new_path': 'README.md',
          'new_line': 3,
        });
      },
    ),
    (
      operation: 'createDraftNote',
      extra: {
        'body': 'synthetic',
        'commitId': '',
        'position': {
          'position_type': 'text',
          'base_sha': '',
          'start_sha': '',
          'head_sha': '',
          'old_path': '',
          'new_path': '',
          'old_line': 0,
          'new_line': 0,
        },
      },
      verify: (args) {
        expect(args['body'], 'synthetic');
        expect(args, isNot(contains('commitId')));
        expect(args, isNot(contains('position')));
      },
    ),
    (
      operation: 'createLabel',
      extra: {
        'fields': {'name': 'synthetic', 'color': '#ffffff', 'description': ''},
      },
      verify: (args) =>
          expect(args['fields'], {'name': 'synthetic', 'color': '#ffffff'}),
    ),
    (
      operation: 'updateLabel',
      extra: {
        'fields': {'name': '', 'color': '#000000', 'description': ''},
      },
      verify: (args) => expect(args['fields'], {'color': '#000000'}),
    ),
    (
      operation: 'createMilestone',
      extra: {
        'fields': {
          'title': 'synthetic',
          'description': '',
          'due_date': '',
          'start_date': '2026-10-01',
        },
      },
      verify: (args) => expect(args['fields'], {
        'title': 'synthetic',
        'start_date': '2026-10-01',
      }),
    ),
    (
      operation: 'updateMilestone',
      extra: {
        'fields': {
          'title': 'synthetic',
          'description': '',
          'due_date': '',
          'start_date': '',
        },
      },
      verify: (args) => expect(args['fields'], {'title': 'synthetic'}),
    ),
    (
      operation: 'moveBoardCard',
      extra: {
        'fields': {'labels': '', 'state_event': 'close'},
      },
      verify: (args) => expect(args['fields'], {
        'labels': '',
        'state_event': 'close',
      }),
    ),
    (
      operation: 'applySuggestion',
      extra: {'suggestionId': 5, 'commitMessage': ''},
      verify: (args) {
        expect(args['suggestionId'], 5);
        expect(args, isNot(contains('commitMessage')));
      },
    ),
    (
      operation: 'updateWorkItemContent',
      extra: {'title': 'Synthetic title', 'description': ''},
      verify: (args) {
        expect(args['title'], 'Synthetic title');
        expect(args, isNot(contains('description')));
      },
    ),
    (
      operation: 'updateWorkItemDates',
      extra: {
        'mode': 'manual',
        'startDate': '',
        'dueDate': '2026-11-01',
        'clearStart': null,
      },
      verify: (args) {
        expect(args['dueDate'], '2026-11-01');
        expect(args, isNot(contains('startDate')));
        expect(args, isNot(contains('clearStart')));
      },
    ),
    (
      operation: 'updateWorkItemMilestone',
      extra: {'milestoneTitle': '', 'clearMilestone': true},
      verify: (args) {
        expect(args['clearMilestone'], isTrue);
        expect(args, isNot(contains('milestoneTitle')));
      },
    ),
    (
      operation: 'updateWorkItemWeight',
      extra: {'weight': 0, 'clearWeight': null},
      verify: (args) {
        expect(args['weight'], 0);
        expect(args, isNot(contains('clearWeight')));
      },
    ),
    (
      operation: 'updateGroupWorkItemDates',
      extra: {
        'mode': 'manual',
        'startDate': '',
        'dueDate': '2026-11-01',
        'clearStart': null,
      },
      verify: (args) {
        expect(args['dueDate'], '2026-11-01');
        expect(args, isNot(contains('startDate')));
        expect(args, isNot(contains('clearStart')));
      },
    ),
    (
      operation: 'updateGroupWorkItemMilestone',
      extra: {'milestoneTitle': '', 'clearMilestone': true},
      verify: (args) {
        expect(args['clearMilestone'], isTrue);
        expect(args, isNot(contains('milestoneTitle')));
      },
    ),
    (
      operation: 'updateGroupWorkItemWeight',
      extra: {'weight': 0, 'clearWeight': null},
      verify: (args) {
        expect(args['weight'], 0);
        expect(args, isNot(contains('clearWeight')));
      },
    ),
    (
      operation: 'updateGroupWorkItemContent',
      extra: {'title': 'Synthetic title', 'description': ''},
      verify: (args) {
        expect(args['title'], 'Synthetic title');
        expect(args, isNot(contains('description')));
      },
    ),
    (
      operation: 'createTag',
      extra: {'tag_name': 'v2/test', 'ref': 'main', 'message': ''},
      verify: (args) {
        expect(args['tag_name'], 'v2/test');
        expect(args, isNot(contains('message')));
      },
    ),
    (
      operation: 'createRelease',
      extra: {
        'fields': {
          'tag_name': 'v1',
          'name': 'Version One',
          'description': '',
        },
      },
      verify: (args) => expect(args['fields'], {
        'tag_name': 'v1',
        'name': 'Version One',
      }),
    ),
    (
      operation: 'updateRelease',
      extra: {
        'fields': {'name': 'Revised', 'description': ''},
      },
      verify: (args) => expect(args['fields'], {'name': 'Revised'}),
    ),
    (
      operation: 'mergeRequest',
      extra: {
        'squash': false,
        'autoMerge': null,
        'removeSourceBranch': null,
      },
      verify: (args) {
        expect(args['squash'], isFalse);
        expect(args, isNot(contains('autoMerge')));
        expect(args, isNot(contains('removeSourceBranch')));
      },
    ),
    (
      operation: 'createPipeline',
      extra: {
        'ref': 'feature/test',
        'variables': <Object?>[
          {'key': 'BUILD_TARGET', 'value': '', 'variable_type': ''},
        ],
      },
      verify: (args) => expect(args['variables'], [
        {'key': 'BUILD_TARGET', 'value': ''},
      ]),
    ),
    (
      operation: 'createSnippet',
      extra: {'title': 'Snippet', 'description': '', 'visibility': ''},
      verify: (args) {
        expect(args['title'], 'Snippet');
        expect(args, isNot(contains('description')));
        expect(args, isNot(contains('visibility')));
      },
    ),
    (
      operation: 'updateSnippetMetadata',
      extra: {
        'fields': {'title': 'Revised', 'description': '', 'visibility': ''},
      },
      verify: (args) => expect(args['fields'], {'title': 'Revised'}),
    ),
    (
      operation: 'updateSnippetFiles',
      extra: {
        'actions': <Object?>[
          {
            'action': 'create',
            'file_path': 'b.txt',
            'content': '',
            'previous_path': '',
            'edits': <Object?>[],
          },
        ],
      },
      verify: (args) => expect(args['actions'], [
        {'action': 'create', 'file_path': 'b.txt', 'content': ''},
      ]),
    ),
    (
      operation: 'createProject',
      extra: {
        'name': 'New project',
        'path': 'new-project',
        'description': '',
      },
      verify: (args) {
        expect(args['name'], 'New project');
        expect(args, isNot(contains('description')));
      },
    ),
    (
      operation: 'editProject',
      extra: {'name': 'Edited project', 'description': ''},
      verify: (args) {
        expect(args['name'], 'Edited project');
        expect(args, isNot(contains('description')));
      },
    ),
  ]) {
    test(
      'placeholder ${item.operation} fields count as not set (gpt-4o-mini)',
      () async {
        final row = productionAiLedger.find(item.operation)!;
        final h = await CoordHarness.create(maxGitLabRequests: row.httpCap);
        addTearDown(h.dispose);
        final probe = Mr7WriteProbe();
        final c = h.newCoordinator(
          scope: mr7WriteScope(row),
          portFactory: () => probe,
        );
        c.beginRun('Requested synthetic action.');
        c.beginTurn();
        final call = AiToolCall(
          id: 'placeholders-${item.operation}',
          name: item.operation,
          arguments: {
            ...mr7WriteArguments[item.operation]!,
            ...item.extra,
            'reason': 'Requested synthetic action.',
          },
        );
        expect(await c.propose(call), isNull);
        item.verify(probe.requests.single.arguments);
        c.stop('done');
      },
    );
  }

  for (final item in <({
    String label,
    String operation,
    Map<String, Object?> arguments,
    void Function(Map<String, Object?>) verify,
  })>[
    (
      label: 'moveBoardCard labels clear',
      operation: 'moveBoardCard',
      arguments: {
        'projectId': 9,
        'iid': 3,
        'fields': {'labels': ''},
      },
      verify: (args) => expect(args['fields'], {'labels': ''}),
    ),
    (
      label: 'updateWorkItemContent description clear',
      operation: 'updateWorkItemContent',
      arguments: {'projectId': 9, 'iid': 3, 'description': ''},
      verify: (args) => expect(args['description'], ''),
    ),
    (
      label: 'updateGroupWorkItemContent description clear',
      operation: 'updateGroupWorkItemContent',
      arguments: {'groupId': 7, 'iid': 5, 'description': ''},
      verify: (args) => expect(args['description'], ''),
    ),
    (
      label: 'updateMilestone due_date clear',
      operation: 'updateMilestone',
      arguments: {
        'projectId': 9,
        'milestoneId': 8,
        'fields': {'due_date': ''},
      },
      verify: (args) => expect(args['fields'], {'due_date': ''}),
    ),
    (
      label: 'updateMilestone start_date clear',
      operation: 'updateMilestone',
      arguments: {
        'projectId': 9,
        'milestoneId': 8,
        'fields': {'start_date': ''},
      },
      verify: (args) => expect(args['fields'], {'start_date': ''}),
    ),
    (
      label: 'updateMilestone description clear',
      operation: 'updateMilestone',
      arguments: {
        'projectId': 9,
        'milestoneId': 8,
        'fields': {'description': ''},
      },
      verify: (args) => expect(args['fields'], {'description': ''}),
    ),
    (
      label: 'updateRelease description clear',
      operation: 'updateRelease',
      arguments: {
        'projectId': 9,
        'tag_name': 'v1',
        'fields': {'description': ''},
      },
      verify: (args) => expect(args['fields'], {'description': ''}),
    ),
    (
      label: 'updateLabel description clear',
      operation: 'updateLabel',
      arguments: {
        'projectId': 9,
        'labelId': 8,
        'fields': {'description': ''},
      },
      verify: (args) => expect(args['fields'], {'description': ''}),
    ),
    (
      label: 'updateSnippetMetadata description clear',
      operation: 'updateSnippetMetadata',
      arguments: {
        'projectId': 9,
        'snippetId': 7,
        'fields': {'description': ''},
      },
      verify: (args) => expect(args['fields'], {'description': ''}),
    ),
    (
      label: 'editProject description clear',
      operation: 'editProject',
      arguments: {'projectId': 9, 'description': ''},
      verify: (args) => expect(args['description'], ''),
    ),
  ]) {
    test('single-clear ${item.label} keeps original arguments', () async {
      final row = productionAiLedger.find(item.operation)!;
      final h = await CoordHarness.create(maxGitLabRequests: row.httpCap);
      addTearDown(h.dispose);
      final probe = Mr7WriteProbe();
      final c = h.newCoordinator(
        scope: mr7WriteScope(row),
        portFactory: () => probe,
      );
      c.beginRun('Requested synthetic action.');
      c.beginTurn();
      final call = AiToolCall(
        id: 'single-clear-${item.operation}',
        name: item.operation,
        arguments: {
          ...item.arguments,
          'reason': 'Requested synthetic action.',
        },
      );
      expect(await c.propose(call), isNull);
      item.verify(probe.requests.single.arguments);
      c.stop('done');
    });
  }

  test('dates placeholder-only request does not become mode-only', () async {
    for (final operation in [
      'updateWorkItemDates',
      'updateGroupWorkItemDates',
    ]) {
      final row = productionAiLedger.find(operation)!;
      final coords = operation == 'updateWorkItemDates'
          ? <String, Object?>{'projectId': 9, 'iid': 3}
          : <String, Object?>{'groupId': 7, 'iid': 5};
      final h = await CoordHarness.create(maxGitLabRequests: row.httpCap);
      addTearDown(h.dispose);
      final probe = Mr7WriteProbe();
      final c = h.newCoordinator(
        scope: mr7WriteScope(row),
        portFactory: () => probe,
      );
      c.beginRun('Requested synthetic action.');
      c.beginTurn();
      final withNull = AiToolCall(
        id: 'dates-null-$operation',
        name: operation,
        arguments: {
          ...coords,
          'mode': 'manual',
          'startDate': '',
          'dueDate': '',
          'clearStart': null,
          'reason': 'Requested synthetic action.',
        },
      );
      expect(await c.propose(withNull), isNull);
      expect(c.recordedOutcomeFor(withNull.id)?.reasonCode, 'invalidArguments');
      expect(probe.requests, isEmpty);

      c.beginTurn();
      final emptyDates = AiToolCall(
        id: 'dates-empty-$operation',
        name: operation,
        arguments: {
          ...coords,
          'mode': 'manual',
          'startDate': '',
          'dueDate': '',
          'reason': 'Requested synthetic action.',
        },
      );
      expect(await c.propose(emptyDates), isNull);
      expect(probe.requests.single.arguments['startDate'], '');
      expect(probe.requests.single.arguments['dueDate'], '');
      c.stop('done');
    }
  });

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
