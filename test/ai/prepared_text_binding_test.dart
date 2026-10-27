import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/graphql_write_hooks.dart';

const _scope = AiWriteScope(accountKey: 'https://example.com#7', grants: []);

AiWriteRequest _request(Map<String, Object?> arguments) => AiWriteRequest(
  operationId: 'editWorkItemActivityNote',
  executionId: 'execution',
  scope: _scope,
  arguments: arguments,
);

AiWritePrepared _prepared(Map<String, Object?> arguments) =>
    AiWritePrepared.graph(
      request: _request(arguments),
      releaseName: '#3',
      writeKeys: {},
      textMutation: (_, _) async => null,
    );

void main() {
  const original = <String, Object?>{
    'projectId': 9,
    'iid': 3,
    'noteId': 12,
    'body': 'before',
  };

  test('binds processed text when target identity stays unchanged', () {
    final prepared = _prepared(original);
    final processed = _request({...original, 'body': 'after'});

    prepared.bindPreparedText(processed);

    expect(prepared.request.arguments['body'], 'after');
    expect((prepared.preview as AiFieldsPreview).fields['body'], 'after');
  });

  test('validates the processed request before binding it', () {
    final validated = <String>[];
    final prepared = AiWritePrepared.graph(
      request: _request(original),
      releaseName: '#3',
      writeKeys: {},
      textMutation: (_, _) async => null,
      validatePreparedText: (request) {
        final body = request.arguments['body']! as String;
        validated.add(body);
        if (body == 'invalid') throw StateError('invalid processed text');
      },
    );

    expect(
      () =>
          prepared.bindPreparedText(_request({...original, 'body': 'invalid'})),
      throwsStateError,
    );
    expect(prepared.request.arguments['body'], 'before');

    prepared.bindPreparedText(_request({...original, 'body': 'valid'}));
    expect(validated, ['invalid', 'valid']);
    expect(prepared.request.arguments['body'], 'valid');
  });

  for (final key in ['projectId', 'iid', 'noteId']) {
    test('refuses changed or removed $key when binding text', () {
      for (final arguments in [
        {...original, key: 99},
        {...original}..remove(key),
      ]) {
        final prepared = _prepared(original);
        expect(
          () => prepared.bindPreparedText(_request(arguments)),
          throwsA(isA<GraphHookContractException>()),
        );
        expect(prepared.request.arguments, original);
      }
    });

    test('refuses an added $key when binding text', () {
      final withoutKey = {...original}..remove(key);
      final prepared = _prepared(withoutKey);
      expect(
        () => prepared.bindPreparedText(_request({...withoutKey, key: null})),
        throwsA(isA<GraphHookContractException>()),
      );
      expect(prepared.request.arguments, withoutKey);
    });
  }
}
