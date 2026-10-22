import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/snippet_models.dart';

import '../support/fake_adapter.dart';

typedef _Call = Future<Object?> Function(GitLabApi api);
typedef _Shape = (String, String, List<String>, Object?, _Call);

Matcher get _validation => isA<ApiFailure>().having(
  (failure) => failure.kind,
  'kind',
  FailureKind.validation,
);

ProjectSnippet _snippet({int project = 42, int id = 8}) =>
    ProjectSnippet.fromJson({
      'id': id,
      'project_id': project,
      'title': 'Before',
      'updated_at': '2026-10-23T00:00:00Z',
      'visibility': 'private',
      'file_name': 'one.txt',
      'files': [
        {'path': 'one.txt'},
      ],
    });

void main() {
  final wrappers = <_Shape>[
    (
      'create repository file',
      'POST',
      ['projects', '42', 'repository', 'files', 'nested/a #.txt'],
      {'branch': 'feature/a', 'content': 'body', 'commit_message': 'create'},
      (api) => api.createRepositoryFile(
        42,
        'nested/a #.txt',
        branch: 'feature/a',
        content: 'body',
        message: 'create',
      ),
    ),
    (
      'update repository file',
      'PUT',
      ['projects', '42', 'repository', 'files', 'nested/a #.txt'],
      {
        'branch': 'feature/a',
        'content': 'body',
        'commit_message': 'edit',
        'last_commit_id': 'previous',
      },
      (api) => api.updateRepositoryFile(
        42,
        'nested/a #.txt',
        branch: 'feature/a',
        content: 'body',
        message: 'edit',
        lastCommit: 'previous',
      ),
    ),
    (
      'delete discussion note',
      'DELETE',
      [
        'projects',
        '42',
        'merge_requests',
        '7',
        'discussions',
        'thread/part',
        'notes',
        '9',
      ],
      null,
      (api) =>
          api.deleteDiscussionNote(42, 'merge_requests', 7, 'thread/part', 9),
    ),
    (
      'delete draft note',
      'DELETE',
      ['projects', '42', 'merge_requests', '7', 'draft_notes', '9'],
      null,
      (api) => api.deleteDraftNote(42, 7, 9),
    ),
    (
      'publish draft notes',
      'POST',
      ['projects', '42', 'merge_requests', '7', 'draft_notes', 'bulk_publish'],
      <String, Object?>{},
      (api) => api.publishDraftNotes(42, 7),
    ),
    (
      'delete label',
      'DELETE',
      ['projects', '42', 'labels', '3'],
      null,
      (api) => api.deleteLabel(42, 3),
    ),
    (
      'delete milestone',
      'DELETE',
      ['projects', '42', 'milestones', '4'],
      null,
      (api) => api.deleteMilestone(42, 4),
    ),
    (
      'delete board',
      'DELETE',
      ['projects', '42', 'boards', '5'],
      null,
      (api) => api.deleteBoard(42, 5),
    ),
    (
      'delete board list',
      'DELETE',
      ['projects', '42', 'boards', '5', 'lists', '6'],
      null,
      (api) => api.deleteBoardList(42, 5, 6),
    ),
    (
      'create snippet',
      'POST',
      ['projects', '42', 'snippets'],
      {
        'title': 'New',
        'description': 'desc',
        'visibility': 'private',
        'files': [
          {'file_path': 'one.txt', 'content': 'body'},
        ],
      },
      (api) => api.createSnippet(
        42,
        title: ' New ',
        description: 'desc',
        visibility: 'private',
        files: [const SnippetFileInput(path: 'one.txt', content: 'body')],
      ),
    ),
    (
      'update legacy snippet',
      'PUT',
      ['projects', '42', 'snippets', '8'],
      {
        'title': 'New',
        'description': 'desc',
        'visibility': 'private',
        'files': [
          {'action': 'update', 'file_path': 'one.txt', 'content': 'new body'},
        ],
      },
      (api) => api.updateSnippet(
        42,
        8,
        before: _snippet(),
        title: 'New',
        description: 'desc',
        visibility: 'private',
        fileName: 'one.txt',
        content: 'new body',
        previousContent: 'old body',
      ),
    ),
    (
      'update snippet metadata',
      'PUT',
      ['projects', '42', 'snippets', '8'],
      {'title': 'New', 'description': 'desc', 'visibility': 'private'},
      (api) => api.updateSnippetMetadata(
        42,
        8,
        title: 'New',
        description: 'desc',
        visibility: 'private',
        currentPaths: ['one.txt'],
      ),
    ),
    (
      'update snippet files',
      'PUT',
      ['projects', '42', 'snippets', '8'],
      {
        'title': 'New',
        'description': 'desc',
        'visibility': 'private',
        'files': [
          {'action': 'create', 'file_path': 'new.txt', 'content': 'new'},
          {'action': 'update', 'file_path': 'one.txt', 'content': 'edit'},
          {
            'action': 'move',
            'previous_path': 'old.txt',
            'file_path': 'moved.txt',
          },
        ],
      },
      (api) => api.updateSnippetFiles(
        42,
        8,
        title: 'New',
        description: 'desc',
        visibility: 'private',
        currentPaths: ['one.txt', 'old.txt'],
        actions: [
          const SnippetFileAction.create(path: 'new.txt', content: 'new'),
          const SnippetFileAction.update(path: 'one.txt', content: 'edit'),
          const SnippetFileAction.move(
            previousPath: 'old.txt',
            path: 'moved.txt',
          ),
        ],
      ),
    ),
    (
      'delete snippet file',
      'PUT',
      ['projects', '42', 'snippets', '8'],
      {
        'title': 'New',
        'description': 'desc',
        'visibility': 'private',
        'files': [
          {'action': 'delete', 'file_path': 'one.txt'},
        ],
      },
      (api) => api.deleteSnippetFile(
        42,
        8,
        title: 'New',
        description: 'desc',
        visibility: 'private',
        currentPaths: ['one.txt', 'keep.txt'],
        path: 'one.txt',
      ),
    ),
    (
      'delete snippet',
      'DELETE',
      ['projects', '42', 'snippets', '8'],
      null,
      (api) => api.deleteSnippet(42, 8),
    ),
    (
      'delete package',
      'DELETE',
      ['projects', '42', 'packages', '10'],
      null,
      (api) => api.deletePackage(42, 10),
    ),
    (
      'delete package file',
      'DELETE',
      ['projects', '42', 'packages', '10', 'package_files', '11'],
      null,
      (api) => api.deletePackageFile(42, 10, 11),
    ),
    (
      'delete container repository',
      'DELETE',
      ['projects', '42', 'registry', 'repositories', '12'],
      null,
      (api) => api.deleteContainerRepository(42, 12),
    ),
    (
      'delete container tag',
      'DELETE',
      ['projects', '42', 'registry', 'repositories', '12', 'tags', 'v1/#tag'],
      null,
      (api) => api.deleteContainerTag(42, 12, 'v1/#tag'),
    ),
  ];
  for (final wrapper in wrappers) {
    test('fixed shape: ${wrapper.$1}', () async {
      final adapter = FakeAdapter(
        (_) => wrapper.$2 == 'DELETE' || wrapper.$1 == 'publish draft notes'
            ? ResponseBody.fromString('', 204)
            : jsonResponse({}),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await wrapper.$5(api);
      final request = adapter.requests.single;
      expect(request.method, wrapper.$2);
      expect(request.uri.pathSegments, ['gitlab', 'api', 'v4', ...wrapper.$3]);
      expect(request.uri.query, isEmpty);
      expect(request.data, wrapper.$4);
      expect(request.followRedirects, isFalse);
    });
    test('negative response has no retry or fallback: ${wrapper.$1}', () async {
      final adapter = FakeAdapter((_) => jsonResponse({}, status: 403));
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        () => wrapper.$5(api),
        throwsA(
          isA<ApiFailure>().having((failure) => failure.status, 'status', 403),
        ),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.method, wrapper.$2);
      expect(adapter.requests.single.uri.pathSegments, [
        'gitlab',
        'api',
        'v4',
        ...wrapper.$3,
      ]);
      expect(adapter.requests.single.data, wrapper.$4);
    });
  }

  test('every new wrapper rejects extra fields before transport', () async {
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);
    final signatures =
        <(String, Function, List<Object?>, Map<Symbol, Object?>)>[
          (
            'createRepositoryFile',
            api.createRepositoryFile,
            [42, 'a.txt'],
            {#branch: 'main', #content: 'body', #message: 'create'},
          ),
          (
            'updateRepositoryFile',
            api.updateRepositoryFile,
            [42, 'a.txt'],
            {
              #branch: 'main',
              #content: 'body',
              #message: 'edit',
              #lastCommit: 'old',
            },
          ),
          (
            'deleteDiscussionNote',
            api.deleteDiscussionNote,
            [42, 'issues', 7, 'thread', 9],
            {},
          ),
          ('deleteDraftNote', api.deleteDraftNote, [42, 7, 9], {}),
          ('publishDraftNotes', api.publishDraftNotes, [42, 7], {}),
          ('deleteLabel', api.deleteLabel, [42, 3], {}),
          ('deleteMilestone', api.deleteMilestone, [42, 4], {}),
          ('deleteBoard', api.deleteBoard, [42, 5], {}),
          ('deleteBoardList', api.deleteBoardList, [42, 5, 6], {}),
          (
            'createSnippet',
            api.createSnippet,
            [42],
            {
              #title: 'New',
              #description: '',
              #visibility: 'private',
              #files: [
                const SnippetFileInput(path: 'one.txt', content: 'body'),
              ],
            },
          ),
          (
            'updateSnippet',
            api.updateSnippet,
            [42, 8],
            {
              #before: _snippet(),
              #title: 'New',
              #description: '',
              #visibility: 'private',
              #fileName: 'one.txt',
              #content: 'new',
              #previousContent: 'old',
            },
          ),
          (
            'updateSnippetMetadata',
            api.updateSnippetMetadata,
            [42, 8],
            {
              #title: 'New',
              #description: '',
              #visibility: 'private',
              #currentPaths: ['one.txt'],
            },
          ),
          (
            'updateSnippetFiles',
            api.updateSnippetFiles,
            [42, 8],
            {
              #title: 'New',
              #description: '',
              #visibility: 'private',
              #currentPaths: ['one.txt'],
              #actions: [
                const SnippetFileAction.update(path: 'one.txt', content: 'new'),
              ],
            },
          ),
          (
            'deleteSnippetFile',
            api.deleteSnippetFile,
            [42, 8],
            {
              #title: 'New',
              #description: '',
              #visibility: 'private',
              #currentPaths: ['one.txt', 'keep.txt'],
              #path: 'one.txt',
            },
          ),
          ('deleteSnippet', api.deleteSnippet, [42, 8], {}),
          ('deletePackage', api.deletePackage, [42, 10], {}),
          ('deletePackageFile', api.deletePackageFile, [42, 10, 11], {}),
          (
            'deleteContainerRepository',
            api.deleteContainerRepository,
            [42, 12],
            {},
          ),
          ('deleteContainerTag', api.deleteContainerTag, [42, 12, 'v1'], {}),
        ];
    for (final (name, method, arguments, named) in signatures) {
      await expectLater(
        () => Function.apply(method, arguments, {...named, #unsafeField: true}),
        throwsA(isA<NoSuchMethodError>()),
        reason: name,
      );
    }
    expect(adapter.requests, isEmpty);
  });

  test('file updates require lastCommit and never become POST', () async {
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      () => Function.apply(
        api.updateRepositoryFile,
        [42, 'a.txt'],
        {#branch: 'feature', #content: 'body', #message: 'edit'},
      ),
      throwsA(isA<NoSuchMethodError>()),
    );
    for (final lastCommit in ['', '  ', '\n']) {
      expect(
        () => api.updateRepositoryFile(
          42,
          'a.txt',
          branch: 'feature',
          content: 'body',
          message: 'edit',
          lastCommit: lastCommit,
        ),
        throwsA(_validation),
      );
      expect(
        () => api.saveFile(
          42,
          'a.txt',
          branch: 'feature',
          content: 'body',
          message: 'edit',
          lastCommit: lastCommit,
        ),
        throwsA(_validation),
      );
    }
    expect(adapter.requests, isEmpty);
  });

  test(
    'legacy saveFile delegates create and locked update unchanged',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse({}));
      final api = testApi(adapter);
      addTearDown(api.close);
      await api.saveFile(
        42,
        'a.txt',
        branch: 'feature',
        content: 'new',
        message: 'create',
      );
      await api.saveFile(
        42,
        'a.txt',
        branch: 'feature',
        content: 'edit',
        message: 'edit',
        lastCommit: 'old',
      );
      expect(adapter.requests.map((r) => r.method), ['POST', 'PUT']);
      expect(adapter.requests.first.data, {
        'branch': 'feature',
        'content': 'new',
        'commit_message': 'create',
      });
      expect(adapter.requests.last.data, {
        'branch': 'feature',
        'content': 'edit',
        'commit_message': 'edit',
        'last_commit_id': 'old',
      });
    },
  );

  test('createRepositoryFile conflict never falls back to an update', () async {
    final adapter = FakeAdapter((_) => jsonResponse({}, status: 400));
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      api.createRepositoryFile(
        42,
        'a.txt',
        branch: 'feature',
        content: 'body',
        message: 'create',
      ),
      throwsA(_validation),
    );
    expect(adapter.requests.single.method, 'POST');
    expect(adapter.requests.single.data, isNot(contains('last_commit_id')));
  });

  test('deleteNote and deleteDiscussionNote reject every other resource', () {
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);
    for (final resource in [
      'snippets',
      '../issues',
      'issues/7',
      'Issues',
      '',
    ]) {
      expect(() => api.deleteNote(42, resource, 7, 9), throwsA(_validation));
      expect(
        () => api.deleteDiscussionNote(42, resource, 7, 'thread', 9),
        throwsA(_validation),
      );
    }
    expect(adapter.requests, isEmpty);
  });

  test('release field allowlists and required existing tag name', () async {
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);
    for (final field in [
      'ref',
      'assets',
      'assets.links',
      'milestones',
      'released_at',
      'other',
    ]) {
      expect(
        () => api.createRelease(42, {'tag_name': 'v1', field: 'blocked'}),
        throwsA(_validation),
      );
      expect(
        () => api.updateRelease(42, 'v1', {field: 'blocked'}),
        throwsA(_validation),
      );
    }
    for (final tag in [null, '', ' ', 7]) {
      expect(
        () => api.createRelease(42, {'tag_name': tag}),
        throwsA(_validation),
      );
    }
    expect(
      () => api.createRelease(42, {'name': 'no tag'}),
      throwsA(_validation),
    );
    expect(
      () => api.updateRelease(42, 'v1', {'tag_name': 'v2'}),
      throwsA(_validation),
    );
    expect(adapter.requests, isEmpty);
    await api.createRelease(42, {
      'tag_name': 'v1',
      'name': 'Name',
      'description': 'Notes',
    });
    await api.updateRelease(42, 'v1/a', {
      'name': 'Next',
      'description': 'Notes',
    });
    expect(adapter.requests.first.method, 'POST');
    expect(adapter.requests.first.uri.pathSegments, [
      'gitlab',
      'api',
      'v4',
      'projects',
      '42',
      'releases',
    ]);
    expect(adapter.requests.first.data, {
      'tag_name': 'v1',
      'name': 'Name',
      'description': 'Notes',
    });
    expect(adapter.requests.last.method, 'PUT');
    expect(adapter.requests.last.uri.pathSegments, [
      'gitlab',
      'api',
      'v4',
      'projects',
      '42',
      'releases',
      'v1/a',
    ]);
    expect(adapter.requests.last.data, {
      'name': 'Next',
      'description': 'Notes',
    });
  });

  test(
    'project creation exposes only private initialized project fields',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse(projectJson(42)));
      final api = testApi(adapter);
      addTearDown(api.close);
      for (final extra in [
        {#visibility: 'public'},
        {#initialize: false},
        {#namespaceId: 5},
      ]) {
        await expectLater(
          () => Function.apply(api.createProject, [], {
            #name: 'Sample',
            ...extra,
          }),
          throwsA(isA<NoSuchMethodError>()),
        );
      }
      expect(adapter.requests, isEmpty);
      await api.createProject(
        name: 'Sample',
        path: 'sample',
        description: 'Desc',
      );
      expect(adapter.requests.single.method, 'POST');
      expect(adapter.requests.single.uri.pathSegments, [
        'gitlab',
        'api',
        'v4',
        'projects',
      ]);
      expect(adapter.requests.single.data, {
        'name': 'Sample',
        'path': 'sample',
        'description': 'Desc',
        'visibility': 'private',
        'initialize_with_readme': true,
      });
    },
  );

  test(
    'pipeline variables reject extra fields and unknown variable types',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse({}));
      final api = testApi(adapter);
      addTearDown(api.close);
      for (final fields in [
        {'key': 'A', 'value': 'B', 'masked': 'true'},
        {'key': 'A', 'value': 'B', 'variable_type': 'secret'},
        {'key': 'A', 'value': 'B', 'variable_type': ''},
      ]) {
        expect(
          () => api.createPipeline(
            42,
            'feature',
            variables: [
              {'key': 'GOOD', 'value': 'ok'},
              fields,
            ],
          ),
          throwsA(_validation),
        );
      }
      expect(adapter.requests, isEmpty);
      final variables = [
        {'key': 'A', 'value': 'B'},
        {'key': 'ENV', 'value': 'body', 'variable_type': 'env_var'},
        {'key': 'FILE', 'value': 'content', 'variable_type': 'file'},
      ];
      await api.createPipeline(42, 'feature', variables: variables);
      expect(adapter.requests.single.data, {
        'ref': 'feature',
        'variables': variables,
      });
    },
  );

  test(
    'pipeline and job actions keep empty bodies and closed action sets',
    () async {
      final adapter = FakeAdapter((_) => jsonResponse({}));
      final api = testApi(adapter);
      addTearDown(api.close);
      expect(
        () => api.pipelineAction(42, 7, 'play'),
        throwsA(isA<ApiFailure>()),
      );
      expect(() => api.jobAction(42, 9, 'erase'), throwsA(isA<ApiFailure>()));
      expect(adapter.requests, isEmpty);
      for (final action in ['retry', 'cancel']) {
        await api.pipelineAction(42, 7, action);
      }
      for (final action in ['retry', 'cancel', 'play']) {
        await api.jobAction(42, 9, action);
      }
      expect(
        adapter.requests.map((r) => r.data),
        everyElement(<String, Object?>{}),
      );
    },
  );

  test('snippet wrappers reject invalid payloads before transport', () async {
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);
    final calls = <_Call>[
      (a) => a.createSnippet(
        42,
        title: 'Title',
        description: '',
        visibility: 'private',
        files: [],
      ),
      (a) => a.createSnippet(
        42,
        title: 'Title',
        description: '',
        visibility: 'private',
        files: [const SnippetFileInput(path: '../escape', content: 'body')],
      ),
      (a) => a.updateSnippet(
        42,
        8,
        before: _snippet(),
        title: 'Title',
        description: '',
        visibility: 'private',
        fileName: 'new.txt',
        content: 'new',
        previousContent: 'old',
      ),
      (a) => a.updateSnippet(
        42,
        8,
        before: _snippet(id: 9),
        title: 'Title',
        description: '',
        visibility: 'private',
        fileName: 'one.txt',
        content: 'new',
        previousContent: 'old',
      ),
      (a) => a.updateSnippetMetadata(
        42,
        8,
        title: '',
        description: '',
        visibility: 'private',
        currentPaths: ['one.txt'],
      ),
      (a) => a.updateSnippetMetadata(
        42,
        8,
        title: 'Title',
        description: '',
        visibility: 'invalid',
        currentPaths: ['one.txt'],
      ),
      (a) => a.updateSnippetFiles(
        42,
        8,
        title: 'Title',
        description: '',
        visibility: 'private',
        currentPaths: ['one.txt', 'keep.txt'],
        actions: [const SnippetFileAction.delete(path: 'one.txt')],
      ),
      (a) => a.updateSnippetFiles(
        42,
        8,
        title: 'Title',
        description: '',
        visibility: 'private',
        currentPaths: ['one.txt'],
        actions: [
          const SnippetFileAction.update(path: 'missing.txt', content: 'body'),
        ],
      ),
      (a) => a.deleteSnippetFile(
        42,
        8,
        title: 'Title',
        description: '',
        visibility: 'private',
        currentPaths: ['one.txt'],
        path: 'one.txt',
      ),
      (a) => a.deleteSnippetFile(
        42,
        8,
        title: 'Title',
        description: '',
        visibility: 'private',
        currentPaths: ['one.txt', 'keep.txt'],
        path: 'missing.txt',
      ),
    ];
    for (final call in calls) {
      await expectLater(() => call(api), throwsA(_validation));
    }
    await expectLater(
      () => api.updateSnippet(
        42,
        8,
        before: _snippet(project: 99),
        title: 'Title',
        description: '',
        visibility: 'private',
        fileName: 'one.txt',
        content: 'new',
        previousContent: 'old',
      ),
      throwsA(
        isA<ApiFailure>().having(
          (failure) => failure.kind,
          'kind',
          FailureKind.invalidResponse,
        ),
      ),
    );
    expect(adapter.requests, isEmpty);
  });

  test(
    'effectiveProjectAccess reads membership and only treats 404 as no access',
    () async {
      for (final (body, status, access) in <(Object?, int, int)>[
        ({'access_level': 40}, 200, 40),
        ({'access_level': '40'}, 200, 0),
        ({}, 200, 0),
        ({}, 404, 0),
      ]) {
        final adapter = FakeAdapter((_) => jsonResponse(body, status: status));
        final api = testApi(adapter);
        addTearDown(api.close);
        expect(await api.effectiveProjectAccess(42, 3), access);
        expect(adapter.requests.single.method, 'GET');
        expect(adapter.requests.single.uri.pathSegments, [
          'gitlab',
          'api',
          'v4',
          'projects',
          '42',
          'members',
          'all',
          '3',
        ]);
      }
      for (final status in [401, 403, 500]) {
        final adapter = FakeAdapter((_) => jsonResponse({}, status: status));
        final api = testApi(adapter);
        addTearDown(api.close);
        await expectLater(
          api.effectiveProjectAccess(42, 3),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.status,
              'status',
              status,
            ),
          ),
        );
        expect(adapter.requests, hasLength(1));
      }
    },
  );
}
