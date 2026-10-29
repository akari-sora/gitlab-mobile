import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart'
    show AiWriteFreshness;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';

import '../../tool/mr7/sandbox_contract.dart';
import '../../tool/mr7_sandbox.dart' as sandbox;

const _gid = 'gid://gitlab/WorkItem/300';
const _path = 'projects/909/issues/3';
const _owner = 'gid://gitlab/User/7';
const _labelA = 'gid://gitlab/ProjectLabel/701';
const _labelB = 'gid://gitlab/ProjectLabel/702';
const _milestone = 'gid://gitlab/Milestone/501';
const _statusA = 'gid://gitlab/WorkItems::Status/40';
const _statusB = 'gid://gitlab/WorkItems::Status/41';
const _snapshotFields = <String>{
  'title',
  'state',
  'description',
  'status',
  'startDate',
  'dueDate',
  'rollUp',
  'isFixed',
  'startDateSourcingWorkItem',
  'dueDateSourcingWorkItem',
  'startDateSourcingMilestone',
  'dueDateSourcingMilestone',
  'assignees',
  'milestone',
  'labels',
  'subscribed',
};

Map<String, Object?> _label(String id, String title) => {
  'id': id,
  'title': title,
  'color': '#ffffff',
  'textColor': '#000000',
};
Map<String, Object?> _user(String id, String username) => {
  'id': id,
  'name': username,
  'username': username,
};

class Mr7CaptureAdapter implements HttpClientAdapter {
  Mr7CaptureAdapter(Mr7WorkItemFixture fixture) : respond = fixture.graph;
  Mr7CaptureAdapter.activity(Mr7ActivityFixture fixture)
    : respond = fixture.graph;
  final ResponseBody Function(RequestOptions) respond;
  final requests = <Map<String, Object?>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(Map<String, Object?>.from(options.data as Map));
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

class Mr7WorkItemFixture {
  Mr7WorkItemFixture._(this.server, this.session);
  static Mr7WorkItemFixture create() {
    final server = Mr7SyntheticGitLab();
    return Mr7WorkItemFixture._(
      server,
      Mr7SandboxSession(
        server: server,
        nonce: 'wave3bfixture',
        requestCap: 1000,
        eventDelay: () async {},
      ),
    );
  }

  final Mr7SyntheticGitLab server;
  final Mr7SandboxSession session;
  String title = 'Original title';
  String state = 'OPEN';
  String? description = 'Original description';
  bool descriptionPresent = true;
  String status = _statusA;
  String? startDate = '2026-11-01';
  String? dueDate = '2026-11-02';
  bool isFixed = true;
  bool rollUp = false;
  List<Map<String, Object?>> assignees = [];
  List<Map<String, Object?>> labels = [];
  Map<String, Object?>? milestone;
  bool subscribed = false;
  String escalation = 'TRIGGERED';
  bool afterWrite = false;
  bool oversizedGraphReadback = false;
  bool paginateAssignees = false;
  bool paginateLabels = false;
  bool badActor = false;
  bool badProject = false;
  bool badIid = false;
  bool badIncidentIid = false;
  bool ceDates = false;
  bool invalidDateSchemaError = false;
  bool partialDateSchemaError = false;
  int incidentPrepareRestReads = -1;
  bool missingWidget = false;
  bool nullConnection = false;
  int writeCount = 0;
  int assigneePages = 0;
  int labelPages = 0;
  void Function()? onWrite;

  Map<String, Object?> get milestoneValue => {
    'id': _milestone,
    'iid': '21',
    'title': 'Synthetic milestone',
    'state': 'active',
    'expired': false,
    'dueDate': null,
    'startDate': null,
    'webPath': '/synthetic/milestones/21',
    'project': {
      'id': 'gid://gitlab/Project/909',
      'fullPath': session.identity!.path,
    },
  };

  Future<void> initialize() async {
    await session.initialize();
    await installRoutesAndBindings();
  }

  Future<void> installRoutesAndBindings() async {
    server.routes['GET $_path'] = (_) => mr7Json({
      'id': 300,
      'iid': 3,
      'project_id': 909,
      'confidential': false,
      'state': 'opened',
      'title': 'Original title',
    });
    server.routes['GET projects/909/issues/4'] = (_) => mr7Json({
      'id': 400,
      'iid': 4,
      'project_id': 909,
      'state': 'opened',
      'title': 'Other issue',
    });
    server.routes['GET projects/909/labels/701'] = (_) => mr7Json({
      'id': 701,
      'project_id': 909,
      'name': 'Synthetic A',
      'is_project_label': true,
    });
    server.routes['GET projects/909/labels/702'] = (_) => mr7Json({
      'id': 702,
      'project_id': 909,
      'name': 'Synthetic B',
      'is_project_label': true,
    });
    server.routes['GET projects/909/milestones/501'] = (_) => mr7Json({
      'id': 501,
      'iid': 21,
      'project_id': 909,
      'title': 'Synthetic milestone',
    });
    await session.bindWorkItemGraphResource(_gid, path: _path);
    await session.bindWorkItemGraphResource(
      'gid://gitlab/WorkItem/400',
      path: 'projects/909/issues/4',
    );
    await session.bindGraphResource(_labelA, path: 'projects/909/labels/701');
    await session.bindGraphResource(_labelB, path: 'projects/909/labels/702');
    await session.bindGraphResource(
      _milestone,
      path: 'projects/909/milestones/501',
    );
    server.routes['POST /install/api/graphql'] = graph;
  }

  bool _selected(String doc, String field) =>
      RegExp('\\b${RegExp.escape(field)}\\b').hasMatch(doc);

  Map<String, Object?> _connection(
    List<Map<String, Object?>> values,
    Object? cursor,
    bool paged,
  ) {
    if (!paged || values.length <= 1) {
      return {
        'nodes': values,
        'pageInfo': {'hasNextPage': false, 'endCursor': null},
      };
    }
    if (cursor == null) {
      return {
        'nodes': values.take(1).toList(),
        'pageInfo': {'hasNextPage': true, 'endCursor': 'cursor-1'},
      };
    }
    if (cursor == 'cursor-1') {
      return {
        'nodes': values.skip(1).toList(),
        'pageInfo': {'hasNextPage': false, 'endCursor': null},
      };
    }
    throw StateError('Unexpected cursor: $cursor');
  }

  ResponseBody graph(RequestOptions request) {
    final body = request.data as Map;
    final doc = body['query'] as String;
    final vars = body['variables'] as Map;
    if (doc.contains('query MobileProjectWorkItem(')) {
      final project = {
        'id': 'gid://gitlab/Project/909',
        'fullPath': session.identity!.path,
      };
      return mr7Json({
        'data': {
          'project': {
            ...project,
            'workItems': {
              'nodes': [
                {
                  'id': _gid,
                  'iid': '3',
                  'title': title,
                  'state': state,
                  'createdAt': '2026-09-01T01:02:03Z',
                  'updatedAt': '2026-10-29T00:00:00Z',
                  'webUrl':
                      'https://gitlab.invalid/install/${session.identity!.path}/-/work_items/3',
                  'project': project,
                  'namespace': {
                    'id': 'gid://gitlab/Namespaces::ProjectNamespace/909',
                    'fullPath': session.identity!.path,
                  },
                  'workItemType': {
                    'id': 'gid://gitlab/WorkItems::Type/99',
                    'name': 'Issue',
                  },
                  'description': description,
                  'widgets': <Object?>[],
                },
              ],
              'pageInfo': {'hasNextPage': false, 'endCursor': null},
            },
          },
        },
      });
    }
    if (doc.contains('query MobileWorkItemState(')) {
      return mr7Json({
        'data': {
          'workItem': {
            'id': _gid,
            'iid': '3',
            'state': state,
            'updatedAt': '2026-10-29T00:00:00Z',
            'project': {
              'id': 'gid://gitlab/Project/909',
              'fullPath': session.identity!.path,
            },
            'namespace': {
              'id': 'gid://gitlab/Namespaces::ProjectNamespace/909',
              'fullPath': session.identity!.path,
            },
            'workItemType': {'id': 'gid://gitlab/WorkItems::Type/99'},
            'userPermissions': {'updateWorkItem': true},
          },
        },
      });
    }
    if (doc.startsWith('mutation ')) {
      writeCount++;
      server.scenarioWrites++;
      server.addEvent(target: 909);
      afterWrite = true;
      onWrite?.call();
      final root = doc.contains('issueSetEscalationStatus')
          ? 'issueSetEscalationStatus'
          : doc.contains('workItemSubscribe')
          ? 'workItemSubscribe'
          : 'workItemUpdate';
      return mr7Json({
        'data': {
          root: {
            'errors': <Object?>[],
            if (root == 'issueSetEscalationStatus')
              'issue': {'id': 'gid://gitlab/Issue/300'}
            else
              'workItem': {'id': _gid},
          },
        },
      });
    }
    final current = {
      'id': badActor && afterWrite ? 'gid://gitlab/User/8' : _owner,
    };
    if (doc.contains('query Mr7Incident') ||
        doc.contains('query MobileIncidentStatus')) {
      return mr7Json({
        'data': {
          if (doc.contains('query Mr7Incident')) 'currentUser': current,
          'project': {
            'id': 'gid://gitlab/Project/909',
            'issues': {
              'nodes': [
                {
                  'id': 'gid://gitlab/Issue/300',
                  'iid': badIncidentIid && afterWrite ? '4' : '3',
                  'projectId': 909,
                  'state': 'opened',
                  'severity': null,
                  'escalationStatus': escalation,
                  'updatedAt': '2026-10-29T00:00:00Z',
                },
              ],
              'pageInfo': {'hasNextPage': false},
            },
          },
        },
      });
    }
    final type = RegExp(r'onlyTypes: \[([A-Z_]+)\]').firstMatch(doc)?.group(1);
    if (type == 'START_AND_DUE_DATE' && _selected(doc, 'isFixed') && ceDates) {
      return mr7Json({
        if (partialDateSchemaError)
          'data': {
            'currentUser': {'id': _owner},
          },
        'errors': [
          {
            'message':
                'Field isFixed does not exist on WorkItemWidgetStartAndDueDate',
            'extensions': {
              'code': invalidDateSchemaError ? 'FORBIDDEN' : 'undefinedField',
              'typeName': 'WorkItemWidgetStartAndDueDate',
              'fieldName': 'isFixed',
            },
          },
        ],
      });
    }

    final widgets = <Map<String, Object?>>[];
    if (type != null &&
        !(missingWidget && afterWrite) &&
        (type != 'DESCRIPTION' || descriptionPresent)) {
      final widget = <String, Object?>{'type': type};
      switch (type) {
        case 'DESCRIPTION':
          widget['description'] = description;
          if (_selected(doc, 'edited')) widget['edited'] = false;
        case 'STATUS':
          widget['status'] = {'id': status};
        case 'START_AND_DUE_DATE':
          if (_selected(doc, 'startDate')) widget['startDate'] = startDate;
          if (_selected(doc, 'dueDate')) widget['dueDate'] = dueDate;
          if (_selected(doc, 'rollUp')) widget['rollUp'] = rollUp;
          if (_selected(doc, 'isFixed')) widget['isFixed'] = isFixed;
          for (final field in [
            'startDateSourcingWorkItem',
            'dueDateSourcingWorkItem',
            'startDateSourcingMilestone',
            'dueDateSourcingMilestone',
          ]) {
            if (_selected(doc, field)) widget[field] = null;
          }
        case 'ASSIGNEES':
          assigneePages++;
          widget['assignees'] = nullConnection && afterWrite
              ? null
              : _connection(
                  assignees,
                  vars['after'],
                  paginateAssignees && afterWrite,
                );
        case 'MILESTONE':
          widget['milestone'] = milestone;
        case 'LABELS':
          labelPages++;
          widget['labels'] = nullConnection && afterWrite
              ? null
              : _connection(
                  labels,
                  vars['after'],
                  paginateLabels && afterWrite,
                );
        case 'NOTIFICATIONS':
          widget['subscribed'] = subscribed;
        default:
          throw StateError('Unexpected widget $type');
      }
      widgets.add(widget);
    }
    return mr7Json({
      if (oversizedGraphReadback && afterWrite)
        'untracked_large_field': 'x' * (2 * 1024 * 1024 + 1),
      'data': {
        'currentUser': current,
        'workItem': {
          'id': vars['id'],
          'iid': badIid && afterWrite ? '4' : '3',
          'title': title,
          'state': state,
          'updatedAt': '2026-10-29T00:00:00Z',
          if (doc.contains('query MobileWorkItemContent(')) ...{
            'createdAt': '2026-09-01T01:02:03Z',
            'namespace': {
              'id': 'gid://gitlab/Namespaces::ProjectNamespace/909',
              'fullPath': session.identity!.path,
            },
            'workItemType': {
              'id': 'gid://gitlab/WorkItems::Type/99',
              'name': 'Issue',
            },
            'userPermissions': {'updateWorkItem': true},
          },
          'project': {
            'id': badProject && afterWrite
                ? 'gid://gitlab/Project/777'
                : 'gid://gitlab/Project/909',
            'fullPath': session.identity!.path,
          },
          if (type != null) 'widgets': widgets,
        },
      },
    });
  }

