import 'dart:async';

import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_labels_models.dart';

import 'fake_adapter.dart';

final class WorkItemLabelsDetailSnapshot {
  const WorkItemLabelsDetailSnapshot._({
    required this.labelTitles,
    required this.updatedAt,
    required Map<String, Object?> envelope,
  }) : _envelope = envelope;

  final List<String> labelTitles;
  final String updatedAt;
  final Map<String, Object?> _envelope;
}

final class WorkItemLabelsDetailRequest {
  final Completer<void> _started = Completer<void>();
  final Completer<ResponseBody> _response = Completer<ResponseBody>();
  late WorkItemLabelsDetailSnapshot snapshot;

  bool get started => _started.isCompleted;

  Future<ResponseBody> get _future => _response.future;

  void _capture(WorkItemLabelsDetailSnapshot value) {
    snapshot = value;
    _started.complete();
  }

  void succeed() {
    if (!started) throw StateError('Detail request has not started.');
    if (_response.isCompleted) {
      throw StateError('Detail request already completed.');
    }
    _response.complete(jsonResponse(snapshot._envelope));
  }

  void fail({int status = 500}) {
    if (!started) throw StateError('Detail request has not started.');
    if (_response.isCompleted) {
      throw StateError('Detail request already completed.');
    }
    _response.complete(
      jsonResponse({
        'errors': [
          const {'message': 'held parent detail request failed'},
        ],
      }, status: status),
    );
  }
}

/// Synthetic work-item labels server for widget testing.
/// Answers real GraphQL queries/mutations and tracks requests.
class WorkItemLabelsFixture {
  WorkItemLabelsFixture({
    this.initialLabelCount = 2,
    this.allowsScoped = WorkItemLabelAllowsScoped.unknown,
    this.readWorkItem = true,
    this.setWorkItemMetadata = true,
    this.widgetPresent = true,
    this.groupOnly = false,
    this.candidateLimit = 3,
    this.initialCustomLabels,
  }) {
    if (initialCustomLabels != null) {
      for (final label in initialCustomLabels!) {
        _labelsRegistry[label.id] = label;
      }
      _initialIds = initialCustomLabels!.map((l) => l.id).toList();
    } else {
      for (var i = 1; i <= initialLabelCount; i++) {
        final id = labelId(i);
        _labelsRegistry[id] = WorkItemLabel(
          id: id,
          title: labelTitle(i),
          color: labelColor(i),
          textColor: labelTextColor(i),
        );
      }
      _initialIds = [for (var i = 1; i <= initialLabelCount; i++) labelId(i)];
    }
    _currentPersistedIds = List.of(_initialIds);

    adapter = FakeAdapter(_respond);
    api = testApi(adapter);
  }

  final int initialLabelCount;
  final WorkItemLabelAllowsScoped allowsScoped;
  final bool readWorkItem;
  final bool setWorkItemMetadata;
  final bool widgetPresent;
  final bool groupOnly;
  final int candidateLimit;
  final List<WorkItemLabel>? initialCustomLabels;

  late final FakeAdapter adapter;
  late GitLabApi api;

  final account = Account(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    user: const GitLabUser(id: 7, username: 'ada', name: 'Ada'),
    token: 'synthetic-test-token',
  );

  final Project project = Project.fromJson(projectJson(42));

  static const workItemId = 'gid://gitlab/WorkItem/501';
  static const typeId = 'gid://gitlab/WorkItems::Type/9';
  static const namespaceId = 'gid://gitlab/Group/77';
  static const groupNamespaceId = 'gid://gitlab/Group/88';

  String updatedAt = '2026-10-03T09:00:00Z';
  String newUpdatedAt = '2026-10-03T10:00:00Z';

  final Map<String, WorkItemLabel> _labelsRegistry = {};
  late List<String> _initialIds;
  late List<String> _currentPersistedIds;

  bool conflictOnNextRead = false;
  bool failReadsAfterMutation = false;
  bool failParentRefetchAfterMutation = false;
  bool failPreflight = false;
  bool notApplied = false;
  int? mutationHttpError;
  List<String>? mutationErrors;

