import 'dart:convert';

import 'ai_failure.dart';

final class SseEvent {
  const SseEvent({
    required this.data,
    this.event = 'message',
    this.id,
    this.retry,
  });

  final String data;
  final String event;
  final String? id;
  final Duration? retry;
}

final class SseDecoder {
  const SseDecoder({
    this.maxLineBytes = 2 * 1024 * 1024,
    this.maxEventDataBytes = 4 * 1024 * 1024,
  });

  final int maxLineBytes;
  final int maxEventDataBytes;

  Stream<SseEvent> decode(Stream<List<int>> source) async* {
    final line = <int>[];
    final initial = <int>[];
    final data = <String>[];
    var dataBytes = 0;
    var event = '';
    String? lastEventId;
    Duration? retry;
    var atStart = true;
    var skipLf = false;

    void addLineByte(int byte) {
      if (line.length >= maxLineBytes) {
        throw const AiFailure(AiFailureKind.responseTooLarge);
      }
      line.add(byte);
    }

    SseEvent? finishLine() {
      final value = _decodeUtf8(line);
      line.clear();
      if (value.isEmpty) {
        if (data.isEmpty) return null;
        final emitted = SseEvent(
          data: data.join('\n'),
          event: event.isEmpty ? 'message' : event,
          id: lastEventId,
          retry: retry,
        );
        data.clear();
        dataBytes = 0;
        event = '';
        return emitted;
      }
      if (value.startsWith(':')) return null;

      final colon = value.indexOf(':');
      final field = colon < 0 ? value : value.substring(0, colon);
      var fieldValue = colon < 0 ? '' : value.substring(colon + 1);
      if (fieldValue.startsWith(' ')) fieldValue = fieldValue.substring(1);
      switch (field) {
        case 'data':
          final bytes = utf8.encode(fieldValue).length;
          final separator = data.isEmpty ? 0 : 1;
          if (dataBytes + separator + bytes > maxEventDataBytes) {
            throw const AiFailure(AiFailureKind.responseTooLarge);
          }
          data.add(fieldValue);
          dataBytes += separator + bytes;
          break;
        case 'event':
          event = fieldValue;
          break;
        case 'id':
          if (!fieldValue.contains('\u0000')) lastEventId = fieldValue;
          break;
        case 'retry':
          if (RegExp(r'^\d+$').hasMatch(fieldValue)) {
            final milliseconds = int.tryParse(fieldValue);
            if (milliseconds != null) {
              retry = Duration(milliseconds: milliseconds);
            }
          }
          break;
      }
      return null;
    }

    Iterable<int> withoutInitialBom(List<int> chunk) sync* {
      for (final byte in chunk) {
        if (!atStart) {
          yield byte;
          continue;
        }
        initial.add(byte);
        if (initial.length < 3) continue;
        atStart = false;
        if (!(initial[0] == 0xef && initial[1] == 0xbb && initial[2] == 0xbf)) {
          yield* initial;
        }
        initial.clear();
      }
    }

    try {
      await for (final chunk in source) {
        for (final byte in withoutInitialBom(chunk)) {
          if (skipLf) {
            skipLf = false;
            if (byte == 0x0a) continue;
          }
          if (byte == 0x0d || byte == 0x0a) {
            final emitted = finishLine();
            if (emitted != null) yield emitted;
            skipLf = byte == 0x0d;
          } else {
            addLineByte(byte);
          }
        }
      }
      if (atStart && initial.isNotEmpty) {
        atStart = false;
        for (final byte in initial) {
          addLineByte(byte);
        }
      }
      if (line.isNotEmpty) _decodeUtf8(line);
    } on AiFailure {
      rethrow;
    } on FormatException {
      throw const AiFailure(AiFailureKind.invalidResponse);
    } catch (_) {
      throw const AiFailure(AiFailureKind.interrupted);
    }
  }
}

String _decodeUtf8(List<int> bytes) {
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw const AiFailure(AiFailureKind.invalidResponse);
  }
}
