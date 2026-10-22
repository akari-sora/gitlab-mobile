import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/tools/attachment_budget.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/attachment_picker.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/fake_adapter.dart';
import '../support/workspace_fixture.dart';

const _payloadText = 'PAYLOAD-5d1e0c9a-NEVER-SENT';
const _tokenName = 'glpat-abcdefghijklmnopqrst.png';
const _metadataOpening = '<gitlab_data source="attachment_metadata"';

void main() {
  group('packet 10 conversation-lifetime attachments', () {
    test(
      'a file picked before the first send survives the send and a runner '
      'rebind, and is discarded with the conversation and on dispose',
      () async {
        final harness = await _Harness.create(
          requiresKey: true,
          picks: [_pick('note.txt'), _pick('second.txt')],
        );
        addTearDown(harness.dispose);
        final controller = harness.controller;
        final conversation = controller.id;

        final attached = await controller.attach(AiAttachmentPick.file);
        expect(attached.status, AiAttachStatus.stored);
        final stored = attached.attachment!;
        expect(stored.id, 'att-1');
        final session = controller.attachmentSession!;
        expect(session.conversationId, conversation);
        expect(controller.attachments.map((a) => a.id), ['att-1']);

        // The first send creates the runner and its write coordinator.
        await controller.send('first');
        expect(controller.failure, isNull);
        expect(harness.wireClients, 1);
        expect(identical(controller.attachmentSession, session), isTrue);
        expect(controller.attachments.map((a) => a.id), ['att-1']);
        expect(_userTexts(harness.requests.last).last, contains('"att-1"'));

        // A new key keeps the conversation and rebinds the runner's
        // recipient (replaceKeyRecipient) with a new wire client.
        await harness.settings.saveProviderKey(
          harness.provider.id,
          'synthetic-provider-key-0102',
          acknowledgeWarning: true,
        );
        await controller.recheck();
        expect(controller.id, conversation);
        expect(harness.wireClients, 2);
        expect(identical(controller.attachmentSession, session), isTrue);
        expect(controller.attachments.map((a) => a.id), ['att-1']);

        await controller.send('second');
        expect(controller.failure, isNull);
        // The new key starts a new segment: the earlier turn, block
        // included, is now escaped inside the conversation summary.
        final second = _userTexts(harness.requests.last).last;
        expect(second, contains('\n\nsecond\n\n$_metadataOpening'));
        expect(second, endsWith('</gitlab_data>'));
        expect(_occurrences(second, _metadataOpening), 1);
        expect(
          second,
          contains('&lt;gitlab_data source="attachment_metadata"'),
        );
        expect(
          second.substring(second.indexOf('second\n')),
          contains('"att-1"'),
        );
        expect(stored.bytes, utf8.encode(_payloadText));

        controller.startNewConversation();
        expect(controller.id, isNot(conversation));
        expect(controller.attachments, isEmpty);
        expect(session.lookup('att-1'), isNull);
        expect(session.resolveModelId('att-1').reasonCode, 'attachmentExpired');
        expect(stored.bytes.every((byte) => byte == 0), isTrue);
        expect(
          AiAttachmentBudget.shared.conversationBytes(session.capacityKey),
          0,
        );
        final next = controller.attachmentSession!;
        expect(identical(next, session), isFalse);
        expect(next.conversationId, controller.id);

        await _waitFor(() => controller.canSend);
        final again = await controller.attach(AiAttachmentPick.file);
        expect(again.status, AiAttachStatus.stored);
        final held = again.attachment!;
        controller.dispose();
        expect(controller.attachments, isEmpty);
        expect(held.bytes.every((byte) => byte == 0), isTrue);
        expect(next.resolveModelId(held.id).reasonCode, 'attachmentExpired');
        expect(
          AiAttachmentBudget.shared.conversationBytes(next.capacityKey),
          0,
        );
      },
    );

    for (final format in AiFormat.values) {
      test('${format.name} user turn carries exactly one metadata block, '
          'names redacted and no bytes', () async {
        final harness = await _Harness.create(
          format: format,
          picks: [
            _pick(_tokenName),
            _pick('diagram.png', type: 'image/png'),
          ],
        );
        addTearDown(harness.dispose);
        final controller = harness.controller;
        expect(
          (await controller.attach(AiAttachmentPick.file)).status,
          AiAttachStatus.stored,
        );
        expect(
          (await controller.attach(AiAttachmentPick.image)).status,
          AiAttachStatus.stored,
        );
        expect(harness.picker.fileCalls, 1);
        expect(harness.picker.imageCalls, 1);

        await controller.send('Please review these.');
        expect(controller.failure, isNull);

        final request = harness.requests.single;
        final turn = _userTexts(request).single;
        expect(turn, startsWith('Please review these.\n\n$_metadataOpening'));
        expect(_occurrences(turn, _metadataOpening), 1);
        expect(_occurrences(request, 'attachment_metadata'), 1);
        final block = turn.substring(turn.indexOf(_metadataOpening));
        expect(block, endsWith('</gitlab_data>'));
        expect(block, contains('att-1'));
        expect(block, contains('att-2'));
        expect(block, contains('[REDACTED]'));
        expect(block, contains('diagram.png'));
        expect(block, contains('image/png'));
        for (final leak in [
          'glpat-abcdefghijklmnopqrst',
          _payloadText,
          base64Encode(utf8.encode(_payloadText)),
        ]) {
          expect(request, isNot(contains(leak)), reason: leak);
        }

        // The visible message is the user's own text; each attachment
        // has a "What was sent" chip with its metadata row.
        final user = controller.items.whereType<AiUserItem>().single;
        expect(user.text, 'Please review these.');
        final chips = user.chips
            .where((chip) => chip.source == 'attachment_metadata')
            .toList();
        expect(chips, hasLength(2));
        expect(chips.map((chip) => chip.resource), [
          '[REDACTED]',
          'diagram.png',
        ]);
        for (final chip in chips) {
          expect(block, contains(chip.sentText!));
          expect(chip.sizeChars, chip.sentText!.length);
          expect(chip.sentText, isNot(contains(_payloadText)));
          expect(chip.sentText, isNot(contains('glpat-abcdefghij')));
        }
        // Still held for a later turn.
        expect(controller.attachments, hasLength(2));
      });

      test(
        '${format.name} without attachments sends byte-identical requests',
        () async {
          Future<List<String>> requests({
            required bool attachThenRemove,
          }) async {
            final harness = await _Harness.create(
              format: format,
              picks: [_pick('dropped.txt')],
            );
            addTearDown(harness.dispose);
            final controller = harness.controller;
            if (attachThenRemove) {
              final result = await controller.attach(AiAttachmentPick.file);
              expect(result.status, AiAttachStatus.stored);
              controller.removeAttachment(result.attachment!.id);
              expect(controller.attachments, isEmpty);
            }
            await controller.send('first');
            await controller.send('follow up');
            expect(controller.failure, isNull);
            expect(harness.requests, hasLength(2));
            final last = _userTexts(harness.requests.last);
            // The user turns are exactly what was typed.
            expect(last, ['first', 'follow up']);
            for (final request in harness.requests) {
              expect(request, isNot(contains('attachment_metadata')));
            }
            final user = controller.items.whereType<AiUserItem>().toList();
            expect(user.expand((item) => item.chips), isEmpty);
            return harness.requests;
          }

          expect(
            await requests(attachThenRemove: true),
            await requests(attachThenRemove: false),
          );
        },
      );
    }

    test('a filename intent word does not authorize a T1 write', () async {
      Future<_Harness> run(String text, {String? filename}) async {
        final harness = await _Harness.create(
          picks: [if (filename != null) _pick(filename)],
          provider: (call) => _sse(
            call == 1
                ? _call('setStar', {
                    'projectId': 42,
                    'starred': true,
                    'reason': 'Synthetic star.',
                  })
                : _answer(AiFormat.responses, 'Done'),
          ),
        );
        addTearDown(harness.dispose);
        if (filename != null) {
          expect(
            (await harness.controller.attach(AiAttachmentPick.file)).status,
            AiAttachStatus.stored,
          );
        }
        final running = harness.controller.send(text);
        await _waitFor(
          () =>
              harness.controller.phase == AiChatPhase.awaitingApproval ||
              harness.controller.phase == AiChatPhase.idle,
        );
        if (harness.controller.phase == AiChatPhase.awaitingApproval) {
          harness.proposal = harness.controller.proposals.single;
          await harness.controller.rejectWrite(harness.proposal!);
        }
        await running;
        return harness;
      }

      // Typed by the user, these words authorize the star.
      final typed = await run('star this project.txt');
      expect(typed.mutations, ['setStar']);
      expect(typed.proposal, isNull);

      final named = await run(
        'Here is a file.',
        filename: 'star this project.txt',
      );
      expect(named.mutations, isEmpty);
      final proposal = named.proposal!;
      expect(proposal.userUtterance, 'Here is a file.');
      expect(
        proposal.tier.reasons,
        contains(AiFixedConfirmReason.intentNotUnique),
      );
      // The model did receive the name.
      expect(
        _userTexts(named.requests.first).single,
        contains('star this project.txt'),
      );
    });

    test('a filename #12 does not bind the issue target', () async {
      Future<_Harness> run(String text, {String? filename}) async {
        final harness = await _Harness.create(
          picks: [if (filename != null) _pick(filename)],
          provider: (call) => _sse(
            call == 1
                ? _call('setSubscribed', {
                    'projectId': 42,
                    'resource': 'issues',
                    'iid': 12,
                    'subscribed': true,
                    'reason': 'Synthetic subscription.',
                  })
                : _answer(AiFormat.responses, 'Done'),
          ),
        );
        addTearDown(harness.dispose);
        if (filename != null) {
          expect(
            (await harness.controller.attach(AiAttachmentPick.file)).status,
            AiAttachStatus.stored,
          );
        }
        final running = harness.controller.send(text);
        await _waitFor(
          () =>
              harness.controller.phase == AiChatPhase.awaitingApproval ||
              harness.controller.phase == AiChatPhase.idle,
        );
        if (harness.controller.phase == AiChatPhase.awaitingApproval) {
          harness.proposal = harness.controller.proposals.single;
          await harness.controller.rejectWrite(harness.proposal!);
        }
        await running;
        return harness;
      }

      // Typed by the user, `#12` binds the issue and the write runs.
      final typed = await run('subscribe me to #12');
      expect(typed.mutations, ['setSubscribed']);
      expect(typed.proposal, isNull);

      final named = await run('subscribe me', filename: 'issue #12.png');
      expect(named.mutations, isEmpty);
      final proposal = named.proposal!;
      expect(proposal.userUtterance, 'subscribe me');
      expect(
        proposal.tier.reasons,
        contains(AiFixedConfirmReason.targetUnbound),
      );
      expect(
        _userTexts(named.requests.first).single,
        contains('issue #12.png'),
      );
    });

    group('canAttach and attach', () {
      test('match the upload tool the segment really carries', () async {
        for (final (label, tools, scoped, offered) in [
          ('project scope', true, true, true),
          ('no project scope', true, false, false),
          ('tools off', false, true, false),
        ]) {
          final harness = await _Harness.create(
            toolsEnabled: tools,
            projectScope: scoped,
            picks: [_pick('a.txt')],
          );
          addTearDown(harness.dispose);
          expect(harness.controller.canAttach, offered, reason: label);
          await harness.controller.send('hello');
          expect(
            _toolNames(harness.requests.single).contains('upload_attachment'),
            offered,
            reason: label,
          );
          expect(harness.controller.canAttach, offered, reason: label);
          final result = await harness.controller.attach(AiAttachmentPick.file);
          if (offered) {
            expect(result.status, AiAttachStatus.stored, reason: label);
          } else {
            expect(result.status, AiAttachStatus.disabled, reason: label);
            expect(result.reasonCode, 'uploadToolDisabled', reason: label);
            expect(harness.picker.fileCalls, 0, reason: label);
          }
        }
      });

      test('are disabled while a run is in progress', () async {
        final gate = Completer<void>();
        final harness = await _Harness.create(
          picks: [_pick('a.txt')],
          provider: (_) async {
            await gate.future;
            return _sse(_answer(AiFormat.responses, 'Done'));
          },
        );
        addTearDown(harness.dispose);
        final controller = harness.controller;
        expect(controller.canAttach, isTrue);

        final running = controller.send('hello');
        await _waitFor(() => harness.requests.isNotEmpty);
        expect(controller.phase, AiChatPhase.running);
        expect(controller.canAttach, isFalse);
        final result = await controller.attach(AiAttachmentPick.file);
        expect(result.status, AiAttachStatus.disabled);
        expect(result.reasonCode, 'conversationBusy');
        expect(harness.picker.fileCalls, 0);

        gate.complete();
        await running;
        expect(controller.canAttach, isTrue);
      });

      test('are disabled once the ceiling is read-only', () async {
        final harness = await _Harness.create(picks: [_pick('a.txt')]);
        addTearDown(harness.dispose);
        expect(harness.controller.canAttach, isTrue);

        await harness.settings.setAutonomySettings(
          harness.account,
          ceiling: AiAutonomyLevel.readOnly,
          startingLevel: AiAutonomyLevel.readOnly,
        );
        await harness.controller.recheck();
        expect(harness.controller.canAttach, isFalse);
        final result = await harness.controller.attach(AiAttachmentPick.file);
        expect(result.status, AiAttachStatus.disabled);
        expect(result.reasonCode, 'uploadToolDisabled');
        expect(harness.picker.fileCalls, 0);
      });

      test('a segment without the upload tool drops held files before the '
          'turn is composed', () async {
        final harness = await _Harness.create(picks: [_pick('a.txt')]);
        addTearDown(harness.dispose);
        final controller = harness.controller;
        final stored = (await controller.attach(
          AiAttachmentPick.file,
        )).attachment!;
        final session = controller.attachmentSession!;

        await harness.settings.setAutonomySettings(
          harness.account,
          ceiling: AiAutonomyLevel.readOnly,
          startingLevel: AiAutonomyLevel.readOnly,
        );
        await controller.recheck();
        await controller.send('hello');

        expect(controller.failure, isNull);
        expect(_userTexts(harness.requests.single), ['hello']);
        expect(harness.requests.single, isNot(contains('attachment_metadata')));
        expect(controller.attachments, isEmpty);
        expect(stored.bytes.every((byte) => byte == 0), isTrue);
        // The session stays open for the conversation; the id is spent.
        expect(identical(controller.attachmentSession, session), isTrue);
        expect(session.resolveModelId('att-1').reasonCode, 'attachmentExpired');
        expect(session.capacityReason, isNull);
      });

      test('a file still uploading when the upload tool goes is not named to '
          'the model', () async {
        final gate = Completer<void>();
        final harness = await _Harness.create(
          picks: [_pick('shot.png', type: 'image/png')],
          uploadGate: gate.future,
          provider: (call) => _sse(
            call == 1
                ? _call('upload_attachment', {
                    'projectId': 42,
                    'attachmentId': 'att-1',
                    'reason': 'The user attached this screenshot.',
                  })
                : _answer(AiFormat.responses, 'Done $call'),
          ),
        );
        addTearDown(harness.dispose);
        final controller = harness.controller;
        await controller.setAutonomyLevel(AiAutonomyLevel.confirmEach);
        expect(
          (await controller.attach(AiAttachmentPick.image)).status,
          AiAttachStatus.stored,
        );
        final running = controller.send('Upload my screenshot.');
        await _waitFor(() => controller.proposals.isNotEmpty);
        final approving = controller.approveWrite(controller.proposals.single);
        await _waitFor(() => harness.mutations.contains('upload_attachment'));
        // Stopped while the upload is on the wire: the conversation is
        // idle again but the upload keeps its bytes until it settles.
        controller.stop();
        await running;
        await _waitFor(() => controller.phase == AiChatPhase.idle);
        expect(controller.attachments.map((a) => a.id), ['att-1']);

        await harness.settings.setAutonomySettings(
          harness.account,
          ceiling: AiAutonomyLevel.readOnly,
          startingLevel: AiAutonomyLevel.readOnly,
        );
        await controller.recheck();
        final sent = harness.requests.length;
        await controller.send('hello');

        expect(harness.requests, hasLength(sent + 1));
        final turn = _userTexts(harness.requests.last).last;
        expect(turn, endsWith('hello'));
        expect(_occurrences(turn, _metadataOpening), 0);
        final user = controller.items.whereType<AiUserItem>().last;
        expect(user.text, 'hello');
        expect(
          user.chips.where((chip) => chip.source == 'attachment_metadata'),
          isEmpty,
        );

        gate.complete();
        await approving;
        expect(controller.attachments, isEmpty);
      });

      test('are disabled after dispose', () async {
        final harness = await _Harness.create(picks: [_pick('a.txt')]);
        addTearDown(harness.dispose);
        harness.controller.dispose();

        expect(harness.controller.canAttach, isFalse);
        expect(harness.controller.attachments, isEmpty);
        final result = await harness.controller.attach(AiAttachmentPick.file);
        expect(result.status, AiAttachStatus.disabled);
        expect(result.reasonCode, 'conversationClosed');
        expect(harness.picker.fileCalls, 0);
      });
    });

    test('removing an attachment invalidates the waiting upload proposal, '
        'which is never journaled', () async {
      final harness = await _Harness.create(
        picks: [_pick('shot.png', type: 'image/png')],
        provider: (call) => _sse(
          call == 1
              ? _call('upload_attachment', {
                  'projectId': 42,
                  'attachmentId': 'att-1',
                  'reason': 'The user attached this screenshot.',
                })
              : _answer(AiFormat.responses, 'Removed'),
        ),
      );
      addTearDown(harness.dispose);
      final controller = harness.controller;
      await controller.setAutonomyLevel(AiAutonomyLevel.confirmEach);
      expect(
        (await controller.attach(AiAttachmentPick.image)).status,
        AiAttachStatus.stored,
      );
      var notified = 0;
      controller.addListener(() => notified++);

      final running = controller.send('Upload my screenshot.');
      await _waitFor(() => controller.proposals.isNotEmpty);
      final proposal = controller.proposals.single;
      expect(proposal.operationId, 'upload_attachment');
      expect(controller.phase, AiChatPhase.awaitingApproval);
      expect(controller.canAttach, isFalse);
      final before = notified;

      controller.removeAttachment('att-1');

      expect(notified, greaterThan(before));
      expect(proposal.valid, isFalse);
      expect(controller.proposals, isEmpty);
      expect(controller.attachments, isEmpty);
      await running;

      expect(harness.mutations, isEmpty);
      expect(
        harness.journal
            .entries(harness.account)
            .where((entry) => entry.executionId == proposal.executionId),
        isEmpty,
      );
      expect(harness.journal.entries(harness.account), isEmpty);
      final row = controller.items.whereType<AiToolRunItem>().single;
      expect(row.writeStatus, AiWriteResultStatus.notExecuted);
      final invalidation = controller.attachmentSession!
          .takeInvalidations()
          .single;
      expect(invalidation.attachmentId, 'att-1');
      expect(invalidation.journal, isFalse);
      // The model was told the write did not run.
      expect(harness.requests, hasLength(2));
      expect(harness.requests.last, contains('write upload_attachment on'));
      expect(harness.requests.last, contains('notExecuted; attachmentExpired'));
    });
  });
}

