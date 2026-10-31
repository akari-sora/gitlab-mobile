import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart'
    show UploadPlaceholderTable;
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_write_ui.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import '../support/fake_adapter.dart' show jsonResponse;
import '../support/workspace_fixture.dart';
import 'fx_coord_support.dart';
import 'release_policy_support.dart';

// The display-redaction fixtures of p17_preview_test.dart: one known secret
// and one token that only the secret patterns catch.
const _knownSecret = 'opaque-known-secret';
const _secretPattern = 'glpat-ABCDEFGHIJKLMNOPQRST';
const _issueTitle = 'Keep release notes concise';

final class _SecretSource implements KnownSecretsSource {
  const _SecretSource(this.current);

  @override
  final Iterable<String> current;
}

final class _CardSession implements AiWriteChatSession {
  _CardSession(this.proposals);

  @override
  final List<AiWriteProposal> proposals;
  @override
  AiAutonomyLevel autonomyLevel = AiAutonomyLevel.confirmEach;
  @override
  AiAutonomyLevel autonomyCeiling = AiAutonomyLevel.conversationGrant;
  @override
  List<AiStoredAttachment> attachments = const [];
  @override
  bool canAttach = true;

  @override
  Future<void> setAutonomyLevel(AiAutonomyLevel level) async =>
      autonomyLevel = level;

  @override
  Future<AiWriteOutcome> approveWrite(
    AiWriteProposal proposal, {
    String? typedName,
    String? editedText,
  }) async =>
      const AiWriteOutcome(state: AiJournalState.succeeded, reasonCode: 'ok');

  @override
  Future<void> rejectWrite(AiWriteProposal proposal) async {}

  @override
  Future<AiAttachResult> attach(AiAttachmentPick pick) async =>
      const AiAttachResult(status: AiAttachStatus.stored, reasonCode: null);

  @override
  void removeAttachment(String id) {}
}

Widget _cardHost(AiWriteProposal proposal, {String tag = 'zh-TW'}) =>
    MaterialApp(
      theme: appTheme(Brightness.light),
      locale: switch (tag) {
        'ar' => const Locale('ar'),
        _ => const Locale('zh', 'TW'),
      },
      supportedLocales: const [Locale('zh', 'TW'), Locale('ar')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: AiWriteProposalCard(
            proposal: proposal,
            session: _CardSession([proposal]),
          ),
        ),
      ),
    );

AiChatOrigin _issueOrigin([int iid = 7]) => AiWorkItemOrigin(
  project: WorkspaceFixture().project,
  kind: AiWorkItemKind.issue,
  iid: iid,
  title: _issueTitle,
);

/// Merge request !12 of the synthetic server, granted to a chat opened on a
/// file (the synthetic server does not serve a merge request's context).
AiWriteScope _mrScope(StackServer server) => AiWriteScope(
  accountKey: server.workspace.account.key,
  grants: const [
    AiScopeGrant(kind: AiScopeKind.project, projectId: 42),
    AiScopeGrant(kind: AiScopeKind.mergeRequest, projectId: 42, iid: 12),
  ],
);

/// Issue #7 of the synthetic server, as GitLab returns it, with labels.
void _issueRecord(StackServer server, {String title = _issueTitle}) {
  server.workspace.issues[7] = {
    ...server.workspace.issue(7, title),
    'labels': <String>['mobile', 'ux'],
  };
  server.overrides['GET projects/42/issues/7/notes'] = (_) =>
      jsonResponse(<Object?>[]);
}

/// Runs the production controller stack (freshness read, prepare, proposal)
/// up to the confirmation card in real async, then rejects the write and
/// disposes of the stack. The proposal keeps what the card shows.
Future<AiWriteProposal> _propose(
  WidgetTester tester,
  String operation,
  Map<String, Object?> arguments, {
  bool mergeRequest = false,
  void Function(StackServer server)? configure,
}) async {
  AiWriteProposal? proposal;
  await tester.runAsync(() async {
    proposal = await _proposeOnStack(
      operation,
      arguments,
      mergeRequest: mergeRequest,
      configure: configure,
    );
  });
  return proposal!;
}

Future<AiWriteProposal> _proposeOnStack(
  String operation,
  Map<String, Object?> arguments, {
  bool mergeRequest = false,
  void Function(StackServer server)? configure,
}) async {
  final harness = await StackHarness.create(
    level: AiAutonomyLevel.confirmEach,
    origin: mergeRequest ? null : _issueOrigin(),
    writeScope: mergeRequest ? _mrScope : null,
    configure: configure ?? _issueRecord,
  );
  try {
    harness.provider.script.add((_) => toolTurn(operation, arguments));
    final sending = harness.controller.send('Please update this.');
    await waitFor(
      () =>
          harness.controller.phase == AiChatPhase.awaitingApproval &&
          harness.controller.proposals.isNotEmpty,
    );
    final proposal = harness.controller.proposals.single;
    await harness.controller.rejectWrite(proposal);
    await sending;
    return proposal;
  } finally {
    harness.dispose();
  }
}