  Future<bool> effect({
    required String operation,
    required Map<String, Object?> args,
    required Map<String, Object?> input,
    required void Function() mutate,
    Map<String, Object?>? capturedRequest,
    bool eeDates = false,
    Set<String> fields = _snapshotFields,
    String? sentGid,
    Set<String> readbackPaths = const {_path},
  }) async {
    if (operation == 'updateWorkItemDates') ceDates = !eeDates;
    final saved = await session.captureSnapshot([
      Mr7SnapshotSpec.workItem(path: _path, workItemId: _gid, fields: fields),
    ]);
    final root = operation == 'setIncidentStatus'
        ? 'issueSetEscalationStatus'
        : operation == 'setWorkItemNotifications'
        ? 'workItemSubscribe'
        : 'workItemUpdate';
    final type = operation == 'setIncidentStatus'
        ? 'IssueSetEscalationStatusInput!'
        : operation == 'setWorkItemNotifications'
        ? 'WorkItemSubscribeInput!'
        : 'WorkItemUpdateInput!';
    final resultField = root == 'issueSetEscalationStatus'
        ? 'issue'
        : 'workItem';
    final doc =
        capturedRequest?['query'] as String? ??
        'mutation Widget(\$input: $type) { $root(input: \$input) { errors $resultField { id } } }';
    final vars =
        capturedRequest?['variables'] as Map<String, Object?>? ??
        {
          'input': {
            if (operation != 'setIncidentStatus') 'id': sentGid ?? _gid,
            ...input,
          },
        };
    final permit =
        Mr7MutationPermit(
            operation: operation,
            paths: {'POST graphql'},
            resourceProjectId: 909,
            graphDocuments: {doc},
            graphVariablesDigests: {mr7Digest(vars)},
            resultPath: ['data', root, resultField],
          )
          ..confirmed = true
          ..snapshot = saved;
    session.permit = permit;
    onWrite = mutate;
    await session.writer.post<Object?>(
      '${session.instance}/api/graphql',
      data: {'query': doc, 'variables': vars},
    );
    final observer = Mr7Readback(
      session,
      session.identity!,
      permit,
      paths: readbackPaths,
    );
    return observer.observe(
      Mr7WorkItemObservation(
        workItemId: _gid,
        iid: 3,
        operation: operation,
        arguments: {'projectId': 909, 'iid': 3, ...args},
      ),
    );
  }

