import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/attachment_budget.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/workspace/attachment_picker.dart';

const String _payloadText = 'PAYLOAD-9f3c2a7b-NOT-METADATA';
final List<int> _payload = utf8.encode(_payloadText);
const String _tokenName = 'glpat-abcdefghijklmnopqrst';
const String _starName = 'star #12.png';

void main() {
  group('§15 row 23 attachment session', () {
    test('caps match the single-file, conversation, and process limits', () {
      expect(
        AiAttachmentSession.maxCountPerConversation,
        AiAttachmentBudget.maxCountPerConversation,
      );
      expect(AiAttachmentSession.maxCountPerConversation, 10);
      expect(AiAttachmentSession.maxBytesPerConversation, 50 * 1024 * 1024);
      expect(AiAttachmentSession.maxBytesPerProcess, 100 * 1024 * 1024);
      expect(GitLabApi.maxUploadBytes, 25 * 1024 * 1024);
    });

    test(
      '40 MiB used plus a known 25 MiB file reserves nothing and does not open',
      () async {
        final AiAttachmentBudget budget = AiAttachmentBudget();
        final AiAttachmentSession session = _session(budget);
        final AiAttachmentReservation? seed = budget.tryReserve(
          conversation: session.capacityKey,
          bytes: 40 * 1024 * 1024,
        );
        expect(seed, isNotNull);
        var opened = 0;
        final _ScriptedPicker picker = _ScriptedPicker(_unexpectedPick);
        final AiAttachResult result = await session.reserveAndRead(
          picker: picker,
          uploadToolInSegment: true,
          intake: AiAttachmentIntake(
            filename: 'big.bin',
            length: 25 * 1024 * 1024,
            open: () {
              opened += 1;
              return const Stream<List<int>>.empty();
            },
          ),
        );
        expect(result.reasonCode, 'attachmentCapacity');
        expect(result.attachment, isNull);
        expect(opened, 0);
        expect(picker.fileCalls, 0);
        expect(budget.conversationBytes(session.capacityKey), 40 * 1024 * 1024);
        session.discardAll();
      },
    );

    test(
      'unknown length under the remaining cap is stored and shrinks the hold',
      () async {
        final AiAttachmentBudget budget = AiAttachmentBudget(
          conversationByteLimit: 30,
          processByteLimit: 30,
        );
        final AiAttachmentSession session = _session(budget, fileCapBytes: 25);
        final AiAttachResult first = await session.reserveAndRead(
          picker: _ScriptedPicker(_unexpectedPick),
          uploadToolInSegment: true,
          intake: AiAttachmentIntake(
            filename: 'note.txt',
            length: null,
            mediaType: 'text/plain',
            open: () async* {
              yield <int>[1, 2, 3, 4, 5];
            },
          ),
        );
        expect(first.status, AiAttachStatus.stored);
        expect(budget.conversationBytes(session.capacityKey), 5);
        final AiAttachResult second = await session.reserveAndRead(
          picker: _ScriptedPicker(_unexpectedPick),
          uploadToolInSegment: true,
          intake: AiAttachmentIntake(
            filename: 'more.txt',
            length: 20,
            open: () async* {
              yield List<int>.filled(20, 7);
            },
          ),
        );
        expect(second.status, AiAttachStatus.stored);
        expect(budget.conversationBytes(session.capacityKey), 25);
        session.discardAll();
      },
    );

    test(
      'unknown length past the cap stops the stream and releases the hold',
      () async {
        final AiAttachmentBudget budget = AiAttachmentBudget();
        final AiAttachmentSession session = _session(budget, fileCapBytes: 4);
        final File copy = await _copyFile(<int>[9, 9, 9, 9, 9]);
        var pulls = 0;
        final AiAttachResult result = await session.reserveAndRead(
          picker: _ScriptedPicker(_unexpectedPick),
          uploadToolInSegment: true,
          intake: AiAttachmentIntake(
            filename: 'over.bin',
            length: null,
            pickedCopyPath: copy.path,
            open: () async* {
              pulls += 1;
              yield List<int>.filled(8, 9);
              pulls += 1;
              yield <int>[1];
            },
          ),
        );
        expect(result.reasonCode, 'attachmentTooLarge');
        expect(pulls, 1);
        expect(budget.processBytes, 0);
        expect(copy.existsSync(), isFalse);
        expect(session.lookup('att-1'), isNull);
        session.discardAll();
      },
    );

    test(
      'a second pick cannot share bytes already reserved by the first',
      () async {
        final AiAttachmentBudget budget = AiAttachmentBudget(
          conversationByteLimit: 25,
          processByteLimit: 100,
        );
        final AiAttachmentSession session = _session(budget, fileCapBytes: 25);
        final Completer<void> gate = Completer<void>();
        final _ScriptedPicker first = _ScriptedPicker(() async {
          await gate.future;
          return PickedAttachment(filename: 'a.txt', bytes: <int>[1, 2, 3, 4]);
        });
        final _ScriptedPicker second = _ScriptedPicker(() async {
          return PickedAttachment(filename: 'b.txt', bytes: <int>[5]);
        });
        final Future<AiAttachResult> firstRun = session.reserveAndRead(
          picker: first,
          uploadToolInSegment: true,
        );
        final Future<AiAttachResult> secondRun = session.reserveAndRead(
          picker: second,
          uploadToolInSegment: true,
        );
        final AiAttachResult denied = await secondRun;
        expect(denied.reasonCode, 'attachmentCapacity');
        expect(second.fileCalls, 0);
        expect(first.fileCalls, 1);
        gate.complete();
        final AiAttachResult stored = await firstRun;
        expect(stored.status, AiAttachStatus.stored);
        expect(budget.conversationBytes(session.capacityKey), 4);
        session.discardAll();
      },
    );

    test(
      'read failure releases the reservation and deletes the picker copy',
      () async {
        final AiAttachmentBudget budget = AiAttachmentBudget();
        final AiAttachmentSession session = _session(budget);
        final File copy = await _copyFile(_payload);
        final AiAttachResult result = await session.reserveAndRead(
          picker: _ScriptedPicker(_unexpectedPick),
          uploadToolInSegment: true,
          intake: AiAttachmentIntake(
            filename: 'note.txt',
            length: _payload.length,
            pickedCopyPath: copy.path,
            open: () async* {
              yield _payload;
              throw Exception('disk');
            },
          ),
        );
        expect(result.reasonCode, 'attachmentReadFailed');
        expect(budget.processBytes, 0);
        expect(copy.existsSync(), isFalse);
        expect(session.capacityReason, isNull);
        session.discardAll();
      },
    );

    test(
      'a stored file deletes the picker copy and keeps bytes only in memory',
      () async {
        final AiAttachmentBudget budget = AiAttachmentBudget();
        final AiAttachmentSession session = _session(budget);
        final List<int> source = List<int>.of(_payload);
        final File copy = await _copyFile(source);
        final AiAttachResult result = await session.reserveAndRead(
          picker: _ScriptedPicker(_unexpectedPick),
          uploadToolInSegment: true,
          intake: AiAttachmentIntake(
            filename: _starName,
            length: source.length,
            mediaType: 'image/png',
            pickedCopyPath: copy.path,
            open: () async* {
              yield source;
            },
          ),
        );
        expect(copy.existsSync(), isFalse);
        final AiStoredAttachment stored = result.attachment!;
        expect(stored.id, 'att-1');
        expect(stored.filename, _starName);
        expect(stored.bytes, _payload);
        expect(stored.mediaType, 'image/png');
        final Map<String, Object?> metadata = session.metadataForModel();
        final Map<String, Object?> journal = session.journalMetadata(
          stored.id,
          projectId: 9,
        )!;
        _expectNoBytes(metadata, _payload);
        _expectNoBytes(journal, _payload);
        expect(journal.keys.toSet(), <String>{
          'attachmentId',
          'releaseName',
          'sha256',
          'size',
          'mediaType',
          'conflictKey',
        });
        expect(journal['releaseName'], _starName);
        expect(journal['conflictKey'], <String>[
          'acct',
          'project:9',
          'upload',
          stored.sha256,
        ]);
        final String block = metadata['block']! as String;
        expect(block, contains('source="attachment_metadata"'));
        expect(block, contains('</gitlab_data>'));
        expect(metadata['source'], 'attachment_metadata');
        final Map<String, Object?> row =
            (metadata['attachments']! as List<Object?>).single
                as Map<String, Object?>;
        expect(row.keys.toSet(), <String>{
          'id',
          'filename',
          'size',
          'mediaType',
        });
        expect(row.containsKey('sha256'), isFalse);
        final List<int> kept = stored.bytes;
        session.discardAll();
        expect(kept, everyElement(0));
      },
    );

    test(
      'a segment without upload_attachment does not pick or reserve',
      () async {
        final AiAttachmentBudget budget = AiAttachmentBudget();
        final AiAttachmentSession session = _session(budget);
        final File copy = await _copyFile(<int>[1]);
        var opened = 0;
        final _ScriptedPicker picker = _ScriptedPicker(_unexpectedPick);
        final AiAttachResult result = await session.reserveAndRead(
          picker: picker,
          uploadToolInSegment: false,
          intake: AiAttachmentIntake(
            filename: 'a.txt',
            length: 1,
            pickedCopyPath: copy.path,
            open: () {
              opened += 1;
              return Stream<List<int>>.value(<int>[1]);
            },
          ),
        );
        expect(result.reasonCode, 'uploadToolDisabled');
        expect(picker.fileCalls, 0);
        expect(opened, 0);
        expect(budget.processBytes, 0);
        expect(copy.existsSync(), isFalse);
        session.discardAll();
      },
    );

    test('an illegal filename does not open the stream', () async {
      final AiAttachmentBudget budget = AiAttachmentBudget();
      final AiAttachmentSession session = _session(budget);
      var opened = 0;
      final AiAttachResult result = await session.reserveAndRead(
        picker: _ScriptedPicker(_unexpectedPick),
        uploadToolInSegment: true,
        intake: AiAttachmentIntake(
          filename: 'a/b.png',
          length: 1,
          open: () {
            opened += 1;
            return Stream<List<int>>.value(<int>[1]);
          },
        ),
      );
      expect(result.reasonCode, 'attachmentInvalidName');
      expect(opened, 0);
      expect(budget.processBytes, 0);
      expect(attachmentFilenameOk('..'), isFalse);
      expect(attachmentFilenameOk('notes..png'), isTrue);
      session.discardAll();
    });

    test('remove, discard, and account switch wipe bytes', () async {
      final AiAttachmentBudget budget = AiAttachmentBudget();
      final AiAttachmentSession kept = _session(
        budget,
        accountKey: 'acct-a',
        conversationId: 'keep',
      );
      final AiAttachmentSession other = _session(
        budget,
        accountKey: 'acct-b',
        conversationId: 'other',
      );
      final AiStoredAttachment left = await _store(kept, <int>[4, 5, 6]);
      final AiStoredAttachment gone = await _store(
        other,
        List<int>.of(_payload),
      );
      final List<int> retained = gone.bytes;
      other.remove(gone.id);
      expect(other.lookup(gone.id), isNull);
      expect(retained, everyElement(0));
      expect(other.resolveModelId(gone.id).reasonCode, 'attachmentExpired');
      expect(budget.conversationBytes(other.capacityKey), 0);
      expect(left.bytes, <int>[4, 5, 6]);

      final AiAttachmentSession first = _session(
        budget,
        accountKey: 'acct-switch',
        conversationId: 'one',
      );
      final AiAttachmentSession second = _session(
        budget,
        accountKey: 'acct-switch',
        conversationId: 'two',
      );
      final AiStoredAttachment one = await _store(first, <int>[8, 8]);
      final AiStoredAttachment two = await _store(second, <int>[9, 9]);
      final List<int> oneBytes = one.bytes;
      final List<int> twoBytes = two.bytes;
      AiAttachmentSession.discardAccount('acct-switch');
      expect(first.lookup(one.id), isNull);
      expect(second.lookup(two.id), isNull);
      expect(oneBytes, everyElement(0));
      expect(twoBytes, everyElement(0));
      expect(left.bytes, <int>[4, 5, 6]);
      expect(first.resolveModelId(one.id).reasonCode, 'attachmentExpired');
      final _ScriptedPicker picker = _ScriptedPicker(_unexpectedPick);
      final AiAttachResult closed = await first.reserveAndRead(
        picker: picker,
        uploadToolInSegment: true,
      );
      expect(closed.reasonCode, 'attachmentExpired');
      expect(picker.fileCalls, 0);
      kept.discardAll();
      other.discardAll();
    });

    test(
      'an upload in progress keeps its reservation until it finishes',
      () async {
        final AiAttachmentBudget budget = AiAttachmentBudget(
          countLimit: 1,
          conversationByteLimit: 10,
          processByteLimit: 10,
        );
        final AiAttachmentSession session = _session(budget, fileCapBytes: 10);
        final AiStoredAttachment stored = await _store(session, <int>[1, 2, 3]);
        final List<int> retained = stored.bytes;
        session.notePrepared(stored.id, projectId: 4);
        session.beginUpload(stored.id);
        session.remove(stored.id);
        expect(session.lookup(stored.id), isNotNull);
        expect(retained, <int>[1, 2, 3]);
        expect(session.takeInvalidations(), isEmpty);
        expect(budget.conversationCount(session.capacityKey), 1);
        final AiAttachResult blocked = await session.reserveAndRead(
          picker: _ScriptedPicker(_unexpectedPick),
          uploadToolInSegment: true,
          intake: _bytesIntake('b.txt', <int>[4]),
        );
        expect(blocked.reasonCode, 'attachmentCapacity');
        session.finishUpload(stored.id);
        expect(session.lookup(stored.id), isNull);
        expect(retained, everyElement(0));
        expect(budget.processBytes, 0);
        final AiStoredAttachment again = await _store(session, <int>[5]);
        expect(again.id, 'att-2');
        session.discardAll();
      },
    );

    test(
      'approval waits are not journaled and prepared rows carry no bytes',
      () async {
        final AiAttachmentBudget budget = AiAttachmentBudget();
        final AiAttachmentSession session = _session(budget);
        final AiStoredAttachment waiting = await _store(session, _payload);
        session.noteProposed(waiting.id);
        session.remove(waiting.id);
        final AiAttachmentInvalidation proposed = session
            .takeInvalidations()
            .single;
        expect(proposed.reasonCode, 'notExecuted');
        expect(proposed.journal, isFalse);
        _expectNoBytes(proposed.toJson(), _payload);

        final AiStoredAttachment prepared = await _store(session, _payload);
        session.notePrepared(prepared.id, projectId: 15);
        session.discardAll();
        final AiAttachmentInvalidation journaled = session
            .takeInvalidations()
            .single;
        expect(journaled.journal, isTrue);
        expect(journaled.reasonCode, 'notExecuted');
        expect(journaled.conflictKey, <String>[
          'acct',
          'project:15',
          'upload',
          prepared.sha256,
        ]);
        expect(journaled.releaseName, 'note.txt');
        _expectNoBytes(journaled.toJson(), _payload);
        expect(session.journalMetadata(prepared.id, projectId: 15), isNull);
      },
    );

    test('foreign, malformed, and URL attachment ids are rejected', () async {
      final AiAttachmentBudget budget = AiAttachmentBudget();
      final AiAttachmentSession session = _session(budget);
      final AiAttachmentSession other = _session(
        budget,
        conversationId: 'other',
      );
      final AiStoredAttachment stored = await _store(session, <int>[1]);
      expect(session.resolveModelId(stored.id).accepted, isTrue);
      expect(other.resolveModelId(stored.id).reasonCode, 'attachmentUnknown');
      expect(other.lookup(stored.id), isNull);
      for (final String id in <String>[
        'https://gitlab.example/uploads/abc/file.png',
        'not-an-id',
        'att-0',
        'att-01',
        '',
        '../att-1',
      ]) {
        expect(
          session.resolveModelId(id).reasonCode,
          'attachmentRejected',
          reason: id,
        );
        expect(session.lookup(id), isNull, reason: id);
      }
      session.discardAll();
      other.discardAll();
    });

    test(
      'filename iid and intent words stay out of bindTargets input',
      () async {
        final AiAttachmentSession session = _session(AiAttachmentBudget());
        await _store(session, _payload, filename: _starName);
        final String block = session.metadataForModel()['block']! as String;
        expect(block, contains(_starName));
        final String binding = session.textForTargetBinding(
          'upload the file\n$block',
        );
        expect(binding.contains(_starName), isFalse);
        expect(binding.contains('#12'), isFalse);
        expect(binding.contains('star'), isFalse);
        final AiBindingResult fromFile = _bind(binding);
        expect(fromFile.allBound, isFalse);
        expect(fromFile.intentAuthorizesLowRisk, isFalse);
        final AiBindingResult typed = _bind('star #12');
        expect(typed.allBound, isTrue);
        expect(typed.intentAuthorizesLowRisk, isTrue);
        expect(session.textForTargetBinding('star #12'), 'star #12');
        session.discardAll();
      },
    );

    test('a token-like filename is redacted for the model only', () async {
      final AiAttachmentSession session = _session(AiAttachmentBudget());
      final AiStoredAttachment stored = await _store(session, <int>[
        1,
        2,
      ], filename: _tokenName);
      expect(stored.filename, _tokenName);
      final String encoded = jsonEncode(session.metadataForModel());
      expect(encoded.contains(_tokenName), isFalse);
      expect(encoded, contains('[REDACTED]'));
      expect(
        session.journalMetadata(stored.id, projectId: 3)!['releaseName'],
        _tokenName,
      );
      session.discardAll();
    });

    test(
      'the same SHA-256 success forces confirmation and an unknown upload isolates',
      () async {
        final AiAttachmentSession session = _session(AiAttachmentBudget());
        final AiStoredAttachment stored = await _store(session, _payload);
        final String hash = stored.sha256;
        final AiPriorUpload success = AiPriorUpload(
          accountKey: 'acct',
          projectId: 9,
          sha256: hash,
          state: AiUploadRecordState.succeeded,
          releaseName: 'note.txt',
        );
        final AiUploadPlan duplicate = planAttachmentUpload(
          accountKey: 'acct',
          projectId: 9,
          sha256: hash,
          filename: 'note.txt',
          prior: <AiPriorUpload>[success],
        );
        expect(duplicate.forcesConfirmation, isTrue);
        expect(duplicate.blocked, isFalse);
        expect(duplicate.mayPropose, isTrue);
        expect(duplicate.reasonCodes, <String>['possibleDuplicate']);
        expect(duplicate.conflictKey, <String>[
          'acct',
          'project:9',
          'upload',
          hash,
        ]);

        final AiUploadPlan otherProject = planAttachmentUpload(
          accountKey: 'acct',
          projectId: 10,
          sha256: hash,
          filename: 'note.txt',
          prior: <AiPriorUpload>[success],
        );
        expect(otherProject.forcesConfirmation, isFalse);
        expect(otherProject.reasonCodes, isEmpty);

        final AiUploadPlan isolated = planAttachmentUpload(
          accountKey: 'acct',
          projectId: 9,
          sha256: hash,
          filename: 'note.txt',
          prior: <AiPriorUpload>[
            success,
            AiPriorUpload(
              accountKey: 'acct',
              projectId: 9,
              sha256: hash,
              state: AiUploadRecordState.writeUncertain,
              releaseName: 'note.txt',
            ),
          ],
        );
        expect(isolated.blocked, isTrue);
        expect(isolated.mayPropose, isFalse);
        expect(isolated.forcesConfirmation, isFalse);
        expect(isolated.reasonCodes, <String>['isolated']);

        final AiUploadPlan dispatching = planAttachmentUpload(
          accountKey: 'acct',
          projectId: 9,
          sha256: hash,
          filename: 'note.txt',
          prior: <AiPriorUpload>[
            AiPriorUpload(
              accountKey: 'acct',
              projectId: 9,
              sha256: hash,
              state: AiUploadRecordState.dispatching,
              releaseName: 'note.txt',
            ),
          ],
        );
        expect(dispatching.reasonCodes, <String>['isolated']);
        session.discardAll();
      },
    );

    test('reopen releases by the journal filename without attachment bytes', () {
      final String stored =
          '${List<String>.filled(180, 'a').join()}🎉مرحبا${List<String>.filled(40, 'b').join()}';
      final String typed = '\u2068$stored\u2069';
      expect(journalReleaseName(typed: typed, stored: stored), stored);
      expect(typed == stored, isFalse);
      expect(journalReleaseName(typed: 'a\u2068b', stored: 'ab'), 'ab');
      expect(journalReleaseName(typed: 'ab', stored: 'ac'), isNull);
      expect(journalReleaseName(typed: 'e\u0301', stored: 'é'), isNull);
      final AiUploadPlan reopened = planAttachmentUpload(
        accountKey: 'acct',
        projectId: 4,
        sha256: 'abc',
        filename: stored,
        prior: <AiPriorUpload>[
          AiPriorUpload(
            accountKey: 'acct',
            projectId: 4,
            sha256: 'abc',
            state: AiUploadRecordState.resolvedByUser,
            releaseName: stored,
            confirmMark: true,
          ),
        ],
      );
      expect(
        reopened.conflictKey,
        attachmentConflictKey(accountKey: 'acct', projectId: 4, sha256: 'abc'),
      );
      expect(reopened.reasonCodes, <String>['confirmMark']);
      expect(reopened.forcesConfirmation, isTrue);
      expect(reopened.releaseName, stored);
      expect(reopened.releaseName.length, stored.length);
    });

    test('public and internal warnings use the card or the audit row', () {
      const List<(AiAutonomyLevel, AiUploadNoticeSurface)> cases =
          <(AiAutonomyLevel, AiUploadNoticeSurface)>[
            (AiAutonomyLevel.confirmEach, AiUploadNoticeSurface.card),
            (AiAutonomyLevel.lowRiskAuto, AiUploadNoticeSurface.card),
            (AiAutonomyLevel.conversationGrant, AiUploadNoticeSurface.audit),
            (AiAutonomyLevel.bypass, AiUploadNoticeSurface.audit),
            (AiAutonomyLevel.readOnly, AiUploadNoticeSurface.none),
          ];
      for (final String visibility in <String>['public', 'INTERNAL']) {
        for (final (AiAutonomyLevel level, AiUploadNoticeSurface surface)
            in cases) {
          final AiUploadVisibilityNotice notice = uploadVisibilityNotice(
            visibility: visibility,
            level: level,
          );
          expect(notice.surface, surface, reason: '$visibility $level');
          expect(
            notice.reasonCode,
            surface == AiUploadNoticeSurface.none
                ? isNull
                : 'uploadReadersCanFetch',
          );
        }
      }
      expect(
        uploadVisibilityNotice(
          visibility: 'private',
          level: AiAutonomyLevel.bypass,
        ).surface,
        AiUploadNoticeSurface.none,
      );
    });

    test('AI upload send timeout follows size over 128 KiB/s', () {
      expect(aiUploadSendTimeout(0), const Duration(seconds: 15));
      expect(aiUploadSendTimeout(15 * 128 * 1024), const Duration(seconds: 15));
      expect(
        aiUploadSendTimeout(15 * 128 * 1024 + 1),
        const Duration(seconds: 16),
      );
      expect(
        aiUploadSendTimeout(25 * 1024 * 1024),
        const Duration(seconds: 200),
      );
      expect(aiUploadSendTimeout(241 * 128 * 1024), const Duration(minutes: 4));
    });

    test('eleven files and a full process are refused before open', () async {
      final AiAttachmentBudget budget = AiAttachmentBudget();
      final AiAttachmentSession session = _session(budget);
      for (var i = 0; i < 10; i++) {
        expect(
          budget.tryReserve(conversation: session.capacityKey, bytes: 0),
          isNotNull,
        );
      }
      var opened = 0;
      final AiAttachResult count = await session.reserveAndRead(
        picker: _ScriptedPicker(_unexpectedPick),
        uploadToolInSegment: true,
        intake: AiAttachmentIntake(
          filename: 'eleventh.txt',
          length: 1,
          open: () {
            opened += 1;
            return Stream<List<int>>.value(<int>[1]);
          },
        ),
      );
      expect(count.reasonCode, 'attachmentCapacity');
      expect(opened, 0);
      expect(session.capacityReason, 'attachmentCapacity');

      final AiAttachmentBudget process = AiAttachmentBudget();
      final AiAttachmentSession next = _session(
        process,
        conversationId: 'next',
      );
      expect(
        process.tryReserve(conversation: 'a', bytes: 50 * 1024 * 1024),
        isNotNull,
      );
      expect(
        process.tryReserve(conversation: 'b', bytes: 50 * 1024 * 1024),
        isNotNull,
      );
      var processOpens = 0;
      final AiAttachResult full = await next.reserveAndRead(
        picker: _ScriptedPicker(_unexpectedPick),
        uploadToolInSegment: true,
        intake: AiAttachmentIntake(
          filename: 'one.bin',
          length: 1,
          open: () {
            processOpens += 1;
            return Stream<List<int>>.value(<int>[1]);
          },
        ),
      );
      expect(full.reasonCode, 'attachmentCapacity');
      expect(processOpens, 0);
      session.discardAll();
      next.discardAll();
    });

    test('two sessions of one conversation share the count', () async {
      final AiAttachmentBudget budget = AiAttachmentBudget(
        countLimit: 1,
        conversationByteLimit: 100,
        processByteLimit: 100,
      );
      final AiAttachmentSession first = _session(budget);
      final AiAttachmentSession second = _session(budget);
      await _store(first, <int>[1]);
      final AiAttachResult denied = await second.reserveAndRead(
        picker: _ScriptedPicker(_unexpectedPick),
        uploadToolInSegment: true,
        intake: _bytesIntake('b.txt', <int>[2]),
      );
      expect(denied.reasonCode, 'attachmentCapacity');
      final AiAttachmentSession separate = _session(
        budget,
        conversationId: 'separate',
      );
      final AiStoredAttachment other = await _store(separate, <int>[3]);
      expect(other.id, 'att-1');
      first.discardAll();
      second.discardAll();
      separate.discardAll();
    });

    test('discard during a pick drops the reservation and the bytes', () async {
      final AiAttachmentBudget budget = AiAttachmentBudget();
      final AiAttachmentSession session = _session(budget);
      final Completer<void> gate = Completer<void>();
      final List<int> source = List<int>.of(_payload);
      final _ScriptedPicker picker = _ScriptedPicker(() async {
        await gate.future;
        return PickedAttachment(filename: 'a.txt', bytes: source);
      });
      final Future<AiAttachResult> pending = session.reserveAndRead(
        picker: picker,
        uploadToolInSegment: true,
      );
      session.discardAll();
      gate.complete();
      final AiAttachResult result = await pending;
      expect(result.reasonCode, 'attachmentExpired');
      expect(budget.processBytes, 0);
      expect(source, everyElement(0));
    });

    test(
      'photos use pickImage and a cancelled pick releases the hold',
      () async {
        final AiAttachmentBudget budget = AiAttachmentBudget();
        final AiAttachmentSession session = _session(budget);
        final _ScriptedPicker images = _ScriptedPicker(
          _unexpectedPick,
          onImage: () async =>
              PickedAttachment(filename: 'shot.jpg', bytes: <int>[1, 2]),
        );
        final AiAttachResult photo = await session.reserveAndRead(
          picker: images,
          uploadToolInSegment: true,
          pick: AiAttachmentPick.image,
        );
        expect(photo.status, AiAttachStatus.stored);
        expect(images.imageCalls, 1);
        expect(images.fileCalls, 0);
        final _ScriptedPicker cancel = _ScriptedPicker(() async => null);
        final AiAttachResult cancelled = await session.reserveAndRead(
          picker: cancel,
          uploadToolInSegment: true,
        );
        expect(cancelled.reasonCode, 'attachmentCancelled');
        expect(budget.conversationBytes(session.capacityKey), 2);
        session.discardAll();
      },
    );

    test('picker bytes above the reserved slice are not kept', () async {
      final AiAttachmentBudget budget = AiAttachmentBudget(
        conversationByteLimit: 10,
        processByteLimit: 10,
      );
      final AiAttachmentSession session = _session(budget, fileCapBytes: 10);
      expect(
        budget.tryReserve(conversation: session.capacityKey, bytes: 6),
        isNotNull,
      );
      final List<int> source = <int>[1, 2, 3, 4, 5];
      final AiAttachResult result = await session.reserveAndRead(
        picker: _ScriptedPicker(
          () async => PickedAttachment(filename: 'a.txt', bytes: source),
        ),
        uploadToolInSegment: true,
      );
      expect(result.reasonCode, 'attachmentCapacity');
      expect(budget.conversationBytes(session.capacityKey), 6);
      expect(session.lookup('att-1'), isNull);
      session.discardAll();
    });
  });
}