Finder _marker(String key) => find.byKey(ValueKey('ai-proposal-change-$key'));

Finder _previous(String key) =>
    find.byKey(ValueKey('ai-proposal-previous-$key'));

/// The test-only ledger rows: the whitelist also names fields the shipped
/// `updateIssue` / `updateMergeRequest` rows do not offer the model yet
/// (`target_branch`, `due_date`, `weight`, `discussion_locked`). These rows
/// reach them through the coordinator's own comparison, with a graph-shaped
/// fake port because only the production port can open a REST target.
final class _WhitelistLedger implements AiCapabilityLedger {
  const _WhitelistLedger();

  static const rows = <AiCapability>[
    AiCapability(
      operationId: 'updateMergeRequest',
      baseTier: AiWriteTier.t2,
      scopeClass: AiScopeClass.mergeRequest,
      boundary: AiWriteBoundary.graph,
      httpCap: 23,
      editableField: 'description',
      arguments: {
        'projectId': AiArgSpec(AiArgType.integer, required: true),
        'iid': AiArgSpec(AiArgType.integer, required: true),
        'fields': AiArgSpec(
          AiArgType.object,
          required: true,
          properties: {
            'title': AiArgSpec(AiArgType.string),
            'description': AiArgSpec(
              AiArgType.string,
              text: AiTextRole.quickActionMarkdown,
              writableField: 'mergeRequestDescription',
            ),
            'assignee_ids': AiArgSpec(AiArgType.integerList),
            'target_branch': AiArgSpec(
              AiArgType.string,
              text: AiTextRole.pathOrRef,
            ),
            'discussion_locked': AiArgSpec(AiArgType.boolean),
            'squash': AiArgSpec(AiArgType.boolean),
          },
        ),
      },
    ),
  ];

  @override
  AiCapability? find(String operationId) {
    for (final row in rows) {
      if (row.operationId == operationId) return row;
    }
    return null;
  }

  @override
  List<AiCapability> get modelVisible => rows;
}

final class _GraphPort implements port.AiGitLabWritePort {
  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) async =>
      port.AiWritePrepared.graph(
        request: request,
        releaseName: '!12',
        writeKeys: {
          const AiConflictKey([
            coordAccount,
            'project:9',
            'mergeRequest',
            '12',
          ]),
        },
        textMutation: (_, _) async => null,
      );

  @override
  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) => prepared.commitGraph(mayStart: mayStart);
}

/// A coordinator proposal for [arguments] against the merge request [record],
/// as the freshness read would have fetched it. [editedText], when given,
/// replaces the description on the card the way the card's edit does.
Future<AiWriteProposal> _coordinatorProposal(
  Map<String, dynamic> record,
  Map<String, Object?> arguments, {
  String? editedText,
}) async {
  final harness = await CoordHarness.create();
  try {
    final coordinator = PolicyAiWriteCoordinator(
      releasePolicy: fixtureReleasePolicy,
      ledger: const _WhitelistLedger(),
      snapshot: () => AiWritePolicySnapshot(
        scope: const AiWriteScope(
          accountKey: coordAccount,
          grants: [
            AiScopeGrant(
              kind: AiScopeKind.mergeRequest,
              projectId: 9,
              iid: 12,
              projectPath: 'group/project',
            ),
          ],
        ),
        level: AiAutonomyLevel.confirmEach,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'consent-v2',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
        appInForeground: true,
        clientMayStart: true,
      ),
      createPort: _GraphPort.new,
      journal: harness.journal,
      conversationId: 'field-changes',
      budget: () => harness.budget,
      readFreshness: (request) async => AiWriteFreshness(
        updatedAt: '2026-10-23T00:00:00Z',
        visibilityUnreadable: false,
        comparable: aiComparableFieldsFor(request.operationId, record),
      ),
      placeholders: UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
    );
    try {
      coordinator.beginRun('Retarget !12');
      coordinator.beginTurn();
      final proposal = await coordinator.propose(
        AiToolCall(
          id: 'call-mr-1',
          name: 'updateMergeRequest',
          arguments: arguments,
        ),
      );
      expect(
        proposal,
        isNotNull,
        reason: coordinator.recordedOutcomeFor('call-mr-1')?.reasonCode,
      );
      if (editedText != null) {
        final edited = await coordinator.approve(
          proposal!,
          editedText: editedText,
        );
        // An edit is never an approval: the card asks again.
        expect(edited.reasonCode, 'approvalRequired');
        expect(proposal.editedText, editedText);
      }
      return proposal!;
    } finally {
      coordinator.stop('disposed');
    }
  } finally {
    await harness.dispose();
  }
}

