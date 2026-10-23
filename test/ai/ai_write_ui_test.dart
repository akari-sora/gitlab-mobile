import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
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
  String reason = 'You asked me to approve the review.',
  AiUploadPreview? upload,
  List<String> closingRefs = const [],
  AiWritePreview? preview,
  bool showSquash = false,
  String? editableField = 'body',
}) => AiWriteProposal(
  executionId: 'exec-1',
  operationId: operationId,
  tier: AiTierDecision(
    decision: AiGateDecision.requireApproval,
    tier: tier,
    requiresTypedName: typedName,
    typedName: typedName ? 'team/example' : null,
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
  releaseName: '!44',
  fields: fields,
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
    // createRelease edits its description; editProject has no editable text,
    // so a name-only edit would always be refused.
    for (final (operation, fields, editable, offered) in [
      (
        'createRelease',
        const {'tagName': 'v1.0', 'description': 'Notes'},
        'description',
        true,
      ),
      ('editProject', const {'name': 'Renamed'}, null, false),
      ('renameBoard', const {'name': 'Sprint'}, null, false),
      ('createIssue', const {'title': 'Only a title'}, 'description', false),
    ]) {
      final proposal = _proposal(
        operationId: operation,
        fields: fields,
        editableField: editable,
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
      'rateLimited',
      'network',
      'invalidResponse',
    ]) {
      expect(aiRefusalText(code), isNotNull, reason: code);
    }
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
      for (final row in productionAiLedger.modelVisible) {
        expect(
          aiOperationLabel(row.operationId),
          isNot(l10n.aiOpUnknown),
          reason: row.operationId,
        );
      }
    });
  });
}

/// The level button reads the session through [AiChatSession]; only the
/// write members matter here.
final class _ChatWrites extends _Writes implements AiChatSession {
  _ChatWrites() : super(const []);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