  Future<bool> noop({
    required String operation,
    required Map<String, Object?> args,
    Map<String, Object?>? callArgs,
    bool prepare = true,
    String? milestoneState,
    bool? milestoneExpired,
  }) async {
    final permit = Mr7MutationPermit(
      operation: operation,
      paths: {'POST graphql'},
      resourceProjectId: 909,
    )..confirmed = true;
    session.permit = permit;
    if (prepare && operation == 'setIncidentStatus') {
      const document = r'''
query MobileIncidentStatus($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    id
    issues(iids: [$iid], types: [INCIDENT], first: 2) {
      nodes { id iid projectId state severity escalationStatus updatedAt }
      pageInfo { hasNextPage }
    }
  }
}
''';
      final vars = <String, Object?>{
        'path': session.identity!.path,
        'iid': '3',
      };
      session.observerAdapter.graphReadDocuments = {
        document: {mr7Digest(vars)},
      };
      final reads = server.requests.where((r) => r == 'GET $_path').length;
      await session.writer.post<Object?>(
        '${session.instance}/api/graphql',
        data: {'query': document, 'variables': vars},
      );
      incidentPrepareRestReads =
          server.requests.where((r) => r == 'GET $_path').length - reads;
    } else if (prepare) {
      await session.writer.get<Object?>(_path);
    }
    final observer = Mr7Readback(
      session,
      session.identity!,
      permit,
      paths: {_path},
    );
    final arguments = <String, Object?>{'projectId': 909, 'iid': 3, ...args};
    permit.capturePreparedArguments(() => arguments);
    return observer.observeNoChange(
      Mr7WorkItemObservation(
        workItemId: _gid,
        iid: 3,
        operation: operation,
        arguments: arguments,
        milestoneState: milestoneState,
        milestoneExpired: milestoneExpired,
      ),
      arguments: callArgs ?? arguments,
    );
  }
}

Future<T> _fixture<T>(Future<T> Function(Mr7WorkItemFixture f) body) async {
  final fixture = Mr7WorkItemFixture.create();
  await fixture.initialize();
  try {
    return await body(fixture);
  } finally {
    await fixture.session.finish();
  }
}

void main() {
  test(
    'state observer proves close and reopen independently of status',
    () async {
      for (final close in [true, false]) {
        expect(
          await _fixture((f) async {
            f.state = close ? 'OPEN' : 'CLOSED';
            return f.effect(
              operation: 'updateWorkItemState',
              args: {'stateEvent': close ? 'close' : 'reopen'},
              input: {'stateEvent': close ? 'CLOSE' : 'REOPEN'},
              mutate: () => f.state = close ? 'CLOSED' : 'OPEN',
            );
          }),
          isTrue,
        );
      }
    },
  );

  test(
    'status observer checks selected custom status independently of lifecycle',
    () async {
      expect(
        await _fixture(
          (f) => f.effect(
            operation: 'updateWorkItemStatus',
            args: {'candidateId': _statusB},
            input: {
              'statusWidget': {'status': _statusB},
            },
            mutate: () => f.status = _statusB,
          ),
        ),
        isTrue,
      );
    },
  );

  test(
    'dates observer proves CE and EE manual, clears and inherited',
    () async {
      final cases =
          <
            ({
              Map<String, Object?> args,
              Map<String, Object?> widget,
              String? start,
              String? due,
              bool ee,
              bool inherited,
            })
          >[
            (
              args: {
                'mode': 'manual',
                'startDate': '2026-12-01',
                'dueDate': '2026-12-02',
              },
              widget: {'startDate': '2026-12-01', 'dueDate': '2026-12-02'},
              start: '2026-12-01',
              due: '2026-12-02',
              ee: false,
              inherited: false,
            ),
            (
              args: {
                'mode': 'manual',
                'startDate': '2026-12-01',
                'dueDate': '2026-12-02',
              },
              widget: {
                'isFixed': true,
                'startDate': '2026-12-01',
                'dueDate': '2026-12-02',
              },
              start: '2026-12-01',
              due: '2026-12-02',
              ee: true,
              inherited: false,
            ),
            (
              args: {'mode': 'manual', 'clearStart': true},
              widget: {'startDate': null, 'dueDate': '2026-11-02'},
              start: null,
              due: '2026-11-02',
              ee: false,
              inherited: false,
            ),
            (
              args: {'mode': 'manual', 'clearDue': true},
              widget: {'startDate': '2026-11-01', 'dueDate': null},
              start: '2026-11-01',
              due: null,
              ee: false,
              inherited: false,
            ),
            (
              args: {'mode': 'manual', 'clearStart': true, 'clearDue': true},
              widget: {'startDate': null, 'dueDate': null},
              start: null,
              due: null,
              ee: false,
              inherited: false,
            ),
            (
              args: {'mode': 'inherited'},
              widget: {'isFixed': false},
              start: '2026-11-01',
              due: '2026-11-02',
              ee: true,
              inherited: true,
            ),
          ];
      for (final c in cases) {
        expect(
          await _fixture(
            (f) => f.effect(
              operation: 'updateWorkItemDates',
              args: c.args,
              input: {'startAndDueDateWidget': c.widget},
              eeDates: c.ee,
              mutate: () {
                f.startDate = c.start;
                f.dueDate = c.due;
                f.isFixed = !c.inherited;
              },
            ),
          ),
          isTrue,
          reason: jsonEncode(c.args),
        );
      }
    },
  );

  test(
    'assignee observer verifies replacement and clear as complete sets',
    () async {
      for (final clear in [false, true]) {
        expect(
          await _fixture((f) async {
            if (clear) f.assignees = [_user(_owner, 'synthetic-owner')];
            return f.effect(
              operation: 'updateWorkItemAssignees',
              args: {
                'assigneeUsernames': clear ? <String>[] : ['synthetic-owner'],
              },
              input: {
                'assigneesWidget': {
                  'assigneeIds': clear ? <String>[] : [_owner],
                },
              },
              mutate: () =>
                  f.assignees = clear ? [] : [_user(_owner, 'synthetic-owner')],
            );
          }),
          isTrue,
        );
      }
    },
  );

  test('assignee observer rejects a partial set', () async {
    await _fixture((f) async {
      f.paginateAssignees = true;
      final result = await f.effect(
        operation: 'updateWorkItemAssignees',
        args: {
          'assigneeUsernames': ['synthetic-owner'],
        },
        input: {
          'assigneesWidget': {
            'assigneeIds': [_owner],
          },
        },
        mutate: () => f.assignees = [
          _user(_owner, 'synthetic-owner'),
          _user('gid://gitlab/User/8', 'other'),
        ],
      );
      expect(result, isFalse);
      expect(f.assigneePages, greaterThanOrEqualTo(3));
    });
  });

  test(
    'milestone observer proves set and clear with project ownership',
    () async {
      for (final clear in [false, true]) {
        expect(
          await _fixture((f) async {
            if (clear) f.milestone = f.milestoneValue;
            return f.effect(
              operation: 'updateWorkItemMilestone',
              args: clear
                  ? {'clearMilestone': true}
                  : {'milestoneTitle': 'Synthetic milestone'},
              input: {
                'milestoneWidget': {'milestoneId': clear ? null : _milestone},
              },
              mutate: () => f.milestone = clear ? null : f.milestoneValue,
            );
          }),
          isTrue,
        );
      }
    },
  );

  test(
    'content observer preserves omitted widget and exact Markdown bytes',
    () async {
      for (final variant in [
        'title',
        'description',
        'both',
        'title-without-widget',
      ]) {
        expect(
          await _fixture((f) async {
            if (variant == 'title-without-widget') f.descriptionPresent = false;
            final title = variant != 'description';
            final description = variant == 'description' || variant == 'both';
            return f.effect(
              operation: 'updateWorkItemContent',
              args: {
                if (title) 'title': 'Revised',
                if (description) 'description': '  **body**\n\n',
              },
              input: {
                if (title) 'title': 'Revised',
                if (description)
                  'descriptionWidget': {'description': '  **body**\n\n'},
              },
              mutate: () {
                if (title) f.title = 'Revised';
                if (description) f.description = '  **body**\n\n';
              },
            );
          }),
          isTrue,
          reason: variant,
        );
      }
    },
  );

  test('content snapshot rejects drift in an omitted description', () async {
    expect(
      await _fixture(
        (f) => f.effect(
          operation: 'updateWorkItemContent',
          args: {'title': 'Revised'},
          input: {'title': 'Revised'},
          mutate: () {
            f.title = 'Revised';
            f.description = 'wrong';
          },
        ),
      ),
      isFalse,
    );
  });

  test('label observer proves complete add remove replace and clear', () async {
    for (final variant in ['add', 'remove', 'replace', 'clear']) {
      expect(
        await _fixture((f) async {
          if (variant != 'add') f.labels = [_label(_labelA, 'Synthetic A')];
          final names = variant == 'clear'
              ? <String>[]
              : variant == 'replace'
              ? ['Synthetic B']
              : ['Synthetic A'];
          if (variant == 'remove') {
            f.labels = [
              _label(_labelA, 'Synthetic A'),
              _label(_labelB, 'Synthetic B'),
            ];
          }
          final adds = variant == 'add'
              ? [_labelA]
              : variant == 'replace'
              ? [_labelB]
              : <String>[];
          final removes = variant == 'replace' || variant == 'clear'
              ? [_labelA]
              : variant == 'remove'
              ? [_labelB]
              : <String>[];
          return f.effect(
            operation: 'updateWorkItemLabels',
            args: {'labels': names},
            input: {
              'labelsWidget': {'addLabelIds': adds, 'removeLabelIds': removes},
            },
            mutate: () => f.labels = [
              for (final name in names)
                _label(name == 'Synthetic A' ? _labelA : _labelB, name),
            ],
          );
        }),
        isTrue,
        reason: variant,
      );
    }
  });

  test('label observer rejects unobserved later pages', () async {
    await _fixture((f) async {
      f.paginateLabels = true;
      final result = await f.effect(
        operation: 'updateWorkItemLabels',
        args: {
          'labels': ['Synthetic A'],
        },
        input: {
          'labelsWidget': {
            'addLabelIds': [_labelA],
            'removeLabelIds': <String>[],
          },
        },
        mutate: () => f.labels = [
          _label(_labelA, 'Synthetic A'),
          _label(_labelB, 'Synthetic B'),
        ],
      );
      expect(result, isFalse);
      expect(f.labelPages, greaterThanOrEqualTo(3));
    });
  });

  test(
    'notification observer requires the subscribed widget and actor',
    () async {
      for (final enabled in [false, true]) {
        expect(
          await _fixture((f) async {
            f.subscribed = !enabled;
            return f.effect(
              operation: 'setWorkItemNotifications',
              args: {'enabled': enabled},
              input: {'subscribed': enabled},
              mutate: () => f.subscribed = enabled,
            );
          }),
          isTrue,
        );
      }
      expect(
        await _fixture((f) async {
          f.missingWidget = true;
          return f.effect(
            operation: 'setWorkItemNotifications',
            args: {'enabled': true},
            input: {'subscribed': true},
            mutate: () => f.subscribed = true,
          );
        }),
        isFalse,
      );
    },
  );

  test('incident observer checks all escalation statuses', () async {
    for (final status in ['TRIGGERED', 'ACKNOWLEDGED', 'RESOLVED']) {
      expect(
        await _fixture(
          (f) => f.effect(
            operation: 'setIncidentStatus',
            args: {'status': status},
            input: {
              'projectPath': f.session.identity!.path,
              'iid': '3',
              'status': status,
            },
            mutate: () => f.escalation = status,
          ),
        ),
        isTrue,
        reason: status,
      );
    }
  });

  test('incident observer rejects another iid', () async {
    expect(
      await _fixture((f) async {
        f.badIncidentIid = true;
        return f.effect(
          operation: 'setIncidentStatus',
          args: {'status': 'RESOLVED'},
          input: {
            'projectPath': f.session.identity!.path,
            'iid': '3',
            'status': 'RESOLVED',
          },
          mutate: () => f.escalation = 'RESOLVED',
        );
      }),
      isFalse,
    );
    await _fixture((f) async {
      await expectLater(
        f.effect(
          operation: 'setIncidentStatus',
          args: {'status': 'RESOLVED'},
          input: {
            'projectPath': f.session.identity!.path,
            'iid': '4',
            'status': 'RESOLVED',
          },
          mutate: () => f.escalation = 'RESOLVED',
        ),
        throwsA(anything),
      );
      expect(f.writeCount, 0);
    });
  });

  test(
    'foreign actor, project and input selector cannot prove effect',
    () async {
      for (final bad in ['actor', 'project', 'selector']) {
        await _fixture((f) async {
          f.badActor = bad == 'actor';
          f.badProject = bad == 'project';
          await expectLater(
            f.effect(
              operation: 'updateWorkItemState',
              args: {'stateEvent': 'close'},
              input: {'stateEvent': 'CLOSE'},
              sentGid: bad == 'selector' ? 'gid://gitlab/WorkItem/400' : null,
              mutate: () => f.state = 'CLOSED',
            ),
            throwsA(anything),
          );
          if (bad == 'selector') expect(f.writeCount, 0);
        });
      }
    },
  );

  test('no-op refuses a changed issue or merge request selector', () async {
    for (final originalResource in ['issues', 'merge_requests']) {
      await _fixture((f) async {
        final arguments = <String, Object?>{
          'projectId': 909,
          'resource': originalResource,
          'iid': 3,
          'subscribed': true,
        };
        final prepared = {
          ...arguments,
          'resource': originalResource == 'issues'
              ? 'merge_requests'
              : 'issues',
        };
        final permit = Mr7MutationPermit(
          operation: 'setSubscribed',
          paths: {'POST projects/909/${prepared['resource']}/3/subscribe'},
          resourceProjectId: 909,
          callArguments: arguments,
        )..capturePreparedArguments(() => prepared);
        f.session.permit = permit;
        final before = f.session.observerAdapter.requests.length;
        await expectLater(
          Mr7Readback(f.session, f.session.identity!, permit).observeNoChange(
            Mr7ParentStateObservation(
              parent: prepared['resource'] == 'issues'
                  ? const Mr7Parent.issue(id: 300, iid: 3)
                  : const Mr7Parent.mergeRequest(id: 300, iid: 3),
              state: Mr7ParentState.subscribed,
              expected: true,
            ),
            arguments: prepared,
          ),
          _activityRefusal('noChangeUnverified'),
        );
        expect(f.session.observerAdapter.requests.length, before);
        expect(f.writeCount, 0);
      });
    }
  });

  test('widget no-op requires its independent witness', () async {
    for (final scenario in [
      'matching',
      'unprepared',
      'arguments',
      'wrong-state',
    ]) {
      await _fixture((f) async {
        f.state = scenario == 'wrong-state' ? 'OPEN' : 'CLOSED';
        final run = f.noop(
          operation: 'updateWorkItemState',
          args: {'stateEvent': 'close'},
          prepare: scenario != 'unprepared',
          callArgs: scenario == 'arguments'
              ? {'projectId': 909, 'iid': 3, 'stateEvent': 'reopen'}
              : null,
        );
        if (scenario == 'matching') {
          expect(await run, isTrue);
        } else if (scenario == 'wrong-state') {
          expect(await run, isFalse);
        } else {
          await expectLater(run, throwsA(anything));
        }
        expect(f.writeCount, 0);
      });
    }
  });

  test(
    'widget no-op witnesses bind current arguments and closed or expired milestone',
    () async {
      expect(
        await _fixture((f) async {
          f.status = _statusB;
          return f.noop(
            operation: 'updateWorkItemStatus',
            args: {'candidateId': _statusB},
          );
        }),
        isTrue,
      );
      expect(
        await _fixture(
          (f) => f.noop(
            operation: 'updateWorkItemDates',
            args: {
              'mode': 'manual',
              'startDate': '2026-11-01',
              'dueDate': '2026-11-02',
            },
          ),
        ),
        isTrue,
      );
      expect(
        await _fixture((f) async {
          f.title = 'Revised';
          return f.noop(
            operation: 'updateWorkItemContent',
            args: {'title': 'Revised'},
          );
        }),
        isTrue,
      );
      expect(
        await _fixture((f) async {
          f.labels = [_label(_labelA, 'Synthetic A')];
          return f.noop(
            operation: 'updateWorkItemLabels',
            args: {
              'labels': ['Synthetic A'],
            },
          );
        }),
        isTrue,
      );
      expect(
        await _fixture((f) async {
          f.subscribed = true;
          return f.noop(
            operation: 'setWorkItemNotifications',
            args: {'enabled': true},
          );
        }),
        isTrue,
      );
      expect(
        await _fixture((f) async {
          f.escalation = 'ACKNOWLEDGED';
          final proved = await f.noop(
            operation: 'setIncidentStatus',
            args: {'status': 'ACKNOWLEDGED'},
          );
          expect(f.incidentPrepareRestReads, 0);
          return proved;
        }),
        isTrue,
      );
      for (final closed in [true, false]) {
        expect(
          await _fixture((f) async {
            f.milestone = {
              ...f.milestoneValue,
              'state': closed ? 'closed' : 'active',
              'expired': !closed,
            };
            return f.noop(
              operation: 'updateWorkItemMilestone',
              args: {'milestoneTitle': 'Synthetic milestone'},
              milestoneState: closed ? 'closed' : null,
              milestoneExpired: closed ? null : true,
            );
          }),
          isTrue,
        );
      }
    },
  );

  test(
    'widget no-op requires its independent witness through the real runner',
    () async {
      for (final variant in ['matching', 'missing', 'mismatched']) {
        final f = Mr7WorkItemFixture.create()..state = 'CLOSED';
        final scenario = sandbox.Mr7Scenario(
          id: 'state-noop-$variant',
          suite: 'graphql',
          operation: 'updateWorkItemState',
          variant: 'no-op',
          tier: 'T2',
          expectedMutations: 0,
          targetKind: AiTargetKind.issue,
          targetKinds: {AiTargetKind.project, AiTargetKind.issue},
          resource: (_) =>
              const AiResourceRef(kind: AiResourceKind.issue, id: 3),
          utterance: (p) => 'Keep issue #3 closed in ${p.path}.',
          call: (_) => AiToolCall(
            id: 'state-noop',
            name: 'updateWorkItemState',
            arguments: {
              'projectId': 909,
              'iid': 3,
              'stateEvent': 'close',
              'reason': 'Keep the synthetic issue closed.',
            },
          ),
          paths: (_) => {'POST graphql'},
          noChangeObservation: variant == 'missing'
              ? null
              : (_) => Mr7WorkItemObservation(
                  workItemId: _gid,
                  iid: 3,
                  operation: 'updateWorkItemState',
                  arguments: {
                    'projectId': 909,
                    'iid': 3,
                    'stateEvent': variant == 'mismatched' ? 'reopen' : 'close',
                    'reason': 'Keep the synthetic issue closed.',
                  },
                ),
          observe: (_, _) async => false,
          fixture: (session, identity) async {
            await f.installRoutesAndBindings();
            final adapter = Mr7CaptureAdapter(f);
            final api = GitLabApi(
              instance: GitLabInstance.parse(session.instance.toString()),
              token: 'synthetic-gitlab-pat',
              dio: Dio()..httpClientAdapter = adapter,
            );
            final detail = await api.projectWorkItem(
              Project(id: 909, name: 'Synthetic', path: identity.path),
              3,
            );
            await api.workItemState(detail.summary);
            return sandbox.Mr7ScenarioFixtures(
              graphReadDocuments: {
                for (final request in adapter.requests)
                  request['query']! as String: {
                    mr7Digest(request['variables']),
                  },
              },
            );
          },
        );
        final receipt = await sandbox.runMr7Sandbox(
          policy: Mr7Policy.candidate,
          releaseSha: '0123456789abcdef0123456789abcdef01234567',
          session: f.session,
          scenarios: [scenario],
          confirm: (_) async => true,
        );
        final row = (receipt['scenarios']! as List).single as Map;
        expect(row['coreNoChange'], true, reason: jsonEncode(receipt));
        expect(row['mutationCount'], 0, reason: jsonEncode(receipt));
        if (variant == 'matching') {
          expect(row['status'], 'PASS', reason: jsonEncode(receipt));
          expect(row['parentStateVerified'], true);
          expect(row['observerRequests'], greaterThan(0));
        } else {
          expect(row['status'], 'NOT_VERIFIED', reason: jsonEncode(receipt));
        }
      }
    },
  );

  for (final variant in [
    'matching',
    'original-witness',
    'different-text',
    'different-text-approved-witness',
  ]) {
    test('content edited approval $variant through the real runner', () async {
      final f = Mr7WorkItemFixture.create();
      final matching = variant == 'matching';
      final differentText = variant.startsWith('different-text');
      final approvedWitness = matching || variant.endsWith('approved-witness');
      final original = differentText ? f.description! : 'Model description';
      final edited = differentText ? 'Approved replacement' : f.description!;
      final arguments = {
        'projectId': 909,
        'iid': 3,
        'title': f.title,
        'description': original,
        'reason': 'Set the synthetic issue description.',
      };
      final scenario = sandbox.Mr7Scenario(
        id: 'content-edited-noop-$variant',
        suite: 'graphql',
        operation: 'updateWorkItemContent',
        variant: 'no-op',
        tier: 'T2',
        expectedMutations: 0,
        targetKind: AiTargetKind.issue,
        targetKinds: {AiTargetKind.project, AiTargetKind.issue},
        resource: (_) => const AiResourceRef(kind: AiResourceKind.issue, id: 3),
        utterance: (p) => 'Set issue #3 description in ${p.path}.',
        call: (_) => AiToolCall(
          id: 'content-edited-noop',
          name: 'updateWorkItemContent',
          arguments: arguments,
        ),
        paths: (_) => {'POST graphql'},
        // A stale core no-change claim must still pass the independent
        // witness against approved text, even when model text matches.
        freshness: differentText
            ? (_, _) async => const AiWriteFreshness(
                noChange: true,
                visibilityUnreadable: false,
                sourceVisibilityUnreadable: false,
                targetVisibility: 'private',
              )
            : null,
        noChangeObservation: (_) => Mr7WorkItemObservation(
          workItemId: _gid,
          iid: 3,
          operation: 'updateWorkItemContent',
          arguments: {
            ...arguments,
            'description': approvedWitness ? edited : original,
          },
        ),
        observe: (_, _) async => false,
        fixture: (session, identity) async {
          await f.installRoutesAndBindings();
          final adapter = Mr7CaptureAdapter(f);
          final api = GitLabApi(
            instance: GitLabInstance.parse(session.instance.toString()),
            token: 'synthetic-gitlab-pat',
            dio: Dio()..httpClientAdapter = adapter,
          );
          final detail = await api.projectWorkItem(
            Project(id: 909, name: 'Synthetic', path: identity.path),
            3,
          );
          await api.workItemContent(detail, expectedUserId: 7);
          return sandbox.Mr7ScenarioFixtures(
            graphReadDocuments: {
              for (final request in adapter.requests)
                request['query']! as String: {mr7Digest(request['variables'])},
            },
          );
        },
      );
      final receipt = await sandbox.runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: '0123456789abcdef0123456789abcdef01234567',
        session: f.session,
        scenarios: [scenario],
        confirm: (_) async => true,
        editConfirm: (proposal) async {
          expect(proposal.editableField, 'description');
          return edited;
        },
      );
      final row = (receipt['scenarios']! as List).single as Map;
      expect(
        row['edit'],
        isA<Map<Object?, Object?>>(),
        reason: jsonEncode(receipt),
      );
      expect(row['edit'], containsPair('reason', 'approvalRequired'));
      expect(row['confirmations'], hasLength(2));
      expect(row['coreNoChange'], true, reason: jsonEncode(receipt));
      expect(row['mutationCount'], 0, reason: jsonEncode(receipt));
      expect(
        row['status'],
        matching ? 'PASS' : 'NOT_VERIFIED',
        reason: jsonEncode(receipt),
      );
      if (matching) {
        expect(row['classification'], 'verifiedNoOp');
        expect(row['parentStateVerified'], true);
        expect(row['readback'], 'PASS');
        expect(row['observerRequests'], greaterThan(0));
      } else {
        expect(row['classification'], isNot('verifiedNoOp'));
        expect(row['reason'], 'noChangeUnverified');
        expect(row['readback'], 'NOT_VERIFIED');
        if (approvedWitness) {
          expect(row['parentStateVerified'], false);
          expect(row['observerRequests'], greaterThan(0));
        }
      }
      expect(f.description, 'Original description');
      expect(f.title, 'Original title');
      expect(f.writeCount, 0);
    });
  }

