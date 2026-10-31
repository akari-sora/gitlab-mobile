import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/graphql_write_classify.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_preview.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/workspace/attachment_picker.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_write_settings.dart';
import 'package:gitlab_mobile/features/ai/ai_write_ui.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'fx_coord_support.dart';

AiWriteProposal _proposal({
  String operationId = 'createNote',
  AiWriteTier tier = AiWriteTier.t2,
  bool typedName = false,
  List<AiFixedConfirmReason> reasons = const [],
  Map<String, String> fields = const {'body': 'Looks good.\nShip it.'},
  Map<String, AiFieldChange> fieldChanges = const {},
  String reason = 'You asked me to approve the review.',
  AiUploadPreview? upload,
  List<String> closingRefs = const [],
  AiWritePreview? preview,
  bool showSquash = false,
  String? editableField = 'body',
  String releaseName = '!44',
  String typedNameValue = 'team/example',
}) => AiWriteProposal(
  executionId: 'exec-1',
  operationId: operationId,
  tier: AiTierDecision(
    decision: AiGateDecision.requireApproval,
    tier: tier,
    requiresTypedName: typedName,
    typedName: typedName ? typedNameValue : null,
    reasons: reasons,
    reusesStoredVariables: tier == AiWriteTier.t3,
    showSquash: showSquash,
  ),
  payloadDigest: 'digest',
  previewText: 'createNote !44',
  userUtterance: 'comment on it',
  modelReason: reason,
  expiresAt: DateTime(2026, 10, 22, 21, 30),
  proposalEpoch: 1,
  writePolicyRevision: 1,
  consentHash: 'hash',
  scopeRevision: 1,
  releaseName: releaseName,
  fields: fields,
  fieldChanges: fieldChanges,
  upload: upload,
  closingRefs: closingRefs,
  preview: preview,
  editableField: editableField,
);

final class _Writes implements AiWriteChatSession {
  _Writes(this.proposals);

  @override
  final List<AiWriteProposal> proposals;
  @override
  AiAutonomyLevel autonomyLevel = AiAutonomyLevel.confirmEach;
  @override
  AiAutonomyLevel autonomyCeiling = AiAutonomyLevel.conversationGrant;

  final approvals = <({String? typedName, String? editedText})>[];
  final rejected = <AiWriteProposal>[];
  AiWriteOutcome Function(String? editedText) answer = (_) =>
      const AiWriteOutcome(state: AiJournalState.succeeded, reasonCode: 'ok');
  Future<AiWriteOutcome> Function(String? editedText)? onApprove;

  @override
  Future<void> setAutonomyLevel(AiAutonomyLevel level) async =>
      autonomyLevel = level;

  @override
  Future<AiWriteOutcome> approveWrite(
    AiWriteProposal proposal, {
    String? typedName,
    String? editedText,
  }) async {
    approvals.add((typedName: typedName, editedText: editedText));
    if (onApprove case final approve?) return approve(editedText);
    return answer(editedText);
  }

  @override
  Future<void> rejectWrite(AiWriteProposal proposal) async =>
      rejected.add(proposal);

  @override
  List<AiStoredAttachment> attachments = const [];
  @override
  bool canAttach = true;
  AiAttachResult attachResult = const AiAttachResult(
    status: AiAttachStatus.stored,
    reasonCode: null,
  );
  final picks = <AiAttachmentPick>[];
  final removed = <String>[];
  @override
  Future<AiAttachResult> attach(AiAttachmentPick pick) async {
    picks.add(pick);
    return attachResult;
  }

  @override
  void removeAttachment(String id) => removed.add(id);
}

final class _NoPicker implements AttachmentPicker {
  @override
  Future<PickedAttachment?> pickImage() async => null;
  @override
  Future<PickedAttachment?> pickFile() async => null;
}

/// A real held attachment, read from synthetic bytes.
Future<AiStoredAttachment> _held(
  WidgetTester tester,
  String filename,
  List<int> bytes, {
  String? mediaType,
}) async {
  final session = AiAttachmentSession(
    accountKey: 'synthetic',
    conversationId: 'conversation-$filename',
  );
  addTearDown(session.discardAll);
  final result = await tester.runAsync(
    () => session.reserveAndRead(
      picker: _NoPicker(),
      uploadToolInSegment: true,
      intake: AiAttachmentIntake(
        filename: filename,
        length: bytes.length,
        open: () => Stream.value(bytes),
        mediaType: mediaType,
      ),
    ),
  );
  return result!.attachment!;
}

