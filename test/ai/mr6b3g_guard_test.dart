import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';

import 'mr6b3g_support.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';

// Independent G15 manifest. The 15 aliases share the named core methods;
// snooze and unsnooze are existing account-todo rows, not extra group aliases.
const _aliases = <String, String>{
  'updateGroupWorkItemState': 'updateWorkItemState',
  'updateGroupWorkItemStatus': 'updateWorkItemStatus',
  'updateGroupWorkItemDates': 'updateWorkItemDates',
  'updateGroupWorkItemHealthStatus': 'updateWorkItemHealthStatus',
  'updateGroupWorkItemAssignees': 'updateWorkItemAssignees',
  'updateGroupWorkItemMilestone': 'updateWorkItemMilestone',
  'updateGroupWorkItemWeight': 'updateWorkItemWeight',
  'createGroupWorkItemActivityComment': 'createWorkItemActivityComment',
  'createGroupWorkItemActivityReply': 'createWorkItemActivityReply',
  'deleteGroupWorkItemActivityNote': 'deleteWorkItemActivityNote',
  'setGroupWorkItemActivityNoteReaction': 'setWorkItemActivityNoteReaction',
  'setGroupWorkItemNotifications': 'setWorkItemNotifications',
  'updateGroupWorkItemContent': 'updateWorkItemContent',
  'editGroupWorkItemActivityNote': 'editWorkItemActivityNote',
  'updateGroupWorkItemLabels': 'updateWorkItemLabels',
};

const _familyMembers = <String, Set<String>>{
  'state': {'workItemState', 'updateWorkItemState'},
  'status': {'workItemStatus', 'updateWorkItemStatus'},
  'dates': {'workItemDates', 'updateWorkItemDates'},
  'health': {'workItemHealthEdit', 'updateWorkItemHealthStatus'},
  'assignees': {
    'workItemAssignees',
    'searchWorkItemAssigneeCandidates',
    'updateWorkItemAssignees',
  },
  'milestone_weight': {
    'workItemMilestone',
    'workItemMilestoneChoices',
    'workItemWeight',
    'updateWorkItemMilestone',
    'updateWorkItemWeight',
  },
  'activity_create': {
    'createWorkItemActivityComment',
    'createWorkItemActivityReply',
    'workItemActivity',
    'workItemActivityNext',
    'workItemActivityWriteAccess',
    'workItemDiscussionNotesNext',
  },
  'activity_delete': {
    'deleteWorkItemActivityNote',
    'workItemActivity',
    'workItemActivityDeleteAccess',
    'workItemActivityNext',
    'workItemDiscussionNotesNext',
  },
  'reactions_notifications': {
    'setWorkItemActivityNoteReaction',
    'setWorkItemNotifications',
    'workItemActivity',
    'workItemActivityNext',
    'workItemActivityReactionAccess',
    'workItemDiscussionNotesNext',
    'workItemNotifications',
  },
  'content': {'updateWorkItemContent', 'workItemContent'},
  'activity_edit': {
    'editWorkItemActivityNote',
    'workItemActivity',
    'workItemActivityEditAccess',
    'workItemActivityNext',
    'workItemDiscussionNotesNext',
  },
  'labels': {
    'updateWorkItemLabels',
    'workItemLabelCandidates',
    'workItemLabels',
  },
};

const _projectReadMembers = <String>{
  'textFile',
  'tree',
  'cachedRecord',
  'cachedRecords',
  'record',
  'records',
  'jobTraceChunk',
  'commit',
  'commitDiff',
  'search',
  'snippetText',
};

