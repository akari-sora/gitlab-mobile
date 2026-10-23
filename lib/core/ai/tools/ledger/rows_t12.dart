part of '../write_ledger.dart';

const _projectId = AiArgSpec(AiArgType.integer, required: true);
const _iid = AiArgSpec(AiArgType.integer, required: true);
const _integer = AiArgSpec(AiArgType.integer);
const _requiredString = AiArgSpec(AiArgType.string, required: true);
const _requiredResource = AiArgSpec(
  AiArgType.string,
  required: true,
  enumValues: ['issues', 'merge_requests'],
);
const _string = AiArgSpec(AiArgType.string);
const _requiredBoolean = AiArgSpec(AiArgType.boolean, required: true);
const _integerList = AiArgSpec(AiArgType.integerList);
const _plain = AiArgSpec(AiArgType.string, text: AiTextRole.plainContent);
const _requiredPlain = AiArgSpec(
  AiArgType.string,
  required: true,
  text: AiTextRole.plainContent,
);
const _rendered = AiArgSpec(
  AiArgType.string,
  text: AiTextRole.renderedMarkdown,
);
const _pathOrRef = AiArgSpec(AiArgType.string, text: AiTextRole.pathOrRef);
const _requiredPathOrRef = AiArgSpec(
  AiArgType.string,
  required: true,
  text: AiTextRole.pathOrRef,
);

const _positionProperties = <String, AiArgSpec>{
  'position_type': _requiredString,
  'base_sha': _requiredPathOrRef,
  'start_sha': _requiredPathOrRef,
  'head_sha': _requiredPathOrRef,
  'old_path': _requiredPathOrRef,
  'new_path': _requiredPathOrRef,
  'old_line': _integer,
  'new_line': _integer,
};

const _issueFields = <String, AiArgSpec>{
  'title': _requiredPlain,
  'description': AiArgSpec(
    AiArgType.string,
    text: AiTextRole.quickActionMarkdown,
    writableField: 'issueDescription',
  ),
  'labels': _plain,
  'assignee_ids': _integerList,
  'milestone_id': _integer,
  'confidential': AiArgSpec(AiArgType.boolean),
  'issue_type': _string,
  'severity': _string,
};

const _issueUpdateFields = <String, AiArgSpec>{
  'title': _plain,
  'description': AiArgSpec(
    AiArgType.string,
    text: AiTextRole.quickActionMarkdown,
    writableField: 'issueDescription',
  ),
  'labels': _plain,
  'assignee_ids': _integerList,
  'milestone_id': _integer,
  'confidential': AiArgSpec(AiArgType.boolean),
  'severity': _string,
  'state_event': _string,
};

const _mergeRequestFields = <String, AiArgSpec>{
  'title': _requiredPlain,
  'description': AiArgSpec(
    AiArgType.string,
    text: AiTextRole.quickActionMarkdown,
    writableField: 'mergeRequestDescription',
  ),
  'labels': _plain,
  'assignee_ids': _integerList,
  'milestone_id': _integer,
  'reviewer_ids': _integerList,
  'source_branch': _requiredPathOrRef,
  'target_branch': _requiredPathOrRef,
};

const _mergeRequestUpdateFields = <String, AiArgSpec>{
  'title': _plain,
  'description': AiArgSpec(
    AiArgType.string,
    text: AiTextRole.quickActionMarkdown,
    writableField: 'mergeRequestDescription',
  ),
  'labels': _plain,
  'assignee_ids': _integerList,
  'milestone_id': _integer,
  'reviewer_ids': _integerList,
  'state_event': _string,
};

const _createLabelFields = <String, AiArgSpec>{
  'name': _requiredPlain,
  'color': _requiredString,
  'description': _rendered,
};

const _updateLabelFields = <String, AiArgSpec>{
  'name': _plain,
  'color': _string,
  'description': _rendered,
};

const _createMilestoneFields = <String, AiArgSpec>{
  'title': _requiredPlain,
  'description': AiArgSpec(
    AiArgType.string,
    text: AiTextRole.renderedMarkdown,
    writableField: 'milestoneDescription',
  ),
  'due_date': _string,
  'start_date': _string,
};

const _updateMilestoneFields = <String, AiArgSpec>{
  'title': _plain,
  'description': AiArgSpec(
    AiArgType.string,
    text: AiTextRole.renderedMarkdown,
    writableField: 'milestoneDescription',
  ),
  'due_date': _string,
  'start_date': _string,
};

