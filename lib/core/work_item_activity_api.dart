part of 'gitlab_api.dart';

const _workItemActivityPageSize = 20;
const _workItemActivityWriteBodyBytes = 2 * 1024 * 1024;

const _workItemActivityIdentityFields = r'''
id
iid
project { id fullPath }
namespace { id fullPath }
''';

const _workItemActivityNoteFields = r'''
id
system
systemNoteIconName
body
createdAt
updatedAt
author { id name username }
''';

final _workItemActivityQuery =
    '''
query MobileWorkItemActivity(
  \$id: WorkItemID!
  \$after: String
  \$filter: NotesFilterType!
  \$sort: WorkItemDiscussionsSort!
) {
  workItem(id: \$id) {
    $_workItemActivityIdentityFields
    widgets {
      type
      ... on WorkItemWidgetNotes {
        discussions(
          first: $_workItemActivityPageSize
          after: \$after
          filter: \$filter
          sort: \$sort
        ) {
          nodes {
            id
            replyId
            createdAt
            notes(first: $_workItemActivityPageSize) {
              nodes { $_workItemActivityNoteFields }
              pageInfo { hasNextPage endCursor }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
''';

final _workItemActivityLegacyQuery =
    '''
query MobileWorkItemActivity(\$id: WorkItemID!, \$after: String) {
  workItem(id: \$id) {
    $_workItemActivityIdentityFields
    widgets {
      type
      ... on WorkItemWidgetNotes {
        discussions(first: $_workItemActivityPageSize, after: \$after) {
          nodes {
            id
            replyId
            createdAt
            notes(first: $_workItemActivityPageSize) {
              nodes { $_workItemActivityNoteFields }
              pageInfo { hasNextPage endCursor }
            }
          }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
  }
}
''';

final _workItemActivityControlsUnsupported = Expando<bool>();

final _workItemDiscussionNotesQuery =
    '''
query MobileWorkItemDiscussionNotes(
  \$workItemId: WorkItemID!
  \$anchorNoteId: NoteID!
  \$after: String
) {
  workItem(id: \$workItemId) {
    $_workItemActivityIdentityFields
  }
  anchor: note(id: \$anchorNoteId) {
    id
    project { id fullPath }
    discussion {
      id
      replyId
      createdAt
      notes(first: $_workItemActivityPageSize, after: \$after) {
        nodes { $_workItemActivityNoteFields }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}
''';

final _workItemActivityWriteAccessQuery =
    '''
query MobileWorkItemActivityWriteAccess(\$id: WorkItemID!) {
  currentUser { id }
  workItem(id: \$id) {
    $_workItemActivityIdentityFields
    userPermissions { createNote }
    widgets {
      type
      ... on WorkItemWidgetNotes { discussionLocked }
    }
  }
}
''';

final _workItemActivityReplyPreflightQuery =
    '''
query MobileWorkItemActivityReplyPreflight(
  \$workItemId: WorkItemID!
  \$anchorNoteId: NoteID!
) {
  currentUser { id }
  workItem(id: \$workItemId) {
    $_workItemActivityIdentityFields
    userPermissions { createNote }
    widgets {
      type
      ... on WorkItemWidgetNotes { discussionLocked }
    }
  }
  anchor: note(id: \$anchorNoteId) {
    id
    noteableType
    noteableId
    project { id fullPath }
    discussion { id replyId createdAt }
  }
}
''';

final _workItemActivityCreateNoteMutation =
    '''
mutation MobileCreateWorkItemActivityNote(\$input: CreateNoteInput!) {
  createNote(input: \$input) {
    errors
    note {
      $_workItemActivityNoteFields
      internal
      noteableType
      noteableId
      project { id fullPath }
      discussion { id replyId createdAt }
    }
  }
}
''';

final _workItemActivityNoteReadbackQuery =
    '''
query MobileWorkItemActivityNoteReadback(
  \$workItemId: WorkItemID!
  \$noteId: NoteID!
) {
  workItem(id: \$workItemId) { $_workItemActivityIdentityFields }
  note(id: \$noteId) {
    $_workItemActivityNoteFields
    internal
    noteableType
    noteableId
    project { id fullPath }
    discussion { id replyId createdAt }
  }
}
''';

/// One bounded activity page plus opaque, account-bound continuation handles.
final class WorkItemActivityPage {
  WorkItemActivityPage._({
    required this.snapshot,
    required this.filter,
    required this.order,
    required this.controlsSupported,
    required this.nextDiscussions,
    required Map<String, WorkItemDiscussionNotesContinuation>
    nextNotesByDiscussion,
    required Map<String, WorkItemActivityReplyTarget> replyTargetsByDiscussion,
  }) : nextNotesByDiscussion = Map.unmodifiable(nextNotesByDiscussion),
       replyTargetsByDiscussion = Map.unmodifiable(replyTargetsByDiscussion);

  final WorkItemActivitySnapshot snapshot;
  final WorkItemActivityFilter filter;
  final WorkItemActivityOrder order;
  final bool controlsSupported;
  final WorkItemActivityContinuation? nextDiscussions;
  final Map<String, WorkItemDiscussionNotesContinuation> nextNotesByDiscussion;
  final Map<String, WorkItemActivityReplyTarget> replyTargetsByDiscussion;
}

/// A permission result isolated from the read-only activity query. Older
/// schemas can keep their reader even when native note creation is unsupported.
final class WorkItemActivityWriteAccess {
  const WorkItemActivityWriteAccess._({
    required this.canCreateNote,
    required this.discussionLocked,
    required this.commentTarget,
  });

  final bool canCreateNote;
  final bool discussionLocked;
  final WorkItemActivityCommentTarget? commentTarget;
}