AiAttachmentSession _session(
  AiAttachmentBudget budget, {
  String accountKey = 'acct',
  String conversationId = 'conv',
  int? fileCapBytes,
}) {
  return AiAttachmentSession(
    accountKey: accountKey,
    conversationId: conversationId,
    budget: budget,
    fileCapBytes: fileCapBytes,
  );
}

AiAttachmentIntake _bytesIntake(String filename, List<int> bytes) {
  return AiAttachmentIntake(
    filename: filename,
    length: bytes.length,
    open: () async* {
      yield bytes;
    },
  );
}

Future<AiStoredAttachment> _store(
  AiAttachmentSession session,
  List<int> bytes, {
  String filename = 'note.txt',
}) async {
  final AiAttachResult result = await session.reserveAndRead(
    picker: _ScriptedPicker(_unexpectedPick),
    uploadToolInSegment: true,
    intake: _bytesIntake(filename, bytes),
  );
  expect(result.status, AiAttachStatus.stored);
  return result.attachment!;
}

Future<File> _copyFile(List<int> bytes) async {
  final Directory root = await Directory.systemTemp.createTemp('att-p8-');
  final File cached = File('${root.path}/tmp/picked.bin');
  await cached.parent.create(recursive: true);
  await cached.writeAsBytes(bytes);
  addTearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });
  return cached;
}