  bool mutationSent = false;
  int mutations = 0;
  int mutationApplies = 0;
  List<String> lastAddLabelIds = const [];
  List<String> lastRemoveLabelIds = const [];
  Map<String, Object?>? lastInput;

  Completer<void>? holdMutationApply;
  Completer<ResponseBody>? holdMutation;
  Completer<ResponseBody>? holdLabelsRead;
  final List<WorkItemLabelsDetailRequest> _heldDetailReads =
      <WorkItemLabelsDetailRequest>[];
  final heldSearches = <String, Completer<ResponseBody>>{};

  int labelsReads = 0;
  int projectSearches = 0;
  int groupSearches = 0;
  int detailReads = 0;
  String? lastSearchTerm;

  String labelId(int number) => 'gid://gitlab/ProjectLabel/$number';
  String labelTitle(int number) => '標籤$number';
  String labelColor(int number) => '#1068BF';
  String labelTextColor(int number) => '#FFFFFF';

  void registerLabel(WorkItemLabel label) {
    _labelsRegistry[label.id] = label;
  }

  WorkItemLabelsDetailRequest holdNextDetailRead() {
    final request = WorkItemLabelsDetailRequest();
    _heldDetailReads.add(request);
    return request;
  }

  void replacePersistedLabels(List<WorkItemLabel> labels) {
    for (final label in labels) {
      _labelsRegistry[label.id] = label;
    }
    _currentPersistedIds = labels
        .map((label) => label.id)
        .toList(growable: false);
    updatedAt = '2026-10-03T12:00:00Z';
  }

  void releaseHoldMutation() {
    final held = holdMutation;
    holdMutation = null;
    held?.complete(jsonResponse(_mutationEnvelope()));
  }

  void releaseHoldMutationApply() {
    final held = holdMutationApply;
    holdMutationApply = null;
    held?.complete();
  }

  void releaseHoldLabelsRead() {
    final held = holdLabelsRead;
    holdLabelsRead = null;
    held?.complete(jsonResponse(_fullLabelsPage(null)));
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
      detailReads++;
      if (mutationSent && failParentRefetchAfterMutation) {
        return jsonResponse({
          'errors': [
            const {'message': 'parent refetch failed'},
          ],
        }, status: 500);
      }
      final envelope = _detailEnvelope();
      if (_heldDetailReads.isNotEmpty) {
        final held = _heldDetailReads.removeAt(0);
        held._capture(
          WorkItemLabelsDetailSnapshot._(
            labelTitles: List<String>.unmodifiable(
              _currentPersistedIds.map(
                (id) => _labelsRegistry[id]?.title ?? '標籤-$id',
              ),
            ),
            updatedAt: updatedAt,
            envelope: envelope,
          ),
        );
        return held._future;
      }
      return jsonResponse(envelope);
    }

    if (query.contains('MobileWorkItemLabels')) {
      labelsReads++;
      final heldRead = holdLabelsRead;
      if (heldRead != null) return heldRead.future;
      if (mutationSent) {
        if (failReadsAfterMutation) {
          return jsonResponse({
            'errors': [
              const {'message': 'read after mutation failed'},
            ],
          }, status: 500);
        }
      }
      if (conflictOnNextRead) {
        conflictOnNextRead = false;
        updatedAt = '2026-10-04T01:02:03Z';
      }
      if (failPreflight && !mutationSent && labelsReads > 1) {
        return jsonResponse({
          'errors': [
            const {'message': 'preflight failed'},
          ],
        }, status: 500);
      }
      final after = vars['after'] as String?;
      return jsonResponse(_fullLabelsPage(after));
    }

    if (query.contains('MobileProjectLabelCandidates')) {
      projectSearches++;
      lastSearchTerm = vars['search']?.toString();
      final after = vars['after'] as String?;
      return _candidatesResponse(
        lastSearchTerm ?? '',
        after: after,
        isGroup: false,
      );
    }

