import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';

AiToolRunItem _writeItem(AiWriteResultStatus writeStatus) => AiToolRunItem(
  name: 'create_note',
  argsPreview: '!12',
  status: writeStatus.legacyStatus,
  sizeChars: 24,
  provenance: 'merge request !12',
  resultExcerpt: 'Synthetic write result',
  writeStatus: writeStatus,
);

Map<String, Object?> _legacyToolJson() => {
  'kind': 'tool',
  'name': 'get_issue',
  'argsPreview': '#3',
  'status': 'completed',
  'sizeChars': 12,
  'provenance': 'issue #3',
  'truncated': false,
  'blocked': false,
  'resultExcerpt': 'Synthetic issue',
};

void main() {
  test('§15 row 15: format 2 round-trips every write result', () {
    final conversation = AiConversation(
      items: [
        for (final status in AiWriteResultStatus.values) _writeItem(status),
      ],
    );

    final json = aiDisplayJson(conversation);
    final restored = aiDisplayFromJson(json);

    expect(aiHistoryLegacyDisplayFormatVersion, 1);
    expect(aiHistoryDisplayFormatVersion, 2);
    expect(aiHistoryDisplayVersionFor(conversation), 2);
    expect(json['formatVersion'], 2);
    expect(
      restored.items.cast<AiToolRunItem>().map((item) => item.writeStatus),
      AiWriteResultStatus.values,
    );
    expect(aiDisplayJson(restored), json);
  });

  test('§15 row 15: nested display v2 keeps cipher envelope v1', () async {
    final key = AiHistoryCipher.newKey();
    final display = aiDisplayJson(
      AiConversation(items: [_writeItem(AiWriteResultStatus.succeeded)]),
    );

    final encrypted = await AiHistoryCipher.encryptJson(
      display,
      key,
      'account',
      'conversation.v1.bin',
    );
    final decrypted = await AiHistoryCipher.decryptJson(
      encrypted,
      key,
      'account',
      'conversation.v1.bin',
    );

    expect(encrypted.first, 1);
    expect(decrypted['formatVersion'], 2);
    expect(
      (aiDisplayFromJson(decrypted).items.single as AiToolRunItem).writeStatus,
      AiWriteResultStatus.succeeded,
    );
  });

  test('§15 row 15: legacy format 1 remains readable byte-for-byte', () {
    final legacy = {
      'items': [_legacyToolJson()],
    };

    final restored = aiDisplayFromJson(legacy);

    expect(aiHistoryDisplayVersionFor(restored), 1);
    expect((restored.items.single as AiToolRunItem).writeStatus, isNull);
    expect(aiDisplayJson(restored), legacy);
  });

  test('§15 row 15: legacy and unsupported formats reject write detail', () {
    final version2 = aiDisplayJson(
      AiConversation(items: [_writeItem(AiWriteResultStatus.succeeded)]),
    );

    expect(
      () => aiDisplayFromJson({...version2}..remove('formatVersion')),
      throwsA(isA<AiHistoryUnsupportedFormat>()),
    );
    expect(
      () => aiDisplayFromJson({...version2, 'formatVersion': 3}),
      throwsA(isA<AiHistoryUnsupportedFormat>()),
    );
    expect(
      () => aiDisplayFromJson({...version2, 'formatVersion': 1}),
      throwsA(isA<AiHistoryUnsupportedFormat>()),
    );
  });

  test('§15 row 15: mismatched legacy and write statuses fail closed', () {
    final mismatch = _writeItem(AiWriteResultStatus.writeUncertain);
    expect(
      () => aiDisplayJson(
        AiConversation(
          items: [
            AiToolRunItem(
              name: mismatch.name,
              argsPreview: mismatch.argsPreview,
              status: AiToolRunStatus.completed,
              sizeChars: mismatch.sizeChars,
              provenance: mismatch.provenance,
              resultExcerpt: mismatch.resultExcerpt,
              writeStatus: mismatch.writeStatus,
            ),
          ],
        ),
      ),
      throwsA(isA<AiHistoryUnsupportedFormat>()),
    );
    expect(
      () => aiDisplayFromJson({
        'formatVersion': 2,
        'items': [
          {..._legacyToolJson(), 'writeStatus': 'write_uncertain'},
        ],
      }),
      throwsA(isA<AiHistoryUnsupportedFormat>()),
    );
  });

  test('§15 row 15: malformed and unknown write results fail closed', () {
    for (final invalid in <Object?>[
      'accepted',
      '',
      null,
      true,
      1,
      <Object?>[],
      <String, Object?>{},
    ]) {
      expect(
        () => aiDisplayFromJson({
          'formatVersion': 2,
          'items': [
            {..._legacyToolJson(), 'writeStatus': invalid},
          ],
        }),
        throwsA(isA<AiHistoryUnsupportedFormat>()),
        reason: 'writeStatus=$invalid must not be accepted',
      );
    }
  });

  test('§15 row 28: write results map safely for exhaustive legacy UI', () {
    expect(
      AiWriteResultStatus.notExecuted.legacyStatus,
      AiToolRunStatus.skipped,
    );
    expect(
      AiWriteResultStatus.succeeded.legacyStatus,
      AiToolRunStatus.completed,
    );
    expect(
      AiWriteResultStatus.readbackConfirmed.legacyStatus,
      AiToolRunStatus.completed,
    );
    expect(
      AiWriteResultStatus.failedCertain.legacyStatus,
      AiToolRunStatus.failed,
    );
    expect(
      AiWriteResultStatus.writeUncertain.legacyStatus,
      AiToolRunStatus.failed,
    );
    expect(
      AiWriteResultStatus.resolvedByUser.legacyStatus,
      AiToolRunStatus.skipped,
    );
    expect(
      AiWriteResultStatus.noChange.legacyStatus,
      AiToolRunStatus.completed,
    );
  });
}
