import 'dart:async';

import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';

import 'fake_adapter.dart';

/// Synthetic assignee server. It answers the real GraphQL operations and
/// records what the client actually sent.
class WorkItemAssigneeFixture {
  WorkItemAssigneeFixture({
    this.userCount = 2,
    this.allowsMultiple = true,
    this.canWrite = true,
    this.widgetPresent = true,
    this.groupOnly = false,
    this.candidateLimit = 3,
  }) {
    adapter = FakeAdapter(_respond);
    api = testApi(adapter);
  }

  final int userCount;
  final bool allowsMultiple;
  final bool canWrite;
  bool widgetPresent;
  final bool groupOnly;
  int candidateLimit;

  late final FakeAdapter adapter;
  late GitLabApi api;

  final account = Account(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    user: const GitLabUser(id: 7, username: 'ada', name: 'Ada'),
    token: 'synthetic-test-token',
  );

  final Project project = Project.fromJson(projectJson(42));

  String updatedAt = '2026-09-02T03:04:05Z';
  bool conflictOnNextRead = false;
  bool failReadsAfterMutation = false;
  bool mutationSent = false;
  int mutations = 0;
  List<String> lastAssigneeIds = const [];
  Completer<void>? holdMutationApply;
  Completer<ResponseBody>? holdMutation;
  Completer<ResponseBody>? holdParentAssigneeRead;
  final heldSearches = <String, Completer<ResponseBody>>{};
  int assigneeReads = 0;
  int _assigneeReadsSinceMutation = 0;
  bool _ackReadPending = false;
  int projectSearches = 0;
  int groupSearches = 0;

  static const workItemId = 'gid://gitlab/WorkItem/501';
  static const typeId = 'gid://gitlab/WorkItems::Type/9';
  static const namespaceId = 'gid://gitlab/Group/77';
  static const groupNamespaceId = 'gid://gitlab/Group/88';

  String userId(int number) => 'gid://gitlab/User/$number';

  String userName(int number) => '人員$number';

  Map<String, Object?> mutationAck() => _mutationEnvelope();

  void releaseParentAssigneeRead() {
    final held = holdParentAssigneeRead;
    holdParentAssigneeRead = null;
    held?.complete(jsonResponse(_assigneePage(null, ids: lastAssigneeIds)));
  }

  int queries(String name) => adapter.requests
      .where((request) => '${(request.data as Map)['query']}'.contains(name))
      .length;

  Future<ResponseBody> _respond(RequestOptions request) async {
    final data = request.data;
    if (data is! Map) {
      return jsonResponse(<String, Object?>{'data': <String, Object?>{}});
    }
    final query = '${data['query']}';
    final variables = data['variables'];
    final vars = variables is Map ? variables : const <Object?, Object?>{};
    if (query.contains('MobileProjectWorkItem') ||
        query.contains('MobileNamespaceWorkItem')) {
      return jsonResponse(_detailEnvelope());
    }
    if (query.contains('MobileWorkItemAssignees')) {
      assigneeReads++;
      if (mutationSent) {
        _assigneeReadsSinceMutation++;
        if (failReadsAfterMutation) {
          return jsonResponse({
            'errors': [
              const {'message': 'read failed'},
            ],
          }, status: 500);
        }
        final parentRead = holdParentAssigneeRead;
        if (parentRead != null && _assigneeReadsSinceMutation > 1) {
          return parentRead.future;
        }
        final heldMutation = holdMutation;
        if (_ackReadPending &&
            (heldMutation == null || heldMutation.isCompleted)) {
          _ackReadPending = false;
          return jsonResponse(_assigneePage(null, ids: lastAssigneeIds));
        }
        return jsonResponse(_assigneePage(null, ids: lastAssigneeIds));
      }
      if (conflictOnNextRead) {
        conflictOnNextRead = false;
        updatedAt = '2026-10-04T01:02:03Z';
      }
      final after = vars['after'];
      return jsonResponse(_assigneePage(after is String ? after : null));
    }
    if (query.contains('MobileProjectAssigneeCandidates')) {
      projectSearches++;
      return _candidates(vars['search']?.toString() ?? '');
    }
    if (query.contains('MobileGroupAssigneeCandidates')) {
      groupSearches++;
      return _candidates(vars['search']?.toString() ?? '');
    }
    if (query.contains('MobileSetWorkItemAssignees')) {
      mutations++;
      mutationSent = true;
      var desired = const <String>[];
      final input = vars['input'];
      if (input is Map) {
        final widget = input['assigneesWidget'];
        if (widget is Map && widget['assigneeIds'] is List) {
          desired = [for (final id in widget['assigneeIds'] as List) '$id'];
        }
      }
      final apply = holdMutationApply;
      holdMutationApply = null;
      if (apply != null) await apply.future;
      lastAssigneeIds = desired;
      _ackReadPending = true;
      final held = holdMutation;
      if (held != null) return held.future;
      return jsonResponse(_mutationEnvelope());
    }
    return jsonResponse(<String, Object?>{'data': <String, Object?>{}});
  }

