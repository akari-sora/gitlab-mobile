import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/exact_edit.dart' as exact;
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' show AiVisibilityContext;
import 'package:gitlab_mobile/core/instance.dart';

import '../support/fake_adapter.dart';
import 'fx_coord_support.dart';
import 'mr6b3_matrix_support.dart' show mr6b3ApiArguments;
import 'mr6b3g_support.dart' show g0eScope;
import 'p6_support.dart' show p6Args;
import 'p10_support.dart' show p10Args;

({String? blockCode, List<AiFixedConfirmReason> confirmReasons})
mr7FragmentChecker(
  port.AiTextScan scan, {
  required Set<String> knownSecrets,
  required GitLabInstance instance,
  required AiVisibilityContext visibility,
}) {
  final checked = exact.checkFragments(
    scan,
    knownSecrets: knownSecrets,
    instance: instance,
    visibility: visibility,
  );
  return (blockCode: checked.blockCode, confirmReasons: checked.confirmReasons);
}

const mr7Head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const mr7Base = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const mr7GroupScope = AiGroupResourceScope(
  accountKey: coordAccount,
  instanceKey: 'https://example.com/gitlab',
  groupId: 5,
  groupFullPath: 'fixture/group',
  iid: 3,
  workItemGid: 'gid://gitlab/WorkItem/30',
);

const mr7ReadArguments = <String, Map<String, Object?>>{
  'read_file': {'path': 'README.md', 'revision': 'head'},
  'list_directory': {'path': 'lib', 'revision': 'head'},
  'get_issue': {'iid': 3},
  'get_merge_request': {'iid': 3},
  'get_merge_request_diff': {},
  'get_pipeline_jobs': {},
  'get_job_log': {'job_id': 4},
  'get_commit': {'sha': mr7Head},
  'get_commit_diff': {'sha': mr7Head},
  'search_project': {'scope': 'issues', 'query': 'synthetic'},
  'get_release': {'tag_name': 'v1'},
  'get_milestone': {'milestone_id': 7},
  'get_snippet': {'snippet_id': 7},
  'get_group_work_item': {'groupId': 5, 'iid': 3},
};

AiResourceScope mr7ReadScope(String name) => AiResourceScope(
  accountKey: coordAccount,
  instanceKey: 'https://example.com/gitlab',
  projectId: 9,
  projectPath: 'team/example-9',
  current: AiResourceRef(
    kind: switch (name) {
      'get_merge_request' ||
      'get_merge_request_diff' => AiResourceKind.mergeRequest,
      'get_pipeline_jobs' || 'get_job_log' => AiResourceKind.job,
      'read_file' || 'list_directory' => AiResourceKind.file,
      _ => AiResourceKind.issue,
    },
    id: name == 'get_pipeline_jobs' || name == 'get_job_log' ? 4 : 3,
  ),
  headSha: mr7Head,
  baseSha: mr7Base,
  pipelineId: 8,
  jobId: 4,
);

/// Synthetic responses through the real read ports; unexpected paths fail.
FakeAdapter mr7ReadAdapter() => FakeAdapter((request) {
  final path = request.uri.path;
  if (path.endsWith('/api/graphql')) {
    return jsonResponse({
      'data': {
        'namespace': {
          'id': 'gid://gitlab/Group/5',
          'fullPath': 'fixture/group',
          'workItem': {
            'id': mr7GroupScope.workItemGid,
            'iid': '3',
            'title': 'Synthetic group item',
            'state': 'OPEN',
            'createdAt': '2026-10-01T00:00:00Z',
            'updatedAt': '2026-10-02T00:00:00Z',
            'project': null,
            'namespace': {
              'id': 'gid://gitlab/Group/5',
              'fullPath': 'fixture/group',
            },
            'workItemType': {
              'id': 'gid://gitlab/WorkItems::Type/1',
              'name': 'Task',
            },
            'widgets': [
              {
                'type': 'DESCRIPTION',
                'description': 'Synthetic description',
                'edited': false,
              },
            ],
          },
        },
      },
    });
  }
  if (request.method == 'HEAD') {
    return ResponseBody.fromString(
      '',
      200,
      headers: const {
        'x-gitlab-size': ['4'],
      },
    );
  }
  if (path.endsWith('/raw')) {
    return ResponseBody.fromString('file', 200);
  }
  if (path.endsWith('/repository/tree')) {
    return jsonResponse([
      {'name': 'a.dart', 'path': 'lib/a.dart', 'type': 'blob'},
    ]);
  }
  if (path.endsWith('/notes') ||
      path.endsWith('/jobs') ||
      path.endsWith('/diff') ||
      path.endsWith('/search')) {
    return jsonResponse(<Object?>[]);
  }
  if (path.endsWith('/versions')) {
    return jsonResponse([
      {'id': 5, 'head_commit_sha': mr7Head, 'base_commit_sha': mr7Base},
    ]);
  }
  if (path.endsWith('/versions/5')) {
    return jsonResponse({
      'head_commit_sha': mr7Head,
      'base_commit_sha': mr7Base,
      'diffs': <Object?>[],
    });
  }
  if (path.endsWith('/jobs/4/trace')) {
    return ResponseBody.fromString(
      'trace',
      200,
      headers: const {
        'x-gitlab-trace-eof': ['true'],
      },
    );
  }
  if (path.contains('/repository/commits/')) {
    return jsonResponse({'id': mr7Head, 'title': 'Commit'});
  }
  if (path.endsWith('/releases/v1')) {
    return jsonResponse({'tag_name': 'v1', 'description': 'Release'});
  }
  if (path.endsWith('/milestones/7')) {
    return jsonResponse({
      'id': 7,
      'iid': 2,
      'project_id': 9,
      'description': 'Milestone',
    });
  }
  if (path.endsWith('/snippets/7')) {
    return jsonResponse({
      'id': 7,
      'project_id': 9,
      'visibility': 'public',
      'files': [
        {'path': 'a.txt'},
      ],
    });
  }
  if (path.endsWith('/issues/3') || path.endsWith('/merge_requests/3')) {
    return jsonResponse({'iid': 3, 'title': 'Resource'});
  }
  throw StateError('Unexpected read: ${request.method} $path');
});

