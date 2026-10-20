import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import '../../core/ai/ai_display.dart';
import '../../core/ai/ai_events.dart';

/// Only this display projection crosses the persistence boundary. Provider
/// transcript entries, reasoning and opaque replay data have no encoder here.
Map<String, Object?> aiDisplayJson(AiConversation conversation) => {
  'items': conversation.items.map(_itemJson).toList(),
};

String _chars(String value, int limit) =>
    value.length <= limit ? value : value.substring(0, limit);

String _excerpt(String value) {
  // At most 8 KiB, including multi-byte Unicode characters.
  final bytes = utf8.encode(value);
  if (bytes.length <= 8192) return value;
  var end = 8192;
  while (end > 0 && (bytes[end] & 0xc0) == 0x80) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end));
}

Map<String, Object?> _itemJson(AiChatItem item) => switch (item) {
  AiUserItem(:final text, :final chips) => {
    'kind': 'user',
    'text': _chars(text, 16000),
    'chips': chips
        .map(
          (chip) => <String, Object?>{
            'source': _chars(chip.source, 1024),
            'preview': _excerpt(chip.preview),
            'sizeChars': chip.sizeChars,
            'blocked': chip.blocked,
            'type': chip.type == null ? null : _chars(chip.type!, 128),
            'resource': chip.resource == null
                ? null
                : _chars(chip.resource!, 2048),
            'pinnedSha': chip.pinnedSha == null
                ? null
                : _chars(chip.pinnedSha!, 128),
          },
        )
        .toList(),
  },
  AiAssistantItem(:final text, :final state, :final usage) => {
    'kind': 'assistant',
    'text': _chars(text, 64000),
    'state': state.name,
    'usage': usage == null
        ? null
        : <String, Object?>{
            'inputTokens': usage.inputTokens,
            'outputTokens': usage.outputTokens,
            'cacheCreationInputTokens': usage.cacheCreationInputTokens,
            'cacheReadInputTokens': usage.cacheReadInputTokens,
          },
  },
  AiToolRunItem() => {
    'kind': 'tool',
    'name': _chars(item.name, 256),
    'argsPreview': _excerpt(item.argsPreview),
    'status': item.status.name,
    'sizeChars': item.sizeChars,
    'provenance': _chars(item.provenance, 2048),
    'truncated': item.truncated,
    'blocked': item.blocked,
    'resultExcerpt': _excerpt(item.resultExcerpt),
  },
  AiNoticeItem(:final kind, :final count) => {
    'kind': 'notice',
    'notice': kind.name,
    'count': count,
  },
};

/// Throws on corrupt/unknown fields instead of projecting malformed records.
AiConversation aiDisplayFromJson(Map<String, Object?> json) {
  final items = json['items'];
  if (items is! List<Object?>) throw const FormatException();
  return AiConversation(
    items: items.map((value) {
      final item = historyObject(value);
      final text = item['text'];
      switch (item['kind']) {
        case 'user':
          if (text is! String || text.length > 16000) {
            throw const FormatException();
          }
          final chips = item['chips'];
          if (chips is! List<Object?>) throw const FormatException();
          return AiUserItem(
            text: text,
            chips: chips.map((value) {
              final chip = historyObject(value);
              return AiContextChip(
                source: _string(chip, 'source', 1024),
                preview: _string(chip, 'preview', 8192, bytes: true),
                sizeChars: _integer(chip, 'sizeChars'),
                blocked: _boolean(chip, 'blocked'),
                type: _optionalString(chip, 'type', 128),
                resource: _optionalString(chip, 'resource', 2048),
                pinnedSha: _optionalString(chip, 'pinnedSha', 128),
              );
            }).toList(),
          );
        case 'assistant':
          if (text is! String || text.length > 64000) {
            throw const FormatException();
          }
          final rawUsage = item['usage'];
          final usage = rawUsage == null ? null : historyObject(rawUsage);
          int? token(String name) {
            final value = usage?[name];
            if (value != null && (value is! int || value < 0)) {
              throw const FormatException();
            }
            return value as int?;
          }
          return AiAssistantItem(
            text: text,
            state: AiAssistantState.values.byName(_string(item, 'state', 32)),
            usage: usage == null
                ? null
                : AiUsage(
                    inputTokens: token('inputTokens'),
                    outputTokens: token('outputTokens'),
                    cacheCreationInputTokens: token('cacheCreationInputTokens'),
                    cacheReadInputTokens: token('cacheReadInputTokens'),
                  ),
          );
        case 'tool':
          return AiToolRunItem(
            name: _string(item, 'name', 256),
            argsPreview: _string(item, 'argsPreview', 8192, bytes: true),
            status: AiToolRunStatus.values.byName(_string(item, 'status', 32)),
            sizeChars: _integer(item, 'sizeChars'),
            provenance: _string(item, 'provenance', 2048),
            truncated: _boolean(item, 'truncated'),
            blocked: _boolean(item, 'blocked'),
            resultExcerpt: _string(item, 'resultExcerpt', 8192, bytes: true),
          );
        case 'notice':
          final count = item['count'];
          if (count != null && (count is! int || count < 0)) {
            throw const FormatException();
          }
          return AiNoticeItem(
            AiNoticeKind.values.byName(_string(item, 'notice', 32)),
            count: count as int?,
          );
        default:
          throw const FormatException();
      }
    }).toList(),
  );
}

