import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';

void main() {
  group('AI history display codec', () {
    test('truncates without splitting UTF-16 and marks assistant text', () {
      final user = AiConversation(
        items: [AiUserItem(text: '${'a' * 15999}😀')],
      );
      final assistant = AiConversation(
        items: [
          AiAssistantItem(
            text: '${'a' * 63999}😀',
            state: AiAssistantState.done,
          ),
        ],
      );

      final userText =
          ((aiDisplayJson(user)['items']! as List).single as Map)['text']!
              as String;
      final assistantText =
          ((aiDisplayJson(assistant)['items']! as List).single as Map)['text']!
              as String;

      expect(userText.length, 15999);
      expect(userText.codeUnits.last, isNot(inInclusiveRange(0xd800, 0xdbff)));
      expect(assistantText.length, lessThanOrEqualTo(64000));
      expect(assistantText, endsWith('…'));
      expect(
        assistantText.codeUnits[assistantText.length - 2],
        isNot(inInclusiveRange(0xd800, 0xdbff)),
      );
    });

    test('uses stable enum wire codes', () {
      final value = aiDisplayJson(
        AiConversation(
          items: const [
            AiAssistantItem(text: 'answer', state: AiAssistantState.done),
            AiToolRunItem(
              name: 'read',
              argsPreview: '{}',
              status: AiToolRunStatus.completed,
              sizeChars: 2,
              provenance: 'synthetic',
            ),
            AiNoticeItem(AiNoticeKind.settingsChanged),
          ],
        ),
      );
      final items = value['items']! as List<Object?>;

      expect((items[0]! as Map<String, Object?>)['state'], 'done');
      expect((items[1]! as Map<String, Object?>)['status'], 'completed');
      expect((items[2]! as Map<String, Object?>)['notice'], 'settings_changed');
    });

    test('rejects unknown keys at every decoded level', () {
      final validUser = <String, Object?>{
        'kind': 'user',
        'text': 'question',
        'chips': <Object?>[
          <String, Object?>{
            'source': 'issue',
            'preview': 'preview',
            'sizeChars': 7,
            'blocked': false,
            'type': null,
            'resource': null,
            'pinnedSha': null,
          },
        ],
      };
      final validAssistant = <String, Object?>{
        'kind': 'assistant',
        'text': 'answer',
        'state': 'done',
        'usage': <String, Object?>{
          'inputTokens': 1,
          'outputTokens': 2,
          'cacheCreationInputTokens': null,
          'cacheReadInputTokens': null,
        },
      };

      for (final value in <Map<String, Object?>>[
        <String, Object?>{'items': <Object?>[], 'providerReplay': 'secret'},
        <String, Object?>{
          'items': <Object?>[
            <String, Object?>{...validUser, 'providerOutput': 'x'},
          ],
        },
        <String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              ...validUser,
              'chips': <Object?>[
                <String, Object?>{
                  ...(validUser['chips']! as List).single
                      as Map<String, Object?>,
                  'unknown': true,
                },
              ],
            },
          ],
        },
        <String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              ...validAssistant,
              'usage': <String, Object?>{
                ...(validAssistant['usage']! as Map<String, Object?>),
                'providerTokens': 3,
              },
            },
          ],
        },
      ]) {
        expect(() => aiDisplayFromJson(value), throwsA(isA<Exception>()));
      }
    });

    test('rejects unknown enum codes as unsupported', () {
      expect(
        () => aiDisplayFromJson(<String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'kind': 'assistant',
              'text': 'answer',
              'state': 'renamed_state',
              'usage': null,
            },
          ],
        }),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('AI history cipher', () {
    test('binds the envelope version into AAD', () async {
      final encrypted = await AiHistoryCipher.encryptBytes(
        utf8.encode('authenticated'),
        List<int>.generate(32, (index) => index),
        'account',
        'file',
        nonce: List<int>.filled(12, 0),
      );
      final changedVersion = encrypted.toList()..first = 2;

      await expectLater(
        AiHistoryCipher.decryptBytes(
          changedVersion,
          List<int>.generate(32, (index) => index),
          'account',
          'file',
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('classifies authenticated JSON and versions as unsupported', () async {
      final key = List<int>.generate(32, (index) => index);
      const account = 'account';
      const file = 'file';
      final malformedJson = await AiHistoryCipher.encryptBytes(
        utf8.encode('{not-json'),
        key,
        account,
        file,
        nonce: List<int>.filled(12, 0),
      );
      await expectLater(
        AiHistoryCipher.decryptJson(malformedJson, key, account, file),
        throwsA(isA<AiHistoryUnsupportedFormat>()),
      );

      final versionTwo = await AiHistoryCipher.seal(
        utf8.encode('{}'),
        key,
        List<int>.filled(12, 0),
        utf8.encode(jsonEncode(<Object?>[2, account, file])),
      );
      await expectLater(
        AiHistoryCipher.decryptBytes(
          <int>[2, ...versionTwo.concatenation()],
          key,
          account,
          file,
        ),
        throwsA(isA<AiHistoryUnsupportedFormat>()),
      );
    });

    test('matches NIST GCM AES-256 Test Case 16 with AAD', () async {
      final box = await AiHistoryCipher.seal(
        _bytes(
          'd9313225f88406e5a55909c5aff5269a'
          '86a7a9531534f7da2e4c303d8a318a72'
          '1c3c0c95956809532fcf0e2449a6b525'
          'b16aedf5aa0de657ba637b39',
        ),
        _bytes(
          'feffe9928665731c6d6a8f9467308308'
          'feffe9928665731c6d6a8f9467308308',
        ),
        _bytes('cafebabefacedbaddecaf888'),
        _bytes('feedfacedeadbeeffeedfacedeadbeefabaddad2'),
      );

      expect(
        _hex(box.cipherText),
        '522dc1f099567d07f47f37a32a84427d'
        '643a8cdcbfe5c0c97598a2bd2555d1aa'
        '8cb08e48590dbb3da7b08b1056828838'
        'c5f61e6393ba7a0abcc9f662',
      );
      expect(_hex(box.mac.bytes), '76fc6ece0f4e1768cddf8853bb2d551b');
    });
  });
}

List<int> _bytes(String value) => [
  for (var index = 0; index < value.length; index += 2)
    int.parse(value.substring(index, index + 2), radix: 16),
];

String _hex(List<int> value) =>
    value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
