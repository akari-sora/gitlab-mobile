import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_events.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/wire/wire_format.dart';

void main() {
  const directory = 'test/ai/fixtures/recorded';
  const bindingErrors = <String>{
    'A/loop/05-control-mutate-user.error.jsonc',
    'A/mut-system/01-system.error.jsonc',
    'A/mut-tools/01-tools.error.jsonc',
    'M/loop/05-control-mutate-user.error.jsonc',
    'M/loop/06-control-mutate-system.error.jsonc',
    'R/mut-encrypted/01-encrypted.error.jsonc',
  };
  final index =
      (jsonDecode(File('$directory/index.json').readAsStringSync())
              as List<Object?>)
          .cast<Map<String, Object?>>();
  for (final recording in index) {
    final column = recording['column'];
    final WireFormatBase wire = switch (column) {
      'A' || 'M' => const AnthropicMessagesFormat(),
      'R' || 'OR' => const ResponsesFormat(),
      _ => const ChatCompletionsFormat(),
    };
    final path = recording['response']! as String;
    if (recording['status'] != 200) {
      test('RECORDED error $path', () {
        final text = File('$directory/$path').readAsStringSync();
        final body = jsonDecode(
          text.split('\n').where((line) => !line.startsWith('//')).join('\n'),
        );
        final failure = wire.decodeError(
          recording['status']! as int,
          body,
          null,
        );
        expect(failure.status, recording['status']);
        if (recording['case'] == 'error') {
          expect(failure.kind, AiFailureKind.notFound);
        }
        if (bindingErrors.contains(path)) {
          expect(failure.requiresNewSegment, isTrue);
        }
      });
      continue;
    }
    for (final mode in ['byte', 'random', 'utf8']) {
      test('RECORDED $path split=$mode', () async {
        final bytes = File('$directory/$path').readAsBytesSync();
        final random = Random(73);
        final chunks = <List<int>>[];
        for (var start = 0; start < bytes.length;) {
          final width = mode == 'byte'
              ? 1
              : mode == 'utf8'
              ? 7
              : 1 + random.nextInt(997);
          var end = min(start + width, bytes.length);
          if (mode == 'utf8') {
            final next = bytes.indexWhere(
              (byte) => byte & 0xc0 == 0x80,
              start + 1,
            );
            end = next < 0 ? bytes.length : next;
          }
          chunks.add(bytes.sublist(start, end));
          start = end;
        }
        final decoder = wire.newDecoder();
        final events = <AiEvent>[];
        await for (final event in const SseDecoder().decode(
          Stream.fromIterable(chunks),
        )) {
          events.addAll(decoder.add(event));
        }
        if (recording['cancelled'] == true) {
          expect(
            decoder.finish,
            throwsA(
              isA<AiFailure>().having(
                (e) => e.kind,
                'kind',
                AiFailureKind.interrupted,
              ),
            ),
          );
        } else {
          final turn = decoder.finish();
          expect(turn.output.format, wire.format);
          expect(events.whereType<AiStarted>(), hasLength(1));
          expect(events.whereType<AiFinished>(), hasLength(1));
          if (wire is ResponsesFormat) {
            final terminals = <Map<String, Object?>>[];
            await for (final event in const SseDecoder().decode(
              Stream.value(bytes),
            )) {
              final body = wireObject(jsonDecode(event.data));
              if (body['type'] == 'response.completed' ||
                  body['type'] == 'response.incomplete') {
                terminals.add(wireObject(body['response']));
              }
            }
            expect(turn.output.raw, terminals.single['output']);
          }
        }
      });
    }
  }
  test('recorded binding rollover assertions cover every expected fixture', () {
    final recordedErrors = index
        .where((recording) => recording['status'] != 200)
        .map((recording) => recording['response']! as String)
        .toSet();
    expect(recordedErrors, containsAll(bindingErrors));
  });
  test('recorded fixtures carry provenance and no forbidden key prefixes', () {
    for (final file in Directory(
      directory,
    ).listSync(recursive: true).whereType<File>()) {
      final text = file.readAsStringSync();
      expect(text.contains('sk-${'ant-'}'), false, reason: file.path);
      expect(text.contains('oc_${'sk_'}'), false, reason: file.path);
      if (file.path.endsWith('.sse') || file.path.endsWith('.jsonc')) {
        expect(
          text,
          startsWith(file.path.endsWith('.sse') ? ': RECORDED' : '// RECORDED'),
        );
        expect(text, contains('2026-10-20'));
      }
    }
  });

  test(
    'recorded index covers every request/response and current byte count',
    () {
      final referenced = <String>{};
      for (final row in index) {
        for (final field in ['request', 'response']) {
          final path = row[field]! as String;
          expect(referenced.add(path), true);
          expect(File('$directory/$path').existsSync(), true);
        }
        expect(
          File('$directory/${row['response']}').lengthSync(),
          row['responseBytes'],
        );
        expect(row['sourceResponseBytes'], isA<int>());
        expect(row['path'], isA<String>());
        expect(row['model'], isA<String>());
        expect(row['via'], isA<String>());
      }
      final files = Directory(directory)
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => file.path.substring(directory.length + 1))
          .where((file) => file.endsWith('.jsonc') || file.endsWith('.sse'))
          .toSet();
      expect(referenced, files);
    },
  );
}
