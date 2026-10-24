import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/work_item_activity_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';

import 'support/fake_adapter.dart';

const _workItemId = 'gid://gitlab/WorkItem/31';
const _projectId = 'gid://gitlab/Project/42';
const _namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/42';
const _path = 'team/example-42';
const _discussionId = 'gid://gitlab/Discussion/server-owned';
const _noteId = 'gid://gitlab/Note/401';
const _replyId = 'gid://gitlab/IndividualNoteDiscussion/server-owned';
const _authorId = 'gid://gitlab/User/9';

final _expected = WorkItemGraphSummary(
  id: _workItemId,
  iid: 7,
  title: 'Synthetic work item',
  state: 'OPEN',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 2),
  project: const GraphResourceRef(id: _projectId, fullPath: _path),
  namespace: const GraphResourceRef(id: _namespaceId, fullPath: _path),
  type: const WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/server-owned',
    name: 'Task',
  ),
);

final _groupExpected = WorkItemGraphSummary(
  id: 'gid://gitlab/WorkItem/41',
  iid: 8,
  title: 'Synthetic group work item',
  state: 'OPEN',
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 2),
  project: null,
  namespace: const GraphResourceRef(
    id: 'gid://gitlab/Group/7',
    fullPath: 'team',
  ),
  type: const WorkItemGraphType(
    id: 'gid://gitlab/WorkItems::Type/group-owned',
    name: 'Epic',
  ),
);

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

Map<String, Object?> _pageInfo({bool next = false, String? cursor}) => {
  'hasNextPage': next,
  'endCursor': cursor,
};

Map<String, Object?> _note({
  String id = _noteId,
  Object? author = const {
    'id': _authorId,
    'name': 'Synthetic User',
    'username': 'synthetic-user',
  },
}) => {
  'id': id,
  'system': false,
  'systemNoteIconName': null,
  'body': 'Synthetic note',
  'createdAt': '2026-10-01T01:02:03Z',
  'updatedAt': '2026-10-01T01:03:04Z',
  'author': author,
};

Map<String, Object?> _discussion({
  String id = _discussionId,
  String replyId = _replyId,
  Object? nodes = const <Object?>[],
  bool notesNext = false,
  String? notesCursor,
}) => {
  'id': id,
  'replyId': replyId,
  'createdAt': '2026-10-01T01:00:00Z',
  'notes': {
    'nodes': nodes,
    'pageInfo': _pageInfo(next: notesNext, cursor: notesCursor),
  },
};

Map<String, Object?> _identity({
  String id = _workItemId,
  Object iid = '7',
  Object? project = const {'id': _projectId, 'fullPath': _path},
  Object? namespace = const {'id': _namespaceId, 'fullPath': _path},
}) => {'id': id, 'iid': iid, 'project': project, 'namespace': namespace};

Map<String, Object?> _activityEnvelope({
  Object? widgets = const <Object?>[],
  String id = _workItemId,
  Object iid = '7',
  Object? project = const {'id': _projectId, 'fullPath': _path},
  Object? namespace = const {'id': _namespaceId, 'fullPath': _path},
}) => {
  'data': {
    'workItem': {
      ..._identity(id: id, iid: iid, project: project, namespace: namespace),
      'widgets': widgets,
    },
  },
};

Map<String, Object?> _notesWidget({
  Object? nodes = const <Object?>[],
  bool next = false,
  String? cursor,
  Object? discussionLocked = false,
}) => {
  'type': 'NOTES',
  'discussionLocked': discussionLocked,
  'discussions': {
    'nodes': nodes,
    'pageInfo': _pageInfo(next: next, cursor: cursor),
  },
};

Map<String, Object?> _schemaError(
  String code,
  String message, {
  Map<String, Object?> details = const {},
}) => {
  'errors': [
    {
      'message': message,
      'extensions': {'code': code, ...details},
    },
  ],
};

Map<String, Object?> _writeAccess({
  WorkItemGraphSummary? expected,
  bool canCreateNote = true,
  String? authorId = _authorId,
  Object? anchor,
  Object? discussionLocked = false,
}) {
  final value = expected ?? _expected;
  return {
    'data': {
      'currentUser': authorId == null ? null : {'id': authorId},
      'workItem': {
        ..._identity(
          id: value.id,
          iid: '${value.iid}',
          project: value.project == null
              ? null
              : {'id': value.project!.id, 'fullPath': value.project!.fullPath},
          namespace: value.namespace == null
              ? null
              : {
                  'id': value.namespace!.id,
                  'fullPath': value.namespace!.fullPath,
                },
        ),
        'userPermissions': {'createNote': canCreateNote},
        'widgets': [_notesWidget(discussionLocked: discussionLocked)],
      },
      'anchor': ?anchor,
    },
  };
}

Map<String, Object?> _writeNote({
  String id = 'gid://gitlab/DiscussionNote/501',
  String body = 'Synthetic note',
  String authorId = _authorId,
  int noteableId = 31,
  String noteableType = 'Issue',
  String discussionId = _discussionId,
  String replyId = _replyId,
  bool internal = false,
  Object? project = const {'id': _projectId, 'fullPath': _path},
}) => {
  ..._note(
    id: id,
    author: {
      'id': authorId,
      'name': 'Synthetic User',
      'username': 'synthetic-user',
    },
  ),
  'body': body,
  'internal': internal,
  'noteableType': noteableType,
  'noteableId': noteableId,
  'project': project,
  'discussion': {
    'id': discussionId,
    'replyId': replyId,
    'createdAt': '2026-10-01T01:00:00Z',
  },
};

Map<String, Object?> _writeAck({Object? note}) => {
  'data': {
    'createNote': {'errors': <Object?>[], 'note': note ?? _writeNote()},
  },
};

Map<String, Object?> _writeReadback({Object? note}) => {
  'data': {'workItem': _identity(), 'note': note ?? _writeNote()},
};

bool _isMutation(RequestOptions request) {
  final data = request.data;
  return data is Map &&
      data['query'] is String &&
      (data['query'] as String).startsWith('mutation ');
}

