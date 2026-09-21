import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'support/fake_adapter.dart';

typedef Operation = Future<Object?> Function(GitLabApi api);
void main() {
  final cases = <(String, String, List<String>, Json, Operation)>[
    ('project create', 'POST', ['projects'], {'name': 'sample', 'visibility': 'private', 'initialize_with_readme': true}, (a) => a.createProject(name: 'sample')),
    ('project edit', 'PUT', ['projects', '42'], {'name': 'changed', 'description': 'new'}, (a) => a.editProject(42, name: 'changed', description: 'new')),
    ('star', 'POST', ['projects', '42', 'star'], {}, (a) => a.setStar(42, true)),
    ('unstar', 'POST', ['projects', '42', 'unstar'], {}, (a) => a.setStar(42, false)),
    ('issue create', 'POST', ['projects', '42', 'issues'], {'title': 'issue', 'description': 'body'}, (a) => a.createIssue(42, {'title': 'issue', 'description': 'body'})),
    ('issue edit', 'PUT', ['projects', '42', 'issues', '7'], {'title': 'updated'}, (a) => a.updateIssue(42, 7, {'title': 'updated'})),
    ('issue close', 'PUT', ['projects', '42', 'issues', '7'], {'state_event': 'close'}, (a) => a.updateIssue(42, 7, {'state_event': 'close'})),
    ('MR create', 'POST', ['projects', '42', 'merge_requests'], {'title': 'review', 'source_branch': 'feat/one', 'target_branch': 'main'},
      (a) => a.createMergeRequest(42, {'title': 'review', 'source_branch': 'feat/one', 'target_branch': 'main'})),
    ('MR edit', 'PUT', ['projects', '42', 'merge_requests', '7'], {'description': 'updated'}, (a) => a.updateMergeRequest(42, 7, {'description': 'updated'})),
    ('MR approval pins SHA', 'POST', ['projects', '42', 'merge_requests', '7', 'approve'], {'sha': 'reviewed-sha'}, (a) => a.approveMergeRequest(42, 7, 'reviewed-sha')),
    ('MR merge pins SHA', 'PUT', ['projects', '42', 'merge_requests', '7', 'merge'], {'sha': 'reviewed-sha', 'squash': true, 'should_remove_source_branch': false},
      (a) => a.mergeRequest(42, 7, 'reviewed-sha', squash: true, removeSourceBranch: false)),
    ('MR merge removes the source branch when asked', 'PUT', ['projects', '42', 'merge_requests', '7', 'merge'],
      {'sha': 'reviewed-sha', 'squash': false, 'should_remove_source_branch': true},
      (a) => a.mergeRequest(42, 7, 'reviewed-sha', squash: false, removeSourceBranch: true)),
    ('note create', 'POST', ['projects', '42', 'issues', '7', 'notes'], {'body': '留言'}, (a) => a.createNote(42, 'issues', 7, '留言')),
    ('note edit', 'PUT', ['projects', '42', 'merge_requests', '7', 'notes', '9'], {'body': 'updated'}, (a) => a.updateNote(42, 'merge_requests', 7, 9, 'updated')),
    ('branch create', 'POST', ['projects', '42', 'repository', 'branches'], {'branch': 'feat/中文', 'ref': 'main'}, (a) => a.createBranch(42, 'feat/中文', 'main')),
    ('tag create', 'POST', ['projects', '42', 'repository', 'tags'], {'tag_name': 'v1.0', 'ref': 'main', 'message': 'release'}, (a) => a.createTag(42, 'v1.0', 'main', message: 'release')),
    ('file create', 'POST', ['projects', '42', 'repository', 'files', 'nested/範例.txt'], {'branch': 'feat/edit', 'content': '第一行\nsecond', 'commit_message': 'create'},
      (a) => a.saveFile(42, 'nested/範例.txt', branch: 'feat/edit', content: '第一行\nsecond', message: 'create')),
    ('file edit optimistic lock', 'PUT', ['projects', '42', 'repository', 'files', 'nested/範例.txt'], {'branch': 'feat/edit', 'content': 'new', 'commit_message': 'edit', 'last_commit_id': 'previous'},
      (a) => a.saveFile(42, 'nested/範例.txt', branch: 'feat/edit', content: 'new', message: 'edit', lastCommit: 'previous')),
    ('pipeline create singular endpoint', 'POST', ['projects', '42', 'pipeline'], {'ref': 'main'}, (a) => a.createPipeline(42, 'main')),
    ('pipeline retry', 'POST', ['projects', '42', 'pipelines', '11', 'retry'], {}, (a) => a.pipelineAction(42, 11, 'retry')),
    ('pipeline cancel', 'POST', ['projects', '42', 'pipelines', '11', 'cancel'], {}, (a) => a.pipelineAction(42, 11, 'cancel')),
    ('job retry', 'POST', ['projects', '42', 'jobs', '15', 'retry'], {}, (a) => a.jobAction(42, 15, 'retry')),
    ('job play', 'POST', ['projects', '42', 'jobs', '15', 'play'], {}, (a) => a.jobAction(42, 15, 'play')),
    ('job cancel', 'POST', ['projects', '42', 'jobs', '15', 'cancel'], {}, (a) => a.jobAction(42, 15, 'cancel')),
    ('release create', 'POST', ['projects', '42', 'releases'], {'tag_name': 'v1', 'name': 'release'}, (a) => a.createRelease(42, {'tag_name': 'v1', 'name': 'release'})),
    ('release edit', 'PUT', ['projects', '42', 'releases', 'v1'], {'name': 'changed'}, (a) => a.updateRelease(42, 'v1', {'name': 'changed'})),
    ('single todo completion', 'POST', ['todos', '19', 'mark_as_done'], {}, (a) => a.markTodoDone(19)),
    ('label edit wire rename', 'PUT', ['projects', '42', 'labels', '21'], {'new_name': 'renamed', 'color': '#4763e4'},
      (a) => a.writeRecord('PUT', ['projects', '42', 'labels', '21'], {'name': 'renamed', 'color': '#4763e4'})),
    ('milestone update', 'PUT', ['projects', '42', 'milestones', '22'], {'title': 'Sprint', 'due_date': null},
      (a) => a.writeRecord('PUT', ['projects', '42', 'milestones', '22'], {'title': 'Sprint', 'due_date': null})),
    ('discussion reply', 'POST', ['projects', '42', 'merge_requests', '7', 'discussions', 'thread-id', 'notes'], {'body': 'reply'},
      (a) => a.writeRecord('POST', ['projects', '42', 'merge_requests', '7', 'discussions', 'thread-id', 'notes'], {'body': 'reply'})),
    ('discussion resolve', 'PUT', ['projects', '42', 'merge_requests', '7', 'discussions', 'thread-id'], {'resolved': true},
      (a) => a.writeRecord('PUT', ['projects', '42', 'merge_requests', '7', 'discussions', 'thread-id'], {'resolved': true})),
  ];
  for (final item in cases) {
    test('contract ${item.$1}', () async {
      final adapter = FakeAdapter((request) => jsonResponse({...projectJson(42), 'iid': 7}, status: request.method == 'POST' ? 201 : 200));
      final api = testApi(adapter); addTearDown(api.close);
      await item.$5(api);
      final request = adapter.requests.single;
      expect(request.method, item.$2);
      expect(request.uri.pathSegments, ['gitlab', 'api', 'v4', ...item.$3]);
      if (item.$4.isEmpty) { expect(request.data, isEmpty); }
      for (final field in item.$4.entries) { expect((request.data as Json)[field.key], field.value); }
      expect(request.headers['PRIVATE-TOKEN'], 'synthetic-test-token');
      expect(request.uri.queryParameters, isNot(contains('private_token')));
      expect(request.followRedirects, isFalse);
    });
  }
  final deletes = <(String, List<String>, Future<void> Function(GitLabApi))>[
    ('project', ['projects', '42'], (a) => a.deleteProject(42)),
    ('issue', ['projects', '42', 'issues', '7'], (a) => a.deleteIssue(42, 7)),
    ('MR', ['projects', '42', 'merge_requests', '7'], (a) => a.deleteMergeRequest(42, 7)),
    ('note', ['projects', '42', 'issues', '7', 'notes', '9'], (a) => a.deleteNote(42, 'issues', 7, 9)),
    ('branch slash', ['projects', '42', 'repository', 'branches', 'feat/中文'], (a) => a.deleteBranch(42, 'feat/中文')),
    ('tag', ['projects', '42', 'repository', 'tags', 'release/v1'], (a) => a.deleteTag(42, 'release/v1')),
    ('release', ['projects', '42', 'releases', 'release/v1'], (a) => a.deleteRelease(42, 'release/v1')),
    ('pipeline', ['projects', '42', 'pipelines', '11'], (a) => a.deletePipeline(42, 11)),
    ('file', ['projects', '42', 'repository', 'files', 'nested/a.txt'], (a) => a.deleteFile(42, 'nested/a.txt', branch: 'main', message: 'delete', lastCommit: 'last')),
  ];
  for (final item in deletes) {
    test('DELETE ${item.$1} accepts empty 204 and preserves path boundaries', () async {
      final adapter = FakeAdapter((_) => ResponseBody.fromString('', 204));
      final api = testApi(adapter); addTearDown(api.close);
      await item.$3(api);
      final request = adapter.requests.single;
      expect(request.method, 'DELETE');
      expect(request.uri.pathSegments, ['gitlab', 'api', 'v4', ...item.$2]);
      if (item.$1 == 'file') { expect(request.data, {'branch': 'main', 'commit_message': 'delete', 'last_commit_id': 'last'}); }
    });
  }
  for (final status in [400, 401, 403, 404, 409, 422, 429, 500]) {
    test('write HTTP $status is not retried and never exposes response contents', () async {
      final adapter = FakeAdapter((_) => jsonResponse({'error': 'sensitive-fixture-content'}, status: status));
      final api = testApi(adapter); addTearDown(api.close);
      await expectLater(api.createIssue(42, {'title': 'sample'}), throwsA(isA<ApiFailure>()
        .having((e) => e.status, 'status', status)
        .having((e) => '${e.title} ${e.detail} $e', 'sanitized', isNot(contains('sensitive-fixture-content')))));
      expect(adapter.requests, hasLength(1));
    });
  }
  test('write timeout is uncertain, does not repeat POST or clear the caller draft', () async {
    final adapter = FakeAdapter((request) => throw DioException(requestOptions: request, type: DioExceptionType.receiveTimeout));
    final api = testApi(adapter); addTearDown(api.close);
    await expectLater(api.createIssue(42, {'title': 'draft'}), throwsA(isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.writeUncertain)));
    expect(adapter.requests, hasLength(1));
  });
  test('job retry exposes the new attempt id', () async {
    final api = testApi(FakeAdapter((_) => jsonResponse({'id': 456, 'status': 'pending'}))); addTearDown(api.close);
    expect((await api.jobAction(42, 123, 'retry'))['id'], 456);
  });
  test('upload sends a multipart file part named for the file and the private token', () async {
    final adapter = FakeAdapter((_) => jsonResponse({
      'markdown': '![photo.png](/uploads/photo.png)',
      'url': '/uploads/photo.png',
      'full_path': '/group/project/uploads/photo.png',
    }, status: 201));
    final api = testApi(adapter);
    addTearDown(api.close);
    final value = await api.uploadProjectFile(42, filename: 'photo.png', bytes: [1, 2, 3], contentType: 'image/png');
    expect(value['markdown'], '![photo.png](/uploads/photo.png)');
    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.uri.pathSegments, ['gitlab', 'api', 'v4', 'projects', '42', 'uploads']);
    expect(request.headers['PRIVATE-TOKEN'], 'synthetic-test-token');
    expect(request.followRedirects, isFalse);
    final header = '${request.contentType ?? request.headers['content-type'] ?? ''}';
    expect(header, contains('multipart/form-data'));
    final form = request.data;
    expect(form, isA<FormData>());
    final files = (form as FormData).files;
    expect(files, hasLength(1));
    expect(files.single.key, 'file');
    expect(files.single.value.filename, 'photo.png');
  });
  test('upload over 25 MiB is tooLarge and sends no request', () async {
    expect(GitLabApi.maxUploadBytes, 25 * 1024 * 1024);
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      api.uploadProjectFile(42, filename: 'big.bin', bytes: Uint8List(GitLabApi.maxUploadBytes + 1)),
      throwsA(isA<ApiFailure>().having((error) => error.kind, 'kind', FailureKind.tooLarge)),
    );
    expect(adapter.requests, isEmpty);
  });
  test('arbitrary actions and off-origin continuations are refused without transport', () async {
    final adapter = FakeAdapter((_) => jsonResponse([])); final api = testApi(adapter); addTearDown(api.close);
    expect(() => api.jobAction(42, 1, 'erase'), throwsA(isA<ApiFailure>()));
    expect(() => api.pipelineAction(42, 1, 'deploy'), throwsA(isA<ApiFailure>()));
    expect(() => api.records(['projects'], next: Uri.parse('https://other.example/api/v4/projects?page=2')), throwsA(isA<ApiFailure>()));
    expect(adapter.requests, isEmpty);
  });
}
