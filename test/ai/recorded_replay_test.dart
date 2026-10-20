import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/sse.dart';
import 'package:gitlab_mobile/core/ai/wire/anthropic_messages.dart';
import 'package:gitlab_mobile/core/ai/wire/chat_completions.dart';

void main() {
  const directory = 'test/ai/fixtures/recorded';
  final recordings =
      (jsonDecode(File('$directory/index.json').readAsStringSync())
              as List<Object?>)
          .cast<Map<String, Object?>>();

  for (final recording in recordings) {
    if (recording['status'] != 200 || recording['cancelled'] == true) continue;
    final column = recording['column'];
    final relativePath = recording['response']! as String;
    final file = File('$directory/$relativePath');
    if (column == 'A' || column == 'M') {
      test('RECORDED Anthropic reconstruction $relativePath', () async {
        final oracle = _anthropicOracle(file);
        final decoder = const AnthropicMessagesFormat().newDecoder();
        await for (final event in const SseDecoder().decode(
          Stream.value(file.readAsBytesSync()),
        )) {
          decoder.add(event);
        }
        final actual = (decoder.finish().output.raw as List<Object?>)
            .cast<Map<String, Object?>>();
        final indexes = oracle.keys.toList()..sort();

        expect(actual, hasLength(indexes.length));
        for (var position = 0; position < indexes.length; position++) {
          final expected = oracle[indexes[position]]!;
          final block = actual[position];
          expect(block['type'], expected.start['type']);
          switch (expected.start['type']) {
            case 'thinking':
              expect(block['thinking'], expected.thinking.toString());
              expect(block['signature'], expected.signature.toString());
            case 'text':
              expect(block['text'], expected.text.toString());
            case 'tool_use':
              expect(block['id'], expected.start['id']);
              expect(block['name'], expected.start['name']);
              expect(block['input'], expected.toolInput());
            default:
              expect(block, expected.start);
          }
        }
      });
      continue;
    }

    if (column == 'C' || column == 'OC') {
      test('RECORDED Chat reconstruction $relativePath', () async {
        final oracle = _chatOracle(file);
        final decoder = const ChatCompletionsFormat().newDecoder();
        await for (final event in const SseDecoder().decode(
          Stream.value(file.readAsBytesSync()),
        )) {
          decoder.add(event);
        }
        final actual = decoder.finish().output.raw as Map<String, Object?>;

        for (final entry in oracle.concatenated.entries) {
          expect(actual[entry.key], entry.value.toString());
        }
        for (final entry in oracle.latestMessageFields.entries) {
          expect(actual[entry.key], entry.value);
        }

        final actualTools = (actual['tool_calls'] as List<Object?>? ?? const [])
            .cast<Map<String, Object?>>();
        final indexes = oracle.tools.keys.toList()..sort();
        expect(actualTools, hasLength(indexes.length));
        for (var position = 0; position < indexes.length; position++) {
          final expected = oracle.tools[indexes[position]]!;
          final tool = actualTools[position];
          final function = tool['function']! as Map<String, Object?>;
          expect(tool['id'], expected.id);
          expect(tool['type'], expected.type);
          expect(function['name'], expected.name);
          expect(function['arguments'], expected.arguments.toString());
          for (final entry in expected.latestToolFields.entries) {
            expect(tool[entry.key], entry.value);
          }
          for (final entry in expected.latestFunctionFields.entries) {
            expect(function[entry.key], entry.value);
          }
        }
      });
    }
  }
}

Map<int, _AnthropicBlockOracle> _anthropicOracle(File file) {
  final blocks = <int, _AnthropicBlockOracle>{};
  for (final body in _dataObjects(file)) {
    final index = body['index'];
    switch (body['type']) {
      case 'content_block_start':
        final start = Map<String, Object?>.from(body['content_block']! as Map);
        blocks[index! as int] = _AnthropicBlockOracle(start);
        break;
      case 'content_block_delta':
        final block = blocks[index! as int]!;
        final delta = Map<String, Object?>.from(body['delta']! as Map);
        switch (delta['type']) {
          case 'thinking_delta':
            block.thinking.write(delta['thinking']! as String);
            break;
          case 'signature_delta':
            block.signature.write(delta['signature']! as String);
            break;
          case 'text_delta':
            block.text.write(delta['text']! as String);
            break;
          case 'input_json_delta':
            block.partialInput.write(delta['partial_json']! as String);
            break;
        }
        break;
    }
  }
  return blocks;
}

