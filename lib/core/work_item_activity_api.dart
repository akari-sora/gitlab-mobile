part of 'gitlab_api.dart';

const _workItemActivityPageSize = 20;

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

/// One bounded activity page plus opaque, account-bound continuation handles.
final class WorkItemActivityPage {
  WorkItemActivityPage._({
    required this.snapshot,
    required this.nextDiscussions,
    required Map<String, WorkItemDiscussionNotesContinuation>
    nextNotesByDiscussion,
  }) : nextNotesByDiscussion = Map.unmodifiable(nextNotesByDiscussion);

  final WorkItemActivitySnapshot snapshot;
  final WorkItemActivityContinuation? nextDiscussions;
  final Map<String, WorkItemDiscussionNotesContinuation> nextNotesByDiscussion;
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
  }) : _owner = owner,
       _identity = identity,
       _cursor = cursor,
       _seenCursors = Set.unmodifiable(seenCursors);

  final GitLabApi _owner;
  final _WorkItemActivityIdentity _identity;
  final String _cursor;
  final Set<String> _seenCursors;
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
  Future<WorkItemActivityPage> workItemActivity(
    WorkItemGraphSummary expected, {
    bool Function()? isCurrent,
  }) async {
    _validateExpectedAttributeIdentity(expected);
    return await _readWorkItemActivity(
      _activityIdentityFromExpected(expected),
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

  Future<WorkItemActivityPage> _readWorkItemActivity(
    _WorkItemActivityIdentity expected, {
    String? after,
    Set<String> seenCursors = const {},
    bool Function()? isCurrent,
  }) async {
    final cursor = _validatedWorkItemCursor(after);
    _requireCurrentWorkItemRequest(isCurrent);
    final response = await _read(
      instance.graphQL,
      method: 'POST',
      graphQuery: true,
      data: {
        'query': _workItemActivityQuery,
        'variables': {'id': expected.id, 'after': cursor},
      },
    );
    _requireCurrentWorkItemRequest(isCurrent);
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
        nextDiscussions: nextCursor == null
            ? null
            : WorkItemActivityContinuation._(
                owner: this,
                identity: identity,
                cursor: nextCursor,
                seenCursors: nextSeen,
              ),
        nextNotesByDiscussion: notesContinuations,
      );
    } on FormatException {
      throw const ApiFailure(FailureKind.invalidResponse);
    }
  }

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