    if (query.contains('MobileGroupLabelCandidates')) {
      groupSearches++;
      lastSearchTerm = vars['search']?.toString();
      final after = vars['after'] as String?;
      return _candidatesResponse(
        lastSearchTerm ?? '',
        after: after,
        isGroup: true,
      );
    }

    if (query.contains('MobileUpdateWorkItemLabels')) {
      mutations++;
      mutationSent = true;
      final input = vars['input'];
      if (input is Map<String, Object?>) {
        lastInput = input;
        final widgetMap = input['labelsWidget'];
        if (widgetMap is Map) {
          final adds = widgetMap['addLabelIds'];
          final removes = widgetMap['removeLabelIds'];
          lastAddLabelIds = adds is List
              ? [for (final id in adds) '$id']
              : const [];
          lastRemoveLabelIds = removes is List
              ? [for (final id in removes) '$id']
              : const [];
        }
      }

      final applyHold = holdMutationApply;
      if (applyHold != null) await applyHold.future;
      if (!notApplied) {
        _currentPersistedIds = [
          for (final id in _currentPersistedIds)
            if (!lastRemoveLabelIds.contains(id)) id,
          ...lastAddLabelIds,
        ];
      }
      mutationApplies++;
      updatedAt = mutations == 1
          ? newUpdatedAt
          : DateTime.parse(
              newUpdatedAt,
            ).add(Duration(hours: mutations - 1)).toUtc().toIso8601String();

      if (mutationHttpError != null) {
        return jsonResponse({
          'errors': [
            const {'message': 'mutation http failure'},
          ],
        }, status: mutationHttpError!);
      }

      final held = holdMutation;
      if (held != null) return held.future;
      return jsonResponse(_mutationEnvelope());
    }

