import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/ai_work_item_write_registry.dart';
import 'package:gitlab_mobile/core/ai/exact_edit.dart' as exact;
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_support.dart';

/// Plan v6 §4.4 reserves the GitLab HTTP allowance through readback when the
/// proposal is created. The budget and boundary test headers enumerate §15
/// rows 19/25/29 coverage, coverage in other suites and explicit NOT_RUN gaps.
///
/// The tree has eleven `mr6b3_*_port_test.dart` files (fifteen operations).
/// Breakdown §5 lists those eleven files.

const mr6b3Revision = '2026-10-23T00:00:00Z';
const mr6b3BumpedRevision = '2026-10-23T00:01:00Z';
const mr6b3ActivityBody = 'Synthetic **activity** note';
// Compatibility default for callers outside the harness. Each harness captures
// its own value and shares it across arguments, fixtures and expectations.
final mr6b3SnoozeUntil = _futureSnoozeUntil(DateTime.now());

String _futureSnoozeUntil(DateTime now) {
  final future = now.toUtc().add(const Duration(days: 1));
  // The write port normalizes snoozes to seconds; keep its input and fixture
  // identical rather than letting fractional seconds drift at that boundary.
  return DateTime.utc(
    future.year,
    future.month,
    future.day,
    future.hour,
    future.minute,
    future.second,
  ).toIso8601String();
}

const mr6b3StatusDoing = 'gid://gitlab/WorkItems::Statuses::Custom::Status/37';

const _workItemId = 'gid://gitlab/WorkItem/31';
const _projectRef = <String, Object?>{
  'id': 'gid://gitlab/Project/9',
  'fullPath': 'team/example-9',
};
const _namespaceRef = <String, Object?>{
  'id': 'gid://gitlab/Namespaces::ProjectNamespace/9',
  'fullPath': 'team/example-9',
};
const _typeRef = <String, Object?>{
  'id': 'gid://gitlab/WorkItems::Type/9',
  'name': 'Task',
};
const _actor = <String, Object?>{'id': 'gid://gitlab/User/7'};
const _discussionId = 'gid://gitlab/Discussion/server-owned';
const _replyId = 'gid://gitlab/IndividualNoteDiscussion/server-owned';
const _noteId = 'gid://gitlab/Note/401';
const _createdNoteId = 'gid://gitlab/DiscussionNote/501';
const _statusTodo = 'gid://gitlab/WorkItems::Statuses::SystemDefined::Status/1';
const _statusDone = 'gid://gitlab/WorkItems::Statuses::Custom::Status/38';
const _statusCanceled =
    'gid://gitlab/WorkItems::Statuses::SystemDefined::Status/5';

const _people = <int, String>{
  11: 'current',
  21: 'alice',
  22: 'bob',
  23: 'carol',
  24: 'dave',
};

const _statusMembers = <Map<String, Object?>>[
  {
    'id': _statusTodo,
    'name': 'To do',
    'iconName': 'status_todo',
    'color': '#737278',
    'position': 0,
    'description': 'Not started',
    'category': 'TO_DO',
  },
  {
    'id': mr6b3StatusDoing,
    'name': 'Doing',
    'iconName': 'status_running',
    'color': '#1f75cb',
    'position': 1,
    'description': null,
    'category': 'IN_PROGRESS',
  },
  {
    'id': _statusDone,
    'name': 'Done',
    'iconName': 'status_success',
    'color': '#108548',
    'position': 2,
    'description': 'Closed by the server',
    'category': 'DONE',
  },
  {
    'id': _statusCanceled,
    'name': 'Canceled',
    'iconName': 'status_canceled',
    'color': '#dd2b0e',
    'position': 3,
    'description': null,
    'category': 'CANCELED',
  },
];

final class _Lease implements AiWorkItemWriteLease {
  _Lease(this.gid, this.kind);

  @override
  final String gid;

  @override
  final AiWorkItemWriteKind kind;
}

final class _Registry implements AiWorkItemWriteRegistry {
  @override
  bool isActive(String gid) => false;

  @override
  AiWorkItemWriteLease? tryStart(String gid, AiWorkItemWriteKind kind) =>
      _Lease(gid, kind);

  @override
  void settle(
    AiWorkItemWriteLease lease,
    AiWorkItemWriteResult result,
    DateTime? revision,
  ) {}
}

/// One adapter for every MR6b-3 GraphQL write. Token refresh uses a second
/// adapter, so [adapter.requests] is the API allowance only.
///
/// A 401 is withheld for assignee candidates, the third assignees read, the
/// third status read and the third weight read. Those are the family success
/// paths: refreshing them advances the read epoch after the target is bound.
/// The static cap still includes a replay of every logical read.
final class Mr6b3ApiServer {
  Mr6b3ApiServer({
    this.oauth = false,
    bool? replayReads,
    this.challengeEveryRead = false,
    String? snoozeUntil,
  }) : replayReads = replayReads ?? oauth,
       snoozeUntil = snoozeUntil ?? mr6b3SnoozeUntil {
    adapter = FakeAdapter(_respond);
    refreshAdapter = FakeAdapter((_) {
      refreshes++;
      return jsonResponse({
        'access_token': 'synthetic-access-$refreshes',
        'refresh_token': 'synthetic-refresh-$refreshes',
        'token_type': 'bearer',
        'expires_in': 7200,
      });
    });
    final instance = mr6b3Scope.resolvedInstance!;
    api = oauth
        ? GitLabApi(
            instance: instance,
            credential: const OAuthCredential(
              accessToken: 'synthetic-access',
              refreshToken: 'synthetic-refresh',
              clientId: 'synthetic-client',
            ),
            dio: Dio()..httpClientAdapter = adapter,
            oauth: OAuthTokenClient(
              instance: instance,
              clientId: 'synthetic-client',
              dio: Dio()..httpClientAdapter = refreshAdapter,
            ),
          )
        : testApi(adapter);
    writePort = port.GitLabAiWritePort(
      api,
      accountKey: mr6b3Account,
      workItemWriteRegistry: _Registry(),
    );
  }

