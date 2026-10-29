import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/mr7/sandbox_contract.dart';

const _oldSha = '1111111111111111111111111111111111111111';
const _newSha = '2222222222222222222222222222222222222222';
const _parent = Mr7Parent.mergeRequest(id: 400, iid: 4);
const _root = 'projects/909';
const _mr = '$_root/merge_requests/4';

Map<String, List<String>> _headers(int page, int total, {int perPage = 100}) =>
    {
      'x-page': ['$page'],
      'x-per-page': ['$perPage'],
      'x-total': ['$total'],
      'x-total-pages': ['${total == 0 ? 1 : (total + perPage - 1) ~/ perPage}'],
      'x-next-page': [page * perPage < total ? '${page + 1}' : ''],
    };

ResponseBody _page(
  RequestOptions request,
  List<Object?> rows, {
  int size = 100,
}) {
  final page = int.parse('${request.queryParameters['page'] ?? 1}');
  return mr7Json(
    rows.skip((page - 1) * size).take(size).toList(),
    headers: _headers(page, rows.length, perPage: size),
  );
}

Future<Mr7SandboxSession> _session(Mr7SyntheticGitLab server) async {
  final session = Mr7SandboxSession(
    server: server,
    nonce: 'testnonce123',
    eventDelay: () async {},
    requestCap: 300,
  );
  await session.initialize();
  addTearDown(session.finish);
  return session;
}

Mr7MutationPermit _permit(
  Mr7SandboxSession session,
  String operation,
  Set<String> paths, {
  Object? arguments,
  int maxMutations = 1,
}) {
  final permit = Mr7MutationPermit(
    operation: operation,
    resourceProjectId: 909,
    paths: paths,
    callArguments: arguments,
    maxMutations: maxMutations,
    captureEffects: true,
  )..confirmed = true;
  session.permit = permit;
  return permit;
}

Mr7Readback _readback(
  Mr7SandboxSession session,
  Mr7MutationPermit permit,
  Set<String> paths,
) => Mr7Readback(session, session.identity!, permit, paths: paths);

Future<void> _reject(Future<Object?> future) async {
  Object? result;
  var threw = false;
  try {
    result = await future;
  } on Exception {
    threw = true;
  }
  if (!threw) expect(result, isFalse);
}

String _blob(List<int> bytes) => sha1.convert([
  ...utf8.encode('blob ${bytes.length}\u0000'),
  ...bytes,
]).toString();

Map<String, Object?> _mrRow({bool enabled = false}) => {
  'id': 400,
  'iid': 4,
  'project_id': 909,
  'source_project_id': 909,
  'source_branch': 'feature',
  'target_branch': 'main',
  'sha': _oldSha,
  'diff_refs': {'base_sha': _oldSha, 'start_sha': _oldSha, 'head_sha': _oldSha},
  'auto_merge_enabled': enabled,
  'merge_when_pipeline_succeeds': enabled,
};

