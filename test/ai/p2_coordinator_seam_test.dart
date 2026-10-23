import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'fx_coord_support.dart';

const _timeout = Duration(seconds: 20);

void main() {
  test('issue13 journal solely owns the process schedule HMAC key', () {
    final source = File('lib/core/ai/tools/write_coordinator.dart').readAsStringSync();
    expect(source, isNot(contains('extension AiWriteJournalScheduleKey')));
    expect(source, isNot(contains('_scheduleKeys')));
    expect(source, isNot(contains('_newScheduleKey')));
  });

  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() async => f.dispose());

  test('ledger required fields and new exhaustive scope cases', () async {
    const globalScope = AiWriteScope(
      accountKey: coordAccount,
      grants: [AiScopeGrant(kind: AiScopeKind.accountGlobal)],
    );
    f.configure(
      row: const AiCapability(
        operationId: 'markAllTodosDone',
        baseTier: AiWriteTier.t4,
        scopeClass: AiScopeClass.accountGlobalOnly,
      ),
      scope: globalScope,
      captureOnly: true,
    );
    expect(f.coordinator.specs.single.parameters['required'], ['reason']);
    await f.propose('markAllTodosDone', {});
    expect(f.captured.single.operationId, 'markAllTodosDone');

    f.configure(
      row: const AiCapability(
        operationId: 'createProject',
        baseTier: AiWriteTier.hardLine,
        scopeClass: AiScopeClass.personalNamespace,
        arguments: {
          'name': AiArgSpec(AiArgType.string, required: true),
          'path': AiArgSpec(
            AiArgType.string,
            required: true,
            text: AiTextRole.pathOrRef,
          ),
        },
      ),
      captureOnly: true,
    );
    expect(f.coordinator.specs.single.parameters['required'], [
      'name',
      'path',
      'reason',
    ]);
    await f.propose('createProject', {'name': 'sample', 'path': 'sample'});
    expect(f.captured.single.arguments, {'name': 'sample', 'path': 'sample'});
  });

  test('injected ledger offering still obeys scope', () {
    f.configure(row: _row(scope: AiScopeClass.accountGlobalOnly));
    expect(f.coordinator.specs, isEmpty);
    f.configure(row: _row(scope: AiScopeClass.personalNamespace));
    expect(f.coordinator.specs, hasLength(1));
    f.configure(
      row: _row(scope: AiScopeClass.personalNamespace),
      scope: const AiWriteScope(
        accountKey: coordAccount,
        grants: [
          AiScopeGrant(kind: AiScopeKind.workItem, projectId: 9, iid: 3),
        ],
      ),
    );
    expect(f.coordinator.specs, isEmpty);
  });

  test('nested schemas are complete and closed at every item', () {
    f.configure(row: _row(arguments: _nestedArguments));
    final schema = f.coordinator.specs.single.parameters;
    final properties = schema['properties']! as Map;
    expect(schema['additionalProperties'], isFalse);
    expect(schema['required'], ['projectId', 'edits', 'reason']);
    for (final name in [
      'edits',
      'variables',
      'suggestionList',
      'snippetActions',
    ]) {
      final array = properties[name] as Map;
      expect(array['type'], 'array');
      expect(array['maxItems'], 20);
      final item = array['items'] as Map;
      expect(item['type'], 'object');
      expect(item['additionalProperties'], isFalse);
      expect(item['properties'], isNotEmpty);
      expect(item['required'], isNotEmpty);
    }
    final edits = (properties['edits'] as Map)['items'] as Map;
    expect(edits['required'], ['old', 'new']);
    final actions = (properties['snippetActions'] as Map)['items'] as Map;
    final actionEdits = (actions['properties'] as Map)['edits'] as Map;
    expect((actionEdits['items'] as Map)['additionalProperties'], isFalse);
  });

  for (final invalid in <Map<String, Object?>>[
    {'projectId': 9},
    {
      'projectId': 9,
      'edits': [
        {'old': 'a', 'new': 'b', 'extra': true},
      ],
    },
    {
      'projectId': 9,
      'edits': [
        {'old': 'a', 'new': 7},
      ],
    },
    {
      'projectId': 9,
      'edits': [
        {'new': 'b'},
      ],
    },
    {
      'projectId': 9,
      'edits': List.generate(21, (_) => {'old': 'a', 'new': 'b'}),
    },
  ]) {
    test(
      'ledger rejects malformed nested arguments ${jsonEncode(invalid)}',
      () async {
        f.configure(row: _row(arguments: _nestedArguments));
        expect(await f.propose('setStar', invalid), isNull);
        expect(
          f.coordinator.outcomeFor('call')?.reasonCode,
          'invalidArguments',
        );
        expect(f.freshnessReads, 0);
        expect(f.captured, isEmpty);
        expect(f.h.adapter.requests, isEmpty);
      },
    );
  }

  test(
    'port-only metadata is absent from schema and refused from model',
    () async {
      f.configure(row: productionAiLedger.find('upload_attachment')!);
      final properties =
          f.coordinator.specs.single.parameters['properties']! as Map;
      expect(properties, contains('attachmentId'));
      expect(properties, isNot(contains('filename')));
      expect(properties, isNot(contains('contentType')));
      await f.propose('upload_attachment', {
        'projectId': 9,
        'filename': 'shot.png',
        'attachmentId': 'att-1',
      });
      expect(f.coordinator.outcomeFor('call')?.reasonCode, 'invalidArguments');
      expect(f.freshnessReads, 0);
    },
  );

  test('model-only arguments stop at the coordinator boundary', () async {
    f.configure(
      row: _row(
        arguments: {
          ...productionAiLedger.find('setStar')!.arguments,
          'modelHint': const AiArgSpec(AiArgType.string, portVisible: false),
        },
      ),
      captureOnly: true,
    );
    await f.propose('setStar', {
      'projectId': 9,
      'starred': true,
      'modelHint': 'hint',
    });
    expect(f.captured.single.arguments, {'projectId': 9, 'starred': true});
  });

  for (final cap in [39, 40, 41]) {
    test('ledger HTTP cap $cap is reserved before reads', () async {
      f.configure(row: _row(httpCap: cap));
      final proposal = await f.propose('setStar', {
        'projectId': 9,
        'starred': true,
      });
      if (cap <= 40) {
        expect(proposal, isNotNull);
        expect(f.h.budget.gitLabRequests, cap);
      } else {
        expect(proposal, isNull);
        expect(
          f.coordinator.outcomeFor('call')?.reasonCode,
          'httpBudgetExceeded',
        );
        expect(f.freshnessReads, 0);
        expect(f.captured, isEmpty);
      }
    });
  }

  test('40 cap refuses a send with only 39 requests left', () async {
    f.configure(row: _row(httpCap: 40));
    expect(f.h.budget.reserve(requests: 1, search: false), isNull);
    expect(
      await f.propose('setStar', {'projectId': 9, 'starred': true}),
      isNull,
    );
    expect(f.coordinator.outcomeFor('call')?.reasonCode, 'httpBudgetExceeded');
    expect(f.freshnessReads, 0);
    expect(f.h.budget.gitLabRequests, 1);
  });

  test(
    'rendered B preserves slash and mentions but requires confirmation',
    () async {
      f.configure(row: _issueRow(AiTextRole.renderedMarkdown));
      final proposal = (await f.propose('createIssue', {
        'projectId': 9,
        'title': 'Release',
        'description': '/close\n@all\n![art](https://media.invalid/a.png)',
      }))!;
      expect(
        (f.captured.single.arguments['fields'] as Map)['description'],
        '/close\n@all\n![art](https://media.invalid/a.png)',
      );
      expect(
        proposal.tier.reasons,
        containsAll([
          AiFixedConfirmReason.massMention,
          AiFixedConfirmReason.externalMediaInRenderedMarkdown,
        ]),
      );
      expect(
        ((proposal.preview as port.AiFieldsPreview).fields['fields']
            as Map)['description'],
        startsWith('/close'),
      );
      expect(proposal.fields['description'], startsWith('/close'));
    },
  );

  test('quick-action A still neutralizes slash', () async {
    f.configure(row: _issueRow(AiTextRole.quickActionMarkdown));
    final proposal = await f.propose('createIssue', {
      'projectId': 9,
      'title': 'Issue',
      'description': '/close',
    });
    expect(proposal, isNotNull);
    expect(
      (f.captured.single.arguments['fields'] as Map)['description'],
      isNot(startsWith('/')),
    );
  });

  test('commit message B keeps text and reports closing references', () async {
    f.configure(row: _issueRow(AiTextRole.commitMessage));
    final proposal = (await f.propose('createIssue', {
      'projectId': 9,
      'title': 'Commit',
      'description': '/keep\nCloses #3 and other/project#8',
    }))!;
    expect(
      (f.captured.single.arguments['fields'] as Map)['description'],
      '/keep\nCloses #3 and other/project#8',
    );
    expect(
      proposal.tier.reasons,
      contains(AiFixedConfirmReason.foreignClosingOrCrossProject),
    );
    expect(proposal.closingRefs, isNotEmpty);
  });

  test('pathOrRef has no Markdown effects but still blocks secrets', () async {
    f.configure(row: _issueRow(AiTextRole.pathOrRef));
    final proposal = (await f.propose('createIssue', {
      'projectId': 9,
      'title': 'Path',
      'description': '/@all',
    }))!;
    expect(
      (f.captured.single.arguments['fields'] as Map)['description'],
      '/@all',
    );
    expect(
      proposal.tier.reasons,
      isNot(contains(AiFixedConfirmReason.massMention)),
    );
    await f.coordinator.reject(proposal);
    f.configure(row: _issueRow(AiTextRole.pathOrRef));
    f.secrets = {'synthetic-private-value'};
    expect(
      await f.propose('createIssue', {
        'projectId': 9,
        'title': 'Path',
        'description': 'dir/synthetic-private-value.txt',
      }),
      isNull,
    );
    expect(f.captured, isEmpty);
  });

  test(
    'nested new content scans full text without modifying fragments',
    () async {
      f.configure(row: _row(arguments: _nestedArguments), captureOnly: true);
      await f.propose('setStar', {
        'projectId': 9,
        'edits': [
          {'old': '[REDACTED secret]', 'new': '/keep'},
        ],
        'snippetActions': [
          {
            'action': 'create',
            'file_path': 'README.md',
            'content': '/keep\n@all',
          },
        ],
      });
      expect(f.captured.single.arguments['edits'], [
        {'old': '[REDACTED secret]', 'new': '/keep'},
      ]);
      expect(
        (f.captured.single.arguments['snippetActions'] as List)
            .single['content'],
        '/keep\n@all',
      );
      f.configure(row: _row(arguments: _nestedArguments), captureOnly: true);
      await f.propose('setStar', {
        'projectId': 9,
        'edits': [],
        'snippetActions': [
          {
            'action': 'create',
            'file_path': 'a.txt',
            'content': '${'a' * 20000}\n[REDACTED secret]',
          },
        ],
      });
      expect(
        f.captured,
        isEmpty,
        reason: 'scan the entire content, including its tail',
      );
    },
  );

  test('fragment role without a prepared scan fails closed', () async {
    f.configure(row: _issueRow(AiTextRole.fragmentEdits));
    expect(
      await f.propose('createIssue', {
        'projectId': 9,
        'title': 'Fragment',
        'description': '/unchanged',
      }),
      isNull,
    );
    expect(
      f.coordinator.outcomeFor('call')?.reasonCode,
      'fragmentCheckUnavailable',
    );
    expect(f.h.mutations, 0);
  });

  test(
    'absent optional fragment field does not block unrelated content',
    () async {
      final args = _issueRow(AiTextRole.fragmentEdits).arguments;
      f.configure(
        row: _row(operation: 'createIssue', arguments: args),
      );
      expect(
        await f.propose('createIssue', {'projectId': 9, 'title': 'No edits'}),
        isNotNull,
      );
    },
  );

  test(
    'editableField chooses title and refreshes structured preview',
    () async {
      f.configure(
        row: _issueRow(AiTextRole.renderedMarkdown, editable: 'title'),
      );
      final proposal = (await f.propose('createIssue', {
        'projectId': 9,
        'title': 'Before',
        'description': '/original',
      }))!;
      final before = proposal.payloadDigest;
      final outcome = await f.coordinator.approve(
        proposal,
        editedText: '/After',
      );
      expect(outcome.reasonCode, 'approvalRequired');
      expect(proposal.fields['title'], '/After');
      expect(proposal.fields['description'], '/original');
      expect(
        ((proposal.preview as port.AiFieldsPreview).fields['fields']
            as Map)['title'],
        '/After',
      );
      expect(proposal.payloadDigest, isNot(before));
      expect(f.h.mutations, 0);
      expect(f.h.journal.entries(coordAccount), isEmpty);
    },
  );

  test('editing a commit message refreshes closing references', () async {
    f.configure(
      row: _issueRow(AiTextRole.commitMessage, editable: 'description'),
    );
    final proposal = (await f.propose('createIssue', {
      'projectId': 9,
      'title': 'Commit',
      'description': 'Closes #1',
    }))!;
    expect(proposal.closingRefs, ['team/example-9#1']);
    final outcome = await f.coordinator.approve(
      proposal,
      editedText: 'Closes #2',
    );
    expect(outcome.reasonCode, 'approvalRequired');
    expect(proposal.closingRefs, ['team/example-9#2']);
    expect(f.h.mutations, 0);
  });

  test('null editableField refuses replacement', () async {
    f.configure(row: _issueRow(AiTextRole.renderedMarkdown));
    final proposal = (await f.propose('createIssue', {
      'projectId': 9,
      'title': 'Before',
      'description': 'Original',
    }))!;
    final outcome = await f.coordinator.approve(proposal, editedText: 'After');
    expect(outcome.reasonCode, 'noEditableText');
    expect(proposal.fields['description'], 'Original');
    expect(f.h.mutations, 0);
  });

  test('ledger controls fields but cannot claim an unperformed readback', () async {
    f.configure(
      row: _row(
        readback: true,
        arguments: {
          ...productionAiLedger.find('setStar')!.arguments,
          'starred': const AiArgSpec(AiArgType.boolean, modelVisible: false),
        },
      ),
    );
    // A ledger with no starred field cannot admit one just because it is a
    // baseline operation. Runtime validation uses the injected row too.
    expect(
      await f.propose('setStar', {'projectId': 9, 'starred': true}),
      isNull,
    );
    expect(f.coordinator.outcomeFor('call')?.reasonCode, 'invalidArguments');
    f.configure(row: _row(readback: true));
    final proposal = (await f.propose('setStar', {
      'projectId': 9,
      'starred': true,
    }))!;
    expect(proposal.fields, {'starred': 'true'});
    final outcome = await f.coordinator.approve(proposal);
    expect(outcome.state, AiJournalState.succeeded);
    expect(outcome.readbackConfirmed, isFalse);
  });

  test(
    'journal HMAC stays immutable and stable across edits and coordinators',
    () async {
      f.configure(
        row: _issueRow(AiTextRole.renderedMarkdown, editable: 'title'),
      );
      final proposal = (await f.propose('createIssue', {
        'projectId': 9,
        'title': 'Before',
      }))!;
      final key = f.captured.single.scheduleHmacKey!;
      expect(key, hasLength(32));
      expect(() => key[0] = 0, throwsUnsupportedError);
      expect(
        () => f.captured.single.segmentCreated.add(
          const port.AiCreatedRef(
            accountKey: coordAccount,
            kind: AiTargetKind.pipeline,
            id: 1,
          ),
        ),
        throwsUnsupportedError,
      );
      await f.coordinator.approve(proposal, editedText: 'After');
      await f.coordinator.approve(proposal);
      expect(f.captured.last.scheduleHmacKey, key);
      expect((f.captured.last.arguments['fields'] as Map)['title'], 'After');
      expect(
        jsonEncode((proposal.preview as port.AiFieldsPreview).fields),
        isNot(contains('scheduleHmacKey')),
      );
      expect(proposal.previewText, isNot(contains('scheduleHmacKey')));
      final source = File(
        'lib/core/ai/tools/write_coordinator.dart',
      ).readAsStringSync();
      final draft = source
          .split('draft: AiJournalDraft(')
          .last
          .split('preparedOnDisk = true;')
          .first;
      expect(draft, isNot(contains('scheduleHmacKey')));
      f.configure();
      await f.propose('setStar', {'projectId': 9, 'starred': true});
      expect(f.captured.single.scheduleHmacKey, key);
    },
  );

  for (final status in [400, 500]) {
    test('T3 failure $status fail-stops later writes', () async {
      f.configure();
      f.h.failWritesWith = status;
      final proposal = (await f.propose('setStar', {
        'projectId': 9,
        'starred': true,
      }))!;
      final outcome = await f.coordinator.approve(proposal);
      expect(
        outcome.state,
        status == 400
            ? AiJournalState.failedCertain
            : AiJournalState.writeUncertain,
      );
      expect(outcome.mutationCount, 1);
      final count = f.captured.length;
      await f.propose('setStar', {
        'projectId': 9,
        'starred': false,
      }, id: 'later');
      expect(
        f.coordinator.outcomeFor('later')?.reasonCode,
        'previousWriteIncomplete',
      );
      expect(f.captured, hasLength(count));
    });
  }

  test('T3 rejection fail-stops but noChange permits next write', () async {
    f.configure();
    final proposal = (await f.propose('setStar', {
      'projectId': 9,
      'starred': true,
    }))!;
    await f.coordinator.reject(proposal);
    await f.propose('setStar', {
      'projectId': 9,
      'starred': true,
    }, id: 'rejected-later');
    expect(
      f.coordinator.outcomeFor('rejected-later')?.reasonCode,
      'previousWriteIncomplete',
    );
    f.configure();
    f.fresh = const AiWriteFreshness(
      noChange: true,
      visibilityUnreadable: false,
    );
    final noChange = (await f.propose('setStar', {
      'projectId': 9,
      'starred': true,
    }))!;
    expect((await f.coordinator.approve(noChange)).noChange, isTrue);
    expect(
      await f.propose('setStar', {
        'projectId': 9,
        'starred': false,
      }, id: 'next'),
      isNotNull,
    );
    expect(f.h.mutations, 0);
  });

  test(
    'T3 post-flush policy change is checked synchronously before mutation',
    () async {
      f.configure();
      final proposal = (await f.propose('setStar', {
        'projectId': 9,
        'starred': true,
      }))!;
      // The real port invokes mayStart immediately before its named mutation.
      f.beforeCommit = () {
        expect(
          f.h.journal.entries(coordAccount).single.state,
          AiJournalState.dispatching,
        );
        f.foreground = false;
      };
      final outcome = await f.coordinator.approve(proposal).timeout(_timeout);
      expect(outcome.mutationCount, 0);
      expect(outcome.reasonCode, 'backgrounded');
      expect(f.h.mutations, 0);
      expect(
        f.h.journal.entries(coordAccount).single.state,
        AiJournalState.notExecuted,
      );
    },
  );

  test('current job snapshot change invalidates a waiting approval', () async {
    f.configure();
    f.currentJobId = 12;
    final proposal = (await f.propose('setStar', {
      'projectId': 9,
      'starred': true,
    }))!;
    f.currentJobId = 13;
    final outcome = await f.coordinator.approve(proposal);
    expect(outcome.reasonCode, 'settingsChanged');
    expect(f.h.mutations, 0);
  });

  test(
    'reserved prepared metadata wiring (source guard, not family runtime proof)',
    () {
      final source = File(
        'lib/core/ai/tools/write_coordinator.dart',
      ).readAsStringSync();
      for (final contract in [
        'typedName: prepared?.confirmName',
        'prepared!.bindingTargets : [target]',
        'prepared.bindingDigest != pending.prepared.bindingDigest',
        'prepared.confirmName != pending.prepared.confirmName',
        '...preparedFacts.reasons',
        'pending.prepared.journal.mergeCheckSummary',
        '_segmentCreated.add(created)',
        'created.accountKey == pending.policy.scope.accountKey',
        'AiTargetOrigin.createdInSegment',
        'target.jobId == policy.currentJobId',
        'target.jobBelongsToBoundPipeline &&',
        'target.pipelineCreatedInSegment || createdPipeline',
        'final checked = checker(scan,',
        'checked.finalText != body',
      ]) {
        expect(source, contains(contract), reason: contract);
      }
      final controller = File(
        'lib/features/ai/ai_chat_controller.dart',
      ).readAsStringSync();
      expect(controller, contains('AiJobOrigin(:final jobId) => jobId'));
      expect(
        controller,
        contains('final resource = !legacy ? null : switch (operation)'),
      );
      expect(controller, contains('updatedAt: legacy &&'));
      expect(
        controller,
        contains("lastCommitId: legacy && target['last_commit_id'] is String"),
      );
    },
  );
}

