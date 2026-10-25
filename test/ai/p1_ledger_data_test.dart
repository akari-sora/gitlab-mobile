import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';

const _baselineOperations = <String>{
  'addAwardEmoji',
  'removeAwardEmoji',
  'setStar',
  'setSubscribed',
  'markTodoDone',
  'createNote',
  'updateNote',
  'createIssue',
  'updateIssue',
  'createMergeRequest',
  'updateMergeRequest',
  'unapproveMergeRequest',
  'createTodo',
  'createDiscussion',
  'createDiscussionNote',
  'updateDiscussionNote',
  'setDiscussionResolved',
  'createDraftNote',
  'updateDraftNote',
  'createLabel',
  'updateLabel',
  'createMilestone',
  'updateMilestone',
  'setMilestoneState',
  'createBoard',
  'renameBoard',
  'setBoardSystemListHidden',
  'createBoardList',
  'moveBoardList',
  'moveBoardCard',
  'upload_attachment',
};

const _mr6b3Operations = <String>{
  'createWorkItemActivityComment',
  'createWorkItemActivityReply',
  'deleteWorkItemActivityNote',
  'updateWorkItemAssignees',
  'updateWorkItemDates',
  'updateWorkItemHealthStatus',
  'updateWorkItemMilestone',
  'updateWorkItemWeight',
  'updateWorkItemState',
  'updateWorkItemStatus',
  'setIncidentStatus',
  'setWorkItemNotifications',
  'setWorkItemActivityNoteReaction',
  'snoozeTodo',
  'unsnoozeTodo',
};

const _mr6b2Operations = <String>{
  'edit_file',
  'createFile',
  'deleteFile',
  'applySuggestion',
  'createBranch',
  'deleteBranch',
  'createTag',
  'deleteTag',
  'createRelease',
  'updateRelease',
  'deleteRelease',
  'mergeRequest',
  'approveMergeRequest',
  'rebaseMergeRequest',
  'cancelAutoMerge',
  'publishDraftNotes',
  'deleteDraftNote',
  'createPipeline',
  'pipelineAction',
  'jobAction',
  'playPipelineSchedule',
  'deletePipeline',
  'createSnippet',
  'updateSnippetMetadata',
  'updateSnippet',
  'updateSnippetFiles',
  'deleteSnippetFile',
  'deleteSnippet',
  'deleteNote',
  'deleteDiscussionNote',
  'deleteIssue',
  'deleteMergeRequest',
  'deleteLabel',
  'deleteMilestone',
  'deleteBoard',
  'deleteBoardList',
  'markAllTodosDone',
  'deletePackage',
  'deletePackageFile',
  'deleteContainerRepository',
  'deleteContainerTag',
  'createProject',
  'editProject',
  'deleteProject',
  'forkProject',
};

