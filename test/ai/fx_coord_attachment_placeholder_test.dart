// C1 (§3.1 佔位字串的替換) on the production path: the chat controller, its
// runner, the coordinator and GitLabAiWritePort over FakeAdapter, with a
// scripted provider. An upload's markdown is kept in memory for the
// conversation; a later batch's (A)-class text in the same project quotes it
// as [[attachment:att-<n>]].

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/workspace/attachment_picker.dart';

import '../support/fake_adapter.dart';
import 'fx_coord_support.dart';

final _png = Uint8List.fromList(List<int>.generate(48, (i) => (i * 7) % 256));

PickedAttachment _shot() => PickedAttachment(
  filename: 'shot.png',
  bytes: _png,
  contentType: 'image/png',
);

const _rebuilt = '![shot.png](/uploads/$uploadSecret/shot.png)';

Map<String, Object?> _uploadArgs({int project = 42}) => {
  'projectId': project,
  'attachmentId': 'att-1',
  'reason': 'The user asked to upload the screenshot.',
};

Map<String, Object?> _noteArgs({int project = 42, int iid = 5}) => {
  'projectId': project,
  'resource': 'issues',
  'iid': iid,
  'body': 'Screenshot below.\n\n[[attachment:att-1]]',
  'reason': 'The user asked to post the screenshot.',
};

Future<StackHarness> _chat({
  AiWriteScope Function(StackServer server)? writeScope,
  void Function(StackServer server)? configure,
}) async {
  final h = await StackHarness.create(
    level: AiAutonomyLevel.bypass,
    picks: [_shot()],
    writeScope: writeScope,
    configure: configure,
  );
  final attached = await h.controller.attach(AiAttachmentPick.image);
  expect(attached.status, AiAttachStatus.stored, reason: attached.reasonCode);
  expect(attached.attachment!.id, 'att-1');
  return h;
}

List<RequestOptionsLike> _notePosts(StackHarness h) => [
  for (final request in h.server.mutations)
    if (request.uri.path.endsWith('/notes')) RequestOptionsLike(request.data),
];

final class RequestOptionsLike {
  RequestOptionsLike(this.data);
  final Object? data;
  String get body => (data! as Map)['body']! as String;
}

String _instructions(String body) =>
    (jsonDecode(body) as Map<String, Object?>)['instructions']! as String;

List<String> _userTexts(String body) => [
  for (final message
      in (jsonDecode(body) as Map<String, Object?>)['input']! as List<Object?>)
    if (message is Map<String, Object?> && message['role'] == 'user')
      ...switch (message['content']) {
        final String text => [text],
        final List<Object?> parts => [
          for (final part in parts)
            if (part is Map<String, Object?> && part['text'] is String)
              part['text']! as String,
        ],
        _ => const <String>[],
      },
];

