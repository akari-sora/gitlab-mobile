import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/graphql_write_classify.dart';
import 'package:gitlab_mobile/core/ai/tools/graphql_write_hooks.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart'
    show AiWriteFreshness;
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/features/ai/ai_chat_context.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import 'fx_coord_support.dart';
import 'mr6b3g_support.dart';
import 'runner_test.dart' as runner_test show Harness, call, spec;

void _gate(bool value) {
  aiGroupWorkItemWritesEnabledForTesting = value;
  addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
}

port.AiWriteRequest _request({
  String operation = 'updateGroupWorkItemContent',
  Map<String, Object?> args = const {
    'groupId': 7,
    'iid': 5,
    'description': 'Safe',
  },
  AiWriteScope scope = g0eScope,
}) => port.AiWriteRequest(
  operationId: operation,
  executionId: 'g0e-resolve',
  scope: scope,
  arguments: args,
);

Map<String, Object?> _namespace({
  int groupId = 7,
  int iid = 5,
  String path = g0ePath,
  String title = 'Group item',
}) => {
  'id': 'gid://gitlab/Group/$groupId',
  'fullPath': path,
  'workItem': {
    'id': 'gid://gitlab/WorkItem/91',
    'iid': '$iid',
    'title': title,
    'state': 'OPEN',
    'createdAt': '2026-10-01T00:00:00Z',
    'updatedAt': '2026-10-02T00:00:00Z',
    'project': null,
    'namespace': {'id': 'gid://gitlab/Group/$groupId', 'fullPath': path},
    'workItemType': {'id': 'gid://gitlab/WorkItems::Type/1', 'name': 'Task'},
    'widgets': <Object?>[],
  },
};

bool _groupRowsAreHidden(Iterable<AiCapability> rows) => rows.every(
  (row) =>
      !row.modelVisible &&
      row.boundary == AiWriteBoundary.graph &&
      row.scopeClass == AiScopeClass.groupWorkItem,
);

text.AiFieldProvenance _titleField(G0eHarness harness) {
  final description = text.AiFieldProvenance.groupWorkItem(
    identity: g0eIdentity(harness.api),
    completeValue: true,
  );
  return text.AiFieldProvenance(
    resourceKey: description.resourceKey,
    fieldName: 'title',
    completeValue: true,
    resourceWeb: description.resourceWeb,
    accountKey: description.accountKey,
    groupId: description.groupId,
    groupFullPath: description.groupFullPath,
  );
}

final class _TitleSecrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => const [];
}

/// Both delivery paths use their production reader and projection over the
/// same synthetic server value as the coordinator's complete opening.
Future<
  ({Future<void> Function(bool whole) deliver, AiToolCatalogue? catalogue})
>
_titleDelivery(G0eHarness harness, String source) async {
  final title = harness.graph.currentFields['title']!;
  final adapter = FakeAdapter((request) {
    if (request.method == 'GET') {
      expect(request.uri.path, '/gitlab/api/v4/groups/7');
      return jsonResponse({
        'id': 7,
        'full_path': g0ePath,
        'visibility': 'private',
      });
    }
    expect(request.uri.path, '/gitlab/api/graphql');
    expect((request.data! as Map)['query'], namespaceWorkItemQuery);
    expect((request.data! as Map)['variables'], {'path': g0ePath, 'iid': '5'});
    final namespace = _namespace(title: title);
    (namespace['workItem']! as Map<String, Object?>)['widgets'] = [
      if (harness.graph.currentFields.containsKey('description'))
        {
          'type': 'DESCRIPTION',
          'description': harness.graph.currentFields['description'],
          'edited': false,
        },
    ];
    return jsonResponse({
      'data': {'namespace': namespace},
    });
  });
  final api = testApi(adapter);
  addTearDown(api.close);
  final redactor = Redactor(secrets: _TitleSecrets());
  if (source == 'catalogue output') {
    final catalogue = AiToolCatalogue.group(
      port: GitLabAiGroupReadPort(
        api,
        instance: api.instance,
        actorUserId: 7,
        generation: 7,
        isCurrent: () => true,
      ),
      scope: AiGroupResourceScope(
        accountKey: g0eAccount,
        instanceKey: api.instance.key,
        groupId: 7,
        groupFullPath: g0ePath,
        iid: 5,
        workItemGid: 'gid://gitlab/WorkItem/91',
      ),
      redactor: redactor,
      placeholders: harness.placeholders,
    );
    return (
      catalogue: catalogue,
      deliver: (bool whole) async {
        final result = await catalogue.execute(
          AiToolCall(
            id: 'title-read',
            name: 'get_group_work_item',
            arguments: {'groupId': 7, 'iid': 5},
          ),
          budget: AiToolBudget(maxSingleOutputChars: whole ? 20000 : 600),
        );
        expect(result.result.isError, isFalse);
        expect(result.truncated, !whole);
        expect(result.result.content.contains(title), whole);
        result.recordDelivery!(result.result.plainData);
      },
    );
  }
  final context = await loadAiChatContext(
    origin: const AiGroupWorkItemOrigin(
      group: GraphResourceRef(id: 'gid://gitlab/Group/7', fullPath: g0ePath),
      iid: 5,
      title: 'Untrusted entry title',
    ),
    api: api,
    redactor: redactor,
    accountKey: g0eAccount,
    refreshSecrets: () async {},
    isCurrent: () => true,
  );
  return (
    catalogue: null,
    deliver: (bool whole) async {
      final sent = whole
          ? context.built.blocks
          : [
              AiContextBlock.fromData(
                source: 'conversation_summary',
                data: buildAiProjectionData(
                  context: context.built.blocks,
                  entries: const [],
                  budget: 2000,
                  redact: (value) => value,
                ),
              ),
            ];
      expect(sent.map((block) => block.text).join().contains(title), whole);
      context.recordDelivery(harness.placeholders, sent);
    },
  );
}

AiRunner _titleRunner(
  G0eHarness h,
  AiToolCatalogue catalogue,
  runner_test.Harness provider,
) => AiRunner(
  appInForeground: () => true,
  config: provider.config(),
  wire: provider.wire,
  complete: provider.complete,
  secrets: provider.secrets,
  refreshSecrets: () async {},
  guard: AiRunGuard(
    expectedGeneration: 1,
    ownerApi: provider.owner,
    generation: () => 1,
    api: () => provider.owner,
    recipientRevision: () => 1,
    consentValid: () => true,
  ),
  system: 'Synthetic title delivery.',
  tools: [runner_test.spec, ...catalogue.specs],
  onRestorableResultCut: h.placeholders.markWholeFieldsCut,
  executeTool: (tool) async {
    if (tool.name == 'get_group_work_item') {
      final result = await catalogue.executeResult(
        tool,
        budget: AiToolBudget(),
      );
      expect(result.uploadPlaceholders, isFalse);
      expect(result.content, contains(h.graph.currentFields['title']!));
      return result;
    }
    return AiToolResult(
      callId: tool.id,
      name: tool.name,
      content: 'p' * (tool.id == 'padding-5' ? 19500 : 20000),
    );
  },
  prepareToolResults: (calls, results, beforeDelivery) =>
      catalogue.prepareDelivery(
        calls,
        results,
        budget: AiToolBudget(),
        beforeDelivery: beforeDelivery,
      ),
  close: () {},
  cancelActive: () {},
);

