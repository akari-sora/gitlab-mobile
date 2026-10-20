// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/features/ai/ai_history_codec.dart';
import 'package:gitlab_mobile/features/ai/ai_history_files.dart';

const account = 'https://synthetic.example/gitlab#7';
final stamp = DateTime.utc(2026, 10, 20);
final key = Uint8List.fromList(List<int>.filled(32, 7));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final scenario in <({String label, int? formatVersion})>[
    (label: 'missing unverified version', formatVersion: null),
    (label: 'recorded unsupported version', formatVersion: 2),
  ]) {
    test('R6b opens matching metadata with ${scenario.label}', () async {
      final root = Directory.systemTemp.createTempSync('probe3-ai-');
      addTearDown(() => root.deleteSync(recursive: true));
      final files = AiHistoryFileStore(
        root: () async => root,
        clock: () => stamp,
      );
      final dir = await files.directory(account)
        ..createSync(recursive: true);
      final conversationId = 2.toRadixString(16).padLeft(32, '0');
      final name = 'c_$conversationId.v1.bin';
      final bytes = await AiHistoryCipher.encryptJson(
        <String, Object?>{
          'version': 2,
          'id': conversationId,
          'updatedAt': stamp.toIso8601String(),
          'stopReason': null,
          'display': aiDisplayJson(
            AiConversation(items: <AiChatItem>[AiUserItem(text: 'future')]),
          ),
        },
        key,
        account,
        name,
      );
      final file = File('${dir.path}/$name')
        ..writeAsBytesSync(bytes, flush: true);
      file.setLastModifiedSync(stamp.subtract(const Duration(days: 1)));
      final entry = <String, Object?>{
        'id': conversationId,
        'updatedAt': stamp.subtract(const Duration(days: 40)).toIso8601String(),
        'size': file.lengthSync(),
        'modifiedAt': file.lastModifiedSync().toUtc().toIso8601String(),
      };
      if (scenario.formatVersion != null) {
        entry['formatVersion'] = scenario.formatVersion;
      }
      final indexBytes = await AiHistoryCipher.encryptJson(
        <String, Object?>{
          'version': 1,
          'entries': <Object?>[entry],
        },
        key,
        account,
        'index.v1.bin',
      );
      File(
        '${dir.path}/index.v1.bin',
      ).writeAsBytesSync(indexBytes, flush: true);

      final fresh = AiHistoryFileStore(
        root: () async => root,
        clock: () => stamp,
      );
      final recovery = await fresh.maintain(account, key, 30);

      print(
        'R6b maintain(retention 30) unsupported=${recovery.unsupported} '
        'exists=${file.existsSync()}',
      );
      expect(recovery.unsupported, isTrue);
      expect(file.existsSync(), isTrue);
    });
  }
}
