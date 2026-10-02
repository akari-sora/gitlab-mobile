import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/snippet_models.dart';

Map<String, dynamic> snippetJson({
  String fileName = 'main.dart',
  Object? files,
}) {
  final result = <String, dynamic>{
    'id': 7,
    'project_id': 42,
    'title': 'Example',
    'description': 'Notes',
    'file_name': fileName,
    'updated_at': '2026-10-02T01:00:00Z',
    'visibility': 'private',
    'author': {'username': 'developer'},
  };
  if (files != null) {
    result['files'] = files;
  }
  return result;
}

void main() {
  test('snippet visibility values follow the exact GitLab.com host', () {
    expect(snippetVisibilitiesForHost('gitlab.com'), ['private', 'public']);
    expect(snippetVisibilitiesForHost('GitLab.COM'), ['private', 'public']);
    expect(snippetVisibilitiesForHost('www.gitlab.com'), [
      'private',
      'internal',
      'public',
    ]);
    expect(snippetVisibilitiesForHost('gitlab.example.com'), [
      'private',
      'internal',
      'public',
    ]);
    expect(snippetVisibilityLabel('private'), '私人');
    expect(snippetVisibilityLabel('internal'), '內部');
    expect(snippetVisibilityLabel('public'), '公開');
  });

  test('legacy raw is allowed only for a verifiable single file', () {
    expect(ProjectSnippet.fromJson(snippetJson()).canUseLegacyRaw, isFalse);
    expect(
      ProjectSnippet.fromJson(
        snippetJson(
          files: [
            {'path': 'main.dart'},
          ],
        ),
      ).canUseLegacyRaw,
      isTrue,
    );
    expect(
      ProjectSnippet.fromJson(
        snippetJson(
          files: [
            {'path': 'main.dart'},
            {'path': 'README.md'},
          ],
        ),
      ).canUseLegacyRaw,
      isFalse,
    );
    expect(
      ProjectSnippet.fromJson(
        snippetJson(
          files: [
            {'path': 'other.dart'},
          ],
        ),
      ).canUseLegacyRaw,
      isFalse,
    );
  });

  test('file_name without files does not prove a snippet is single-file', () {
    final snippet = ProjectSnippet.fromJson(snippetJson(fileName: 'README.md'));

    expect(snippet.fileName, 'README.md');
    expect(snippet.hasExplicitFiles, isFalse);
    expect(snippet.canUseLegacyRaw, isFalse);
  });

  test('create payload uses the documented files schema', () {
    expect(
      createSnippetPayload(
        title: ' Example ',
        description: 'Notes',
        visibility: 'private',
        files: const [
          SnippetFileInput(path: 'lib/a.dart', content: 'a'),
          SnippetFileInput(path: 'README.md', content: 'b'),
        ],
      ),
      {
        'title': 'Example',
        'description': 'Notes',
        'visibility': 'private',
        'files': [
          {'file_path': 'lib/a.dart', 'content': 'a'},
          {'file_path': 'README.md', 'content': 'b'},
        ],
      },
    );
    expect(
      () => createSnippetPayload(
        title: 'Example',
        description: '',
        visibility: 'private',
        files: const [
          SnippetFileInput(path: 'same.txt', content: 'a'),
          SnippetFileInput(path: 'same.txt', content: 'b'),
        ],
      ),
      throwsA(isA<ApiFailure>()),
    );
  });

  test('single-file update emits update or move and rejects ambiguous mix', () {
    final before = ProjectSnippet.fromJson(snippetJson());
    expect(
      updateSingleFileSnippetPayload(
        before: before,
        title: 'Example 2',
        description: 'Notes',
        visibility: 'public',
        fileName: 'main.dart',
        content: 'new',
        previousContent: 'old',
      )['files'],
      [
        {'action': 'update', 'file_path': 'main.dart', 'content': 'new'},
      ],
    );
    expect(
      updateSingleFileSnippetPayload(
        before: before,
        title: 'Example',
        description: 'Notes',
        visibility: 'private',
        fileName: 'renamed.dart',
        content: 'old',
        previousContent: 'old',
      )['files'],
      [
        {
          'action': 'move',
          'previous_path': 'main.dart',
          'file_path': 'renamed.dart',
        },
      ],
    );
    expect(
      () => updateSingleFileSnippetPayload(
        before: before,
        title: 'Example',
        description: 'Notes',
        visibility: 'private',
        fileName: 'renamed.dart',
        content: 'new',
        previousContent: 'old',
      ),
      throwsA(
        isA<ApiFailure>().having(
          (error) => error.kind,
          'kind',
          FailureKind.validation,
        ),
      ),
    );
  });
}