final class _AnthropicBlockOracle {
  _AnthropicBlockOracle(this.start) {
    if (start['thinking'] case final String value) thinking.write(value);
    if (start['signature'] case final String value) signature.write(value);
    if (start['text'] case final String value) text.write(value);
  }

  final Map<String, Object?> start;
  final thinking = StringBuffer();
  final signature = StringBuffer();
  final text = StringBuffer();
  final partialInput = StringBuffer();

  Object? toolInput() {
    if (partialInput.isEmpty) return start['input'];
    return jsonDecode(partialInput.toString());
  }
}

_ChatOracle _chatOracle(File file) {
  final oracle = _ChatOracle();
  for (final body in _dataObjects(file)) {
    final choices = body['choices'];
    if (choices is! List) continue;
    for (final value in choices) {
      final choice = Map<String, Object?>.from(value! as Map);
      if (choice['index'] != 0 || choice['delta'] is! Map) continue;
      final delta = Map<String, Object?>.from(choice['delta']! as Map);
      for (final key in const ['reasoning_content', 'reasoning']) {
        if (delta[key] case final String value) {
          oracle.concatenated.putIfAbsent(key, StringBuffer.new).write(value);
        }
      }
      for (final entry in delta.entries) {
        if (!_chatMessageFields.contains(entry.key) && entry.value != null) {
          oracle.latestMessageFields[entry.key] = entry.value;
        }
      }
      final calls = delta['tool_calls'];
      if (calls is! List) continue;
      for (final value in calls) {
        final call = Map<String, Object?>.from(value! as Map);
        final index = call['index']! as int;
        final tool = oracle.tools.putIfAbsent(index, _ChatToolOracle.new);
        tool.id ??= _nonEmpty(call['id']);
        tool.type ??= _nonEmpty(call['type']);
        for (final entry in call.entries) {
          if (!_chatToolFields.contains(entry.key) && entry.value != null) {
            tool.latestToolFields[entry.key] = entry.value;
          }
        }
        if (call['function'] case final Map<Object?, Object?> functionValue) {
          final function = Map<String, Object?>.from(functionValue);
          tool.name ??= _nonEmpty(function['name']);
          if (function['arguments'] case final String arguments) {
            tool.arguments.write(arguments);
          }
          for (final entry in function.entries) {
            if (!_chatFunctionFields.contains(entry.key) &&
                entry.value != null) {
              tool.latestFunctionFields[entry.key] = entry.value;
            }
          }
        }
      }
    }
  }
  return oracle;
}

final class _ChatOracle {
  final concatenated = <String, StringBuffer>{};
  final latestMessageFields = <String, Object?>{};
  final tools = <int, _ChatToolOracle>{};
}

final class _ChatToolOracle {
  String? id;
  String? type;
  String? name;
  final arguments = StringBuffer();
  final latestToolFields = <String, Object?>{};
  final latestFunctionFields = <String, Object?>{};
}

Iterable<Map<String, Object?>> _dataObjects(File file) sync* {
  for (final line in file.readAsLinesSync()) {
    if (!line.startsWith('data:')) continue;
    final data = line.substring(5).trimLeft();
    if (data.isEmpty || data == '[DONE]') continue;
    yield Map<String, Object?>.from(jsonDecode(data) as Map);
  }
}

String? _nonEmpty(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

const _chatMessageFields = <String>{
  'role',
  'content',
  'refusal',
  'tool_calls',
  'function_call',
  'reasoning_content',
  'reasoning',
  'reasoning_details',
};
const _chatToolFields = <String>{'index', 'id', 'type', 'function'};
const _chatFunctionFields = <String>{'name', 'arguments'};
