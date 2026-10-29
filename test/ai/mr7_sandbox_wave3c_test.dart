import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';

import '../../tool/mr7/sandbox_contract.dart';
import '../../tool/mr7_sandbox.dart' as sandbox;

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

Future<void> _refused(Future<Object?> future, String code) async {
  Object? caught;
  try {
    await future;
  } catch (error) {
    caught = error;
  }
  while (caught is DioException) {
    caught = caught.error;
  }
  expect(caught, isA<Mr7Refused>());
  expect((caught as Mr7Refused).code, code);
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
    'applySuggestion verifies ownership with default captureEffects',
    () async {
      for (final scenario in [
        'valid',
        'missing binding',
        'foreign suggestion',
        'invalid parent',
        'unreadable',
      ]) {
        final server = Mr7SyntheticGitLab();
        final session = await _session(server);
        final arguments = <String, Object?>{
          'projectId': 909,
          'iid': 4,
          'noteId': 17,
          'suggestionId': 5,
          if (scenario != 'missing binding') 'discussionId': 'discussion-a',
        };
        server.routes['GET $_mr'] = (_) => mr7Json(
          scenario == 'invalid parent'
              ? {..._mrRow(), 'project_id': 123}
              : _mrRow(),
        );
        server.routes['GET $_mr/discussions/discussion-a'] = (_) =>
            scenario == 'unreadable'
            ? mr7Json({}, status: 403)
            : mr7Json({
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
                        'id': scenario == 'foreign suggestion' ? 6 : 5,
                        'appliable': true,
                        'applied': false,
                        'from_content': 'old\n',
                        'to_content': 'new\n',
                        'from_line': 1,
                        'to_line': 1,
                      },
                    ],
                  },
                ],
              });
        server.routes['PUT suggestions/5/apply'] = (_) => mr7Json({'id': 5});
        final permit = Mr7MutationPermit(
          operation: 'applySuggestion',
          resourceProjectId: 909,
          paths: {'PUT suggestions/5/apply'},
          callArguments: arguments,
        )..confirmed = true;
        session.permit = permit;
        final send = session.writer.put<Object?>(
          'suggestions/5/apply',
          data: <String, Object?>{},
        );
        if (scenario == 'valid') {
          await send;
          expect(permit.sent, 1);
          expect(server.requests, contains('PUT suggestions/5/apply'));
        } else {
          final code = switch (scenario) {
            'missing binding' => 'observerMutationTarget',
            'foreign suggestion' => 'observerDiscussion',
            'invalid parent' => 'observerParent',
            _ => 'observerUnreadable',
          };
          await _refused(send, code);
          expect(permit.sent, 0, reason: scenario);
          expect(
            server.requests,
            isNot(contains('PUT suggestions/5/apply')),
            reason: scenario,
          );
        }
      }
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
      server.routes['GET $_mr/discussions'] = (r) => _page(r, [
        {
          'id': 'existing',
          'individual_note': true,
          'notes': [note(20, 'previous')],
        },
        if (sent)
          {
            'id': 'new-first',
            'individual_note': false,
            'notes': [note(21, 'First text')],
          },
        if (sent && !omitSecond)
          {
            'id': 'new-second',
            'individual_note': true,
            'notes': [note(22, 'Second text')],
          },
      ]);
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
      await _refused(witness.observe(observation), 'observerPublishedNote');
    },
  );

  test('published drafts enforce thread identity and position', () async {
    for (final scenario in [
      'wrong existing thread',
      'correct reply',
      'wrong reply',
      'positioned new',
      'wrong position',
      'missing position',
      'unexpected position',
      'incomplete draft position',
      'multiline draft position',
      'published multiline position',
    ]) {
      final server = Mr7SyntheticGitLab();
      final session = await _session(server);
      var sent = false;
      final reply = scenario == 'correct reply' || scenario == 'wrong reply';
      final positioned =
          scenario == 'positioned new' ||
          scenario == 'wrong position' ||
          scenario == 'missing position' ||
          scenario == 'incomplete draft position' ||
          scenario == 'multiline draft position' ||
          scenario == 'published multiline position';
      final position = <String, Object?>{
        'position_type': 'text',
        'base_sha': _oldSha,
        'start_sha': _oldSha,
        'head_sha': _oldSha,
        'old_path': 'dir/file.txt',
        'new_path': 'dir/file.txt',
        'old_line': 1,
        'new_line': 2,
      };
      final range = <String, Object?>{
        'start': {'type': 'new', 'new_line': 2},
        'end': {'type': 'new', 'new_line': 3},
      };
      final draftPosition = scenario == 'incomplete draft position'
          ? ({...position}..remove('head_sha'))
          : scenario == 'multiline draft position'
          ? {...position, 'line_range': range}
          : position;
      Map<String, Object?> note(
        int id,
        String body, {
        Map<String, Object?>? position,
      }) => {
        'id': id,
        'body': body,
        'author': {'id': 7},
        'noteable_id': 400,
        'noteable_type': 'MergeRequest',
        'project_id': 909,
        'system': false,
        'internal': false,
        'position': ?position,
      };
      final publishedPosition = scenario == 'missing position'
          ? null
          : scenario == 'wrong position'
          ? {...position, 'new_line': 3}
          : scenario == 'published multiline position'
          ? {...position, 'line_range': range}
          : positioned || scenario == 'unexpected position'
          ? position
          : null;
      final published = note(21, 'Same text', position: publishedPosition);
      server.routes['GET $_mr'] = (_) => mr7Json(_mrRow());
      server.routes['GET $_mr/draft_notes'] = (r) => _page(
        r,
        sent
            ? []
            : [
                {
                  'id': 10,
                  'author_id': 7,
                  'merge_request_id': 400,
                  'discussion_id': reply ? 'thread-a' : null,
                  'note': 'Same text',
                  if (positioned) 'position': draftPosition,
                },
              ],
      );
      server.routes['GET $_mr/notes'] = (r) =>
          _page(r, [note(19, 'a'), note(20, 'b'), if (sent) published]);
      final publishedThread = switch (scenario) {
        'correct reply' => 'thread-a',
        'wrong existing thread' || 'wrong reply' => 'thread-b',
        _ => 'new-thread',
      };
      server.routes['GET $_mr/discussions'] = (r) => _page(r, [
        {
          'id': 'thread-a',
          'individual_note': false,
          'notes': [
            note(19, 'a'),
            if (sent && publishedThread == 'thread-a') published,
          ],
        },
        {
          'id': 'thread-b',
          'individual_note': false,
          'notes': [
            note(20, 'b'),
            if (sent && publishedThread == 'thread-b') published,
          ],
        },
        if (sent && publishedThread == 'new-thread')
          {
            'id': 'new-thread',
            'individual_note': false,
            'notes': [published],
          },
      ]);
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
      if (scenario == 'incomplete draft position' ||
          scenario == 'multiline draft position') {
        await _refused(
          session.writer.post<Object?>('$_mr/draft_notes/bulk_publish'),
          'observerDrafts',
        );
        expect(permit.sent, 0, reason: scenario);
        expect(
          server.requests,
          isNot(contains('POST $_mr/draft_notes/bulk_publish')),
          reason: scenario,
        );
        continue;
      }
      await session.writer.post<Object?>('$_mr/draft_notes/bulk_publish');
      final witness = _readback(session, permit, {
        _mr,
        '$_mr/draft_notes',
        '$_mr/notes',
        '$_mr/discussions',
      });
      final observation = Mr7PublishedDraftsObservation(
        parent: _parent,
        drafts: const {10: 'Same text'},
      );
      if (scenario == 'correct reply' || scenario == 'positioned new') {
        expect(await witness.observe(observation), isTrue, reason: scenario);
      } else {
        await _refused(witness.observe(observation), 'observerPublishedNote');
      }
    }
  });

  test('schedule play remains closed without reading stored inputs', () async {
    for (final captureEffects in [false, true]) {
      for (final prepare in [false, true]) {
        final server = Mr7SyntheticGitLab();
        final session = await _session(server);
        var targetInputs = <Object?>[];
        server.routes['GET $_root/pipeline_schedules'] = (r) => _page(r, [
          {'id': 6, 'inputs': targetInputs},
          {
            'id': 7,
            'inputs': [
              {'name': 'other', 'value': 'private'},
            ],
          },
        ]);
        server.routes['GET $_root/pipeline_schedules/6'] = (_) => mr7Json({
          'id': 6,
          'ref': 'refs/heads/main',
          'owner': {'id': 7},
          'active': false,
          'inputs': targetInputs,
          'variables': <Object?>[],
        });
        server.routes['GET $_root/pipeline_schedules/6/pipelines'] = (r) =>
            _page(r, []);
        server.routes['POST $_root/pipeline_schedules/6/play'] = (_) =>
            mr7Json({}, status: 201);
        final permit = Mr7MutationPermit(
          operation: 'playPipelineSchedule',
          resourceProjectId: 909,
          paths: {'POST $_root/pipeline_schedules/6/play'},
          callArguments: {'projectId': 909, 'scheduleId': 6},
          captureEffects: captureEffects,
        )..confirmed = true;
        session.permit = permit;
        if (prepare) {
          await session.writer.get<Object?>('$_root/pipeline_schedules/6');
          targetInputs = [
            {'name': 'changed', 'value': 'private'},
          ];
        }
        final before = List<String>.of(server.requests);
        await _refused(
          session.writer.post<Object?>(
            '$_root/pipeline_schedules/6/play',
            data: <String, Object?>{},
          ),
          'scheduleParametersUnproven',
        );
        final subsequent = server.requests.skip(before.length).toList();
        expect(subsequent, isNot(contains('GET $_root/pipeline_schedules')));
        expect(subsequent, isNot(contains('GET $_root/pipeline_schedules/6')));
        expect(
          subsequent,
          isNot(contains('GET $_root/pipeline_schedules/6/pipelines')),
        );
        expect(
          subsequent,
          isNot(contains('POST $_root/pipeline_schedules/6/play')),
        );
        expect(permit.sent, 0);
      }
    }
  });

  test(
    'readback deadline cancels delayed and never completing reads',
    () async {
      for (final scenario in ['delayed', 'never', 'later page']) {
        final server = Mr7SyntheticGitLab();
        final session = await _session(server);
        var sent = false;
        final blocked = Completer<ResponseBody>();
        server.routes['GET $_root/boards/12'] = (_) => mr7Json({
          'id': 12,
          'name': 'Board',
          'project': {'id': 909},
        });
        server.routes['GET $_root/boards/12/lists'] = (r) {
          if (!sent) {
            return _page(r, [
              {'id': 52, 'position': 0, 'list_type': 'label'},
            ]);
          }
          if (scenario == 'later page' &&
              '${r.queryParameters['page']}' == '1') {
            return _page(r, [
              {'id': 51, 'position': 0, 'list_type': 'label'},
              {'id': 53, 'position': 1, 'list_type': 'label'},
            ], size: 1);
          }
          return blocked.future;
        };
        server.routes['DELETE $_root/boards/12/lists/52'] = (_) {
          sent = true;
          return mr7Json({}, status: 204);
        };
        final permit = _permit(session, 'deleteBoardList', {
          'DELETE $_root/boards/12/lists/52',
        });
        await session.writer.delete<Object?>('$_root/boards/12/lists/52');
        final witness = Mr7Readback(
          session,
          session.identity!,
          permit,
          paths: {'$_root/boards/12', '$_root/boards/12/lists'},
          timeout: const Duration(milliseconds: 60),
        );
        final lateResponse = scenario == 'delayed'
            ? Future<void>.delayed(const Duration(milliseconds: 150), () {
                blocked.complete(mr7Json(<Object?>[]));
              })
            : null;
        final watch = Stopwatch()..start();
        await _refused(
          witness
              .observe(
                const Mr7DeletedBoardListObservation(boardId: 12, listId: 52),
              )
              .timeout(const Duration(milliseconds: 500)),
          'observerTimeout',
        );
        expect(
          watch.elapsed,
          lessThan(const Duration(milliseconds: 400)),
          reason: scenario,
        );
        final requestsAtTimeout = List<String>.of(server.requests);
        final creditAtTimeout = witness.verifiedRequests;
        if (lateResponse == null) {
          blocked.complete(
            _page(
              RequestOptions(
                path: '/',
                queryParameters: {'page': scenario == 'later page' ? 2 : 1},
              ),
              [],
            ),
          );
        } else {
          await lateResponse;
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(server.requests, requestsAtTimeout, reason: scenario);
        expect(witness.verifiedRequests, creditAtTimeout, reason: scenario);
        expect(creditAtTimeout, 0, reason: scenario);
      }
    },
  );

  test('readback deadline covers initial identity and streamed body', () async {
    for (final scenario in ['identity', 'stream', 'success']) {
      final server = Mr7SyntheticGitLab();
      final session = await _session(server);
      var sent = false;
      server.routes['GET $_root/boards/12'] = (_) => mr7Json({
        'id': 12,
        'name': 'Board',
        'project': {'id': 909},
      });
      final identityResponse = Completer<ResponseBody>();
      var streamCancelled = false;
      final body = StreamController<Uint8List>.broadcast(
        onCancel: () {
          streamCancelled = true;
        },
      );
      server.routes['GET $_root/boards/12/lists'] = (r) {
        if (!sent) {
          return _page(r, [
            {'id': 52, 'position': 0, 'list_type': 'label'},
          ]);
        }
        if (scenario == 'stream') {
          return ResponseBody(
            body.stream,
            200,
            headers: {
              ..._headers(1, 0),
              'content-type': ['application/json'],
            },
          );
        }
        return _page(r, []);
      };
      server.routes['DELETE $_root/boards/12/lists/52'] = (_) {
        sent = true;
        return mr7Json({}, status: 204);
      };
      final permit = _permit(session, 'deleteBoardList', {
        'DELETE $_root/boards/12/lists/52',
      });
      await session.writer.delete<Object?>('$_root/boards/12/lists/52');
      if (scenario == 'identity') {
        server.routes['GET user'] = (_) => identityResponse.future;
      }
      final witness = Mr7Readback(
        session,
        session.identity!,
        permit,
        paths: {'$_root/boards/12', '$_root/boards/12/lists'},
        timeout: const Duration(milliseconds: 60),
      );
      final observe = witness
          .observe(
            const Mr7DeletedBoardListObservation(boardId: 12, listId: 52),
          )
          .timeout(const Duration(milliseconds: 500));
      if (scenario == 'success') {
        expect(await observe, isTrue);
        expect(witness.verifiedRequests, greaterThan(0));
      } else {
        await _refused(observe, 'observerTimeout');
        final requests = List<String>.of(server.requests);
        final credit = witness.verifiedRequests;
        if (scenario == 'identity') {
          identityResponse.complete(
            mr7Json({'id': 7, 'username': 'synthetic-owner'}),
          );
        } else {
          expect(streamCancelled, isTrue);
          body.add(Uint8List.fromList(utf8.encode('[]')));
        }
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(server.requests, requests, reason: scenario);
        expect(witness.verifiedRequests, credit, reason: scenario);
        expect(credit, 0);
      }
      await body.close();
    }
  });

  test('runner closes schedule scenario before fixture and provider', () async {
    var fixtureCalls = 0;
    var providerCalls = 0;
    final scenario = sandbox.Mr7Scenario(
      id: 'schedule-closed',
      suite: 'rest',
      operation: 'playPipelineSchedule',
      variant: 'empty',
      tier: 'T1',
      fixture: (_, _) async {
        fixtureCalls++;
        return const sandbox.Mr7ScenarioFixtures();
      },
      call: (identity) {
        providerCalls++;
        return AiToolCall(
          id: 'schedule-closed',
          name: 'playPipelineSchedule',
          arguments: {'projectId': identity.projectId, 'scheduleId': 6},
        );
      },
      paths: (identity) => {
        'POST projects/${identity.projectId}/pipeline_schedules/6/play',
      },
      observe: (_, _) async => true,
    );
    final receipt = await sandbox.runMr7Sandbox(
      policy: Mr7Policy.candidate,
      releaseSha: _oldSha,
      session: Mr7SandboxSession(
        server: Mr7SyntheticGitLab(),
        nonce: 'testnonce123',
        eventDelay: () async {},
      ),
      scenarios: [scenario],
      confirm: (_) async => true,
    );
    final row = (receipt['scenarios'] as List).single as Map;
    expect(row['status'], 'NOT_RUN');
    expect(row['classification'], 'closedVariant');
    expect(row['refusal'], {
      'type': 'closedVariant',
      'cause': 'observerUnavailable',
      'code': 'scheduleParametersUnproven',
    });
    expect(row['providerCalls'], 0);
    expect(row['mutationCount'], 0);
    expect(fixtureCalls, 0);
    expect(providerCalls, 0);
  });

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
}