/// Existing port-family success payloads (ai_write_port, refs and project).
const _t12Arguments = <String, Map<String, Object?>>{
  'setStar': {'starred': true},
  'setSubscribed': {'resource': 'issues', 'iid': 3, 'subscribed': true},
  'markTodoDone': {'todoId': 18},
  'addAwardEmoji': {'resource': 'issues', 'iid': 3, 'name': 'thumbsup'},
  'removeAwardEmoji': {'resource': 'issues', 'iid': 3, 'awardId': 8},
  'createNote': {'resource': 'issues', 'iid': 3, 'body': 'synthetic'},
  'updateNote': {
    'resource': 'issues',
    'iid': 3,
    'noteId': 8,
    'body': 'synthetic',
  },
  'createIssue': {
    'fields': {'title': 'synthetic'},
  },
  'updateIssue': {
    'iid': 3,
    'fields': {'title': 'synthetic'},
  },
  'createMergeRequest': {
    'fields': {
      'title': 'synthetic',
      'source_branch': 'feature',
      'target_branch': 'main',
    },
  },
  'updateMergeRequest': {
    'iid': 3,
    'fields': {'title': 'synthetic'},
  },
  'unapproveMergeRequest': {'iid': 3},
  'createTodo': {'resource': 'issues', 'iid': 3},
  'createDiscussion': {
    'resource': 'merge_requests',
    'iid': 3,
    'body': 'synthetic',
  },
  'createDiscussionNote': {
    'resource': 'merge_requests',
    'iid': 3,
    'discussionId': 'abc',
    'body': 'synthetic',
  },
  'updateDiscussionNote': {
    'resource': 'merge_requests',
    'iid': 3,
    'discussionId': 'abc',
    'noteId': 8,
    'body': 'synthetic',
  },
  'setDiscussionResolved': {
    'resource': 'merge_requests',
    'iid': 3,
    'discussionId': 'abc',
    'resolved': true,
  },
  'createDraftNote': {'iid': 3, 'body': 'synthetic'},
  'updateDraftNote': {'iid': 3, 'noteId': 8, 'body': 'synthetic'},
  'createLabel': {
    'fields': {'name': 'synthetic', 'color': '#ffffff'},
  },
  'updateLabel': {
    'labelId': 8,
    'fields': {'color': '#000000'},
  },
  'createMilestone': {
    'fields': {'title': 'synthetic'},
  },
  'updateMilestone': {
    'milestoneId': 8,
    'fields': {'title': 'synthetic'},
  },
  'setMilestoneState': {'milestoneId': 8, 'stateEvent': 'close'},
  'createBoard': {'name': 'synthetic'},
  'renameBoard': {'boardId': 8, 'name': 'synthetic'},
  'setBoardSystemListHidden': {'boardId': 8, 'list': 'closed', 'hidden': true},
  'createBoardList': {'boardId': 8, 'labelId': 8},
  'moveBoardList': {'boardId': 8, 'listId': 8, 'position': 0},
  'moveBoardCard': {
    'iid': 3,
    'fields': {'labels': 'synthetic'},
  },
};
const _refArguments = <String, Map<String, Object?>>{
  'createBranch': {'projectId': 9, 'branch': 'feature/new', 'ref': 'main'},
  'deleteBranch': {'projectId': 9, 'branch': 'feature/old'},
  'createTag': {
    'projectId': 9,
    'tag_name': 'v2/test',
    'ref': 'main',
    'message': '  /release\n@all  ',
  },
  'deleteTag': {'projectId': 9, 'tag_name': 'v1'},
  'createRelease': {
    'projectId': 9,
    'fields': {
      'tag_name': 'v1',
      'name': 'Version One',
      'description': '  /release\nNotes  ',
    },
  },
  'updateRelease': {
    'projectId': 9,
    'tag_name': 'v1',
    'fields': {'name': 'Revised', 'description': '  /release\nRevised  '},
  },
  'deleteRelease': {'projectId': 9, 'tag_name': 'v1'},
};
const _projectArguments = <String, Map<String, Object?>>{
  'deletePackage': {'projectId': 9, 'packageId': 4},
  'deletePackageFile': {'projectId': 9, 'packageId': 4, 'fileId': 8},
  'deleteContainerRepository': {'projectId': 9, 'repositoryId': 5},
  'deleteContainerTag': {'projectId': 9, 'repositoryId': 5, 'tag': 'v1'},
  'createProject': {
    'name': 'New project',
    'path': 'new-project',
    'description': 'new description',
  },
  'editProject': {
    'projectId': 9,
    'name': 'Edited project',
    'description': 'edited description',
  },
  'deleteProject': {'projectId': 9},
  'forkProject': {'projectId': 9},
};