AiCapability _row({
  String operation = 'setStar',
  AiScopeClass scope = AiScopeClass.project,
  Map<String, AiArgSpec>? arguments,
  int httpCap = 13,
  bool readback = false,
  String? editable,
}) => AiCapability(
  operationId: operation,
  baseTier: AiWriteTier.t3,
  scopeClass: scope,
  arguments: arguments ?? productionAiLedger.find(operation)!.arguments,
  httpCap: httpCap,
  readback: readback,
  editableField: editable,
);

AiCapability _issueRow(AiTextRole role, {String? editable}) => _row(
  operation: 'createIssue',
  arguments: {
    ...productionAiLedger.find('createIssue')!.arguments,
    'fields': AiArgSpec(
      AiArgType.object,
      required: true,
      properties: {
        ...productionAiLedger
            .find('createIssue')!
            .arguments['fields']!
            .properties,
        'description': AiArgSpec(AiArgType.string, text: role),
      },
    ),
  },
  editable: editable,
);

const _nestedArguments = {
  'projectId': AiArgSpec(AiArgType.integer, required: true),
  'edits': AiArgSpec(
    AiArgType.edits,
    required: true,
    text: AiTextRole.fragmentEdits,
  ),
  'variables': AiArgSpec(AiArgType.variables),
  'suggestionList': AiArgSpec(AiArgType.suggestionList),
  'snippetActions': AiArgSpec(AiArgType.snippetActions),
};

