import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_support.dart';
import 'mr6b3g_support.dart' show g0eIdentity;
import '../support/namespace_work_item_query.dart';

const groupContentStageOperations = <String>{'updateGroupWorkItemContent'};
const _operation = 'updateGroupWorkItemContent';
const _path = 'studio/mobile-workspace';
const _scope = AiWriteScope(
  accountKey: mr6b3Account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.groupWorkItem,
      groupId: 7,
      groupFullPath: _path,
      iid: 31,
    ),
  ],
);

void main() {
  setUp(() {
    aiGroupWorkItemWritesEnabledForTesting = true;
    addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
  });
  _groupContracts();
  test('fixed hidden alias has group scope, text roles and cap 21', () {
    final row = productionAiLedger.find(_operation)!;
    expect(
      aiGroupContentRows.map((row) => row.operationId).toSet(),
      groupContentStageOperations,
    );
    expect(row.modelVisible, isFalse);
    expect(row.namedMethod, 'updateWorkItemContent');
    expect(row.scopeClass, AiScopeClass.groupWorkItem);
    expect(row.baseTier, AiWriteTier.t2);
    expect(row.boundary, AiWriteBoundary.graph);
    expect(
      row.arguments.keys,
      unorderedEquals(['groupId', 'iid', 'title', 'description']),
    );
    expect(row.arguments['title']!.required, isFalse);
    expect(row.arguments['description']!.required, isFalse);
    expect(row.arguments['title']!.text, AiTextRole.plainContent);
    expect(row.arguments['description']!.text, AiTextRole.quickActionMarkdown);
    expect(row.arguments['description']!.writableField, 'issueDescription');
    expect(row.editableField, 'description');
    const logicalReads = 2 * (1 + 3) + 1 + 1;
    expect(logicalReads, 10);
    expect(row.httpCap, 2 * logicalReads + 1);
    expect(aiWriteRequestAllowance(_operation, oauthReplay: false), 11);
  });

  test(
    'description-only clear preserves title and omits unsupported revision input',
    () async {
      final f = _Fixture();
      addTearDown(f.close);
      final prepared = await f.prepare({'description': ''});
      expect(prepared.currentFields, {
        'title': 'Original title',
        'description': 'Original description',
      });
      expect((prepared.preview as port.AiFieldsPreview).fields, {
        'description': '',
      });
      final result = await f.commit(prepared) as port.AiWriteSettled;
      expect(result.state, AiJournalState.succeeded);
      expect(result.readbackVerified, isTrue);
      expect(f.server.input, {
        'id': 'gid://gitlab/WorkItem/91',
        'descriptionWidget': {'description': ''},
      });
      expect(f.server.input, isNot(contains('expectedUpdatedAt')));
      expect(f.server.title, 'Original title');
      expect(f.server.description, '');
      expect(f.hooks, 1);
      expect(f.starts, 1);
    },
  );

  test(
    'title-only update omits description and preserves whitespace',
    () async {
      final f = _Fixture();
      addTearDown(f.close);
      final prepared = await f.prepare({'title': '  Changed title  '});
      expect(
        (await f.commit(prepared) as port.AiWriteSettled).state,
        AiJournalState.succeeded,
      );
      expect(f.server.input!['title'], '  Changed title  ');
      expect(f.server.input!.containsKey('descriptionWidget'), isFalse);
      expect(f.server.description, 'Original description');
    },
  );

  for (final title in [
    '',
    ' \t\n ',
    'bad\u0000title',
    'a' * 256,
    '😀' * 256,
    'e\u0301' * 128,
  ]) {
    test(
      'invalid title (${title.runes.length} code points) refuses without HTTP',
      () async {
        final f = _Fixture();
        addTearDown(f.close);
        await expectLater(
          f.prepare({'title': title}),
          throwsA(
            isA<port.AiWriteRefused>().having(
              (e) => e.reason,
              'reason',
              'validation',
            ),
          ),
        );
        expect(f.server.adapter.requests, isEmpty);
        expect(f.server.mutations, 0);
      },
    );
  }

  for (final title in ['a' * 255, '😀' * 255, '${'e\u0301' * 127}x']) {
    test(
      '255 code point title succeeds (${title.length} UTF-16 units)',
      () async {
        final f = _Fixture();
        addTearDown(f.close);
        expect(
          (await f.commit(await f.prepare({'title': title}))
                  as port.AiWriteSettled)
              .state,
          AiJournalState.succeeded,
        );
        expect(f.server.input!['title'], title);
      },
    );
  }

  test(
    'content fake rejects unknown WorkItemUpdateInput keys with top-level errors',
    () async {
      for (final key in ['expectedUpdatedAt', 'unexpectedWidget']) {
        final f = _Fixture();
        addTearDown(f.close);
        final client = Dio()..httpClientAdapter = f.server.adapter;
        addTearDown(() => client.close(force: true));
        final response = await client.post<Object?>(
          f.server.api.instance.graphQL.toString(),
          options: Options(followRedirects: false),
          data: {
            'query':
                r'mutation MobileUpdateWorkItemContent($input: WorkItemUpdateInput!) { workItemUpdate(input: $input) { errors } }',
            'variables': {
              'input': {
                'id': 'gid://gitlab/WorkItem/91',
                'title': 'Must not be applied',
                key: 'unsupported',
              },
            },
          },
        );
        final envelope = response.data! as Map;
        expect(envelope['errors'], isNotEmpty);
        expect(envelope, isNot(contains('data')));
        expect(f.server.title, 'Original title');
        expect(f.server.description, 'Original description');
        expect(f.server.updatedAt, _Server.opened);
      }
    },
  );

  test('description bounds refuse at prepare without HTTP', () async {
    final f = _Fixture();
    addTearDown(f.close);
    for (final description in [
      'x' * (GitLabApi.maxTextBytes + 1),
      '😀' * (GitLabApi.maxTextBytes ~/ 4 + 1),
      '\n' * GitLabApi.maxTextLines,
      'bad\u0000description',
    ]) {
      await expectLater(
        f.prepare({'description': description}),
        throwsA(
          isA<port.AiWriteRefused>().having(
            (e) => e.reason,
            'reason',
            'validation',
          ),
        ),
      );
    }
    expect(f.server.adapter.requests, isEmpty);
  });

  test('long description refuses before any proposal or mutation', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    expect(
      await h.propose({'description': 'x' * (GitLabApi.maxTextBytes + 1)}),
      isNull,
    );
    expect(h.outcomes.single.reasonCode, 'validation');
    expect(h.fixture.server.mutations, 0);
    expect(h.storage.journal.entries(mr6b3Account), isEmpty);
  });

  test(
    'description exceeding bounds after attribution refuses before a card',
    () async {
      final h = await _Harness.create(aiAttribution: true);
      addTearDown(h.close);
      final description = List.filled(
        GitLabApi.maxTextLines,
        'line',
      ).join('\n');
      expect(isValidWorkItemContentInput(description: description), isTrue);
      expect(await h.propose({'description': description}), isNull);
      expect(h.outcomes.single.reasonCode, 'validation');
      expect(h.fixture.server.mutations, 0);
      expect(h.storage.journal.entries(mr6b3Account), isEmpty);
    },
  );

  test(
    'oversized edited description is refused before updating the card',
    () async {
      final h = await _Harness.create();
      addTearDown(h.close);
      final proposal = (await h.propose({'description': 'Valid proposal'}))!;
      final preview = (proposal.preview as port.AiFieldsPreview).fields;
      final edited = await h.coordinator.approve(
        proposal,
        editedText: 'x' * (GitLabApi.maxTextBytes + 1),
      );
      expect(edited.reasonCode, 'validation');
      expect((proposal.preview as port.AiFieldsPreview).fields, preview);
      expect((await h.approve(proposal)).reasonCode, 'validation');
      expect(h.fixture.server.mutations, 0);
      expect(h.storage.journal.entries(mr6b3Account), isEmpty);
    },
  );

  test(
    'edited description is rechecked after attribution before updating the card',
    () async {
      final h = await _Harness.create(aiAttribution: true);
      addTearDown(h.close);
      final proposal = (await h.propose({'description': 'Valid proposal'}))!;
      final preview = (proposal.preview as port.AiFieldsPreview).fields;
      final description = List.filled(
        GitLabApi.maxTextLines,
        'line',
      ).join('\n');
      final edited = await h.coordinator.approve(
        proposal,
        editedText: description,
      );
      expect(edited.reasonCode, 'validation');
      expect((proposal.preview as port.AiFieldsPreview).fields, preview);
      expect(h.fixture.server.mutations, 0);
      expect(h.storage.journal.entries(mr6b3Account), isEmpty);
    },
  );

  test('no text fields and wrong field types refuse without HTTP', () async {
    final f = _Fixture();
    addTearDown(f.close);
    for (final args in <Map<String, Object?>>[
      {},
      {'title': null},
      {'description': false},
    ]) {
      await expectLater(
        f.prepare(args),
        throwsA(
          isA<port.AiWriteRefused>().having(
            (e) => e.reason,
            'reason',
            'validation',
          ),
        ),
      );
    }
    expect(f.server.adapter.requests, isEmpty);
  });

  test('fresh no-op never crosses either hook', () async {
    final f = _Fixture();
    addTearDown(f.close);
    final result = await f.commit(await f.prepare({'title': 'Original title'}));
    expect(result, isA<port.AiGraphNoChange>());
    expect(f.server.mutations, 0);
    expect(f.hooks, 0);
    expect(f.starts, 0);
  });

  test(
    'same-revision body drift changes binding and preflight refuses targetChanged',
    () async {
      final f = _Fixture();
      addTearDown(f.close);
      final first = await f.prepare({'description': 'changed'});
      f.server.description = 'Other editor content';
      final second = await f.prepare({'description': 'changed'});
      expect(second.bindingDigest, isNot(first.bindingDigest));
      final result = await f.commit(first) as port.AiWriteNotSent;
      expect(result.reasonCode, 'targetChanged');
      expect(f.server.mutations, 0);
      expect(f.hooks, 0);
    },
  );

  test('revision drift refuses before the durable hook', () async {
    final f = _Fixture();
    addTearDown(f.close);
    final prepared = await f.prepare({'title': 'changed'});
    f.server.updatedAt = _Server.saved;
    final result = await f.commit(prepared) as port.AiWriteNotSent;
    expect(result.reasonCode, 'targetChanged');
    expect(f.hooks, 0);
    expect(f.server.mutations, 0);
  });

  test('hook failure propagates and mayStart false sends nothing', () async {
    final f = _Fixture();
    addTearDown(f.close);
    await expectLater(
      f.commit(
        await f.prepare({'title': 'changed'}),
        before: () async => throw StateError('synthetic journal failure'),
      ),
      throwsStateError,
    );
    expect(f.starts, 0);
    expect(f.server.mutations, 0);
    final result = await f.commit(
      await f.prepare({'title': 'changed'}),
      mayStart: () => false,
    );
    expect(result, isA<port.AiWriteNotSent>());
    expect(f.server.mutations, 0);
  });

  test(
    'mutation rejection and failed independent readback stay uncertain',
    () async {
      for (final readbackFailure in [false, true]) {
        final f = _Fixture();
        addTearDown(f.close);
        f.server.rejectMutation = !readbackFailure;
        f.server.failReadback = readbackFailure;
        final result =
            await f.commit(await f.prepare({'description': 'changed'}))
                as port.AiWriteSettled;
        expect(result.state, AiJournalState.writeUncertain);
        expect(result.readbackVerified, isFalse);
        expect(f.server.mutations, 1);
      }
    },
  );

  test(
    'prepare refuses missing description widget, permission, actor and foreign scope',
    () async {
      for (final scenario in ['widget', 'permission', 'actor', 'scope']) {
        final f = _Fixture();
        addTearDown(f.close);
        if (scenario == 'widget') f.server.widget = false;
        if (scenario == 'permission') f.server.permission = false;
        if (scenario == 'actor') f.server.actor = 8;
        if (scenario == 'scope') f.server.group = 99;
        final expected = switch (scenario) {
          'widget' => isA<port.AiWriteRefused>().having(
            (e) => e.reason,
            'reason',
            'unsupported',
          ),
          'permission' => isA<port.AiWriteRefused>().having(
            (e) => e.reason,
            'reason',
            'forbidden',
          ),
          'actor' => isA<ApiFailure>().having(
            (e) => e.kind,
            'kind',
            FailureKind.cancelled,
          ),
          _ => isA<ApiFailure>().having(
            (e) => e.kind,
            'kind',
            FailureKind.invalidResponse,
          ),
        };
        await expectLater(
          f.prepare({'description': 'changed'}),
          throwsA(expected),
        );
        expect(f.server.mutations, 0);
      }
    },
  );

  test(
    'coordinator journals prepared, dispatching and succeeded before independent readback',
    () async {
      final h = await _Harness.create();
      addTearDown(h.close);
      final proposal = await h.propose({'description': 'changed'});
      expect(proposal, isNotNull);
      expect(h.storage.journal.entries(mr6b3Account), isEmpty);
      h.fixture.server.onMutation = () {
        expect(
          h.storage.journal.entries(mr6b3Account).last.state,
          AiJournalState.dispatching,
        );
      };
      expect((await h.approve(proposal!)).state, AiJournalState.succeeded);
      expect(
        h.storage.journal.entries(mr6b3Account).last.state,
        AiJournalState.succeeded,
      );
    },
  );

  test(
    'coordinator noop is notExecuted, failed hook retains prepared, sent failure is uncertain',
    () async {
      for (final scenario in ['noop', 'hook', 'mutation']) {
        final h = await _Harness.create();
        addTearDown(h.close);
        final proposal = await h.propose({
          'description': scenario == 'noop'
              ? 'Original description'
              : 'changed',
        });
        expect(proposal, isNotNull);
        if (scenario == 'hook') {
          h.storage.files.failWriteNumber = h.storage.files.writeCount + 2;
        }
        if (scenario == 'mutation') h.fixture.server.rejectMutation = true;
        final result = await h.approve(proposal!);
        expect(result.state, switch (scenario) {
          'mutation' => AiJournalState.writeUncertain,
          'noop' => AiJournalState.succeeded,
          _ => AiJournalState.notExecuted,
        });
        expect(h.fixture.server.mutations, scenario == 'mutation' ? 1 : 0);
        expect(
          h.storage.journal.entries(mr6b3Account).last.state,
          switch (scenario) {
            'noop' => AiJournalState.notExecuted,
            'hook' => AiJournalState.prepared,
            _ => result.state,
          },
        );
      }
    },
  );

  for (final level in AiAutonomyLevel.values.where(
    (value) => value != AiAutonomyLevel.readOnly,
  )) {
    test(
      'hidden-span removal requires approval at $level using fresh port fields',
      () async {
        final h = await _Harness.create(level: level);
        addTearDown(h.close);
        h.fixture.server.description =
            'Keep ![private](/uploads/0123456789abcdef0123456789abcdef/a.png) tail';
        final proposal = await h.propose({'description': 'Keep tail'});
        expect(proposal, isNotNull);
        expect(proposal!.tier.decision, AiGateDecision.requireApproval);
        expect(
          proposal.tier.reasons,
          contains(AiFixedConfirmReason.wholeFieldDropsHiddenSpans),
        );
        expect(h.fixture.server.mutations, 0);
        expect((await h.approve(proposal)).state, AiJournalState.succeeded);
      },
    );
  }

  test('editing description on approval rechecks hidden-span removal', () async {
    final h = await _Harness.create();
    addTearDown(h.close);
    const original =
        'Keep ![private](/uploads/0123456789abcdef0123456789abcdef/a.png) tail';
    h.fixture.server.description = original;
    final proposal = (await h.propose({'description': original}))!;
    expect(proposal.editableField, 'description');
    expect(
      proposal.tier.reasons,
      isNot(contains(AiFixedConfirmReason.wholeFieldDropsHiddenSpans)),
    );
    final requests = h.fixture.server.adapter.requests.length;
    final edited = await h.coordinator.approve(
      proposal,
      editedText: 'Keep tail',
    );
    expect(edited.reasonCode, 'approvalRequired');
    expect(h.fixture.server.adapter.requests, hasLength(requests));
    expect(
      proposal.tier.reasons,
      contains(AiFixedConfirmReason.wholeFieldDropsHiddenSpans),
    );
    expect(proposal.tier.decision, AiGateDecision.requireApproval);
    expect(h.fixture.server.mutations, 0);
    expect(h.storage.journal.entries(mr6b3Account), isEmpty);
    expect((await h.approve(proposal)).state, AiJournalState.succeeded);
    expect(h.fixture.server.description, contains('Keep tail'));
    expect(h.fixture.server.description, isNot(contains('/uploads/')));
  });

  for (final failReadback in [false, true]) {
    test(
      'identical edits require approval and readback ($failReadback)',
      () async {
        final h = await _Harness.create(aiAttribution: true);
        addTearDown(h.close);
        final proposal = (await h.propose({'description': 'Proposed text'}))!;
        final oldDigest = proposal.payloadDigest;
        final requests = h.fixture.server.adapter.requests.length;
        const edited = 'Steps\n/close\n@all';
        final editing = await h.coordinator.approve(
          proposal,
          editedText: edited,
        );
        expect(editing.state, AiJournalState.notExecuted);
        expect(editing.reasonCode, 'approvalRequired');
        expect(h.fixture.server.adapter.requests, hasLength(requests));
        expect(h.fixture.server.mutations, 0);
        expect(proposal.payloadDigest, isNot(oldDigest));
        expect(
          proposal.tier.reasons,
          contains(AiFixedConfirmReason.massMention),
        );
        final shown =
            (proposal.preview as port.AiFieldsPreview).fields['description']!
                as String;
        expect(shown, isNot(edited));
        expect(shown.split('\n').any((line) => line.startsWith('/')), isFalse);
        final editedDigest = proposal.payloadDigest;
        final repeated = await h.coordinator.approve(
          proposal,
          editedText: edited,
        );
        expect(repeated.state, AiJournalState.notExecuted);
        expect(repeated.reasonCode, 'approvalRequired');
        expect(proposal.valid, isTrue);
        expect(proposal.editedText, edited);
        expect(proposal.payloadDigest, editedDigest);
        expect(h.fixture.server.adapter.requests, hasLength(requests));
        expect(h.fixture.server.mutations, 0);
        expect(h.storage.journal.entries(mr6b3Account), isEmpty);
        h.fixture.server.failReadback = failReadback;
        h.fixture.server.onMutation = () => expect(proposal.editedText, edited);
        final outcome = await h.approve(proposal);
        expect(
          outcome.state,
          failReadback
              ? AiJournalState.writeUncertain
              : AiJournalState.succeeded,
        );
        expect(outcome.readbackConfirmed, !failReadback);
        expect(h.fixture.server.mutations, 1);
        expect(h.fixture.server.input!['descriptionWidget'], {
          'description': shown,
        });
        expect(proposal.editedText, failReadback ? edited : null);
        expect(h.fixture.server.successfulReads, 10);
        expect(h.fixture.server.readStages, {
          'freshness': 2,
          'actor': 2,
          'namespace': 2,
          'content': 4,
        });
        expect((await h.approve(proposal)).state, outcome.state);
        expect(h.fixture.server.mutations, 1);
      },
    );
  }

  for (final drift in ['revision', 'description']) {
    test('edited description rejects target $drift drift', () async {
      final h = await _Harness.create();
      addTearDown(h.close);
      final proposal = (await h.propose({'description': 'Proposed text'}))!;
      const edited = 'New description';
      expect(
        (await h.coordinator.approve(proposal, editedText: edited)).reasonCode,
        'approvalRequired',
      );
      if (drift == 'revision') {
        h.fixture.server.updatedAt = DateTime.utc(2026, 10, 28);
      } else {
        h.fixture.server.description = 'Concurrent server edit';
      }
      final outcome = await h.approve(proposal);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, 'targetChanged');
      expect(h.fixture.server.mutations, 0);
      expect(proposal.editedText, edited);
    });
  }

  test(
    'pipeline-blocked description edits stay blocked on reapproval',
    () async {
      final h = await _Harness.create();
      addTearDown(h.close);
      final proposal = (await h.propose({'description': 'Proposed text'}))!;
      final originalPreview = proposal.preview;
      final originalDigest = proposal.payloadDigest;
      final requests = h.fixture.server.adapter.requests.length;
      const edited = '![remote](https://outside.example/a.png)';
      for (final edit in [edited, edited, null]) {
        final outcome = await h.coordinator.approve(proposal, editedText: edit);
        expect(outcome.reasonCode, text.AiTextBlockCode.externalMedia);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(proposal.valid, isTrue);
        expect(h.fixture.server.adapter.requests, hasLength(requests));
        expect(h.fixture.server.mutations, 0);
        expect(proposal.preview, same(originalPreview));
        expect(proposal.payloadDigest, originalDigest);
        expect(proposal.editedText, edited);
        expect(h.storage.journal.entries(mr6b3Account), isEmpty);
      }
    },
  );

  test('bypass identical edits wait for approval before one send', () async {
    final h = await _Harness.create(level: AiAutonomyLevel.bypass);
    addTearDown(h.close);
    final proposal = (await h.propose({'description': 'Proposed for @all'}))!;
    final requests = h.fixture.server.adapter.requests.length;
    const edited = 'User revised description';
    for (var attempt = 0; attempt < 2; attempt++) {
      final outcome = await h.coordinator.approve(proposal, editedText: edited);
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, 'approvalRequired');
      expect(proposal.valid, isTrue);
      expect(h.fixture.server.adapter.requests, hasLength(requests));
      expect(h.fixture.server.mutations, 0);
      expect(h.storage.journal.entries(mr6b3Account), isEmpty);
    }
    final shown =
        (proposal.preview as port.AiFieldsPreview).fields['description'];
    final outcome = await h.approve(proposal);
    expect(outcome.state, AiJournalState.succeeded);
    expect(outcome.readbackConfirmed, isTrue);
    expect(outcome.mutationCount, 1);
    expect(h.fixture.server.description, shown);
    expect(h.fixture.server.mutations, 1);
    expect(h.fixture.server.successfulReads, 10);
    expect(proposal.editedText, isNull);
    await h.approve(proposal);
    expect(h.fixture.server.mutations, 1);
  });

  for (final level in AiAutonomyLevel.values.where(
    (value) => value != AiAutonomyLevel.readOnly,
  )) {
    test(
      'sanitized preview and sent description agree; @all confirms at $level',
      () async {
        final h = await _Harness.create(level: level);
        addTearDown(h.close);
        const raw = 'Steps\n/close\n@all';
        final proposal = await h.propose({'description': raw});
        expect(proposal, isNotNull);
        expect(proposal!.tier.decision, AiGateDecision.requireApproval);
        expect(
          proposal.tier.reasons,
          contains(AiFixedConfirmReason.massMention),
        );
        final preview = (proposal.preview as port.AiFieldsPreview).fields;
        expect(preview.keys, ['description']);
        final shown = preview['description']! as String;
        expect(shown, isNot(raw));
        expect(shown.split('\n').any((line) => line.startsWith('/')), isFalse);
        expect(h.fixture.server.mutations, 0);
        // One proposal opening: REST actor, WI identity, content. Text binding
        // must reuse that capability rather than run another prepare/read.
        expect(h.fixture.server.successfulReads, 4);
        expect((await h.approve(proposal)).state, AiJournalState.succeeded);
        expect(h.fixture.server.description, shown);
        expect(h.fixture.server.input!['descriptionWidget'], {
          'description': shown,
        });
        expect(h.fixture.server.input!.containsKey('title'), isFalse);
        expect(h.fixture.server.title, 'Original title');
        expect(h.fixture.server.successfulReads, 10);
      },
    );
  }

  for (final combined in [false, true]) {
    final fields = combined ? 'title+description' : 'title-only';
    test(
      'coordinator $fields writes once with strict independent readback',
      () async {
        final h = await _Harness.create();
        addTearDown(h.close);
        const title = '  Changed title  ';
        const description = 'Changed description';
        final proposal = await h.propose({
          'title': title,
          if (combined) 'description': description,
        });
        expect(proposal, isNotNull, reason: h.outcomes.toString());
        expect((proposal!.preview as port.AiFieldsPreview).fields, {
          'title': title,
          if (combined) 'description': description,
        });
        expect(h.fixture.server.successfulReads, 4);
        expect(h.fixture.server.contentReads, 1);
        expect(h.fixture.server.mutations, 0);
        expect(h.storage.journal.entries(mr6b3Account), isEmpty);

        final result = await h.approve(proposal);
        expect(
          result.state,
          AiJournalState.succeeded,
          reason: result.reasonCode,
        );
        expect(result.readbackConfirmed, isTrue);
        expect(result.mutationCount, 1);
        expect(h.fixture.server.input, {
          'id': 'gid://gitlab/WorkItem/91',
          'title': title,
          if (combined) 'descriptionWidget': {'description': description},
        });
        expect(h.fixture.server.title, title);
        expect(
          h.fixture.server.description,
          combined ? description : 'Original description',
        );
        expect(h.fixture.server.contentReads, 4);
        expect(h.fixture.server.readStages, {
          'freshness': 2,
          'actor': 2,
          'namespace': 2,
          'content': 4,
        });
        expect(h.fixture.server.adapter.requests, hasLength(11));
        expect(h.fixture.server.mutations, 1);
        expect(
          h.storage.journal.entries(mr6b3Account).last.state,
          AiJournalState.succeeded,
        );
        await h.approve(proposal);
        expect(h.fixture.server.mutations, 1);
      },
    );

    for (final corruption in ['title', 'owner']) {
      test(
        'coordinator $fields rejects independent readback $corruption drift',
        () async {
          final h = await _Harness.create();
          addTearDown(h.close);
          final proposal = await h.propose({
            'title': 'Changed title',
            if (combined) 'description': 'Changed description',
          });
          expect(proposal, isNotNull);
          h.fixture.server.tamper = (stage, node) {
            if (stage != 'content4') return;
            if (corruption == 'title') {
              node['title'] = 'Different readback title';
            } else {
              node['namespace'] = {
                'id': 'gid://gitlab/Group/8',
                'fullPath': _path,
              };
            }
          };
          final result = await h.approve(proposal!);
          expect(result.state, AiJournalState.writeUncertain);
          expect(result.readbackConfirmed, isFalse);
          expect(h.fixture.server.title, 'Changed title');
          expect(h.fixture.server.contentReads, 4);
          expect(h.fixture.server.mutations, 1);
          expect(
            h.storage.journal.entries(mr6b3Account).last.state,
            AiJournalState.writeUncertain,
          );
        },
      );
    }

    for (final source in ['description', 'note']) {
      test('$source upload token in $fields refuses before mutation', () async {
        final h = await _Harness.create(level: AiAutonomyLevel.bypass);
        addTearDown(h.close);
        const original =
            '[file](/uploads/0123456789abcdef0123456789abcdef/a.png)';
        h.fixture.server.description = original;
        final field = text.AiFieldProvenance.groupWorkItem(
          identity: g0eIdentity(h.fixture.server.api, fullPath: _path, iid: 31),
          completeValue: true,
          noteId: source == 'note' ? 71 : null,
        );
        final masked = h.placeholders.redactOutgoing(original, field: field);
        expect(masked, contains('[[upload:'));
        expect(
          await h.propose({
            'title': masked,
            if (combined) 'description': 'Safe description',
          }),
          isNull,
        );
        expect(h.outcomes.single.reasonCode, text.AiTextBlockCode.rereadField);
        expect(h.fixture.server.successfulReads, 4);
        expect(h.fixture.server.mutations, 0);
        expect(h.storage.journal.entries(mr6b3Account), isEmpty);
      });
    }
  }

  for (final atDispatch in [false, true]) {
    final phase = atDispatch ? 'dispatch' : 'proposal';
    for (final cut in ['excerpt', 'output limit']) {
      test('$cut title refuses at $phase despite complete opening', () async {
        final h = await _Harness.create(level: AiAutonomyLevel.bypass);
        addTearDown(h.close);
        final description = text.AiFieldProvenance.groupWorkItem(
          identity: g0eIdentity(h.fixture.server.api, fullPath: _path, iid: 31),
          completeValue: true,
        );
        final title = text.AiFieldProvenance(
          resourceKey: description.resourceKey,
          fieldName: 'title',
          completeValue: true,
          resourceWeb: description.resourceWeb,
          accountKey: description.accountKey,
          groupId: description.groupId,
          groupFullPath: description.groupFullPath,
        );
        void cutTitle() {
          h.placeholders.recordFieldDelivery(title, whole: cut != 'excerpt');
          if (cut == 'output limit') h.placeholders.markWholeFieldsCut();
        }

        if (!atDispatch) cutTitle();
        final proposal = await h.propose({
          'title': 'Changed title',
          'description': 'Changed description',
        });
        if (atDispatch) {
          expect(proposal, isNotNull);
          cutTitle();
          final result = await h.approve(proposal!);
          expect(result.state, AiJournalState.notExecuted);
          expect(result.reasonCode, text.AiTextBlockCode.fieldTooLong);
        } else {
          expect(proposal, isNull);
          expect(
            h.outcomes.single.reasonCode,
            text.AiTextBlockCode.fieldTooLong,
          );
          expect(h.storage.journal.entries(mr6b3Account), isEmpty);
        }
        expect(h.fixture.server.contentReads, atDispatch ? 2 : 1);
        expect(h.fixture.server.mutations, 0);
      });
    }
  }

  test('valid title cannot authorize a note token in description', () async {
    final h = await _Harness.create(level: AiAutonomyLevel.bypass);
    addTearDown(h.close);
    final field = text.AiFieldProvenance.groupWorkItem(
      identity: g0eIdentity(h.fixture.server.api, fullPath: _path, iid: 31),
      completeValue: true,
      noteId: 71,
    );
    final masked = h.placeholders.redactOutgoing(
      '[file](/uploads/0123456789abcdef0123456789abcdef/a.png)',
      field: field,
    );
    expect(masked, contains('[[upload:'));
    expect(
      await h.propose({'title': 'Changed title', 'description': masked}),
      isNull,
    );
    expect(h.outcomes.single.reasonCode, text.AiTextBlockCode.rereadField);
    expect(h.fixture.server.successfulReads, 4);
    expect(h.fixture.server.mutations, 0);
    expect(h.storage.journal.entries(mr6b3Account), isEmpty);
  });

  test(
    'shared text pipeline refuses external embeds and secrets before mutation',
    () async {
      for (final item in [
        (
          '![remote](https://outside.example/a.png)',
          text.AiTextBlockCode.externalMedia,
        ),
        ('token: glpat-ABCDEFGHIJKLMNOPQRST', text.AiTextBlockCode.secret),
      ]) {
        final h = await _Harness.create();
        addTearDown(h.close);
        expect(await h.propose({'description': item.$1}), isNull);
        expect(h.outcomes.single.reasonCode, item.$2);
        expect(h.fixture.server.mutations, 0);
        expect(h.fixture.server.successfulReads, 4);
      }
    },
  );

  for (final oauth in [false, true]) {
    test(
      'measured L10 PAT11 and reachable OAuth replay cap ($oauth)',
      () async {
        final h = await _Harness.create(oauth: oauth);
        addTearDown(h.close);
        h.fixture.server.challengeBoundReads = false;
        final proposal = await h.propose({'description': 'changed'});
        expect(proposal, isNotNull, reason: h.outcomes.toString());
        expect((await h.approve(proposal!)).state, AiJournalState.succeeded);
        expect(h.fixture.server.successfulReads, 10);
        expect(h.fixture.server.readStages, {
          'freshness': 2,
          'actor': 2,
          'namespace': 2,
          'content': 4,
        });
        expect(h.fixture.server.mutations, 1);
        expect(h.fixture.server.refreshes, oauth ? 2 : 0);
        expect(h.fixture.server.adapter.requests.length, oauth ? 13 : 11);
        expect(
          h.fixture.server.adapter.requests.length,
          lessThanOrEqualTo(
            aiWriteRequestAllowance(_operation, oauthReplay: oauth),
          ),
        );
      },
    );
  }
}