  test('work-item snapshot refuses caller-selected partial coverage', () async {
    await _fixture((f) async {
      await expectLater(
        f.effect(
          operation: 'updateWorkItemContent',
          args: {'title': 'Revised'},
          input: {'title': 'Revised'},
          fields: {'title'},
          mutate: () {
            f.title = 'Revised';
            f.description = 'Unexpected drift';
          },
        ),
        throwsA(
          isA<Mr7Refused>().having(
            (e) => e.code,
            'code',
            'snapshotConfiguration',
          ),
        ),
      );
      expect(f.writeCount, 0);
    });
  });

  for (final violation in ['path', 'size', 'graph-size']) {
    test('snapshot readback enforces $violation for workItem', () async {
      await _fixture((f) async {
        await expectLater(
          f.effect(
            operation: 'updateWorkItemContent',
            args: {'title': 'Revised'},
            input: {'title': 'Revised'},
            readbackPaths: violation == 'path' ? {} : {_path},
            mutate: () {
              f.title = 'Revised';
              if (violation == 'size') {
                f.server.routes['GET $_path'] = (_) => mr7Json({
                  'id': 300,
                  'iid': 3,
                  'project_id': 909,
                  'untracked_large_field': 'x' * (2 * 1024 * 1024 + 1),
                });
              }
              f.oversizedGraphReadback = violation == 'graph-size';
            },
          ),
          throwsA(
            isA<Mr7Refused>().having(
              (error) => error.code,
              'code',
              violation == 'path' ? 'readbackTarget' : 'observerUnreadable',
            ),
          ),
        );
      });
    });
  }

  test('complete snapshot preserves omitted EE date mode', () async {
    expect(
      await _fixture(
        (f) => f.effect(
          operation: 'updateWorkItemContent',
          args: {'title': 'Revised'},
          input: {'title': 'Revised'},
          mutate: () {
            f.title = 'Revised';
            f.isFixed = false;
          },
        ),
      ),
      isFalse,
    );
  });

  test(
    'manual date no-op rejects inherited dates without a caller edition flag',
    () async {
      expect(
        await _fixture((f) async {
          f.isFixed = false;
          return f.noop(
            operation: 'updateWorkItemDates',
            args: {
              'mode': 'manual',
              'startDate': f.startDate,
              'dueDate': f.dueDate,
            },
          );
        }),
        isFalse,
      );
    },
  );

  test(
    'CE date fallback requires precise schema errors without partial data',
    () async {
      for (final invalid in [false, true]) {
        await _fixture((f) async {
          f.ceDates = true;
          f.invalidDateSchemaError = invalid;
          f.partialDateSchemaError = !invalid;
          await expectLater(
            f.noop(
              operation: 'updateWorkItemDates',
              args: {
                'mode': 'manual',
                'startDate': f.startDate,
                'dueDate': f.dueDate,
              },
            ),
            throwsA(isA<Mr7Refused>()),
          );
          expect(f.writeCount, 0);
        });
      }
      expect(
        await _fixture((f) async {
          f.ceDates = true;
          return f.noop(
            operation: 'updateWorkItemDates',
            args: {
              'mode': 'manual',
              'startDate': f.startDate,
              'dueDate': f.dueDate,
            },
          );
        }),
        isTrue,
      );
    },
  );