/// A successfully acknowledged and independently read-back note.
final class WorkItemActivityCreatedNote {
  const WorkItemActivityCreatedNote._({
    required this.note,
    required this.discussionId,
    required this.replyId,
  });

  final WorkItemActivityNote note;
  final String discussionId;
  final String replyId;
}

/// Opaque, owner-bound capability for one top-level comment attempt.
final class WorkItemActivityCommentTarget {
  WorkItemActivityCommentTarget._({
    required GitLabApi owner,
    required _WorkItemActivityIdentity identity,
    required int workItemModelId,
    required String authorId,
  }) : _owner = owner,
       _identity = identity,
       _workItemModelId = workItemModelId,
       _authorId = authorId;

  final GitLabApi _owner;
  final _WorkItemActivityIdentity _identity;
  final int _workItemModelId;
  final String _authorId;
  bool _consumed = false;
}

/// Opaque, owner-bound capability for one reply attempt.
final class WorkItemActivityReplyTarget {
  WorkItemActivityReplyTarget._({
    required GitLabApi owner,
    required _WorkItemActivityIdentity identity,
    required int workItemModelId,
    required String discussionId,
    required String replyId,
    required DateTime discussionCreatedAt,
    required String anchorNoteId,
  }) : _owner = owner,
       _identity = identity,
       _workItemModelId = workItemModelId,
       _discussionId = discussionId,
       _replyId = replyId,
       _discussionCreatedAt = discussionCreatedAt,
       _anchorNoteId = anchorNoteId;

  final GitLabApi _owner;
  final _WorkItemActivityIdentity _identity;
  final int _workItemModelId;
  final String _discussionId;
  final String _replyId;
  final DateTime _discussionCreatedAt;
  final String _anchorNoteId;
  bool _consumed = false;
}

/// A bounded continuation page for exactly one validated discussion.
final class WorkItemDiscussionNotesPage {
  const WorkItemDiscussionNotesPage._({
    required this.workItemId,
    required this.discussionId,
    required this.notes,
    required this.next,
  });

  final String workItemId;
  final String discussionId;
  final WorkItemActivityConnection<WorkItemActivityNote> notes;
  final WorkItemDiscussionNotesContinuation? next;
}

/// Opaque capability minted by [GitLabApi] for the next discussion page.
final class WorkItemActivityContinuation {
  WorkItemActivityContinuation._({
    required GitLabApi owner,
    required _WorkItemActivityIdentity identity,
    required String cursor,
    required Set<String> seenCursors,
    required WorkItemActivityFilter filter,
    required WorkItemActivityOrder order,
    required bool controlsSupported,
  }) : _owner = owner,
       _identity = identity,
       _cursor = cursor,
       _seenCursors = Set.unmodifiable(seenCursors),
       _filter = filter,
       _order = order,
       _controlsSupported = controlsSupported;

  final GitLabApi _owner;
  final _WorkItemActivityIdentity _identity;
  final String _cursor;
  final Set<String> _seenCursors;
  final WorkItemActivityFilter _filter;
  final WorkItemActivityOrder _order;
  final bool _controlsSupported;
}

/// Opaque capability minted from a note returned by a validated activity page.
final class WorkItemDiscussionNotesContinuation {
  WorkItemDiscussionNotesContinuation._({
    required GitLabApi owner,
    required _WorkItemActivityIdentity identity,
    required String discussionId,
    required String replyId,
    required DateTime discussionCreatedAt,
    required String anchorNoteId,
    required String cursor,
    required Set<String> seenCursors,
  }) : _owner = owner,
       _identity = identity,
       _discussionId = discussionId,
       _replyId = replyId,
       _discussionCreatedAt = discussionCreatedAt,
       _anchorNoteId = anchorNoteId,
       _cursor = cursor,
       _seenCursors = Set.unmodifiable(seenCursors);

  final GitLabApi _owner;
  final _WorkItemActivityIdentity _identity;
  final String _discussionId;
  final String _replyId;
  final DateTime _discussionCreatedAt;
  final String _anchorNoteId;
  final String _cursor;
  final Set<String> _seenCursors;
}

typedef _WorkItemActivityIdentity = ({
  String id,
  int iid,
  GraphResourceRef? project,
  GraphResourceRef? namespace,
});

extension WorkItemActivityApi on GitLabApi {
  Future<WorkItemActivityWriteAccess> workItemActivityWriteAccess(
    WorkItemGraphSummary expected, {
    bool Function()? isCurrent,
  }) async {
    _validateExpectedAttributeIdentity(expected);
    final identity = _activityIdentityFromExpected(expected);
    final modelId = _workItemActivityModelId(identity.id);
    final preflight = await _readActivityWritePreflight(
      identity,
      isCurrent: isCurrent,
    );
    return WorkItemActivityWriteAccess._(
      canCreateNote: preflight.canCreateNote,
      discussionLocked: preflight.discussionLocked,
      commentTarget: preflight.canCreateNote && !preflight.discussionLocked
          ? WorkItemActivityCommentTarget._(
              owner: this,
              identity: identity,
              workItemModelId: modelId,
              authorId: preflight.authorId!,
            )
          : null,
    );
  }