void _groupContracts() {
  for (final limit in [20, 21]) {
    test('static OAuth allowance reserves 21 against budget $limit', () async {
      final h = await _Harness.create(oauth: true);
      addTearDown(h.close);
      h.fixture.server.challengeBoundReads = false;
      h.budget = AiToolBudget(maxGitLabRequests: limit);
      final proposal = await h.propose({'description': 'changed'});
      if (limit == 20) {
        expect(proposal, isNull);
        expect(h.outcomes.single.reasonCode, 'httpBudgetExceeded');
        expect(h.fixture.server.adapter.requests, isEmpty);
      } else {
        expect(proposal, isNotNull);
        expect((await h.approve(proposal!)).state, AiJournalState.succeeded);
        expect(h.fixture.server.adapter.requests.length, 13);
      }
    });
  }
  test('production row and gate remain hidden with no model offer', () {
    aiGroupWorkItemWritesEnabledForTesting = null;
    expect(aiGroupWorkItemWritesAreEnabled, isFalse);
    expect(
      productionAiLedger.modelVisible.map((row) => row.operationId),
      isNot(contains(_operation)),
    );
    expect(toolsForScope(_scope), isEmpty);
  });

  test(
    'prepared identity, release name and canonical key are group-bound',
    () async {
      final f = _Fixture();
      addTearDown(f.close);
      final prepared = await f.prepare({'description': 'changed'});
      final identity = prepared.groupIdentity!;
      expect(identity.apiOwner, same(f.server.api));
      expect(identity.generation, 7);
      expect(identity.groupId, 7);
      expect(identity.iid, 31);
      expect(identity.workItemGid, 'gid://gitlab/WorkItem/91');
      expect(prepared.hasCurrentGroupIdentity, isTrue);
      expect(prepared.releaseName, '$_path#31');
      expect(prepared.confirmName, prepared.releaseName);
      expect(prepared.writeKeys, {
        AiConflictKey([mr6b3Account, 'group:7', 'workItem', '31']),
      });
      expect(prepared.dependencyKeys, isEmpty);
      final target = prepared.bindingTargets.single;
      expect(target.kind, AiTargetKind.groupWorkItem);
      expect(target.groupId, 7);
      expect(target.groupFullPath, _path);
      expect(target.iid, 31);
      expect(target.workItemGid, identity.workItemGid);
      expect(target.projectId, isNull);
      expect(prepared.projectPath, isNull);
      expect(prepared.journal.updatedAt, _Server.opened.toIso8601String());
      f.server.api.clearReadCache();
      expect(prepared.hasCurrentGroupIdentity, isFalse);
    },
  );

  for (final withContext in [false, true]) {
    test(
      'absent or revoked trusted context refuses before HTTP ($withContext)',
      () async {
        final f = _Fixture(withContext: withContext);
        addTearDown(f.close);
        f.live = false;
        await expectLater(
          f.prepare({'description': 'changed'}),
          throwsA(isA<port.AiWriteRefused>()),
        );
        expect(f.server.adapter.requests, isEmpty);
        expect(f.server.mutations, 0);
      },
    );
  }

  for (final read in [1, 2, 3]) {
    test(
      'context revoked during opening read $read refuses mutation0',
      () async {
        final f = _Fixture();
        addTearDown(f.close);
        f.server.onRead = (number) {
          if (number == read) f.currentGeneration++;
        };
        await expectLater(
          f.prepare({'description': 'changed'}),
          throwsA(anything),
        );
        expect(f.server.successfulReads, read);
        expect(f.server.mutations, 0);
      },
    );
  }

  test('flush-time generation change refuses before send', () async {
    final f = _Fixture();
    addTearDown(f.close);
    final result = await f.commit(
      await f.prepare({'description': 'changed'}),
      before: () async => f.currentGeneration++,
    );
    expect(result, isA<port.AiWriteNotSent>());
    expect(f.server.mutations, 0);
    expect(f.starts, 0);
  });

  test('post-send generation change stays uncertain without replay', () async {
    final f = _Fixture();
    addTearDown(f.close);
    f.server.onMutation = () => f.currentGeneration++;
    final prepared = await f.prepare({'description': 'changed'});
    final result = await f.commit(prepared) as port.AiWriteSettled;
    expect(result.state, AiJournalState.writeUncertain);
    expect(result.readbackVerified, isFalse);
    expect(f.server.mutations, 1);
    expect(
      await f.writePort.commit(prepared, mayStart: () => true),
      isA<port.AiWriteNotSent>(),
    );
    expect(f.server.mutations, 1);
  });

  test('foreign group and sibling iid grant cannot widen', () async {
    for (final arguments in <Map<String, Object?>>[
      {'groupId': 8},
      {'iid': 32},
      {'groupId': 0},
      {'groupId': '7'},
    ]) {
      final f = _Fixture();
      addTearDown(f.close);
      await expectLater(
        f.prepare({'description': 'changed', ...arguments}),
        throwsA(anything),
      );
      expect(f.server.mutations, 0);
      expect(f.server.adapter.requests.length, lessThanOrEqualTo(1));
    }
  });

  for (final key in [
    'projectId',
    'id',
    'query',
    'expectedUpdatedAt',
    'confidential',
    'groupFullPath',
  ]) {
    test('field allowlist refuses $key before HTTP', () async {
      final f = _Fixture();
      addTearDown(f.close);
      await expectLater(
        f.prepare({'description': 'changed', key: 7}),
        throwsA(isA<ApiFailure>()),
      );
      expect(f.server.adapter.requests, isEmpty);
      expect(f.server.mutations, 0);
    });
  }

  test('project and account-global grants cannot authorize content', () async {
    for (final kind in [AiScopeKind.workItem, AiScopeKind.accountGlobal]) {
      final f = _Fixture();
      addTearDown(f.close);
      f.scope = AiWriteScope(
        accountKey: mr6b3Account,
        grants: [
          AiScopeGrant(
            kind: kind,
            projectId: kind == AiScopeKind.workItem ? 7 : null,
            projectPath: kind == AiScopeKind.workItem ? _path : null,
            iid: kind == AiScopeKind.workItem ? 31 : null,
          ),
        ],
      );
      await expectLater(
        f.prepare({'description': 'changed'}),
        throwsA(anything),
      );
      expect(f.server.mutations, 0);
    }
  });

  final corruption = <String, void Function(Map<String, Object?>)>{
    'missing project': (node) => node.remove('project'),
    'project descendant': (node) =>
        node['project'] = {'id': 'gid://gitlab/Project/7', 'fullPath': _path},
    'foreign group same iid and path': (node) =>
        node['namespace'] = {'id': 'gid://gitlab/Group/8', 'fullPath': _path},
    'missing namespace': (node) => node.remove('namespace'),
    'renamed group': (node) => node['namespace'] = {
      'id': 'gid://gitlab/Group/7',
      'fullPath': 'renamed/group',
    },
    'wrong iid': (node) => node['iid'] = '32',
    'wrong WorkItem GID': (node) => node['id'] = 'gid://gitlab/WorkItem/92',
  };
  for (final phase in [
    'namespace',
    'content1',
    'content2',
    'ack',
    'content3',
  ]) {
    for (final entry in corruption.entries) {
      if (phase == 'namespace' && entry.key == 'wrong WorkItem GID') continue;
      test('strict $phase refuses ${entry.key}', () async {
        final f = _Fixture();
        addTearDown(f.close);
        f.server.tamper = (stage, node) {
          if (stage == phase) entry.value(node);
        };
        if (phase == 'namespace' || phase == 'content1') {
          await expectLater(
            f.prepare({'description': 'changed'}),
            throwsA(anything),
          );
          expect(f.server.mutations, 0);
        } else {
          final result = await f.commit(
            await f.prepare({'description': 'changed'}),
          );
          if (phase == 'content2') {
            expect(result, isA<port.AiWriteNotSent>());
            expect(f.hooks, 0);
            expect(f.server.mutations, 0);
          } else {
            expect(
              (result as port.AiWriteSettled).state,
              AiJournalState.writeUncertain,
            );
            expect(result.readbackVerified, isFalse);
            expect(f.server.mutations, 1);
          }
        }
      });
    }
  }

  test('REST actor mismatch refuses before namespace opening', () async {
    final f = _Fixture();
    addTearDown(f.close);
    f.server.restActor = 8;
    await expectLater(
      f.prepare({'description': 'changed'}),
      throwsA(isA<port.AiWriteRefused>()),
    );
    expect(f.server.successfulReads, 1);
    expect(f.server.mutations, 0);
  });

  test('title-only port remains usable without description widget', () async {
    final f = _Fixture();
    addTearDown(f.close);
    f.server.widget = false;
    final prepared = await f.prepare({'title': 'Updated'});
    expect(prepared.currentFields, {'title': 'Original title'});
    expect(
      (await f.commit(prepared) as port.AiWriteSettled).state,
      AiJournalState.succeeded,
    );
    expect(f.server.input!.keys, unorderedEquals(['id', 'title']));
  });

  test(
    'same group whole description placeholder restores after real opening',
    () async {
      final h = await _Harness.create();
      addTearDown(h.close);
      const original =
          'Keep ![file](/uploads/0123456789abcdef0123456789abcdef/a.png)';
      h.fixture.server.description = original;
      final field = text.AiFieldProvenance.groupWorkItem(
        identity: g0eIdentity(h.fixture.server.api, fullPath: _path, iid: 31),
        completeValue: true,
      );
      final masked = h.placeholders.redactOutgoing(original, field: field);
      expect(masked, contains('[[upload:'));
      expect(masked, isNot(contains('0123456789abcdef')));
      final proposal = await h.propose({'description': '$masked changed'});
      expect(proposal, isNotNull);
      expect(h.fixture.server.contentReads, 1);
      final result = await h.approve(proposal!);
      expect(result.state, AiJournalState.succeeded);
      expect(result.readbackConfirmed, isTrue);
      expect(h.fixture.server.description, '$original changed');
      expect(h.fixture.server.contentReads, 4);
      expect(h.fixture.server.successfulReads, 10);
      expect(h.fixture.server.mutations, 1);
    },
  );

  for (final mismatch in ['group', 'iid', 'note', 'title', 'incomplete']) {
    test(
      'placeholder from $mismatch refuses after opening mutation0',
      () async {
        final h = await _Harness.create(level: AiAutonomyLevel.bypass);
        addTearDown(h.close);
        const original =
            '![file](/uploads/0123456789abcdef0123456789abcdef/a.png)';
        h.fixture.server.description = original;
        final field = text.AiFieldProvenance.groupWorkItem(
          identity: g0eIdentity(
            h.fixture.server.api,
            groupId: mismatch == 'group' ? 8 : 7,
            fullPath: _path,
            iid: mismatch == 'iid' ? 32 : 31,
          ),
          completeValue: mismatch != 'incomplete',
          noteId: mismatch == 'note' ? 71 : null,
        );
        final masked = h.placeholders.redactOutgoing(original, field: field);
        if (mismatch != 'incomplete') expect(masked, contains('[[upload:'));
        final proposal = await h.propose({
          mismatch == 'title' ? 'title' : 'description': masked,
        });
        expect(proposal, isNull);
        expect(h.outcomes.single.reasonCode, switch (mismatch) {
          'incomplete' => text.AiTextBlockCode.redactionMarker,
          _ => text.AiTextBlockCode.rereadField,
        });
        expect(h.fixture.server.successfulReads, 4);
        expect(h.fixture.server.mutations, 0);
        expect(h.storage.journal.entries(mr6b3Account), isEmpty);
      },
    );
  }

  test('group attachment placeholder is refused at bypass', () async {
    final h = await _Harness.create(level: AiAutonomyLevel.bypass);
    addTearDown(h.close);
    expect(
      await h.propose({'description': '![file]([[attachment:att-1]])'}),
      isNull,
    );
    expect(h.outcomes.single.reasonCode, text.AiTextBlockCode.attachmentScope);
    expect(h.fixture.server.mutations, 0);
  });

  test(
    'dispatch opening detects hidden spans introduced after proposal',
    () async {
      final h = await _Harness.create(level: AiAutonomyLevel.bypass);
      addTearDown(h.close);
      final proposal = (await h.propose({'description': 'Changed @all'}))!;
      expect(
        proposal.tier.reasons,
        isNot(contains(AiFixedConfirmReason.wholeFieldDropsHiddenSpans)),
      );
      h.fixture.server.description =
          'Original ![remote](https://outside.example/a.png)';
      final result = await h.approve(proposal);
      expect(result.state, AiJournalState.notExecuted);
      expect(h.fixture.server.contentReads, 2);
      expect(h.fixture.server.mutations, 0);
    },
  );

  test(
    'OAuth replay on bound actor revokes opening instead of weakening epoch',
    () async {
      final h = await _Harness.create(oauth: true);
      addTearDown(h.close);
      expect(await h.propose({'description': 'changed'}), isNull);
      expect(h.outcomes.single.reasonCode, 'workItemUnverifiable');
      expect(h.fixture.server.successfulReads, 2);
      expect(h.fixture.server.adapter.requests.length, 4);
      expect(h.fixture.server.refreshes, 2);
      expect(h.fixture.server.mutations, 0);
    },
  );

  test(
    'OAuth refresh between prepare rounds invalidates saved opening',
    () async {
      final h = await _Harness.create(oauth: true);
      addTearDown(h.close);
      h.fixture.server.challengeBoundReads = false;
      final proposal = (await h.propose({'description': 'changed'}))!;
      h.fixture.server.challengeBoundReads = true;
      final result = await h.approve(proposal);
      expect(result.state, AiJournalState.notExecuted);
      expect(result.reasonCode, 'workItemUnverifiable');
      expect(h.fixture.server.contentReads, 1);
      expect(h.fixture.server.mutations, 0);
    },
  );
}

