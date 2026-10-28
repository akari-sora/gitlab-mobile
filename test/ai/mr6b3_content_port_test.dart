import 'release_policy_support.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
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

const _operation = 'updateWorkItemContent';
const _path = 'studio/mobile-workspace';
const _scope = AiWriteScope(
  accountKey: mr6b3Account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.workItem,
      projectId: 42,
      projectPath: _path,
      iid: 31,
    ),
  ],
);

void main() {
  test('visible T2 row has whole-field text roles and independent cap', () {
    final row = productionAiLedger.find(_operation)!;
    expect(row.modelVisible, isTrue);
    expect(row.baseTier, AiWriteTier.t2);
    expect(row.boundary, AiWriteBoundary.graph);
    expect(
      row.arguments.keys,
      unorderedEquals(['projectId', 'iid', 'title', 'description']),
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
        'id': 'gid://gitlab/WorkItem/31',
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
                'id': 'gid://gitlab/WorkItem/31',
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
        if (scenario == 'scope') f.server.project = 99;
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
      final outcome = await h.coordinator.approve(
        proposal,
        editedText: edited,
      );
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

  test(
    'coordinator title-only preview and mutation omit description',
    () async {
      final h = await _Harness.create();
      addTearDown(h.close);
      final proposal = await h.propose({'title': 'Changed title'});
      expect(proposal, isNotNull);
      expect((proposal!.preview as port.AiFieldsPreview).fields, {
        'title': 'Changed title',
      });
      expect((await h.approve(proposal)).state, AiJournalState.succeeded);
      expect(h.fixture.server.input!.containsKey('descriptionWidget'), isFalse);
      expect(h.fixture.server.description, 'Original description');
    },
  );

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
      'measured coordinator L10 PAT11 OAuth21 request drive ($oauth)',
      () async {
        final h = await _Harness.create(oauth: oauth);
        addTearDown(h.close);
        final proposal = await h.propose({'description': 'changed'});
        expect((await h.approve(proposal!)).state, AiJournalState.succeeded);
        expect(h.fixture.server.successfulReads, 10);
        expect(h.fixture.server.mutations, 1);
        expect(h.fixture.server.refreshes, oauth ? 10 : 0);
        expect(h.fixture.server.adapter.requests.length, oauth ? 21 : 11);
        expect(
          h.fixture.server.adapter.requests.length,
          aiWriteRequestAllowance(_operation, oauthReplay: oauth),
        );
      },
    );
  }
}

final class _Fixture {
  _Fixture({bool oauth = false}) : server = _Server(oauth: oauth) {
    writePort = port.GitLabAiWritePort(server.api, accountKey: mr6b3Account);
  }
  final _Server server;
  late final port.GitLabAiWritePort writePort;
  int hooks = 0;
  int starts = 0;
  Future<port.AiWritePrepared> prepare(Map<String, Object?> args) =>
      writePort.prepare(
        port.AiWriteRequest(
          operationId: _operation,
          executionId: 'content-test',
          scope: _scope,
          arguments: {'projectId': 42, 'iid': 31, ...args},
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
  int project = 42;
  bool rejectMutation = false;
  bool failReadback = false;
  int mutations = 0;
  int successfulReads = 0;
  int refreshes = 0;
  int readAttempts = 0;
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
    'id': 'gid://gitlab/WorkItem/31',
    'iid': '31',
    'title': title,
    'state': 'OPEN',
    'createdAt': '2026-10-01T00:00:00.000Z',
    'updatedAt': updatedAt.toIso8601String(),
    'project': {'id': 'gid://gitlab/Project/$project', 'fullPath': _path},
    'namespace': {
      'id': 'gid://gitlab/Namespaces::ProjectNamespace/42',
      'fullPath': _path,
    },
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
      if (oauth && readAttempts.isOdd) return jsonResponse({}, status: 401);
      successfulReads++;
    }
    if (query == null) {
      if (request.uri.path.endsWith('/user')) {
        return jsonResponse({'id': 7, 'username': 'ada', 'name': 'Ada'});
      }
      expect(request.uri.path, '/gitlab/api/v4/projects/42');
      return jsonResponse({...projectJson(42), 'path_with_namespace': _path});
    }
    if (query.startsWith('query MobileProjectWorkItem(')) {
      return jsonResponse({
        'data': {
          'project': {
            'id': 'gid://gitlab/Project/42',
            'fullPath': _path,
            'workItems': {
              'nodes': [node()],
              'pageInfo': {'hasNextPage': false, 'endCursor': null},
            },
          },
        },
      });
    }
    if (query.startsWith('query MobileWorkItemContent(')) {
      if (mutations > 0 && failReadback) return jsonResponse({}, status: 500);
      return jsonResponse({
        'data': {
          'currentUser': {'id': 'gid://gitlab/User/$actor'},
          'workItem': node(),
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
          'workItem': node(permissions: false),
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
    coordinator = PolicyAiWriteCoordinator(
      releasePolicy: fixtureReleasePolicy,
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
        alive: true,
        consentValid: true,
      ),
      createPort: () => fixture.writePort,
      journal: storage.journal,
      conversationId: mr6b3Conversation,
      budget: () => budget,
      readFreshness: (_) async {
        await fixture.server.api.record(['projects', '42']);
        return const AiWriteFreshness(visibilityUnreadable: false);
      },
      placeholders: text.UploadPlaceholderTable(
        instance: fixture.server.api.instance,
      ),
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
  late final PolicyAiWriteCoordinator coordinator;
  final budget = AiToolBudget(maxGitLabRequests: 100);
  Future<AiWriteProposal?> propose(Map<String, Object?> args) =>
      coordinator.propose(
        AiToolCall(
          id: 'content-call',
          name: _operation,
          arguments: {
            'projectId': 42,
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