void main() {
  test(
    'fixed activity query parses bounded discussions and nullable author',
    () async {
      final adapter = FakeAdapter((request) {
        expect(request.uri.path, '/gitlab/api/graphql');
        expect(request.followRedirects, isFalse);
        expect(request.headers['Authorization'], 'Bearer synthetic-test-token');
        expect(request.headers['PRIVATE-TOKEN'], isNull);
        final body = request.data as Map;
        final query = body['query'] as String;
        expect(query, contains('query MobileWorkItemActivity'));
        expect(query, contains(r'workItem(id: $id)'));
        expect(query, contains('WorkItemWidgetNotes'));
        expect(query, contains(r'$filter: NotesFilterType!'));
        expect(query, contains(r'$sort: WorkItemDiscussionsSort!'));
        expect(query, contains(r'filter: $filter'));
        expect(query, contains(r'sort: $sort'));
        expect(query, isNot(contains('avatarUrl')));
        expect(query, isNot(contains('webUrl')));
        expect(body['variables'], {
          'id': _workItemId,
          'after': null,
          'filter': 'ALL_NOTES',
          'sort': 'CREATED_ASC',
        });
        return jsonResponse(
          _activityEnvelope(
            widgets: [
              _notesWidget(
                nodes: [
                  _discussion(nodes: [_note(author: null)]),
                ],
              ),
            ],
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final page = await api.workItemActivity(_expected);

      expect(page.snapshot.availability, WorkItemActivityAvailability.present);
      expect(page.snapshot.project!.fullPath, _path);
      expect(page.snapshot.discussions.items, hasLength(1));
      final note = page.snapshot.discussions.items.single.notes.items.single;
      expect(note.author, isNull);
      expect(note.body, 'Synthetic note');
      expect(note.createdAt.isUtc, isTrue);
      expect(page.nextDiscussions, isNull);
      expect(page.nextNotesByDiscussion, isEmpty);
      expect(page.filter, WorkItemActivityFilter.all);
      expect(page.order, WorkItemActivityOrder.oldestFirst);
      expect(page.controlsSupported, isTrue);
    },
  );

  test('sends every server filter and order combination', () async {
    final expectedPairs = <(WorkItemActivityFilter, WorkItemActivityOrder)>[
      for (final filter in WorkItemActivityFilter.values)
        for (final order in WorkItemActivityOrder.values) (filter, order),
    ];
    var call = 0;
    final api = testApi(
      FakeAdapter((request) {
        final pair = expectedPairs[call++];
        final body = request.data as Map;
        expect(body['variables'], {
          'id': _workItemId,
          'after': null,
          'filter': pair.$1.graphValue,
          'sort': pair.$2.graphValue,
        });
        return jsonResponse(_activityEnvelope());
      }),
    );
    addTearDown(api.close);

    for (final pair in expectedPairs) {
      final page = await api.workItemActivity(
        _expected,
        filter: pair.$1,
        order: pair.$2,
      );
      expect(page.filter, pair.$1);
      expect(page.order, pair.$2);
      expect(page.controlsSupported, isTrue);
    }
    expect(call, expectedPairs.length);
  });

  test('preserves widget and connection availability distinctions', () async {
    final responses = <Object?>[
      _activityEnvelope(widgets: null),
      _activityEnvelope(widgets: const []),
      _activityEnvelope(
        widgets: const [
          {'type': 'NOTES', 'discussionLocked': false, 'discussions': null},
        ],
      ),
      _activityEnvelope(widgets: [_notesWidget(nodes: null)]),
    ];
    var call = 0;
    final api = testApi(FakeAdapter((_) => jsonResponse(responses[call++])));
    addTearDown(api.close);

    final widgetsUnavailable = await api.workItemActivity(_expected);
    final absent = await api.workItemActivity(_expected);
    final connectionUnavailable = await api.workItemActivity(_expected);
    final nodesUnavailable = await api.workItemActivity(_expected);

    expect(
      widgetsUnavailable.snapshot.availability,
      WorkItemActivityAvailability.widgetsUnavailable,
    );
    expect(absent.snapshot.availability, WorkItemActivityAvailability.absent);
    expect(
      connectionUnavailable.snapshot.discussions.availability,
      WorkItemActivityConnectionAvailability.unavailable,
    );
    expect(
      nodesUnavailable.snapshot.discussions.availability,
      WorkItemActivityConnectionAvailability.unavailable,
    );
  });

  test(
    'rejects null list items, duplicates, and mismatched root identity',
    () async {
      final invalid = <Object?>[
        _activityEnvelope(
          widgets: [
            _notesWidget(nodes: [null]),
          ],
        ),
        _activityEnvelope(
          widgets: [
            _notesWidget(nodes: [_discussion(), _discussion()]),
          ],
        ),
        _activityEnvelope(id: 'gid://gitlab/WorkItem/wrong'),
        _activityEnvelope(project: null),
      ];
      for (final response in invalid) {
        final api = testApi(FakeAdapter((_) => jsonResponse(response)));
        await expectLater(
          api.workItemActivity(_expected),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        api.close();
      }
    },
  );

  test('outer continuation is owner-bound and rejects cursor loops', () async {
    var call = 0;
    final firstApi = testApi(
      FakeAdapter((request) {
        call++;
        final variables = (request.data as Map)['variables'] as Map;
        expect(variables['filter'], 'ONLY_COMMENTS');
        expect(variables['sort'], 'CREATED_DESC');
        if (call == 1) {
          expect(variables['after'], isNull);
          return jsonResponse(
            _activityEnvelope(
              widgets: [_notesWidget(next: true, cursor: 'cursor-a')],
            ),
          );
        }
        expect(variables['after'], 'cursor-a');
        return jsonResponse(
          _activityEnvelope(
            widgets: [_notesWidget(next: true, cursor: 'cursor-a')],
          ),
        );
      }),
    );
    addTearDown(firstApi.close);
    final first = await firstApi.workItemActivity(
      _expected,
      filter: WorkItemActivityFilter.comments,
      order: WorkItemActivityOrder.newestFirst,
    );
    expect(first.filter, WorkItemActivityFilter.comments);
    expect(first.order, WorkItemActivityOrder.newestFirst);
    final continuation = first.nextDiscussions!;

    final other = testApi(FakeAdapter((_) => fail('must reject before I/O')));
    await expectLater(
      other.workItemActivityNext(continuation),
      throwsA(_failure(FailureKind.validation)),
    );
    other.close();

    await expectLater(
      firstApi.workItemActivityNext(continuation),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
  });

  test(
    'nested continuation validates root, anchor, discussion, and project',
    () async {
      var call = 0;
      final api = testApi(
        FakeAdapter((request) {
          call++;
          if (call == 1) {
            return jsonResponse(
              _activityEnvelope(
                widgets: [
                  _notesWidget(
                    nodes: [
                      _discussion(
                        nodes: [_note()],
                        notesNext: true,
                        notesCursor: 'notes-a',
                      ),
                    ],
                  ),
                ],
              ),
            );
          }
          final body = request.data as Map;
          final query = body['query'] as String;
          expect(query, contains('query MobileWorkItemDiscussionNotes'));
          expect(query, contains(r'anchor: note(id: $anchorNoteId)'));
          expect(query, isNot(contains('noteable')));
          expect(body['variables'], {
            'workItemId': _workItemId,
            'anchorNoteId': _noteId,
            'after': 'notes-a',
          });
          return jsonResponse({
            'data': {
              'workItem': _identity(),
              'anchor': {
                'id': _noteId,
                'project': {'id': _projectId, 'fullPath': _path},
                'discussion': _discussion(
                  nodes: [_note(id: 'gid://gitlab/Note/402')],
                ),
              },
            },
          });
        }),
      );
      addTearDown(api.close);

      final first = await api.workItemActivity(_expected);
      final token = first.nextNotesByDiscussion[_discussionId]!;
      final next = await api.workItemDiscussionNotesNext(token);

      expect(next.workItemId, _workItemId);
      expect(next.discussionId, _discussionId);
      expect(next.notes.items.single.id, 'gid://gitlab/Note/402');
      expect(next.next, isNull);
    },
  );

  test(
    'per-note reply targets preserve exact anchors across continuation pages',
    () async {
      const firstNoteId = 'gid://gitlab/Note/400';
      const continuedNoteId = 'gid://gitlab/Note/402';
      var call = 0;
      final adapter = FakeAdapter((request) {
        call++;
        final body = request.data as Map;
        final query = body['query'] as String;
        if (call == 1) {
          return jsonResponse(
            _activityEnvelope(
              widgets: [
                _notesWidget(
                  nodes: [
                    _discussion(
                      nodes: [
                        _note(id: firstNoteId),
                        _note(),
                      ],
                      notesNext: true,
                      notesCursor: 'notes-a',
                    ),
                  ],
                ),
              ],
            ),
          );
        }
        if (call == 2) {
          expect(query, contains('query MobileWorkItemDiscussionNotes'));
          expect(body['variables'], {
            'workItemId': _workItemId,
            'anchorNoteId': _noteId,
            'after': 'notes-a',
          });
          return jsonResponse({
            'data': {
              'workItem': _identity(),
              'anchor': {
                'id': _noteId,
                'project': {'id': _projectId, 'fullPath': _path},
                'discussion': _discussion(nodes: [_note(id: continuedNoteId)]),
              },
            },
          });
        }
        if (call == 3) {
          expect(
            query,
            startsWith('query MobileWorkItemActivityReplyPreflight'),
          );
          expect(body['variables'], {
            'workItemId': _workItemId,
            'anchorNoteId': continuedNoteId,
          });
          return jsonResponse(
            _writeAccess(anchor: _writeNote(id: continuedNoteId)),
          );
        }
        if (call == 4) {
          expect(_isMutation(request), isTrue);
          return jsonResponse(
            _writeAck(note: _writeNote(body: 'Continuation reply')),
          );
        }
        return jsonResponse(
          _writeReadback(note: _writeNote(body: 'Continuation reply')),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final first = await api.workItemActivity(_expected);
      expect(
        first.replyTargetsByNote.keys,
        unorderedEquals([firstNoteId, _noteId]),
      );
      expect(first.replyTargetsByNote[firstNoteId]!.anchorNoteId, firstNoteId);
      expect(first.replyTargetsByNote[_noteId]!.anchorNoteId, _noteId);
      expect(
        first.replyTargetsByDiscussion[_discussionId]!.anchorNoteId,
        _noteId,
      );

      final continued = await api.workItemDiscussionNotesNext(
        first.nextNotesByDiscussion[_discussionId]!,
      );
      expect(
        continued.replyTargetsByNote.keys,
        unorderedEquals([continuedNoteId]),
      );
      final continuedTarget = continued.replyTargetsByNote[continuedNoteId]!;
      expect(continuedTarget.anchorNoteId, continuedNoteId);

      final created = await api.createWorkItemActivityReply(
        continuedTarget,
        'Continuation reply',
      );
      expect(created.note.body, 'Continuation reply');
      expect(adapter.requests.where(_isMutation), hasLength(1));
      expect(call, 5);
    },
  );

  test(
    'nested continuation rejects wrong anchor scope and cursor history',
    () async {
      Future<WorkItemDiscussionNotesContinuation> tokenFor(
        GitLabApi api,
      ) async => (await api.workItemActivity(
        _expected,
      )).nextNotesByDiscussion[_discussionId]!;

      final wrongProject = testApi(
        FakeAdapter((request) {
          final query = ((request.data as Map)['query'] as String);
          if (query.contains('MobileWorkItemActivity')) {
            return jsonResponse(
              _activityEnvelope(
                widgets: [
                  _notesWidget(
                    nodes: [
                      _discussion(
                        nodes: [_note()],
                        notesNext: true,
                        notesCursor: 'notes-a',
                      ),
                    ],
                  ),
                ],
              ),
            );
          }
          return jsonResponse({
            'data': {
              'workItem': _identity(),
              'anchor': {
                'id': _noteId,
                'project': {
                  'id': 'gid://gitlab/Project/99',
                  'fullPath': 'team/wrong',
                },
                'discussion': _discussion(),
              },
            },
          });
        }),
      );
      final wrongProjectToken = await tokenFor(wrongProject);
      await expectLater(
        wrongProject.workItemDiscussionNotesNext(wrongProjectToken),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      wrongProject.close();

      final repeated = testApi(
        FakeAdapter((request) {
          final query = ((request.data as Map)['query'] as String);
          if (query.contains('MobileWorkItemActivity')) {
            return jsonResponse(
              _activityEnvelope(
                widgets: [
                  _notesWidget(
                    nodes: [
                      _discussion(
                        nodes: [_note()],
                        notesNext: true,
                        notesCursor: 'notes-a',
                      ),
                    ],
                  ),
                ],
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
                  nodes: [_note()],
                  notesNext: true,
                  notesCursor: 'notes-a',
                ),
              },
            },
          });
        }),
      );
      final repeatedToken = await tokenFor(repeated);
      await expectLater(
        repeated.workItemDiscussionNotesNext(repeatedToken),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      repeated.close();
    },
  );

  test(
    'nested continuation rejects wrong root, anchor, and discussion',
    () async {
      Future<void> expectInvalid(Map<String, Object?> nestedData) async {
        final api = testApi(
          FakeAdapter((request) {
            final query = (request.data as Map)['query'] as String;
            if (query.contains('MobileWorkItemActivity')) {
              return jsonResponse(
                _activityEnvelope(
                  widgets: [
                    _notesWidget(
                      nodes: [
                        _discussion(
                          nodes: [_note()],
                          notesNext: true,
                          notesCursor: 'notes-a',
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }
            return jsonResponse({'data': nestedData});
          }),
        );
        final token = (await api.workItemActivity(
          _expected,
        )).nextNotesByDiscussion[_discussionId]!;
        await expectLater(
          api.workItemDiscussionNotesNext(token),
          throwsA(_failure(FailureKind.invalidResponse)),
        );
        api.close();
      }

      final validAnchor = <String, Object?>{
        'id': _noteId,
        'project': {'id': _projectId, 'fullPath': _path},
        'discussion': _discussion(),
      };
      await expectInvalid({
        'workItem': _identity(id: 'gid://gitlab/WorkItem/wrong'),
        'anchor': validAnchor,
      });
      await expectInvalid({
        'workItem': _identity(),
        'anchor': {...validAnchor, 'id': 'gid://gitlab/Note/wrong'},
      });
      await expectInvalid({
        'workItem': _identity(),
        'anchor': {
          ...validAnchor,
          'discussion': _discussion(
            id: 'gid://gitlab/Discussion/wrong',
            replyId: 'wrong-reply',
          ),
        },
      });
    },
  );

  test('group activity permits only a null anchored project', () async {
    final groupExpected = WorkItemGraphSummary(
      id: 'gid://gitlab/WorkItem/group-owned',
      iid: 8,
      title: 'Synthetic group work item',
      state: 'OPEN',
      createdAt: DateTime.utc(2026, 10, 1),
      updatedAt: DateTime.utc(2026, 10, 2),
      project: null,
      namespace: const GraphResourceRef(
        id: 'gid://gitlab/Group/7',
        fullPath: 'team',
      ),
      type: const WorkItemGraphType(
        id: 'gid://gitlab/WorkItems::Type/group-owned',
        name: 'Epic',
      ),
    );
    var call = 0;
    final api = testApi(
      FakeAdapter((request) {
        call++;
        if (call == 1) {
          expect((request.data as Map)['variables'], {
            'id': groupExpected.id,
            'after': null,
            'filter': 'ONLY_ACTIVITY',
            'sort': 'CREATED_DESC',
          });
          return jsonResponse(
            _activityEnvelope(
              id: groupExpected.id,
              iid: '8',
              project: null,
              namespace: {
                'id': groupExpected.namespace!.id,
                'fullPath': groupExpected.namespace!.fullPath,
              },
              widgets: [
                _notesWidget(
                  nodes: [
                    _discussion(
                      nodes: [_note()],
                      notesNext: true,
                      notesCursor: 'group-notes-a',
                    ),
                  ],
                ),
              ],
            ),
          );
        }
        return jsonResponse({
          'data': {
            'workItem': _identity(
              id: groupExpected.id,
              iid: '8',
              project: null,
              namespace: {
                'id': groupExpected.namespace!.id,
                'fullPath': groupExpected.namespace!.fullPath,
              },
            ),
            'anchor': {
              'id': _noteId,
              'project': null,
              'discussion': _discussion(),
            },
          },
        });
      }),
    );
    addTearDown(api.close);

    final first = await api.workItemActivity(
      groupExpected,
      filter: WorkItemActivityFilter.history,
      order: WorkItemActivityOrder.newestFirst,
    );
    expect(first.filter, WorkItemActivityFilter.history);
    expect(first.order, WorkItemActivityOrder.newestFirst);
    final next = await api.workItemDiscussionNotesNext(
      first.nextNotesByDiscussion[_discussionId]!,
    );
    expect(next.discussionId, _discussionId);
  });

  test('nested cursor history rejects a non-adjacent loop', () async {
    var call = 0;
    final api = testApi(
      FakeAdapter((request) {
        call++;
        if (call == 1) {
          return jsonResponse(
            _activityEnvelope(
              widgets: [
                _notesWidget(
                  nodes: [
                    _discussion(
                      nodes: [_note()],
                      notesNext: true,
                      notesCursor: 'notes-a',
                    ),
                  ],
                ),
              ],
            ),
          );
        }
        final variables = (request.data as Map)['variables'] as Map;
        final anchorId = variables['anchorNoteId'] as String;
        final nextNoteId = call == 2
            ? 'gid://gitlab/Note/402'
            : 'gid://gitlab/Note/403';
        return jsonResponse({
          'data': {
            'workItem': _identity(),
            'anchor': {
              'id': anchorId,
              'project': {'id': _projectId, 'fullPath': _path},
              'discussion': _discussion(
                nodes: [_note(id: nextNoteId)],
                notesNext: true,
                notesCursor: call == 2 ? 'notes-b' : 'notes-a',
              ),
            },
          },
        });
      }),
    );
    addTearDown(api.close);

    final first = await api.workItemActivity(_expected);
    final second = await api.workItemDiscussionNotesNext(
      first.nextNotesByDiscussion[_discussionId]!,
    );
    await expectLater(
      api.workItemDiscussionNotesNext(second.next!),
      throwsA(_failure(FailureKind.invalidResponse)),
    );
  });

  test(
    'initial control schema rejection falls back once and caches per API',
    () async {
      var call = 0;
      final adapter = FakeAdapter((request) {
        call++;
        final body = request.data as Map;
        final query = body['query'] as String;
        final variables = body['variables'] as Map;
        if (call == 1) {
          expect(query, contains('NotesFilterType'));
          expect(variables['filter'], 'ONLY_COMMENTS');
          expect(variables['sort'], 'CREATED_DESC');
          return jsonResponse(
            _schemaError(
              'argumentNotAccepted',
              "Field 'discussions' doesn't accept argument 'filter'",
              details: const {
                'name': 'discussions',
                'typeName': 'Field',
                'argumentName': 'filter',
              },
            ),
          );
        }
        expect(query, isNot(contains('NotesFilterType')));
        expect(variables.keys, unorderedEquals(['id', 'after']));
        if (call == 2) {
          expect(variables['after'], isNull);
          return jsonResponse(
            _activityEnvelope(
              widgets: [_notesWidget(next: true, cursor: 'legacy-next')],
            ),
          );
        }
        if (call == 3) {
          expect(variables['after'], 'legacy-next');
        } else {
          expect(variables['after'], isNull);
        }
        return jsonResponse(_activityEnvelope());
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final first = await api.workItemActivity(
        _expected,
        filter: WorkItemActivityFilter.comments,
        order: WorkItemActivityOrder.newestFirst,
      );
      expect(first.controlsSupported, isFalse);
      expect(first.filter, WorkItemActivityFilter.all);
      expect(first.order, WorkItemActivityOrder.oldestFirst);

      final next = await api.workItemActivityNext(first.nextDiscussions!);
      expect(next.controlsSupported, isFalse);
      expect(next.filter, WorkItemActivityFilter.all);
      expect(next.order, WorkItemActivityOrder.oldestFirst);

      final cached = await api.workItemActivity(
        _expected,
        filter: WorkItemActivityFilter.history,
        order: WorkItemActivityOrder.newestFirst,
      );
      expect(cached.controlsSupported, isFalse);
      expect(call, 4);

      var otherCalls = 0;
      final other = testApi(
        FakeAdapter((request) {
          otherCalls++;
          expect((request.data as Map)['query'], contains('NotesFilterType'));
          return jsonResponse(_activityEnvelope());
        }),
      );
      await other.workItemActivity(_expected);
      expect(otherCalls, 1);
      other.close();
    },
  );

  test(
    'exact missing control variable types permit initial fallback',
    () async {
      var call = 0;
      final api = testApi(
        FakeAdapter((_) {
          call++;
          if (call == 1) {
            return jsonResponse({
              'errors': [
                {
                  'message': 'synthetic missing filter type',
                  'extensions': {
                    'code': 'variableRequiresValidType',
                    'typeName': 'NotesFilterType',
                    'variableName': 'filter',
                  },
                },
                {
                  'message': 'synthetic missing sort type',
                  'extensions': {
                    'code': 'variableRequiresValidType',
                    'typeName': 'WorkItemDiscussionsSort',
                    'variableName': 'sort',
                  },
                },
              ],
            });
          }
          return jsonResponse(_activityEnvelope());
        }),
      );
      addTearDown(api.close);

      final page = await api.workItemActivity(
        _expected,
        filter: WorkItemActivityFilter.history,
        order: WorkItemActivityOrder.newestFirst,
      );
      expect(call, 2);
      expect(page.controlsSupported, isFalse);
      expect(page.filter, WorkItemActivityFilter.all);
      expect(page.order, WorkItemActivityOrder.oldestFirst);
    },
  );

  test('advanced continuation never falls back to a legacy cursor', () async {
    var call = 0;
    final api = testApi(
      FakeAdapter((request) {
        call++;
        final variables = (request.data as Map)['variables'] as Map;
        expect(variables['filter'], 'ONLY_COMMENTS');
        expect(variables['sort'], 'CREATED_DESC');
        if (call == 1) {
          return jsonResponse(
            _activityEnvelope(
              widgets: [_notesWidget(next: true, cursor: 'advanced-next')],
            ),
          );
        }
        expect(variables['after'], 'advanced-next');
        return jsonResponse(
          _schemaError(
            'argumentNotAccepted',
            "Field 'discussions' doesn't accept argument 'sort'",
            details: const {
              'name': 'discussions',
              'typeName': 'Field',
              'argumentName': 'sort',
            },
          ),
        );
      }),
    );
    addTearDown(api.close);

    final first = await api.workItemActivity(
      _expected,
      filter: WorkItemActivityFilter.comments,
      order: WorkItemActivityOrder.newestFirst,
    );
    await expectLater(
      api.workItemActivityNext(first.nextDiscussions!),
      throwsA(_failure(FailureKind.unsupported)),
    );
    expect(call, 2);
  });

  test(
    'fallback excludes unrelated schema, authentication, network, and stale errors',
    () async {
      Future<void> expectSingleFailure(
        ResponseBody response,
        FailureKind kind,
      ) async {
        var calls = 0;
        final api = testApi(
          FakeAdapter((_) {
            calls++;
            return response;
          }),
        );
        await expectLater(
          api.workItemActivity(_expected),
          throwsA(_failure(kind)),
        );
        expect(calls, 1);
        api.close();
      }

      for (final details in const [
        {
          'code': 'argumentNotAccepted',
          'name': 'otherField',
          'typeName': 'Field',
          'argumentName': 'filter',
        },
        {
          'code': 'argumentNotAccepted',
          'name': 'discussions',
          'typeName': 'Field',
          'argumentName': 'unrelated',
        },
        {
          'code': 'otherCode',
          'name': 'discussions',
          'typeName': 'Field',
          'argumentName': 'filter',
        },
      ]) {
        await expectSingleFailure(
          jsonResponse({
            'errors': [
              {'message': 'synthetic schema failure', 'extensions': details},
            ],
          }),
          FailureKind.invalidResponse,
        );
      }
      await expectSingleFailure(
        jsonResponse({}, status: 401),
        FailureKind.unauthenticated,
      );
      await expectSingleFailure(
        jsonResponse({}, status: 503),
        FailureKind.server,
      );

      var current = true;
      var calls = 0;
      final pending = Completer<ResponseBody>();
      final stale = testApi(
        FakeAdapter((_) {
          calls++;
          return pending.future;
        }),
      );
      final operation = stale.workItemActivity(
        _expected,
        isCurrent: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      pending.complete(
        jsonResponse(
          _schemaError(
            'argumentNotAccepted',
            "Field 'discussions' doesn't accept argument 'filter'",
            details: const {
              'name': 'discussions',
              'typeName': 'Field',
              'argumentName': 'filter',
            },
          ),
        ),
      );
      await expectLater(operation, throwsA(_failure(FailureKind.cancelled)));
      expect(calls, 1);
      stale.close();
    },
  );

  test(
    'shared reader enforces GraphQL errors, redirects, and OAuth rotation',
    () async {
      final malformed = testApi(
        FakeAdapter(
          (_) => jsonResponse({
            'errors': [
              {'message': 'synthetic failure'},
            ],
          }),
        ),
      );
      await expectLater(
        malformed.workItemActivity(_expected),
        throwsA(_failure(FailureKind.invalidResponse)),
      );
      malformed.close();

      final redirected = testApi(
        FakeAdapter(
          (_) => ResponseBody.fromString(
            '',
            302,
            headers: {
              'location': ['https://third-party.example/graphql'],
            },
          ),
        ),
      );
      await expectLater(
        redirected.workItemActivity(_expected),
        throwsA(_failure(FailureKind.redirectBlocked)),
      );
      redirected.close();

      var graphCalls = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/oauth/token')) {
          return jsonResponse({
            'access_token': 'rotated-access',
            'refresh_token': 'rotated-refresh',
            'token_type': 'bearer',
            'expires_in': 7200,
          });
        }
        graphCalls++;
        if (graphCalls == 1) return jsonResponse({}, status: 401);
        expect(request.headers['Authorization'], 'Bearer rotated-access');
        expect(request.headers['PRIVATE-TOKEN'], isNull);
        return jsonResponse(_activityEnvelope());
      });
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      final dio = Dio()..httpClientAdapter = adapter;
      final oauth = GitLabApi(
        instance: instance,
        dio: dio,
        credential: const OAuthCredential(
          accessToken: 'old-access',
          refreshToken: 'old-refresh',
          clientId: 'app',
        ),
        oauth: OAuthTokenClient(instance: instance, clientId: 'app', dio: dio),
      );
      addTearDown(oauth.close);
      await oauth.workItemActivity(_expected);
      expect(graphCalls, 2);
    },
  );

  test(
    'isCurrent and close reject stale activity before and after I/O',
    () async {
      final before = FakeAdapter((_) => fail('must reject before request'));
      final stale = testApi(before);
      await expectLater(
        stale.workItemActivity(_expected, isCurrent: () => false),
        throwsA(_failure(FailureKind.cancelled)),
      );
      expect(before.requests, isEmpty);
      stale.close();

      var current = true;
      final pending = Completer<ResponseBody>();
      final late = testApi(FakeAdapter((_) => pending.future));
      final operation = late.workItemActivity(
        _expected,
        isCurrent: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      pending.complete(jsonResponse(_activityEnvelope()));
      await expectLater(operation, throwsA(_failure(FailureKind.cancelled)));
      late.close();

      final closed = testApi(
        FakeAdapter(
          (_) => jsonResponse(
            _activityEnvelope(
              widgets: [_notesWidget(next: true, cursor: 'cursor-a')],
            ),
          ),
        ),
      );
      final page = await closed.workItemActivity(_expected);
      closed.close();
      await expectLater(
        closed.workItemActivityNext(page.nextDiscussions!),
        throwsA(_failure(FailureKind.cancelled)),
      );
    },
  );

  test(
    'write access is exact, permission-bearing, and independently optional',
    () async {
      var allowed = true;
      var locked = false;
      final adapter = FakeAdapter((request) {
        final data = request.data as Map;
        expect(
          data['query'],
          startsWith('query MobileWorkItemActivityWriteAccess'),
        );
        expect(data['variables'], {'id': _workItemId});
        return jsonResponse(
          _writeAccess(canCreateNote: allowed, discussionLocked: locked),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final access = await api.workItemActivityWriteAccess(_expected);
      expect(access.canCreateNote, isTrue);
      expect(access.discussionLocked, isFalse);
      expect(access.actorId, _authorId);
      expect(access.controlsSupported, isNull);
      expect(access.commentTarget, isNotNull);

      allowed = false;
      final denied = await api.workItemActivityWriteAccess(_expected);
      expect(denied.canCreateNote, isFalse);
      expect(denied.discussionLocked, isFalse);
      expect(denied.actorId, _authorId);
      expect(denied.controlsSupported, isNull);
      expect(denied.commentTarget, isNull);

      allowed = true;
      locked = true;
      final lockedAccess = await api.workItemActivityWriteAccess(_expected);
      expect(lockedAccess.canCreateNote, isTrue);
      expect(lockedAccess.discussionLocked, isTrue);
      expect(lockedAccess.actorId, _authorId);
      expect(lockedAccess.controlsSupported, isNull);
      expect(lockedAccess.commentTarget, isNull);

      final anonymous = testApi(
        FakeAdapter(
          (_) =>
              jsonResponse(_writeAccess(canCreateNote: false, authorId: null)),
        ),
      );
      final anonymousAccess = await anonymous.workItemActivityWriteAccess(
        _expected,
      );
      expect(anonymousAccess.canCreateNote, isFalse);
      expect(anonymousAccess.discussionLocked, isFalse);
      expect(anonymousAccess.actorId, isNull);
      expect(anonymousAccess.controlsSupported, isNull);
      expect(anonymousAccess.commentTarget, isNull);
      anonymous.close();

      final anonymousServerAllowed = testApi(
        FakeAdapter(
          (_) => jsonResponse(
            _writeAccess(
              canCreateNote: true,
              authorId: null,
              discussionLocked: null,
            ),
          ),
        ),
      );
      final signedOutAccess = await anonymousServerAllowed
          .workItemActivityWriteAccess(_expected);
      expect(signedOutAccess.canCreateNote, isFalse);
      expect(signedOutAccess.discussionLocked, isFalse);
      expect(signedOutAccess.actorId, isNull);
      expect(signedOutAccess.controlsSupported, isNull);
      expect(signedOutAccess.commentTarget, isNull);
      anonymousServerAllowed.close();
    },
  );

  test(
    'required controls probe is in access read and unsupported state is cached',
    () async {
      var calls = 0;
      final adapter = FakeAdapter((request) {
        calls++;
        final body = request.data as Map;
        final query = body['query'] as String;
        if (calls == 1) {
          expect(query, contains(r'$filter: NotesFilterType!'));
          expect(query, contains(r'$sort: WorkItemDiscussionsSort!'));
          expect(
            query,
            contains(r'discussions(first: 1, filter: $filter, sort: $sort)'),
          );
          expect(body['variables'], {
            'id': _workItemId,
            'filter': 'ALL_NOTES',
            'sort': 'CREATED_ASC',
          });
          return jsonResponse(_writeAccess());
        }
        if (calls == 2) {
          expect(query, contains(r'discussions(first: 1'));
          return jsonResponse(
            _schemaError(
              'argumentNotAccepted',
              "Field 'discussions' doesn't accept argument 'filter'",
              details: const {
                'name': 'discussions',
                'typeName': 'Field',
                'argumentName': 'filter',
              },
            ),
          );
        }
        expect(query, isNot(contains('NotesFilterType')));
        expect(body['variables'], {'id': _workItemId});
        return jsonResponse(_writeAccess());
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final supported = await api.workItemActivityWriteAccess(
        _expected,
        requireControlsSupported: true,
      );
      expect(supported.controlsSupported, isTrue);
      expect(supported.commentTarget, isNotNull);

      final detected = await api.workItemActivityWriteAccess(
        _expected,
        requireControlsSupported: true,
      );
      expect(detected.controlsSupported, isFalse);
      expect(detected.canCreateNote, isFalse);
      expect(detected.commentTarget, isNull);

      final cached = await api.workItemActivityWriteAccess(
        _expected,
        requireControlsSupported: true,
      );
      expect(cached.controlsSupported, isFalse);
      expect(cached.commentTarget, isNull);
      expect(calls, 2);

      final defaultAccess = await api.workItemActivityWriteAccess(_expected);
      expect(defaultAccess.controlsSupported, isFalse);
      expect(defaultAccess.canCreateNote, isTrue);
      expect(defaultAccess.commentTarget, isNotNull);
      expect(calls, 3);
    },
  );

  test(
    'top-level project comment uses one createNote and exact readback',
    () async {
      var call = 0;
      final adapter = FakeAdapter((request) {
        call++;
        final data = request.data as Map;
        final query = data['query'] as String;
        if (call <= 2) return jsonResponse(_writeAccess());
        if (call == 3) {
          expect(
            query,
            startsWith('mutation MobileCreateWorkItemActivityNote'),
          );
          expect(data['variables'], {
            'input': {
              'noteableId': _workItemId,
              'body': 'Hello **mobile**',
              'internal': false,
            },
          });
          return jsonResponse(
            _writeAck(note: _writeNote(body: 'Hello **mobile**')),
          );
        }
        expect(query, startsWith('query MobileWorkItemActivityNoteReadback'));
        expect(data['variables'], {
          'workItemId': _workItemId,
          'noteId': 'gid://gitlab/DiscussionNote/501',
        });
        return jsonResponse(
          _writeReadback(note: _writeNote(body: 'Hello **mobile**')),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final access = await api.workItemActivityWriteAccess(_expected);
      final created = await api.createWorkItemActivityComment(
        access.commentTarget!,
        '  Hello **mobile**  ',
        expectedActorId: _authorId,
      );

      expect(created.note.body, 'Hello **mobile**');
      expect(created.discussionId, _discussionId);
      expect(created.replyId, _replyId);
      expect(adapter.requests.where(_isMutation), hasLength(1));
    },
  );

  test(
    'group discussion reply uses server replyId and validates anchor',
    () async {
      var call = 0;
      final adapter = FakeAdapter((request) {
        call++;
        final data = request.data as Map;
        final query = data['query'] as String;
        if (call == 1) {
          return jsonResponse(
            _activityEnvelope(
              id: _groupExpected.id,
              iid: '${_groupExpected.iid}',
              project: null,
              namespace: {
                'id': _groupExpected.namespace!.id,
                'fullPath': _groupExpected.namespace!.fullPath,
              },
              widgets: [
                _notesWidget(
                  nodes: [
                    _discussion(nodes: [_note()]),
                  ],
                ),
              ],
            ),
          );
        }
        if (call == 2) {
          expect(
            query,
            startsWith('query MobileWorkItemActivityReplyPreflight'),
          );
          expect(data['variables'], {
            'workItemId': _groupExpected.id,
            'anchorNoteId': _noteId,
          });
          return jsonResponse(
            _writeAccess(
              expected: _groupExpected,
              anchor: _writeNote(id: _noteId, noteableId: 41, project: null),
            ),
          );
        }
        if (call == 3) {
          expect(data['variables'], {
            'input': {
              'noteableId': _groupExpected.id,
              'body': 'Group reply',
              'internal': false,
              'discussionId': _replyId,
            },
          });
          return jsonResponse(
            _writeAck(
              note: _writeNote(
                body: 'Group reply',
                noteableId: 41,
                project: null,
              ),
            ),
          );
        }
        return jsonResponse({
          'data': {
            'workItem': _identity(
              id: _groupExpected.id,
              iid: '${_groupExpected.iid}',
              project: null,
              namespace: {
                'id': _groupExpected.namespace!.id,
                'fullPath': _groupExpected.namespace!.fullPath,
              },
            ),
            'note': _writeNote(
              body: 'Group reply',
              noteableId: 41,
              project: null,
            ),
          },
        });
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final page = await api.workItemActivity(_groupExpected);
      final target = page.replyTargetsByDiscussion[_discussionId];
      expect(target, isNotNull);
      final created = await api.createWorkItemActivityReply(
        target!,
        'Group reply',
        expectedActorId: _authorId,
      );
      expect(created.replyId, _replyId);
      expect(adapter.requests.where(_isMutation), hasLength(1));
    },
  );

  test('locked discussions suppress comment access targets', () async {
    var call = 0;
    final adapter = FakeAdapter((request) {
      call++;
      if (call == 1) {
        return jsonResponse(
          _activityEnvelope(
            widgets: [
              _notesWidget(
                discussionLocked: true,
                nodes: [
                  _discussion(nodes: [_note()]),
                ],
              ),
            ],
          ),
        );
      }
      return jsonResponse(_writeAccess(discussionLocked: true));
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    final page = await api.workItemActivity(_expected);
    expect(page.replyTargetsByDiscussion, contains(_discussionId));

    final access = await api.workItemActivityWriteAccess(_expected);
    expect(access.canCreateNote, isTrue);
    expect(access.discussionLocked, isTrue);
    expect(access.commentTarget, isNull);
    expect(adapter.requests.where(_isMutation), isEmpty);
  });

  test(
    'write-access schema failure is explicit and does not weaken reader',
    () async {
      var call = 0;
      final adapter = FakeAdapter((_) {
        call++;
        if (call == 1) {
          return jsonResponse(
            _schemaError('undefinedField', 'private schema detail'),
          );
        }
        return jsonResponse(_activityEnvelope());
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await expectLater(
        api.workItemActivityWriteAccess(_expected),
        throwsA(_failure(FailureKind.unsupported)),
      );
      final page = await api.workItemActivity(_expected);
      expect(page.snapshot.availability, WorkItemActivityAvailability.absent);
      expect(adapter.requests, hasLength(2));
    },
  );

  test('write access rejects nonnumeric WorkItem IDs before I/O', () async {
    final invalid = WorkItemGraphSummary(
      id: 'gid://gitlab/WorkItem/opaque',
      iid: _expected.iid,
      title: _expected.title,
      state: _expected.state,
      createdAt: _expected.createdAt,
      updatedAt: _expected.updatedAt,
      project: _expected.project,
      namespace: _expected.namespace,
      type: _expected.type,
    );
    final adapter = FakeAdapter((_) => fail('must reject before I/O'));
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      api.workItemActivityWriteAccess(invalid),
      throwsA(_failure(FailureKind.validation)),
    );
    expect(adapter.requests, isEmpty);
  });

  test(
    'wrong-class and nonnumeric note IDs never mint reply targets',
    () async {
      for (final id in [
        'gid://gitlab/Project/401',
        'gid://gitlab/Note/not-numeric',
      ]) {
        final api = testApi(
          FakeAdapter(
            (_) => jsonResponse(
              _activityEnvelope(
                widgets: [
                  _notesWidget(
                    nodes: [
                      _discussion(nodes: [_note(id: id)]),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
        final page = await api.workItemActivity(_expected);
        expect(page.replyTargetsByDiscussion, isEmpty);
        api.close();
      }
    },
  );

  test(
    'reply preflight rejects foreign anchor scope and discussion before write',
    () async {
      final invalidAnchors = <Map<String, Object?>>[
        _writeNote(id: 'gid://gitlab/Note/999'),
        _writeNote(id: 'gid://gitlab/Project/401'),
        _writeNote(id: 'gid://gitlab/Note/not-numeric'),
        _writeNote(noteableId: 99),
        _writeNote(
          project: const {
            'id': 'gid://gitlab/Project/99',
            'fullPath': 'other/project',
          },
        ),
        _writeNote(discussionId: 'gid://gitlab/Discussion/foreign'),
        _writeNote(replyId: 'gid://gitlab/IndividualNoteDiscussion/foreign'),
      ];
      for (final invalidAnchor in invalidAnchors) {
        var call = 0;
        final adapter = FakeAdapter((_) {
          call++;
          if (call == 1) {
            return jsonResponse(
              _activityEnvelope(
                widgets: [
                  _notesWidget(
                    nodes: [
                      _discussion(nodes: [_note()]),
                    ],
                  ),
                ],
              ),
            );
          }
          return jsonResponse(_writeAccess(anchor: invalidAnchor));
        });
        final api = testApi(adapter);
        final page = await api.workItemActivity(_expected);
        await expectLater(
          api.createWorkItemActivityReply(
            page.replyTargetsByDiscussion[_discussionId]!,
            'Reply',
          ),
          throwsA(isA<ApiFailure>()),
        );
        expect(adapter.requests.where(_isMutation), isEmpty);
        api.close();
      }
    },
  );

  test(
    'supplied actor mismatch rejects comments and replies before dispatch hooks',
    () async {
      for (final reply in [false, true]) {
        var beforeMutationCalled = false;
        var mayStartCalled = false;
        final adapter = FakeAdapter((request) {
          final query = (request.data as Map)['query'] as String;
          if (query.contains('MobileWorkItemActivity(')) {
            return jsonResponse(
              _activityEnvelope(
                widgets: [
                  _notesWidget(
                    nodes: [
                      _discussion(nodes: [_note()]),
                    ],
                  ),
                ],
              ),
            );
          }
          if (query.startsWith('query MobileWorkItemActivityReplyPreflight')) {
            return jsonResponse(_writeAccess(anchor: _writeNote(id: _noteId)));
          }
          expect(query, startsWith('query MobileWorkItemActivityWriteAccess'));
          return jsonResponse(_writeAccess());
        });
        final api = testApi(adapter);
        final Future<WorkItemActivityCreatedNote> operation;
        if (reply) {
          final page = await api.workItemActivity(_expected);
          operation = api.createWorkItemActivityReply(
            page.replyTargetsByNote[_noteId]!,
            'Reply',
            expectedActorId: 'gid://gitlab/User/7',
            beforeMutation: () async => beforeMutationCalled = true,
            mayStart: () {
              mayStartCalled = true;
              return true;
            },
          );
        } else {
          final access = await api.workItemActivityWriteAccess(_expected);
          expect(access.actorId, _authorId);
          operation = api.createWorkItemActivityComment(
            access.commentTarget!,
            'Comment',
            expectedActorId: 'gid://gitlab/User/7',
            beforeMutation: () async => beforeMutationCalled = true,
            mayStart: () {
              mayStartCalled = true;
              return true;
            },
          );
        }
        await expectLater(operation, throwsA(_failure(FailureKind.cancelled)));
        expect(beforeMutationCalled, isFalse);
        expect(mayStartCalled, isFalse);
        expect(adapter.requests.where(_isMutation), isEmpty);
        api.close();
      }
    },
  );

  test(
    'required-controls targets reject detected and cached unsupported preflight',
    () async {
      var call = 0;
      var beforeMutationCalled = false;
      var mayStartCalled = false;
      final adapter = FakeAdapter((request) {
        call++;
        final body = request.data as Map;
        final query = body['query'] as String;
        if (call == 1) {
          return jsonResponse(
            _activityEnvelope(
              widgets: [
                _notesWidget(
                  nodes: [
                    _discussion(nodes: [_note()]),
                  ],
                ),
              ],
            ),
          );
        }
        if (call == 2) {
          expect(query, startsWith('query MobileWorkItemActivityWriteAccess'));
          expect(query, contains(r'discussions(first: 1'));
          return jsonResponse(_writeAccess());
        }
        expect(call, 3);
        expect(query, startsWith('query MobileWorkItemActivityWriteAccess'));
        expect(query, contains(r'discussions(first: 1'));
        return jsonResponse(
          _schemaError(
            'argumentNotAccepted',
            "Field 'discussions' doesn't accept argument 'sort'",
            details: const {
              'name': 'discussions',
              'typeName': 'Field',
              'argumentName': 'sort',
            },
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final page = await api.workItemActivity(_expected);
      final access = await api.workItemActivityWriteAccess(
        _expected,
        requireControlsSupported: true,
      );

      await expectLater(
        api.createWorkItemActivityComment(
          access.commentTarget!,
          'Comment',
          beforeMutation: () async => beforeMutationCalled = true,
          mayStart: () {
            mayStartCalled = true;
            return true;
          },
        ),
        throwsA(_failure(FailureKind.unsupported)),
      );
      await expectLater(
        api.createWorkItemActivityReply(
          page.replyTargetsByNote[_noteId]!,
          'Reply',
          requireControlsSupported: true,
          beforeMutation: () async => beforeMutationCalled = true,
          mayStart: () {
            mayStartCalled = true;
            return true;
          },
        ),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(beforeMutationCalled, isFalse);
      expect(mayStartCalled, isFalse);
      expect(adapter.requests.where(_isMutation), isEmpty);
      expect(call, 3);
    },
  );

  test(
    'reply controls probe rejects fresh unsupported schema before hooks',
    () async {
      var call = 0;
      var beforeMutationCalled = false;
      var mayStartCalled = false;
      final adapter = FakeAdapter((request) {
        call++;
        final body = request.data as Map;
        final query = body['query'] as String;
        if (call == 1) {
          return jsonResponse(
            _activityEnvelope(
              widgets: [
                _notesWidget(
                  nodes: [
                    _discussion(nodes: [_note()]),
                  ],
                ),
              ],
            ),
          );
        }
        expect(call, 2);
        expect(query, startsWith('query MobileWorkItemActivityReplyPreflight'));
        expect(query, contains(r'$filter: NotesFilterType!'));
        expect(query, contains(r'$sort: WorkItemDiscussionsSort!'));
        expect(
          query,
          contains(r'discussions(first: 1, filter: $filter, sort: $sort)'),
        );
        expect(body['variables'], {
          'workItemId': _workItemId,
          'anchorNoteId': _noteId,
          'filter': 'ALL_NOTES',
          'sort': 'CREATED_ASC',
        });
        return jsonResponse(
          _schemaError(
            'argumentNotAccepted',
            "Field 'discussions' doesn't accept argument 'filter'",
            details: const {
              'name': 'discussions',
              'typeName': 'Field',
              'argumentName': 'filter',
            },
          ),
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final page = await api.workItemActivity(_expected);

      await expectLater(
        api.createWorkItemActivityReply(
          page.replyTargetsByNote[_noteId]!,
          'Reply',
          expectedActorId: _authorId,
          requireControlsSupported: true,
          beforeMutation: () async => beforeMutationCalled = true,
          mayStart: () {
            mayStartCalled = true;
            return true;
          },
        ),
        throwsA(_failure(FailureKind.unsupported)),
      );
      expect(beforeMutationCalled, isFalse);
      expect(mayStartCalled, isFalse);
      expect(adapter.requests.where(_isMutation), isEmpty);
      expect(call, 2);
    },
  );

  test(
    'late owner invalidation after reply preflight sends no write',
    () async {
      var current = true;
      final pending = Completer<ResponseBody>();
      var call = 0;
      final adapter = FakeAdapter((_) {
        call++;
        if (call == 1) {
          return jsonResponse(
            _activityEnvelope(
              widgets: [
                _notesWidget(
                  nodes: [
                    _discussion(nodes: [_note()]),
                  ],
                ),
              ],
            ),
          );
        }
        return pending.future;
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final page = await api.workItemActivity(_expected);
      final operation = api.createWorkItemActivityReply(
        page.replyTargetsByDiscussion[_discussionId]!,
        'Reply',
        isCurrent: () => current,
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      pending.complete(
        jsonResponse(_writeAccess(anchor: _writeNote(id: _noteId))),
      );
      await expectLater(operation, throwsA(_failure(FailureKind.cancelled)));
      expect(adapter.requests.where(_isMutation), isEmpty);
    },
  );

  test(
    'comment target is API-bound and consumed before concurrent dispatch',
    () async {
      final mutationResponse = Completer<ResponseBody>();
      final adapter = FakeAdapter((request) {
        final query = (request.data as Map)['query'] as String;
        if (query.startsWith('query MobileWorkItemActivityWriteAccess')) {
          return jsonResponse(_writeAccess());
        }
        if (_isMutation(request)) return mutationResponse.future;
        return jsonResponse(_writeReadback(note: _writeNote(body: 'Once')));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemActivityWriteAccess(
        _expected,
      )).commentTarget!;

      final other = testApi(
        FakeAdapter((_) => fail('wrong API must not send')),
      );
      await expectLater(
        other.createWorkItemActivityComment(target, 'Other'),
        throwsA(_failure(FailureKind.validation)),
      );
      other.close();

      final first = api.createWorkItemActivityComment(target, 'Once');
      final second = api.createWorkItemActivityComment(target, 'Once');
      await Future<void>.delayed(Duration.zero);
      mutationResponse.complete(
        jsonResponse(_writeAck(note: _writeNote(body: 'Once'))),
      );
      final outcomes = await Future.wait<Object>([
        first.then<Object>((value) => value, onError: (Object error) => error),
        second.then<Object>((value) => value, onError: (Object error) => error),
      ]);
      expect(outcomes.whereType<WorkItemActivityCreatedNote>(), hasLength(1));
      expect(
        outcomes.whereType<ApiFailure>().single.kind,
        FailureKind.writeUncertain,
      );
      expect(adapter.requests.where(_isMutation), hasLength(1));
    },
  );

  test('invalid body and stale owner send no writes', () async {
    var call = 0;
    final adapter = FakeAdapter((request) {
      call++;
      if (call <= 2) return jsonResponse(_writeAccess());
      if (_isMutation(request)) {
        return jsonResponse(
          _writeAck(note: _writeNote(body: '```\n/close\n```')),
        );
      }
      return jsonResponse(
        _writeReadback(note: _writeNote(body: '```\n/close\n```')),
      );
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final target = (await api.workItemActivityWriteAccess(
      _expected,
    )).commentTarget!;
    final before = adapter.requests.length;

    for (final body in [
      '   ',
      '/close',
      'text\n  /assign @me',
      'x' * (2 * 1024 * 1024 + 1),
    ]) {
      await expectLater(
        api.createWorkItemActivityComment(target, body),
        throwsA(_failure(FailureKind.validation)),
      );
    }
    await expectLater(
      api.createWorkItemActivityComment(
        target,
        'Fresh body',
        isCurrent: () => false,
      ),
      throwsA(_failure(FailureKind.cancelled)),
    );
    expect(adapter.requests.length, before);

    // Slash-like text inside code remains ordinary Markdown.
    await api.createWorkItemActivityComment(target, '```\n/close\n```');
    expect(adapter.requests.where(_isMutation), hasLength(1));
  });

  test(
    'fresh locked preflight rejects a previously minted comment target',
    () async {
      var call = 0;
      final adapter = FakeAdapter((_) {
        call++;
        return jsonResponse(_writeAccess(discussionLocked: call > 1));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final target = (await api.workItemActivityWriteAccess(
        _expected,
      )).commentTarget!;

      await expectLater(
        api.createWorkItemActivityComment(target, 'Fresh body'),
        throwsA(_failure(FailureKind.conflict)),
      );
      expect(adapter.requests.where(_isMutation), isEmpty);
    },
  );

  test(
    'foreign acknowledgement and readback identities are uncertain',
    () async {
      final invalidNotes = <Map<String, Object?>>[
        _writeNote(id: 'gid://gitlab/Project/501'),
        _writeNote(id: 'gid://gitlab/Note/not-numeric'),
        _writeNote(noteableId: 99),
        _writeNote(noteableType: 'MergeRequest'),
        _writeNote(authorId: 'gid://gitlab/User/10'),
        _writeNote(internal: true),
        _writeNote(
          project: const {
            'id': 'gid://gitlab/Project/99',
            'fullPath': 'other/project',
          },
        ),
      ];
      for (final invalid in invalidNotes) {
        var call = 0;
        final api = testApi(
          FakeAdapter((request) {
            call++;
            if (call <= 2) return jsonResponse(_writeAccess());
            if (_isMutation(request)) {
              return jsonResponse(_writeAck(note: invalid));
            }
            return jsonResponse(_writeReadback());
          }),
        );
        final target = (await api.workItemActivityWriteAccess(
          _expected,
        )).commentTarget!;
        await expectLater(
          api.createWorkItemActivityComment(target, 'Synthetic note'),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(api.isClosed, isFalse);
        api.close();
      }

      for (final invalid in [
        _writeNote(id: 'gid://gitlab/Project/501'),
        _writeNote(id: 'gid://gitlab/DiscussionNote/not-numeric'),
        _writeNote(noteableId: 99),
        _writeNote(internal: true),
      ]) {
        var call = 0;
        final readbackApi = testApi(
          FakeAdapter((request) {
            call++;
            if (call <= 2) return jsonResponse(_writeAccess());
            if (_isMutation(request)) return jsonResponse(_writeAck());
            return jsonResponse(_writeReadback(note: invalid));
          }),
        );
        final target = (await readbackApi.workItemActivityWriteAccess(
          _expected,
        )).commentTarget!;
        await expectLater(
          readbackApi.createWorkItemActivityComment(target, 'Synthetic note'),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        readbackApi.close();
      }
    },
  );

  test(
    'missing payload and mutation timeout are uncertain and never replay',
    () async {
      for (final timeout in [false, true]) {
        var call = 0;
        final adapter = FakeAdapter((request) {
          call++;
          if (call <= 2) return jsonResponse(_writeAccess());
          if (_isMutation(request)) {
            if (timeout) {
              throw DioException(
                requestOptions: request,
                type: DioExceptionType.receiveTimeout,
              );
            }
            return jsonResponse({
              'data': {
                'createNote': {'errors': <Object?>[], 'note': null},
              },
            });
          }
          return jsonResponse(_writeReadback());
        });
        final api = testApi(adapter);
        final target = (await api.workItemActivityWriteAccess(
          _expected,
        )).commentTarget!;
        await expectLater(
          api.createWorkItemActivityComment(target, 'Synthetic note'),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        await expectLater(
          api.createWorkItemActivityComment(target, 'Synthetic note'),
          throwsA(_failure(FailureKind.writeUncertain)),
        );
        expect(adapter.requests.where(_isMutation), hasLength(1));
        api.close();
      }
    },
  );
}