  test('label observer accepts a complete set across multiple pages', () async {
    expect(
      await _fixture((f) async {
        f.paginateLabels = true;
        final proved = await f.effect(
          operation: 'updateWorkItemLabels',
          args: {
            'labels': ['Synthetic A', 'Synthetic B'],
          },
          input: {
            'labelsWidget': {
              'addLabelIds': [_labelA, _labelB],
              'removeLabelIds': <String>[],
            },
          },
          mutate: () => f.labels = [
            _label(_labelA, 'Synthetic A'),
            _label(_labelB, 'Synthetic B'),
          ],
        );
        expect(f.labelPages, greaterThanOrEqualTo(5));
        return proved;
      }),
      isTrue,
    );
  });

  _activityTests();
}

const _activityWorkItem = 'gid://gitlab/WorkItem/300';
const _activityIssuePath = 'projects/909/issues/3';
const _activityNote51 = 'gid://gitlab/Note/51';
const _activityNote52 = 'gid://gitlab/Note/52';
const _activityNote53 = 'gid://gitlab/Note/53';
const _activityActor = 'gid://gitlab/User/7';
const _activityOther = 'gid://gitlab/User/8';
const _activityDiscussion = 'gid://gitlab/Discussion/opaque-thread';
const _activityReply = 'gid://gitlab/IndividualNoteDiscussion/opaque-reply';

Matcher _activityRefusal(String code) =>
    throwsA(isA<Mr7Refused>().having((error) => error.code, 'code', code));

class Mr7ActivityFixture {
  Mr7ActivityFixture._(this.server, this.session);
  static Mr7ActivityFixture create() {
    final server = Mr7SyntheticGitLab();
    return Mr7ActivityFixture._(
      server,
      Mr7SandboxSession(
        server: server,
        nonce: 'activity-wave3b',
        requestCap: 1000,
        eventDelay: () async {},
      ),
    );
  }

  final Mr7SyntheticGitLab server;
  final Mr7SandboxSession session;
  final List<String> threadNotes = [_activityNote51];
  final List<String> secondNotes = <String>[];
  final Map<String, String> bodies = {_activityNote51: 'Original'};
  final List<Map<String, Object?>> awards = [];
  String noteAuthor = _activityActor;
  bool wrongProject = false;
  bool wrongParent = false;
  bool retainDeleted = false;
  bool omitExactNoteRead = false;
  bool paginateDiscussions = false;
  bool paginateNotes = false;
  bool paginateAwards = false;
  bool reactionCursorCycle = false;
  bool removeOtherInstead = false;
  bool brokenDiscussionCursor = false;
  bool wrongReplyThread = false;
  bool bindCreatedNote = true;
  String rawCallBody = 'Created';
  int discussionReads = 0;
  int notePageReads = 0;
  int reactionReads = 0;
  int noteLookupReads = 0;
  int writeCount = 0;
  late Mr7MutationPermit permit;

  Map<String, Object?> get project => {
    'id': 'gid://gitlab/Project/909',
    'fullPath': session.identity!.path,
  };
  Map<String, Object?> get item => {
    'id': _activityWorkItem,
    'iid': '3',
    'title': 'Activity issue',
    'state': 'OPEN',
    'createdAt': '2026-09-01T01:02:03Z',
    'updatedAt': '2026-10-29T00:00:00Z',
    'webUrl':
        'https://gitlab.invalid/install/${session.identity!.path}/-/work_items/3',
    'namespace': {
      'id': 'gid://gitlab/Namespaces::ProjectNamespace/909',
      'fullPath': session.identity!.path,
    },
    'workItemType': {'id': 'gid://gitlab/WorkItems::Type/99', 'name': 'Issue'},
    'project': wrongProject
        ? {'id': 'gid://gitlab/Project/777', 'fullPath': 'other/project'}
        : project,
  };
  Map<String, Object?> get actor => {'id': _activityActor};

  Map<String, Object?> noteRest(String id) => {
    'id': int.parse(id.split('/').last),
    'project_id': 909,
    'noteable_id': 300,
    'author': {
      'id': id == _activityNote51 && noteAuthor == _activityOther ? 8 : 7,
    },
    'system': false,
    'internal': false,
  };
  Map<String, Object?> noteSummary(String id) => {
    'id': id,
    'body': bodies[id] ?? 'Other note',
    'system': false,
    'createdAt': '2026-09-01T01:02:03Z',
    'updatedAt': '2026-10-29T00:00:00Z',
    'author': {
      'id': id == _activityNote51 ? noteAuthor : _activityActor,
      'name': 'Synthetic actor',
      'username': 'synthetic-owner',
    },
  };
  Map<String, Object?> noteDetail(String id) => {
    ...noteSummary(id),
    'internal': false,
    'noteableType': 'Issue',
    'noteableId': wrongParent ? 301 : 300,
    'project': project,
    'userPermissions': {'adminNote': true, 'awardEmoji': true},
    'discussion': {
      'createdAt': '2026-09-01T01:02:03Z',
      'id': wrongReplyThread && id == _activityNote51
          ? 'gid://gitlab/Discussion/original-anchor-thread'
          : _activityDiscussion,
      'replyId': wrongReplyThread && id == _activityNote51
          ? 'gid://gitlab/IndividualNoteDiscussion/original-reply'
          : _activityReply,
    },
  };
  Map<String, Object?> connection(List<Object?> nodes, {String? next}) => {
    'nodes': nodes,
    'pageInfo': {'hasNextPage': next != null, 'endCursor': next},
  };
  Map<String, Object?> discussion(List<String> ids, {String? after}) {
    final page = paginateNotes && ids.length > 1;
    final shown = page ? (after == null ? ids.take(1) : ids.skip(1)) : ids;
    return {
      'id': _activityDiscussion,
      'replyId': _activityReply,
      'createdAt': '2026-09-01T01:02:03Z',
      'notes': connection(
        shown.map(noteSummary).toList(),
        next: page && after == null ? 'note-cursor-1' : null,
      ),
    };
  }

  Map<String, Object?> award(String name, String user) => {
    'name': name,
    'unicode': '👍',
    'user': {'id': user},
  };

  Future<void> initialize() async {
    await session.initialize();
    await installRoutesAndBindings();
  }

  Future<void> installRoutesAndBindings() async {
    server.routes['GET $_activityIssuePath'] = (_) =>
        mr7Json({'id': 300, 'iid': 3, 'project_id': 909});
    for (final id in [_activityNote51, _activityNote52, _activityNote53]) {
      server.routes['GET $_activityIssuePath/notes/${id.split('/').last}'] =
          (_) => mr7Json(noteRest(id));
    }
    await session.bindWorkItemGraphResource(
      _activityWorkItem,
      path: _activityIssuePath,
    );
    for (final id in [_activityNote51, if (bindCreatedNote) _activityNote52]) {
      await session.bindGraphResource(
        id,
        path: '$_activityIssuePath/notes/${id.split('/').last}',
      );
    }
    server.routes['POST /install/api/graphql'] = graph;
  }

  ResponseBody graph(RequestOptions request) {
    final body = request.data as Map;
    final doc = body['query'] as String;
    final vars = body['variables'] as Map;
    if (doc.contains('query MobileProjectWorkItem(')) {
      return mr7Json({
        'data': {
          'project': {
            ...project,
            'workItems': connection([
              {...item, 'widgets': <Object?>[]},
            ]),
          },
        },
      });
    }
    if (doc.startsWith('mutation')) {
      writeCount++;
      server.scenarioWrites++;
      server.addEvent(target: 909);
      final input = vars['input'] as Map;
      if (doc.contains('createNote(')) {
        bodies[_activityNote52] = input['body'] as String;
        threadNotes.add(_activityNote52);
        return mr7Json({
          'data': {
            'createNote': {
              'errors': <String>[],
              'note': {'id': _activityNote52},
            },
          },
        });
      }
      if (doc.contains('updateNote(')) {
        bodies[_activityNote51] = input['body'] as String;
        return mr7Json({
          'data': {
            'updateNote': {
              'note': {'id': _activityNote51},
            },
          },
        });
      }
      if (doc.contains('destroyNote(')) {
        if (!retainDeleted) threadNotes.remove(_activityNote51);
        return mr7Json({
          'data': {
            'destroyNote': {'errors': <String>[]},
          },
        });
      }
      if (doc.contains('awardEmojiAdd(')) {
        awards.add(award(input['name'] as String, _activityActor));
        return mr7Json({
          'data': {
            'awardEmojiAdd': {'errors': <String>[]},
          },
        });
      }
      if (doc.contains('awardEmojiRemove(')) {
        final removed = removeOtherInstead ? _activityOther : _activityActor;
        awards.removeWhere(
          (a) =>
              a['name'] == input['name'] && (a['user'] as Map)['id'] == removed,
        );
        return mr7Json({
          'data': {
            'awardEmojiRemove': {'errors': <String>[]},
          },
        });
      }
      throw StateError('Unexpected mutation');
    }
    if (doc.contains('query Mr7Note(') ||
        doc.contains('query MobileWorkItemActivityNoteReadback(') ||
        doc.contains('query MobileWorkItemActivityEditAccess(')) {
      noteLookupReads++;
      return mr7Json({
        'data': {
          'currentUser': actor,
          'workItem': item,
          'note': omitExactNoteRead
              ? null
              : noteDetail(vars['noteId'] as String),
        },
      });
    }
    if (doc.contains('query Mr7Reactions(') ||
        doc.contains('query MobileWorkItemActivityReactionAccess(')) {
      reactionReads++;
      final after = vars['after'];
      final paged = paginateAwards && awards.length > 1;
      final List<Map<String, Object?>> page;
      String? next;
      if (!paged) {
        page = awards.toList();
      } else if (after == null) {
        page = awards.take(1).toList();
        next = 'reaction-cursor-1';
      } else {
        page = awards.skip(1).toList();
        next = reactionCursorCycle ? 'reaction-cursor-1' : null;
      }
      return mr7Json({
        'data': {
          'currentUser': actor,
          'workItem': item,
          'note': {
            ...noteDetail(vars['noteId'] as String),
            'discussion': {
              'id': _activityDiscussion,
              'createdAt': '2026-09-01T01:02:03Z',
            },
            'awardEmoji': connection(page, next: next),
          },
        },
      });
    }
    if (doc.contains('query Mr7Activity(') ||
        doc.contains('query MobileWorkItemActivity(')) {
      discussionReads++;
      final after = vars['after'];
      final second = secondNotes.isNotEmpty;
      final nodes = <Object?>[];
      if (!paginateDiscussions || after == null) {
        nodes.add(discussion(threadNotes));
      }
      if (second && (!paginateDiscussions || after != null)) {
        nodes.add({
          'id': 'gid://gitlab/Discussion/second-thread',
          'replyId': 'gid://gitlab/Discussion/second-reply',
          'notes': connection(secondNotes.map(noteSummary).toList()),
        });
      }
      final next = paginateDiscussions && second && after == null
          ? (brokenDiscussionCursor ? '' : 'discussion-cursor-1')
          : null;
      return mr7Json({
        'data': {
          'currentUser': actor,
          'workItem': {
            ...item,
            'widgets': [
              {'type': 'NOTES', 'discussions': connection(nodes, next: next)},
            ],
          },
        },
      });
    }
    if (doc.contains('query Mr7DiscussionNotes(')) {
      notePageReads++;
      final anchorId = vars['anchorNoteId'] as String;
      return mr7Json({
        'data': {
          'currentUser': actor,
          'workItem': item,
          'anchor': {
            'id': anchorId,
            'noteableType': 'Issue',
            'noteableId': 300,
            'project': project,
            'discussion': discussion(
              threadNotes,
              after: vars['after'] as String?,
            ),
          },
        },
      });
    }
    throw StateError('Unexpected query: $doc');
  }