  final bool oauth;
  final bool replayReads;
  final bool challengeEveryRead;
  final String snoozeUntil;
  bool applyMutations = true;

  /// The GraphQL identity-variable check assumes project 9. A test that
  /// answers another project through [onRequest] turns it off for that server;
  /// the port still verifies the identity in the returned payload.
  bool checkGraphqlIdentity = true;

  /// Runs at the real adapter boundary, after accounting and optional mutation
  /// application. A null return serves the normal payload. Tests can inspect
  /// journal state, edit a payload, return an HTTP failure, or throw transport
  /// cancellation without replacing the production port.
  ResponseBody? Function(
    String name,
    bool mutation,
    RequestOptions request,
    Map<String, Object?> payload,
  )?
  onRequest;
  late final FakeAdapter adapter;
  late final FakeAdapter refreshAdapter;
  late final GitLabApi api;
  late final port.GitLabAiWritePort writePort;

  final reads = <String, int>{};
  final reactionStages = <int>[];
  // Dio converts adapter assertions into transport failures. Retain them so
  // teardown checks the original contract even when production handles it.
  final unexpectedRequests = <String>[];
  final requestCheckFailures = <String>[];
  int logicalReads = 0;
  int mutations = 0;
  int refreshes = 0;

  String revision = mr6b3Revision;
  String workItemState = 'OPEN';
  String incidentStatus = 'TRIGGERED';
  String incidentUpdatedAt = mr6b3Revision;
  String healthStatus = 'onTrack';
  String statusId = _statusTodo;
  String? milestoneId = 'gid://gitlab/Milestone/5';
  String startDate = '2026-10-05';
  String dueDate = '2026-10-20';
  String noteUpdatedAt = '2026-10-01T01:03:04Z';
  String createdBody = mr6b3ActivityBody;
  int? weight = 3;
  bool notificationsOn = false;
  bool reactionAwarded = false;
  List<int> users = const [11];
  bool _replaying = false;

  void close() => api.close();

  void verifyRequests() {
    expect(unexpectedRequests, isEmpty, reason: 'Unexpected synthetic routes');
    expect(requestCheckFailures, isEmpty, reason: 'Synthetic adapter checks');
  }

  ResponseBody _respond(RequestOptions request) {
    try {
      return _respondChecked(request);
    } on TestFailure catch (error, stack) {
      requestCheckFailures.add(
        '${request.method} ${request.uri}: $error\n$stack',
      );
      rethrow;
    }
  }

  Never _unexpected(RequestOptions request, String detail) {
    final message =
        'Unexpected synthetic route: ${request.method} ${request.uri} $detail';
    unexpectedRequests.add(message);
    fail(message);
  }

  ResponseBody _respondChecked(RequestOptions request) {
    final query = _query(request);
    final classified = _classify(request, query, api.instance.graphQL);
    if (classified == null) {
      final head = query == null ? '' : ' ${query.split('\n').first}';
      _unexpected(request, head);
    }
    if (query != null && checkGraphqlIdentity) {
      _checkGraphqlIdentity(classified.name, classified.mutation, request);
    }
    if (oauth &&
        replayReads &&
        !classified.mutation &&
        _replay(classified.name)) {
      if (!_replaying) {
        _replaying = true;
        return jsonResponse({'message': 'synthetic expired read'}, status: 401);
      }
      _replaying = false;
    }
    reads.update(classified.name, (count) => count + 1, ifAbsent: () => 1);
    if (classified.mutation) {
      mutations++;
      if (applyMutations) _applyMutation(classified.name, request);
    } else {
      logicalReads++;
    }
    final payload = _payload(classified.name, request);
    return onRequest?.call(
          classified.name,
          classified.mutation,
          request,
          payload,
        ) ??
        jsonResponse(payload);
  }