void main() {
  test('the ledger exposes exactly the MR6b-1, MR6b-2 and MR6b-3 rows', () {
    expect(
      productionAiLedger.modelVisible.map((row) => row.operationId).toSet(),
      {..._baselineOperations, ..._mr6b2Operations, ..._mr6b3Operations},
    );
    expect(
      ProductionAiLedger.rows.map((row) => row.operationId).toSet(),
      hasLength(ProductionAiLedger.rows.length),
    );
  });

  test('argument names merge coordinator and port metadata without reason', () {
    const expected = <String, Set<String>>{
      'setStar': {'projectId', 'starred'},
      'setSubscribed': {'projectId', 'resource', 'iid', 'subscribed'},
      'markTodoDone': {'todoId'},
      'addAwardEmoji': {'projectId', 'resource', 'iid', 'name', 'noteId'},
      'removeAwardEmoji': {'projectId', 'resource', 'iid', 'awardId', 'noteId'},
      'createNote': {'projectId', 'resource', 'iid', 'body'},
      'updateNote': {'projectId', 'resource', 'iid', 'noteId', 'body'},
      'createIssue': {'projectId', 'fields'},
      'updateIssue': {'projectId', 'iid', 'fields'},
      'createMergeRequest': {'projectId', 'fields'},
      'updateMergeRequest': {'projectId', 'iid', 'fields'},
      'unapproveMergeRequest': {'projectId', 'iid'},
      'createTodo': {'projectId', 'resource', 'iid'},
      'createDiscussion': {'projectId', 'resource', 'iid', 'body', 'position'},
      'createDiscussionNote': {
        'projectId',
        'resource',
        'iid',
        'discussionId',
        'body',
      },
      'updateDiscussionNote': {
        'projectId',
        'resource',
        'iid',
        'discussionId',
        'noteId',
        'body',
      },
      'setDiscussionResolved': {
        'projectId',
        'resource',
        'iid',
        'discussionId',
        'resolved',
      },
      'createDraftNote': {'projectId', 'iid', 'body', 'commitId', 'position'},
      'updateDraftNote': {'projectId', 'iid', 'noteId', 'body'},
      'createLabel': {'projectId', 'fields'},
      'updateLabel': {'projectId', 'labelId', 'fields'},
      'createMilestone': {'projectId', 'fields'},
      'updateMilestone': {'projectId', 'milestoneId', 'fields'},
      'setMilestoneState': {'projectId', 'milestoneId', 'stateEvent'},
      'createBoard': {'projectId', 'name'},
      'renameBoard': {'projectId', 'boardId', 'name'},
      'setBoardSystemListHidden': {'projectId', 'boardId', 'list', 'hidden'},
      'createBoardList': {'projectId', 'boardId', 'labelId'},
      'moveBoardList': {'projectId', 'boardId', 'listId', 'position'},
      'moveBoardCard': {'projectId', 'iid', 'fields'},
      'upload_attachment': {
        'projectId',
        'attachmentId',
        'filename',
        'contentType',
      },
    };
    expect(<String, Set<String>>{
      for (final row in ProductionAiLedger.rows)
        if (expected.containsKey(row.operationId))
          row.operationId: row.arguments.keys.toSet(),
    }, expected);
    for (final row in ProductionAiLedger.rows) {
      expect(row.arguments, isNot(contains('reason')), reason: row.operationId);
    }
  });

  test('nested fields and diff positions are closed ledger shapes', () {
    expect(
      productionAiLedger
          .find('createIssue')!
          .arguments['fields']!
          .properties
          .keys
          .toSet(),
      {
        'title',
        'description',
        'labels',
        'assignee_ids',
        'milestone_id',
        'confidential',
        'issue_type',
        'severity',
      },
    );
    expect(
      productionAiLedger
          .find('createDiscussion')!
          .arguments['position']!
          .properties
          .keys
          .toSet(),
      {
        'position_type',
        'base_sha',
        'start_sha',
        'head_sha',
        'old_path',
        'new_path',
        'old_line',
        'new_line',
      },
    );
  });

  test('upload union retains separate model and port whitelists', () {
    final arguments = productionAiLedger.find('upload_attachment')!.arguments;
    expect(arguments['attachmentId']!.modelVisible, isTrue);
    expect(arguments['attachmentId']!.portVisible, isFalse);
    expect(arguments['filename']!.modelVisible, isFalse);
    expect(arguments['filename']!.portVisible, isTrue);
    expect(arguments['contentType']!.modelVisible, isFalse);
    expect(arguments['contentType']!.portVisible, isTrue);
  });

  test('required nested fields match create and update validation', () {
    Map<String, AiArgSpec> fields(String operation) =>
        productionAiLedger.find(operation)!.arguments['fields']!.properties;

    expect(fields('createIssue')['title']!.required, isTrue);
    expect(fields('updateIssue')['title']!.required, isFalse);
    expect(fields('createMergeRequest')['title']!.required, isTrue);
    expect(fields('createMergeRequest')['source_branch']!.required, isTrue);
    expect(fields('createMergeRequest')['target_branch']!.required, isTrue);
    expect(fields('updateMergeRequest')['title']!.required, isFalse);
    expect(fields('createLabel')['name']!.required, isTrue);
    expect(fields('createLabel')['color']!.required, isTrue);
    expect(fields('updateLabel')['name']!.required, isFalse);
    expect(fields('updateLabel')['color']!.required, isFalse);
    expect(fields('createMilestone')['title']!.required, isTrue);
    expect(fields('updateMilestone')['title']!.required, isFalse);
  });

  test('argument kinds and writable-field mappings are declarative', () {
    AiArgSpec argument(String operation, String name) =>
        productionAiLedger.find(operation)!.arguments[name]!;
    AiArgSpec field(String operation, String name) => productionAiLedger
        .find(operation)!
        .arguments['fields']!
        .properties[name]!;

    expect(argument('setStar', 'projectId').type, AiArgType.integer);
    expect(argument('setStar', 'starred').type, AiArgType.boolean);
    expect(argument('createIssue', 'fields').type, AiArgType.object);
    expect(field('createIssue', 'assignee_ids').type, AiArgType.integerList);
    expect(argument('createDiscussion', 'position').type, AiArgType.object);
    expect(argument('moveBoardList', 'position').type, AiArgType.integer);
    expect(
      field('createIssue', 'description').writableField,
      'issueDescription',
    );
    expect(
      field('createMergeRequest', 'description').writableField,
      'mergeRequestDescription',
    );
    expect(argument('createNote', 'body').writableField, 'note');
    expect(argument('createDiscussion', 'body').writableField, 'discussion');
    expect(
      field('createMilestone', 'description').writableField,
      'milestoneDescription',
    );
  });

  test('editable fields identify the card replaceable text', () {
    expect(
      <String, String>{
        for (final row in ProductionAiLedger.rows)
          if (_baselineOperations.contains(row.operationId) &&
              row.editableField != null)
            row.operationId: row.editableField!,
      },
      <String, String>{
        'createNote': 'body',
        'updateNote': 'body',
        'createIssue': 'description',
        'updateIssue': 'description',
        'createMergeRequest': 'description',
        'updateMergeRequest': 'description',
        'createDiscussion': 'body',
        'createDiscussionNote': 'body',
        'updateDiscussionNote': 'body',
        'createDraftNote': 'body',
        'updateDraftNote': 'body',
        'createLabel': 'description',
        'updateLabel': 'description',
        'createMilestone': 'description',
        'updateMilestone': 'description',
        'createBoard': 'name',
        'renameBoard': 'name',
      },
    );
  });

  test('HTTP caps are the independently counted OAuth worst cases', () {
    const expected = <String, int>{
      'setStar': 13,
      'setSubscribed': 21,
      'markTodoDone': 21,
      'addAwardEmoji': 25,
      'removeAwardEmoji': 29,
      'createNote': 23,
      'updateNote': 27,
      'createIssue': 15,
      'updateIssue': 23,
      'createMergeRequest': 15,
      'updateMergeRequest': 23,
      'unapproveMergeRequest': 21,
      'createTodo': 21,
      'createDiscussion': 25,
      'createDiscussionNote': 27,
      'updateDiscussionNote': 27,
      'setDiscussionResolved': 27,
      'createDraftNote': 25,
      'updateDraftNote': 27,
      'createLabel': 13,
      'updateLabel': 23,
      'createMilestone': 13,
      'updateMilestone': 23,
      'setMilestoneState': 23,
      'createBoard': 13,
      'renameBoard': 21,
      'setBoardSystemListHidden': 21,
      'createBoardList': 21,
      'moveBoardList': 25,
      'moveBoardCard': 23,
      'upload_attachment': 13,
    };
    expect(<String, int>{
      for (final row in ProductionAiLedger.rows)
        if (expected.containsKey(row.operationId)) row.operationId: row.httpCap,
    }, expected);
  });

  test('readback flags match the existing port callbacks', () {
    const expected = <String>{
      'createIssue',
      'updateIssue',
      'createMergeRequest',
      'updateMergeRequest',
      'createNote',
      'updateNote',
      'createDiscussionNote',
      'updateDiscussionNote',
      'setDiscussionResolved',
      'updateDraftNote',
      'updateLabel',
      'updateMilestone',
      'setMilestoneState',
      'moveBoardCard',
    };
    expect(
      ProductionAiLedger.rows
          .where(
            (row) =>
                _baselineOperations.contains(row.operationId) && row.readback,
          )
          .map((row) => row.operationId)
          .toSet(),
      expected,
    );
  });

  test('text roles distinguish quick actions and rendered markdown', () {
    AiArgSpec field(String operation, String name) => productionAiLedger
        .find(operation)!
        .arguments['fields']!
        .properties[name]!;

    expect(
      productionAiLedger.find('createNote')!.arguments['body']!.text,
      AiTextRole.quickActionMarkdown,
    );
    expect(
      field('createIssue', 'description').text,
      AiTextRole.quickActionMarkdown,
    );
    expect(
      field('createMergeRequest', 'description').text,
      AiTextRole.quickActionMarkdown,
    );
    expect(
      field('createLabel', 'description').text,
      AiTextRole.renderedMarkdown,
    );
    expect(
      field('createMilestone', 'description').text,
      AiTextRole.renderedMarkdown,
    );
  });

  test('named methods stay in the approved T1/T2 method set', () {
    const approved = <String>{
      'addAwardEmoji',
      'removeAwardEmoji',
      'setStar',
      'setSubscribed',
      'markTodoDone',
      'createNote',
      'updateNote',
      'createIssue',
      'updateIssue',
      'createMergeRequest',
      'updateMergeRequest',
      'unapproveMergeRequest',
      'createTodo',
      'createDiscussion',
      'createDiscussionNote',
      'updateDiscussionNote',
      'setDiscussionResolved',
      'createDraftNote',
      'updateDraftNote',
      'createLabel',
      'updateLabel',
      'createMilestone',
      'updateMilestone',
      'setMilestoneState',
      'createBoard',
      'renameBoard',
      'setBoardSystemListHidden',
      'createBoardList',
      'moveBoardList',
      'moveBoardCard',
      'uploadProjectFile',
    };
    for (final row in ProductionAiLedger.rows) {
      if (!_baselineOperations.contains(row.operationId)) continue;
      expect(approved, contains(row.namedMethod), reason: row.operationId);
    }
  });
}
