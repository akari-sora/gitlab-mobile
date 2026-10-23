import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';

import 'mr6b2_deletes_port_test.dart';

void main() {
  late DeleteServer server;

  setUp(() => server = DeleteServer());
  tearDown(() => server.api.close());

  for (final value in [
    ('deleteLabel', AiTargetKind.label, 'priority::high'),
    ('deleteMilestone', AiTargetKind.milestone, 'Release 1'),
    ('deleteBoard', AiTargetKind.other, 'Sprint board'),
    ('deleteBoardList', AiTargetKind.other, 'workflow::ready'),
  ]) {
    test('${value.$1} publishes its exact typed binding target', () async {
      final prepared = await server.port.prepare(server.request(value.$1));
      final target = prepared.bindingTargets.single;
      expect(target.kind, value.$2);
      expect(target.projectId, 9);
      expect(target.projectPath, 'team/example-9');
      expect(target.name, value.$3);
      expect(server.mutations, 0);
    });
  }

  for (final operation in ['deleteNote', 'deleteDiscussionNote']) {
    test(
      '$operation binds the note id and previews the pre-read note',
      () async {
        final prepared = await server.port.prepare(server.request(operation));
        final target = prepared.bindingTargets.single;
        expect(target.kind, AiTargetKind.note);
        expect(
          target.side,
          operation == 'deleteNote'
              ? AiResourceSide.issue
              : AiResourceSide.mergeRequest,
        );
        expect(target.projectId, 9);
        expect(target.projectPath, 'team/example-9');
        expect(target.parentIid, 3);
        expect(target.noteId, 8);

        final preview = prepared.preview as AiDeletePreview;
        expect(preview.targetName, isEmpty);
        expect(preview.parentName, operation == 'deleteNote' ? '#3' : '!3');
        expect(preview.author, '@reviewer');
        expect(preview.excerpt, 'First line\nSecond line\nThird line');
        expect(server.mutations, 0);
      },
    );
  }

  test(
    'note excerpt is limited to the first three lines and 200 characters',
    () async {
      server.overrides['projects/9/issues/3/notes/8'] = {
        'id': 8,
        'updated_at': '2026-10-23T00:00:00Z',
        'author': {'id': 7, 'username': 'reviewer'},
        'body':
            '${List.filled(100, 'a').join()}'
            '\n${List.filled(100, 'b').join()}'
            '\n${List.filled(100, 'c').join()}\nfourth',
      };
      final prepared = await server.port.prepare(server.request('deleteNote'));
      final preview = prepared.preview as AiDeletePreview;
      expect(preview.excerpt, hasLength(200));
      expect(preview.excerpt, isNot(contains('c')));
      expect(preview.excerpt, isNot(contains('fourth')));
      expect(server.mutations, 0);
    },
  );

  test('note excerpt counts non-BMP characters without splitting them', () async {
    final prefix = List.filled(199, 'a').join();
    server.overrides['projects/9/issues/3/notes/8'] = {
      'id': 8,
      'updated_at': '2026-10-23T00:00:00Z',
      'author': {'id': 7, 'username': 'reviewer'},
      'body': '$prefix😀trailing',
    };
    final prepared = await server.port.prepare(server.request('deleteNote'));
    final excerpt = (prepared.preview as AiDeletePreview).excerpt!;
    expect(excerpt.runes, hasLength(200));
    expect(excerpt, '$prefix😀');
    expect(server.mutations, 0);
  });
}