  void _checkGraphqlIdentity(
    String name,
    bool mutation,
    RequestOptions request,
  ) {
    final variables = _variables(request);
    final actual = mutation && !name.startsWith('MobileTodo')
        ? _input(variables)
        : variables;
    final Map<String, Object?> expected = mutation
        ? switch (name) {
            'MobileUpdateWorkItemState' ||
            'MobileUpdateWorkItemStatus' ||
            'MobileSetWorkItemHealthStatus' ||
            'MobileSetWorkItemDatesEe' ||
            'MobileSetWorkItemDatesCe' ||
            'MobileSetWorkItemMilestone' ||
            'MobileSetWorkItemWeight' ||
            'MobileSetWorkItemAssignees' ||
            'MobileSetWorkItemNotifications' => {'id': _workItemId},
            'MobileSetIncidentStatus' => {
              'projectPath': 'team/example-9',
              'iid': '3',
            },
            'MobileAddWorkItemActivityNoteReaction' ||
            'MobileRemoveWorkItemActivityNoteReaction' => {
              'awardableId': _noteId,
            },
            'MobileCreateWorkItemActivityNote' => {'noteableId': _workItemId},
            'MobileDestroyWorkItemActivityNote' => {'id': _noteId},
            'MobileTodoSnooze' => {'id': 'gid://gitlab/Todo/400'},
            'MobileTodoUnsnooze' => {'id': 'gid://gitlab/Todo/400'},
            _ => _unexpected(request, 'mutation $name'),
          }
        : switch (name) {
            'MobileProjectWorkItem' ||
            'MobileIncidentStatus' => {'path': 'team/example-9', 'iid': '3'},
            'MobileWorkItemState' ||
            'MobileWorkItemStatus' ||
            'MobileWorkItemHealthEdit' ||
            'MobileWorkItemDatesBase' ||
            'MobileWorkItemDatesProbe' ||
            'MobileWorkItemMilestone' ||
            'MobileWorkItemWeight' ||
            'MobileWorkItemAssignees' ||
            'MobileWorkItemNotifications' ||
            'MobileWorkItemActivity' ||
            'MobileWorkItemActivityWriteAccess' => {'id': _workItemId},
            'MobileProjectWorkItemMilestones' ||
            'MobileProjectAssigneeCandidates' => {'fullPath': 'team/example-9'},
            'MobileWorkItemActivityReplyPreflight' => {
              'workItemId': _workItemId,
              'anchorNoteId': _noteId,
            },
            'MobileWorkItemActivityReactionAccess' ||
            'MobileWorkItemActivityEditAccess' ||
            'MobileWorkItemActivityDeleteReadback' => {
              'workItemId': _workItemId,
              'noteId': _noteId,
            },
            'MobileWorkItemActivityNoteReadback' => {
              'workItemId': _workItemId,
              'noteId': _createdNoteId,
            },
            'MobilePendingTodosForSnooze' ||
            'MobileSnoozedTodosForUnsnooze' ||
            'MobileSnoozedTodos' => {'first': 100},
            _ => _unexpected(request, 'query $name'),
          };
    for (final entry in expected.entries) {
      expect(actual, containsPair(entry.key, entry.value), reason: name);
    }
    if (name == 'MobileCreateWorkItemActivityNote' &&
        actual.containsKey('discussionId')) {
      expect(actual['discussionId'], _replyId, reason: name);
    }
  }

  bool _replay(String name) {
    if (challengeEveryRead) return true;
    final next = (reads[name] ?? 0) + 1;
    return switch (name) {
      'MobileProjectAssigneeCandidates' => false,
      'MobileWorkItemAssignees' => next != 3,
      'MobileWorkItemStatus' => next != 3,
      'MobileWorkItemWeight' => next != 3,
      _ => true,
    };
  }

  void _applyMutation(String name, RequestOptions request) {
    final variables = _variables(request);
    switch (name) {
      case 'MobileUpdateWorkItemState':
        final event = _input(variables)['stateEvent'];
        workItemState = event == 'REOPEN' ? 'OPEN' : 'CLOSED';
        revision = mr6b3BumpedRevision;
      case 'MobileUpdateWorkItemStatus':
        final selected = _widget(_input(variables), 'statusWidget')['status'];
        if (selected is String) statusId = selected;
        revision = mr6b3BumpedRevision;
      case 'MobileSetWorkItemHealthStatus':
        final selected = _widget(
          _input(variables),
          'healthStatusWidget',
        )['healthStatus'];
        healthStatus = selected is String ? selected : 'onTrack';
        revision = mr6b3BumpedRevision;
      case 'MobileSetWorkItemDatesEe':
      case 'MobileSetWorkItemDatesCe':
        final widget = _widget(_input(variables), 'startAndDueDateWidget');
        final start = widget['startDate'];
        final due = widget['dueDate'];
        if (start is String) startDate = start;
        if (due is String) dueDate = due;
      case 'MobileSetWorkItemMilestone':
        final selected = _widget(
          _input(variables),
          'milestoneWidget',
        )['milestoneId'];
        milestoneId = selected is String ? selected : null;
        revision = mr6b3BumpedRevision;
      case 'MobileSetWorkItemWeight':
        final selected = _widget(_input(variables), 'weightWidget')['weight'];
        weight = selected is int ? selected : null;
        revision = mr6b3BumpedRevision;
      case 'MobileSetWorkItemAssignees':
        users = _assigneeIds(_widget(_input(variables), 'assigneesWidget'));
        revision = mr6b3BumpedRevision;
      case 'MobileSetIncidentStatus':
        final selected = _input(variables)['status'];
        if (selected is String) incidentStatus = selected;
      case 'MobileSetWorkItemNotifications':
        final selected = _input(variables)['subscribed'];
        if (selected is bool) notificationsOn = selected;
      case 'MobileAddWorkItemActivityNoteReaction':
        reactionAwarded = true;
        noteUpdatedAt = '2026-10-01T01:03:05Z';
      case 'MobileRemoveWorkItemActivityNoteReaction':
        reactionAwarded = false;
        noteUpdatedAt = '2026-10-01T01:03:05Z';
      case 'MobileCreateWorkItemActivityNote':
        final body = _input(variables)['body'];
        if (body is String) createdBody = body;
      case 'MobileTodoSnooze':
      case 'MobileTodoUnsnooze':
      case 'MobileDestroyWorkItemActivityNote':
        break;
      default:
        _unexpected(request, 'mutation $name');
    }
  }