Widget _host(Widget child, {String tag = 'zh-TW', double scale = 1}) =>
    MaterialApp(
      theme: appTheme(Brightness.light),
      locale: switch (tag) {
        'ar' => const Locale('ar'),
        'en' => const Locale('en'),
        _ => const Locale('zh', 'TW'),
      },
      supportedLocales: const [Locale('zh', 'TW'), Locale('ar'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    );

/// The fifteen MR6b-3g group work-item aliases and the project operation each
/// one mirrors. Written out rather than read from the ledger: the group rows
/// stay empty and hidden until each family lands, and the labels may not
/// wait for them.
const _groupAliases = <String, String>{
  'updateGroupWorkItemState': 'updateWorkItemState',
  'updateGroupWorkItemStatus': 'updateWorkItemStatus',
  'updateGroupWorkItemDates': 'updateWorkItemDates',
  'updateGroupWorkItemHealthStatus': 'updateWorkItemHealthStatus',
  'updateGroupWorkItemAssignees': 'updateWorkItemAssignees',
  'updateGroupWorkItemMilestone': 'updateWorkItemMilestone',
  'updateGroupWorkItemWeight': 'updateWorkItemWeight',
  'createGroupWorkItemActivityComment': 'createWorkItemActivityComment',
  'createGroupWorkItemActivityReply': 'createWorkItemActivityReply',
  'deleteGroupWorkItemActivityNote': 'deleteWorkItemActivityNote',
  'setGroupWorkItemActivityNoteReaction': 'setWorkItemActivityNoteReaction',
  'setGroupWorkItemNotifications': 'setWorkItemNotifications',
  'updateGroupWorkItemContent': 'updateWorkItemContent',
  'editGroupWorkItemActivityNote': 'editWorkItemActivityNote',
  'updateGroupWorkItemLabels': 'updateWorkItemLabels',
};

/// The aliases whose project label names the work item: their own label
/// names the group's work item instead. Every other alias names only the
/// action, which reads the same on a group's work item.
Map<String, String> _groupWorkItemLabels() => {
  'updateGroupWorkItemContent': l10n.aiOpEditGroupWorkItem,
  'updateGroupWorkItemState': l10n.aiOpSetGroupWorkItemState,
  'updateGroupWorkItemAssignees': l10n.aiOpSetGroupWorkItemAssignees,
  'updateGroupWorkItemDates': l10n.aiOpSetGroupWorkItemDates,
};

/// Each two-way group alias, a direction, and the title it must show.
List<(String, Map<String, String>, String)> _groupDirectionTitles() => [
  (
    'setGroupWorkItemActivityNoteReaction',
    {'add': 'true'},
    l10n.aiOpAddAwardEmoji,
  ),
  (
    'setGroupWorkItemActivityNoteReaction',
    {'add': 'false'},
    l10n.aiOpRemoveAwardEmoji,
  ),
  ('setGroupWorkItemNotifications', {'enabled': 'true'}, l10n.aiOpSubscribeOn),
  (
    'setGroupWorkItemNotifications',
    {'enabled': 'false'},
    l10n.aiOpSubscribeOff,
  ),
  (
    'updateGroupWorkItemState',
    {'stateEvent': 'close'},
    l10n.aiOpCloseGroupWorkItem,
  ),
  (
    'updateGroupWorkItemState',
    {'stateEvent': 'reopen'},
    l10n.aiOpReopenGroupWorkItem,
  ),
];

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  testWidgets('shows what would be written and approves it', (tester) async {
    final proposal = _proposal();
    final writes = _Writes([proposal]);
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: writes)),
    );
    expect(find.text(l10n.aiOpCreateNote), findsOneWidget);
    expect(find.textContaining('!44'), findsOneWidget);
    expect(
      find.text(l10n.aiProposalReason('You asked me to approve the review.')),
      findsOneWidget,
    );
    // The body keeps its line breaks.
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('ai-proposal-field-body')))
          .data,
      'Looks good.\nShip it.',
    );
    await tester.tap(find.byKey(const ValueKey('ai-proposal-approve')));
    await tester.pumpAndSettle();
    expect(writes.approvals, [(typedName: null, editedText: null)]);
    expect(find.byKey(const ValueKey('ai-proposal-message')), findsNothing);
  });

  testWidgets('reject sends nothing', (tester) async {
    final proposal = _proposal();
    final writes = _Writes([proposal]);
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: writes)),
    );
    await tester.tap(find.byKey(const ValueKey('ai-proposal-reject')));
    await tester.pumpAndSettle();
    expect(writes.rejected, [proposal]);
    expect(writes.approvals, isEmpty);
  });

  testWidgets('a two-way write names its direction, not its raw field', (
    tester,
  ) async {
    for (final (operation, fields, title) in [
      ('setStar', const {'starred': 'true'}, l10n.star),
      ('setStar', const {'starred': 'false'}, l10n.unstar),
      ('setSubscribed', const {'subscribed': 'false'}, l10n.aiOpSubscribeOff),
      (
        'setDiscussionResolved',
        const {'resolved': 'true'},
        l10n.aiOpResolveThread,
      ),
      ('setMilestoneState', const {'stateEvent': 'close'}, l10n.closeMilestone),
      ..._groupDirectionTitles(),
    ]) {
      final proposal = _proposal(
        operationId: operation,
        tier: AiWriteTier.t1,
        fields: fields,
      );
      await tester.pumpWidget(
        _host(
          AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
        ),
      );
      expect(find.text(title), findsOneWidget, reason: '$operation $fields');
      expect(find.text('true'), findsNothing);
      expect(find.text('false'), findsNothing);
      expect(
        find.byKey(ValueKey('ai-proposal-field-${fields.keys.single}')),
        findsNothing,
      );
    }
  });

  testWidgets('a reaction card offers no text edit', (tester) async {
    final proposal = _proposal(
      operationId: 'addAwardEmoji',
      tier: AiWriteTier.t1,
      fields: const {'name': 'thumbsup'},
    );
    await tester.pumpWidget(
      _host(
        AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
      ),
    );
    expect(find.byKey(const ValueKey('ai-proposal-edit')), findsNothing);
    expect(find.byKey(const ValueKey('ai-proposal-approve')), findsOne);
  });

  testWidgets('the edit button follows the ledger, not the field names', (
    tester,
  ) async {
    // The editable field comes from the production ledger: createRelease
    // edits its description and renameBoard its name; editProject has no
    // editable text, so a name-only edit would always be refused; a title-only
    // issue does not carry the description it would edit.
    for (final (operation, fields, offered) in [
      ('createRelease', const {'tagName': 'v1.0', 'description': 'Notes'}, true),
      ('editProject', const {'name': 'Renamed'}, false),
      ('renameBoard', const {'name': 'Sprint'}, true),
      ('createIssue', const {'title': 'Only a title'}, false),
    ]) {
      final proposal = _proposal(
        operationId: operation,
        fields: fields,
        editableField: productionAiLedger.find(operation)!.editableField,
      );
      await tester.pumpWidget(
        _host(
          AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
        ),
      );
      expect(
        find.byKey(const ValueKey('ai-proposal-edit')),
        offered ? findsOneWidget : findsNothing,
        reason: operation,
      );
    }
  });

  testWidgets('switches and state changes read as words', (tester) async {
    final proposal = _proposal(
      operationId: 'updateIssue',
      fields: const {'confidential': 'true', 'state_event': 'close'},
    );
    await tester.pumpWidget(
      _host(
        AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
      ),
    );
    expect(find.text(l10n.confidentialIssue), findsOneWidget);
    expect(find.text(l10n.yesLabel), findsOneWidget);
    expect(find.text(l10n.status), findsOneWidget);
    expect(find.text(l10n.closeAction), findsOneWidget);
    expect(find.text('state_event'), findsNothing);
  });

  testWidgets('a typed name with direction marks still matches', (
    tester,
  ) async {
    final proposal = _proposal(
      operationId: 'updateMergeRequest',
      tier: AiWriteTier.t3,
      typedName: true,
      fields: const {'title': 'Draft: rename'},
    );
    final writes = _Writes([proposal]);
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: writes)),
    );
    await tester.enterText(
      find.byKey(const ValueKey('ai-proposal-typed-name')),
      '\u2068team/example\u2069',
    );
    await tester.pump();
    final approve = find.byKey(const ValueKey('ai-proposal-approve'));
    await tester.tap(approve);
    await tester.pumpAndSettle();
    // The coordinator's exact check gets the stored name.
    expect(writes.approvals.single.typedName, 'team/example');
  });

  AiUploadPreview upload(String? visibility) => AiUploadPreview(
    attachmentId: 'att-1',
    filename: 'shot.png',
    sizeBytes: 2048,
    contentType: 'image/png',
    sha256Prefix: 'abcd1234',
    projectId: 9,
    projectPath: 'team/example-9',
    projectVisibility: visibility,
  );

  testWidgets('an upload card shows the file, the project and who can see', (
    tester,
  ) async {
    for (final (visibility, label, warns) in [
      ('public', l10n.visibilityPublic, true),
      ('internal', l10n.visibilityInternal, true),
      ('private', l10n.visibilityPrivate, false),
      (null, l10n.aiUploadVisibilityUnknown, true),
    ]) {
      final proposal = _proposal(
        operationId: 'upload_attachment',
        fields: const {'filename': 'shot.png', 'contentType': 'image/png'},
        upload: upload(visibility),
      );
      await tester.pumpWidget(
        _host(
          AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
        ),
      );
      expect(find.byKey(const ValueKey('ai-proposal-upload')), findsOne);
      expect(find.text('shot.png'), findsOneWidget);
      expect(
        find.text(l10n.aiUploadTarget('team/example-9', label)),
        findsOneWidget,
        reason: '$visibility',
      );
      expect(
        find.byKey(const ValueKey('ai-proposal-upload-warning')),
        warns ? findsOne : findsNothing,
        reason: '$visibility',
      );
      // The raw fields are not repeated under the preview.
      expect(
        find.byKey(const ValueKey('ai-proposal-field-filename')),
        findsNothing,
      );
    }
  });

  testWidgets('a merge request card lists the issues it closes', (
    tester,
  ) async {
    final proposal = _proposal(
      operationId: 'updateMergeRequest',
      fields: const {'description': 'Closes #3'},
      closingRefs: const ['team/example-9#3', 'team/example-9#8'],
    );
    await tester.pumpWidget(
      _host(
        AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
      ),
    );
    expect(
      find.text(
        l10n.aiProposalClosesOnMerge('team/example-9#3, team/example-9#8'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a merge card shows its preview once, without repeats', (
    tester,
  ) async {
    final proposal = _proposal(
      operationId: 'mergeRequest',
      tier: AiWriteTier.t4,
      fields: const {'squash': 'true'},
      showSquash: true,
      closingRefs: const ['#3'],
      preview: AiMergePreview(
        sourceBranch: 'feature/login',
        targetBranch: 'main',
        shortSha: 'a1b2c3d4',
        pathCount: 2,
        squash: true,
        closingIssues: const [
          AiClosingIssue(projectId: 9, iid: 3, outOfScope: false),
        ],
      ),
    );
    await tester.pumpWidget(
      _host(
        AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
      ),
    );
    expect(find.byKey(const ValueKey('ai-preview-merge')), findsOneWidget);
    expect(find.text(l10n.aiPreviewSquashOn), findsOneWidget);
    expect(find.text(l10n.aiProposalSquash), findsNothing);
    expect(find.text(l10n.aiProposalClosesOnMerge('#3')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-proposal-closes')), findsNothing);
    expect(
      find.byKey(const ValueKey('ai-proposal-field-squash')),
      findsNothing,
    );
  });

  testWidgets('pipeline variables read as KEY = value lines', (tester) async {
    final proposal = _proposal(
      operationId: 'createPipeline',
      tier: AiWriteTier.t3,
      fields: const {
        'ref': 'main',
        'variables':
            '[{"key":"DEPLOY_TARGET","value":"staging"},'
            '{"key":"CFG","value":"x","variable_type":"file"}]',
      },
      preview: AiPipelinePreview(
        ref: 'main',
        newVariableNames: const ['DEPLOY_TARGET', 'CFG'],
      ),
    );
    await tester.pumpWidget(
      _host(
        AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
      ),
    );
    expect(find.text(l10n.aiFieldVariables), findsOneWidget);
    expect(
      find.text('DEPLOY_TARGET = staging\nCFG (file) = x'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('ai-proposal-field-ref')), findsNothing);
  });

  testWidgets('a delete card leaves its target to the preview', (tester) async {
    final proposal = _proposal(
      operationId: 'deleteBranch',
      tier: AiWriteTier.t4,
      fields: const {'branch': 'feature/old'},
      preview: const AiDeletePreview(targetName: 'feature/old'),
    );
    await tester.pumpWidget(
      _host(
        AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
      ),
    );
    expect(find.byKey(const ValueKey('ai-preview-delete')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('ai-proposal-field-branch')),
      findsNothing,
    );
  });

  testWidgets('a rerun card warns about stored variables once', (tester) async {
    final proposal = _proposal(
      operationId: 'retryPipeline',
      tier: AiWriteTier.t3,
      fields: const {},
      preview: AiPipelinePreview(ref: 'main', pipelineId: 1201),
    );
    await tester.pumpWidget(
      _host(
        AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
      ),
    );
    expect(
      find.byKey(const ValueKey('ai-preview-stored-variables')),
      findsOneWidget,
    );
    expect(find.text(l10n.aiProposalStoredVariables), findsNothing);
  });

  testWidgets('a rate-limit pause is shown once, by the status line', (
    tester,
  ) async {
    late CoordHarness h;
    late AiWriteProposal proposal;
    await tester.runAsync(() async {
      h = await CoordHarness.create();
      h.newRun('Comment on #3 in team/example-9');
      proposal = (await h.coordinator.propose(coordNoteCall('limited')))!;
    });
    addTearDown(() => tester.runAsync(h.dispose));
    // GitLab starts limiting between the render and the tap: the approval
    // itself finds the pause and marks the proposal paused.
    final writes = _Writes([proposal])
      ..answer = (_) {
        h.clientMayStart = false;
        h.coordinator.checkNow();
        return const AiWriteOutcome(
          state: AiJournalState.notExecuted,
          reasonCode: AiWritePause.clientUnavailable,
        );
      };
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: writes)),
    );
    expect(find.text(l10n.aiProposalPausedRateLimited), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ai-proposal-approve')));
    await tester.pumpAndSettle();
    expect(proposal.pausedReason, AiWritePause.clientUnavailable);
    expect(find.text(l10n.aiProposalPausedRateLimited), findsOneWidget);
  });

  testWidgets('a background pause on approve never claims the edit failed', (
    tester,
  ) async {
    final proposal = _proposal()..editedText = 'Edited words';
    final writes = _Writes([proposal])
      ..answer = (_) => const AiWriteOutcome(
        state: AiJournalState.notExecuted,
        reasonCode: AiWritePause.backgrounded,
      );
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: writes)),
    );
    await tester.tap(find.byKey(const ValueKey('ai-proposal-approve')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiProposalEditRefused), findsNothing);
    expect(find.text(l10n.aiProposalNotRun), findsNothing);
  });

  testWidgets('a card held by an account removal cannot be approved', (
    tester,
  ) async {
    late CoordHarness h;
    late AiWriteProposal proposal;
    await tester.runAsync(() async {
      h = await CoordHarness.create();
      h.newRun('Comment on #3 in team/example-9');
      proposal = (await h.coordinator.propose(coordNoteCall('held')))!;
      h.journal.beginRemoval(coordAccount);
      h.coordinator.checkNow();
    });
    addTearDown(() => tester.runAsync(h.dispose));
    expect(proposal.accountRemovalHeld, isTrue);
    await tester.pumpWidget(
      _host(
        AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
      ),
    );
    expect(find.text(l10n.aiProposalPausedRemoval), findsOneWidget);
    final approve = find.byKey(const ValueKey('ai-proposal-approve'));
    expect(tester.widget<ButtonStyleButton>(approve).onPressed, isNull);
  });

  testWidgets('an edited card that did not run keeps the text to copy', (
    tester,
  ) async {
    final proposal = _proposal()..editedText = 'My own careful words.';
    var dismissed = 0;
    await tester.pumpWidget(
      _host(
        AiSettledEditCard(proposal: proposal, onDismiss: () => dismissed++),
      ),
    );
    expect(find.text('My own careful words.'), findsOneWidget);
    expect(find.text(l10n.aiSettledEditKept), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ai-settled-edit-dismiss')));
    expect(dismissed, 1);
  });

  testWidgets('an edited card the user rejected says so', (tester) async {
    late CoordHarness h;
    late AiWriteProposal kept;
    await tester.runAsync(() async {
      h = await CoordHarness.create();
      h.newRun('Start a thread on #3 in team/example-9');
      final proposal = (await h.coordinator.propose(
        AiToolCall(
          id: 'thread',
          name: 'createDiscussion',
          arguments: const {
            'projectId': 9,
            'resource': 'issues',
            'iid': 3,
            'body': 'synthetic thread',
            'reason': 'The user asked for a thread.',
          },
        ),
      ))!;
      await h.coordinator.approve(proposal, editedText: 'my own words');
      await h.coordinator.reject(proposal);
      kept = h.coordinator.settledEdits.single;
    });
    addTearDown(() => tester.runAsync(h.dispose));
    expect(kept.outcome?.reasonCode, 'userRejected');
    await tester.pumpWidget(
      _host(AiSettledEditCard(proposal: kept, onDismiss: () {})),
    );
    expect(find.textContaining(l10n.aiSettledEditRejected), findsOneWidget);
  });

  testWidgets('an edited write that ran is never called not made', (
    tester,
  ) async {
    late CoordHarness h;
    late AiWriteProposal kept;
    await tester.runAsync(() async {
      h = await CoordHarness.create();
      h.newRun('Start a thread on #3 in team/example-9');
      final proposal = (await h.coordinator.propose(
        AiToolCall(
          id: 'thread',
          name: 'createDiscussion',
          arguments: const {
            'projectId': 9,
            'resource': 'issues',
            'iid': 3,
            'body': 'synthetic thread',
            'reason': 'The user asked for a thread.',
          },
        ),
      ))!;
      final edit = await h.coordinator.approve(
        proposal,
        editedText: 'my own thread words',
      );
      expect(edit.reasonCode, 'approvalRequired');
      final ran = await h.coordinator.approve(proposal);
      expect(ran.state, AiJournalState.succeeded);
      kept = h.coordinator.settledEdits.single;
    });
    addTearDown(() => tester.runAsync(h.dispose));
    await tester.pumpWidget(
      _host(AiSettledEditCard(proposal: kept, onDismiss: () {})),
    );
    expect(
      find.textContaining('${l10n.aiWriteStatusSucceeded} · '),
      findsOneWidget,
    );
    expect(find.text(l10n.aiSettledEditWritten), findsOneWidget);
    expect(find.textContaining(l10n.aiWriteStatusNotExecuted), findsNothing);
    expect(find.text(l10n.aiSettledEditKept), findsNothing);
  });

  testWidgets('a major write needs the exact name', (tester) async {
    final proposal = _proposal(
      operationId: 'updateMergeRequest',
      tier: AiWriteTier.t3,
      typedName: true,
      fields: const {'title': 'Draft: rename'},
    );
    final writes = _Writes([proposal]);
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: writes)),
    );
    expect(find.text(l10n.aiProposalStoredVariables), findsOneWidget);
    final approve = find.byKey(const ValueKey('ai-proposal-approve'));
    expect(tester.widget<ButtonStyleButton>(approve).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('ai-proposal-typed-name')),
      'team/other',
    );
    await tester.pump();
    expect(tester.widget<ButtonStyleButton>(approve).onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('ai-proposal-typed-name')),
      'team/example',
    );
    await tester.pump();
    await tester.tap(approve);
    await tester.pumpAndSettle();
    expect(writes.approvals.single.typedName, 'team/example');
  });

  testWidgets('the reasons it waits are spelled out', (tester) async {
    final proposal = _proposal(
      reasons: const [
        AiFixedConfirmReason.massMention,
        AiFixedConfirmReason.targetUnbound,
      ],
    );
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: _Writes([]))),
    );
    expect(find.text(l10n.aiConfirmMassMention), findsOneWidget);
    expect(find.text(l10n.aiConfirmTargetUnbound), findsOneWidget);
  });

  testWidgets('an edit is checked again and asks for a second approval', (
    tester,
  ) async {
    final proposal = _proposal();
    final writes = _Writes([proposal])
      ..answer = (edited) => AiWriteOutcome(
        state: AiJournalState.notExecuted,
        reasonCode: edited == null ? 'ok' : 'approvalRequired',
      );
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: writes)),
    );
    await tester.tap(find.byKey(const ValueKey('ai-proposal-edit')));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('ai-proposal-edit-text'));
    expect(
      tester.widget<TextField>(field).controller!.text,
      'Looks good.\nShip it.',
    );
    await tester.enterText(field, 'Looks good to me.');
    await tester.tap(find.byKey(const ValueKey('ai-proposal-edit-done')));
    await tester.pumpAndSettle();
    expect(writes.approvals.single.editedText, 'Looks good to me.');
    expect(find.text(l10n.aiProposalEdited), findsOneWidget);
  });

  testWidgets('reapplying the same card edit still requires approval', (
    tester,
  ) async {
    late CoordHarness h;
    late AiWriteProposal proposal;
    await tester.runAsync(() async {
      h = await CoordHarness.create();
      h.newRun('Comment on #3 in team/example-9');
      proposal = (await h.coordinator.propose(coordNoteCall('same-edit')))!;
    });
    addTearDown(() => tester.runAsync(h.dispose));
    late Future<AiWriteOutcome> Function() approval;
    final writes = _Writes([proposal])
      ..onApprove = (edited) {
        final done = Completer<AiWriteOutcome>();
        approval = () async {
          final result = await h.coordinator.approve(
            proposal,
            editedText: edited,
          );
          done.complete(result);
          return result;
        };
        return done.future;
      };
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: writes)),
    );
    final requestsAfterProposal = h.adapter.requests.length;
    const edited = 'My revised comment';
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.tap(find.byKey(const ValueKey('ai-proposal-edit')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('ai-proposal-edit-text'));
      if (attempt == 0) {
        await tester.enterText(field, edited);
      } else {
        expect(tester.widget<TextField>(field).controller!.text, edited);
      }
      await tester.tap(find.byKey(const ValueKey('ai-proposal-edit-done')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(writes.approvals, hasLength(attempt + 1));
      final result = await tester.runAsync(approval);
      await tester.pumpAndSettle();
      expect(result!.reasonCode, 'approvalRequired');
      expect(proposal.valid, isTrue);
      expect(h.coordinator.proposals, contains(proposal));
      expect(h.adapter.requests, hasLength(requestsAfterProposal));
      expect(h.mutations, 0);
    }
    await tester.tap(find.byKey(const ValueKey('ai-proposal-approve')));
    await tester.pump();
    final result = await tester.runAsync(approval);
    await tester.pump();
    expect(result!.state, AiJournalState.succeeded);
    expect(result.readbackConfirmed, isTrue);
    expect(result.mutationCount, 1);
    expect(h.mutations, 1);
    await tester.runAsync(() => h.coordinator.approve(proposal));
    expect(h.mutations, 1);
    expect(writes.approvals.map((call) => call.editedText), [
      edited,
      edited,
      null,
    ]);
  });

  testWidgets('reapplying a blocked card edit remains blocked', (tester) async {
    late CoordHarness h;
    late AiWriteProposal proposal;
    await tester.runAsync(() async {
      h = await CoordHarness.create();
      h.newRun('Comment on #3 in team/example-9');
      proposal = (await h.coordinator.propose(coordNoteCall('blocked-edit')))!;
    });
    addTearDown(() => tester.runAsync(h.dispose));
    late Future<AiWriteOutcome> Function() approval;
    final writes = _Writes([proposal])
      ..onApprove = (edited) {
        final done = Completer<AiWriteOutcome>();
        approval = () async {
          final result = await h.coordinator.approve(
            proposal,
            editedText: edited,
          );
          done.complete(result);
          return result;
        };
        return done.future;
      };
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: writes)),
    );
    final requestsAfterProposal = h.adapter.requests.length;
    const blocked = 'glpat-ABCDEFGHIJKLMNOPQRST';
    for (var attempt = 0; attempt < 2; attempt++) {
      await tester.tap(find.byKey(const ValueKey('ai-proposal-edit')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('ai-proposal-edit-text'));
      if (attempt == 0) {
        await tester.enterText(field, blocked);
      } else {
        expect(tester.widget<TextField>(field).controller!.text, blocked);
      }
      await tester.tap(find.byKey(const ValueKey('ai-proposal-edit-done')));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(writes.approvals, hasLength(attempt + 1));
      final result = await tester.runAsync(approval);
      await tester.pumpAndSettle();
      expect(result!.reasonCode, 'secret');
      expect(proposal.valid, isTrue);
      expect(h.adapter.requests, hasLength(requestsAfterProposal));
      expect(h.mutations, 0);
    }
  });

  testWidgets('closing the edit sheet does not refocus the composer', (
    tester,
  ) async {
    final proposal = _proposal();
    final writes = _Writes([proposal])
      ..answer = (edited) => AiWriteOutcome(
        state: AiJournalState.notExecuted,
        reasonCode: 'approvalRequired',
      );
    final composer = FocusNode();
    addTearDown(composer.dispose);
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            AiWriteProposalCard(proposal: proposal, session: writes),
            TextField(focusNode: composer, autofocus: true),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(composer.hasFocus, isTrue);
    for (final close in ['done', 'cancel']) {
      await tester.tap(find.byKey(const ValueKey('ai-proposal-edit')));
      await tester.pumpAndSettle();
      if (close == 'done') {
        await tester.tap(find.byKey(const ValueKey('ai-proposal-edit-done')));
      } else {
        await tester.tap(find.text(l10n.cancelAction));
      }
      await tester.pumpAndSettle();
      expect(composer.hasFocus, isFalse, reason: close);
      expect(tester.testTextInput.isVisible, isFalse, reason: close);
    }
  });

  testWidgets('a proposal that is no longer valid cannot be approved', (
    tester,
  ) async {
    final proposal = _proposal()..invalidate();
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: _Writes([]))),
    );
    expect(find.text(l10n.aiProposalInvalid), findsOneWidget);
    for (final key in ['ai-proposal-approve', 'ai-proposal-reject']) {
      expect(
        tester.widget<ButtonStyleButton>(find.byKey(ValueKey(key))).onPressed,
        isNull,
      );
    }
  });

  testWidgets('a refused approval says why', (tester) async {
    final proposal = _proposal();
    final writes = _Writes([proposal])
      ..answer = (_) => const AiWriteOutcome(
        state: AiJournalState.notExecuted,
        reasonCode: 'tooManyRunning',
      );
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: writes)),
    );
    await tester.tap(find.byKey(const ValueKey('ai-proposal-approve')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiProposalTooManyRunning), findsOneWidget);
  });

  testWidgets('an approval refused for background work says only what '
      'happened', (
    tester,
  ) async {
    final proposal = _proposal();
    final writes = _Writes([proposal])
      ..answer = (_) => const AiWriteOutcome(
        state: AiJournalState.notExecuted,
        reasonCode: 'executionPaused',
      );
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: writes)),
    );
    await tester.tap(find.byKey(const ValueKey('ai-proposal-approve')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiProposalBackgroundUnavailable), findsOneWidget);
    expect(find.text(l10n.aiProposalNotRun), findsNothing);
    // GLM M1: the run usually withdraws the proposal, so the text must not
    // claim it is still valid or ask to approve again.
    expect(
      l10n.aiProposalBackgroundUnavailable,
      isNot(anyOf(contains('有效'), contains('再核准'))),
    );
    // Calm, not an error: nothing was sent.
    final message = tester.widget<Text>(
      find.text(l10n.aiProposalBackgroundUnavailable),
    );
    final scheme = Theme.of(
      tester.element(find.byType(AiWriteProposalCard)),
    ).colorScheme;
    expect(message.style?.color, isNot(scheme.error));
    expect(find.byKey(const ValueKey('ai-proposal-approve')), findsOneWidget);
  });

  for (final (code, text) in [
    ('alreadyMerged', () => l10n.aiRefusedAlreadyMerged),
    ('headMoved', () => l10n.aiRefusedChanged),
    ('refMissing', () => l10n.aiRefusedGone),
    ('maintainerRequired', () => l10n.aiRefusedPermission),
    ('sensitivePath', () => l10n.aiRefusedContent),
    ('somethingNew', () => l10n.aiProposalNotRun),
  ]) {
    testWidgets('a write GitLab refused as $code says so', (tester) async {
      final proposal = _proposal();
      final writes = _Writes([proposal])
        ..answer = (_) => AiWriteOutcome(
          state: AiJournalState.failedCertain,
          reasonCode: code,
        );
      await tester.pumpWidget(
        _host(AiWriteProposalCard(proposal: proposal, session: writes)),
      );
      await tester.tap(find.byKey(const ValueKey('ai-proposal-approve')));
      await tester.pumpAndSettle();
      expect(find.text(text()), findsOneWidget);
    });
  }

  test('every refusal the write port names has words', () {
    // The codes MR6b-2's families and the coordinator return.
    for (final code in const [
      'targetChanged',
      'previewChanged',
      'draftsChanged',
      'settingsChanged',
      'superseded',
      'proposalInvalidated',
      'fileExists',
      'fileMissing',
      'fragmentNotFound',
      'fragmentNotUnique',
      'fragmentsOverlap',
      'releaseMissing',
      'tagMissing',
      'scheduleMissing',
      'containerMissing',
      'jobNotInPipeline',
      'packageNotDeletable',
      'projectArchived',
      'protectedBranch',
      'defaultBranch',
      'autoMergeNotEnabled',
      'mergeCheckIncomplete',
      'mergeCheckUnsupported',
      'autoMergeCancelError',
      'cancelEndpointUnavailable',
      'suggestionForeign',
      'suggestionNotAppliable',
      'personalNamespaceUnknown',
      'batchTooLarge',
      'binaryFile',
      'fileTooLarge',
      'invalidPath',
      'noEditableText',
      'pipelineVariableForbidden',
      'pipelineVariableSecret',
      'scheduleParamsUnreadable',
      'conflict',
      'snippetChanged',
      'snippetLastFile',
      'snippetBinary',
      'snippetTooLarge',
      'snippetPathInvalid',
      'snippetTooManyFiles',
      'snippetFilesUnreadable',
      'validation',
      'forbidden',
      'invisible',
      'unsupported',
      // MR6b-3 graph writes.
      'activityForbidden',
      'activityLocked',
      'activityUnverifiable',
      'anchorMismatch',
      'assigneeConflict',
      'assigneeForbidden',
      'assigneeInvalidSelection',
      'assigneeRejected',
      'datesConflict',
      'datesForbidden',
      'datesNotApplied',
      'healthConflict',
      'healthForbidden',
      'healthUnsupported',
      'incidentConflict',
      'incidentInvalidStatus',
      'incidentRejected',
      'intentUnclear',
      'milestoneConflict',
      'milestoneForbidden',
      'milestoneRejected',
      'notOwnNote',
      'labelUnknown',
      'noteChanged',
      'noteMissing',
      'notificationConflict',
      'notificationForbidden',
      'reactionConflict',
      'reactionForbidden',
      'registryUnavailable',
      'stateConflict',
      'stateForbidden',
      'stateNotApplied',
      'statusInvalidCandidate',
      'statusNotStarted',
      'statusStaleFence',
      'todoForeign',
      'todoNotFound',
      'todoUnsupportedTarget',
      'todoUnverifiable',
      'weightConflict',
      'weightForbidden',
      'weightRejected',
      'workItemUnverifiable',
      'rateLimited',
      'network',
      'invalidResponse',
    ]) {
      expect(aiRefusalText(code), isNotNull, reason: code);
    }
  });

  test('graph write titles name their direction and values their words', () {
    String title(String operationId, Map<String, String> fields) =>
        aiProposalTitle(_proposal(operationId: operationId, fields: fields));
    expect(
      title('setWorkItemActivityNoteReaction', {'add': 'true'}),
      l10n.aiOpAddAwardEmoji,
    );
    expect(
      title('setWorkItemActivityNoteReaction', {'add': 'false'}),
      l10n.aiOpRemoveAwardEmoji,
    );
    expect(
      title('setWorkItemNotifications', {'enabled': 'true'}),
      l10n.aiOpSubscribeOn,
    );
    expect(
      title('updateWorkItemState', {'stateEvent': 'close'}),
      l10n.closeWorkItem,
    );
    expect(
      title('updateWorkItemState', {'stateEvent': 'reopen'}),
      l10n.aiOpReopenWorkItem,
    );
    // The group aliases name the same directions; closing or reopening names
    // the group's work item, as its operation label does.
    for (final (operationId, fields, expected) in _groupDirectionTitles()) {
      expect(title(operationId, fields), expected, reason: operationId);
      expect(aiFieldInTitle(operationId, fields.keys.single), isTrue);
      // No direction: the title is the alias's own label, never the fallback.
      expect(title(operationId, const {}), aiOperationLabel(operationId));
      expect(title(operationId, const {}), isNot(l10n.aiOpUnknown));
    }
    expect(l10n.aiOpCloseGroupWorkItem, isNot(l10n.closeWorkItem));
    expect(l10n.aiOpReopenGroupWorkItem, isNot(l10n.aiOpReopenWorkItem));
    expect(aiFieldValue('healthStatus', 'onTrack'), l10n.healthOnTrack);
    expect(aiFieldValue('healthStatus', 'none'), l10n.clearHealthStatus);
    expect(aiFieldValue('mode', 'manual'), l10n.manualDates);
    expect(aiFieldValue('mode', 'inherited'), l10n.datesRolledUpFromHierarchy);
    expect(aiFieldValue('status', 'RESOLVED'), l10n.resolvedLabel);
    expect(aiFieldValue('stateEvent', 'reopen'), l10n.reopen);
    expect(aiFieldValue('assigneeUsernames', '["alice","bob"]'), 'alice, bob');
    expect(aiFieldValue('assigneeUsernames', 'not json'), 'not json');
  });

  testWidgets('an edit the checks refused can be changed again', (
    tester,
  ) async {
    final proposal = _proposal()
      ..editedText = 'token glpat-ABCDEFGHIJKLMNOPQRST';
    final writes = _Writes([proposal])
      ..answer = (_) => const AiWriteOutcome(
        state: AiJournalState.notExecuted,
        reasonCode: 'secretDetected',
      );
    await tester.pumpWidget(
      _host(AiWriteProposalCard(proposal: proposal, session: writes)),
    );
    await tester.tap(find.byKey(const ValueKey('ai-proposal-approve')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.aiProposalEditRefused), findsOneWidget);
    expect(find.text(l10n.aiProposalNotRun), findsNothing);
  });

  for (final (code, expected) in [
    ('quickAction', l10n.aiRefusedQuickAction),
    ('approvalExpired', l10n.aiProposalNotRun),
    ('proposalInvalidated', l10n.aiProposalInvalid),
    ('attachmentExpired', l10n.aiProposalNotRun),
    ('invalidProposal', l10n.aiProposalNotRun),
    ('accountChanged', l10n.aiProposalNotRun),
    ('settingsChanged', l10n.aiProposalNotRun),
    ('superseded', l10n.aiProposalNotRun),
    ('stopped', l10n.aiProposalNotRun),
    ('timeout', l10n.aiProposalNotRun),
    (AiWritePause.clientUnavailable, l10n.aiProposalPausedRateLimited),
    ('accountBlocked', l10n.aiProposalPausedRemoval),
    (AiWritePause.accountRemovalHeld, l10n.aiProposalPausedRemoval),
  ]) {
    for (final editing in [false, true]) {
      testWidgets(
        '$code shows its true reason on ${editing ? 'edit' : 'approval'} before the card refresh',
        (tester) async {
          final realPause = editing && code == AiWritePause.clientUnavailable;
          late final CoordHarness h;
          late final AiWriteProposal proposal;
          if (realPause) {
            await tester.runAsync(() async {
              h = await CoordHarness.create();
              addTearDown(() => tester.runAsync(h.dispose));
              h.newRun('Comment on #3 in team/example-9');
              proposal = (await h.coordinator.propose(
                coordNoteCall('table-pause'),
              ))!;
            });
            expect(proposal.pausedReason, isNull);
          } else {
            proposal = _proposal()..editedText = 'Edited words';
          }
          final writes = _Writes([proposal])
            ..answer = (_) => AiWriteOutcome(
              state: AiJournalState.notExecuted,
              reasonCode: code,
            );
          if (realPause) {
            writes.onApprove = (edited) {
              h.clientMayStart = false;
              return h.coordinator.approve(proposal, editedText: edited);
            };
          }
          await tester.pumpWidget(
            _host(AiWriteProposalCard(proposal: proposal, session: writes)),
          );
          if (editing) {
            await tester.tap(find.byKey(const ValueKey('ai-proposal-edit')));
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byKey(const ValueKey('ai-proposal-edit-text')),
              'New edited words',
            );
            await tester.tap(
              find.byKey(const ValueKey('ai-proposal-edit-done')),
            );
          } else {
            await tester.tap(find.byKey(const ValueKey('ai-proposal-approve')));
          }
          await tester.pumpAndSettle();
          // Pauses are card states, not refusal texts. An edit made during a
          // pause is not applied, so the edit path says so instead of
          // promising a later approval of text that was not kept.
          const pauses = {
            AiWritePause.clientUnavailable,
            AiWritePause.accountRemovalHeld,
            'accountBlocked',
          };
          final paused = pauses.contains(code);
          if (!paused) expect(aiRefusalText(code), expected);
          final shown = editing && paused ? l10n.aiProposalEditBlocked : expected;
          expect(find.text(shown), findsOneWidget);
          expect(find.text(l10n.aiProposalEditRefused), findsNothing);
          if (shown != l10n.aiProposalEditBlocked) {
            expect(find.text(l10n.aiProposalEditBlocked), findsNothing);
          }
          if (editing && paused) {
            if (realPause) {
              expect(proposal.pausedReason, AiWritePause.clientUnavailable);
              expect(proposal.editedText, isNull);
              expect(find.text(l10n.aiProposalPausedRateLimited), findsOneWidget);
              final message = find.byKey(const ValueKey('ai-proposal-message'));
              expect(message, findsOneWidget);
              expect(
                tester.widget<Text>(message).data,
                l10n.aiProposalEditBlocked,
              );
              final status = find.byKey(const ValueKey('ai-proposal-status'));
              expect(status, findsOneWidget);
              expect(
                tester.widget<Text>(status).data,
                l10n.aiProposalPausedRateLimited,
              );
            } else {
              expect(find.text(l10n.aiProposalPausedRateLimited), findsNothing);
            }
            expect(find.text(l10n.aiProposalPausedRemoval), findsNothing);
          }
          expect(find.text(l10n.aiRefusedChanged), findsNothing);
        },
      );
    }
  }

  for (final (tag, size) in [
    ('zh-TW', const Size(320, 640)),
    ('ar', const Size(320, 640)),
    ('en', const Size(640, 360)),
  ]) {
    testWidgets('the card fits $tag at 2x on ${size.width}x${size.height}', (
      tester,
    ) async {
      tester.view.physicalSize = size * tester.view.devicePixelRatio;
      addTearDown(tester.view.reset);
      if (tag != 'zh-TW') useLanguage(languageForTag(tag)!);
      addTearDown(() => useLanguage(languageForTag('zh-TW')!));
      final proposal = _proposal(
        operationId: 'setBoardSystemListHidden',
        tier: AiWriteTier.t3,
        typedName: true,
        reasons: const [AiFixedConfirmReason.confirmMarkAfterManualRelease],
      );
      await tester.pumpWidget(
        _host(
          AiWriteProposalCard(proposal: proposal, session: _Writes([])),
          tag: tag,
          scale: 2,
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }

  group('attachments', () {
    testWidgets('each file shows its name and size and can be removed', (
      tester,
    ) async {
      final notes = await _held(tester, 'notes.txt', List.filled(2048, 65));
      final removed = <String>[];
      await tester.pumpWidget(
        _host(AiAttachmentStrip(attachments: [notes], onRemove: removed.add)),
      );
      expect(find.textContaining('notes.txt'), findsOneWidget);
      expect(find.textContaining('2.0 KiB'), findsOneWidget);
      await tester.tap(find.byTooltip(l10n.aiAttachmentRemove));
      expect(removed, [notes.id]);
    });

    testWidgets('a file that says it is an image but is not still fits', (
      tester,
    ) async {
      final fake = await _held(
        tester,
        'shot.png',
        List.filled(64, 1),
        mediaType: 'image/png',
      );
      await tester.pumpWidget(
        _host(AiAttachmentStrip(attachments: [fake], onRemove: null)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip(l10n.aiAttachmentRemove), findsNothing);
    });

    test('every refusal has words, and a cancel says nothing', () {
      for (final status in AiAttachStatus.values) {
        final text = aiAttachFailureText(status);
        if (status == AiAttachStatus.stored ||
            status == AiAttachStatus.cancelled) {
          expect(text, isNull);
        } else {
          expect(text, isNotEmpty);
        }
      }
    });
  });

  group('the level button', () {
    testWidgets('offers levels up to the ceiling only', (tester) async {
      final writes = _ChatWrites();
      await tester.pumpWidget(_host(AiChatLevelButton(session: writes)));
      await tester.tap(find.byKey(const ValueKey('ai-chat-level')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('ai-level-conversationGrant')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('ai-level-bypass')), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('ai-level-conversationGrant')),
      );
      await tester.pumpAndSettle();
      expect(writes.autonomyLevel, AiAutonomyLevel.conversationGrant);
    });

    test('every level, tier, reason and status has words', () {
      for (final level in AiAutonomyLevel.values) {
        expect(aiLevelLabel(level), isNotEmpty);
      }
      for (final tier in AiWriteTier.values) {
        expect(aiTierLabel(tier), isNotEmpty);
      }
      for (final reason in AiFixedConfirmReason.values) {
        expect(aiConfirmReasonText(reason), isNotEmpty);
      }
      for (final status in AiWriteResultStatus.values) {
        expect(aiWriteStatusLabel(status), isNotEmpty);
      }
      // Every ledger row, including the three delivered §7t families.
      for (final row in ProductionAiLedger.rows) {
        expect(
          aiOperationLabel(row.operationId),
          isNot(l10n.aiOpUnknown),
          reason: row.operationId,
        );
      }
      // And every graph operation, including the fifteen group aliases whose
      // rows are still empty and hidden, so the loop above cannot reach them.
      expect(_groupAliases, hasLength(15));
      for (final operationId in {
        ...graphWriteRules.keys,
        ..._groupAliases.keys,
      }) {
        expect(
          aiOperationLabel(operationId),
          isNot(l10n.aiOpUnknown),
          reason: operationId,
        );
      }
      for (final key in [
        'title',
        'description',
        'body',
        'labels',
        'assigneeUsernames',
        'startDate',
        'dueDate',
        'healthStatus',
        'weight',
        'clearWeight',
        'stateEvent',
        'status',
        'mode',
        'clearStart',
        'clearDue',
        'clearMilestone',
        'milestoneTitle',
        'targetType',
        'until',
      ]) {
        expect(aiFieldLabel(key), isNot(key), reason: key);
      }
    });
  });

  group('group work-item aliases', () {
    test('the alias list is the one the write port classifies', () {
      expect(
        graphWriteRules.keys.where((id) => id.contains('GroupWorkItem')),
        unorderedEquals(_groupAliases.keys),
      );
      for (final project in _groupAliases.values) {
        expect(graphWriteRules, contains(project), reason: project);
      }
      // Snooze keeps its own ids and the incident status has no group form.
      expect(_groupAliases.values, isNot(contains('setIncidentStatus')));
      expect(_groupAliases.values, isNot(contains('snoozeTodo')));
      expect(_groupAliases.values, isNot(contains('unsnoozeTodo')));
    });

    test('every language names each alias, and the group work item where '
        'the project label names the work item', () {
      addTearDown(() => useLanguage(languageForTag('zh-TW')!));
      expect(appLanguages, hasLength(24));
      for (final language in appLanguages) {
        useLanguage(language);
        final named = _groupWorkItemLabels();
        for (final MapEntry(key: alias, value: project)
            in _groupAliases.entries) {
          final label = aiOperationLabel(alias);
          final reason = '${language.tag} $alias';
          expect(label.trim(), isNotEmpty, reason: reason);
          expect(label, isNot(l10n.aiOpUnknown), reason: reason);
          if (named[alias] case final expected?) {
            expect(label, expected, reason: reason);
            expect(label, isNot(aiOperationLabel(project)), reason: reason);
          } else {
            expect(label, aiOperationLabel(project), reason: reason);
          }
        }
        for (final (alias, fields, expected) in _groupDirectionTitles()) {
          final title = aiProposalTitle(
            _proposal(operationId: alias, fields: fields),
          );
          expect(title, expected, reason: '${language.tag} $alias $fields');
          expect(title, isNot(l10n.aiOpUnknown));
        }
        expect(
          {l10n.aiOpCloseGroupWorkItem, l10n.aiOpReopenGroupWorkItem},
          hasLength(2),
          reason: language.tag,
        );
        expect(l10n.aiOpCloseGroupWorkItem, isNot(l10n.closeWorkItem));
        expect(l10n.aiOpReopenGroupWorkItem, isNot(l10n.aiOpReopenWorkItem));
      }
    });

    test('Arabic labels read right to left and take no isolated values', () {
      addTearDown(() => useLanguage(languageForTag('zh-TW')!));
      final arabic = languageForTag('ar')!;
      expect(arabic.rtl, isTrue);
      useLanguage(arabic);
      // No alias label has a placeholder, so no value is wrapped in
      // U+2066…U+2069; a label that gains one must isolate it and change
      // this test. Each one starts with an Arabic letter, so the line takes
      // its direction from the label itself.
      final firstLetter = RegExp(r'\p{L}', unicode: true);
      final arabicLetter = RegExp(r'\p{Script=Arabic}', unicode: true);
      final isolates = RegExp(r'[\u2066-\u2069]');
      final shown = [
        for (final alias in _groupAliases.keys) aiOperationLabel(alias),
        for (final (_, _, title) in _groupDirectionTitles()) title,
      ];
      for (final text in shown) {
        expect(text, isNot(matches(isolates)), reason: text);
        final first = firstLetter.firstMatch(text)!.group(0)!;
        expect(first, matches(arabicLetter), reason: text);
      }
    });

    testWidgets('an Arabic group card names its direction right to left', (
      tester,
    ) async {
      useLanguage(languageForTag('ar')!);
      addTearDown(() => useLanguage(languageForTag('zh-TW')!));
      for (final (alias, fields, title) in _groupDirectionTitles()) {
        final proposal = _proposal(
          operationId: alias,
          tier: AiWriteTier.t1,
          fields: fields,
        );
        await tester.pumpWidget(
          _host(
            AiWriteProposalCard(
              proposal: proposal,
              session: _Writes([proposal]),
            ),
            tag: 'ar',
          ),
        );
        final shown = find.text(title);
        expect(shown, findsOneWidget, reason: '$alias $fields');
        expect(
          Directionality.of(tester.element(shown)),
          TextDirection.rtl,
          reason: alias,
        );
        expect(
          find.byKey(ValueKey('ai-proposal-field-${fields.keys.single}')),
          findsNothing,
          reason: alias,
        );
        expect(tester.takeException(), isNull);
      }
    });
  });
  // MR6b-3g full UI (§6.1): the group owner, full path and #iid on every
  // group card; own-note delete and own to-do wording; a missing feature
  // and a lost ownership proof read differently from a plain refusal.
  group('group work-item cards', () {
    const groupAlias = 'updateGroupWorkItemState';
    const ltrIsolate = '\u2068';
    const popIsolate = '\u2069';

    test('the owning group is read only from a group alias release name', () {
      expect(aiGroupWriteTarget(groupAlias, 'team/sub#5'), (
        path: 'team/sub',
        iid: 5,
      ));
      for (final alias in _groupAliases.keys) {
        expect(aiGroupWriteTarget(alias, 'a/b.c_d-e#12'), (
          path: 'a/b.c_d-e',
          iid: 12,
        ), reason: alias);
      }
      // A project write with the same shape, a to-do and an unknown id are
      // never a group's: the operation decides, not the text.
      for (final (operationId, name) in const [
        ('updateWorkItemState', 'team/sub#5'),
        ('createNote', 'team/sub#5'),
        ('snoozeTodo', '@alice'),
        ('notAnOperation', 'team/sub#5'),
      ]) {
        expect(aiGroupWriteTarget(operationId, name), isNull, reason: name);
      }
      // A name the port would never build, or one the redaction changed.
      for (final name in const [
        'team/sub',
        '#5',
        'team/sub#',
        'team/sub#0',
        'team/sub#05',
        'team/sub#+5',
        'team/sub#5x',
        'team/../sub#5',
        'team sub#5',
        '[REDACTED]#5',
        'team/sub#5#6',
      ]) {
        expect(aiGroupWriteTarget(groupAlias, name), isNull, reason: name);
      }
      expect(aiWriteTargetText(groupAlias, 'team/sub#5'), 'team/sub #5');
      expect(aiWriteTargetText('updateWorkItemState', '#5'), '#5');
      expect(aiOwnTodoUsername('snoozeTodo', '@alice'), 'alice');
      expect(aiOwnTodoUsername('unsnoozeTodo', '@alice'), 'alice');
      for (final (operationId, name) in const [
        ('markTodoDone', '@alice'),
        ('snoozeTodo', 'alice'),
        ('snoozeTodo', '@'),
        ('snoozeTodo', '@a b'),
      ]) {
        expect(aiOwnTodoUsername(operationId, name), isNull, reason: name);
      }
    });

    test('in Arabic the path and #iid are isolated one piece at a time', () {
      useLanguage(languageForTag('ar')!);
      addTearDown(() => useLanguage(languageForTag('zh-TW')!));
      expect(
        aiWriteTargetText(groupAlias, 'team/sub#5'),
        '${ltrIsolate}team/sub$popIsolate $ltrIsolate#5$popIsolate',
      );
      // Not one isolate around `team/sub#5`.
      expect(
        aiWriteTargetText(groupAlias, 'team/sub#5'),
        isNot(contains('team/sub#5')),
      );
      expect(
        aiFieldValue('labels', '["bug","ui"]'),
        '${ltrIsolate}bug$popIsolate, ${ltrIsolate}ui$popIsolate',
      );
    });

    testWidgets('every group alias card names its owning group and number', (
      tester,
    ) async {
      for (final alias in _groupAliases.keys) {
        final proposal = _proposal(
          operationId: alias,
          fields: const {},
          editableField: null,
          releaseName: 'team/sub#5',
        );
        await tester.pumpWidget(
          _host(
            AiWriteProposalCard(
              proposal: proposal,
              session: _Writes([proposal]),
            ),
          ),
        );
        final line = find.byKey(const ValueKey('ai-proposal-group-target'));
        expect(line, findsOneWidget, reason: alias);
        expect(
          tester.widget<Text>(line).data,
          l10n.aiProposalGroupTarget('team/sub', 5),
          reason: alias,
        );
        // The subtitle keeps only the tier; the raw `team/sub#5` never
        // shows, so it cannot read like a project path.
        expect(find.text(aiTierLabel(AiWriteTier.t2)), findsOneWidget);
        expect(find.textContaining('team/sub#5'), findsNothing, reason: alias);
        expect(tester.takeException(), isNull);
      }
      // A project work item keeps its one-line subtitle and no group line.
      final project = _proposal(
        operationId: 'updateWorkItemState',
        fields: const {},
        editableField: null,
        releaseName: '#5',
      );
      await tester.pumpWidget(
        _host(
          AiWriteProposalCard(proposal: project, session: _Writes([project])),
        ),
      );
      expect(
        find.byKey(const ValueKey('ai-proposal-group-target')),
        findsNothing,
      );
      expect(find.text('${aiTierLabel(AiWriteTier.t2)} · #5'), findsOneWidget);
    });

    testWidgets('the same number in another group reads differently', (
      tester,
    ) async {
      final first = _proposal(
        operationId: groupAlias,
        fields: const {'stateEvent': 'close'},
        editableField: null,
        releaseName: 'team/a#5',
      );
      final second = _proposal(
        operationId: groupAlias,
        fields: const {'stateEvent': 'close'},
        editableField: null,
        releaseName: 'team/b#5',
      );
      await tester.pumpWidget(
        _host(
          Column(
            children: [
              AiWriteProposalCard(proposal: first, session: _Writes([first])),
              AiWriteProposalCard(proposal: second, session: _Writes([second])),
            ],
          ),
        ),
      );
      expect(find.text(l10n.aiProposalGroupTarget('team/a', 5)), findsOne);
      expect(find.text(l10n.aiProposalGroupTarget('team/b', 5)), findsOne);
      expect(find.text(l10n.aiOpCloseGroupWorkItem), findsNWidgets(2));
    });

    testWidgets('deleting your own group comment names the owner, the '
        'author and the text, and needs the exact group name', (tester) async {
      final proposal = _proposal(
        operationId: 'deleteGroupWorkItemActivityNote',
        tier: AiWriteTier.t4,
        typedName: true,
        typedNameValue: 'team/sub#5',
        fields: const {},
        editableField: null,
        releaseName: 'team/sub#5',
        preview: const AiDeletePreview(
          targetName: '',
          path: 'team/sub',
          parentName: 'team/sub#5',
          author: '@alice',
          excerpt: 'An old synthetic comment.',
        ),
      );
      final writes = _Writes([proposal]);
      await tester.pumpWidget(
        _host(AiWriteProposalCard(proposal: proposal, session: writes)),
      );
      expect(find.text(l10n.aiOpDeleteOwnComment), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-proposal-own-note')),
        findsOneWidget,
      );
      expect(find.text(l10n.aiProposalDeleteOwnNote), findsOneWidget);
      expect(find.text(l10n.aiProposalGroupTarget('team/sub', 5)), findsOne);
      // The preview: the group (not a "path"), the parent as path and #iid,
      // the author, the text and that it cannot be undone.
      expect(find.text(l10n.groupLabel), findsOneWidget);
      expect(find.text(l10n.aiPreviewPath), findsNothing);
      expect(find.text('team/sub'), findsOneWidget);
      expect(find.text('team/sub #5'), findsOneWidget);
      expect(find.text('@alice'), findsOneWidget);
      expect(find.textContaining('An old synthetic comment.'), findsOne);
      expect(
        find.byKey(const ValueKey('ai-preview-cannot-undo')),
        findsOneWidget,
      );
      expect(find.text(l10n.aiProposalTypeName('team/sub#5')), findsOne);
      final approve = find.byKey(const ValueKey('ai-proposal-approve'));
      final typed = find.byKey(const ValueKey('ai-proposal-typed-name'));
      expect(tester.widget<ButtonStyleButton>(approve).onPressed, isNull);
      // The number alone, the path alone, another group or the project form
      // of the name never confirm a group delete.
      for (final wrong in const [
        '#5',
        'team/sub',
        'team/other#5',
        'team/sub#6',
      ]) {
        await tester.enterText(typed, wrong);
        await tester.pump();
        expect(
          tester.widget<ButtonStyleButton>(approve).onPressed,
          isNull,
          reason: wrong,
        );
      }
      // Direction marks copied from an Arabic interface still match.
      await tester.enterText(typed, '${ltrIsolate}team/sub#5$popIsolate');
      await tester.pump();
      await tester.tap(approve);
      await tester.pumpAndSettle();
      expect(writes.approvals.single.typedName, 'team/sub#5');
    });

    testWidgets('a project comment delete names the own-comment limit too', (
      tester,
    ) async {
      final proposal = _proposal(
        operationId: 'deleteWorkItemActivityNote',
        tier: AiWriteTier.t4,
        typedName: true,
        typedNameValue: '#5',
        fields: const {},
        editableField: null,
        releaseName: '#5',
        preview: const AiDeletePreview(
          targetName: '',
          path: 'team/app',
          parentName: '#5',
          author: '@alice',
        ),
      );
      await tester.pumpWidget(
        _host(
          AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
        ),
      );
      expect(find.text(l10n.aiProposalDeleteOwnNote), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-proposal-group-target')),
        findsNothing,
      );
      // A project's path keeps its own label.
      expect(find.text(l10n.aiPreviewPath), findsOneWidget);
      expect(find.text(l10n.groupLabel), findsNothing);
    });

    testWidgets('a to-do snooze says only your own to-do list changes', (
      tester,
    ) async {
      for (final operationId in const ['snoozeTodo', 'unsnoozeTodo']) {
        final proposal = _proposal(
          operationId: operationId,
          tier: AiWriteTier.t1,
          fields: operationId == 'snoozeTodo'
              ? const {'until': '2026-10-30T09:00:00Z'}
              : const {},
          editableField: null,
          releaseName: '@alice',
        );
        await tester.pumpWidget(
          _host(
            AiWriteProposalCard(
              proposal: proposal,
              session: _Writes([proposal]),
            ),
          ),
        );
        final line = find.byKey(const ValueKey('ai-proposal-own-todo'));
        expect(line, findsOneWidget, reason: operationId);
        expect(tester.widget<Text>(line).data, l10n.aiProposalOwnTodo('alice'));
        expect(tester.widget<Text>(line).data, contains('@alice'));
        expect(
          find.byKey(const ValueKey('ai-proposal-group-target')),
          findsNothing,
        );
      }
      final done = _proposal(
        operationId: 'markTodoDone',
        tier: AiWriteTier.t1,
        fields: const {},
        editableField: null,
        releaseName: '@alice',
      );
      await tester.pumpWidget(
        _host(AiWriteProposalCard(proposal: done, session: _Writes([done]))),
      );
      expect(find.byKey(const ValueKey('ai-proposal-own-todo')), findsNothing);
    });

    test('a missing feature and a lost ownership proof have their own words '
        'on a group alias only', () {
      for (final alias in _groupAliases.keys) {
        // The dates row's `unsupported` is D29's strict no-op refusal, not a
        // missing feature (FIX1 R2).
        expect(
          aiRefusalText('unsupported', operationId: alias),
          alias == 'updateGroupWorkItemDates'
              ? l10n.aiRefusedGroupDatesNotSent
              : l10n.aiRefusedGroupUnsupported,
          reason: alias,
        );
        expect(
          aiRefusalText('healthUnsupported', operationId: alias),
          l10n.aiRefusedGroupUnsupported,
        );
        expect(
          aiRefusalText('workItemUnverifiable', operationId: alias),
          l10n.aiRefusedGroupUnverifiable,
        );
        // Everything else keeps the shared sentence.
        expect(
          aiRefusalText('forbidden', operationId: alias),
          l10n.aiRefusedPermission,
        );
        expect(
          aiRefusalText('stateConflict', operationId: alias),
          l10n.aiRefusedChanged,
        );
        expect(aiRefusalText('somethingNew', operationId: alias), isNull);
      }
      for (final operationId in const [
        null,
        'updateWorkItemState',
        'snoozeTodo',
        'notAnOperation',
      ]) {
        expect(
          aiRefusalText('unsupported', operationId: operationId),
          l10n.aiRefusedNotAllowed,
          reason: operationId,
        );
        expect(
          aiRefusalText('workItemUnverifiable', operationId: operationId),
          l10n.aiRefusedUnverifiable,
        );
      }
      expect(l10n.aiRefusedGroupUnsupported, isNot(l10n.aiRefusedNotAllowed));
      // The project dates row keeps the shared sentence.
      expect(
        aiRefusalText('unsupported', operationId: 'updateWorkItemDates'),
        l10n.aiRefusedNotAllowed,
      );
    });

    // FIX1 R2: the group dates port passes the core's strict no-op refusal on
    // as `unsupported` (pinned by mr6b3g_dates_test "strict noop has journal
    // notExecuted, no write charge, and fail-stop": notExecuted, reason
    // `unsupported`, zero mutations). The card says the dates were not sent
    // and may already match, never that GitLab lacks the feature.
    testWidgets('a group dates no-op refusal says the dates may already '
        'match, not that the feature is missing', (tester) async {
      final proposal = _proposal(
        operationId: 'updateGroupWorkItemDates',
        fields: const {'mode': 'manual', 'startDate': '2026-10-05'},
        editableField: null,
        releaseName: 'team/sub#5',
      );
      final writes = _Writes([proposal])
        ..answer = (_) => const AiWriteOutcome(
          state: AiJournalState.notExecuted,
          reasonCode: 'unsupported',
        );
      await tester.pumpWidget(
        _host(AiWriteProposalCard(proposal: proposal, session: writes)),
      );
      await tester.tap(find.byKey(const ValueKey('ai-proposal-approve')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiRefusedGroupDatesNotSent), findsOneWidget);
      expect(find.text(l10n.aiRefusedGroupUnsupported), findsNothing);
      expect(find.text(l10n.aiRefusedNotAllowed), findsNothing);
    });

    testWidgets('a refused group approval says the feature is missing', (
      tester,
    ) async {
      final proposal = _proposal(
        operationId: 'updateGroupWorkItemHealthStatus',
        fields: const {'healthStatus': 'atRisk'},
        editableField: null,
        releaseName: 'team/sub#5',
      );
      final writes = _Writes([proposal])
        ..answer = (_) => const AiWriteOutcome(
          state: AiJournalState.notExecuted,
          reasonCode: 'healthUnsupported',
        );
      await tester.pumpWidget(
        _host(AiWriteProposalCard(proposal: proposal, session: writes)),
      );
      await tester.tap(find.byKey(const ValueKey('ai-proposal-approve')));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiRefusedGroupUnsupported), findsOneWidget);
      expect(find.text(l10n.aiRefusedNotAllowed), findsNothing);
    });

    test('label and assignee lists read as names; an empty list stays '
        'visible', () {
      expect(aiFieldValue('labels', '["bug","ui"]'), 'bug, ui');
      expect(aiFieldValue('labels', '[]'), '[]');
      expect(aiFieldValue('labels', 'not json'), 'not json');
      expect(aiFieldValue('labels', '[1,"ui"]'), '[1,"ui"]');
      expect(aiFieldValue('assigneeUsernames', '[]'), '[]');
    });

    testWidgets('a settled group edit names its group and number', (
      tester,
    ) async {
      final proposal = _proposal(
        operationId: 'editGroupWorkItemActivityNote',
        releaseName: 'team/sub#5',
      )..editedText = 'My own careful words.';
      await tester.pumpWidget(
        _host(AiSettledEditCard(proposal: proposal, onDismiss: () {})),
      );
      expect(
        find.text('${l10n.aiWriteStatusNotExecuted} · team/sub #5'),
        findsOneWidget,
      );
    });

    for (final (tag, scale) in const [
      ('zh-TW', 2.0),
      ('ar', 2.0),
      ('ar', 1.0),
    ]) {
      testWidgets('a long group path card fits 320dp in $tag at ${scale}x', (
        tester,
      ) async {
        useLanguage(languageForTag(tag)!);
        addTearDown(() => useLanguage(languageForTag('zh-TW')!));
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        const path =
            'synthetic-organisation/platform-division/mobile-applications-team';
        const name = '$path#4242';
        final proposal = _proposal(
          operationId: 'deleteGroupWorkItemActivityNote',
          tier: AiWriteTier.t4,
          typedName: true,
          typedNameValue: name,
          fields: const {},
          editableField: null,
          releaseName: name,
          preview: const AiDeletePreview(
            targetName: '',
            path: path,
            parentName: name,
            author: '@alice',
            excerpt: 'An old synthetic comment.',
          ),
        );
        await tester.pumpWidget(
          _host(
            AiWriteProposalCard(
              proposal: proposal,
              session: _Writes([proposal]),
            ),
            tag: tag,
            scale: scale,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final line = find.byKey(const ValueKey('ai-proposal-group-target'));
        expect(line, findsOneWidget);
        final text = tester.widget<Text>(line).data!;
        expect(text, l10n.aiProposalGroupTarget(path, 4242));
        if (tag == 'ar') {
          expect(Directionality.of(tester.element(line)), TextDirection.rtl);
          // Path and `#4242` are separate isolates, never one `path#4242`.
          expect(text, contains('$ltrIsolate$path$popIsolate'));
          expect(text, contains('$ltrIsolate#4242$popIsolate'));
          expect(text, isNot(contains(name)));
        }
        // Everything the user acts on is reachable at this size.
        for (final key in const [
          'ai-proposal-typed-name',
          'ai-proposal-approve',
          'ai-proposal-reject',
        ]) {
          await tester.ensureVisible(find.byKey(ValueKey(key)));
          expect(tester.takeException(), isNull, reason: key);
        }
      });
    }

    test('every language words the group card, scope and result lines', () {
      addTearDown(() => useLanguage(languageForTag('zh-TW')!));
      expect(appLanguages, hasLength(24));
      for (final language in appLanguages) {
        useLanguage(language);
        final reason = language.tag;
        for (final text in [
          l10n.aiProposalGroupTarget('team/sub', 5),
          l10n.aiChatEmptyGroup('team/sub', 5),
          l10n.aiRemovedGroupWorkItem('team/sub', 5),
        ]) {
          expect(text, contains('team/sub'), reason: reason);
          // The sigil and number stay together, isolated as one in Arabic.
          expect(
            text,
            contains(language.rtl ? '$ltrIsolate#5$popIsolate' : '#5'),
            reason: reason,
          );
        }
        final ownTodo = l10n.aiProposalOwnTodo('alice');
        expect(
          ownTodo,
          contains(language.rtl ? '$ltrIsolate@alice$popIsolate' : '@alice'),
          reason: reason,
        );
        for (final text in [
          l10n.aiProposalDeleteOwnNote,
          l10n.aiRefusedGroupUnsupported,
          l10n.aiRefusedGroupUnverifiable,
          l10n.aiConsentWritesGroupScope,
          l10n.aiChatEmptyGroupItem,
          l10n.aiSuggestWorkItemSummary,
        ]) {
          expect(text.trim(), isNotEmpty, reason: reason);
        }
        // Each one says something the shared sentence does not.
        expect(
          l10n.aiRefusedGroupUnsupported,
          isNot(l10n.aiRefusedNotAllowed),
          reason: reason,
        );
        expect(
          l10n.aiRefusedGroupUnverifiable,
          isNot(l10n.aiRefusedUnverifiable),
          reason: reason,
        );
        // FIX1: the dates no-op sentence and the added-items scope lines.
        expect(
          {
            l10n.aiRefusedGroupDatesNotSent,
            l10n.aiRefusedGroupUnsupported,
            l10n.aiRefusedNotAllowed,
          },
          hasLength(3),
          reason: reason,
        );
        expect(
          l10n.aiChatEmptyGroupAdded('team/sub', 5),
          allOf(
            contains('team/sub'),
            contains(language.rtl ? '$ltrIsolate#5$popIsolate' : '#5'),
            isNot(l10n.aiChatEmptyGroup('team/sub', 5)),
          ),
          reason: reason,
        );
        expect(
          l10n.aiChatEmptyGroupItemAdded,
          isNot(l10n.aiChatEmptyGroupItem),
          reason: reason,
        );
        expect(
          l10n.aiSuggestWorkItemSummary,
          isNot(l10n.aiSuggestIssueSummary),
          reason: reason,
        );
        if (language.tag != 'en') {
          expect(
            l10n.aiProposalGroupTarget('team/sub', 5),
            isNot(_englishGroupTarget),
            reason: reason,
          );
        }
      }
    });
  });

  group('field change markers on the confirmation card', () {
    testWidgets(
      'renders changed, unchanged and unknown field rows with semantics',
      (tester) async {
        final handle = tester.ensureSemantics();
        final proposal = _proposal(
          operationId: 'updateIssue',
          fields: const {
            'title': 'Rewritten title',
            'labels': 'ux, mobile',
            'description': 'Updated prose body',
            'state_event': 'reopen',
          },
          fieldChanges: const {
            'title': AiFieldChange.changed(
              previous: 'Keep release notes concise',
            ),
            'labels': AiFieldChange.unchanged(),
            'description': AiFieldChange.changed(),
            'state_event': AiFieldChange.unknown(),
          },
          editableField: 'description',
          releaseName: '#7',
        );
        await tester.pumpWidget(
          _host(
            AiWriteProposalCard(
              proposal: proposal,
              session: _Writes([proposal]),
            ),
          ),
        );

        final titleChange = find.byKey(
          const ValueKey('ai-proposal-change-title'),
        );
        expect(titleChange, findsOneWidget);
        expect(
          find.descendant(
            of: titleChange,
            matching: find.text(l10n.aiProposalFieldChanged),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: titleChange, matching: find.byIcon(Icons.edit)),
          findsOneWidget,
        );
        final titlePrev = find.byKey(
          const ValueKey('ai-proposal-previous-title'),
        );
        expect(titlePrev, findsOneWidget);
        expect(
          tester.widget<Text>(titlePrev).data,
          l10n.aiProposalFieldPrevious('Keep release notes concise'),
        );
        expect(
          tester
              .getSemantics(
                find.byKey(const ValueKey('ai-proposal-field-title')),
              )
              .label,
          allOf(
            contains(l10n.title),
            contains(l10n.aiProposalFieldChanged),
            contains('Rewritten title'),
          ),
        );

        final labelsChange = find.byKey(
          const ValueKey('ai-proposal-change-labels'),
        );
        expect(labelsChange, findsOneWidget);
        expect(
          find.descendant(
            of: labelsChange,
            matching: find.text(l10n.aiProposalFieldUnchanged),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('ai-proposal-previous-labels')),
          findsNothing,
        );
        expect(
          tester
              .getSemantics(
                find.byKey(const ValueKey('ai-proposal-field-labels')),
              )
              .label,
          allOf(
            contains(l10n.labelNoun),
            contains(l10n.aiProposalFieldUnchanged),
          ),
        );

        // Description is prose: changed marker is shown, never a previous line.
        expect(
          find.byKey(const ValueKey('ai-proposal-change-description')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('ai-proposal-previous-description')),
          findsNothing,
        );

        // Action field has no marker and no previous line.
        expect(
          find.byKey(const ValueKey('ai-proposal-change-state_event')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('ai-proposal-previous-state_event')),
          findsNothing,
        );
        handle.dispose();
      },
    );

    testWidgets('a yes/no previous value reads like the proposed one', (
      tester,
    ) async {
      final proposal = _proposal(
        operationId: 'updateIssue',
        fields: const {'confidential': 'true'},
        fieldChanges: const {
          'confidential': AiFieldChange.changed(previous: 'false'),
        },
        editableField: null,
        releaseName: '#7',
      );
      await tester.pumpWidget(
        _host(
          AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
        ),
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('ai-proposal-field-confidential')),
            )
            .data,
        l10n.yesLabel,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('ai-proposal-previous-confidential')),
            )
            .data,
        l10n.aiProposalFieldPrevious(l10n.noLabel),
      );
    });

    testWidgets('a field without a comparison keeps the plain row', (
      tester,
    ) async {
      final proposal = _proposal(
        operationId: 'updateIssue',
        fields: const {'title': 'Rewritten title', 'labels': 'ux'},
        fieldChanges: const {'labels': AiFieldChange.unknown()},
        editableField: null,
        releaseName: '#7',
      );
      await tester.pumpWidget(
        _host(
          AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
        ),
      );
      for (final key in ['title', 'labels']) {
        final value = find.byKey(ValueKey('ai-proposal-field-$key'));
        expect(value, findsOneWidget);
        expect(
          tester.widget<Text>(value).style,
          Theme.of(tester.element(value)).textTheme.bodySmall,
        );
        expect(
          find.ancestor(of: value, matching: find.byType(MergeSemantics)),
          findsNothing,
          reason: key,
        );
        expect(find.byKey(ValueKey('ai-proposal-change-$key')), findsNothing);
        expect(find.byKey(ValueKey('ai-proposal-previous-$key')), findsNothing);
      }
      expect(find.text(l10n.aiProposalFieldChanged), findsNothing);
      expect(find.text(l10n.aiProposalFieldUnchanged), findsNothing);
    });

    testWidgets('wraps the previous value in bidi isolates under Arabic', (
      tester,
    ) async {
      useLanguage(languageForTag('ar')!);
      addTearDown(() => useLanguage(languageForTag('zh-TW')!));
      const oldTitle = 'Keep release notes !44';
      final proposal = _proposal(
        operationId: 'updateIssue',
        fields: const {'title': 'New title'},
        fieldChanges: const {
          'title': AiFieldChange.changed(previous: oldTitle),
        },
        editableField: null,
        releaseName: '#7',
      );
      await tester.pumpWidget(
        _host(
          AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
          tag: 'ar',
        ),
      );
      final prev = find.byKey(const ValueKey('ai-proposal-previous-title'));
      expect(prev, findsOneWidget);
      final rendered = tester.widget<Text>(prev).data!;
      const ltrIsolate = '\u2068';
      const popIsolate = '\u2069';
      // The Arabic message isolates its argument by itself; the inner pair
      // is the card's own isolated(), without which this fails.
      expect(
        rendered,
        contains('$ltrIsolate$ltrIsolate$oldTitle$popIsolate$popIsolate'),
      );
    });

    testWidgets('an old title that reads true or false is shown as it is', (
      tester,
    ) async {
      final proposal = _proposal(
        operationId: 'updateIssue',
        fields: const {'title': 'Ship it', 'confidential': 'false'},
        fieldChanges: const {
          'title': AiFieldChange.changed(previous: 'false'),
          'confidential': AiFieldChange.changed(previous: 'true'),
        },
        editableField: null,
        releaseName: '#7',
      );
      await tester.pumpWidget(
        _host(
          AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
        ),
      );
      String previous(String key) => tester
          .widget<Text>(find.byKey(ValueKey('ai-proposal-previous-$key')))
          .data!;
      expect(previous('title'), l10n.aiProposalFieldPrevious('false'));
      expect(
        previous('confidential'),
        l10n.aiProposalFieldPrevious(l10n.yesLabel),
      );
    });

    testWidgets('prose and set fields never show an old value', (tester) async {
      final proposal = _proposal(
        operationId: 'updateIssue',
        fields: const {
          'description': 'New body',
          'labels': 'ux',
          'assignee_ids': '[7]',
        },
        // Even if a comparison carried one, the card leaves it out.
        fieldChanges: const {
          'description': AiFieldChange.changed(previous: 'Old body'),
          'labels': AiFieldChange.changed(previous: 'bug'),
          'assignee_ids': AiFieldChange.changed(previous: '[1]'),
        },
        editableField: null,
        releaseName: '#7',
      );
      await tester.pumpWidget(
        _host(
          AiWriteProposalCard(proposal: proposal, session: _Writes([proposal])),
        ),
      );
      for (final key in ['description', 'labels', 'assignee_ids']) {
        expect(
          find.byKey(ValueKey('ai-proposal-change-$key')),
          findsOneWidget,
          reason: key,
        );
        expect(
          find.byKey(ValueKey('ai-proposal-previous-$key')),
          findsNothing,
          reason: key,
        );
      }
      expect(find.textContaining('Old body'), findsNothing);
    });
  });
}

const _englishGroupTarget = 'Work item #5, owned directly by group team/sub';

/// The level button reads the session through [AiChatSession]; only the
/// write members matter here.
final class _ChatWrites extends _Writes implements AiChatSession {
  _ChatWrites() : super(const []);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