AiFieldChange _compare(
  String operation,
  String field,
  Object? proposed,
  Map<String, dynamic> record, {
  String Function(String)? safeDisplay,
}) => aiCompareWriteField(
  operationId: operation,
  field: field,
  proposed: proposed,
  comparable: aiComparableFieldsFor(operation, record),
  safeDisplay: safeDisplay ?? (value) => value,
);

void main() {
  testWidgets('1. the same title as the record is unchanged, with no '
      'previous line', (tester) async {
    final proposal = await _propose(tester, 'updateIssue', {
      'projectId': 42,
      'iid': 7,
      'fields': {'title': '  $_issueTitle  ', 'state_event': 'reopen'},
      'reason': 'Reopen the issue.',
    });

    expect(
      proposal.fieldChanges['title']?.status,
      AiFieldChangeStatus.unchanged,
    );
    expect(proposal.fieldChanges['title']?.previous, isNull);

    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_cardHost(proposal));
    expect(
      find.descendant(
        of: _marker('title'),
        matching: find.text(l10n.aiProposalFieldUnchanged),
      ),
      findsOneWidget,
    );
    expect(_previous('title'), findsNothing);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('ai-proposal-field-title')))
          .label,
      allOf(contains(l10n.title), contains(l10n.aiProposalFieldUnchanged)),
    );
    semantics.dispose();
  });

  testWidgets('2. a different title is changed and shows the old title; the '
      'reopen action has no marker', (tester) async {
    final proposal = await _propose(tester, 'updateIssue', {
      'projectId': 42,
      'iid': 7,
      'fields': {
        'title': 'Unrequested rewritten title',
        'state_event': 'reopen',
      },
      'reason': 'Reopen the issue.',
    });

    expect(proposal.fieldChanges['title']?.status, AiFieldChangeStatus.changed);
    expect(proposal.fieldChanges['title']?.previous, _issueTitle);
    expect(
      proposal.fieldChanges['state_event']?.status,
      AiFieldChangeStatus.unknown,
    );

    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_cardHost(proposal));
    expect(
      find.descendant(
        of: _marker('title'),
        matching: find.text(l10n.aiProposalFieldChanged),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _marker('title'), matching: find.byIcon(Icons.edit)),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(_previous('title')).data,
      l10n.aiProposalFieldPrevious(_issueTitle),
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('ai-proposal-field-title')))
          .label,
      allOf(
        contains(l10n.aiProposalFieldChanged),
        contains('Unrequested rewritten title'),
        contains(_issueTitle),
      ),
    );
    semantics.dispose();
    // The action itself is listed exactly as before: no marker, no line.
    expect(
      find.byKey(const ValueKey('ai-proposal-field-state_event')),
      findsOneWidget,
    );
    expect(_marker('state_event'), findsNothing);
    expect(_previous('state_event'), findsNothing);
  });

  testWidgets('3. labels in another order but the same set are unchanged', (
    tester,
  ) async {
    final proposal = await _propose(tester, 'updateIssue', {
      'projectId': 42,
      'iid': 7,
      'fields': {'labels': ' ux , mobile '},
      'reason': 'Keep the labels.',
    });

    expect(
      proposal.fieldChanges['labels']?.status,
      AiFieldChangeStatus.unchanged,
    );
    await tester.pumpWidget(_cardHost(proposal));
    expect(
      find.descendant(
        of: _marker('labels'),
        matching: find.text(l10n.aiProposalFieldUnchanged),
      ),
      findsOneWidget,
    );
    expect(_previous('labels'), findsNothing);

    // A different set is a change, and a label change never shows the old
    // value; neither does a subset.
    final record = {
      ...WorkspaceFixture().issue(7, _issueTitle),
      'labels': ['mobile', 'ux'],
    };
    for (final labels in ['ux, bug', 'ux', 'mobile, ux, bug', '']) {
      final change = _compare('updateIssue', 'labels', labels, record);
      expect(change.status, AiFieldChangeStatus.changed, reason: labels);
      expect(change.previous, isNull);
    }
  });

  testWidgets('4. a milestone change shows the old milestone title', (
    tester,
  ) async {
    final proposal = await _propose(
      tester,
      'updateIssue',
      {
        'projectId': 42,
        'iid': 7,
        'fields': {'milestone_id': 9},
        'reason': 'Move it to the next milestone.',
      },
      configure: (server) {
        _issueRecord(server);
        server.workspace.issues[7]!['milestone'] = <String, Object?>{
          'id': 4,
          'iid': 1,
          'project_id': 42,
          'title': 'v1.0',
          'state': 'active',
        };
      },
    );

    expect(
      proposal.fieldChanges['milestone_id']?.status,
      AiFieldChangeStatus.changed,
    );
    expect(proposal.fieldChanges['milestone_id']?.previous, 'v1.0');
    await tester.pumpWidget(_cardHost(proposal));
    expect(_marker('milestone_id'), findsOneWidget);
    expect(
      tester.widget<Text>(_previous('milestone_id')).data,
      l10n.aiProposalFieldPrevious('v1.0'),
    );

    // The same milestone, and "none" against no milestone, are unchanged.
    final record = WorkspaceFixture().issue(
      7,
      _issueTitle,
      milestone: {'id': 4, 'iid': 1, 'project_id': 42, 'title': 'v1.0'},
    );
    expect(
      _compare('updateIssue', 'milestone_id', 4, record).status,
      AiFieldChangeStatus.unchanged,
    );
    expect(
      _compare('updateIssue', 'milestone_id', 0, {
        ...WorkspaceFixture().issue(7, _issueTitle),
        'milestone': null,
      }).status,
      AiFieldChangeStatus.unchanged,
    );
    // Removing it is a change that names the milestone being removed.
    final removed = _compare('updateIssue', 'milestone_id', 0, record);
    expect(removed.status, AiFieldChangeStatus.changed);
    expect(removed.previous, 'v1.0');
  });

  testWidgets('5. a key outside the whitelist gets no marker', (tester) async {
    final proposal = await _propose(tester, 'updateIssue', {
      'projectId': 42,
      'iid': 7,
      'fields': {'severity': 'high', 'state_event': 'close'},
      'reason': 'Close it as high severity.',
    });

    for (final key in ['severity', 'state_event']) {
      expect(
        proposal.fieldChanges[key]?.status ?? AiFieldChangeStatus.unknown,
        AiFieldChangeStatus.unknown,
        reason: key,
      );
    }
    await tester.pumpWidget(_cardHost(proposal));
    expect(
      find.byKey(const ValueKey('ai-proposal-field-severity')),
      findsOneWidget,
    );
    expect(_marker('severity'), findsNothing);
    expect(_marker('state_event'), findsNothing);

    // Action fields are never compared, even when the record has a value
    // under the same name.
    final record = <String, dynamic>{
      ...WorkspaceFixture().mergeRequest,
      'squash': true,
      'merge_when_pipeline_succeeds': false,
      'reviewers': <Object?>[],
    };
    for (final (field, value) in const <(String, Object?)>[
      ('state_event', 'close'),
      ('remove_source_branch', true),
      ('squash', true),
      ('add_labels', 'mobile'),
      ('remove_labels', 'ux'),
      ('merge_when_pipeline_succeeds', false),
      ('reviewer_ids', <int>[]),
      ('severity', 'high'),
    ]) {
      final change = _compare('updateMergeRequest', field, value, record);
      expect(change.status, AiFieldChangeStatus.unknown, reason: field);
    }
    // Only the two REST updates are compared at all.
    for (final operation in [
      'createIssue',
      'updateWorkItemContent',
      'updateGroupWorkItemContent',
      'updateNote',
    ]) {
      expect(aiComparableFieldsFor(operation, record), isEmpty);
      expect(
        _compare(operation, 'title', record['title'], record).status,
        AiFieldChangeStatus.unknown,
      );
    }
  });

  testWidgets('6. a missing record key or an unexpected type gets no marker, '
      'never unchanged', (tester) async {
    // WorkspaceFixture.issue omits `milestone` when there is none.
    final proposal = await _propose(tester, 'updateIssue', {
      'projectId': 42,
      'iid': 7,
      'fields': {'milestone_id': 4, 'labels': 'mobile, ux'},
      'reason': 'Set the milestone and keep the labels.',
    });

    expect(
      proposal.fieldChanges['milestone_id']?.status,
      AiFieldChangeStatus.unknown,
    );
    expect(
      proposal.fieldChanges['labels']?.status,
      AiFieldChangeStatus.unchanged,
    );
    await tester.pumpWidget(_cardHost(proposal));
    expect(
      find.byKey(const ValueKey('ai-proposal-field-milestone_id')),
      findsOneWidget,
    );
    expect(_marker('milestone_id'), findsNothing);
    expect(_previous('milestone_id'), findsNothing);

    // Labels read with `with_labels_details` come back as objects, not names.
    final detailed = <String, dynamic>{
      ...WorkspaceFixture().issue(7, _issueTitle),
      'labels': [
        {
          'id': 3,
          'name': 'mobile',
          'color': '#428BCA',
          'description': null,
          'text_color': '#FFFFFF',
        },
      ],
    };
    expect(
      _compare('updateIssue', 'labels', 'mobile', detailed).status,
      AiFieldChangeStatus.unknown,
    );

    // Every whitelisted field, against a record that lacks it.
    const sameAsAnything = <(String, Object?)>[
      ('title', _issueTitle),
      ('description', ''),
      ('due_date', '2026-12-31'),
      ('confidential', false),
      ('weight', 3),
      ('milestone_id', 0),
      ('labels', ''),
      ('assignee_ids', <int>[]),
      ('target_branch', 'main'),
      ('discussion_locked', false),
    ];
    final bare = <String, dynamic>{'id': 1012, 'iid': 12, 'project_id': 42};
    expect(aiComparableFieldsFor('updateMergeRequest', bare), isEmpty);
    for (final (field, value) in sameAsAnything) {
      expect(
        _compare('updateMergeRequest', field, value, bare).status,
        AiFieldChangeStatus.unknown,
        reason: field,
      );
    }

    // Every whitelisted field, with a record value of the wrong type.
    final malformed = <String, dynamic>{
      'title': 42,
      'description': ['not text'],
      'due_date': '2026-12-31T00:00:00Z',
      'confidential': 'maybe',
      'weight': '3',
      'milestone': {'id': '4', 'title': 'v1.0'},
      'labels': 'mobile,ux',
      'assignees': [
        {'id': '7', 'username': 'developer'},
      ],
      'target_branch': 7,
      'discussion_locked': 'false',
    };
    expect(aiComparableFieldsFor('updateMergeRequest', malformed), isEmpty);

    // Proposal values that cannot be parsed, against a well-formed record.
    final record = <String, dynamic>{
      ...WorkspaceFixture().mergeRequest,
      'description': 'Body',
      'due_date': '2026-12-31',
      'weight': 2,
      'milestone': {'id': 4, 'title': 'v1.0'},
      'labels': ['mobile'],
      'assignees': [
        {'id': 7, 'username': 'developer'},
      ],
      'discussion_locked': false,
    };
    for (final (field, value) in const <(String, Object?)>[
      ('title', 123),
      ('description', 123),
      ('due_date', '31-12-2026'),
      ('confidential', 'yes'),
      ('weight', '2'),
      ('milestone_id', -1),
      ('labels', ['mobile']),
      ('assignee_ids', ['7']),
      ('target_branch', 123),
      ('discussion_locked', 'false'),
    ]) {
      expect(
        _compare('updateMergeRequest', field, value, record).status,
        AiFieldChangeStatus.unknown,
        reason: field,
      );
    }
  });

  test('6b. only the whitespace GitLab strips is ignored', () {
    final record = <String, dynamic>{
      ...WorkspaceFixture().issue(7, _issueTitle),
      'description': '    code\n',
      'labels': ['bug', 'ux'],
    };
    AiFieldChangeStatus status(String field, Object? value) =>
        _compare('updateIssue', field, value, record).status;

    // Ruby's strip set (NUL, tab, LF, VT, FF, CR, space) is what GitLab
    // removes from a title or a label name, so these are the same values.
    for (final title in [
      '  $_issueTitle ',
      '\t$_issueTitle\r\n',
      '\x00$_issueTitle\x0b\x0c',
    ]) {
      expect(status('title', title), AiFieldChangeStatus.unchanged);
    }
    for (final labels in ['ux,bug', ' bug ,\tux\n', 'bug, ux, ']) {
      expect(status('labels', labels), AiFieldChangeStatus.unchanged);
    }

    // Unicode spaces are kept by GitLab: a different title, a different
    // label (the real `bug` would be removed).
    for (final title in [
      '\u00a0$_issueTitle',
      '$_issueTitle\ufeff',
      '\u3000$_issueTitle',
      '$_issueTitle\u2028',
    ]) {
      final change = _compare('updateIssue', 'title', title, record);
      expect(change.status, AiFieldChangeStatus.changed, reason: title);
      expect(change.previous, _issueTitle);
    }
    for (final labels in [
      '\u00a0bug, ux',
      'bug\u2028, ux',
      'bug, ux\ufeff',
      'bug,\u3000ux',
    ]) {
      expect(
        status('labels', labels),
        AiFieldChangeStatus.changed,
        reason: labels,
      );
    }

    // A description is compared exactly: indentation and line ends are
    // content.
    expect(status('description', '    code\n'), AiFieldChangeStatus.unchanged);
    for (final description in ['code', '    code', 'code\n', '  code\n']) {
      expect(
        status('description', description),
        AiFieldChangeStatus.changed,
        reason: description,
      );
    }
  });

  testWidgets('7. a previous title holding a secret is shown redacted', (
    tester,
  ) async {
    final token = WorkspaceFixture().account.token;
    final proposal = await _propose(
      tester,
      'updateIssue',
      {
        'projectId': 42,
        'iid': 7,
        'fields': {'title': 'Sanitized title'},
        'reason': 'Retitle the issue.',
      },
      configure: (server) =>
          _issueRecord(server, title: 'Leak $_secretPattern and $token'),
    );

    final previous = proposal.fieldChanges['title']?.previous;
    expect(proposal.fieldChanges['title']?.status, AiFieldChangeStatus.changed);
    expect(previous, contains('[REDACTED]'));
    expect(previous, isNot(contains(_secretPattern)));
    expect(previous, isNot(contains(token)));
    await tester.pumpWidget(_cardHost(proposal));
    final shown = tester.widget<Text>(_previous('title')).data!;
    expect(shown, contains('[REDACTED]'));
    expect(shown, isNot(contains(_secretPattern)));
    expect(shown, isNot(contains(token)));
    expect(find.textContaining(_secretPattern), findsNothing);

    // The comparison takes the card's own redaction: a known secret and a
    // pattern hit are both masked before the old value is capped.
    final redactor = Redactor(secrets: const _SecretSource([_knownSecret]));
    String safeDisplay(String value) => redactor.redactSource(value).text;
    final change = _compare('updateIssue', 'title', 'Clean title', {
      'title': 'Old $_knownSecret and $_secretPattern',
    }, safeDisplay: safeDisplay);
    expect(change.previous, 'Old [REDACTED] and [REDACTED]');

    // The cap is 200 code units with the `…` that marks a cut, never inside
    // a surrogate pair; a value that fits is shown whole.
    String? previousOf(String title) => _compare('updateIssue', 'title', 'S', {
      'title': title,
    }, safeDisplay: safeDisplay).previous;
    expect(previousOf('c' * 200), 'c' * 200);
    expect(previousOf('b' * 255), '${'b' * 199}…');
    expect(previousOf('${'a' * 198}😀 tail'), '${'a' * 198}…');
    expect(previousOf('${'a' * 197}😀 tail'), '${'a' * 197}😀…');
    for (final title in ['b' * 255, '${'a' * 198}😀 tail']) {
      expect(
        previousOf(title)!.length,
        lessThanOrEqualTo(aiPreviousValueLimit),
      );
    }
  });

  testWidgets('8. in Arabic the previous value is wrapped in isolates', (
    tester,
  ) async {
    final proposal = await _propose(tester, 'updateIssue', {
      'projectId': 42,
      'iid': 7,
      'fields': {'title': 'New title'},
      'reason': 'Retitle the issue.',
    });

    useLanguage(languageForTag('ar')!);
    await tester.pumpWidget(_cardHost(proposal, tag: 'ar'));
    final shown = tester.widget<Text>(_previous('title')).data!;
    // The generated Arabic message isolates every argument by itself; the
    // inner pair is the card's own isolated(), as for any GitLab text.
    expect(shown, contains('\u2068\u2068$_issueTitle\u2069\u2069'));
    expect(shown, contains(l10n.aiProposalFieldPrevious('').trim()));
    expect(
      find.descendant(
        of: _marker('title'),
        matching: find.text(l10n.aiProposalFieldChanged),
      ),
      findsOneWidget,
    );
  });

  test('9. the GitLab requests for updateIssue and updateMergeRequest are '
      'exactly the pinned counts', () async {
    Future<void> measure(
      String operation,
      Map<String, Object?> arguments, {
      bool mergeRequest = false,
    }) async {
      final harness = await StackHarness.create(
        level: AiAutonomyLevel.confirmEach,
        origin: mergeRequest ? null : _issueOrigin(),
        writeScope: mergeRequest ? _mrScope : null,
        configure: _issueRecord,
      );
      addTearDown(harness.dispose);
      harness.provider.script.add((_) => toolTurn(operation, arguments));
      final gets = harness.server.gets;
      final requests = harness.server.adapter.requests.length;
      final sending = harness.controller.send('Update it.');
      await waitFor(
        () =>
            harness.controller.phase == AiChatPhase.awaitingApproval &&
            harness.controller.proposals.isNotEmpty,
      );
      final proposal = harness.controller.proposals.single;
      // The comparison ran on this very card.
      expect(
        proposal.fieldChanges['title']?.status,
        AiFieldChangeStatus.changed,
      );
      final outcome = await harness.controller.approveWrite(
        proposal,
        typedName: proposal.tier.typedName,
      );
      await sending;
      expect(outcome.state, AiJournalState.succeeded, reason: operation);
      expect(harness.server.mutations, hasLength(1), reason: operation);
      final reads = aiWriteRequestCounts[operation]!.reads;
      expect(harness.server.gets - gets, reads, reason: operation);
      expect(
        harness.server.adapter.requests.length - requests,
        reads + 1,
        reason: operation,
      );
    }

    // The pinned numbers this feature must not move.
    expect(
      [
        for (final operation in ['updateIssue', 'updateMergeRequest'])
          (
            aiWriteRequestCounts[operation]!.fresh,
            aiWriteRequestCounts[operation]!.prepare,
            aiWriteRequestCounts[operation]!.readback,
          ),
      ],
      [(2, 3, 1), (2, 3, 1)],
    );
    await measure('updateIssue', {
      'projectId': 42,
      'iid': 7,
      'fields': {'title': 'Updated issue title', 'labels': 'ux, mobile'},
      'reason': 'Update the issue.',
    });
    await measure('updateMergeRequest', {
      'projectId': 42,
      'iid': 12,
      'fields': {
        'title': 'Updated MR title',
        'assignee_ids': [7],
      },
      'reason': 'Update the merge request.',
    }, mergeRequest: true);
  });

  test('10. nothing persists: no previous value or change map in history, '
      'no title text in the journal', () async {
    const oldTitle = 'SentinelPreviousTitle9812';
    const newTitle = 'SentinelNewTitle9812';
    final harness = await StackHarness.create(
      level: AiAutonomyLevel.confirmEach,
      origin: _issueOrigin(),
      configure: (server) => _issueRecord(server, title: oldTitle),
    );
    addTearDown(harness.dispose);
    harness.provider.script.add(
      (_) => toolTurn('updateIssue', {
        'projectId': 42,
        'iid': 7,
        'fields': {'title': newTitle, 'state_event': 'reopen'},
        'reason': 'Reopen the issue.',
      }),
    );
    final sending = harness.controller.send('Reopen #7');
    await waitFor(
      () =>
          harness.controller.phase == AiChatPhase.awaitingApproval &&
          harness.controller.proposals.isNotEmpty,
    );
    final proposal = harness.controller.proposals.single;
    expect(proposal.fieldChanges['title']?.previous, oldTitle);
    final outcome = await harness.controller.approveWrite(
      proposal,
      typedName: proposal.tier.typedName,
    );
    await sending;
    expect(outcome.state, AiJournalState.succeeded);

    // The display model the history codec would save for this conversation.
    // The issue context the chat was opened with (the user's chip) carries
    // the record by design; nothing else may.
    final saved = aiDisplayJson(
      AiConversation(items: harness.controller.items),
    );
    final display = jsonEncode(saved);
    final items = (saved['items']! as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(items.map((item) => item['kind']), contains('tool'));
    final outsideContext = jsonEncode([
      for (final item in items) {...item}..remove('chips'),
    ]);
    expect(outsideContext, isNot(contains(oldTitle)));
    expect(outsideContext, isNot(contains(newTitle)));
    for (final marker in [
      'fieldChanges',
      l10n.aiProposalFieldChanged,
      l10n.aiProposalFieldUnchanged,
      l10n.aiProposalFieldPrevious(''),
    ]) {
      expect(display, isNot(contains(marker)), reason: marker);
    }

    // The journal as written to disk, decrypted: every field of every entry,
    // not a selection.
    final entries = harness.journal.entries(harness.account);
    expect(entries, hasLength(1));
    final raw = await AiJournalFiles(harness.root).read(harness.account);
    final journaled = jsonEncode(
      await AiHistoryCipher.decryptJson(
        raw!,
        harness.journalKeys.keys[harness.account]!,
        harness.account,
        AiJournalFiles.fileName,
      ),
    );
    expect(journaled, contains(entries.single.executionId));
    expect(journaled, contains('updateIssue'));
    for (final text in [
      oldTitle,
      newTitle,
      'fieldChanges',
      'comparable',
      l10n.aiProposalFieldChanged,
      l10n.aiProposalFieldUnchanged,
      l10n.aiProposalFieldPrevious(''),
    ]) {
      expect(journaled, isNot(contains(text)), reason: text);
    }
  });

  testWidgets('11. updateMergeRequest: target_branch changed, assignee_ids '
      'unchanged', (tester) async {
    // The shipped ledger row, through the controller stack.
    final stack = await _propose(
      tester,
      'updateMergeRequest',
      {
        'projectId': 42,
        'iid': 12,
        'fields': {
          'assignee_ids': [7],
          'title': 'Improve private-project navigation',
        },
        'reason': 'Keep the assignee.',
      },
      mergeRequest: true,
      configure: (server) {
        server.workspace.mergeFields['assignees'] = <Map<String, dynamic>>[
          {'id': 7, 'username': 'developer', 'name': 'Developer'},
        ];
      },
    );
    expect(
      stack.fieldChanges['assignee_ids']?.status,
      AiFieldChangeStatus.unchanged,
    );
    expect(stack.fieldChanges['title']?.status, AiFieldChangeStatus.unchanged);

    // target_branch through the coordinator's comparison.
    final record = <String, dynamic>{
      ...WorkspaceFixture().mergeRequest,
      'description': '',
      'assignees': [
        {'id': 1, 'username': 'alice', 'name': 'Alice'},
      ],
      'discussion_locked': false,
    };
    late final AiWriteProposal proposal;
    await tester.runAsync(() async {
      proposal = await _coordinatorProposal(record, const {
        'projectId': 9,
        'iid': 12,
        'fields': {
          'target_branch': 'release/v1',
          'assignee_ids': [1],
          'description': 'Ships the navigation.',
          'discussion_locked': true,
          'squash': true,
        },
        'reason': 'Retarget the merge request.',
      });
    });
    final changes = proposal.fieldChanges;
    expect(changes['target_branch']?.status, AiFieldChangeStatus.changed);
    expect(changes['target_branch']?.previous, 'main');
    expect(changes['assignee_ids']?.status, AiFieldChangeStatus.unchanged);
    expect(changes['assignee_ids']?.previous, isNull);
    expect(changes['description']?.status, AiFieldChangeStatus.changed);
    expect(changes['description']?.previous, isNull);
    expect(changes['discussion_locked']?.status, AiFieldChangeStatus.changed);
    expect(changes['discussion_locked']?.previous, isNull);
    expect(changes['squash']?.status, AiFieldChangeStatus.unknown);

    await tester.pumpWidget(_cardHost(proposal));
    expect(
      find.descendant(
        of: _marker('target_branch'),
        matching: find.text(l10n.aiProposalFieldChanged),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<Text>(_previous('target_branch')).data,
      l10n.aiProposalFieldPrevious('main'),
    );
    expect(
      find.descendant(
        of: _marker('assignee_ids'),
        matching: find.text(l10n.aiProposalFieldUnchanged),
      ),
      findsOneWidget,
    );
    expect(_previous('assignee_ids'), findsNothing);
    expect(_previous('description'), findsNothing);
    expect(_marker('squash'), findsNothing);

    // target_branch is compared for merge requests only.
    expect(
      _compare('updateIssue', 'target_branch', 'main', record).status,
      AiFieldChangeStatus.unknown,
    );
  });

  testWidgets('an edited description is compared again', (tester) async {
    final record = <String, dynamic>{
      ...WorkspaceFixture().mergeRequest,
      'description': 'Ships the navigation.',
    };
    const arguments = {
      'projectId': 9,
      'iid': 12,
      'fields': {'description': 'A rewritten body nobody asked for.'},
      'reason': 'Tidy the description.',
    };
    late final AiWriteProposal proposed;
    late final AiWriteProposal edited;
    await tester.runAsync(() async {
      proposed = await _coordinatorProposal(record, arguments);
      edited = await _coordinatorProposal(
        record,
        arguments,
        editedText: 'Ships the navigation.',
      );
    });
    expect(
      proposed.fieldChanges['description']?.status,
      AiFieldChangeStatus.changed,
    );
    expect(
      edited.fieldChanges['description']?.status,
      AiFieldChangeStatus.unchanged,
    );
    expect(edited.fieldChanges['description']?.previous, isNull);
  });

  test('issue fields: due date, confidential, weight and discussion lock', () {
    // GitLab's issue response carries all four; weight and the lock are null
    // when unset.
    final record = <String, dynamic>{
      ...WorkspaceFixture().issue(7, _issueTitle),
      'description': null,
      'due_date': '2026-11-15',
      'weight': 3,
      'discussion_locked': true,
    };
    AiFieldChange compare(String field, Object? value) =>
        _compare('updateIssue', field, value, record);

    expect(
      compare('due_date', '2026-11-15').status,
      AiFieldChangeStatus.unchanged,
    );
    final due = compare('due_date', '2026-12-01');
    expect(due.status, AiFieldChangeStatus.changed);
    expect(due.previous, '2026-11-15');
    expect(compare('due_date', '').status, AiFieldChangeStatus.changed);
    expect(
      compare('confidential', false).status,
      AiFieldChangeStatus.unchanged,
    );
    expect(
      compare('confidential', 'false').status,
      AiFieldChangeStatus.unchanged,
    );
    final confidential = compare('confidential', true);
    expect(confidential.status, AiFieldChangeStatus.changed);
    expect(confidential.previous, 'false');
    expect(compare('weight', 3).status, AiFieldChangeStatus.unchanged);
    expect(compare('weight', 5).previous, '3');
    expect(
      compare('discussion_locked', true).status,
      AiFieldChangeStatus.unchanged,
    );
    final unlocked = compare('discussion_locked', false);
    expect(unlocked.status, AiFieldChangeStatus.changed);
    expect(unlocked.previous, isNull);
    // A null description and an empty one are the same; blank text is not.
    expect(compare('description', '').status, AiFieldChangeStatus.unchanged);
    expect(compare('description', '  ').status, AiFieldChangeStatus.changed);
    final description = compare('description', 'Now with text');
    expect(description.status, AiFieldChangeStatus.changed);
    expect(description.previous, isNull);

    final unset = <String, dynamic>{
      ...record,
      'due_date': null,
      'weight': null,
      'discussion_locked': null,
    };
    expect(
      _compare('updateIssue', 'due_date', '', unset).status,
      AiFieldChangeStatus.unchanged,
    );
    final firstDue = _compare('updateIssue', 'due_date', '2026-12-01', unset);
    expect(firstDue.status, AiFieldChangeStatus.changed);
    expect(firstDue.previous, isNull);
    // An unset weight or lock is not a value to compare with.
    expect(
      _compare('updateIssue', 'weight', 2, unset).status,
      AiFieldChangeStatus.unknown,
    );
    expect(
      _compare('updateIssue', 'discussion_locked', false, unset).status,
      AiFieldChangeStatus.unknown,
    );
  });
}