  Map<String, Object?> _payload(String name, RequestOptions request) {
    final variables = _variables(request);
    return switch (name) {
      'user' => {'id': 7, 'username': 'synthetic', 'name': 'Synthetic actor'},
      'freshness' => projectJson(9),
      'MobileProjectWorkItem' => _projectWorkItem(_detail()),
      'MobileWorkItemState' => {
        'data': {'workItem': _stateNode()},
      },
      'MobileUpdateWorkItemState' => {
        'data': {
          'workItemUpdate': {'errors': <Object?>[], 'workItem': _stateNode()},
        },
      },
      'MobileWorkItemStatus' => {
        'data': {'currentUser': _actor, 'workItem': _statusNode(ack: false)},
      },
      'MobileUpdateWorkItemStatus' => {
        'data': {
          'workItemUpdate': {
            'errors': <Object?>[],
            'workItem': _statusNode(ack: true),
          },
        },
      },
      'MobileWorkItemHealthEdit' => {
        'data': {
          'currentUser': _actor,
          'workItem': _healthNode(includePermissions: true),
        },
      },
      'MobileSetWorkItemHealthStatus' => {
        'data': {
          'workItemUpdate': {
            'errors': <Object?>[],
            'workItem': _healthNode(includePermissions: false),
          },
        },
      },
      'MobileWorkItemDatesBase' => {
        'data': {
          'currentUser': _actor,
          'workItem': _datesNode(probe: false, permissions: true),
        },
      },
      'MobileWorkItemDatesProbe' => {
        'data': {
          'currentUser': _actor,
          'workItem': _datesNode(probe: true, permissions: true),
        },
      },
      'MobileSetWorkItemDatesEe' => {
        'data': {
          'workItemUpdate': {
            'errors': <Object?>[],
            'workItem': _datesNode(probe: true, permissions: false),
          },
        },
      },
      'MobileSetWorkItemDatesCe' => {
        'data': {
          'workItemUpdate': {
            'errors': <Object?>[],
            'workItem': _datesNode(probe: false, permissions: false),
          },
        },
      },
      'MobileWorkItemMilestone' => {
        'data': {'currentUser': _actor, 'workItem': _milestoneNode()},
      },
      'MobileSetWorkItemMilestone' => {
        'data': {
          'workItemUpdate': {
            'errors': <Object?>[],
            'workItem': _milestoneNode(),
          },
        },
      },
      'MobileProjectWorkItemMilestones' => _milestoneChoices(),
      'MobileWorkItemWeight' => {
        'data': {'currentUser': _actor, 'workItem': _weightNode()},
      },
      'MobileSetWorkItemWeight' => {
        'data': {
          'workItemUpdate': {'errors': <Object?>[], 'workItem': _weightNode()},
        },
      },
      'MobileWorkItemAssignees' => {
        'data': {'currentUser': _actor, 'workItem': _assigneesNode()},
      },
      'MobileSetWorkItemAssignees' => {
        'data': {
          'workItemUpdate': {
            'errors': <Object?>[],
            'workItem': _assigneesNode(),
          },
        },
      },
      'MobileProjectAssigneeCandidates' => _candidates(variables['search']),
      'MobileIncidentStatus' => _incidentEnvelope(),
      'MobileSetIncidentStatus' => {
        'data': {
          'issueSetEscalationStatus': {
            'errors': <Object?>[],
            'issue': _incidentIssue(),
          },
        },
      },
      'MobileWorkItemNotifications' => {
        'data': {'currentUser': _actor, 'workItem': _notificationNode()},
      },
      'MobileSetWorkItemNotifications' => {
        'data': {
          'workItemSubscribe': {
            'errors': <Object?>[],
            'workItem': _notificationNode(),
          },
        },
      },
      'MobileWorkItemActivity' => _activity(
        firstPage: variables['after'] == null,
      ),
      'MobileWorkItemActivityReactionAccess' => _reactionAccess(
        variables['after'],
      ),
      'MobileAddWorkItemActivityNoteReaction' => {
        'data': {
          'awardEmojiAdd': {
            'errors': <Object?>[],
            'awardEmoji': _award(7, 'thumbsup'),
          },
        },
      },
      'MobileRemoveWorkItemActivityNoteReaction' => {
        'data': {
          'awardEmojiRemove': {'errors': <Object?>[]},
        },
      },
      'MobileWorkItemActivityWriteAccess' => _noteAccess(anchor: false),
      'MobileWorkItemActivityReplyPreflight' => _noteAccess(anchor: true),
      'MobileCreateWorkItemActivityNote' => {
        'data': {
          'createNote': {
            'errors': <Object?>[],
            'note': _createdNote(createdBody),
          },
        },
      },
      'MobileWorkItemActivityNoteReadback' => {
        'data': {'workItem': _identity(), 'note': _createdNote(createdBody)},
      },
      'MobileWorkItemActivityEditAccess' => {
        'data': {
          'currentUser': _actor,
          'workItem': _identity(),
          'note': _existingNote(),
        },
      },
      'MobileDestroyWorkItemActivityNote' => {
        'data': {
          'destroyNote': {'errors': <Object?>[]},
        },
      },
      'MobileWorkItemActivityDeleteReadback' => {
        'data': {'currentUser': _actor, 'workItem': _identity(), 'note': null},
      },
      'MobilePendingTodosForSnooze' => _todoPage(
        snoozed: false,
        after: variables['after'],
      ),
      'MobileSnoozedTodosForUnsnooze' => _todoPage(
        snoozed: true,
        after: variables['after'],
      ),
      'MobileSnoozedTodos' => {
        'data': {
          'currentUser': {
            'todos': {
              'nodes': <Object?>[],
              'pageInfo': {'hasNextPage': false},
            },
          },
        },
      },
      'MobileTodoSnooze' => {
        'data': {
          'todoSnooze': {
            'errors': <Object?>[],
            'todo': {'id': variables['id'], 'snoozedUntil': variables['until']},
          },
        },
      },
      'MobileTodoUnsnooze' => {
        'data': {
          'todoUnSnooze': {
            'errors': <Object?>[],
            'todo': {'id': variables['id'], 'snoozedUntil': null},
          },
        },
      },
      _ => _unexpected(request, 'operation $name'),
    };
  }