  Future<void> send(String operation, {bool? add}) async {
    final root = switch (operation) {
      'createWorkItemActivityComment' ||
      'createWorkItemActivityReply' => 'createNote',
      'editWorkItemActivityNote' => 'updateNote',
      'deleteWorkItemActivityNote' => 'destroyNote',
      'setWorkItemActivityNoteReaction' =>
        add == true ? 'awardEmojiAdd' : 'awardEmojiRemove',
      _ => throw StateError(operation),
    };
    final input = switch (operation) {
      'createWorkItemActivityComment' => {
        'noteableId': _activityWorkItem,
        'body': 'Created',
      },
      'createWorkItemActivityReply' => {
        'noteableId': _activityWorkItem,
        'body': 'Created',
        'discussionId': _activityReply,
      },
      'editWorkItemActivityNote' => {'id': _activityNote51, 'body': 'Edited'},
      'deleteWorkItemActivityNote' => {'id': _activityNote51},
      'setWorkItemActivityNoteReaction' => {
        'awardableId': _activityNote51,
        'name': 'thumbsup',
      },
      _ => throw StateError(operation),
    };
    final type = switch (root) {
      'createNote' => 'CreateNoteInput!',
      'updateNote' => 'UpdateNoteInput!',
      'destroyNote' => 'DestroyNoteInput!',
      'awardEmojiAdd' => 'AwardEmojiAddInput!',
      _ => 'AwardEmojiRemoveInput!',
    };
    final selection = root == 'createNote' || root == 'updateNote'
        ? 'note { id }'
        : 'errors';
    final document =
        'mutation Test(\$input: $type) { $root(input: \$input) { $selection } }';
    final vars = {'input': input};
    permit = Mr7MutationPermit(
      operation: operation,
      paths: {'POST graphql'},
      resourceProjectId: 909,
      graphDocuments: {document},
      graphVariablesDigests: {mr7Digest(vars)},
      resultPath: root == 'createNote' ? ['data', root, 'note'] : const [],
      callArguments: {
        'projectId': 909,
        'iid': 3,
        if (root == 'createNote') 'body': rawCallBody,
        if (operation == 'createWorkItemActivityReply') 'anchorNoteId': 51,
      },
    )..confirmed = true;
    session.permit = permit;
    await session.writer.post<Object?>(
      '${session.instance}/api/graphql',
      data: {'query': document, 'variables': vars},
    );
  }

  Future<void> readProductionNote(
    GitLabApi api,
    String operation,
    String noteId,
  ) async {
    final detail = await api.projectWorkItem(
      Project(id: 909, name: 'Synthetic', path: session.identity!.path),
      3,
    );
    final activity = await api.workItemActivity(
      detail.summary,
      allowLegacyFallback: false,
    );
    final discussion = activity.snapshot.discussions.items.single;
    final note = discussion.notes.items.singleWhere((n) => n.id == noteId);
    if (operation == 'editWorkItemActivityNote') {
      await api.workItemActivityEditAccess(detail.summary, discussion, note);
    } else {
      await api.workItemActivityReactionAccess(
        detail.summary,
        discussion,
        note,
      );
    }
  }

  Future<Map<String, Set<String>>> productionReadDocuments(
    String operation, {
    String noteId = _activityNote51,
  }) async {
    final adapter = Mr7CaptureAdapter.activity(this);
    final api = GitLabApi(
      instance: GitLabInstance.parse(session.instance.toString()),
      token: 'synthetic-gitlab-pat',
      dio: Dio()..httpClientAdapter = adapter,
    );
    await readProductionNote(api, operation, noteId);
    return {
      for (final request in adapter.requests)
        request['query']! as String: {mr7Digest(request['variables'])},
    };
  }

  Future<void> prepareNoop(
    String operation, {
    String? noteId = _activityNote51,
    Map<String, Object?>? callArguments,
    bool recordArguments = true,
  }) async {
    if (noteId != null) {
      session.observerAdapter.graphReadDocuments =
          await productionReadDocuments(operation, noteId: noteId);
    }
    permit = Mr7MutationPermit(
      operation: operation,
      paths: {'POST graphql'},
      resourceProjectId: 909,
      callArguments: callArguments,
    )..confirmed = true;
    session.permit = permit;
    if (recordArguments) {
      final preparedArguments = Map<String, Object?>.unmodifiable(
        callArguments ??
            {
              'projectId': 909,
              'iid': 3,
              'noteId': 51,
              if (operation == 'setWorkItemActivityNoteReaction') ...{
                'name': 'thumbsup',
                'add': true,
              } else
                'body': 'Original',
            },
      );
      permit.capturePreparedArguments(() => preparedArguments);
    }
    await session.writer.get<Object?>(_activityIssuePath);
    if (noteId != null) {
      await readProductionNote(
        GitLabApi(
          instance: GitLabInstance.parse(session.instance.toString()),
          token: 'synthetic-gitlab-pat',
          dio: session.writer,
        ),
        operation,
        noteId,
      );
    }
  }

  Mr7WorkItemActivityObservation observation(
    String operation, {
    String noteId = _activityNote51,
    String? body,
    String? discussionId = _activityDiscussion,
    String? replyId,
    bool? add,
  }) => Mr7WorkItemActivityObservation(
    workItemId: _activityWorkItem,
    iid: 3,
    operation: operation,
    noteId: noteId,
    body: body,
    discussionId: discussionId,
    replyId: replyId,
    emojiName: add == null ? null : 'thumbsup',
    add: add,
  );

  Future<bool> observe(Mr7WorkItemActivityObservation spec) => Mr7Readback(
    session,
    session.identity!,
    permit,
    paths: {
      _activityIssuePath,
      for (final id in [_activityNote51, _activityNote52, _activityNote53])
        '$_activityIssuePath/notes/${id.split('/').last}',
    },
  ).observe(spec);

  Future<bool> observeNoop(
    Mr7WorkItemActivityObservation spec,
    Map<String, Object?> args,
  ) => Mr7Readback(
    session,
    session.identity!,
    permit,
  ).observeNoChange(spec, arguments: args);
}