void main() {
  test(
    'deleteFile proves complete tree absence at the resulting ref',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = await _session(server);
      var sent = false;
      server.routes['GET $_root/repository/branches/feature'] = (_) => mr7Json({
        'name': 'feature',
        'commit': {'id': sent ? _newSha : _oldSha},
      });
      server.routes['GET $_root/repository/files/dir/file.txt'] = (_) =>
          mr7Json({
            'file_path': 'dir/file.txt',
            'commit_id': _oldSha,
            'last_commit_id': _oldSha,
            'blob_id': _blob(utf8.encode('old\n')),
            'encoding': 'base64',
            'content': base64Encode(utf8.encode('old\n')),
          });
      server.routes['GET $_root/repository/tree'] = (r) => _page(r, [
        {
          'id': _oldSha,
          'name': 'other.txt',
          'type': 'blob',
          'path': 'dir/other.txt',
          'mode': '100644',
        },
      ]);
      server.routes['DELETE $_root/repository/files/dir/file.txt'] = (_) {
        sent = true;
        server.scenarioWrites++;
        server.addEvent(target: 909);
        return mr7Json({}, status: 204);
      };
      final permit = _permit(session, 'deleteFile', {
        'DELETE $_root/repository/files/dir/file.txt',
      });
      await session.writer.delete<Object?>(
        '$_root/repository/files/dir%2Ffile.txt',
        data: {
          'branch': 'feature',
          'commit_message': 'delete',
          'last_commit_id': _oldSha,
        },
      );
      final witness = _readback(session, permit, {
        '$_root/repository/branches/feature',
        '$_root/repository/tree',
      });
      expect(
        await witness.observe(
          const Mr7DeletedFileObservation(
            path: 'dir/file.txt',
            ref: 'feature',
            sha: _newSha,
          ),
        ),
        isTrue,
      );
      expect(server.requests, contains('GET $_root/repository/tree'));
    },
  );

  test('deleteFile rejects tree absence from an incomplete page set', () async {
    final server = Mr7SyntheticGitLab();
    final session = await _session(server);
    var sent = false;
    server.routes['GET $_root/repository/branches/feature'] = (_) => mr7Json({
      'name': 'feature',
      'commit': {'id': sent ? _newSha : _oldSha},
    });
    server.routes['GET $_root/repository/files/dir/file.txt'] = (_) => mr7Json({
      'file_path': 'dir/file.txt',
      'commit_id': _oldSha,
      'last_commit_id': _oldSha,
      'blob_id': _blob(utf8.encode('old\n')),
      'encoding': 'base64',
      'content': base64Encode(utf8.encode('old\n')),
    });
    server.routes['GET $_root/repository/tree'] = (r) => mr7Json(
      [
        {
          'id': _oldSha,
          'name': 'other.txt',
          'type': 'blob',
          'path': 'dir/other.txt',
          'mode': '100644',
        },
      ],
      headers: {
        ..._headers(1, 2, perPage: 1),
        'x-next-page': [''],
      },
    );
    server.routes['DELETE $_root/repository/files/dir/file.txt'] = (_) {
      sent = true;
      return mr7Json({}, status: 204);
    };
    final permit = _permit(session, 'deleteFile', {
      'DELETE $_root/repository/files/dir/file.txt',
    });
    await session.writer.delete<Object?>(
      '$_root/repository/files/dir%2Ffile.txt',
      data: {
        'branch': 'feature',
        'commit_message': 'delete',
        'last_commit_id': _oldSha,
      },
    );
    await _reject(
      _readback(session, permit, {
        '$_root/repository/branches/feature',
        '$_root/repository/tree',
      }).observe(
        const Mr7DeletedFileObservation(
          path: 'dir/file.txt',
          ref: 'feature',
          sha: _newSha,
        ),
      ),
    );
  });

  test(
    'deleteBoardList checks complete list under the dispatched board',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = await _session(server);
      var sent = false;
      server.routes['GET $_root/boards/12'] = (_) => mr7Json({
        'id': 12,
        'name': 'Board',
        'project': {'id': 909},
      });
      server.routes['GET $_root/boards/12/lists'] = (r) => _page(r, [
        {'id': 51, 'position': 0, 'list_type': 'label'},
        if (!sent) {'id': 52, 'position': 1, 'list_type': 'label'},
      ]);
      server.routes['DELETE $_root/boards/12/lists/52'] = (_) {
        sent = true;
        return mr7Json({}, status: 204);
      };
      final permit = _permit(session, 'deleteBoardList', {
        'DELETE $_root/boards/12/lists/52',
      });
      await session.writer.delete<Object?>('$_root/boards/12/lists/52');
      final witness = _readback(session, permit, {
        '$_root/boards/12',
        '$_root/boards/12/lists',
      });
      expect(
        await witness.observe(
          const Mr7DeletedBoardListObservation(boardId: 12, listId: 52),
        ),
        isTrue,
      );
      await _reject(
        witness.observe(
          const Mr7DeletedBoardListObservation(boardId: 12, listId: 51),
        ),
      );
    },
  );

  test('snippet visibility and bytes bind to the dispatched create', () async {
    final server = Mr7SyntheticGitLab();
    final session = await _session(server);
    var createStatus = 201;
    var includeId = true;
    server.routes['POST $_root/snippets'] = (_) => mr7Json({
      if (includeId) 'id': 60,
      'project_id': 909,
    }, status: createStatus);
    var visibility = 'public';
    var rawBytes = utf8.encode('example');
    server.routes['GET $_root/snippets/60'] = (_) => mr7Json({
      'id': 60,
      'project_id': 909,
      'visibility': visibility,
      'updated_at': 'revision-one',
      'files': [
        {
          'path': 'dir/raw.bin',
          'raw_url':
              'https://gitlab.invalid/install/synthetic-owner/mr7-testnonce123/-/snippets/60/raw/ref-one/dir/raw.bin',
        },
      ],
    });
    server.routes['GET $_root/snippets/60/files/ref-one/dir/raw.bin/raw'] =
        (_) => ResponseBody.fromBytes(rawBytes, 200);
    final permit = _permit(session, 'createSnippet', {'POST $_root/snippets'});
    await session.writer.post<Object?>(
      '$_root/snippets',
      data: {
        'title': 'Example',
        'visibility': 'public',
        'files': [
          {'file_path': 'dir/raw.bin', 'content': 'example'},
        ],
      },
    );
    final witness = _readback(session, permit, {
      '$_root/snippets/60',
      '$_root/snippets/60/files/ref-one/dir%2Fraw.bin/raw',
    });
    Mr7SnippetObservation spec(String value, [List<int>? bytes]) =>
        Mr7SnippetObservation(
          id: 60,
          revision: 'revision-one',
          visibility: value,
          files: {
            'dir/raw.bin': Mr7SnippetFile(
              ref: 'ref-one',
              bytes: bytes ?? utf8.encode('example'),
            ),
          },
        );
    expect(
      (await witness.observe(spec('public')))['dir/raw.bin'],
      utf8.encode('example'),
    );
    visibility = 'internal';
    await _reject(witness.observe(spec('public')));
    visibility = 'internal';
    await _reject(witness.observe(spec('internal')));
    visibility = 'public';
    rawBytes = utf8.encode('other');
    await _reject(witness.observe(spec('public', rawBytes)));
    rawBytes = utf8.encode('example');
    for (final status in [400, 201]) {
      createStatus = status;
      includeId = false;
      final failed = _permit(session, 'createSnippet', {
        'POST $_root/snippets',
      });
      final send = session.writer.post<Object?>(
        '$_root/snippets',
        data: {
          'visibility': 'public',
          'files': [
            {'file_path': 'dir/raw.bin', 'content': 'example'},
          ],
        },
      );
      if (status == 400) {
        await expectLater(send, throwsA(isA<DioException>()));
      } else {
        await send;
      }
      await _reject(
        _readback(session, failed, {
          '$_root/snippets/60',
          '$_root/snippets/60/files/ref-one/dir%2Fraw.bin/raw',
        }).observe(spec('public')),
      );
    }
  });

  test(
    'applySuggestion binds resulting bytes and blob to the dispatched discussion',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = await _session(server);
      var sent = false;
      final before = utf8.encode('old\n');
      var after = utf8.encode('new\n');
      server.routes['GET $_mr'] = (_) => mr7Json(_mrRow());
      server.routes['GET $_mr/discussions/discussion-a'] = (_) => mr7Json({
        'id': 'discussion-a',
        'notes': [
          {
            'id': 17,
            'position': {
              'position_type': 'text',
              'new_path': 'dir/file.txt',
              'old_path': 'dir/file.txt',
              'base_sha': _oldSha,
              'start_sha': _oldSha,
              'head_sha': _oldSha,
            },
            'suggestions': [
              {
                'id': 5,
                'from_line': 1,
                'to_line': 1,
                'appliable': !sent,
                'applied': sent,
                'from_content': 'old\n',
                'to_content': 'new\n',
              },
            ],
          },
        ],
      });
      server.routes['GET $_mr/discussions/discussion-b'] = (_) => mr7Json({
        'id': 'discussion-b',
        'notes': [
          {
            'id': 18,
            'position': {
              'position_type': 'text',
              'new_path': 'dir/other.txt',
              'old_path': 'dir/other.txt',
              'base_sha': _oldSha,
              'start_sha': _oldSha,
              'head_sha': _oldSha,
            },
            'suggestions': [
              {
                'id': 6,
                'from_line': 1,
                'to_line': 1,
                'appliable': true,
                'applied': false,
                'from_content': 'old\n',
                'to_content': 'other\n',
              },
            ],
          },
        ],
      });
      server.routes['GET $_root/repository/branches/feature'] = (_) => mr7Json({
        'name': 'feature',
        'commit': {'id': sent ? _newSha : _oldSha},
      });
      server.routes['GET $_root/repository/files/dir/file.txt'] = (_) {
        final bytes = sent ? after : before;
        return mr7Json({
          'file_path': 'dir/file.txt',
          'commit_id': sent ? _newSha : _oldSha,
          'last_commit_id': sent ? _newSha : _oldSha,
          'blob_id': _blob(bytes),
          'encoding': 'base64',
          'content': base64Encode(bytes),
        });
      };
      server.routes['PUT suggestions/5/apply'] = (_) {
        sent = true;
        return mr7Json({'id': 5, 'applied': true});
      };
      final permit = _permit(
        session,
        'applySuggestion',
        {'PUT suggestions/5/apply'},
        arguments: {
          'projectId': 909,
          'iid': 4,
          'discussionId': 'discussion-a',
          'noteId': 17,
          'suggestionId': 5,
        },
      );
      await session.writer.put<Object?>(
        'suggestions/5/apply',
        data: <String, Object?>{},
      );
      final witness = _readback(session, permit, {
        _mr,
        '$_mr/discussions/discussion-a',
        '$_mr/discussions/discussion-b',
        '$_root/repository/branches/feature',
        '$_root/repository/files/dir%2Ffile.txt',
      });
      final positive = Mr7SuggestionObservation(
        parent: _parent,
        discussionId: 'discussion-a',
        noteId: 17,
        suggestionId: 5,
        path: 'dir/file.txt',
        ref: 'feature',
        sha: _newSha,
        blobSha: _blob(after),
        bytes: after,
      );
      expect(await witness.observe(positive), isTrue);
      final other = utf8.encode('other\n');
      await _reject(
        witness.observe(
          Mr7SuggestionObservation(
            parent: _parent,
            discussionId: 'discussion-b',
            noteId: 18,
            suggestionId: 6,
            path: 'dir/file.txt',
            ref: 'feature',
            sha: _newSha,
            blobSha: _blob(other),
            bytes: other,
          ),
        ),
      );
      // Keep the dispatched identifiers while substituting another suggestion's
      // result. Matching the observed file alone must not make it attributable.
      after = other;
      await _reject(
        witness.observe(
          Mr7SuggestionObservation(
            parent: _parent,
            discussionId: 'discussion-a',
            noteId: 17,
            suggestionId: 5,
            path: 'dir/file.txt',
            ref: 'feature',
            sha: _newSha,
            blobSha: _blob(other),
            bytes: other,
          ),
        ),
      );
    },
  );

  test(
    'publishDraftNotes matches each original draft to a new public MR note',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = await _session(server);
      var sent = false;
      final drafts = <Object?>[
        {
          'id': 10,
          'author_id': 7,
          'merge_request_id': 400,
          'discussion_id': null,
          'note': 'First text',
        },
        {
          'id': 11,
          'author_id': 7,
          'merge_request_id': 400,
          'discussion_id': null,
          'note': 'Second text',
        },
      ];
      var omitSecond = false;
      Map<String, Object?> note(int id, String body) => {
        'id': id,
        'body': body,
        'author': {'id': 7},
        'noteable_id': 400,
        'noteable_type': 'MergeRequest',
        'project_id': 909,
        'system': false,
        'internal': false,
      };
      server.routes['GET $_mr'] = (_) => mr7Json(_mrRow());
      server.routes['GET $_mr/draft_notes'] = (r) =>
          _page(r, sent ? [] : drafts);
      server.routes['GET $_mr/notes'] = (r) => _page(r, [
        note(20, 'previous'),
        if (sent) note(21, 'First text'),
        if (sent && !omitSecond) note(22, 'Second text'),
      ]);
      server.routes['GET $_mr/discussions'] = (r) => _page(r, []);
      server.routes['POST $_mr/draft_notes/bulk_publish'] = (_) {
        sent = true;
        return mr7Json({}, status: 204);
      };
      final permit = _permit(
        session,
        'publishDraftNotes',
        {'POST $_mr/draft_notes/bulk_publish'},
        arguments: {'projectId': 909, 'iid': 4},
      );
      await session.writer.post<Object?>('$_mr/draft_notes/bulk_publish');
      final witness = _readback(session, permit, {
        _mr,
        '$_mr/draft_notes',
        '$_mr/notes',
        '$_mr/discussions',
      });
      final observation = Mr7PublishedDraftsObservation(
        parent: _parent,
        drafts: const {10: 'First text', 11: 'Second text'},
      );
      expect(await witness.observe(observation), isTrue);
      omitSecond = true;
      await _reject(witness.observe(observation));
    },
  );

  test(
    'schedule play correlates a new pipeline under the exact schedule',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = await _session(server);
      var sent = false;
      var createdAt = '';
      server.routes['GET $_root/pipeline_schedules'] = (r) => _page(r, [
        {
          'id': 6,
          'ref': 'refs/heads/main',
          'owner': {'id': 7},
          'active': false,
        },
      ]);
      server.routes['GET $_root/pipeline_schedules/6'] = (_) => mr7Json({
        'id': 6,
        'ref': 'refs/heads/main',
        'owner': {'id': 7},
        'active': false,
        'variables': <Object?>[],
        'inputs': <Object?>[],
      });
      server.routes['GET $_root/pipeline_schedules/6/pipelines'] = (r) =>
          _page(r, [
            if (sent)
              {
                'id': 70,
                'project_id': 909,
                'ref': 'main',
                'source': 'schedule',
                'created_at': createdAt,
              },
          ]);
      server.routes['POST $_root/pipeline_schedules/6/play'] = (_) {
        sent = true;
        server.clock = server.clock.add(const Duration(seconds: 1));
        createdAt = server.clock.toIso8601String();
        return mr7Json({'message': '201 Created'}, status: 201);
      };
      final permit = _permit(
        session,
        'playPipelineSchedule',
        {'POST $_root/pipeline_schedules/6/play'},
        arguments: {'projectId': 909, 'scheduleId': 6},
      );
      await session.writer.get<Object?>('$_root/pipeline_schedules/6');
      await session.writer.post<Object?>(
        '$_root/pipeline_schedules/6/play',
        data: <String, Object?>{},
      );
      final witness = _readback(session, permit, {
        '$_root/pipeline_schedules',
        '$_root/pipeline_schedules/6/pipelines',
      });
      final observation = Mr7SchedulePipelineObservation(
        scheduleId: 6,
        ref: 'refs/heads/main',
        pipelineId: 70,
      );
      final result = await witness.observe(observation);
      expect(result['id'], 70);
      createdAt = DateTime.utc(2026, 10, 28).toIso8601String();
      await _reject(witness.observe(observation));
    },
  );

  test(
    'legacy cancellation requires failed current endpoint and actual fallback',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = await _session(server);
      var enabled = true;
      var contradictory = false;
      server.routes['GET $_mr'] = (_) {
        final row = _mrRow(enabled: enabled)..remove('auto_merge_enabled');
        if (contradictory) row['auto_merge_enabled'] = true;
        return mr7Json(row);
      };
      server.routes['POST $_mr/cancel_auto_merge'] = (_) =>
          mr7Json({'message': 'Not found'}, status: 404);
      server.routes['POST $_mr/cancel_merge_when_pipeline_succeeds'] = (_) {
        enabled = false;
        return mr7Json({'status': 'success'});
      };
      final permit = _permit(
        session,
        'cancelAutoMerge',
        {
          'POST $_mr/cancel_auto_merge',
          'POST $_mr/cancel_merge_when_pipeline_succeeds',
        },
        arguments: {'projectId': 909, 'iid': 4},
        maxMutations: 2,
      );
      try {
        await session.writer.post<Object?>(
          '$_mr/cancel_auto_merge',
          data: <String, Object?>{},
        );
      } on DioException catch (_) {
        /* The production port falls back after this failure. */
      }
      await session.writer.post<Object?>(
        '$_mr/cancel_merge_when_pipeline_succeeds',
        data: <String, Object?>{},
      );
      final witness = _readback(session, permit, {_mr});
      expect(
        await witness.observe(
          const Mr7LegacyCancelObservation(parent: _parent),
        ),
        isTrue,
      );
      enabled = true;
      await _reject(
        witness.observe(const Mr7LegacyCancelObservation(parent: _parent)),
      );
      enabled = false;
      contradictory = true;
      await _reject(
        witness.observe(const Mr7LegacyCancelObservation(parent: _parent)),
      );
    },
  );

  test(
    'terminal project deletion uses actor and complete personal inventory',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = await _session(server);
      server.routes['GET users/7/projects'] = (r) =>
          _page(r, [if (server.project != null) server.project]);
      server.routes['GET projects/synthetic-owner/mr7-testnonce123'] = (_) =>
          server.project == null
          ? mr7Json({}, status: 404)
          : mr7Json(server.project);
      server.routes['DELETE $_root'] = (_) {
        server.project = null;
        return mr7Json({}, status: 202);
      };
      final permit = _permit(
        session,
        'deleteProject',
        {'DELETE $_root'},
        arguments: {'projectId': 909},
      );
      await session.writer.delete<Object?>(_root);
      final witness = _readback(session, permit, {_root, 'users/7/projects'});
      expect(
        await witness.observe(const Mr7ProjectDeletionObservation()),
        isTrue,
      );
    },
  );

  test('terminal project deletion cannot be proven by the finalizer', () async {
    final server = Mr7SyntheticGitLab();
    final session = await _session(server);
    server.routes['GET users/7/projects'] = (r) =>
        _page(r, [if (server.project != null) server.project]);
    final permit = _permit(
      session,
      'deleteProject',
      {'DELETE $_root'},
      arguments: {'projectId': 909},
    );
    final witness = _readback(session, permit, {_root, 'users/7/projects'});
    await session.finish();
    expect(server.cleanupWrites, 1);
    await _reject(witness.observe(const Mr7ProjectDeletionObservation()));
  });

  test(
    'legacy cancel refuses fallback before dispatch after 403 or success',
    () async {
      for (final status in [403, 200]) {
        final server = Mr7SyntheticGitLab();
        final session = await _session(server);
        server.routes['GET $_mr'] = (_) => mr7Json(_mrRow(enabled: true));
        server.routes['POST $_mr/cancel_auto_merge'] = (_) =>
            mr7Json({'message': 'response'}, status: status);
        server.routes['POST $_mr/cancel_merge_when_pipeline_succeeds'] = (_) =>
            mr7Json({'status': 'success'});
        _permit(
          session,
          'cancelAutoMerge',
          {
            'POST $_mr/cancel_auto_merge',
            'POST $_mr/cancel_merge_when_pipeline_succeeds',
          },
          arguments: {'projectId': 909, 'iid': 4},
          maxMutations: 2,
        );
        try {
          await session.writer.post<Object?>(
            '$_mr/cancel_auto_merge',
            data: <String, Object?>{},
          );
        } on DioException catch (_) {}
        await expectLater(
          session.writer.post<Object?>(
            '$_mr/cancel_merge_when_pipeline_succeeds',
            data: <String, Object?>{},
          ),
          throwsA(anything),
        );
        expect(
          server.requests,
          isNot(contains('POST $_mr/cancel_merge_when_pipeline_succeeds')),
          reason: 'first status $status',
        );
      }
    },
  );

  test('legacy cancel refuses fallback-only dispatch', () async {
    final server = Mr7SyntheticGitLab();
    final session = await _session(server);
    server.routes['GET $_mr'] = (_) => mr7Json(_mrRow(enabled: true));
    server.routes['POST $_mr/cancel_merge_when_pipeline_succeeds'] = (_) =>
        mr7Json({'status': 'success'});
    _permit(
      session,
      'cancelAutoMerge',
      {'POST $_mr/cancel_merge_when_pipeline_succeeds'},
      arguments: {'projectId': 909, 'iid': 4},
      maxMutations: 2,
    );
    await expectLater(
      session.writer.post<Object?>(
        '$_mr/cancel_merge_when_pipeline_succeeds',
        data: <String, Object?>{},
      ),
      throwsA(anything),
    );
    expect(
      server.requests,
      isNot(contains('POST $_mr/cancel_merge_when_pipeline_succeeds')),
    );
  });

  test(
    'terminal deletion accepts retained owned project marked pending',
    () async {
      final server = Mr7SyntheticGitLab();
      final session = await _session(server);
      server.routes['GET users/7/projects'] = (r) =>
          _page(r, [if (server.project != null) server.project]);
      server.routes['DELETE $_root'] = (_) {
        server.project!['marked_for_deletion_on'] = '2026-10-30';
        return mr7Json({}, status: 202);
      };
      final permit = _permit(
        session,
        'deleteProject',
        {'DELETE $_root'},
        arguments: {'projectId': 909},
      );
      await session.writer.delete<Object?>(_root);
      final witness = _readback(session, permit, {_root, 'users/7/projects'});
      expect(
        await witness.observe(const Mr7ProjectDeletionObservation()),
        isTrue,
      );
      expect(witness.projectDeletionState, 'pending');
      _permit(session, 'setStar', {'POST $_root/star'});
      await expectLater(
        session.writer.post<Object?>('$_root/star'),
        throwsA(anything),
      );
      expect(server.requests, isNot(contains('POST $_root/star')));
    },
  );

  test('terminal deletion rejects incomplete personal inventory', () async {
    final server = Mr7SyntheticGitLab();
    final session = await _session(server);
    var sent = false;
    server.routes['GET users/7/projects'] = (r) => sent
        ? mr7Json(
            <Object?>[],
            headers: {
              ..._headers(1, 2, perPage: 1),
              'x-next-page': [''],
            },
          )
        : _page(r, [server.project]);
    server.routes['GET projects/synthetic-owner/mr7-testnonce123'] = (_) =>
        server.project == null
        ? mr7Json({}, status: 404)
        : mr7Json(server.project);
    server.routes['DELETE $_root'] = (_) {
      sent = true;
      server.project = null;
      return mr7Json({}, status: 202);
    };
    final permit = _permit(
      session,
      'deleteProject',
      {'DELETE $_root'},
      arguments: {'projectId': 909},
    );
    await session.writer.delete<Object?>(_root);
    await _reject(
      _readback(session, permit, {
        _root,
        'users/7/projects',
      }).observe(const Mr7ProjectDeletionObservation()),
    );
  });

  test('deleteBoardList rejects malformed list ID before dispatch', () async {
    final server = Mr7SyntheticGitLab();
    final session = await _session(server);
    server.routes['GET $_root/boards/12'] = (_) => mr7Json({
      'id': 12,
      'name': 'Board',
      'project': {'id': 909},
    });
    server.routes['GET $_root/boards/12/lists'] = (r) => _page(r, [
      {'id': '52', 'position': 0, 'list_type': 'label'},
    ]);
    server.routes['DELETE $_root/boards/12/lists/52'] = (_) =>
        mr7Json({}, status: 204);
    _permit(session, 'deleteBoardList', {'DELETE $_root/boards/12/lists/52'});
    await expectLater(
      session.writer.delete<Object?>('$_root/boards/12/lists/52'),
      throwsA(anything),
    );
    expect(
      server.requests,
      isNot(contains('DELETE $_root/boards/12/lists/52')),
    );
  });

  test('schedule play refuses an active schedule before dispatch', () async {
    final server = Mr7SyntheticGitLab();
    final session = await _session(server);
    server.routes['GET $_root/pipeline_schedules'] = (r) => _page(r, [
      {
        'id': 6,
        'ref': 'refs/heads/main',
        'active': true,
        'owner': {'id': 7},
      },
    ]);
    server.routes['GET $_root/pipeline_schedules/6'] = (_) => mr7Json({
      'id': 6,
      'ref': 'refs/heads/main',
      'active': true,
      'owner': {'id': 7},
      'variables': <Object?>[],
      'inputs': <Object?>[],
    });
    server.routes['GET $_root/pipeline_schedules/6/pipelines'] = (r) =>
        _page(r, []);
    server.routes['POST $_root/pipeline_schedules/6/play'] = (_) =>
        mr7Json({'message': '201 Created'}, status: 201);
    _permit(
      session,
      'playPipelineSchedule',
      {'POST $_root/pipeline_schedules/6/play'},
      arguments: {'projectId': 909, 'scheduleId': 6},
    );
    await session.writer.get<Object?>('$_root/pipeline_schedules/6');
    await expectLater(
      session.writer.post<Object?>(
        '$_root/pipeline_schedules/6/play',
        data: <String, Object?>{},
      ),
      throwsA(anything),
    );
    expect(
      server.requests,
      isNot(contains('POST $_root/pipeline_schedules/6/play')),
    );
  });
}