final class _Fixture {
  _Fixture({bool oauth = false, bool withContext = true})
    : server = _Server(oauth: oauth) {
    writePort = port.GitLabAiWritePort(
      server.api,
      accountKey: mr6b3Account,
      sessionGeneration: withContext ? 7 : null,
      isCurrent: withContext ? () => live && currentGeneration == 7 : null,
    );
  }
  final _Server server;
  late final port.GitLabAiWritePort writePort;
  bool live = true;
  int currentGeneration = 7;
  AiWriteScope scope = _scope;
  int hooks = 0;
  int starts = 0;
  Future<port.AiWritePrepared> prepare(Map<String, Object?> args) =>
      writePort.prepare(
        port.AiWriteRequest(
          operationId: _operation,
          executionId: 'content-test',
          scope: scope,
          arguments: {'groupId': 7, 'iid': 31, ...args},
        ),
      );
  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    Future<void> Function()? before,
    bool Function()? mayStart,
  }) {
    prepared.bindGraphBeforeMutation(() async {
      hooks++;
      await before?.call();
    });
    return writePort.commit(
      prepared,
      mayStart: () {
        starts++;
        return mayStart?.call() ?? true;
      },
    );
  }

  void close() => server.api.close();
}

final class _Server {
  _Server({required this.oauth}) {
    adapter = FakeAdapter(_respond);
    final instance = GitLabInstance.parse('https://example.com/gitlab');
    final refreshAdapter = FakeAdapter((_) {
      refreshes++;
      return jsonResponse({
        'access_token': 'synthetic-$refreshes',
        'refresh_token': 'synthetic-refresh-$refreshes',
        'expires_in': 3600,
      });
    });
    api = GitLabApi(
      instance: instance,
      dio: Dio()..httpClientAdapter = adapter,
      cdnAdapter: adapter,
      credential: oauth
          ? const OAuthCredential(
              accessToken: 'synthetic-access',
              refreshToken: 'synthetic-refresh',
              clientId: 'synthetic-client',
            )
          : const PatCredential('synthetic-pat'),
      oauth: oauth
          ? OAuthTokenClient(
              instance: instance,
              clientId: 'synthetic-client',
              dio: Dio()..httpClientAdapter = refreshAdapter,
            )
          : null,
    );
  }
  static final opened = DateTime.utc(2026, 10, 26);
  static final saved = DateTime.utc(2026, 10, 27);
  final bool oauth;
  late final FakeAdapter adapter;
  late final GitLabApi api;
  String title = 'Original title';
  String description = 'Original description';
  DateTime updatedAt = opened;
  bool permission = true;
  bool widget = true;
  int actor = 7;
  int group = 7;
  bool rejectMutation = false;
  bool failReadback = false;
  int mutations = 0;
  int successfulReads = 0;
  int refreshes = 0;
  int readAttempts = 0;
  final readStages = <String, int>{};
  int contentReads = 0;
  bool challengeBoundReads = true;
  int restActor = 7;
  void Function(int read)? onRead;
  void Function(String phase, Map<String, Object?> node)? tamper;
  Map<String, Object?> servedNode(String phase, {bool permissions = true}) {
    final result = node(permissions: permissions);
    tamper?.call(phase, result);
    return result;
  }

