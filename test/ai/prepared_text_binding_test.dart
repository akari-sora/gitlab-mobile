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

  test('rebinds payload and digest while retaining the opening target', () {
    final prepared = AiWritePrepared.graph(
      request: _request(original),
      releaseName: '#3',
      writeKeys: {},
      currentFields: {'body': 'original server body'},
      textBindingDigest: (request) => 'revision-1:${request.arguments['body']}',
      textMutation: (_, _) async => null,
    );
    expect(prepared.bindingDigest, 'revision-1:before');

    for (final body in ['processed', 'edited', 'edited again']) {
      prepared.bindPreparedText(_request({...original, 'body': body}));
      expect(prepared.bindingDigest, 'revision-1:$body');
      expect((prepared.preview as AiFieldsPreview).fields['body'], body);
      expect(prepared.currentFields, {'body': 'original server body'});
    }

    prepared.bindGraphBeforeMutation(() async {});
    expect(
      () => prepared.bindPreparedText(_request({...original, 'body': 'late'})),
      throwsA(isA<GraphHookContractException>()),
    );
    expect(prepared.request.arguments['body'], 'edited again');
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

  for (final key in ['projectId', 'iid', 'noteId', 'anchorNoteId']) {
    test('refuses changed or removed $key when binding text', () {
      final identified = {...original, key: 12};
      for (final arguments in [
        {...identified, key: 99},
        {...identified}..remove(key),
      ]) {
        final prepared = _prepared(identified);
        prepared.bindPreparedText(_request({...identified, 'body': 'edited'}));
        expect(
          () => prepared.bindPreparedText(_request(arguments)),
          throwsA(isA<GraphHookContractException>()),
        );
        expect(prepared.request.arguments, {...identified, 'body': 'edited'});
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