void main() {
  test('C1 an upload, then a later batch\'s createNote quoting '
      '[[attachment:att-1]]: GitLab receives the markdown', () async {
    final h = await _chat();
    addTearDown(h.dispose);
    h.provider.script
      ..add((_) => toolTurn('upload_attachment', _uploadArgs()))
      ..add((_) => toolTurn('createNote', _noteArgs()));

    await h.controller.send('Upload my screenshot and attach it to #5');

    expect(h.server.uploads, hasLength(1));
    final notes = _notePosts(h);
    expect(notes, hasLength(1));
    expect(notes.single.body, 'Screenshot below.\n\n$_rebuilt');
    // The model learned the upload can be quoted, never its secret path.
    expect(h.provider.bodies[1], contains('referable=true'));
    for (final body in h.provider.bodies) {
      expect(body, isNot(contains(uploadSecret)));
      expect(body, isNot(contains('uploads/')));
    }
  });

  test('C1 the provider request carries the instruction\'s placeholder '
      'syntax', () async {
    final h = await _chat();
    addTearDown(h.dispose);

    await h.controller.send('Hello [[attachment:att-1]] [[upload:u-1]]');

    final body = h.provider.bodies.single;
    expect(_instructions(body), contains('[[attachment:att-1]]'));
    // A literal placeholder in the user's own text is still an ordinary
    // marker; only the app's instruction keeps the syntax.
    final user = _userTexts(body).join('\n');
    expect(user, isNot(contains('[[attachment:')));
    expect(user, isNot(contains('[[upload:')));
    expect(user, contains('[REDACTED]'));
  });

  test('C1 a reference in the same batch as its upload is '
      'attachmentNotUploaded', () async {
    final h = await _chat();
    addTearDown(h.dispose);
    h.provider.script.add(
      (_) => toolTurn(
        'upload_attachment',
        _uploadArgs(),
        calls: [('createNote', _noteArgs())],
      ),
    );

    await h.controller.send('Upload my screenshot and attach it to #5');

    expect(h.server.uploads, hasLength(1));
    expect(_notePosts(h), isEmpty);
    expect(h.provider.bodies[1], contains('attachmentNotUploaded'));
  });

  test('C1 a reference with no upload is attachmentNotUploaded', () async {
    final h = await _chat();
    addTearDown(h.dispose);
    h.provider.script.add((_) => toolTurn('createNote', _noteArgs()));

    await h.controller.send('Attach my screenshot to #5');

    expect(h.server.mutations, isEmpty);
    expect(h.provider.bodies[1], contains('attachmentNotUploaded'));
  });

  test('C1 a cross-project reference is refused', () async {
    final h = await _chat(
      writeScope: (server) => AiWriteScope(
        accountKey: server.workspace.account.key,
        instance: server.workspace.api.instance,
        grants: const [
          AiScopeGrant(
            kind: AiScopeKind.project,
            projectId: 42,
            projectPath: 'studio/mobile-workspace',
          ),
          AiScopeGrant(
            kind: AiScopeKind.project,
            projectId: 77,
            projectPath: 'studio/other',
          ),
        ],
      ),
      configure: (server) {
        server.overrides['GET projects/77'] = (_) => jsonResponse({
          'id': 77,
          'name': 'Other',
          'path_with_namespace': 'studio/other',
          'visibility': 'private',
        });
        server.overrides['GET projects/77/issues/1'] = (_) => jsonResponse({
          'id': 7701,
          'iid': 1,
          'project_id': 77,
          'title': 'Other one',
          'confidential': false,
          'updated_at': '2026-10-01T00:00:00Z',
        });
      },
    );
    addTearDown(h.dispose);
    h.provider.script
      ..add((_) => toolTurn('upload_attachment', _uploadArgs()))
      ..add((_) => toolTurn('createNote', _noteArgs(project: 77, iid: 1)));

    await h.controller.send(
      'Upload my screenshot and attach it to studio/other#1',
    );

    expect(h.server.uploads, hasLength(1));
    expect(_notePosts(h), isEmpty);
    expect(h.provider.bodies[2], contains('attachmentScope'));
  });

  test('C1 an upload whose markdown cannot be rebuilt succeeds but cannot '
      'be quoted', () async {
    final h = await _chat(
      configure: (server) =>
          server.uploadMarkdown = (name) =>
              '![$name](/uploads/$uploadSecret/$name) '
              '![b](/uploads/$uploadSecret/b.png)',
    );
    addTearDown(h.dispose);
    h.provider.script
      ..add((_) => toolTurn('upload_attachment', _uploadArgs()))
      ..add((_) => toolTurn('createNote', _noteArgs()));

    await h.controller.send('Upload my screenshot and attach it to #5');

    expect(h.server.uploads, hasLength(1));
    expect(h.provider.bodies[1], contains('succeeded'));
    expect(h.provider.bodies[1], contains('referable=false'));
    expect(_notePosts(h), isEmpty);
    expect(h.provider.bodies[2], contains('attachmentUnusable'));
  });

  group('C1 the conversation\'s upload memory', () {
    late AiAttachmentSession session;

    setUp(() async {
      session = AiAttachmentSession(
        accountKey: 'https://example.com/gitlab#7',
        conversationId: 'fx-coord-memory',
      );
      final picked = await session.reserveAndRead(
        picker: FakePicker([_shot()]),
        uploadToolInSegment: true,
      );
      expect(picked.attachment?.id, 'att-1');
    });

    tearDown(() => session.discardAll());

    const secret = uploadSecret;
    for (final (name, markdown) in [
      ('a carriage return', '![a](/uploads/$secret/a.png)\r'),
      ('a line feed', '![a](/uploads/$secret/a.png)\n'),
      ('a control character', '![a\u0007](/uploads/$secret/a.png)'),
      ('a bracket in the name', '![a[1]](/uploads/$secret/a.png)'),
      ('a parenthesis in the file name', '![a](/uploads/$secret/a(1).png)'),
      (
        'a trailing second token',
        '![a](/uploads/$secret/a.png) ![b](/uploads/$secret/b.png)',
      ),
      ('a short secret', '![a](/uploads/test/a.png)'),
    ]) {
      test('markdown with $name is not referable', () {
        expect(
          session.recordUpload('att-1', projectId: 42, markdown: markdown),
          isFalse,
        );
        final substituted = session
            .substitutionFor(42)!
            .substitute('[[attachment:att-1]]', sameProjectClassA: true);
        expect(substituted.policyBlocked, isTrue);
        expect(substituted.blockedReasonCode, 'attachmentUnusable');
      });
    }

    test('a well-formed markdown is referable in its project only', () {
      expect(
        session.recordUpload('att-1', projectId: 42, markdown: _rebuilt),
        isTrue,
      );
      expect(session.uploadedProjects('att-1'), {42});
      expect(
        session
            .substitutionFor(42)!
            .substitute('[[attachment:att-1]]', sameProjectClassA: true)
            .finalText,
        _rebuilt,
      );
      expect(session.substitutionFor(77), isNull);
    });

    test('removing the file keeps the upload; ending the conversation drops '
        'it', () {
      session.recordUpload('att-1', projectId: 42, markdown: _rebuilt);
      session.remove('att-1');
      expect(session.substitutionFor(42), isNotNull);
      session.discardAll();
      expect(session.substitutionFor(42), isNull);
      expect(session.uploadedProjects('att-1'), isEmpty);
    });
  });
}