  Map<String, Object?>? input;
  // WorkItemUpdateInput fields from the schema reviewed in r1/opus.md (C1).
  static const _workItemUpdateFields = {
    'agentPlanWidget',
    'assigneesWidget',
    'awardEmojiWidget',
    'clientMutationId',
    'colorWidget',
    'confidential',
    'crmContactsWidget',
    'currentUserTodosWidget',
    'customFieldsWidget',
    'descriptionWidget',
    'healthStatusWidget',
    'hierarchyWidget',
    'id',
    'iterationWidget',
    'labelsWidget',
    'milestoneWidget',
    'moveAfterId',
    'moveBeforeId',
    'notesWidget',
    'notificationsWidget',
    'progressWidget',
    'severityWidget',
    'startAndDueDateWidget',
    'stateEvent',
    'statusWidget',
    'timeTrackingWidget',
    'title',
    'verificationStatusWidget',
    'weightWidget',
  };
  void Function()? onMutation;
  Map<String, Object?> node({bool permissions = true}) => {
    'id': 'gid://gitlab/WorkItem/91',
    'iid': '31',
    'title': title,
    'state': 'OPEN',
    'createdAt': '2026-10-01T00:00:00.000Z',
    'updatedAt': updatedAt.toIso8601String(),
    'project': null,
    'namespace': {'id': 'gid://gitlab/Group/$group', 'fullPath': _path},
    'workItemType': {'id': 'gid://gitlab/WorkItems::Type/9', 'name': 'Task'},
    if (permissions) 'userPermissions': {'updateWorkItem': permission},
    'widgets': [
      if (widget)
        {
          'type': 'DESCRIPTION',
          'description': description,
          'edited': false,
          'lastEditedAt': null,
        },
    ],
  };
  ResponseBody _respond(RequestOptions request) {
    expect(request.uri.host, 'example.com');
    expect(request.followRedirects, isFalse);
    final data = request.data;
    final query = data is Map ? data['query'] as String? : null;
    final mutation = query?.startsWith('mutation ') ?? false;
    if (!mutation) {
      readAttempts++;
      final challenge =
          challengeBoundReads ||
          (successfulReads == 0 && request.uri.path.endsWith('/groups/7')) ||
          mutations > 0;
      if (oauth && challenge && readAttempts.isOdd) {
        return jsonResponse({}, status: 401);
      }
      successfulReads++;
      final stage = query == null
          ? request.uri.path.endsWith('/user')
                ? 'actor'
                : 'freshness'
          : query.startsWith('query MobileNamespaceWorkItem(')
          ? 'namespace'
          : 'content';
      readStages.update(stage, (count) => count + 1, ifAbsent: () => 1);
      onRead?.call(successfulReads);
    }
    if (query == null) {
      if (request.uri.path.endsWith('/user')) {
        return jsonResponse({
          'id': restActor,
          'username': 'ada',
          'name': 'Ada',
        });
      }
      expect(request.uri.path, '/gitlab/api/v4/groups/7');
      expect(request.uri.queryParameters, {'with_projects': 'false'});
      return jsonResponse({
        'id': 7,
        'full_path': _path,
        'visibility': 'private',
      });
    }
    if (query.startsWith('query MobileNamespaceWorkItem(')) {
      expect(query, namespaceWorkItemQuery);
      expect((data as Map)['variables'], {'path': _path, 'iid': '31'});
      return jsonResponse({
        'data': {
          'namespace': {
            'id': 'gid://gitlab/Group/$group',
            'fullPath': _path,
            'workItem': servedNode('namespace'),
          },
        },
      });
    }
    if (query.startsWith('query MobileWorkItemContent(')) {
      contentReads++;
      if (mutations > 0 && failReadback) return jsonResponse({}, status: 500);
      return jsonResponse({
        'data': {
          'currentUser': {'id': 'gid://gitlab/User/$actor'},
          'workItem': servedNode('content$contentReads'),
        },
      });
    }
    expect(query, startsWith('mutation MobileUpdateWorkItemContent('));
    onMutation?.call();
    mutations++;
    input = Map<String, Object?>.from(
      (data as Map)['variables']['input'] as Map,
    );
    final unknown = input!.keys.where(
      (key) => !_workItemUpdateFields.contains(key),
    );
    if (unknown.isNotEmpty) {
      return jsonResponse({
        'errors': [
          for (final key in unknown)
            {
              'message': 'Field $key is not defined by WorkItemUpdateInput',
              'extensions': {'code': 'undefinedInputField'},
            },
        ],
      });
    }
    if (rejectMutation) {
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': ['synthetic refusal'],
            'workItem': null,
          },
        },
      });
    }
    if (input!.containsKey('title')) title = input!['title']! as String;
    if (input!.containsKey('descriptionWidget')) {
      description =
          (input!['descriptionWidget'] as Map)['description'] as String;
    }
    updatedAt = saved;
    return jsonResponse({
      'data': {
        'workItemUpdate': {
          'errors': <Object?>[],
          'workItem': servedNode('ack', permissions: false),
        },
      },
    });
  }
}