void _activityTests() {
  test('reply observer accepts the effective trimmed dispatch text', () async {
    final f = Mr7ActivityFixture.create()..bindCreatedNote = false;
    await f.initialize();
    f.rawCallBody = '  Created \n';
    await f.send('createWorkItemActivityReply');
    expect(
      await f.observe(
        f.observation(
          'createWorkItemActivityReply',
          noteId: _activityNote52,
          body: 'Created',
          replyId: _activityReply,
        ),
      ),
      isTrue,
    );
    await f.session.finish();
  });

  test(
    'reply observer binds the dispatched thread to the requested anchor note',
    () async {
      final f = Mr7ActivityFixture.create()..bindCreatedNote = false;
      await f.initialize();
      f.wrongReplyThread = true;
      await f.send('createWorkItemActivityReply');
      await expectLater(
        f.observe(
          f.observation(
            'createWorkItemActivityReply',
            noteId: _activityNote52,
            body: 'Created',
            replyId: _activityReply,
          ),
        ),
        _activityRefusal('observerReplyAnchor'),
      );
      expect(f.noteLookupReads, 1);
      await f.session.finish();
    },
  );

  test('delete guard refuses a foreign note author before dispatch', () async {
    final f = Mr7ActivityFixture.create();
    await f.initialize();
    f.noteAuthor = _activityOther;
    await expectLater(
      f.send('deleteWorkItemActivityNote'),
      throwsA(
        isA<DioException>().having(
          (error) => error.error,
          'error',
          isA<Mr7Refused>().having(
            (error) => error.code,
            'code',
            'observerNoteOwnership',
          ),
        ),
      ),
    );
    expect(f.writeCount, 0);
    await f.session.finish();
  });

  test(
    'activity comment and opaque reply read exact authored notes on real connections',
    () async {
      for (final operation in [
        'createWorkItemActivityComment',
        'createWorkItemActivityReply',
      ]) {
        final f = Mr7ActivityFixture.create()..bindCreatedNote = false;
        await f.initialize();
        await f.send(operation);
        expect(
          await f.observe(
            f.observation(
              operation,
              noteId: _activityNote52,
              body: 'Created',
              replyId: operation.endsWith('Reply') ? _activityReply : null,
            ),
          ),
          isTrue,
          reason: operation,
        );
        expect(f.writeCount, 1);
        expect(f.noteLookupReads, operation.endsWith('Reply') ? 2 : 1);
        await f.session.finish();
      }
    },
  );

  test(
    'activity edit reads exact actor parent and all discussion and note pages',
    () async {
      final f = Mr7ActivityFixture.create();
      await f.initialize();
      f.threadNotes.insert(0, _activityNote52);
      f.bodies[_activityNote52] = 'Anchor';
      f.secondNotes.add(_activityNote53);
      f.bodies[_activityNote53] = 'Second discussion';
      f.paginateNotes = true;
      f.paginateDiscussions = true;
      await f.send('editWorkItemActivityNote');
      expect(
        await f.observe(
          f.observation('editWorkItemActivityNote', body: 'Edited'),
        ),
        isTrue,
      );
      expect(f.discussionReads, 2);
      expect(f.notePageReads, 1);
      await f.session.finish();
    },
  );

  test(
    'activity rejects foreign note owner parent project and opaque discussion identities',
    () async {
      for (final variant in [
        'author',
        'parent',
        'project',
        'discussion',
        'reply',
      ]) {
        final f = Mr7ActivityFixture.create();
        await f.initialize();
        await f.send('editWorkItemActivityNote');
        if (variant == 'author') f.noteAuthor = _activityOther;
        if (variant == 'parent') f.wrongParent = true;
        if (variant == 'project') f.wrongProject = true;
        final observed = f.observe(
          f.observation(
            'editWorkItemActivityNote',
            body: 'Edited',
            discussionId: variant == 'discussion'
                ? 'gid://gitlab/Discussion/different'
                : _activityDiscussion,
            replyId: variant == 'reply'
                ? 'gid://gitlab/Discussion/different-reply'
                : null,
          ),
        );
        if (variant == 'discussion' || variant == 'reply') {
          expect(await observed, isFalse, reason: variant);
        } else {
          await expectLater(
            observed,
            _activityRefusal(
              variant == 'project'
                  ? 'readbackIdentity'
                  : 'observerNoteOwnership',
            ),
            reason: variant,
          );
        }
        await f.session.finish();
      }
    },
  );

  test('deletion is not proven by one missing read', () async {
    final f = Mr7ActivityFixture.create();
    await f.initialize();
    f.retainDeleted = true;
    f.omitExactNoteRead = true;
    f.threadNotes.insert(0, _activityNote52);
    f.paginateNotes = true;
    await f.send('deleteWorkItemActivityNote');
    // Body, author and relationship all match. Only the final presence check
    // can reject this retained Note after the complete connection traversal.
    expect(
      await f.observe(
        f.observation('deleteWorkItemActivityNote', body: 'Original'),
      ),
      isFalse,
    );
    expect(f.notePageReads, 1);
    await f.session.finish();
  });

  test(
    'activity deletion requires complete connections and rejects incomplete page metadata',
    () async {
      for (final broken in [false, true]) {
        final f = Mr7ActivityFixture.create();
        await f.initialize();
        f.threadNotes.add(_activityNote52);
        f.secondNotes.add(_activityNote53);
        f.paginateDiscussions = true;
        f.brokenDiscussionCursor = broken;
        await f.send('deleteWorkItemActivityNote');
        final observed = f.observe(f.observation('deleteWorkItemActivityNote'));
        if (broken) {
          await expectLater(observed, _activityRefusal('observerConnection'));
        } else {
          expect(await observed, isTrue);
        }
        await f.session.finish();
      }
    },
  );

  test('reaction removal cannot be accepted for another actor', () async {
    final f = Mr7ActivityFixture.create();
    await f.initialize();
    f.awards.addAll([
      f.award('thumbsup', _activityActor),
      f.award('thumbsup', _activityOther),
    ]);
    f.removeOtherInstead = true;
    await f.send('setWorkItemActivityNoteReaction', add: false);
    expect(
      await f.observe(
        f.observation('setWorkItemActivityNoteReaction', add: false),
      ),
      isFalse,
    );
    expect(f.reactionReads, 1);
    await f.session.finish();
  });

  test(
    'activity reaction add and remove page the exact actor awards',
    () async {
      for (final add in [true, false]) {
        final f = Mr7ActivityFixture.create();
        await f.initialize();
        f.paginateAwards = true;
        f.awards.add(f.award('thumbsup', _activityOther));
        if (!add) {
          f.awards.add(f.award('thumbsup', _activityActor));
          f.awards.add(f.award('smile', _activityOther));
        }
        await f.send('setWorkItemActivityNoteReaction', add: add);
        expect(
          await f.observe(
            f.observation('setWorkItemActivityNoteReaction', add: add),
          ),
          isTrue,
        );
        expect(f.reactionReads, 2);
        expect(
          f.awards.any(
            (award) =>
                (award['user'] as Map)['id'] == _activityOther &&
                award['name'] == 'thumbsup',
          ),
          isTrue,
          reason: 'The synthetic transport retains the other actor award.',
        );
        await f.session.finish();
      }
    },
  );

  test(
    'activity reaction pagination rejects repeated cursor and duplicate awards',
    () async {
      for (final variant in ['cursor', 'duplicate']) {
        final f = Mr7ActivityFixture.create();
        await f.initialize();
        f.paginateAwards = true;
        f.awards.addAll([
          f.award('thumbsup', _activityOther),
          f.award(
            variant == 'duplicate' ? 'thumbsup' : 'smile',
            _activityOther,
          ),
        ]);
        f.reactionCursorCycle = variant == 'cursor';
        await f.send('setWorkItemActivityNoteReaction', add: true);
        await expectLater(
          f.observe(
            f.observation('setWorkItemActivityNoteReaction', add: true),
          ),
          _activityRefusal(
            variant == 'cursor' ? 'observerConnection' : 'observerRelationship',
          ),
          reason: variant,
        );
        await f.session.finish();
      }
    },
  );

  test(
    'activity edit and reaction zero-dispatch require prepared exact target and requested state',
    () async {
      for (final operation in [
        'editWorkItemActivityNote',
        'setWorkItemActivityNoteReaction',
      ]) {
        for (final mismatch in [false, true]) {
          final f = Mr7ActivityFixture.create();
          await f.initialize();
          final isReaction = operation == 'setWorkItemActivityNoteReaction';
          if (isReaction) f.awards.add(f.award('thumbsup', _activityActor));
          await f.prepareNoop(operation);
          final args = <String, Object?>{
            'projectId': 909,
            'iid': 3,
            'noteId': 51,
            if (isReaction) ...{
              'name': 'thumbsup',
              'add': true,
            } else
              'body': mismatch ? 'Different' : 'Original',
          };
          final spec = f.observation(
            operation,
            body: isReaction ? null : 'Original',
            add: isReaction ? (mismatch ? false : true) : null,
          );
          if (mismatch) {
            await expectLater(
              f.observeNoop(spec, args),
              _activityRefusal('noChangeUnverified'),
              reason: operation,
            );
          } else {
            expect(await f.observeNoop(spec, args), isTrue, reason: operation);
          }
          expect(f.writeCount, 0);
          await f.session.finish();
        }
      }
    },
  );

  for (final variant in ['unread', 'earlier permit', 'different prepared']) {
    test('activity no-op refuses a Note with $variant preparation', () async {
      for (final operation in [
        'editWorkItemActivityNote',
        'setWorkItemActivityNoteReaction',
      ]) {
        final f = Mr7ActivityFixture.create();
        await f.initialize();
        f.threadNotes.add(_activityNote52);
        f.bodies[_activityNote52] = 'Original';
        final isReaction = operation == 'setWorkItemActivityNoteReaction';
        if (isReaction) f.awards.add(f.award('thumbsup', _activityActor));
        if (variant == 'earlier permit') await f.prepareNoop(operation);
        await f.prepareNoop(
          operation,
          noteId: variant == 'different prepared' ? _activityNote52 : null,
        );
        await expectLater(
          f.observeNoop(
            f.observation(
              operation,
              body: isReaction ? null : 'Original',
              add: isReaction ? true : null,
            ),
            {
              'projectId': 909,
              'iid': 3,
              'noteId': 51,
              if (isReaction) ...{
                'name': 'thumbsup',
                'add': true,
              } else
                'body': 'Original',
            },
          ),
          _activityRefusal('observerMutationTarget'),
          reason: operation,
        );
        expect(f.writeCount, 0);
        await f.session.finish();
      }
    });
  }

  test(
    'activity no-op refuses an unrelated Note read with unselected fields',
    () async {
      for (final operation in [
        'editWorkItemActivityNote',
        'setWorkItemActivityNoteReaction',
      ]) {
        final f = Mr7ActivityFixture.create();
        await f.initialize();
        final isReaction = operation == 'setWorkItemActivityNoteReaction';
        if (isReaction) f.awards.add(f.award('thumbsup', _activityActor));
        await f.prepareNoop(operation, noteId: null);
        const document = r'''
query UnrelatedAnchor($workItemId: WorkItemID!, $noteId: NoteID!) {
  workItem(id: $workItemId) { id iid project { id fullPath } }
  anchor: note(id: $noteId) { id }
}
''';
        final variables = {
          'workItemId': _activityWorkItem,
          'noteId': _activityNote51,
        };
        f.session.observerAdapter.graphReadDocuments = {
          document: {mr7Digest(variables)},
        };
        f.server.routes['POST /install/api/graphql'] = (_) => mr7Json({
          'data': {'workItem': f.item, 'anchor': f.noteDetail(_activityNote51)},
        });
        await f.session.writer.post<Object?>(
          '${f.session.instance}/api/graphql',
          data: {'query': document, 'variables': variables},
        );
        f.server.routes['POST /install/api/graphql'] = f.graph;
        await expectLater(
          f.observeNoop(
            f.observation(
              operation,
              body: isReaction ? null : 'Original',
              add: isReaction ? true : null,
            ),
            {
              'projectId': 909,
              'iid': 3,
              'noteId': 51,
              if (isReaction) ...{
                'name': 'thumbsup',
                'add': true,
              } else
                'body': 'Original',
            },
          ),
          _activityRefusal('observerMutationTarget'),
        );
        await f.session.finish();
      }
    },
  );

  test(
    'activity no-op refuses missing prepared arguments despite matching call text',
    () async {
      final f = Mr7ActivityFixture.create();
      await f.initialize();
      final arguments = <String, Object?>{
        'projectId': 909,
        'iid': 3,
        'noteId': 51,
        'body': 'Original',
      };
      await f.prepareNoop(
        'editWorkItemActivityNote',
        callArguments: arguments,
        recordArguments: false,
      );
      final before = f.session.observerAdapter.requests.length;
      await expectLater(
        f.observeNoop(
          f.observation('editWorkItemActivityNote', body: 'Original'),
          arguments,
        ),
        _activityRefusal('noChangeUnverified'),
      );
      expect(f.session.observerAdapter.requests.length, before);
      expect(f.writeCount, 0);
      await f.session.finish();
    },
  );

  test(
    'activity no-op binds frozen prepared values and original selectors independent of key order',
    () async {
      for (final operation in [
        'editWorkItemActivityNote',
        'setWorkItemActivityNoteReaction',
      ]) {
        final f = Mr7ActivityFixture.create();
        await f.initialize();
        f.threadNotes.add(_activityNote52);
        f.bodies[_activityNote52] = 'Original';
        final isReaction = operation == 'setWorkItemActivityNoteReaction';
        if (isReaction) f.awards.add(f.award('thumbsup', _activityActor));
        final arguments = <String, Object?>{
          'projectId': 909,
          'iid': 3,
          'noteId': 51,
          if (isReaction) ...{
            'name': 'thumbsup',
            'add': true,
          } else
            'body': 'Original',
        };
        await f.prepareNoop(
          operation,
          noteId: _activityNote52,
          callArguments: arguments,
        );
        f.permit.capturePreparedArguments(() => {...arguments, 'noteId': 52});
        await expectLater(
          f.observeNoop(
            f.observation(
              operation,
              noteId: _activityNote52,
              body: isReaction ? null : 'Original',
              add: isReaction ? true : null,
            ),
            {...arguments, 'noteId': 52},
          ),
          _activityRefusal('noChangeUnverified'),
        );
        final matchingArguments = {...arguments, 'noteId': 52};
        await f.prepareNoop(
          operation,
          noteId: _activityNote52,
          callArguments: matchingArguments,
        );
        expect(
          await f.observeNoop(
            f.observation(
              operation,
              noteId: _activityNote52,
              body: isReaction ? null : 'Original',
              add: isReaction ? true : null,
            ),
            Map<String, Object?>.fromEntries(
              matchingArguments.entries.toList().reversed,
            ),
          ),
          isTrue,
          reason: 'Equivalent argument maps may have different key order.',
        );
        await f.session.finish();
      }
    },
  );

  test('activity no-op rejects a retained earlier permit', () async {
    for (final operation in [
      'editWorkItemActivityNote',
      'setWorkItemActivityNoteReaction',
    ]) {
      for (final cleared in [false, true]) {
        final f = Mr7ActivityFixture.create();
        await f.initialize();
        final isReaction = operation == 'setWorkItemActivityNoteReaction';
        if (isReaction) f.awards.add(f.award('thumbsup', _activityActor));
        await f.prepareNoop(operation);
        final earlier = f.permit;
        if (cleared) {
          f.session.permit = null;
        } else {
          await f.prepareNoop(operation, noteId: null);
        }
        await expectLater(
          Mr7Readback(f.session, f.session.identity!, earlier).observeNoChange(
            f.observation(
              operation,
              body: isReaction ? null : 'Original',
              add: isReaction ? true : null,
            ),
            arguments: {
              'projectId': 909,
              'iid': 3,
              'noteId': 51,
              if (isReaction) ...{
                'name': 'thumbsup',
                'add': true,
              } else
                'body': 'Original',
            },
          ),
          _activityRefusal('noChangeUnverified'),
        );
        await f.session.finish();
      }
    }
  });

  test(
    'activity preparation cannot cross a permit switch during a read',
    () async {
      for (final operation in [
        'editWorkItemActivityNote',
        'setWorkItemActivityNoteReaction',
      ]) {
        for (final delayedStream in [false, true]) {
          for (final hadPermit in [false, true]) {
            final f = Mr7ActivityFixture.create();
            await f.initialize();
            final isReaction = operation == 'setWorkItemActivityNoteReaction';
            if (isReaction) f.awards.add(f.award('thumbsup', _activityActor));
            f.session.observerAdapter.graphReadDocuments = await f
                .productionReadDocuments(operation);
            final document = f.session.observerAdapter.graphReadDocuments.keys
                .singleWhere(
                  (doc) => doc.contains(
                    isReaction
                        ? 'query MobileWorkItemActivityReactionAccess('
                        : 'query MobileWorkItemActivityEditAccess(',
                  ),
                );
            if (hadPermit) await f.prepareNoop(operation, noteId: null);
            final started = Completer<void>();
            final release = Completer<void>();
            f.server.routes['POST /install/api/graphql'] = (request) async {
              if (!delayedStream) {
                started.complete();
                await release.future;
                return f.graph(request);
              }
              Stream<Uint8List> bytes() async* {
                started.complete();
                await release.future;
                yield* f.graph(request).stream;
              }

              return ResponseBody(
                bytes(),
                200,
                headers: {
                  Headers.contentTypeHeader: ['application/json'],
                },
              );
            };
            final pending = f.session.writer.post<Object?>(
              '${f.session.instance}/api/graphql',
              data: {
                'query': document,
                'variables': {
                  'workItemId': _activityWorkItem,
                  'noteId': _activityNote51,
                  if (isReaction) 'after': null,
                },
              },
            );
            await started.future;
            await f.prepareNoop(operation, noteId: null);
            final completed = hadPermit
                ? expectLater(
                    pending,
                    throwsA(
                      isA<DioException>().having(
                        (error) => error.error,
                        'error',
                        isA<Mr7Refused>().having(
                          (error) => error.code,
                          'code',
                          'noChangeTargetUnbound',
                        ),
                      ),
                    ),
                  )
                : pending;
            release.complete();
            await completed;
            await expectLater(
              f.observeNoop(
                f.observation(
                  operation,
                  body: isReaction ? null : 'Original',
                  add: isReaction ? true : null,
                ),
                {
                  'projectId': 909,
                  'iid': 3,
                  'noteId': 51,
                  if (isReaction) ...{
                    'name': 'thumbsup',
                    'add': true,
                  } else
                    'body': 'Original',
                },
              ),
              _activityRefusal('observerMutationTarget'),
            );
            await f.session.finish();
          }
        }
      }
    },
  );

  for (final variant in [
    'matching',
    'original-witness',
    'different-text',
    'different-text-approved-witness',
  ]) {
    test('activity edited approval $variant through the real runner', () async {
      final f = Mr7ActivityFixture.create();
      final matching = variant == 'matching';
      final differentText = variant.startsWith('different-text');
      final approvedWitness = matching || variant.endsWith('approved-witness');
      final original = differentText ? 'Original' : 'Model replacement';
      final edited = differentText ? 'Approved replacement' : 'Original';
      final scenario = sandbox.Mr7Scenario(
        id: 'activity-edited-noop-$variant',
        suite: 'graphql',
        operation: 'editWorkItemActivityNote',
        variant: 'no-op',
        tier: 'T2',
        expectedMutations: 0,
        targetKind: AiTargetKind.note,
        targetKinds: {
          AiTargetKind.project,
          AiTargetKind.issue,
          AiTargetKind.note,
        },
        resource: (_) => const AiResourceRef(kind: AiResourceKind.issue, id: 3),
        utterance: (p) => 'Edit my note #51 on issue #3 in ${p.path}.',
        call: (_) => AiToolCall(
          id: 'activity-edited-noop',
          name: 'editWorkItemActivityNote',
          arguments: {
            'projectId': 909,
            'iid': 3,
            'noteId': 51,
            'body': original,
            'reason': 'Set the synthetic note text.',
          },
        ),
        paths: (_) => {'POST graphql'},
        // Exercise rejection of a stale core no-change claim separately
        // from the genuine method-level no-op in the matching case.
        freshness: differentText
            ? (_, _) async => const AiWriteFreshness(
                noChange: true,
                visibilityUnreadable: false,
                sourceVisibilityUnreadable: false,
                targetVisibility: 'private',
              )
            : null,
        noChangeObservation: (_) => f.observation(
          'editWorkItemActivityNote',
          body: approvedWitness ? edited : original,
        ),
        observe: (_, _) async => false,
        fixture: (_, _) async {
          await f.installRoutesAndBindings();
          return sandbox.Mr7ScenarioFixtures(
            graphReadDocuments: await f.productionReadDocuments(
              'editWorkItemActivityNote',
            ),
          );
        },
      );
      final receipt = await sandbox.runMr7Sandbox(
        policy: Mr7Policy.candidate,
        releaseSha: '0123456789abcdef0123456789abcdef01234567',
        session: f.session,
        scenarios: [scenario],
        confirm: (_) async => true,
        editConfirm: (proposal) async {
          expect(proposal.editableField, 'body');
          return edited;
        },
      );
      final row = (receipt['scenarios']! as List).single as Map;
      expect(
        row['edit'],
        isA<Map<Object?, Object?>>(),
        reason: jsonEncode(receipt),
      );
      expect(row['edit'], containsPair('reason', 'approvalRequired'));
      expect(row['confirmations'], hasLength(2));
      expect(row['coreNoChange'], true, reason: jsonEncode(receipt));
      expect(row['mutationCount'], 0, reason: jsonEncode(receipt));
      expect(
        row['status'],
        matching ? 'PASS' : 'NOT_VERIFIED',
        reason: jsonEncode(receipt),
      );
      if (matching) {
        expect(row['classification'], 'verifiedNoOp');
        expect(row['parentStateVerified'], true);
        expect(row['readback'], 'PASS');
        expect(row['observerRequests'], greaterThan(0));
      } else {
        expect(row['classification'], isNot('verifiedNoOp'));
        expect(row['reason'], 'noChangeUnverified');
        expect(row['readback'], 'NOT_VERIFIED');
        if (approvedWitness) {
          expect(row['parentStateVerified'], false);
          expect(row['observerRequests'], greaterThan(0));
        }
      }
      expect(f.bodies[_activityNote51], 'Original');
      expect(f.writeCount, 0);
    });
  }

  test(
    'activity no-op binds production Note preparation through the real runner',
    () async {
      for (final operation in [
        'editWorkItemActivityNote',
        'setWorkItemActivityNoteReaction',
      ]) {
        for (final variant in ['matching', 'wrong-note', 'superseded-permit']) {
          final matching = variant == 'matching';
          final f = Mr7ActivityFixture.create();
          final isReaction = operation == 'setWorkItemActivityNoteReaction';
          if (isReaction) f.awards.add(f.award('thumbsup', _activityActor));
          final scenario = sandbox.Mr7Scenario(
            id: 'activity-noop-$operation-$variant',
            suite: 'graphql',
            operation: operation,
            variant: 'no-op',
            tier: isReaction ? 'T1' : 'T2',
            expectedMutations: 0,
            targetKind: AiTargetKind.note,
            targetKinds: {
              AiTargetKind.project,
              AiTargetKind.issue,
              AiTargetKind.note,
            },
            resource: (_) =>
                const AiResourceRef(kind: AiResourceKind.issue, id: 3),
            utterance: (p) =>
                'Keep my note #51 on issue #3 in ${p.path} unchanged.',
            call: (_) => AiToolCall(
              id: 'activity-noop',
              name: operation,
              arguments: {
                'projectId': 909,
                'iid': 3,
                'noteId': 51,
                if (isReaction) ...{
                  'name': 'thumbsup',
                  'add': true,
                } else
                  'body': 'Original',
                'reason': 'Keep the synthetic note unchanged.',
              },
            ),
            paths: (_) => {'POST graphql'},
            noChangeObservation: (_) {
              if (variant == 'superseded-permit') {
                f.session.permit = Mr7MutationPermit(
                  operation: operation,
                  paths: {'POST graphql'},
                  resourceProjectId: 909,
                );
              }
              return f.observation(
                operation,
                noteId: variant == 'wrong-note'
                    ? _activityNote52
                    : _activityNote51,
                body: isReaction ? null : 'Original',
                add: isReaction ? true : null,
              );
            },
            observe: (_, _) async => false,
            fixture: (_, _) async {
              await f.installRoutesAndBindings();
              return sandbox.Mr7ScenarioFixtures(
                graphReadDocuments: await f.productionReadDocuments(operation),
              );
            },
          );
          final receipt = await sandbox.runMr7Sandbox(
            policy: Mr7Policy.candidate,
            releaseSha: '0123456789abcdef0123456789abcdef01234567',
            session: f.session,
            scenarios: [scenario],
            confirm: (_) async => true,
          );
          final row = (receipt['scenarios']! as List).single as Map;
          expect(row['coreNoChange'], true, reason: jsonEncode(receipt));
          expect(row['mutationCount'], 0, reason: jsonEncode(receipt));
          expect(
            row['status'],
            matching ? 'PASS' : 'NOT_VERIFIED',
            reason: jsonEncode(receipt),
          );
          if (matching) {
            expect(row['classification'], 'verifiedNoOp');
            expect(row['parentStateVerified'], true);
            expect(row['observerRequests'], greaterThan(0));
          } else {
            expect(row['reason'], 'noChangeUnverified');
            expect(row['classification'], isNot('verifiedNoOp'));
          }
          expect(f.writeCount, 0);
        }
      }
    },
  );
}
