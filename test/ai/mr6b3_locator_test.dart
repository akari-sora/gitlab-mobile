import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import '../support/fake_adapter.dart';

const _path = 'team/example-42';
const _workItemId = 'gid://gitlab/WorkItem/31';
const _projectId = 'gid://gitlab/Project/42';
const _namespaceId = 'gid://gitlab/Group/77';
const _discussionId = 'gid://gitlab/Discussion/server-owned';
const _replyId = 'gid://gitlab/IndividualNoteDiscussion/server-owned';
const _noteId = 'gid://gitlab/Note/401';

const _scope = AiWriteScope(
  accountKey: 'https://example.com/gitlab#9',
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.workItem,
      projectId: 42,
      projectPath: _path,
      iid: 7,
    ),
  ],
);

final _summary = WorkItemGraphSummary(
  id: _workItemId,
  iid: 7,
  title: 'Synthetic work item',
  state: 'OPEN',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 2),
  project: const GraphResourceRef(id: _projectId, fullPath: _path),
  namespace: const GraphResourceRef(id: _namespaceId, fullPath: 'team'),
  type: const WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/server-owned',
    name: 'Task',
  ),
);

final _detail = WorkItemGraphDetail(
  summary: _summary,
  description: null,
  widgetsAvailable: true,
  widgetTypes: const {},
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

Matcher _refusal(String reason) =>
    isA<AiWriteRefused>().having((error) => error.reason, 'reason', reason);

Map<String, Object?> _pageInfo({bool next = false, String? cursor}) => {
  'hasNextPage': next,
  'endCursor': cursor,
};

Map<String, Object?> _identity() => {
  'id': _workItemId,
  'iid': '7',
  'project': {'id': _projectId, 'fullPath': _path},
  'namespace': {'id': _namespaceId, 'fullPath': 'team'},
};

Map<String, Object?> _note(
  String id, {
  bool system = false,
  Object? author = const {
    'id': 'gid://gitlab/User/9',
    'name': 'Synthetic User',
    'username': 'synthetic-user',
  },
}) => {
  'id': id,
  'system': system,
  'systemNoteIconName': null,
  'body': 'Synthetic note',
  'createdAt': '2026-10-01T01:02:03Z',
  'updatedAt': '2026-10-01T01:03:04Z',
  'author': author,
};

Map<String, Object?> _discussion({
  required List<Object?> notes,
  bool next = false,
  String? cursor,
}) => {
  'id': _discussionId,
  'replyId': _replyId,
  'createdAt': '2026-10-01T01:00:00Z',
  'notes': {'nodes': notes, 'pageInfo': _pageInfo(next: next, cursor: cursor)},
};

Map<String, Object?> _activity({required Object discussion}) => {
  'data': {
    'workItem': {
      ..._identity(),
      'widgets': [
        {
          'type': 'NOTES',
          'discussionLocked': false,
          'discussions': {
            'nodes': [discussion],
            'pageInfo': _pageInfo(),
          },
        },
      ],
    },
  },
};

Never _unexpectedActivityNext(WorkItemActivityContinuation _) =>
    fail('unexpected outer continuation');

Never _unexpectedNotesNext(WorkItemDiscussionNotesContinuation _) =>
    fail('unexpected nested continuation');

void main() {
  test(
    'resolver derives Project from grant and validates exact coordinates',
    () async {
      final location = await resolveAiProjectWorkItem(
        _scope,
        42,
        7,
        readDetail: (project, iid) async {
          expect(project.id, 42);
          expect(project.name, _path);
          expect(project.path, _path);
          expect(iid, 7);
          return _detail;
        },
      );

      expect(location.project.path, _path);
      expect(location.detail, same(_detail));
    },
  );

  test(
    'resolver refuses missing grant path and mismatched project identity',
    () async {
      const missingPath = AiWriteScope(
        accountKey: 'https://example.com/gitlab#9',
        grants: [
          AiScopeGrant(kind: AiScopeKind.workItem, projectId: 42, iid: 7),
        ],
      );
      await expectLater(
        resolveAiProjectWorkItem(
          missingPath,
          42,
          7,
          readDetail: (_, _) async => _detail,
        ),
        throwsA(_refusal('workItemUnverifiable')),
      );
      final wrong = WorkItemGraphDetail(
        summary: WorkItemGraphSummary(
          id: _summary.id,
          iid: _summary.iid,
          title: _summary.title,
          state: _summary.state,
          createdAt: _summary.createdAt,
          updatedAt: _summary.updatedAt,
          project: const GraphResourceRef(
            id: 'gid://gitlab/Project/99',
            fullPath: _path,
          ),
          namespace: _summary.namespace,
          type: _summary.type,
        ),
        description: null,
        widgetsAvailable: true,
        widgetTypes: const {},
        descriptionWidget: null,
        assignees: null,
        labels: null,
        hierarchy: null,
        dates: null,
      );
      await expectLater(
        resolveAiProjectWorkItem(
          _scope,
          42,
          7,
          readDetail: (_, _) async => wrong,
        ),
        throwsA(_refusal('workItemUnverifiable')),
      );
    },
  );

  test('locator returns the exact note and reply target in one read', () async {
    final api = testApi(
      FakeAdapter(
        (_) => jsonResponse(
          _activity(
            discussion: _discussion(
              notes: [
                _note('gid://gitlab/Note/400', system: true, author: null),
                _note(_noteId),
              ],
            ),
          ),
        ),
      ),
    );
    addTearDown(api.close);

    final location = await locateAiWorkItemActivityNote(
      _detail,
      401,
      first: api.workItemActivity,
      next: _unexpectedActivityNext,
      notesNext: _unexpectedNotesNext,
    );

    expect(location.note.id, _noteId);
    expect(location.discussion.id, _discussionId);
    expect(location.replyTarget, isNotNull);
  });

  test('locator shares a strict two-read budget with nested notes', () async {
    var reads = 0;
    final api = testApi(
      FakeAdapter((RequestOptions request) {
        reads += 1;
        final query = ((request.data as Map)['query'] as String);
        if (query.contains('MobileWorkItemActivity(')) {
          return jsonResponse(
            _activity(
              discussion: _discussion(
                notes: [_note(_noteId)],
                next: true,
                cursor: 'notes-a',
              ),
            ),
          );
        }
        return jsonResponse({
          'data': {
            'workItem': _identity(),
            'anchor': {
              'id': _noteId,
              'project': {'id': _projectId, 'fullPath': _path},
              'discussion': _discussion(
                notes: [_note('gid://gitlab/Note/402')],
              ),
            },
          },
        });
      }),
    );
    addTearDown(api.close);

    final location = await locateAiWorkItemActivityNote(
      _detail,
      402,
      first: api.workItemActivity,
      next: _unexpectedActivityNext,
      notesNext: api.workItemDiscussionNotesNext,
    );

    expect(location.note.id, 'gid://gitlab/Note/402');
    expect(location.replyTarget, isNotNull);
    expect(reads, 2);
  });

  test('locator refuses rather than taking a third logical read', () async {
    var reads = 0;
    final api = testApi(
      FakeAdapter((RequestOptions request) {
        reads += 1;
        final query = ((request.data as Map)['query'] as String);
        if (query.contains('MobileWorkItemActivity(')) {
          return jsonResponse(
            _activity(
              discussion: _discussion(
                notes: [_note(_noteId)],
                next: true,
                cursor: 'notes-a',
              ),
            ),
          );
        }
        return jsonResponse({
          'data': {
            'workItem': _identity(),
            'anchor': {
              'id': _noteId,
              'project': {'id': _projectId, 'fullPath': _path},
              'discussion': _discussion(
                notes: [_note('gid://gitlab/Note/402')],
                next: true,
                cursor: 'notes-b',
              ),
            },
          },
        });
      }),
    );
    addTearDown(api.close);

    await expectLater(
      locateAiWorkItemActivityNote(
        _detail,
        999,
        first: api.workItemActivity,
        next: _unexpectedActivityNext,
        notesNext: api.workItemDiscussionNotesNext,
      ),
      throwsA(_refusal('activityUnverifiable')),
    );
    expect(reads, 2);
  });
}