void main() {
  group('FIX1 real title delivery to coordinator', () {
    for (final source in ['catalogue output', 'context projection']) {
      for (final atDispatch in [false, true]) {
        for (final combined in [false, true]) {
          test(
            '$source cut refuses ${atDispatch ? 'dispatch' : 'proposal'} '
            '${combined ? 'title+description' : 'title-only'} until whole reread',
            () async {
              _gate(true);
              final h = await G0eHarness.create();
              addTearDown(h.dispose);
              h.graph.currentFields['title'] = 'Original group title. ' * 100;
              final deliver = (await _titleDelivery(h, source)).deliver;
              final fields = {
                'title': '  Changed title  ',
                if (combined) 'description': 'Safe replacement description',
              };
              final call = h.call('updateGroupWorkItemContent', fields);
              await deliver(atDispatch);
              final proposal = await h.coordinator.propose(call);
              if (atDispatch) {
                expect(proposal, isNotNull);
                await deliver(false);
                final result = await h.coordinator.approve(proposal!);
                expect(result.state, AiJournalState.notExecuted);
                expect(result.reasonCode, text.AiTextBlockCode.fieldTooLong);
              } else {
                expect(proposal, isNull);
                expect(
                  h.coordinator.recordedOutcomeFor(call.id)!.reasonCode,
                  text.AiTextBlockCode.fieldTooLong,
                );
              }
              expect(h.graph.prepares, atDispatch ? 2 : 1);
              expect(h.graph.mutations, 0);

              // An opening cannot clear the cut; only a subsequent whole
              // delivery of this same title can authorize the replacement.
              h.beginRun();
              final stillCut = h.call('updateGroupWorkItemContent', fields);
              expect(await h.coordinator.propose(stillCut), isNull);
              expect(
                h.coordinator.recordedOutcomeFor(stillCut.id)!.reasonCode,
                text.AiTextBlockCode.fieldTooLong,
              );
              expect(h.graph.mutations, 0);
              await deliver(true);
              h.beginRun();
              final allowed = await h.coordinator.propose(
                h.call('updateGroupWorkItemContent', fields),
              );
              expect(allowed, isNotNull);
              expect(
                (allowed!.preview as port.AiFieldsPreview).fields['title'],
                fields['title'],
              );
              final result = await h.coordinator.approve(allowed);
              expect(
                result.state,
                AiJournalState.succeeded,
                reason: result.reasonCode,
              );
              expect(h.graph.dispatched!.arguments['title'], fields['title']);
              if (combined) {
                expect(
                  h.graph.dispatched!.arguments['description'],
                  fields['description'],
                );
              }
              expect(h.graph.mutations, 1);
            },
          );
        }
      }
    }
  });

  for (final atDispatch in [false, true]) {
    test('FIX1 runner aggregate cut of title without description refuses '
        '${atDispatch ? 'dispatch' : 'proposal'}', () async {
      _gate(true);
      final h = await G0eHarness.create();
      addTearDown(h.dispose);
      h.graph.currentFields
        ..['title'] = 'Original group title. ' * 100
        ..remove('description');
      final source = await _titleDelivery(h, 'catalogue output');
      final catalogue = source.catalogue!;
      final call = h.call('updateGroupWorkItemContent', {'title': 'Changed'});
      final proposal = atDispatch ? await h.coordinator.propose(call) : null;
      if (atDispatch) expect(proposal, isNotNull);

      final provider = runner_test.Harness();
      var response = 0;
      provider.respond = (_, _) async => switch (++response) {
        1 => provider.turn(
          calls: [for (var i = 0; i < 4; i++) runner_test.call('padding-$i')],
        ),
        2 => provider.turn(
          calls: [
            runner_test.call('padding-4'),
            runner_test.call('padding-5'),
            AiToolCall(
              id: 'title-read',
              name: 'get_group_work_item',
              arguments: {'groupId': 7, 'iid': 5},
            ),
          ],
        ),
        _ => provider.turn(text: 'Finished reading.'),
      };
      final runner = _titleRunner(h, catalogue, provider);
      final run = await runner.run('Read the title.');
      expect(run.reason, AiRunEnd.done);
      final delivered = runner.segment!.entries
          .whereType<AppToolResultsEntry>()
          .expand((entry) => entry.results)
          .singleWhere((result) => result.name == 'get_group_work_item');
      expect(delivered.truncated, isTrue);
      expect(
        delivered.content,
        isNot(contains(h.graph.currentFields['title']!)),
      );
      if (atDispatch) {
        final result = await h.coordinator.approve(proposal!);
        expect(result.state, AiJournalState.notExecuted);
        expect(result.reasonCode, text.AiTextBlockCode.fieldTooLong);
      } else {
        expect(await h.coordinator.propose(call), isNull);
        expect(
          h.coordinator.recordedOutcomeFor(call.id)!.reasonCode,
          text.AiTextBlockCode.fieldTooLong,
        );
      }
      expect(h.graph.mutations, 0);
      await source.deliver(true);
      h.beginRun();
      final allowed = await h.coordinator.propose(
        h.call('updateGroupWorkItemContent', {'title': 'Changed'}),
      );
      expect(allowed, isNotNull);
      expect(
        (await h.coordinator.approve(allowed!)).state,
        AiJournalState.succeeded,
      );
      expect(h.graph.mutations, 1);
    });
  }

  for (final atDispatch in [false, true]) {
    test('FIX1 runner summary after whole title refuses '
        '${atDispatch ? 'dispatch' : 'proposal'} until reread', () async {
      _gate(true);
      final h = await G0eHarness.create();
      addTearDown(h.dispose);
      h.graph.currentFields
        ..['title'] = 'Original group title. ' * 100
        ..remove('description');
      final source = await _titleDelivery(h, 'catalogue output');
      final provider = runner_test.Harness();
      var response = 0;
      provider.respond = (_, _) async => ++response == 1
          ? provider.turn(
              calls: [
                AiToolCall(
                  id: 'title-read',
                  name: 'get_group_work_item',
                  arguments: {'groupId': 7, 'iid': 5},
                ),
              ],
            )
          : provider.turn(text: 'Finished.');
      final runner = _titleRunner(h, source.catalogue!, provider);
      expect((await runner.run('Read title.')).reason, AiRunEnd.done);
      expect(provider.payloads.last, contains(h.graph.currentFields['title']!));
      final call = h.call('updateGroupWorkItemContent', {'title': 'Changed'});
      final proposal = atDispatch ? await h.coordinator.propose(call) : null;
      if (atDispatch) expect(proposal, isNotNull);
      runner.forceProjection();
      expect((await runner.run('Summarize.')).reason, AiRunEnd.done);
      expect(provider.payloads.last, contains('conversation_summary'));
      expect(
        provider.payloads.last,
        isNot(contains(h.graph.currentFields['title']!)),
      );
      if (atDispatch) {
        final result = await h.coordinator.approve(proposal!);
        expect(result.state, AiJournalState.notExecuted);
        expect(result.reasonCode, text.AiTextBlockCode.fieldTooLong);
      } else {
        expect(await h.coordinator.propose(call), isNull);
        expect(
          h.coordinator.recordedOutcomeFor(call.id)!.reasonCode,
          text.AiTextBlockCode.fieldTooLong,
        );
      }
      expect(h.graph.mutations, 0);
      await source.deliver(true);
      h.beginRun();
      final allowed = await h.coordinator.propose(
        h.call('updateGroupWorkItemContent', {'title': 'Changed'}),
      );
      expect(allowed, isNotNull);
      expect(
        (await h.coordinator.approve(allowed!)).state,
        AiJournalState.succeeded,
      );
      expect(h.graph.mutations, 1);
    });
  }

  test(
    'FIX1 whole read cannot clear a title cut before model delivery',
    () async {
      _gate(true);
      final h = await G0eHarness.create();
      addTearDown(h.dispose);
      h.graph.currentFields['title'] = 'Original group title. ' * 100;
      final source = await _titleDelivery(h, 'catalogue output');
      await source.deliver(false);
      final whole = await source.catalogue!.execute(
        AiToolCall(
          id: 'pending-whole-title',
          name: 'get_group_work_item',
          arguments: {'groupId': 7, 'iid': 5},
        ),
        budget: AiToolBudget(),
      );
      expect(whole.truncated, isFalse);
      final call = h.call('updateGroupWorkItemContent', {'title': 'Changed'});
      expect(await h.coordinator.propose(call), isNull);
      expect(
        h.coordinator.recordedOutcomeFor(call.id)!.reasonCode,
        text.AiTextBlockCode.fieldTooLong,
      );
      expect(h.graph.mutations, 0);
      whole.recordDelivery!(whole.result.plainData);
      h.beginRun();
      final proposal = await h.coordinator.propose(
        h.call('updateGroupWorkItemContent', {'title': 'Changed'}),
      );
      expect(proposal, isNotNull);
      expect(
        (await h.coordinator.approve(proposal!)).state,
        AiJournalState.succeeded,
      );
      expect(h.graph.mutations, 1);
    },
  );

  group('G0j opening title provenance', () {
    for (final combined in [false, true]) {
      test(
        'coordinator ${combined ? 'title+description' : 'title-only'} succeeds',
        () async {
          _gate(true);
          final h = await G0eHarness.create();
          addTearDown(h.dispose);
          const title = '  Updated group title  ';
          const description = 'Updated group description';
          // Freshness alone calls the title incomplete. The strict opening's
          // whole currentFields must supply the evidence for both text rounds.
          final field = _titleField(h);
          h.priorProvenance = {
            'title': text.AiFieldProvenance(
              resourceKey: field.resourceKey,
              fieldName: 'title',
              completeValue: false,
              accountKey: field.accountKey,
              groupId: field.groupId,
              groupFullPath: field.groupFullPath,
              resourceWeb: field.resourceWeb,
            ),
          };
          final call = h.call('updateGroupWorkItemContent', {
            'title': title,
            if (combined) 'description': description,
          });
          final proposal = await h.coordinator.propose(call);
          expect(
            proposal,
            isNotNull,
            reason: h.coordinator.recordedOutcomeFor(call.id)?.reasonCode,
          );
          expect(
            (proposal!.preview as port.AiFieldsPreview).fields['title'],
            title,
          );
          expect(h.graph.mutations, 0);
          final result = await h.coordinator.approve(proposal);
          expect(
            result.state,
            AiJournalState.succeeded,
            reason: result.reasonCode,
          );
          expect(h.graph.dispatched!.arguments['title'], title);
          if (combined) {
            expect(h.graph.dispatched!.arguments['description'], description);
          } else {
            expect(
              h.graph.dispatched!.arguments,
              isNot(contains('description')),
            );
          }
          expect(h.freshnessReads, 2);
          expect(h.graph.events, ['open:1', 'open:2', 'start', 'send']);
          expect(h.graph.mutations, 1);
        },
      );
    }

    for (final atDispatch in [false, true]) {
      final phase = atDispatch ? 'dispatch' : 'proposal';
      test(
        'missing opening title refuses at $phase despite prior provenance',
        () async {
          _gate(true);
          final h = await G0eHarness.create();
          addTearDown(h.dispose);
          h.priorProvenance = {'title': _titleField(h)};
          final call = h.call('updateGroupWorkItemContent', {
            'title': 'Changed',
          });
          if (!atDispatch) h.graph.currentFields.remove('title');
          final proposal = await h.coordinator.propose(call);
          if (atDispatch) {
            expect(proposal, isNotNull);
            h.graph.currentFields.remove('title');
            final result = await h.coordinator.approve(proposal!);
            expect(result.state, AiJournalState.notExecuted);
            expect(result.reasonCode, text.AiTextBlockCode.fieldTooLong);
          } else {
            expect(proposal, isNull);
            expect(
              h.coordinator.recordedOutcomeFor(call.id)!.reasonCode,
              text.AiTextBlockCode.fieldTooLong,
            );
          }
          expect(h.graph.mutations, 0);
        },
      );

      for (final cut in ['excerpt', 'output limit']) {
        test(
          '$cut title refuses at $phase despite a complete opening',
          () async {
            _gate(true);
            final h = await G0eHarness.create();
            addTearDown(h.dispose);
            void cutTitle() {
              final field = _titleField(h);
              h.placeholders.recordFieldDelivery(
                field,
                whole: cut != 'excerpt',
              );
              if (cut == 'output limit') h.placeholders.markWholeFieldsCut();
            }

            final call = h.call('updateGroupWorkItemContent', {
              'title': 'Changed',
              'description': 'Safe description',
            });
            if (!atDispatch) cutTitle();
            final proposal = await h.coordinator.propose(call);
            if (atDispatch) {
              expect(proposal, isNotNull);
              cutTitle();
              final result = await h.coordinator.approve(proposal!);
              expect(result.state, AiJournalState.notExecuted);
              expect(result.reasonCode, text.AiTextBlockCode.fieldTooLong);
            } else {
              expect(proposal, isNull);
              expect(
                h.coordinator.recordedOutcomeFor(call.id)!.reasonCode,
                text.AiTextBlockCode.fieldTooLong,
              );
            }
            expect(h.graph.prepares, atDispatch ? 2 : 1);
            expect(h.graph.mutations, 0);
          },
        );
      }
    }

    test('whole title delivery clears an earlier excerpt refusal', () async {
      _gate(true);
      final h = await G0eHarness.create();
      addTearDown(h.dispose);
      final field = _titleField(h);
      h.placeholders.recordFieldDelivery(field, whole: false);
      expect(
        await h.coordinator.propose(
          h.call('updateGroupWorkItemContent', {'title': 'Changed'}),
        ),
        isNull,
      );
      h.placeholders.recordFieldDelivery(field, whole: true);
      h.beginRun();
      final proposal = await h.coordinator.propose(
        h.call('updateGroupWorkItemContent', {'title': 'Changed'}),
      );
      expect(proposal, isNotNull);
      final result = await h.coordinator.approve(proposal!);
      expect(result.state, AiJournalState.succeeded, reason: result.reasonCode);
      expect(h.graph.mutations, 1);
    });

    test('stale opening identity cannot authorize a title edit', () async {
      _gate(true);
      final h = await G0eHarness.create();
      addTearDown(h.dispose);
      h.graph.live = false;
      final call = h.call('updateGroupWorkItemContent', {'title': 'Changed'});
      expect(await h.coordinator.propose(call), isNull);
      expect(
        h.coordinator.recordedOutcomeFor(call.id)!.reasonCode,
        'workItemUnverifiable',
      );
      expect(h.graph.mutations, 0);
    });

    for (final source in ['description', 'note']) {
      for (final combined in [false, true]) {
        test('$source upload token in ${combined ? 'combined' : 'title-only'} '
            'proposal refuses', () async {
          _gate(true);
          final h = await G0eHarness.create();
          addTearDown(h.dispose);
          final field = text.AiFieldProvenance.groupWorkItem(
            identity: g0eIdentity(h.api),
            completeValue: true,
            noteId: source == 'note' ? 12 : null,
          );
          const original =
              '[file](/uploads/0123456789abcdef0123456789abcdef/file.txt)';
          final masked = h.placeholders.redactOutgoing(original, field: field);
          expect(masked, contains('[[upload:'));
          final call = h.call('updateGroupWorkItemContent', {
            'title': masked,
            if (combined) 'description': 'Safe description',
          });
          expect(await h.coordinator.propose(call), isNull);
          expect(
            h.coordinator.recordedOutcomeFor(call.id)!.reasonCode,
            text.AiTextBlockCode.rereadField,
          );
          expect(h.graph.prepares, 1);
          expect(h.graph.mutations, 0);
        });
      }
    }

    test(
      'valid title cannot allow a cross-field note token in description',
      () async {
        _gate(true);
        final h = await G0eHarness.create();
        addTearDown(h.dispose);
        final note = text.AiFieldProvenance.groupWorkItem(
          identity: g0eIdentity(h.api),
          completeValue: true,
          noteId: 12,
        );
        final masked = h.placeholders.redactOutgoing(
          '[file](/uploads/0123456789abcdef0123456789abcdef/file.txt)',
          field: note,
        );
        expect(masked, contains('[[upload:'));
        final call = h.call('updateGroupWorkItemContent', {
          'title': 'Changed',
          'description': masked,
        });
        expect(await h.coordinator.propose(call), isNull);
        expect(
          h.coordinator.recordedOutcomeFor(call.id)!.reasonCode,
          text.AiTextBlockCode.rereadField,
        );
        expect(h.graph.mutations, 0);
      },
    );
  });

  test(
    'freshness defaults retain unknown source evidence for older readers',
    () {
      expect(const AiWriteFreshness().sourceVisibilityUnreadable, isTrue);
    },
  );

  test(
    'production group gate and visible rows remain closed; UI channel starts empty',
    () {
      expect(aiGroupWorkItemWritesEnabledForTesting, isNull);
      expect(aiGroupWorkItemWritesAreEnabled, isFalse);
      expect(g0eScope.uiAddedGroupWorkItems, isEmpty);
      final groupRows = ProductionAiLedger.rows.where(
        (row) =>
            row.operationId.contains('GroupWorkItem') ||
            row.scopeClass == AiScopeClass.groupWorkItem,
      );
      expect(_groupRowsAreHidden(groupRows), isTrue);
      expect(
        productionAiLedger.modelVisible.where(
          (row) => row.scopeClass == AiScopeClass.groupWorkItem,
        ),
        isEmpty,
      );
      expect(toolsForScope(g0eScope), isEmpty);
    },
  );

  test('stage assertion rejects visible or malformed group rows', () {
    AiCapability row({
      bool visible = false,
      AiWriteBoundary boundary = AiWriteBoundary.graph,
      AiScopeClass scope = AiScopeClass.groupWorkItem,
    }) => AiCapability(
      operationId: 'updateGroupWorkItemState',
      baseTier: AiWriteTier.t2,
      modelVisible: visible,
      boundary: boundary,
      scopeClass: scope,
    );
    expect(_groupRowsAreHidden([row()]), isTrue);
    expect(_groupRowsAreHidden([row(visible: true)]), isFalse);
    expect(_groupRowsAreHidden([row(boundary: AiWriteBoundary.rest)]), isFalse);
    expect(_groupRowsAreHidden([row(scope: AiScopeClass.workItem)]), isFalse);
  });

  test(
    'strict main resolver uses one actor plus one fixed namespace read',
    () async {
      final adapter = FakeAdapter((request) {
        if (request.method == 'GET') {
          expect(request.uri.path, '/gitlab/api/v4/user');
          return jsonResponse({'id': 7, 'username': 'tester'});
        }
        expect(request.method, 'POST');
        expect(request.uri.path, '/gitlab/api/graphql');
        final body = request.data! as Map;
        expect(body.keys, unorderedEquals(['query', 'variables']));
        expect(body['query'], namespaceWorkItemQuery);
        expect(body['variables'], {'path': g0ePath, 'iid': '5'});
        return jsonResponse({
          'data': {'namespace': _namespace()},
        });
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final writePort = port.GitLabAiWritePort(api, accountKey: g0eAccount);
      var live = true;
      final location = await writePort.resolveGroupWorkItemForTesting(
        _request(),
        generation: 7,
        readEpoch: 11,
        isCurrent: () => live,
        resolvedUrl: Uri.parse(
          'https://example.com/gitlab/groups/team/sub/-/work_items/5',
        ),
      );
      expect(location.identity.groupId, 7);
      expect(location.identity.iid, 5);
      expect(location.identity.workItemGid, 'gid://gitlab/WorkItem/91');
      expect(location.identity.readEpoch, 11);
      expect(adapter.requests, hasLength(2));
      expect(location.isCurrent(), isTrue);
      live = false;
      expect(location.isCurrent(), isFalse);
    },
  );

  final invalidResponses = <String, void Function(Map<String, Object?>)>{
    'foreign outer Group': (node) => node['id'] = 'gid://gitlab/Group/8',
    'foreign item namespace': (node) =>
        (node['workItem']! as Map)['namespace'] = {
          'id': 'gid://gitlab/Group/8',
          'fullPath': g0ePath,
        },
    'same iid in another Group': (node) => node.addAll(_namespace(groupId: 8)),
    'missing project': (node) => (node['workItem']! as Map).remove('project'),
    'project descendant': (node) => (node['workItem']! as Map)['project'] = {
      'id': 'gid://gitlab/Project/7',
      'fullPath': g0ePath,
    },
    'wrong iid': (node) => (node['workItem']! as Map)['iid'] = '6',
    'Group used as WorkItem GID': (node) =>
        (node['workItem']! as Map)['id'] = 'gid://gitlab/Group/7',
    'ancestor path': (node) => node['fullPath'] = 'team',
  };
  for (final entry in invalidResponses.entries) {
    test('strict resolver refuses ${entry.key}, mutation 0', () async {
      final node = _namespace();
      entry.value(node);
      final adapter = FakeAdapter(
        (request) => request.method == 'GET'
            ? jsonResponse({'id': 7, 'username': 'tester'})
            : jsonResponse({
                'data': {'namespace': node},
              }),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        port.GitLabAiWritePort(
          api,
          accountKey: g0eAccount,
        ).resolveGroupWorkItemForTesting(
          _request(),
          generation: 7,
          readEpoch: 1,
          isCurrent: () => true,
        ),
        throwsA(anything),
      );
      expect(adapter.requests, hasLength(2));
      expect(
        adapter.requests.where(
          (r) =>
              r.method == 'POST' &&
              (r.data as Map)['query'].toString().trimLeft().startsWith(
                'mutation',
              ),
        ),
        isEmpty,
      );
    });
  }

  for (final url in [
    'https://foreign.example/gitlab/groups/team/sub/-/work_items/5',
    'https://example.com/groups/team/sub/-/work_items/5',
    'https://example.com:8443/gitlab/groups/team/sub/-/work_items/5',
    'http://example.com/gitlab/groups/team/sub/-/work_items/5',
    'https://example.com/gitlab/groups/team/sub/-/work_items/6',
  ]) {
    test('URL locator rejects foreign origin, prefix, or iid: $url', () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse({'id': 7, 'username': 'tester'}),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        port.GitLabAiWritePort(
          api,
          accountKey: g0eAccount,
        ).resolveGroupWorkItemForTesting(
          _request(),
          generation: 7,
          readEpoch: 1,
          isCurrent: () => true,
          resolvedUrl: Uri.parse(url),
        ),
        throwsA(isA<port.AiWriteRefused>()),
      );
      expect(adapter.requests, hasLength(1));
    });
  }

  test('group path rejects reserved segments before namespace read', () async {
    final adapter = FakeAdapter(
      (_) => jsonResponse({'id': 7, 'username': 'tester'}),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    for (final path in ['team/-/x', 'team/../x', 'team/./x']) {
      final scope = AiWriteScope(
        accountKey: g0eAccount,
        grants: [
          AiScopeGrant(
            kind: AiScopeKind.groupWorkItem,
            groupId: 7,
            groupFullPath: path,
            iid: 5,
          ),
        ],
      );
      await expectLater(
        port.GitLabAiWritePort(
          api,
          accountKey: g0eAccount,
        ).resolveGroupWorkItemForTesting(
          _request(scope: scope),
          generation: 7,
          readEpoch: 1,
          isCurrent: () => true,
        ),
        throwsA(anything),
      );
    }
    expect(adapter.requests, hasLength(3));
    expect(adapter.requests.every((r) => r.method == 'GET'), isTrue);
  });

  for (final path in [
    'team/../sub',
    'team/./sub',
    'team/-/sub',
    '',
    '.',
    '..',
    '-',
    'team//sub',
    '/team',
    'team/',
    'team space/sub',
    'team/sub%2fextra',
    'team/sub?query',
    'team/sub#fragment',
    r'team\sub',
    'team/é',
    'team/sub\n',
    'a' * 1025,
  ]) {
    test(
      'group binding rejects invalid path ${path.length > 40 ? path.length : path}',
      () {
        _gate(true);
        final scope = AiWriteScope(
          accountKey: g0eAccount,
          grants: [
            AiScopeGrant(
              kind: AiScopeKind.groupWorkItem,
              groupId: 7,
              groupFullPath: path,
              iid: 5,
            ),
          ],
        );
        final target = AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: 7,
          groupFullPath: path,
          iid: 5,
          origin: AiTargetOrigin.currentResource,
        );
        expect(
          scopeAdmits(
            scope,
            const G0eLedger().find('updateGroupWorkItemContent')!,
            target,
          ),
          isFalse,
        );
        expect(
          bindTargets(
            userMessage: 'Update this work item.',
            restoredFromHistory: false,
            scope: scope,
            targets: [target],
            interfaceLanguage: 'en',
            deviceLanguages: const ['en'],
          ).allBound,
          isFalse,
        );
      },
    );
  }

  for (final path in ['team/sub', 'team-1/sub_group.v2', '.hidden/a..b']) {
    test('group binding accepts canonical path $path', () {
      _gate(true);
      final scope = AiWriteScope(
        accountKey: g0eAccount,
        grants: [
          AiScopeGrant(
            kind: AiScopeKind.groupWorkItem,
            groupId: 7,
            groupFullPath: path,
            iid: 5,
          ),
        ],
      );
      final target = AiTargetRef(
        kind: AiTargetKind.groupWorkItem,
        groupId: 7,
        groupFullPath: path,
        iid: 5,
        origin: AiTargetOrigin.currentResource,
      );
      expect(
        scopeAdmits(
          scope,
          const G0eLedger().find('updateGroupWorkItemContent')!,
          target,
        ),
        isTrue,
      );
      expect(
        bindTargets(
          userMessage: 'Update this work item.',
          restoredFromHistory: false,
          scope: scope,
          targets: [target],
          interfaceLanguage: 'en',
          deviceLanguages: const ['en'],
        ).allBound,
        isTrue,
      );
    });
  }

  test(
    'actor mismatch and stale generation stop before namespace read',
    () async {
      for (final actor in [7, 8]) {
        var current = true;
        final adapter = FakeAdapter((_) {
          if (actor == 7) current = false;
          return jsonResponse({'id': actor, 'username': 'tester'});
        });
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          port.GitLabAiWritePort(
            api,
            accountKey: g0eAccount,
          ).resolveGroupWorkItemForTesting(
            _request(),
            generation: 7,
            readEpoch: 1,
            isCurrent: () => current,
          ),
          throwsA(anything),
        );
        expect(adapter.requests, hasLength(1));
      }
    },
  );

  test(
    'group schema enum comes only from group grants; project schema stays separate',
    () async {
      _gate(true);
      final h = await G0eHarness.create();
      addTearDown(h.dispose);
      h.scope = AiWriteScope(
        accountKey: g0eAccount,
        grants: [
          ...g0eScope.grants,
          AiScopeGrant(
            kind: AiScopeKind.project,
            projectId: 9,
            projectPath: 'team/p',
          ),
        ],
      );
      final spec = h.coordinator.specs.singleWhere(
        (s) => s.name == 'updateGroupWorkItemContent',
      );
      final properties = spec.parameters['properties']! as Map;
      expect((properties['groupId']! as Map)['enum'], [7]);
      expect(properties, isNot(contains('projectId')));
      expect(
        spec.description,
        contains('group work item #5 in group 7 (team/sub)'),
      );
    },
  );

  test('hidden group row direct-call refuses even with test gate on', () async {
    _gate(true);
    final h = await G0eHarness.create(ledger: const G0eLedger(visible: false));
    addTearDown(h.dispose);
    final call = h.call('updateGroupWorkItemState', {'stateEvent': 'close'});
    expect(await h.coordinator.propose(call), isNull);
    expect(
      h.coordinator.recordedOutcomeFor(call.id)!.reasonCode,
      'unknownOperation',
    );
    expect(h.graph.prepares, 0);
    expect(h.graph.mutations, 0);
  });

  for (final args in <Map<String, Object?>>[
    {'groupId': 0},
    {'groupId': -1},
    {'groupId': '7'},
    {'iid': 0},
    {'projectId': 7},
    {'url': 'https://example.com'},
    {'workItemGid': 'gid://gitlab/WorkItem/91'},
  ]) {
    test(
      'group arguments reject nonnumeric, mixed, or model identity: $args',
      () async {
        _gate(true);
        final h = await G0eHarness.create();
        addTearDown(h.dispose);
        expect(
          await h.coordinator.propose(
            h.call('updateGroupWorkItemState', {
              'stateEvent': 'close',
              ...args,
            }),
          ),
          isNull,
        );
        expect(h.graph.prepares, 0);
        expect(h.graph.mutations, 0);
      },
    );
  }

  for (final groupId in [8, 9]) {
    test(
      'foreign Group and same iid never gain UI-added authority ($groupId)',
      () async {
        _gate(true);
        final h = await G0eHarness.create();
        addTearDown(h.dispose);
        h.scope = AiWriteScope(
          accountKey: g0eAccount,
          grants: g0eScope.grants,
          uiAddedGroupWorkItems: [g0eIdentity(h.api, groupId: groupId)],
        );
        final foreign = AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: groupId,
          groupFullPath: g0ePath,
          iid: 5,
          workItemGid: 'gid://gitlab/WorkItem/91',
          origin: AiTargetOrigin.uiAdded,
        );
        expect(
          scopeAdmits(
            h.scope,
            const G0eLedger().find('updateGroupWorkItemState')!,
            foreign,
          ),
          isFalse,
        );
        expect(
          await h.coordinator.propose(
            h.call('updateGroupWorkItemState', {
              'groupId': groupId,
              'stateEvent': 'close',
            }),
          ),
          isNull,
        );
        expect(h.graph.mutations, 0);
      },
    );
  }

  test(
    'request freezes a verified UI-added group identity and exact GID binds',
    () {
      _gate(true);
      final api = Object();
      final identities = [g0eIdentity(api)];
      final request = _request(
        scope: AiWriteScope(
          accountKey: g0eAccount,
          grants: g0eScope.grants,
          uiAddedGroupWorkItems: identities,
        ),
      );
      identities.clear();
      expect(request.scope.uiAddedGroupWorkItems, hasLength(1));
      expect(
        () => request.scope.uiAddedGroupWorkItems.clear(),
        throwsUnsupportedError,
      );
      final target = AiTargetRef(
        kind: AiTargetKind.groupWorkItem,
        groupId: 7,
        groupFullPath: g0ePath,
        iid: 5,
        workItemGid: 'gid://gitlab/WorkItem/91',
        origin: AiTargetOrigin.uiAdded,
      );
      expect(
        scopeAdmits(
          request.scope,
          const G0eLedger().find('updateGroupWorkItemContent')!,
          target,
        ),
        isTrue,
      );
    },
  );

  test(
    'group content opens before scan in both rounds and uses graph hook order',
    () async {
      _gate(true);
      final h = await G0eHarness.create();
      addTearDown(h.dispose);
      final proposal = await h.coordinator.propose(
        h.call('updateGroupWorkItemContent', {
          'description': '  Safe replacement  ',
        }),
      );
      expect(proposal, isNotNull);
      expect(h.graph.events, ['open:1']);
      final result = await h.coordinator.approve(proposal!);
      expect(result.state, AiJournalState.succeeded, reason: result.reasonCode);
      expect(h.graph.events, ['open:1', 'open:2', 'start', 'send']);
      expect(
        h.graph.dispatched!.arguments['description'],
        '  Safe replacement  ',
      );
      expect(h.freshnessReads, 2);
      expect(h.graph.mutations, 1, reason: 'synthetic graph double only');
    },
  );

  for (final operation in [
    'updateGroupWorkItemContent',
    'editGroupWorkItemActivityNote',
  ]) {
    test(
      '$operation rejects group attachments without a proven project',
      () async {
        _gate(true);
        final h = await G0eHarness.create();
        addTearDown(h.dispose);
        final args = operation == 'updateGroupWorkItemContent'
            ? <String, Object?>{'description': '[[attachment:att-1]]'}
            : <String, Object?>{'noteId': 31, 'body': '[[attachment:att-1]]'};
        expect(await h.coordinator.propose(h.call(operation, args)), isNull);
        expect(h.graph.prepares, 1);
        expect(h.graph.mutations, 0);
      },
    );
  }

  test('live identity revoked after hook refuses send, mutation 0', () async {
    _gate(true);
    final h = await G0eHarness.create();
    addTearDown(h.dispose);
    final proposal = await h.coordinator.propose(
      h.call('updateGroupWorkItemContent', {'description': 'Safe'}),
    );
    expect(proposal, isNotNull);
    h.graph.afterBeforeMutation = () => h.graph.live = false;
    final result = await h.coordinator.approve(proposal!);
    expect(result.state, AiJournalState.notExecuted, reason: result.reasonCode);
    expect(h.graph.events, ['open:1', 'open:2', 'start']);
    expect(h.graph.mutations, 0);
  });

  test('group content hidden-span removal still confirms in bypass', () async {
    _gate(true);
    final h = await G0eHarness.create();
    addTearDown(h.dispose);
    h.level = AiAutonomyLevel.bypass;
    h.graph.currentFields['description'] =
        'Visible ![file](/uploads/0123456789abcdef0123456789abcdef/file.png)';
    final proposal = await h.coordinator.propose(
      h.call('updateGroupWorkItemContent', {'description': 'Visible'}),
    );
    expect(proposal, isNotNull);
    expect(
      proposal!.tier.reasons,
      contains(AiFixedConfirmReason.wholeFieldDropsHiddenSpans),
    );
    expect(h.graph.mutations, 0);
  });

  for (final groupId in [7, 8]) {
    test(
      'synthetic group Todo owner $groupId uses exact grant and group link',
      () async {
        _gate(true);
        final h = await G0eHarness.create();
        addTearDown(h.dispose);
        h.graph.groupTodoTarget = (
          groupId: groupId,
          groupFullPath: g0ePath,
          iid: 5,
          workItemGid: 'gid://gitlab/WorkItem/91',
        );
        final proposal = await h.coordinator.propose(
          AiToolCall(
            id: 'typed-todo',
            name: 'snoozeTodo',
            arguments: {
              'todoId': 15,
              'until': '2030-01-01T00:00:00Z',
              'reason': 'Asked.',
            },
          ),
        );
        if (groupId == 8) {
          expect(proposal, isNull);
          expect(h.graph.mutations, 0);
        } else {
          expect(proposal, isNotNull);
          final result = await h.coordinator.approve(proposal!);
          expect(
            result.state,
            AiJournalState.succeeded,
            reason: result.reasonCode,
          );
          expect(
            result.webLink.toString(),
            'https://example.com/gitlab/groups/team/sub/-/work_items/5',
          );
          expect(h.graph.lastPrepared!.todoTarget, isNull);
        }
      },
    );
  }

  for (final phase in ['second opening', 'journal flush']) {
    test('synthetic group Todo revocation at $phase prevents START', () async {
      _gate(true);
      final h = await G0eHarness.create();
      addTearDown(h.dispose);
      h.graph.groupTodoTarget = (
        groupId: 7,
        groupFullPath: g0ePath,
        iid: 5,
        workItemGid: 'gid://gitlab/WorkItem/91',
      );
      if (phase == 'second opening') {
        h.graph.identityForEpoch = (epoch) {
          if (epoch == 2) h.graph.live = false;
          return g0eIdentity(h.api, readEpoch: epoch);
        };
      } else {
        h.graph.afterBeforeMutation = () => h.graph.live = false;
      }
      final proposal = await h.coordinator.propose(
        AiToolCall(
          id: 'g0g-group-todo-$phase',
          name: 'snoozeTodo',
          arguments: const {
            'todoId': 15,
            'until': '2030-01-01T00:00:00Z',
            'reason': 'Asked.',
          },
        ),
      );
      expect(proposal, isNotNull);
      final outcome = await h.coordinator.approve(proposal!);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(h.graph.mutations, 0);
    });
  }

  test('fresh opening cannot replace saved UI-added WorkItem GID', () async {
    _gate(true);
    final h = await G0eHarness.create();
    addTearDown(h.dispose);
    h.scope = AiWriteScope(
      accountKey: g0eAccount,
      grants: g0eScope.grants,
      uiAddedGroupWorkItems: [g0eIdentity(h.api)],
    );
    h.graph.identityForEpoch = (epoch) => g0eIdentity(
      h.api,
      readEpoch: epoch,
      workItemGid: 'gid://gitlab/WorkItem/92',
    );
    expect(
      await h.coordinator.propose(
        h.call('updateGroupWorkItemContent', {'description': 'Safe'}),
      ),
      isNull,
    );
    expect(h.graph.mutations, 0);
  });

  test(
    'known non-confidential opening retains unknown visibility confirmation',
    () async {
      _gate(true);
      final h = await G0eHarness.create();
      addTearDown(h.dispose);
      h.graph.targetConfidential = false;
      h.visibility = null;
      final proposal = await h.coordinator.propose(
        h.call('updateGroupWorkItemContent', {'description': 'Safe'}),
      );
      expect(proposal, isNotNull);
      expect(
        proposal!.tier.reasons,
        contains(AiFixedConfirmReason.confidentialOrVisibilityMix),
      );
      expect(h.graph.mutations, 0);
    },
  );

  test(
    'same-field group upload restores after opening, with unknown confidentiality confirmation',
    () async {
      _gate(true);
      final h = await G0eHarness.create();
      addTearDown(h.dispose);
      const original =
          '![file](/uploads/0123456789abcdef0123456789abcdef/file.png)';
      final field = text.AiFieldProvenance.groupWorkItem(
        identity: g0eIdentity(h.api),
        completeValue: true,
      );
      final masked = h.placeholders.redactOutgoing(original, field: field);
      expect(masked, contains('[[upload:'));
      h.graph.currentFields['description'] = original;
      final proposal = await h.coordinator.propose(
        h.call('updateGroupWorkItemContent', {'description': masked}),
      );
      expect(proposal, isNotNull);
      expect(
        proposal!.tier.reasons,
        contains(AiFixedConfirmReason.confidentialOrVisibilityMix),
      );
      final result = await h.coordinator.approve(proposal);
      expect(result.state, AiJournalState.succeeded, reason: result.reasonCode);
      expect(h.graph.dispatched!.arguments['description'], original);
    },
  );

  for (final mismatch in ['group', 'iid', 'api', 'generation', 'epoch']) {
    test(
      'prepared identity $mismatch mismatch grants no restorable provenance',
      () async {
        _gate(true);
        final h = await G0eHarness.create();
        addTearDown(h.dispose);
        const original =
            '[file](/uploads/0123456789abcdef0123456789abcdef/file.txt)';
        final field = text.AiFieldProvenance.groupWorkItem(
          identity: g0eIdentity(h.api),
          completeValue: true,
        );
        final masked = h.placeholders.redactOutgoing(original, field: field);
        // Even a prior valid read cannot fill an invalid new opening's provenance.
        h.priorProvenance = {'description': field};
        h.graph.currentFields['description'] = original;
        h.graph.identityForEpoch = (epoch) => g0eIdentity(
          mismatch == 'api' ? Object() : h.api,
          groupId: mismatch == 'group' ? 8 : 7,
          iid: mismatch == 'iid' ? 6 : 5,
          generation: mismatch == 'generation' ? 8 : 7,
          readEpoch: epoch,
        );
        if (mismatch == 'epoch') h.graph.supplyCurrentPredicate = false;
        expect(
          await h.coordinator.propose(
            h.call('updateGroupWorkItemContent', {'description': masked}),
          ),
          isNull,
        );
        expect(h.graph.mutations, 0);
      },
    );
  }

  for (final evidence in [
    (sourceUnknown: false, confidential: null, polluted: false),
    (sourceUnknown: false, confidential: false, polluted: false),
    (sourceUnknown: true, confidential: false, polluted: false),
    (sourceUnknown: false, confidential: false, polluted: true),
    (sourceUnknown: false, confidential: true, polluted: false),
  ]) {
    test(
      'source unknown ${evidence.sourceUnknown}, target confidentiality ${evidence.confidential}, pollution ${evidence.polluted} survives both rounds',
      () async {
        _gate(true);
        final h = await G0eHarness.create();
        addTearDown(h.dispose);
        h.level = AiAutonomyLevel.conversationGrant;
        h.sourceVisibilityUnreadable = evidence.sourceUnknown;
        h.graph.targetConfidential = evidence.confidential;
        h.polluted = evidence.polluted;
        h.visibility = 'public';
        final proposal = await h.coordinator.propose(
          h.call('updateGroupWorkItemContent', {'description': 'Safe'}),
        );
        expect(proposal, isNotNull);
        final mustConfirm =
            evidence.sourceUnknown ||
            evidence.confidential != false ||
            evidence.polluted;
        expect(
          proposal!.tier.reasons.contains(
            AiFixedConfirmReason.confidentialOrVisibilityMix,
          ),
          mustConfirm,
        );
        expect(
          proposal.tier.decision,
          mustConfirm ? AiGateDecision.requireApproval : AiGateDecision.execute,
        );
        expect(h.graph.mutations, 0);
        final result = await h.coordinator.approve(proposal);
        expect(
          result.state,
          AiJournalState.succeeded,
          reason: result.reasonCode,
        );
        expect(h.freshnessReads, 2);
        expect(h.graph.events, ['open:1', 'open:2', 'start', 'send']);
        expect(h.graph.mutations, 1);
      },
    );
  }

  for (final restriction in ['source unknown', 'pollution']) {
    test(
      'new $restriction before dispatch still requires confirmation',
      () async {
        _gate(true);
        final h = await G0eHarness.create();
        addTearDown(h.dispose);
        h.level = AiAutonomyLevel.conversationGrant;
        h.graph.targetConfidential = false;
        h.visibility = 'public';
        final proposal = await h.coordinator.propose(
          h.call('updateGroupWorkItemContent', {'description': 'Safe'}),
        );
        expect(proposal!.tier.decision, AiGateDecision.execute);
        if (restriction == 'source unknown') {
          h.sourceVisibilityUnreadable = true;
        } else {
          h.polluted = true;
        }
        final result = await h.coordinator.approve(proposal);
        expect(result.state, AiJournalState.notExecuted);
        expect(result.reasonCode, 'approvalRequired');
        expect(h.freshnessReads, 2);
        expect(h.graph.events, ['open:1', 'open:2']);
        expect(h.graph.mutations, 0);
      },
    );
  }

  test(
    'source confidentiality once unknown survives a later target opening',
    () async {
      _gate(true);
      final h = await G0eHarness.create();
      addTearDown(h.dispose);
      h.level = AiAutonomyLevel.conversationGrant;
      h.sourceVisibilityUnreadable = true;
      h.graph.targetConfidential = null;
      h.visibility = 'public';
      final first = await h.coordinator.propose(
        h.call('updateGroupWorkItemContent', {'description': 'Safe'}),
      );
      expect(
        first!.tier.reasons,
        contains(AiFixedConfirmReason.confidentialOrVisibilityMix),
      );
      h.graph.targetConfidential = false;
      final result = await h.coordinator.approve(first);
      expect(result.state, AiJournalState.succeeded, reason: result.reasonCode);
      expect(h.graph.events, ['open:1', 'open:2', 'start', 'send']);
      // A new proposal retains the conversation's source restriction too.
      h.beginRun();
      final later = await h.coordinator.propose(
        h.call('updateGroupWorkItemContent', {
          'description': 'Another safe edit',
        }),
      );
      expect(
        later!.tier.reasons,
        contains(AiFixedConfirmReason.confidentialOrVisibilityMix),
      );
      expect(later.tier.decision, AiGateDecision.requireApproval);
      expect(h.graph.mutations, 1);
    },
  );

  for (final drift in ['groupId', 'groupFullPath']) {
    test('origin $drift drift invalidates proposal, mutation 0', () async {
      _gate(true);
      final h = await G0eHarness.create();
      addTearDown(h.dispose);
      final proposal = await h.coordinator.propose(
        h.call('updateGroupWorkItemState', {'stateEvent': 'close'}),
      );
      expect(proposal, isNotNull);
      h.currentResource = AiTargetRef(
        kind: AiTargetKind.groupWorkItem,
        iid: 5,
        groupId: drift == 'groupId' ? 8 : 7,
        groupFullPath: drift == 'groupFullPath' ? 'team/other' : g0ePath,
      );
      final result = await h.coordinator.approve(proposal!);
      expect(result.state, AiJournalState.notExecuted);
      expect(result.reasonCode, 'settingsChanged');
      expect(h.graph.mutations, 0);
    });
  }

  for (final tamper in ['swap group', 'remove group', 'inject project']) {
    test('bindPreparedText rejects $tamper with mutation 0', () {
      var mutations = 0;
      final request = _request();
      final prepared = port.AiWritePrepared.graph(
        request: request,
        releaseName: '$g0ePath#5',
        writeKeys: const {},
        textMutation: (_, request) async {
          mutations++;
          return const GraphWriteResult();
        },
      );
      final arguments = Map<String, Object?>.from(request.arguments);
      if (tamper == 'swap group') arguments['groupId'] = 8;
      if (tamper == 'remove group') arguments.remove('groupId');
      if (tamper == 'inject project') arguments['projectId'] = 7;
      expect(
        () => prepared.bindPreparedText(_request(args: arguments)),
        throwsA(isA<GraphHookContractException>()),
      );
      expect(mutations, 0);
    });
  }

  test(
    'controller freshness foreign Group or iid produces no provenance',
    () async {
      const group = GraphResourceRef(
        id: 'gid://gitlab/Group/7',
        fullPath: g0ePath,
      );
      final h = await StackHarness.create(
        origin: const AiGroupWorkItemOrigin(
          group: group,
          iid: 5,
          title: 'Group item',
        ),
        configure: (server) {
          server.overrides['GET groups/7'] = (_) => jsonResponse({
            'id': 7,
            'full_path': g0ePath,
            'visibility': 'private',
          });
          server.overrides['POST '] = (_) => jsonResponse({
            'data': {'namespace': _namespace()},
          });
        },
      );
      addTearDown(h.dispose);
      final current = await h.controller.readWriteFreshnessForTesting(
        _request(),
        capabilityLedger: const G0eLedger(),
        groupIdentity: () =>
            g0eIdentity(h.session.api!, generation: h.session.generation),
      );
      expect(current.provenance.keys, containsAll(['description', 'title']));
      for (final foreign in [
        g0eIdentity(
          h.session.api!,
          groupId: 8,
          generation: h.session.generation,
        ),
        g0eIdentity(h.session.api!, iid: 6, generation: h.session.generation),
      ]) {
        final fresh = await h.controller.readWriteFreshnessForTesting(
          _request(),
          capabilityLedger: const G0eLedger(),
          groupIdentity: () => foreign,
        );
        expect(fresh.provenance, isEmpty);
        expect(fresh.visibilityUnreadable, isTrue);
      }
      expect(
        h.server.mutations.where(
          (request) =>
              request.uri.path != '/gitlab/api/graphql' ||
              (request.data as Map)['query'] != namespaceWorkItemQuery,
        ),
        isEmpty,
      );
    },
  );
}
