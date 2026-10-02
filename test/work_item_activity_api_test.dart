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

const _workItemId = 'gid://gitlab/WorkItem/server-owned';
const _projectId = 'gid://gitlab/Project/42';
const _namespaceId = 'gid://gitlab/Namespaces::ProjectNamespace/42';
const _path = 'team/example-42';
const _discussionId = 'gid://gitlab/Discussion/server-owned';
const _noteId = 'gid://gitlab/Note/server-owned';

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

Matcher _failure(FailureKind kind) =>
    isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

Map<String, Object?> _pageInfo({bool next = false, String? cursor}) => {
  'hasNextPage': next,
  'endCursor': cursor,
};

Map<String, Object?> _note({
  String id = _noteId,
  Object? author = const {
    'id': 'gid://gitlab/User/9',
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
  String replyId = 'reply-server-owned',
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
}) => {
  'type': 'NOTES',
  'discussions': {
    'nodes': nodes,
    'pageInfo': _pageInfo(next: next, cursor: cursor),
  },
};

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
        expect(query, contains('discussions(first: 20'));
        expect(query, isNot(contains('avatarUrl')));
        expect(query, isNot(contains('webUrl')));
        expect(body['variables'], {'id': _workItemId, 'after': null});
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
    },
  );

  test('preserves widget and connection availability distinctions', () async {
    final responses = <Object?>[
      _activityEnvelope(widgets: null),
      _activityEnvelope(widgets: const []),
      _activityEnvelope(
        widgets: const [
          {'type': 'NOTES', 'discussions': null},
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
    final first = await firstApi.workItemActivity(_expected);
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
                  nodes: [_note(id: 'gid://gitlab/Note/next')],
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
      expect(next.notes.items.single.id, 'gid://gitlab/Note/next');
      expect(next.next, isNull);
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
      FakeAdapter((_) {
        call++;
        if (call == 1) {
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

    final first = await api.workItemActivity(groupExpected);
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
            ? 'gid://gitlab/Note/next'
            : 'gid://gitlab/Note/third';
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
}