void _expectNoBytes(Object? value, List<int> secret) {
  expect(_containsBytes(value, secret), isFalse);
  final String encoded = jsonEncode(value);
  expect(encoded.contains(_payloadText), isFalse);
  expect(encoded.contains(base64Encode(secret)), isFalse);
}

bool _containsBytes(Object? value, List<int> secret) {
  if (value is Uint8List || value is List<int>) {
    final List<int> bytes = value as List<int>;
    if (bytes.length == secret.length) {
      var same = true;
      for (var i = 0; i < secret.length; i++) {
        if (bytes[i] != secret[i]) same = false;
      }
      if (same && secret.isNotEmpty) return true;
    }
  }
  if (value is List<Object?>) {
    for (final Object? item in value) {
      if (_containsBytes(item, secret)) return true;
    }
  } else if (value is Map<Object?, Object?>) {
    for (final MapEntry<Object?, Object?> entry in value.entries) {
      if (_containsBytes(entry.key, secret) ||
          _containsBytes(entry.value, secret)) {
        return true;
      }
    }
  }
  return false;
}

AiBindingResult _bind(String message) {
  return bindTargets(
    userMessage: message,
    restoredFromHistory: false,
    scope: AiWriteScope(
      accountKey: 'https://gitlab.example#7',
      grants: const <AiScopeGrant>[
        AiScopeGrant(
          kind: AiScopeKind.project,
          projectId: 9,
          projectPath: 'group/app',
        ),
      ],
    ),
    targets: <AiTargetRef>[
      AiTargetRef(
        kind: AiTargetKind.issue,
        projectId: 9,
        projectPath: 'group/app',
        iid: 12,
      ),
    ],
    interfaceLanguage: 'en',
    deviceLanguages: const <String>['en'],
    operationId: 'setStar',
    arguments: const <String, Object?>{'starred': true},
  );
}

final class _ScriptedPicker implements AttachmentPicker {
  _ScriptedPicker(this._onFile, {this.onImage});

  final Future<PickedAttachment?> Function() _onFile;
  final Future<PickedAttachment?> Function()? onImage;
  int fileCalls = 0;
  int imageCalls = 0;

  @override
  Future<PickedAttachment?> pickFile() {
    fileCalls += 1;
    return _onFile();
  }

  @override
  Future<PickedAttachment?> pickImage() {
    imageCalls += 1;
    final Future<PickedAttachment?> Function()? pick = onImage;
    if (pick == null) return Future<PickedAttachment?>.value();
    return pick();
  }
}

Future<PickedAttachment?> _unexpectedPick() async =>
    throw StateError('picker should not run');
