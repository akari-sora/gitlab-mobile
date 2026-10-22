import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/workspace/attachment_picker.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_write_settings.dart';
import 'package:gitlab_mobile/features/ai/ai_write_ui.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

AiWriteProposal _proposal({
  String operationId = 'createNote',
  AiWriteTier tier = AiWriteTier.t2,
  bool typedName = false,
  List<AiFixedConfirmReason> reasons = const [],
  Map<String, String> fields = const {'body': 'Looks good.\nShip it.'},
  String reason = 'You asked me to approve the review.',
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
      for (final row in ProductionAiLedger.rows) {
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