final class _Ledger implements AiCapabilityLedger {
  const _Ledger(this.row);
  final AiCapability row;
  @override
  AiCapability? find(String operationId) =>
      operationId == row.operationId ? row : null;
  @override
  List<AiCapability> get modelVisible => [row];
}

final class _Fixture implements port.AiGitLabWritePort {
  _Fixture(this.h);
  static Future<_Fixture> create() async =>
      _Fixture(await CoordHarness.create());
  final CoordHarness h;
  late PolicyAiWriteCoordinator coordinator;
  late port.GitLabAiWritePort delegate;
  final captured = <port.AiWriteRequest>[];
  final prepared = <port.AiWritePrepared>[];
  int freshnessReads = 0;
  bool captureOnly = false;
  bool foreground = true;
  int? currentJobId;
  Set<String> secrets = {};
  void Function()? beforeCommit;
  AiWriteFreshness fresh = const AiWriteFreshness(visibilityUnreadable: false);

  void configure({
    AiCapability? row,
    AiWriteScope scope = coordScope,
    bool captureOnly = false,
  }) {
    if (captured.isNotEmpty || prepared.isNotEmpty) {
      coordinator.stop('superseded');
    }
    captured.clear();
    prepared.clear();
    freshnessReads = 0;
    h.budget = AiToolBudget(maxGitLabRequests: 40);
    this.captureOnly = captureOnly;
    delegate = port.GitLabAiWritePort(h.api, accountKey: coordAccount);
    coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: scope,
        level: AiAutonomyLevel.confirmEach,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'synthetic-consent',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
        appInForeground: foreground,
        currentJobId: currentJobId,
      ),
      createPort: () => this,
      journal: h.journal,
      conversationId: 'p2-conversation',
      budget: () => h.budget,
      readFreshness: (_) async {
        freshnessReads++;
        return fresh;
      },
      placeholders: text.UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => secrets,
      safeDisplay: (value) => value,
      ledger: _Ledger(row ?? _row()),
    );
    coordinator.beginRun('Apply the requested change in team/example-9');
    coordinator.beginTurn();
  }

  Future<AiWriteProposal?> propose(
    String operation,
    Map<String, Object?> args, {
    String id = 'call',
  }) => coordinator
      .propose(
        AiToolCall(
          id: id,
          name: operation,
          arguments: {
            if (operation == 'createIssue') ...{
              'projectId': args['projectId'],
              'fields': {
                for (final entry in args.entries)
                  if (entry.key != 'projectId') entry.key: entry.value,
              },
            } else
              ...args,
            'reason': 'Synthetic user request',
          },
        ),
      )
      .timeout(_timeout);

  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) async {
    captured.add(request);
    if (captureOnly) {
      throw StateError(
        'Capture boundary; no family implementation in packet 1',
      );
    }
    final value = await delegate.prepare(request);
    prepared.add(value);
    return value;
  }

  @override
  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) {
    beforeCommit?.call();
    return delegate.commit(prepared, mayStart: mayStart);
  }

  Future<void> dispose() async {
    // Await refunds for every outstanding card before removing the test root.
    if (prepared.isNotEmpty) {
      for (final proposal in coordinator.proposals) {
        await coordinator.reject(proposal).timeout(_timeout);
      }
      coordinator.stop('disposed');
    }
    await h.dispose();
  }
}