  Map<String, Object?> _summary() => {
    'id': _workItemId,
    'iid': '3',
    'title': 'Synthetic item',
    'state': workItemState,
    'createdAt': '2026-10-01T00:00:00Z',
    'updatedAt': revision,
    'project': _projectRef,
    'namespace': _namespaceRef,
    'workItemType': _typeRef,
  };

  Map<String, Object?> _identity() => {
    'id': _workItemId,
    'iid': '3',
    'project': _projectRef,
    'namespace': _namespaceRef,
  };

  Map<String, Object?> _detail() => {
    ..._summary(),
    'description': null,
    'widgets': <Object?>[],
  };

  Map<String, Object?> _projectWorkItem(Map<String, Object?> node) => {
    'data': {
      'project': {
        ..._projectRef,
        'workItems': {
          'nodes': [node],
          'pageInfo': _page(false),
        },
      },
    },
  };

  Map<String, Object?> _stateNode() => {
    ..._summary(),
    'userPermissions': {'updateWorkItem': true},
  };

  Map<String, Object?> _statusNode({required bool ack}) {
    final status = _statusRecord(statusId);
    final widgets = [
      {'type': 'STATUS', 'status': status},
    ];
    if (ack) {
      return {
        'id': _workItemId,
        'iid': '3',
        'state': workItemState,
        'updatedAt': revision,
        'project': _projectRef,
        'namespace': _namespaceRef,
        'workItemType': {'id': _typeRef['id']},
        'widgets': widgets,
      };
    }
    return {
      ..._summary(),
      'lockVersion': 1,
      'userPermissions': {'readWorkItem': true, 'setWorkItemMetadata': true},
      'workItemType': {
        ..._typeRef,
        'widgetDefinitions': [
          {'type': 'STATUS', 'allowedStatuses': _statusMembers},
        ],
      },
      'widgets': widgets,
    };
  }

  Map<String, Object?> _statusRecord(String id) {
    for (final member in _statusMembers) {
      if (member['id'] == id) return member;
    }
    fail('Unknown synthetic status $id');
  }

  Map<String, Object?> _healthNode({required bool includePermissions}) => {
    ..._summary(),
    if (includePermissions)
      'userPermissions': {'readWorkItem': true, 'adminWorkItem': true},
    'widgets': [
      {
        'type': 'HEALTH_STATUS',
        'healthStatus': healthStatus,
        'rolledUpHealthStatus': [
          {'healthStatus': 'atRisk', 'count': 99},
        ],
      },
    ],
  };

  Map<String, Object?> _datesNode({
    required bool probe,
    required bool permissions,
  }) => {
    ..._summary(),
    'workItemType': {
      ..._typeRef,
      'widgetDefinitions': [
        {'type': 'START_AND_DUE_DATE'},
      ],
    },
    if (permissions)
      'userPermissions': {'readWorkItem': true, 'setWorkItemMetadata': true},
    'widgets': [
      {
        'type': 'START_AND_DUE_DATE',
        'startDate': startDate,
        'dueDate': dueDate,
        'rollUp': false,
        if (probe) ...{
          'isFixed': true,
          'startDateSourcingWorkItem': null,
          'dueDateSourcingWorkItem': null,
          'startDateSourcingMilestone': null,
          'dueDateSourcingMilestone': null,
        },
      },
    ],
  };

  Map<String, Object?> _milestoneNode() {
    Map<String, Object?>? selected;
    for (final node in _milestoneCatalog) {
      if (node['id'] == milestoneId) selected = node;
    }
    return {
      ..._summary(),
      'userPermissions': {
        'readWorkItem': true,
        'adminWorkItem': true,
        'setWorkItemMetadata': true,
      },
      'widgets': [
        {'type': 'MILESTONE', 'milestone': selected},
      ],
    };
  }

  Map<String, Object?> _milestoneChoices() => {
    'data': {
      'currentUser': _actor,
      'project': {
        ..._projectRef,
        'milestones': {'nodes': _milestoneCatalog, 'pageInfo': _page(false)},
      },
    },
  };

  Map<String, Object?> _weightNode() => {
    ..._summary(),
    'userPermissions': {
      'readWorkItem': true,
      'adminWorkItem': true,
      'setWorkItemMetadata': true,
    },
    'widgets': [
      {
        'type': 'WEIGHT',
        'weight': weight,
        'rolledUpWeight': 99,
        'rolledUpCompletedWeight': 17,
      },
    ],
  };

  Map<String, Object?> _assigneesNode() => {
    ..._summary(),
    'userPermissions': {'readWorkItem': true, 'setWorkItemMetadata': true},
    'widgets': [
      {
        'type': 'ASSIGNEES',
        'allowsMultipleAssignees': true,
        'assignees': {
          'nodes': [for (final id in users) _person(id)],
          'pageInfo': _page(false),
        },
      },
    ],
  };

  Map<String, Object?> _candidates(Object? search) => {
    'data': {
      'currentUser': _actor,
      'project': {
        ..._projectRef,
        'autocompleteUsers': [
          for (final entry in _people.entries)
            if (entry.value == search) _person(entry.key),
        ],
      },
    },
  };

  Map<String, Object?> _person(int id) => {
    'id': 'gid://gitlab/User/$id',
    'name': 'Synthetic person $id',
    'username': _people[id],
  };

