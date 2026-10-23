import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/merge_request_state.dart' as core;
import 'package:gitlab_mobile/features/workspace/work_item_page.dart' as screen;

import '../support/fake_adapter.dart';

typedef _Write = Future<void> Function(GitLabApi api);
typedef _Shape = (String, String, List<String>, _Write);

String _screenSource(String file) =>
    File('lib/features/workspace/$file.dart').readAsStringSync();

void main() {
  final shapes = <_Shape>[
    (
      'deleteIssue',
      'DELETE',
      ['projects', '42', 'issues', '12'],
      (api) => api.deleteIssue(42, 12),
    ),
    (
      'deleteMergeRequest',
      'DELETE',
      ['projects', '42', 'merge_requests', '12'],
      (api) => api.deleteMergeRequest(42, 12),
    ),
    for (final resource in ['issues', 'merge_requests']) ...[
      (
        'deleteNote $resource',
        'DELETE',
        ['projects', '42', resource, '12', 'notes', '9'],
        (api) => api.deleteNote(42, resource, 12, 9),
      ),
      (
        'deleteDiscussionNote $resource',
        'DELETE',
        [
          'projects', '42', resource, '12', 'discussions',
          'thread/part #?%', 'notes', '9',
        ],
        (api) => api.deleteDiscussionNote(
          42, resource, 12, 'thread/part #?%', 9,
        ),
      ),
    ],
    (
      'deleteDraftNote',
      'DELETE',
      ['projects', '42', 'merge_requests', '12', 'draft_notes', '9'],
      (api) => api.deleteDraftNote(42, 12, 9),
    ),
    (
      'publishDraftNotes',
      'POST',
      ['projects', '42', 'merge_requests', '12', 'draft_notes', 'bulk_publish'],
      (api) => api.publishDraftNotes(42, 12),
    ),
    (
      'deleteBoardList',
      'DELETE',
      ['projects', '42', 'boards', '5', 'lists', '6'],
      (api) => api.deleteBoardList(42, 5, 6),
    ),
    (
      'deleteBoard',
      'DELETE',
      ['projects', '42', 'boards', '5'],
      (api) => api.deleteBoard(42, 5),
    ),
  ];

  for (final (name, method, path, write) in shapes) {
    test('$name preserves the generic request byte for byte', () async {
      final adapter = FakeAdapter((_) => jsonResponse(null, status: 204));
      final api = testApi(adapter, host: 'https://example.com:8443/nested/gitlab');
      addTearDown(api.close);

      if (method == 'POST') {
        await api.writeEmpty(method, path);
      } else {
        await api.removeRecord(path);
      }
      await write(api);

      expect(adapter.requests, hasLength(2));
      final legacy = adapter.requests.first;
      final named = adapter.requests.last;
      expect(named.method, method);
      expect(utf8.encode(named.method), utf8.encode(legacy.method));
      expect(
        utf8.encode(named.uri.toString()),
        utf8.encode(legacy.uri.toString()),
      );
      expect(named.uri.pathSegments, [
        'nested', 'gitlab', 'api', 'v4', ...path,
      ]);
      expect(named.uri.query, isEmpty);
      expect(named.data, legacy.data);
      expect(named.data, method == 'POST' ? <String, Object?>{} : null);
      expect(named.followRedirects, isFalse);
    });
  }

  const calls = <String, List<String>>{
    'work_item_page': [
      "if (owner.resource == 'issues')",
      'owner.api.deleteIssue(owner.project.id, owner.iid)',
      'owner.api.deleteMergeRequest(owner.project.id, owner.iid)',
    ],
    'discussions_tab': [
      'if (discussion == null)',
      'widget.api.deleteNote(widget.project.id, widget.resource, widget.iid, noteId)',
      'widget.api.deleteDiscussionNote(widget.project.id, widget.resource, widget.iid, discussion, noteId)',
    ],
    'draft_review_page': [
      'scope.api.deleteDraftNote(scope.project.id, scope.iid, id)',
      'scope.api.publishDraftNotes(scope.project.id, scope.iid)',
    ],
    'boards_page': [
      'api.deleteBoardList(projectId, board.id, listId)',
      'api.deleteBoard(projectId, board.id)',
    ],
  };
  for (final entry in calls.entries) {
    test('${entry.key} uses its named writes without generic channels', () {
      // Extension methods resolve statically, so HTTP parity alone cannot
      // distinguish a named screen call from the old generic call.
      final source = _screenSource(entry.key);
      final compact = source.replaceAll(RegExp(r'\s+'), '');
      for (final call in entry.value) {
        expect(
          compact.contains(call.replaceAll(RegExp(r'\s+'), '')),
          isTrue,
          reason: '${entry.key}: $call',
        );
      }
      expect(
        RegExp(r'\.(?:removeRecord|writeRecord|writeEmpty)\s*\(')
            .hasMatch(source),
        isFalse,
      );
    });
  }

  test('work item page re-exports the shared auto-merge functions', () {
    expect(identical(screen.isAutoMergeEnabled, core.isAutoMergeEnabled), isTrue);
    expect(identical(screen.canAutoMerge, core.canAutoMerge), isTrue);
  });
}