void main() {
  test('fifteen visible group rows map exactly to approved named methods', () {
    final rows = ProductionAiLedger.rows
        .where((row) => row.scopeClass == AiScopeClass.groupWorkItem)
        .toList();
    expect(rows, hasLength(15));
    expect({
      for (final row in rows) row.operationId: row.namedMethod,
    }, _aliases);
    for (final row in rows) {
      expect(row.boundary, AiWriteBoundary.graph, reason: row.operationId);
      expect(row.modelVisible, isTrue, reason: row.operationId);
      expect(row.arguments, containsPair('groupId', isA<AiArgSpec>()));
      expect(row.arguments, containsPair('iid', isA<AiArgSpec>()));
      expect(row.arguments, isNot(contains('projectId')));
    }
    expect(aiGroupWorkItemWritesEnabled, isTrue);
    expect(_aliases.keys, isNot(contains('setGroupIncidentStatus')));
    expect(_aliases.keys, isNot(contains('markTodoDone')));
    for (final name in ['snoozeTodo', 'unsnoozeTodo']) {
      expect(
        productionAiLedger.find(name)!.scopeClass,
        AiScopeClass.accountTodo,
      );
    }
  });

  test(
    'effective production gate offers every group alias but no project operations',
    () {
      expect(aiGroupWorkItemWritesEnabledForTesting, isNull);
      expect(aiGroupWorkItemWritesAreEnabled, isTrue);
      final offers = toolsForScope(
        g0eScope,
      ).map((row) => row.operationId).toSet();
      expect(offers, containsAll(_aliases.keys));
      expect(offers, containsAll(['snoozeTodo', 'unsnoozeTodo']));
      expect(offers, isNot(contains('markTodoDone')));
      expect(offers, isNot(contains('setIncidentStatus')));
      expect(offers, isNot(contains('updateWorkItemState')));
    },
  );

  test('explicit gate-off suppresses all group aliases', () {
    aiGroupWorkItemWritesEnabledForTesting = false;
    addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
    final offers = toolsForScope(
      g0eScope,
    ).map((row) => row.operationId).toSet();
    expect(offers.intersection(_aliases.keys.toSet()), isEmpty);
  });

  test(
    'group family part APIs have exact independently pinned read and write members',
    () {
      final directory = Directory('lib/core/ai/tools');
      final files = directory
          .listSync()
          .whereType<File>()
          .where(
            (file) => RegExp(
              r'gitlab_write_port_group_\w+\.dart$',
            ).hasMatch(file.path),
          )
          .toList();
      expect(files, hasLength(_familyMembers.length));
      final found = <String>{};
      for (final file in files) {
        final name = file.uri.pathSegments.last
            .replaceFirst('gitlab_write_port_group_', '')
            .replaceFirst('.dart', '');
        found.add(name);
        expect(_familyMembers, contains(name));
        final members = _members(file.readAsStringSync());
        expect(members, _familyMembers[name], reason: file.path);
        expect(
          members.intersection({
            'namespaceWorkItem',
            'graphQuery',
            'graphMutation',
            '_send',
          }),
          isEmpty,
          reason: file.path,
        );
      }
      expect(found, _familyMembers.keys.toSet());
    },
  );

  test('only group read port adds a single namespace reader', () {
    final source = File(
      'lib/core/ai/tools/gitlab_read_port.dart',
    ).readAsStringSync();
    final groupStart = source.indexOf('final class GitLabAiGroupReadPort');
    final projectStart = source.indexOf('final class GitLabAiReadPort');
    expect(groupStart, greaterThanOrEqualTo(0));
    expect(projectStart, greaterThan(groupStart));
    final group = source.substring(groupStart, projectStart);
    final project = source.substring(projectStart);
    expect(_members(group), {'namespaceWorkItem'});
    expect(_members(project), _projectReadMembers);
    expect(
      RegExp(r'_api\s*\.\s*namespaceWorkItem\s*\(').allMatches(group),
      hasLength(1),
    );
    expect(
      _members(source).intersection({'graphQuery', 'graphMutation', '_send'}),
      isEmpty,
    );
  });

  test(
    'real group read sends the fixed namespace query with only bound variables',
    () async {
      final adapter = FakeAdapter(
        (_) => jsonResponse({
          'data': {
            'namespace': {
              'id': 'gid://gitlab/Group/7',
              'fullPath': 'team/sub',
              'workItem': {
                'id': 'gid://gitlab/WorkItem/91',
                'iid': '5',
                'title': 'Group item',
                'state': 'OPEN',
                'createdAt': '2026-10-01T00:00:00Z',
                'updatedAt': '2026-10-02T00:00:00Z',
                'project': null,
                'namespace': {
                  'id': 'gid://gitlab/Group/7',
                  'fullPath': 'team/sub',
                },
                'workItemType': {
                  'id': 'gid://gitlab/WorkItems::Type/1',
                  'name': 'Task',
                },
                'widgets': <Object?>[],
              },
            },
          },
        }),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      final reader = GitLabAiGroupReadPort(
        api,
        instance: api.instance,
        actorUserId: 7,
        generation: 7,
        isCurrent: () => true,
      );
      final result = await reader.workItem(
        const AiGroupResourceScope(
          accountKey: 'https://example.com/gitlab#7',
          instanceKey: 'https://example.com/gitlab',
          groupId: 7,
          groupFullPath: 'team/sub',
          iid: 5,
          workItemGid: 'gid://gitlab/WorkItem/91',
        ),
      );
      expect(result.requestCount, 1);
      expect(adapter.requests, hasLength(1));
      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.uri, api.instance.graphQL);
      final body = request.data as Map;
      expect(body.keys.toSet(), {'query', 'variables'});
      expect(body['query'], namespaceWorkItemQuery);
      expect(body['variables'], {'path': 'team/sub', 'iid': '5'});
    },
  );

  test(
    'model cannot supply a namespace query, operation name, or variables',
    () async {
      final adapter = FakeAdapter((_) => fail('untrusted input must not send'));
      final api = testApi(adapter);
      addTearDown(api.close);
      final reader = GitLabAiGroupReadPort(
        api,
        instance: api.instance,
        actorUserId: 7,
        generation: 7,
        isCurrent: () => true,
      );
      final catalogue = AiToolCatalogue.group(
        port: reader,
        scope: const AiGroupResourceScope(
          accountKey: 'https://example.com/gitlab#7',
          instanceKey: 'https://example.com/gitlab',
          groupId: 7,
          groupFullPath: 'team/sub',
          iid: 5,
          workItemGid: 'gid://gitlab/WorkItem/91',
        ),
        redactor: Redactor(secrets: _Secrets()),
        placeholders: UploadPlaceholderTable(instance: api.instance),
      );
      for (final extra in <String, Object?>{
        'query': 'mutation Evil { destroyEverything }',
        'operationName': 'Evil',
        'variables': {'path': 'foreign'},
      }.entries) {
        final result = await catalogue.execute(
          AiToolCall(
            id: extra.key,
            name: 'get_group_work_item',
            arguments: {'groupId': 7, 'iid': 5, extra.key: extra.value},
          ),
          budget: AiToolBudget(maxGitLabRequests: 40),
        );
        expect(result.result.isError, isTrue, reason: extra.key);
        expect(result.gitLabRequests, 0, reason: extra.key);
        expect(adapter.requests, isEmpty);
      }
    },
  );
}

final class _Secrets implements KnownSecretsSource {
  @override
  Iterable<String> get current => const [];
}

Set<String> _members(String source) => RegExp(
  r'\b_api\s*\.\s*(\w+)',
).allMatches(source).map((match) => match.group(1)!).toSet();