Future<void> _waitFor(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(condition(), isTrue, reason: 'synthetic step did not complete');
}

int _occurrences(String text, String needle) {
  var count = 0;
  for (
    var at = text.indexOf(needle);
    at >= 0;
    at = text.indexOf(needle, at + 1)
  ) {
    count++;
  }
  return count;
}

/// The user turns of one encoded provider request, in order, for all three
/// formats: text parts only (tool results are not user text).
List<String> _userTexts(String request) {
  final body = jsonDecode(request) as Map<String, Object?>;
  final messages = (body['messages'] ?? body['input'])! as List<Object?>;
  return [
    for (final message in messages)
      if (message is Map<String, Object?> && message['role'] == 'user')
        ...switch (message['content']) {
          final String text => [text],
          final List<Object?> parts => [
            for (final part in parts)
              if (part is Map<String, Object?> && part['text'] is String)
                part['text']! as String,
          ],
          _ => const <String>[],
        },
  ];
}

List<String> _toolNames(String request) {
  final body = jsonDecode(request) as Map<String, Object?>;
  return [
    for (final tool in (body['tools'] as List<Object?>?) ?? const <Object?>[])
      if (tool is Map<String, Object?> && tool['name'] is String)
        tool['name']! as String,
  ];
}

PickedAttachment _pick(String filename, {String? type}) => PickedAttachment(
  filename: filename,
  bytes: Uint8List.fromList(utf8.encode(_payloadText)),
  contentType: type,
);