  Future<ResponseBody> _candidates(String search) async {
    final held = heldSearches.remove(search);
    if (held != null) {
      heldSearches['pending:$search'] = held;
      return held.future;
    }
    if (search == '失敗') {
      return jsonResponse({
        'errors': [
          const {'message': 'search failed'},
        ],
      }, status: 500);
    }
    final matched = <Map<String, Object?>>[];
    for (var number = 1; number <= candidateLimit; number++) {
      final name = '候選$number';
      if (search.isNotEmpty && !name.contains(search) && search != '人') {
        continue;
      }
      matched.add(
        _userNode(1000 + number, name: name, username: 'cand$number'),
      );
      if (matched.length == 20) break;
    }
    final container = groupOnly
        ? {
            'id': groupNamespaceId,
            'fullPath': 'group/sample',
            'autocompleteUsers': matched,
          }
        : {
            'id': 'gid://gitlab/Project/42',
            'fullPath': project.path,
            'autocompleteUsers': matched,
          };
    return jsonResponse({
      'data': {
        'currentUser': {'id': userId(7)},
        if (groupOnly) 'group': container else 'project': container,
      },
    });
  }

  Map<String, Object?> _detailEnvelope() {
    final node = _summaryNode(preview: true);
    if (groupOnly) {
      return {
        'data': {
          'namespace': {
            'id': groupNamespaceId,
            'fullPath': 'group/sample',
            'workItem': node,
          },
        },
      };
    }
    return {
      'data': {
        'project': {
          'id': 'gid://gitlab/Project/42',
          'fullPath': project.path,
          'workItems': {
            'nodes': [node],
            'pageInfo': {'hasNextPage': false, 'endCursor': null},
          },
        },
      },
    };
  }

  Map<String, Object?> _assigneePage(String? after, {List<String>? ids}) {
    if (ids != null) {
      return {
        'data': {
          'currentUser': {'id': userId(7)},
          'workItem': _summaryNode(
            preview: false,
            users: [
              for (final id in ids) _userNode(int.parse(id.split('/').last)),
            ],
            hasNext: false,
            cursor: null,
          ),
        },
      };
    }
    final start = after == null ? 0 : int.parse(after);
    final end = start + 100 > userCount ? userCount : start + 100;
    final hasNext = end < userCount;
    return {
      'data': {
        'currentUser': {'id': userId(7)},
        'workItem': _summaryNode(
          preview: false,
          users: [
            for (var number = start + 1; number <= end; number++)
              _userNode(number),
          ],
          hasNext: hasNext,
          cursor: hasNext ? '$end' : null,
        ),
      },
    };
  }

  Map<String, Object?> _mutationEnvelope() {
    return {
      'data': {
        'workItemUpdate': {
          'errors': <String>[],
          'workItem': _summaryNode(
            preview: false,
            users: [
              for (final id in lastAssigneeIds)
                _userNode(int.parse(id.split('/').last)),
            ],
            hasNext: false,
            cursor: null,
          ),
        },
      },
    };
  }

  Map<String, Object?> _summaryNode({
    required bool preview,
    List<Map<String, Object?>>? users,
    bool? hasNext,
    String? cursor,
  }) {
    final shown =
        users ??
        [
          for (var number = 1; number <= userCount && number <= 20; number++)
            _userNode(number),
        ];
    final more = hasNext ?? (preview && userCount > 20);
    return {
      'id': workItemId,
      'iid': '31',
      'title': '合成工作項目',
      'state': 'OPEN',
      'createdAt': '2026-09-01T01:02:03Z',
      'updatedAt': updatedAt,
      'description': '說明',
      if (!groupOnly)
        'project': {'id': 'gid://gitlab/Project/42', 'fullPath': project.path},
      if (groupOnly) 'project': null,
      'namespace': {
        'id': groupOnly ? groupNamespaceId : namespaceId,
        'fullPath': groupOnly ? 'group/sample' : project.path,
      },
      'workItemType': {'id': typeId, 'name': 'Task'},
      'userPermissions': {
        'readWorkItem': true,
        'setWorkItemMetadata': canWrite,
      },
      'widgets': widgetPresent
          ? [
              {
                'type': 'ASSIGNEES',
                'allowsMultipleAssignees': allowsMultiple,
                'assignees': {
                  'nodes': shown,
                  'pageInfo': {
                    'hasNextPage': more,
                    'endCursor': cursor ?? (more ? '20' : null),
                  },
                },
              },
            ]
          : <Object?>[],
    };
  }

  Map<String, Object?> _userNode(
    int number, {
    String? name,
    String? username,
  }) => {
    'id': userId(number),
    'name': name ?? userName(number),
    'username': username ?? 'user$number',
  };
}