  Map<String, Object?> _incidentEnvelope() => {
    'data': {
      'project': {
        ..._projectRef,
        'issues': {
          'nodes': [_incidentIssue()],
          'pageInfo': {'hasNextPage': false},
        },
      },
    },
  };

  Map<String, Object?> _incidentIssue() => {
    'id': 'gid://gitlab/Issue/31',
    'iid': '3',
    'projectId': 9,
    'state': 'opened',
    'severity': 'UNKNOWN',
    'escalationStatus': incidentStatus,
    'updatedAt': incidentUpdatedAt,
  };

  Map<String, Object?> _notificationNode() => {
    ..._summary(),
    'widgets': [
      {'type': 'NOTIFICATIONS', 'subscribed': notificationsOn},
    ],
  };

  Map<String, Object?> _activity({required bool firstPage}) => {
    'data': {
      'workItem': {
        ..._identity(),
        'widgets': [
          {
            'type': 'NOTES',
            'discussionLocked': false,
            'discussions': {
              'nodes': firstPage
                  ? <Object?>[]
                  : [
                      _discussion([_existingNote()]),
                    ],
              'pageInfo': _page(firstPage, firstPage ? 'activity-next' : null),
            },
          },
        ],
      },
    },
  };

  Map<String, Object?> _reactionAccess(Object? after) {
    if (after == null) reactionStages.add(0);
    final stage = reactionStages.length - 1;
    reactionStages[stage] = reactionStages[stage] + 1;
    final page = reactionStages[stage];
    final next = page < 2;
    return {
      'data': {
        'currentUser': _actor,
        'workItem': _identity(),
        'note': {
          ..._existingNote(),
          'userPermissions': {'awardEmoji': true, 'adminNote': true},
          'awardEmoji': {
            'nodes': page == 2 && reactionAwarded
                ? [_award(7, 'thumbsup')]
                : <Object?>[],
            'pageInfo': _page(next, next ? 'reaction-$stage-$page' : null),
          },
        },
      },
    };
  }

  Map<String, Object?> _noteAccess({required bool anchor}) => {
    'data': {
      'currentUser': _actor,
      'workItem': {
        ..._identity(),
        'userPermissions': {'createNote': true},
        'widgets': [
          {
            'type': 'NOTES',
            'discussionLocked': false,
            'discussions': {
              'pageInfo': {'hasNextPage': false},
            },
          },
        ],
      },
      if (anchor)
        'anchor': {
          'id': _noteId,
          'noteableType': 'Issue',
          'noteableId': 31,
          'project': _projectRef,
          'discussion': {
            'id': _discussionId,
            'replyId': _replyId,
            'createdAt': '2026-10-01T01:00:00Z',
          },
        },
    },
  };

  Map<String, Object?> _existingNote() => {
    'id': _noteId,
    'system': false,
    'systemNoteIconName': null,
    'body': 'Synthetic note',
    'createdAt': '2026-10-01T01:02:03Z',
    'updatedAt': noteUpdatedAt,
    'author': {
      'id': 'gid://gitlab/User/7',
      'name': 'Synthetic author',
      'username': 'synthetic',
    },
    'internal': false,
    'noteableType': 'Issue',
    'noteableId': 31,
    'project': _projectRef,
    'discussion': {
      'id': _discussionId,
      'replyId': _replyId,
      'createdAt': '2026-10-01T01:00:00Z',
    },
    'userPermissions': {'adminNote': true, 'awardEmoji': true},
  };

  Map<String, Object?> _createdNote(String body) => {
    'id': _createdNoteId,
    'system': false,
    'systemNoteIconName': null,
    'body': body,
    'createdAt': '2026-10-01T01:02:03Z',
    'updatedAt': '2026-10-01T01:03:04Z',
    'author': {
      'id': 'gid://gitlab/User/7',
      'name': 'Synthetic User',
      'username': 'tester',
    },
    'internal': false,
    'noteableType': 'Issue',
    'noteableId': 31,
    'project': _projectRef,
    'discussion': {
      'id': _discussionId,
      'replyId': _replyId,
      'createdAt': '2026-10-01T01:00:00Z',
    },
  };

  Map<String, Object?> _discussion(List<Object?> notes) => {
    'id': _discussionId,
    'replyId': _replyId,
    'createdAt': '2026-10-01T01:00:00Z',
    'notes': {'nodes': notes, 'pageInfo': _page(false)},
  };

  Map<String, Object?> _award(int user, String name) => {
    'name': name,
    'unicode': null,
    'user': {'id': 'gid://gitlab/User/$user'},
  };

  Map<String, Object?> _todoPage({
    required bool snoozed,
    required Object? after,
  }) {
    final offset = after == null ? 0 : int.parse(after as String);
    const total = 400;
    final nodes = <Map<String, Object?>>[
      for (var id = offset + 1; id <= offset + 100 && id <= total; id++)
        _todo(id, snoozed: snoozed),
    ];
    final more = offset + nodes.length < total;
    return {
      'data': {
        'currentUser': {
          'id': 'gid://gitlab/User/7',
          'todos': {
            'nodes': nodes,
            'pageInfo': _page(more, more ? '${offset + nodes.length}' : null),
          },
        },
      },
    };
  }

  Map<String, Object?> _todo(int id, {required bool snoozed}) => {
    'id': 'gid://gitlab/Todo/$id',
    'targetType': 'WORKITEM',
    'snoozedUntil': snoozed ? snoozeUntil : null,
    'project': _projectRef,
    'targetEntity': {
      '__typename': 'WorkItem',
      'id': 'gid://gitlab/WorkItem/91',
      'iid': '3',
      'project': _projectRef,
      'namespace': {'id': 'gid://gitlab/Group/5', 'fullPath': 'team'},
    },
  };