final class _Picker implements AttachmentPicker {
  _Picker(List<PickedAttachment?> picks) : _picks = List.of(picks);

  final List<PickedAttachment?> _picks;
  var imageCalls = 0;
  var fileCalls = 0;

  @override
  Future<PickedAttachment?> pickImage() async {
    imageCalls++;
    return _next();
  }

  @override
  Future<PickedAttachment?> pickFile() async {
    fileCalls++;
    return _next();
  }

  PickedAttachment? _next() => _picks.isEmpty ? null : _picks.removeAt(0);
}

final class _Harness {
  _Harness._({
    required this.root,
    required this.session,
    required this.settings,
    required this.journal,
    required this.provider,
    required this.picker,
    required this.account,
  });

  static Future<_Harness> create({
    AiFormat format = AiFormat.responses,
    bool toolsEnabled = true,
    bool requiresKey = false,
    bool projectScope = true,
    List<PickedAttachment?> picks = const [],
    FutureOr<ResponseBody> Function(int call)? provider,
    Future<void>? uploadGate,
  }) async {
    final workspace = WorkspaceFixture();
    workspace.issues[12] = workspace.issue(12, 'Synthetic twelve');
    final mutations = <String>[];
    final gitLabAdapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (request.method == 'POST') {
        if (path.endsWith('/projects/42/star')) mutations.add('setStar');
        if (path.endsWith('/subscribe')) mutations.add('setSubscribed');
        if (path.endsWith('/projects/42/uploads')) {
          mutations.add('upload_attachment');
        }
      }
      if (request.method == 'POST' && path.endsWith('/projects/42/star')) {
        return jsonResponse({
          ...workspace.projectRecord,
          'starred': true,
        }, status: 201);
      }
      if (uploadGate != null &&
          request.method == 'POST' &&
          path.endsWith('/projects/42/uploads')) {
        return uploadGate.then((_) => workspace.respond(request));
      }
      return workspace.respond(request);
    });
    final accounts = MemoryAccountStore()
      ..accounts = [workspace.account]
      ..lastActive = workspace.account.key;
    final session = controllerFor(accounts, gitLabAdapter);
    await session.initialize();
    final account = workspace.account.key;

    final settings = AiSettingsController(MemoryAiStore());
    await settings.initialize();
    final saved = await settings.saveProvider(
      _providerConfig(format, tools: toolsEnabled, requiresKey: requiresKey),
    );
    if (requiresKey) {
      await settings.saveProviderKey(
        saved.id,
        'synthetic-provider-key-0101',
        acknowledgeWarning: true,
      );
    }
    await settings.loadAccount(account);
    await settings.setAutonomySettings(
      account,
      ceiling: AiAutonomyLevel.lowRiskAuto,
      startingLevel: AiAutonomyLevel.lowRiskAuto,
    );
    // A write grant names the tool categories, so a provider with tools off
    // has the read-only disclosure.
    final contract = toolsEnabled
        ? settings.consentContractFor(
            account,
            saved,
            writePolicy: aiMr6b1WritePolicy(AiAutonomyLevel.lowRiskAuto),
            agreedCeiling: AiAutonomyLevel.lowRiskAuto,
          )
        : aiCurrentConsentContractFor(saved);
    await settings.grantConsent(account, contract, const {'synthetic': true});

    final root = Directory.systemTemp.createTempSync('packet10-attachments-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'packet10-attachments-test',
    );
    await journal.recoverAfterAccountsLoaded([account]);
    await journal.ensureInitialized(account);

    var providerCalls = 0;
    final providerAdapter = FakeAdapter((_) {
      providerCalls++;
      return provider?.call(providerCalls) ??
          _sse(_answer(format, 'Done $providerCalls'));
    });
    final picker = _Picker(picks);
    final harness = _Harness._(
      root: root,
      session: session,
      settings: settings,
      journal: journal,
      provider: saved,
      picker: picker,
      account: account,
    );
    harness._mutations = mutations;
    harness._providerAdapter = providerAdapter;
    harness.controller = AiChatController(
      origin: const AiGeneralOrigin(),
      session: session,
      settings: settings,
      runningCount: () => 0,
      appInForeground: () => true,
      clientMayStart: () => true,
      writeJournal: journal,
      attachmentPicker: picker,
      writeScope: () => AiWriteScope(
        accountKey: account,
        instance: workspace.api.instance,
        grants: [
          if (projectScope)
            AiScopeGrant(
              kind: AiScopeKind.project,
              projectId: workspace.project.id,
              projectPath: workspace.project.path,
            ),
        ],
      ),
      readWriteFreshness: (_) async =>
          const AiWriteFreshness(visibilityUnreadable: false),
      writePortFactory: () =>
          GitLabAiWritePort(session.api!, accountKey: account),
      wireClientFactory:
          ({required config, required apiKey, required conversationId}) {
            harness.wireClients++;
            return AiWireClient(
              transport: AiTransport(
                endpoint: AiEndpoint.parse(
                  config.baseUrl,
                  allowLanCleartext: false,
                ),
                apiKey: apiKey ?? '',
                authStyle: config.authStyle,
                adapter: providerAdapter,
              ),
              wire: switch (config.format) {
                AiFormat.chatCompletions => const ChatCompletionsFormat(),
                AiFormat.responses => const ResponsesFormat(),
                AiFormat.anthropicMessages => const AnthropicMessagesFormat(),
              },
              config: config,
              conversationId: conversationId,
              appVersion: 'test',
            );
          },
    );
    await harness.controller.recheck();
    expect(harness.controller.canSend, isTrue);
    return harness;
  }

  final Directory root;
  final SessionController session;
  final AiSettingsController settings;
  final AiWriteJournal journal;
  final AiProviderConfig provider;
  final _Picker picker;
  final String account;
  late final AiChatController controller;
  late final List<String> _mutations;
  late final FakeAdapter _providerAdapter;
  var wireClients = 0;
  AiWriteProposal? proposal;

  List<String> get mutations => List.unmodifiable(_mutations);

  /// Encoded provider request bodies, as sent.
  List<String> get requests => [
    for (final request in _providerAdapter.requests) request.data as String,
  ];

  void dispose() {
    controller.dispose();
    settings.dispose();
    session.dispose();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

AiProviderConfig _providerConfig(
  AiFormat format, {
  required bool tools,
  required bool requiresKey,
}) => AiProviderConfig(
  id: 'packet10-${format.name}',
  name: 'Packet 10 ${format.name}',
  presetId: 'custom',
  baseUrl: 'https://provider.example/v1',
  format: format,
  model: 'synthetic-model',
  authStyle: AiAuthStyle.bearer,
  caps: AiCaps(
    tokenLimitField: switch (format) {
      AiFormat.responses => AiTokenLimitField.maxOutputTokens,
      _ => AiTokenLimitField.maxTokens,
    },
    requiresKey: requiresKey,
    toolChoice: true,
  ),
  allowLanCleartext: false,
  toolsEnabled: tools,
  recipientRevision: 1,
);

ResponseBody _sse(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/event-stream'],
  },
);