final class _Harness {
  _Harness(
    this.storage,
    this.fixture, {
    this.level = AiAutonomyLevel.confirmEach,
    this.aiAttribution = false,
  }) {
    placeholders = text.UploadPlaceholderTable(
      instance: fixture.server.api.instance,
      accountKey: mr6b3Account,
      conversationId: mr6b3Conversation,
    );
    coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        appInForeground: true,
        scope: _scope,
        level: level,
        aiAttribution: aiAttribution,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'synthetic-content-consent',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
        ownerApi: fixture.server.api,
        currentResource: AiTargetRef(
          kind: AiTargetKind.groupWorkItem,
          groupId: 7,
          groupFullPath: _path,
          iid: 31,
          workItemGid: 'gid://gitlab/WorkItem/91',
        ),
        alive: true,
        consentValid: true,
      ),
      createPort: () => fixture.writePort,
      journal: storage.journal,
      conversationId: mr6b3Conversation,
      budget: () => budget,
      readFreshness: (_) async {
        await fixture.server.api.group(7);
        return const AiWriteFreshness(visibilityUnreadable: false);
      },
      placeholders: placeholders,
      ledger: const _TestLedger(),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      httpCost: (op) =>
          aiWriteRequestAllowance(op, oauthReplay: fixture.server.oauth),
      now: () => storage.clock,
      onOutcome: (_, result) => outcomes.add(result),
    );
    coordinator.beginRun('Update #31 in $_path.');
    coordinator.beginTurn();
  }
  static Future<_Harness> create({
    bool oauth = false,
    AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
    bool aiAttribution = false,
  }) async => _Harness(
    await Mr6b3Harness.create(),
    _Fixture(oauth: oauth),
    level: level,
    aiAttribution: aiAttribution,
  );
  final Mr6b3Harness storage;
  final _Fixture fixture;
  final AiAutonomyLevel level;
  final bool aiAttribution;
  final outcomes = <AiWriteOutcome>[];
  late final text.UploadPlaceholderTable placeholders;
  late final PolicyAiWriteCoordinator coordinator;
  var budget = AiToolBudget(maxGitLabRequests: 100);
  Future<AiWriteProposal?> propose(Map<String, Object?> args) =>
      coordinator.propose(
        AiToolCall(
          id: 'content-call',
          name: _operation,
          arguments: {
            'groupId': 7,
            'iid': 31,
            ...args,
            'reason': 'Synthetic content update',
          },
        ),
      );
  Future<AiWriteOutcome> approve(AiWriteProposal proposal) =>
      coordinator.approve(proposal, typedName: proposal.tier.typedName);
  Future<void> close() async {
    coordinator.stop();
    fixture.close();
    await storage.dispose();
  }
}

// Exercise the real row/port behind a local test-only visible catalogue.
final class _TestLedger implements AiCapabilityLedger {
  const _TestLedger();
  @override
  AiCapability? find(String operationId) {
    final row = productionAiLedger.find(operationId);
    if (row == null || operationId != _operation) return row;
    return AiCapability(
      operationId: row.operationId,
      namedMethod: row.namedMethod,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      boundary: row.boundary,
      arguments: row.arguments,
      httpCap: row.httpCap,
      readback: row.readback,
      editableField: row.editableField,
    );
  }

  @override
  List<AiCapability> get modelVisible => [find(_operation)!];
}