  Future<WorkItemActivityCreatedNote> createWorkItemActivityComment(
    WorkItemActivityCommentTarget target,
    String body, {
    bool Function()? isCurrent,
  }) async {
    _requireActivityOwner(target._owner);
    if (target._consumed) {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
    final normalized = _validatedActivityWriteBody(body);
    _requireCurrentWorkItemRequest(isCurrent);
    final preflight = await _readActivityWritePreflight(
      target._identity,
      isCurrent: isCurrent,
    );
    if (!preflight.canCreateNote) {
      throw const ApiFailure(
        FailureKind.forbidden,
        title: '無法新增工作項目留言',
        detail: '目前帳號沒有在這個工作項目留言的權限。',
      );
    }
    if (preflight.discussionLocked) {
      throw const ApiFailure(
        FailureKind.conflict,
        title: '工作項目討論已鎖定',
        detail: '這個工作項目目前不接受新的留言。',
      );
    }
    if (preflight.authorId != target._authorId) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    return _createWorkItemActivityNote(
      identity: target._identity,
      workItemModelId: target._workItemModelId,
      expectedAuthorId: preflight.authorId!,
      body: normalized,
      consume: () {
        if (target._consumed) return false;
        target._consumed = true;
        return true;
      },
      isCurrent: isCurrent,
    );
  }

  Future<WorkItemActivityCreatedNote> createWorkItemActivityReply(
    WorkItemActivityReplyTarget target,
    String body, {
    bool Function()? isCurrent,
  }) async {
    _requireActivityOwner(target._owner);
    if (target._consumed) {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
    final normalized = _validatedActivityWriteBody(body);
    _requireCurrentWorkItemRequest(isCurrent);
    final preflight = await _readActivityWritePreflight(
      target._identity,
      anchorNoteId: target._anchorNoteId,
      isCurrent: isCurrent,
    );
    if (!preflight.canCreateNote) {
      throw const ApiFailure(
        FailureKind.forbidden,
        title: '無法回覆工作項目討論',
        detail: '目前帳號沒有回覆這個工作項目討論的權限。',
      );
    }
    if (preflight.discussionLocked) {
      throw const ApiFailure(
        FailureKind.conflict,
        title: '工作項目討論已鎖定',
        detail: '這個工作項目目前不接受新的回覆。',
      );
    }
    final anchor = preflight.anchor;
    if (anchor == null ||
        anchor.noteableId != target._workItemModelId ||
        anchor.discussionId != target._discussionId ||
        anchor.replyId != target._replyId ||
        anchor.discussionCreatedAt != target._discussionCreatedAt) {
      throw const ApiFailure(FailureKind.conflict);
    }
    return _createWorkItemActivityNote(
      identity: target._identity,
      workItemModelId: target._workItemModelId,
      expectedAuthorId: preflight.authorId!,
      body: normalized,
      expectedDiscussionId: target._discussionId,
      expectedReplyId: target._replyId,
      expectedDiscussionCreatedAt: target._discussionCreatedAt,
      consume: () {
        if (target._consumed) return false;
        target._consumed = true;
        return true;
      },
      isCurrent: isCurrent,
    );
  }

  Future<WorkItemActivityPage> workItemActivity(
    WorkItemGraphSummary expected, {
    WorkItemActivityFilter filter = WorkItemActivityFilter.all,
    WorkItemActivityOrder order = WorkItemActivityOrder.oldestFirst,
    bool Function()? isCurrent,
  }) async {
    _validateExpectedAttributeIdentity(expected);
    return await _readWorkItemActivity(
      _activityIdentityFromExpected(expected),
      filter: filter,
      order: order,
      isCurrent: isCurrent,
    );
  }

  Future<WorkItemActivityPage> workItemActivityNext(
    WorkItemActivityContinuation continuation, {
    bool Function()? isCurrent,
  }) async {
    _requireActivityOwner(continuation._owner);
    return await _readWorkItemActivity(
      continuation._identity,
      after: continuation._cursor,
      seenCursors: continuation._seenCursors,
      filter: continuation._filter,
      order: continuation._order,
      controlsSupported: continuation._controlsSupported,
      isCurrent: isCurrent,
    );
  }

  Future<WorkItemDiscussionNotesPage> workItemDiscussionNotesNext(
    WorkItemDiscussionNotesContinuation continuation, {
    bool Function()? isCurrent,
  }) async {
    _requireActivityOwner(continuation._owner);
    _requireCurrentWorkItemRequest(isCurrent);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _workItemDiscussionNotesQuery,
        'variables': {
          'workItemId': continuation._identity.id,
          'anchorNoteId': continuation._anchorNoteId,
          'after': continuation._cursor,
        },
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final data = _workItemGraphData(response.bytes);
      final root = data['workItem'];
      final anchor = data['anchor'];
      if (root == null || anchor == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final identity = _parseAttributeIdentity(objectJson(root));
      _requireActivityIdentity(identity, continuation._identity);
      final anchorNode = objectJson(anchor);
      if (requiredString(anchorNode, 'id') != continuation._anchorNoteId) {
        throw const FormatException('Wrong activity anchor');
      }
      _requireCompatibleAnchorProject(
        _parseOptionalResourceRef(anchorNode['project']),
        continuation._identity.project,
      );
      final discussion = _parseActivityDiscussion(
        anchorNode['discussion'],
        previousNotesCursor: continuation._cursor,
      );
      if (discussion.value.id != continuation._discussionId ||
          discussion.value.replyId != continuation._replyId ||
          discussion.value.createdAt != continuation._discussionCreatedAt) {
        throw const FormatException('Wrong activity discussion');
      }
      final next = _notesContinuation(
        identity: continuation._identity,
        discussion: discussion.value,
        cursor: discussion.nextCursor,
        seenCursors: continuation._seenCursors,
        rejectSeenCursor: true,
      );
      return WorkItemDiscussionNotesPage._(
        workItemId: identity.id,
        discussionId: discussion.value.id,
        notes: discussion.value.notes,
        next: next,
      );
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  Future<
    ({
      bool canCreateNote,
      bool discussionLocked,
      String? authorId,
      _WorkItemActivityAnchor? anchor,
    })
  >
  _readActivityWritePreflight(
    _WorkItemActivityIdentity expected, {
    String? anchorNoteId,
    bool Function()? isCurrent,
  }) async {
    _requireCurrentWorkItemRequest(isCurrent);
    final ({Uint8List bytes, Headers headers, int statusCode}) response;
    try {
      response = await _read(
        instance.graphQL,
        method: 'POST',
        graphQuery: true,
        data: {
          'query': anchorNoteId == null
              ? _workItemActivityWriteAccessQuery
              : _workItemActivityReplyPreflightQuery,
          'variables': anchorNoteId == null
              ? {'id': expected.id}
              : {'workItemId': expected.id, 'anchorNoteId': anchorNoteId},
        },
      );
    } on Object {
      _requireCurrentWorkItemRequest(isCurrent);
      rethrow;
    }
    _requireCurrentWorkItemRequest(isCurrent);
    try {
      final data = _workItemGraphData(response.bytes);
      final rawWorkItem = data['workItem'];
      final rawCurrentUser = data['currentUser'];
      if (rawWorkItem == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final workItem = objectJson(rawWorkItem);
      final identity = _parseAttributeIdentity(workItem);
      _requireActivityIdentity(identity, expected);
      final permissions = objectJson(workItem['userPermissions']);
      final serverCanCreateNote = permissions['createNote'];
      if (serverCanCreateNote is! bool) {
        throw const FormatException('Invalid note permission');
      }
      String? authorId;
      if (rawCurrentUser != null) {
        authorId = requiredString(objectJson(rawCurrentUser), 'id');
        if (!_isGraphIdType(authorId, const {'User'})) {
          throw const FormatException('Invalid current user identity');
        }
      }
      final canCreateNote = serverCanCreateNote && authorId != null;
      final discussionLocked = _parseActivityDiscussionLocked(
        workItem['widgets'],
      );
      _WorkItemActivityAnchor? anchor;
      if (anchorNoteId != null) {
        if (data['anchor'] == null) {
          throw const ApiFailure(FailureKind.invisible);
        }
        anchor = _parseActivityAnchor(
          data['anchor'],
          expected: expected,
          expectedAnchorId: anchorNoteId,
        );
      }
      return (
        canCreateNote: canCreateNote,
        discussionLocked: discussionLocked,
        authorId: authorId,
        anchor: anchor,
      );
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  Future<WorkItemActivityCreatedNote> _createWorkItemActivityNote({
    required _WorkItemActivityIdentity identity,
    required int workItemModelId,
    required String expectedAuthorId,
    required String body,
    required bool Function() consume,
    String? expectedDiscussionId,
    String? expectedReplyId,
    DateTime? expectedDiscussionCreatedAt,
    bool Function()? isCurrent,
  }) async {
    _requireCurrentWorkItemRequest(isCurrent);
    if (!consume()) throw const ApiFailure(FailureKind.writeUncertain);

    final ({Uint8List bytes, Headers headers, int statusCode}) response;
    try {
      response = await _send(
        instance.graphQL,
        method: 'POST',
        graphMutation: true,
        data: {
          'query': _workItemActivityCreateNoteMutation,
          'variables': {
            'input': {
              'noteableId': identity.id,
              'body': body,
              'internal': false,
              'discussionId': ?expectedReplyId,
            },
          },
        },
      );
    } on ApiFailure {
      throw const ApiFailure(FailureKind.writeUncertain);
    }

    late final _WorkItemActivityCreatedIdentity acknowledged;
    try {
      _requireCurrentWorkItemRequest(isCurrent);
      final data = _workItemGraphData(response.bytes);
      final rawPayload = data['createNote'];
      if (rawPayload == null) {
        throw const FormatException('Missing createNote payload');
      }
      final payload = objectJson(rawPayload);
      final errors = payload['errors'];
      if (errors is! List || errors.any((error) => error is! String)) {
        throw const FormatException('Invalid createNote errors');
      }
      if (errors.isNotEmpty) {
        throw const ApiFailure(FailureKind.writeUncertain);
      }
      acknowledged = _parseCreatedActivityNote(
        payload['note'],
        expectedIdentity: identity,
        expectedWorkItemModelId: workItemModelId,
        expectedAuthorId: expectedAuthorId,
        expectedBody: body,
        expectedDiscussionId: expectedDiscussionId,
        expectedReplyId: expectedReplyId,
        expectedDiscussionCreatedAt: expectedDiscussionCreatedAt,
      );
    } on ApiFailure catch (failure) {
      if (failure.kind == FailureKind.unsupported) rethrow;
      throw const ApiFailure(FailureKind.writeUncertain);
    } on FormatException {
      throw const ApiFailure(FailureKind.writeUncertain);
    }

    try {
      _requireCurrentWorkItemRequest(isCurrent);
      final readbackResponse = await _read(
        instance.graphQL,
        method: 'POST',
        graphQuery: true,
        data: {
          'query': _workItemActivityNoteReadbackQuery,
          'variables': {
            'workItemId': identity.id,
            'noteId': acknowledged.note.id,
          },
        },
      );
      _requireCurrentWorkItemRequest(isCurrent);
      final data = _workItemGraphData(readbackResponse.bytes);
      if (data['workItem'] == null || data['note'] == null) {
        throw const FormatException('Missing note readback');
      }
      final actualIdentity = _parseAttributeIdentity(
        objectJson(data['workItem']),
      );
      _requireActivityIdentity(actualIdentity, identity);
      final readback = _parseCreatedActivityNote(
        data['note'],
        expectedIdentity: identity,
        expectedWorkItemModelId: workItemModelId,
        expectedAuthorId: expectedAuthorId,
        expectedBody: body,
        expectedDiscussionId: acknowledged.discussionId,
        expectedReplyId: acknowledged.replyId,
        expectedDiscussionCreatedAt: acknowledged.discussionCreatedAt,
        expectedNoteId: acknowledged.note.id,
      );
      return WorkItemActivityCreatedNote._(
        note: readback.note,
        discussionId: readback.discussionId,
        replyId: readback.replyId,
      );
    } on Object {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
  }

  Future<WorkItemActivityPage> _readWorkItemActivity(
    _WorkItemActivityIdentity expected, {
    String? after,
    Set<String> seenCursors = const {},
    required WorkItemActivityFilter filter,
    required WorkItemActivityOrder order,
    bool? controlsSupported,
    bool Function()? isCurrent,
  }) async {
    final cursor = _validatedWorkItemCursor(after);
    final initialRequest = cursor == null;
    var useControls =
        controlsSupported ?? _workItemActivityControlsUnsupported[this] != true;
    _requireCurrentWorkItemRequest(isCurrent);
    var response = await _readWorkItemActivityResponse(
      expected.id,
      cursor,
      filter: filter,
      order: order,
      controlsSupported: useControls,
    );
    _requireCurrentWorkItemRequest(isCurrent);
    if (useControls && _activityControlsSchemaUnavailable(response.bytes)) {
      if (!initialRequest) {
        throw const ApiFailure(
          FailureKind.unsupported,
          title: '實例未提供活動篩選與排序',
          detail: '這個 GitLab 版本不支援活動篩選或排序。',
        );
      }
      _workItemActivityControlsUnsupported[this] = true;
      useControls = false;
      response = await _readWorkItemActivityResponse(
        expected.id,
        null,
        filter: WorkItemActivityFilter.all,
        order: WorkItemActivityOrder.oldestFirst,
        controlsSupported: false,
      );
      _requireCurrentWorkItemRequest(isCurrent);
    }
    final effectiveFilter = useControls ? filter : WorkItemActivityFilter.all;
    final effectiveOrder = useControls
        ? order
        : WorkItemActivityOrder.oldestFirst;
    try {
      final data = _workItemGraphData(response.bytes);
      if (data['workItem'] == null) {
        throw const ApiFailure(FailureKind.invisible);
      }
      final node = objectJson(data['workItem']);
      final identity = _parseAttributeIdentity(node);
      _requireActivityIdentity(identity, expected);
      final parsed = _parseActivityWidgets(node['widgets'], previous: cursor);
      final nextCursor = parsed.nextCursor;
      _requireActivityCursorProgress(nextCursor, seenCursors);
      final nextSeen = nextCursor == null
          ? seenCursors
          : {...seenCursors, nextCursor};
      final notesContinuations =
          <String, WorkItemDiscussionNotesContinuation>{};
      final replyTargets = <String, WorkItemActivityReplyTarget>{};
      final workItemModelId = _workItemActivityModelIdOrNull(identity.id);
      for (final entry in parsed.discussionsWithCursors) {
        final continuation = _notesContinuation(
          identity: identity,
          discussion: entry.value,
          cursor: entry.nextCursor,
          seenCursors: const {},
          rejectSeenCursor: false,
        );
        if (continuation != null) {
          notesContinuations[entry.value.id] = continuation;
        }
        if (workItemModelId != null) {
          final target = _activityReplyTarget(
            identity: identity,
            workItemModelId: workItemModelId,
            discussion: entry.value,
          );
          if (target != null) replyTargets[entry.value.id] = target;
        }
      }
      return WorkItemActivityPage._(
        snapshot: WorkItemActivitySnapshot(
          workItemId: identity.id,
          iid: identity.iid,
          project: identity.project,
          namespace: identity.namespace,
          availability: parsed.availability,
          discussions: parsed.discussions,
        ),
        filter: effectiveFilter,
        order: effectiveOrder,
        controlsSupported: useControls,
        nextDiscussions: nextCursor == null
            ? null
            : WorkItemActivityContinuation._(
                owner: this,
                identity: identity,
                cursor: nextCursor,
                seenCursors: nextSeen,
                filter: effectiveFilter,
                order: effectiveOrder,
                controlsSupported: useControls,
              ),
        nextNotesByDiscussion: notesContinuations,
        replyTargetsByDiscussion: replyTargets,
      );
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

  Future<({Uint8List bytes, Headers headers, int statusCode})>
  _readWorkItemActivityResponse(
    String id,
    String? after, {
    required WorkItemActivityFilter filter,
    required WorkItemActivityOrder order,
    required bool controlsSupported,
  }) => _read(
    instance.graphQL,
    method: 'POST',
    graphQuery: true,
    data: {
      'query': controlsSupported
          ? _workItemActivityQuery
          : _workItemActivityLegacyQuery,
      'variables': controlsSupported
          ? {
              'id': id,
              'after': after,
              'filter': filter.graphValue,
              'sort': order.graphValue,
            }
          : {'id': id, 'after': after},
    },
  );

  void _requireActivityOwner(GitLabApi owner) {
    if (!identical(owner, this)) {
      throw const ApiFailure(FailureKind.validation);
    }
    if (isClosed) throw const ApiFailure(FailureKind.cancelled);
  }

  WorkItemDiscussionNotesContinuation? _notesContinuation({
    required _WorkItemActivityIdentity identity,
    required WorkItemActivityDiscussion discussion,
    required String? cursor,
    required Set<String> seenCursors,
    required bool rejectSeenCursor,
  }) {
    if (cursor == null) return null;
    if (rejectSeenCursor && seenCursors.contains(cursor)) {
      throw const FormatException('Repeated activity note cursor');
    }
    if (discussion.notes.availability !=
            WorkItemActivityConnectionAvailability.present ||
        discussion.notes.items.isEmpty) {
      throw const FormatException('Missing activity continuation anchor');
    }
    return WorkItemDiscussionNotesContinuation._(
      owner: this,
      identity: identity,
      discussionId: discussion.id,
      replyId: discussion.replyId,
      discussionCreatedAt: discussion.createdAt,
      anchorNoteId: discussion.notes.items.last.id,
      cursor: cursor,
      seenCursors: {...seenCursors, cursor},
    );
  }

  WorkItemActivityReplyTarget? _activityReplyTarget({
    required _WorkItemActivityIdentity identity,
    required int workItemModelId,
    required WorkItemActivityDiscussion discussion,
  }) {
    if (discussion.notes.availability !=
            WorkItemActivityConnectionAvailability.present ||
        discussion.notes.items.isEmpty) {
      return null;
    }
    final anchorNoteId = discussion.notes.items.last.id;
    if (!_isWritableActivityNoteId(anchorNoteId) ||
        !_isGraphIdType(discussion.id, const {'Discussion'}) ||
        !_isGraphIdType(discussion.replyId, const {
          'Discussion',
          'IndividualNoteDiscussion',
        })) {
      return null;
    }
    return WorkItemActivityReplyTarget._(
      owner: this,
      identity: identity,
      workItemModelId: workItemModelId,
      discussionId: discussion.id,
      replyId: discussion.replyId,
      discussionCreatedAt: discussion.createdAt,
      anchorNoteId: anchorNoteId,
    );
  }
}

typedef _WorkItemActivityAnchor = ({
  int noteableId,
  String discussionId,
  String replyId,
  DateTime discussionCreatedAt,
});

typedef _WorkItemActivityCreatedIdentity = ({
  WorkItemActivityNote note,
  String discussionId,
  String replyId,
  DateTime discussionCreatedAt,
});

int _workItemActivityModelId(String id) {
  final value = _workItemActivityModelIdOrNull(id);
  if (value == null) throw const ApiFailure(FailureKind.validation);
  return value;
}

int? _workItemActivityModelIdOrNull(String id) {
  final uri = Uri.tryParse(id);
  if (uri == null ||
      uri.scheme != 'gid' ||
      uri.host != 'gitlab' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.pathSegments.length != 2 ||
      uri.pathSegments.first != 'WorkItem') {
    return null;
  }
  final raw = uri.pathSegments.last;
  if (!RegExp(r'^[1-9][0-9]*$').hasMatch(raw)) return null;
  return int.tryParse(raw);
}

bool _isGraphIdType(String id, Set<String> types) {
  if (!_validOpaqueGraphId(id)) return false;
  final uri = Uri.parse(id);
  return uri.pathSegments.isNotEmpty && types.contains(uri.pathSegments.first);
}

bool _isWritableActivityNoteId(String id) {
  final uri = Uri.tryParse(id);
  if (uri == null ||
      uri.scheme != 'gid' ||
      uri.host != 'gitlab' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.pathSegments.length != 2 ||
      !const {'Note', 'DiscussionNote'}.contains(uri.pathSegments.first)) {
    return false;
  }
  return RegExp(r'^[1-9][0-9]*$').hasMatch(uri.pathSegments.last);
}

String _validatedActivityWriteBody(String raw) {
  if (raw.contains('\u0000')) {
    throw const ApiFailure(FailureKind.validation);
  }
  final body = raw.trim();
  if (body.isEmpty ||
      utf8.encode(body).length > _workItemActivityWriteBodyBytes ||
      '\n'.allMatches(body).length + 1 > GitLabApi.maxTextLines) {
    throw const ApiFailure(FailureKind.validation);
  }
  if (_containsActivityQuickAction(body)) {
    throw const ApiFailure(
      FailureKind.validation,
      title: '留言不支援快速指令',
      detail: '請移除獨立一行的 / 指令；這個編輯器只會建立一般 Markdown 留言。',
    );
  }
  return body;
}

bool _containsActivityQuickAction(String body) {
  var fence = '';
  for (final line in body.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
      final marker = trimmed.substring(0, 3);
      if (fence.isEmpty) {
        fence = marker;
      } else if (fence == marker) {
        fence = '';
      }
      continue;
    }
    if (fence.isNotEmpty || line.startsWith('    ') || line.startsWith('\t')) {
      continue;
    }
    if (RegExp(r'^ {0,3}/[A-Za-z][A-Za-z0-9_-]*(?:\s|$)').hasMatch(line)) {
      return true;
    }
  }
  return false;
}

_WorkItemActivityAnchor _parseActivityAnchor(
  Object? raw, {
  required _WorkItemActivityIdentity expected,
  required String expectedAnchorId,
}) {
  final node = objectJson(raw);
  if (requiredString(node, 'id') != expectedAnchorId ||
      !_isWritableActivityNoteId(expectedAnchorId)) {
    throw const FormatException('Wrong reply anchor');
  }
  _requireCompatibleAnchorProject(
    _parseOptionalResourceRef(node['project']),
    expected.project,
  );
  final noteableId = _activityNoteableId(node);
  if (noteableId != _workItemActivityModelId(expected.id)) {
    throw const FormatException('Wrong reply noteable');
  }
  final discussion = _parseActivityDiscussionIdentity(node['discussion']);
  return (
    noteableId: noteableId,
    discussionId: discussion.id,
    replyId: discussion.replyId,
    discussionCreatedAt: discussion.createdAt,
  );
}

_WorkItemActivityCreatedIdentity _parseCreatedActivityNote(
  Object? raw, {
  required _WorkItemActivityIdentity expectedIdentity,
  required int expectedWorkItemModelId,
  required String expectedAuthorId,
  required String expectedBody,
  String? expectedDiscussionId,
  String? expectedReplyId,
  DateTime? expectedDiscussionCreatedAt,
  String? expectedNoteId,
}) {
  final node = objectJson(raw);
  final note = _parseActivityNote(node);
  if (!_isWritableActivityNoteId(note.id)) {
    throw const FormatException('Invalid created note identity');
  }
  if (node['internal'] != false) {
    throw const FormatException('Created note must be public');
  }
  if (expectedNoteId != null && note.id != expectedNoteId) {
    throw const FormatException('Wrong created note');
  }
  if (note.system ||
      note.body != expectedBody ||
      note.author == null ||
      note.author!.id != expectedAuthorId ||
      !_isGraphIdType(expectedAuthorId, const {'User'})) {
    throw const FormatException('Wrong created note content');
  }
  if (_activityNoteableId(node) != expectedWorkItemModelId) {
    throw const FormatException('Wrong created noteable');
  }
  _requireCompatibleAnchorProject(
    _parseOptionalResourceRef(node['project']),
    expectedIdentity.project,
  );
  final discussion = _parseActivityDiscussionIdentity(node['discussion']);
  if ((expectedDiscussionId != null && discussion.id != expectedDiscussionId) ||
      (expectedReplyId != null && discussion.replyId != expectedReplyId) ||
      (expectedDiscussionCreatedAt != null &&
          discussion.createdAt != expectedDiscussionCreatedAt)) {
    throw const FormatException('Wrong created discussion');
  }
  return (
    note: note,
    discussionId: discussion.id,
    replyId: discussion.replyId,
    discussionCreatedAt: discussion.createdAt,
  );
}

int _activityNoteableId(Json note) {
  if (note['noteableType'] != 'Issue') {
    throw const FormatException('Wrong activity noteable type');
  }
  return _positiveWorkItemInt(note['noteableId']);
}

({String id, String replyId, DateTime createdAt})
_parseActivityDiscussionIdentity(Object? raw) {
  final node = objectJson(raw);
  final id = requiredString(node, 'id');
  final replyId = requiredString(node, 'replyId');
  if (!_isGraphIdType(id, const {'Discussion'}) ||
      !_isGraphIdType(replyId, const {
        'Discussion',
        'IndividualNoteDiscussion',
      })) {
    throw const FormatException('Invalid created discussion identity');
  }
  return (
    id: id,
    replyId: replyId,
    createdAt: _workItemTimestamp(node['createdAt']),
  );
}

bool _activityControlsSchemaUnavailable(Uint8List bytes) {
  try {
    final envelope = objectJson(jsonDecode(utf8.decode(bytes)));
    final errors = envelope['errors'];
    if (errors is! List || errors.isEmpty) return false;
    return errors.every(_activityControlSchemaError);
  } on FormatException {
    return false;
  }
}

bool _activityControlSchemaError(Object? raw) {
  if (raw is! Map || raw['extensions'] is! Map) return false;
  final extensions = raw['extensions'] as Map;
  final code = extensions['code'];
  if (code == 'argumentNotAccepted') {
    return extensions['name'] == 'discussions' &&
        extensions['typeName'] == 'Field' &&
        const {'filter', 'sort'}.contains(extensions['argumentName']);
  }
  if (code == 'variableRequiresValidType') {
    return (extensions['typeName'] == 'NotesFilterType' &&
            extensions['variableName'] == 'filter') ||
        (extensions['typeName'] == 'WorkItemDiscussionsSort' &&
            extensions['variableName'] == 'sort');
  }
  return false;
}

_WorkItemActivityIdentity _activityIdentityFromExpected(
  WorkItemGraphSummary expected,
) => (
  id: expected.id,
  iid: expected.iid,
  project: expected.project,
  namespace: expected.namespace,
);

void _requireActivityIdentity(
  _WorkItemActivityIdentity actual,
  _WorkItemActivityIdentity expected,
) {
  if (actual.id != expected.id ||
      actual.iid != expected.iid ||
      !_sameAttributeRef(actual.project, expected.project) ||
      !_sameAttributeRef(actual.namespace, expected.namespace)) {
    throw const FormatException('Wrong work item activity identity');
  }
}

({
  WorkItemActivityAvailability availability,
  WorkItemActivityConnection<WorkItemActivityDiscussion> discussions,
  List<({WorkItemActivityDiscussion value, String? nextCursor})>
  discussionsWithCursors,
  String? nextCursor,
})
_parseActivityWidgets(Object? raw, {String? previous}) {
  if (raw == null) {
    return (
      availability: WorkItemActivityAvailability.widgetsUnavailable,
      discussions: WorkItemActivityConnection(
        availability: WorkItemActivityConnectionAvailability.unavailable,
        items: const [],
      ),
      discussionsWithCursors: const [],
      nextCursor: null,
    );
  }
  if (raw is! List || raw.length > _workItemWidgetLimit) {
    throw const FormatException('Invalid activity widgets');
  }
  final seenTypes = <String>{};
  Json? selected;
  for (final value in raw) {
    final widget = objectJson(value);
    final type = _boundedRequiredText(widget, 'type', 128);
    if (!seenTypes.add(type)) {
      throw const FormatException('Duplicate activity widget');
    }
    if (type == 'NOTES') selected = widget;
  }
  if (selected == null) {
    return (
      availability: WorkItemActivityAvailability.absent,
      discussions: WorkItemActivityConnection(
        availability: WorkItemActivityConnectionAvailability.present,
        items: const [],
      ),
      discussionsWithCursors: const [],
      nextCursor: null,
    );
  }
  final rawConnection = selected['discussions'];
  if (rawConnection == null) {
    return (
      availability: WorkItemActivityAvailability.present,
      discussions: WorkItemActivityConnection(
        availability: WorkItemActivityConnectionAvailability.unavailable,
        items: const [],
      ),
      discussionsWithCursors: const [],
      nextCursor: null,
    );
  }
  final connection = objectJson(rawConnection);
  final parsedPage = _activityPageInfo(connection, previous: previous);
  final nodes = connection['nodes'];
  if (nodes == null) {
    return (
      availability: WorkItemActivityAvailability.present,
      discussions: WorkItemActivityConnection(
        availability: WorkItemActivityConnectionAvailability.unavailable,
        items: const [],
      ),
      discussionsWithCursors: const [],
      nextCursor: null,
    );
  }
  if (nodes is! List || nodes.length > _workItemActivityPageSize) {
    throw const FormatException('Invalid activity discussions');
  }
  final values = <({WorkItemActivityDiscussion value, String? nextCursor})>[];
  final discussionIds = <String>{};
  final replyIds = <String>{};
  for (final rawDiscussion in nodes) {
    final value = _parseActivityDiscussion(rawDiscussion);
    if (!discussionIds.add(value.value.id) ||
        !replyIds.add(value.value.replyId)) {
      throw const FormatException('Duplicate activity discussion');
    }
    values.add(value);
  }
  return (
    availability: WorkItemActivityAvailability.present,
    discussions: WorkItemActivityConnection(
      availability: WorkItemActivityConnectionAvailability.present,
      items: values.map((value) => value.value).toList(),
    ),
    discussionsWithCursors: List.unmodifiable(values),
    nextCursor: parsedPage,
  );
}

bool _parseActivityDiscussionLocked(Object? raw) {
  if (raw is! List || raw.length > _workItemWidgetLimit) {
    throw const FormatException('Invalid activity widgets');
  }
  final seenTypes = <String>{};
  Json? selected;
  for (final value in raw) {
    final widget = objectJson(value);
    final type = _boundedRequiredText(widget, 'type', 128);
    if (!seenTypes.add(type)) {
      throw const FormatException('Duplicate activity widget');
    }
    if (type == 'NOTES') selected = widget;
  }
  if (selected == null) {
    throw const FormatException('Missing discussion lock state');
  }
  final locked = selected['discussionLocked'];
  if (locked != null && locked is! bool) {
    throw const FormatException('Invalid discussion lock state');
  }
  return locked as bool? ?? false;
}

({WorkItemActivityDiscussion value, String? nextCursor})
_parseActivityDiscussion(Object? raw, {String? previousNotesCursor}) {
  final node = objectJson(raw);
  final id = requiredString(node, 'id');
  if (!_validOpaqueGraphId(id)) {
    throw const FormatException('Invalid activity discussion ID');
  }
  final replyId = _boundedRequiredText(node, 'replyId', 512);
  if (replyId.isEmpty) throw const FormatException('Invalid reply ID');
  final notesResult = _parseActivityNotesConnection(
    node['notes'],
    previous: previousNotesCursor,
  );
  return (
    value: WorkItemActivityDiscussion(
      id: id,
      replyId: replyId,
      createdAt: _workItemTimestamp(node['createdAt']),
      notes: notesResult.connection,
    ),
    nextCursor: notesResult.nextCursor,
  );
}

({
  WorkItemActivityConnection<WorkItemActivityNote> connection,
  String? nextCursor,
})
_parseActivityNotesConnection(Object? raw, {String? previous}) {
  if (raw == null) throw const FormatException('Missing notes connection');
  final connection = objectJson(raw);
  final nextCursor = _activityPageInfo(connection, previous: previous);
  final nodes = connection['nodes'];
  if (nodes == null) {
    return (
      connection: WorkItemActivityConnection(
        availability: WorkItemActivityConnectionAvailability.unavailable,
        items: const [],
      ),
      nextCursor: null,
    );
  }
  if (nodes is! List || nodes.length > _workItemActivityPageSize) {
    throw const FormatException('Invalid activity notes');
  }
  final notes = <WorkItemActivityNote>[];
  final ids = <String>{};
  for (final rawNote in nodes) {
    final note = _parseActivityNote(rawNote);
    if (!ids.add(note.id)) throw const FormatException('Duplicate note');
    notes.add(note);
  }
  return (
    connection: WorkItemActivityConnection(
      availability: WorkItemActivityConnectionAvailability.present,
      items: notes,
    ),
    nextCursor: nextCursor,
  );
}

WorkItemActivityNote _parseActivityNote(Object? raw) {
  final node = objectJson(raw);
  final id = requiredString(node, 'id');
  if (!_validOpaqueGraphId(id)) throw const FormatException('Invalid note ID');
  final system = node['system'];
  if (system is! bool) throw const FormatException('Invalid system note flag');
  final icon = node['systemNoteIconName'];
  if (icon != null &&
      (icon is! String || icon.length > 256 || icon.contains('\u0000'))) {
    throw const FormatException('Invalid system note icon');
  }
  final body = _boundedOptionalDescription(node['body']);
  if (body == null) throw const FormatException('Missing note body');
  final rawAuthor = node['author'];
  WorkItemActivityAuthor? author;
  if (rawAuthor != null) {
    final value = objectJson(rawAuthor);
    final authorId = requiredString(value, 'id');
    if (!_validOpaqueGraphId(authorId)) {
      throw const FormatException('Invalid note author ID');
    }
    author = WorkItemActivityAuthor(
      id: authorId,
      name: _boundedRequiredText(value, 'name', 512),
      username: _boundedRequiredText(value, 'username', 255),
    );
  }
  return WorkItemActivityNote(
    id: id,
    system: system,
    systemNoteIconName: icon as String?,
    body: body,
    createdAt: _workItemTimestamp(node['createdAt']),
    updatedAt: _workItemTimestamp(node['updatedAt']),
    author: author,
  );
}

String? _activityPageInfo(Json connection, {String? previous}) =>
    _nextWorkItemCursor(connection, previous: previous);

void _requireActivityCursorProgress(String? next, Set<String> seen) {
  if (next == null) return;
  if (seen.contains(next)) {
    throw const FormatException('Repeated activity cursor');
  }
}

void _requireCompatibleAnchorProject(
  GraphResourceRef? actual,
  GraphResourceRef? expected,
) {
  if (!_sameAttributeRef(actual, expected)) {
    throw const FormatException('Wrong activity anchor project');
  }
}