String _data(Object value, {String? event}) =>
    '${event == null ? '' : 'event: $event\n'}data: ${jsonEncode(value)}\n\n';

String _call(String name, Map<String, Object?> arguments) => _data({
  'type': 'response.completed',
  'response': {
    'output': [
      {
        'type': 'function_call',
        'call_id': 'call-$name',
        'name': name,
        'arguments': jsonEncode(arguments),
        'status': 'completed',
      },
    ],
  },
});

String _answer(AiFormat format, String text) => switch (format) {
  AiFormat.responses => _data({
    'type': 'response.completed',
    'response': {
      'output': [
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': text},
          ],
        },
      ],
    },
  }),
  AiFormat.chatCompletions =>
    '${_data({
      'choices': [
        {
          'index': 0,
          'finish_reason': 'stop',
          'delta': {'content': text},
        },
      ],
    })}data: [DONE]\n\n',
  AiFormat.anthropicMessages =>
    '${_data({
          'type': 'message_start',
          'message': {
            'content': <Object?>[],
            'usage': {'input_tokens': 1, 'output_tokens': 0},
          },
        }, event: 'message_start')}'
        '${_data({
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': text},
        }, event: 'content_block_start')}'
        '${_data({'type': 'content_block_stop', 'index': 0}, event: 'content_block_stop')}'
        '${_data({
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': {'output_tokens': 2},
        }, event: 'message_delta')}'
        '${_data({'type': 'message_stop'}, event: 'message_stop')}',
};