  Map<String, Object?> _page(bool hasNext, [String? cursor]) => {
    'hasNextPage': hasNext,
    'endCursor': cursor,
  };
}

const _milestoneCatalog = <Map<String, Object?>>[
  {
    'id': 'gid://gitlab/Milestone/5',
    'iid': '5',
    'title': 'October',
    'state': 'ACTIVE',
    'expired': false,
    'webPath': '/team/example-9/-/milestones/5',
    'dueDate': '2026-10-31',
    'startDate': '2026-10-01',
    'project': _projectRef,
    'group': null,
  },
  {
    'id': 'gid://gitlab/Milestone/6',
    'iid': '6',
    'title': 'November',
    'state': 'ACTIVE',
    'expired': false,
    'webPath': '/team/example-9/-/milestones/6',
    'dueDate': '2026-11-30',
    'startDate': '2026-11-01',
    'project': _projectRef,
    'group': null,
  },
];

({String name, bool mutation})? _classify(
  RequestOptions request,
  String? query,
  Uri graphQL,
) {
  final path = request.uri.path;
  if (request.method == 'GET' && path.endsWith('/api/v4/user')) {
    return (name: 'user', mutation: false);
  }
  if (request.method == 'GET' && path.endsWith('/api/v4/projects/9')) {
    return (name: 'freshness', mutation: false);
  }
  if (request.method != 'POST' || request.uri != graphQL || query == null) {
    return null;
  }
  final document = RegExp(r'^(query|mutation)\s+(\w+)').firstMatch(query);
  if (document == null) return null;
  return (name: document.group(2)!, mutation: document.group(1) == 'mutation');
}

String? _query(RequestOptions request) {
  final data = request.data;
  if (data is! Map) return null;
  final query = data['query'];
  if (query is String) return query;
  return null;
}

Map<String, Object?> _variables(RequestOptions request) {
  final data = request.data;
  if (data is! Map) return const {};
  final variables = data['variables'];
  if (variables is! Map) return const {};
  return Map<String, Object?>.from(variables);
}

Map<String, Object?> _input(Map<String, Object?> variables) {
  final input = variables['input'];
  if (input is! Map) fail('Synthetic mutation is missing input');
  return Map<String, Object?>.from(input);
}

Map<String, Object?> _widget(Map<String, Object?> input, String key) {
  final widget = input[key];
  if (widget is! Map) fail('Synthetic mutation is missing $key');
  return Map<String, Object?>.from(widget);
}

List<int> _assigneeIds(Map<String, Object?> widget) {
  final raw = widget['assigneeIds'];
  if (raw is! List) fail('Synthetic assignees are missing ids');
  return [for (final id in raw) int.parse((id as String).split('/').last)];
}

/// Worst-case arguments taken from the family port drives.
Map<String, Object?> mr6b3ApiArguments(
  String operation, {
  String? snoozeUntil,
}) => switch (operation) {
  'createWorkItemActivityComment' => {
    'projectId': 9,
    'iid': 3,
    'body': mr6b3ActivityBody,
  },
  'createWorkItemActivityReply' => {
    'projectId': 9,
    'iid': 3,
    'anchorNoteId': 401,
    'body': mr6b3ActivityBody,
  },
  'deleteWorkItemActivityNote' => {'projectId': 9, 'iid': 3, 'noteId': 401},
  'updateWorkItemDates' => {
    'projectId': 9,
    'iid': 3,
    'mode': 'manual',
    'startDate': '2026-10-06',
  },
  'updateWorkItemAssignees' => {
    'projectId': 9,
    'iid': 3,
    'assigneeUsernames': ['current', 'alice', 'bob', 'carol', 'dave'],
  },
  'updateWorkItemHealthStatus' => {
    'projectId': 9,
    'iid': 3,
    'healthStatus': 'atRisk',
  },
  'setWorkItemNotifications' => {'projectId': 9, 'iid': 3, 'enabled': true},
  'setIncidentStatus' => {'projectId': 9, 'iid': 3, 'status': 'ACKNOWLEDGED'},
  'updateWorkItemMilestone' => {
    'projectId': 9,
    'iid': 3,
    'milestoneTitle': 'November',
  },
  'setWorkItemActivityNoteReaction' => {
    'projectId': 9,
    'iid': 3,
    'noteId': 401,
    'name': 'thumbsup',
    'add': true,
  },
  'updateWorkItemStatus' => {
    'projectId': 9,
    'iid': 3,
    'candidateId': mr6b3StatusDoing,
  },
  'snoozeTodo' => {'todoId': 400, 'until': snoozeUntil ?? mr6b3SnoozeUntil},
  'unsnoozeTodo' => {'todoId': 400},
  'updateWorkItemState' => {'projectId': 9, 'iid': 3, 'stateEvent': 'close'},
  'updateWorkItemWeight' => {'projectId': 9, 'iid': 3, 'weight': 4},
  _ => throw ArgumentError.value(operation, 'operation'),
};

final class Mr6b3ApiHarness {
  Mr6b3ApiHarness._({
    required this.root,
    required this.server,
    required this.files,
    required this.keys,
    required this.policy,
    required this.journal,
    required this.coordinator,
    required this.budget,
  });