    return jsonResponse(<String, Object?>{'data': <String, Object?>{}});
  }

  Future<ResponseBody> _candidatesResponse(
    String search, {
    String? after,
    required bool isGroup,
  }) async {
    final held = heldSearches.remove(search);
    if (held != null) {
      heldSearches['pending:$search'] = held;
      return held.future;
    }
    if (search == '失敗') {
      return jsonResponse({
        'errors': [
          const {'message': 'candidate search failed'},
        ],
      }, status: 500);
    }

    final candidateList = <Map<String, Object?>>[];
    for (var i = 1; i <= candidateLimit; i++) {
      final candId =
          'gid://gitlab/${isGroup ? 'GroupLabel' : 'ProjectLabel'}/${2000 + i}';
      final candTitle = '候選$i-$search';
      final candNode = {
        'id': candId,
        'title': candTitle,
        'color': '#008800',
        'textColor': '#FFFFFF',
      };
      _labelsRegistry[candId] = WorkItemLabel(
        id: candId,
        title: candTitle,
        color: '#008800',
        textColor: '#FFFFFF',
      );
      candidateList.add(candNode);
    }

    final pageNum = after == null
        ? 0
        : (int.tryParse(after.split('_').last) ?? 1);
    final startIndex = pageNum * 20;
    final pageNodes = candidateList.skip(startIndex).take(20).toList();
    final nextIndex = startIndex + pageNodes.length;
    final hasNext = nextIndex < candidateList.length;
    final endCursor = hasNext ? 'cand_cursor_${pageNum + 1}' : null;
    final container = isGroup
        ? {
            'id': groupNamespaceId,
            'fullPath': 'group/sample',
            'labels': {
              'nodes': pageNodes,
              'pageInfo': {'hasNextPage': hasNext, 'endCursor': endCursor},
            },
          }
        : {
            'id': 'gid://gitlab/Project/42',
            'fullPath': project.path,
            'labels': {
              'nodes': pageNodes,
              'pageInfo': {'hasNextPage': hasNext, 'endCursor': endCursor},
            },
          };

    return jsonResponse({
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/7'},
        if (isGroup) 'group': container else 'project': container,
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

  Map<String, Object?> _fullLabelsPage(String? after) {
    final idsToRender = _currentPersistedIds;

    final start = after == null ? 0 : int.tryParse(after) ?? 0;
    final end = (start + 100 > idsToRender.length)
        ? idsToRender.length
        : start + 100;
    final hasNext = end < idsToRender.length;

    final pageIds = idsToRender.sublist(start, end);
    final nodes = <Map<String, Object?>>[];
    for (final id in pageIds) {
      final label =
          _labelsRegistry[id] ??
          WorkItemLabel(
            id: id,
            title: '標籤-$id',
            color: '#1068BF',
            textColor: '#FFFFFF',
          );
      nodes.add({
        'id': label.id,
        'title': label.title,
        'color': label.color,
        'textColor': label.textColor,
      });
    }

    return {
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/7'},
        'workItem': {
          'id': workItemId,
          'iid': '100',
          'title': '測試工作項目',
          'state': 'OPEN',
          'createdAt': '2026-10-03T08:00:00Z',
          'updatedAt': updatedAt,
          'project': groupOnly
              ? null
              : {'id': 'gid://gitlab/Project/42', 'fullPath': project.path},
          'namespace': {
            'id': groupOnly ? groupNamespaceId : namespaceId,
            'fullPath': groupOnly ? 'group/sample' : project.path,
          },
          'workItemType': {
            'id': typeId,
            'name': 'Issue',
            'widgetDefinitions': [
              {
                'type': 'LABELS',
                'allowsScopedLabels':
                    allowsScoped == WorkItemLabelAllowsScoped.allowed
                    ? true
                    : (allowsScoped == WorkItemLabelAllowsScoped.disabled
                          ? false
                          : null),
              },
            ],
          },
          'userPermissions': {
            'readWorkItem': readWorkItem,
            'setWorkItemMetadata': setWorkItemMetadata,
          },
          'widgets': [
            if (widgetPresent)
              {
                'type': 'LABELS',
                'labels': {
                  'nodes': nodes,
                  'pageInfo': {
                    'hasNextPage': hasNext,
                    'endCursor': hasNext ? '$end' : null,
                  },
                },
              },
          ],
        },
      },
    };
  }

  Map<String, Object?> _mutationEnvelope() {
    return {
      'data': {
        'workItemUpdate': {
          'errors': mutationErrors ?? <String>[],
          'workItem': {'id': workItemId, 'updatedAt': updatedAt},
        },
      },
    };
  }

  Map<String, Object?> _summaryNode({required bool preview}) {
    final ids = _currentPersistedIds;
    final previewIds = ids.take(50).toList();
    final nodes = <Map<String, Object?>>[];
    for (final id in previewIds) {
      final label =
          _labelsRegistry[id] ??
          WorkItemLabel(
            id: id,
            title: '標籤-$id',
            color: '#1068BF',
            textColor: '#FFFFFF',
          );
      nodes.add({
        'id': label.id,
        'title': label.title,
        'color': label.color,
        'textColor': label.textColor,
      });
    }

    return {
      'id': workItemId,
      'iid': '100',
      'title': '測試工作項目',
      'state': 'OPEN',
      'createdAt': '2026-10-03T08:00:00Z',
      'updatedAt': updatedAt,
      'project': groupOnly
          ? null
          : {'id': 'gid://gitlab/Project/42', 'fullPath': project.path},
      'namespace': {
        'id': groupOnly ? groupNamespaceId : namespaceId,
        'fullPath': groupOnly ? 'group/sample' : project.path,
      },
      'workItemType': {'id': typeId, 'name': 'Issue'},
      'userPermissions': {
        'readWorkItem': readWorkItem,
        'setWorkItemMetadata': setWorkItemMetadata,
      },
      'widgets': [
        if (widgetPresent)
          {
            'type': 'LABELS',
            'labels': {
              'nodes': nodes,
              'pageInfo': {
                'hasNextPage': ids.length > 50,
                'endCursor': ids.length > 50 ? 'cursor_50' : null,
              },
            },
          },
      ],
    };
  }
}