const List<AiCapability> aiT12Rows = <AiCapability>[
  AiCapability(
    operationId: 'addAwardEmoji',
    baseTier: AiWriteTier.t1,
    scopeClass: AiScopeClass.resource,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'resource': _requiredResource,
      'iid': _iid,
      'name': _requiredString,
      'noteId': _integer,
    },
    httpCap: 25,
  ),
  AiCapability(
    operationId: 'removeAwardEmoji',
    baseTier: AiWriteTier.t1,
    scopeClass: AiScopeClass.resource,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'resource': _requiredResource,
      'iid': _iid,
      'awardId': AiArgSpec(AiArgType.integer, required: true),
      'noteId': _integer,
    },
    httpCap: 29,
  ),
  AiCapability(
    operationId: 'setStar',
    baseTier: AiWriteTier.t1,
    scopeClass: AiScopeClass.project,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'starred': _requiredBoolean,
    },
    httpCap: 13,
  ),
  AiCapability(
    operationId: 'setSubscribed',
    baseTier: AiWriteTier.t1,
    scopeClass: AiScopeClass.resource,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'resource': _requiredResource,
      'iid': _iid,
      'subscribed': _requiredBoolean,
    },
    httpCap: 21,
  ),
  AiCapability(
    operationId: 'markTodoDone',
    baseTier: AiWriteTier.t1,
    scopeClass: AiScopeClass.accountTodo,
    arguments: <String, AiArgSpec>{
      'todoId': AiArgSpec(AiArgType.integer, required: true),
    },
    httpCap: 21,
  ),
  AiCapability(
    operationId: 'createNote',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.resource,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'resource': _requiredResource,
      'iid': _iid,
      'body': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'note',
      ),
    },
    httpCap: 23,
    readback: true,
    editableField: 'body',
  ),
  AiCapability(
    operationId: 'updateNote',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.resource,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'resource': _requiredResource,
      'iid': _iid,
      'noteId': AiArgSpec(AiArgType.integer, required: true),
      'body': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'note',
      ),
    },
    httpCap: 27,
    readback: true,
    editableField: 'body',
  ),
  AiCapability(
    operationId: 'createIssue',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'fields': AiArgSpec(
        AiArgType.object,
        required: true,
        properties: _issueFields,
      ),
    },
    httpCap: 15,
    readback: true,
    editableField: 'description',
  ),
  AiCapability(
    operationId: 'updateIssue',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'iid': _iid,
      'fields': AiArgSpec(
        AiArgType.object,
        required: true,
        properties: _issueUpdateFields,
      ),
    },
    httpCap: 23,
    readback: true,
    editableField: 'description',
  ),
  AiCapability(
    operationId: 'createMergeRequest',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'fields': AiArgSpec(
        AiArgType.object,
        required: true,
        properties: _mergeRequestFields,
      ),
    },
    httpCap: 15,
    readback: true,
    editableField: 'description',
  ),
  AiCapability(
    operationId: 'updateMergeRequest',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.mergeRequest,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'iid': _iid,
      'fields': AiArgSpec(
        AiArgType.object,
        required: true,
        properties: _mergeRequestUpdateFields,
      ),
    },
    httpCap: 23,
    readback: true,
    editableField: 'description',
  ),
  AiCapability(
    operationId: 'unapproveMergeRequest',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.mergeRequest,
    arguments: <String, AiArgSpec>{'projectId': _projectId, 'iid': _iid},
    httpCap: 21,
  ),
  AiCapability(
    operationId: 'createTodo',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.resource,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'resource': _requiredResource,
      'iid': _iid,
    },
    httpCap: 21,
  ),
  AiCapability(
    operationId: 'createDiscussion',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.resource,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'resource': _requiredResource,
      'iid': _iid,
      'body': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'discussion',
      ),
      'position': AiArgSpec(AiArgType.object, properties: _positionProperties),
    },
    httpCap: 25,
    editableField: 'body',
  ),
  AiCapability(
    operationId: 'createDiscussionNote',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.resource,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'resource': _requiredResource,
      'iid': _iid,
      'discussionId': _requiredString,
      'body': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'discussion',
      ),
    },
    httpCap: 27,
    readback: true,
    editableField: 'body',
  ),
  AiCapability(
    operationId: 'updateDiscussionNote',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.resource,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'resource': _requiredResource,
      'iid': _iid,
      'discussionId': _requiredString,
      'noteId': AiArgSpec(AiArgType.integer, required: true),
      'body': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'discussion',
      ),
    },
    httpCap: 27,
    readback: true,
    editableField: 'body',
  ),
  AiCapability(
    operationId: 'setDiscussionResolved',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.resource,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'resource': _requiredResource,
      'iid': _iid,
      'discussionId': _requiredString,
      'resolved': _requiredBoolean,
    },
    httpCap: 27,
    readback: true,
  ),
  AiCapability(
    operationId: 'createDraftNote',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.mergeRequest,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'iid': _iid,
      'body': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'discussion',
      ),
      'commitId': _pathOrRef,
      'position': AiArgSpec(AiArgType.object, properties: _positionProperties),
    },
    httpCap: 25,
    editableField: 'body',
  ),
  AiCapability(
    operationId: 'updateDraftNote',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.mergeRequest,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'iid': _iid,
      'noteId': AiArgSpec(AiArgType.integer, required: true),
      'body': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.quickActionMarkdown,
        writableField: 'discussion',
      ),
    },
    httpCap: 27,
    readback: true,
    editableField: 'body',
  ),
  AiCapability(
    operationId: 'createLabel',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'fields': AiArgSpec(
        AiArgType.object,
        required: true,
        properties: _createLabelFields,
      ),
    },
    httpCap: 13,
    editableField: 'description',
  ),
  AiCapability(
    operationId: 'updateLabel',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'labelId': AiArgSpec(AiArgType.integer, required: true),
      'fields': AiArgSpec(
        AiArgType.object,
        required: true,
        properties: _updateLabelFields,
      ),
    },
    httpCap: 23,
    readback: true,
    editableField: 'description',
  ),
  AiCapability(
    operationId: 'createMilestone',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'fields': AiArgSpec(
        AiArgType.object,
        required: true,
        properties: _createMilestoneFields,
      ),
    },
    httpCap: 13,
    editableField: 'description',
  ),
  AiCapability(
    operationId: 'updateMilestone',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'milestoneId': AiArgSpec(AiArgType.integer, required: true),
      'fields': AiArgSpec(
        AiArgType.object,
        required: true,
        properties: _updateMilestoneFields,
      ),
    },
    httpCap: 23,
    readback: true,
    editableField: 'description',
  ),
  AiCapability(
    operationId: 'setMilestoneState',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'milestoneId': AiArgSpec(AiArgType.integer, required: true),
      'stateEvent': _requiredString,
    },
    httpCap: 23,
    readback: true,
  ),
  AiCapability(
    operationId: 'createBoard',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'name': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.plainContent,
      ),
    },
    httpCap: 13,
    editableField: 'name',
  ),
  AiCapability(
    operationId: 'renameBoard',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'boardId': AiArgSpec(AiArgType.integer, required: true),
      'name': AiArgSpec(
        AiArgType.string,
        required: true,
        text: AiTextRole.plainContent,
      ),
    },
    httpCap: 21,
    editableField: 'name',
  ),
  AiCapability(
    operationId: 'setBoardSystemListHidden',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'boardId': AiArgSpec(AiArgType.integer, required: true),
      'list': _requiredString,
      'hidden': _requiredBoolean,
    },
    httpCap: 21,
  ),
  AiCapability(
    operationId: 'createBoardList',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'boardId': AiArgSpec(AiArgType.integer, required: true),
      'labelId': AiArgSpec(AiArgType.integer, required: true),
    },
    httpCap: 21,
  ),
  AiCapability(
    operationId: 'moveBoardList',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.project,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'boardId': AiArgSpec(AiArgType.integer, required: true),
      'listId': AiArgSpec(AiArgType.integer, required: true),
      'position': AiArgSpec(AiArgType.integer, required: true),
    },
    httpCap: 25,
  ),
  AiCapability(
    operationId: 'moveBoardCard',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'iid': _iid,
      'fields': AiArgSpec(
        AiArgType.object,
        required: true,
        properties: <String, AiArgSpec>{
          'labels': _plain,
          'state_event': _string,
        },
      ),
    },
    httpCap: 23,
    readback: true,
  ),
  AiCapability(
    operationId: 'upload_attachment',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.projectUpload,
    namedMethod: 'uploadProjectFile',
    arguments: <String, AiArgSpec>{
      'projectId': _projectId,
      'attachmentId': AiArgSpec(
        AiArgType.string,
        required: true,
        portVisible: false,
      ),
      'filename': AiArgSpec(
        AiArgType.string,
        text: AiTextRole.pathOrRef,
        modelVisible: false,
      ),
      'contentType': AiArgSpec(AiArgType.string, modelVisible: false),
    },
    httpCap: 13,
  ),
];