  static Future<Mr6b3ApiHarness> create({
    bool oauth = true,
    int maxGitLabRequests = 40,
    bool challengeEveryRead = false,
    DateTime? now,
    port.AiGitLabWritePort Function(port.GitLabAiWritePort)? portFactory,
  }) async {
    final harnessNow = now ?? DateTime.now();
    final snoozeUntil = _futureSnoozeUntil(harnessNow);
    final root = Directory.systemTemp.createTempSync('mr6b3-p15-');
    final files = Mr6b3JournalFiles(root);
    final keys = Mr6b3JournalKeyStore();
    final journal = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      files: files,
      processId: 'mr6b3-p15',
    );
    await journal.recoverAfterAccountsLoaded([mr6b3Account]);
    await journal.ensureInitialized(mr6b3Account);
    final server = Mr6b3ApiServer(
      oauth: oauth,
      challengeEveryRead: challengeEveryRead,
      snoozeUntil: snoozeUntil,
    );
    final policy = Mr6b3Policy();
    final budget = AiToolBudget(maxGitLabRequests: maxGitLabRequests);
    late final Mr6b3ApiHarness harness;
    final coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: mr6b3Scope,
        level: policy.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'mr6b3-consent',
        writePolicyRevision: policy.revision,
        scopeRevision: 1,
        sessionGeneration: harness.sessionGeneration,
        appInForeground: harness.appInForeground,
        alive: policy.alive,
        consentValid: policy.consentValid,
        clientMayStart: policy.clientMayStart && server.api.mayStartRequest,
      ),
      createPort: () => portFactory?.call(server.writePort) ?? server.writePort,
      journal: journal,
      conversationId: 'mr6b3-p15-budget',
      budget: () => budget,
      readFreshness: (request) async {
        final row = productionAiLedger.find(request.operationId);
        if (row?.scopeClass == AiScopeClass.accountTodo) {
          return const AiWriteFreshness(
            updatedAt: mr6b3Revision,
            visibilityUnreadable: false,
          );
        }
        final project = await server.api.record(['projects', '9']);
        return AiWriteFreshness(
          updatedAt: mr6b3Revision,
          visibilityUnreadable: project['visibility'] != 'private',
        );
      },
      placeholders: text.UploadPlaceholderTable(instance: server.api.instance),
      knownSecrets: () => const <String>{},
      safeDisplay: (value) => value,
      ledger: productionAiLedger,
      checkFragments:
          (
            scan, {
            required knownSecrets,
            required instance,
            required visibility,
          }) {
            final result = exact.checkFragments(
              scan,
              knownSecrets: knownSecrets,
              instance: instance,
              visibility: visibility,
            );
            return (
              blockCode: result.blockCode,
              confirmReasons: result.confirmReasons,
            );
          },
      now: () => harnessNow,
      httpCost: oauth
          ? null
          : (String op) => aiWriteRequestAllowance(op, oauthReplay: false),
    );
    harness = Mr6b3ApiHarness._(
      root: root,
      server: server,
      files: files,
      keys: keys,
      policy: policy,
      journal: journal,
      coordinator: coordinator,
      budget: budget,
    );
    coordinator.beginRun('Update work item 3 in team/example-9.');
    coordinator.beginTurn();
    return harness;
  }

  final Directory root;
  final Mr6b3ApiServer server;
  final Mr6b3JournalFiles files;
  final Mr6b3JournalKeyStore keys;
  final Mr6b3Policy policy;
  final AiWriteJournal journal;
  final PolicyAiWriteCoordinator coordinator;
  final AiToolBudget budget;
  String get snoozeUntil => server.snoozeUntil;
  int sessionGeneration = 7;
  bool appInForeground = true;
  int _callId = 0;

  Future<AiWriteProposal?> propose(
    String operation, {
    String? id,
    Map<String, Object?> arguments = const {},
  }) => coordinator
      .propose(
        AiToolCall(
          id: id ?? 'p15-${_callId++}',
          name: operation,
          arguments: {
            ...mr6b3ApiArguments(operation, snoozeUntil: snoozeUntil),
            ...arguments,
            'reason': 'synthetic packet 15 request',
          },
        ),
      )
      .timeout(mr6b3Timeout);

  Future<AiWriteOutcome> approve(AiWriteProposal proposal) => coordinator
      .approve(proposal, typedName: proposal.tier.typedName)
      .timeout(mr6b3Timeout);

  Future<void> seedConfirmMark() async {
    const execution = 'mr6b3-p15-seed';
    await journal.prepare(
      draft: AiJournalDraft(
        executionId: execution,
        accountKey: mr6b3Account,
        conversationId: 'mr6b3-p15-seed',
        runId: 'mr6b3-p15-seed',
        operationId: 'updateWorkItemState',
        writeKeys: {mr6b3WriteKey},
        payloadSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        releaseName: '#3',
      ),
    );
    await journal.markDispatching(executionId: execution);
    await journal.finish(
      executionId: execution,
      terminal: AiJournalState.writeUncertain,
    );
    await journal.releaseByUser(executionId: execution, typedName: '#3');
  }

  Future<Map<String, Object?>> readDurableJournal() =>
      AiHistoryCipher.decryptJson(
        File(files.pathFor(mr6b3Account)).readAsBytesSync(),
        keys.keys[mr6b3Account]!,
        mr6b3Account,
        AiJournalFiles.fileName,
      );

  Future<AiWriteJournal> recoverInNewProcess() async {
    final recovered = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      files: files,
      processId: 'mr6b3-p15-restarted',
    );
    await recovered.recoverAfterAccountsLoaded([mr6b3Account]);
    return recovered;
  }

  Future<void> dispose() async {
    try {
      server.verifyRequests();
    } finally {
      files.releaseBarrier();
      coordinator.stop('disposed');
      server.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
  }
}