Map<String, Object?> historyObject(Object? value) {
  if (value is! Map<String, Object?>) throw const FormatException();
  return value;
}

String _string(
  Map<String, Object?> map,
  String name,
  int cap, {
  bool bytes = false,
}) {
  final value = map[name];
  if (value is! String ||
      (bytes ? utf8.encode(value).length : value.length) > cap) {
    throw const FormatException();
  }
  return value;
}

String? _optionalString(Map<String, Object?> map, String name, int cap) =>
    map[name] == null ? null : _string(map, name, cap);
int _integer(Map<String, Object?> map, String name) {
  final value = map[name];
  if (value is! int || value < 0) throw const FormatException();
  return value;
}

bool _boolean(Map<String, Object?> map, String name) {
  final value = map[name];
  if (value is! bool) throw const FormatException();
  return value;
}

/// Pure Dart AES-256-GCM; version || nonce || ciphertext || tag. AAD is
/// unambiguous JSON, so account/file pairs cannot collide by concatenation.
final class AiHistoryCipher {
  static List<int> newKey() => _randomBytes(32);
  static List<int> _randomBytes(int count) {
    final random = Random.secure();
    return List<int>.generate(count, (_) => random.nextInt(256));
  }

  static Future<Uint8List> encryptJson(
    Map<String, Object?> value,
    List<int> key,
    String account,
    String file,
  ) => Isolate.run(() async {
    final plain = utf8.encode(jsonEncode(value));
    return encryptBytes(plain, key, account, file);
  });

  static Future<Map<String, Object?>> decryptJson(
    List<int> encrypted,
    List<int> key,
    String account,
    String file, {
    int? maxPlaintextBytes,
  }) => Isolate.run(() async {
    final plain = await decryptBytes(encrypted, key, account, file);
    if (maxPlaintextBytes != null && plain.length > maxPlaintextBytes) {
      throw const FormatException();
    }
    return historyObject(jsonDecode(utf8.decode(plain)));
  });

  static Future<Uint8List> encryptBytes(
    List<int> plain,
    List<int> key,
    String account,
    String file, {
    List<int>? nonce,
  }) async {
    if (key.length != 32) throw const FormatException();
    final box = await seal(
      plain,
      key,
      nonce ?? _randomBytes(12),
      utf8.encode(jsonEncode([account, file])),
    );
    return Uint8List.fromList([1, ...box.concatenation()]);
  }

  /// Shared AES primitive, exposed for NIST known-answer verification.
  /// Persistence always uses encryptJson/encryptBytes to supply bound AAD.
  static Future<SecretBox> seal(
    List<int> plain,
    List<int> key,
    List<int> nonce,
    List<int> aad,
  ) {
    if (key.length != 32 || nonce.length != 12) throw const FormatException();
    return DartAesGcm(
      secretKeyLength: 32,
    ).encrypt(plain, secretKey: SecretKey(key), nonce: nonce, aad: aad);
  }

  static Future<List<int>> decryptBytes(
    List<int> encrypted,
    List<int> key,
    String account,
    String file,
  ) async {
    if (key.length != 32 || encrypted.length < 29 || encrypted.first != 1) {
      throw const FormatException();
    }
    final box = SecretBox.fromConcatenation(
      encrypted.sublist(1),
      nonceLength: 12,
      macLength: 16,
    );
    return DartAesGcm(secretKeyLength: 32).decrypt(
      box,
      secretKey: SecretKey(key),
      aad: utf8.encode(jsonEncode([account, file])),
    );
  }
}