final mr7WriteArguments = <String, Map<String, Object?>>{
  for (final entry in _t12Arguments.entries)
    entry.key: {
      if (entry.key != 'markTodoDone') 'projectId': 9,
      ...entry.value,
    },
  ..._refArguments,
  ..._projectArguments,
  for (final row in aiFileRows) row.operationId: p6Args(row.operationId),
  for (final row in aiSnippetRows) row.operationId: p10Args(row.operationId),
  for (final row in aiMergeRows)
    row.operationId: {
      'projectId': 9,
      'iid': 3,
      if (row.operationId == 'deleteDraftNote') 'noteId': 8,
    },
  'createPipeline': {'projectId': 9, 'ref': 'feature/test'},
  'pipelineAction': {'projectId': 9, 'pipelineId': 12, 'action': 'retry'},
  'jobAction': {'projectId': 9, 'jobId': 21, 'action': 'retry'},
  'playPipelineSchedule': {'projectId': 9, 'scheduleId': 4},
  'deletePipeline': {'projectId': 9, 'pipelineId': 12},
  'deleteNote': {'projectId': 9, 'resource': 'issues', 'iid': 3, 'noteId': 8},
  'deleteDiscussionNote': {
    'projectId': 9,
    'resource': 'merge_requests',
    'iid': 3,
    'discussionId': 'abc',
    'noteId': 8,
  },
  'deleteIssue': {'projectId': 9, 'iid': 3},
  'deleteMergeRequest': {'projectId': 9, 'iid': 3},
  'deleteLabel': {'projectId': 9, 'labelId': 8},
  'deleteMilestone': {'projectId': 9, 'milestoneId': 8},
  'deleteBoard': {'projectId': 9, 'boardId': 8},
  'deleteBoardList': {'projectId': 9, 'boardId': 8, 'listId': 6},
  'markAllTodosDone': {},
  'upload_attachment': {'projectId': 9, 'attachmentId': 'att-1'},
  for (final row in ProductionAiLedger.rows.where(
    (row) => row.boundary == AiWriteBoundary.graph,
  ))
    row.operationId: _graphArguments(row.operationId),
};

Map<String, Object?> _graphArguments(String operation) {
  final projectOperation = operation.replaceFirst('GroupWorkItem', 'WorkItem');
  final arguments = switch (projectOperation) {
    'updateWorkItemContent' => {
      'projectId': 9,
      'iid': 3,
      'title': 'Synthetic title',
    },
    'updateWorkItemLabels' => {
      'projectId': 9,
      'iid': 3,
      'labels': ['next'],
    },
    'editWorkItemActivityNote' => {
      'projectId': 9,
      'iid': 3,
      'noteId': 401,
      'body': 'Edited synthetic note',
    },
    _ => mr6b3ApiArguments(projectOperation),
  };
  return operation == projectOperation
      ? arguments
      : {
          for (final entry in arguments.entries)
            if (entry.key != 'projectId') entry.key: entry.value,
          'groupId': 7,
          'iid': 5,
        };
}

AiToolCall mr7WriteCall(String operation) => operation == 'setStar'
    ? starCall(operation)
    : AiToolCall(
        id: operation,
        name: operation,
        arguments: {
          ...mr7WriteArguments[operation]!,
          'reason': 'Requested synthetic action.',
        },
      );

AiWriteScope mr7WriteScope(AiCapability row) => switch (row.scopeClass) {
  AiScopeClass.groupWorkItem => g0eScope,
  AiScopeClass.accountGlobalOnly => const AiWriteScope(
    accountKey: coordAccount,
    grants: [AiScopeGrant(kind: AiScopeKind.accountGlobal)],
  ),
  _ => coordScope,
};

/// Stops at the prepare boundary: family suites own server preflight/commit.
/// Counting actual entry proves the payload passed proposal validation, scope,
/// tier, budget, attachment, freshness and text checks before opening a port.
final class Mr7WriteProbe implements port.AiGitLabWritePort {
  final requests = <port.AiWriteRequest>[];

  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) async {
    requests.add(request);
    throw StateError('Synthetic prepare boundary reached');
  }

  @override
  Future<port.AiWriteSettled> commit(
    port.AiWritePrepared prepared, {
    required bool Function() mayStart,
    Future<void> Function()? beforeMutation,
  }) async => throw StateError('Proposal-only probe cannot commit');
}
