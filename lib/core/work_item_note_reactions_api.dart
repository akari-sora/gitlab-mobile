part of 'gitlab_api.dart';

const _workItemActivityReactionPageSize = 50;
const _workItemActivityReactionPageLimit = 20;
const _workItemActivityReactionCursorLimit = 4096;

final _workItemActivityReactionAccessQuery =
    '''
query MobileWorkItemActivityReactionAccess(
  \$workItemId: WorkItemID!
  \$noteId: NoteID!
  \$after: String
) {
  currentUser { id }
  workItem(id: \$workItemId) { $_workItemActivityIdentityFields }
  note(id: \$noteId) {
    $_workItemActivityNoteFields
    internal
    noteableType
    noteableId
    project { id fullPath }
    discussion { id createdAt }
    userPermissions { awardEmoji }
    awardEmoji(first: $_workItemActivityReactionPageSize, after: \$after) {
      nodes { name unicode user { id } }
      pageInfo { hasNextPage endCursor }
    }
  }
}
''';

const _workItemActivityReactionAddMutation = r'''
mutation MobileAddWorkItemActivityNoteReaction($input: AwardEmojiAddInput!) {
  awardEmojiAdd(input: $input) {
    errors
    awardEmoji { name unicode user { id } }
  }
}
''';

const _workItemActivityReactionRemoveMutation = r'''
mutation MobileRemoveWorkItemActivityNoteReaction($input: AwardEmojiRemoveInput!) {
  awardEmojiRemove(input: $input) { errors }
}
''';

/// One server-owned emoji award on an ordinary Work Item note.
final class WorkItemActivityReaction {
  const WorkItemActivityReaction({
    required this.name,
    required this.unicode,
    required this.actorId,
  });

  final String name;
  final String? unicode;
  final String actorId;
}

/// A complete, freshly paged reaction snapshot and optional write capability.
final class WorkItemActivityReactionAccess {
  const WorkItemActivityReactionAccess._({
    required this.reactions,
    required this.actorId,
    required this.canAward,
    required this.target,
  });

  final List<WorkItemActivityReaction> reactions;
  final String? actorId;
  final bool canAward;
  final WorkItemActivityReactionTarget? target;
}

/// One reaction attempt bound to the API owner, actor, note and revision.
final class WorkItemActivityReactionTarget {
  WorkItemActivityReactionTarget._({
    required GitLabApi owner,
    required _WorkItemActivityIdentity identity,
    required String actorId,
    required _WorkItemActivityEditNote original,
    required List<WorkItemActivityReaction> reactions,
  }) : _owner = owner,
       _identity = identity,
       _actorId = actorId,
       _original = original,
       _reactions = List.unmodifiable(reactions);

  final GitLabApi _owner;
  final _WorkItemActivityIdentity _identity;
  final String _actorId;
  final _WorkItemActivityEditNote _original;
  final List<WorkItemActivityReaction> _reactions;
  bool _consumed = false;

  WorkItemActivityNote get note => _original.note;
}

typedef _WorkItemActivityReactionPreflight = ({
  _WorkItemActivityEditNote value,
  String? actorId,
  bool canAward,
  List<WorkItemActivityReaction> reactions,
});

extension WorkItemActivityNoteReactionsApi on GitLabApi {
  Future<WorkItemActivityReactionAccess> workItemActivityReactionAccess(
    WorkItemGraphSummary expected,
    WorkItemActivityDiscussion discussion,
    WorkItemActivityNote expectedNote, {
    bool Function()? isCurrent,
  }) async {
    _validateExpectedAttributeIdentity(expected);
    _workItemActivityModelId(expected.id);
    if (expectedNote.system ||
        !_isWritableActivityNoteId(expectedNote.id) ||
        !_isGraphIdType(discussion.id, const {'Discussion'})) {
      throw const ApiFailure(FailureKind.validation);
    }
    final identity = _activityIdentityFromExpected(expected);
    final preflight = await _readWorkItemActivityReactionPreflight(
      identity,
      noteId: expectedNote.id,
      discussionId: discussion.id,
      discussionCreatedAt: discussion.createdAt,
      isCurrent: isCurrent,
    );
    _requireDisplayedActivityNote(preflight.value.note, expectedNote);
    return _workItemActivityReactionAccess(identity, preflight);
  }

  Future<WorkItemActivityReactionAccess> setWorkItemActivityNoteReaction(
    WorkItemActivityReactionTarget target,
    String name, {
    required bool awarded,
    bool Function()? isCurrent,
  }) async {
    _requireActivityOwner(target._owner);
    if (target._consumed) {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
    final normalizedName = _validatedWorkItemActivityReactionName(name);
    final preflight = await _readWorkItemActivityReactionPreflight(
      target._identity,
      noteId: target.note.id,
      discussionId: target._original.discussionId,
      discussionCreatedAt: target._original.discussionCreatedAt,
      isCurrent: isCurrent,
    );
    if (!preflight.canAward) {
      throw ApiFailure(
        FailureKind.forbidden,
        title: l10n.cannotReactToComment,
        detail: l10n.noPermissionEmojiReaction,
      );
    }
    if (preflight.actorId != target._actorId) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    _requireDisplayedActivityNote(preflight.value.note, target.note);
    final before = _hasWorkItemActivityReaction(
      target._reactions,
      actorId: target._actorId,
      name: normalizedName,
    );
    final fresh = _hasWorkItemActivityReaction(
      preflight.reactions,
      actorId: target._actorId,
      name: normalizedName,
    );
    if (fresh != before) {
      throw ApiFailure(
        FailureKind.conflict,
        title: l10n.emojiReactionChanged,
        detail: l10n.reloadCommentBeforeAction,
      );
    }
    _requireCurrentWorkItemRequest(isCurrent);
    if (target._consumed) {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
    target._consumed = true;
    if (fresh == awarded) {
      return _workItemActivityReactionAccess(target._identity, preflight);
    }

    try {
      final response = await _send(
        instance.graphQL,
        method: 'POST',
        graphMutation: true,
        data: {
          'query': awarded
              ? _workItemActivityReactionAddMutation
              : _workItemActivityReactionRemoveMutation,
          'variables': {
            'input': {'awardableId': target.note.id, 'name': normalizedName},
          },
        },
      );
      _requireCurrentWorkItemRequest(isCurrent);
      final data = _workItemGraphData(response.bytes);
      final payload = objectJson(
        data[awarded ? 'awardEmojiAdd' : 'awardEmojiRemove'],
      );
      _requireEmptyWorkItemActivityReactionErrors(payload['errors']);
      if (awarded) {
        final acknowledgement = _parseWorkItemActivityReaction(
          payload['awardEmoji'],
        );
        if (acknowledgement.name != normalizedName ||
            acknowledgement.actorId != target._actorId) {
          throw const FormatException('Wrong reaction acknowledgement');
        }
      }
    } on Object {
      throw const ApiFailure(FailureKind.writeUncertain);
    }

    try {
      final readback = await _readWorkItemActivityReactionPreflight(
        target._identity,
        noteId: target.note.id,
        discussionId: target._original.discussionId,
        discussionCreatedAt: target._original.discussionCreatedAt,
        isCurrent: isCurrent,
      );
      if (readback.actorId != target._actorId) {
        throw const FormatException('Changed reaction actor');
      }
      _requireSameWorkItemActivityReactionNote(
        readback.value,
        target._original,
        // Award emoji changes bump updatedAt without editing the note.
        compareUpdatedAt: false,
      );
      if (_hasWorkItemActivityReaction(
            readback.reactions,
            actorId: target._actorId,
            name: normalizedName,
          ) !=
          awarded) {
        throw const FormatException('Unconfirmed reaction state');
      }
      return _workItemActivityReactionAccess(target._identity, readback);
    } on Object {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
  }

  Future<_WorkItemActivityReactionPreflight>
  _readWorkItemActivityReactionPreflight(
    _WorkItemActivityIdentity identity, {
    required String noteId,
    required String discussionId,
    required DateTime discussionCreatedAt,
    bool Function()? isCurrent,
  }) async {
    String? after;
    final seenCursors = <String>{};
    final reactions = <WorkItemActivityReaction>[];
    final seenReactions = <String>{};
    _WorkItemActivityEditNote? firstValue;
    String? firstActorId;
    bool? firstPermission;

    for (var page = 0; page < _workItemActivityReactionPageLimit; page++) {
      _requireCurrentWorkItemRequest(isCurrent);
      final response = await _read(
        instance.graphQL,
        method: 'POST',
        graphQuery: true,
        data: {
          'query': _workItemActivityReactionAccessQuery,
          'variables': {
            'workItemId': identity.id,
            'noteId': noteId,
            'after': after,
          },
        },
      );
      _requireCurrentWorkItemRequest(isCurrent);
      try {
        final data = _workItemGraphData(response.bytes);
        if (data['workItem'] == null || data['note'] == null) {
          throw const ApiFailure(FailureKind.invisible);
        }
        _requireActivityIdentity(
          _parseAttributeIdentity(objectJson(data['workItem'])),
          identity,
        );
        final value = _parseActivityEditNote(
          data['note'],
          identity: identity,
          noteId: noteId,
          discussionId: discussionId,
          discussionCreatedAt: discussionCreatedAt,
        );
        final noteNode = objectJson(data['note']);
        final permission = objectJson(
          noteNode['userPermissions'],
        )['awardEmoji'];
        if (permission is! bool) {
          throw const FormatException('Invalid reaction permission');
        }
        String? actorId;
        if (data['currentUser'] != null) {
          actorId = requiredString(objectJson(data['currentUser']), 'id');
          if (!_isGraphIdType(actorId, const {'User'})) {
            throw const FormatException('Invalid reaction actor');
          }
        }
        if (firstValue == null) {
          firstValue = value;
          firstActorId = actorId;
          firstPermission = permission;
        } else {
          _requireSameWorkItemActivityReactionNote(value, firstValue);
          if (actorId != firstActorId || permission != firstPermission) {
            throw const FormatException('Changed reaction access page');
          }
        }

        final connection = objectJson(noteNode['awardEmoji']);
        final nodes = connection['nodes'];
        if (nodes is! List ||
            nodes.length > _workItemActivityReactionPageSize ||
            nodes.any((node) => node == null)) {
          throw const FormatException('Invalid reaction nodes');
        }
        for (final raw in nodes) {
          final reaction = _parseWorkItemActivityReaction(raw);
          if (!seenReactions.add('${reaction.name}\u0000${reaction.actorId}')) {
            throw const FormatException('Duplicate reaction');
          }
          reactions.add(reaction);
        }
        final pageInfo = objectJson(connection['pageInfo']);
        final hasNextPage = pageInfo['hasNextPage'];
        final rawCursor = pageInfo['endCursor'];
        if (hasNextPage is! bool ||
            (rawCursor != null && rawCursor is! String)) {
          throw const FormatException('Invalid reaction page info');
        }
        if (!hasNextPage) {
          final completedValue = firstValue;
          final ordinary =
              !completedValue.internal && !completedValue.note.system;
          return (
            value: completedValue,
            actorId: firstActorId,
            canAward: firstPermission! && firstActorId != null && ordinary,
            reactions: List<WorkItemActivityReaction>.unmodifiable(reactions),
          );
        }
        if (rawCursor is! String ||
            rawCursor.isEmpty ||
            rawCursor.length > _workItemActivityReactionCursorLimit ||
            !seenCursors.add(rawCursor)) {
          throw const FormatException('Invalid reaction cursor');
        }
        if (page + 1 == _workItemActivityReactionPageLimit) {
          throw const FormatException('Reaction page limit exceeded');
        }
        after = rawCursor;
      } on FormatException {
        throw const ApiFailure(FailureKind.invalidResponse);
      }
    }
    throw const ApiFailure(FailureKind.invalidResponse);
  }

  WorkItemActivityReactionAccess _workItemActivityReactionAccess(
    _WorkItemActivityIdentity identity,
    _WorkItemActivityReactionPreflight preflight,
  ) => WorkItemActivityReactionAccess._(
    reactions: preflight.reactions,
    actorId: preflight.actorId,
    canAward: preflight.canAward,
    target: preflight.canAward
        ? WorkItemActivityReactionTarget._(
            owner: this,
            identity: identity,
            actorId: preflight.actorId!,
            original: preflight.value,
            reactions: preflight.reactions,
          )
        : null,
  );
}

String _validatedWorkItemActivityReactionName(String value) {
  if (value.isEmpty ||
      value.length > 80 ||
      !RegExp(r'^[A-Za-z0-9_+\-]+$').hasMatch(value)) {
    throw const ApiFailure(FailureKind.validation);
  }
  return value;
}

WorkItemActivityReaction _parseWorkItemActivityReaction(Object? raw) {
  final node = objectJson(raw);
  final name = requiredString(node, 'name');
  if (name.length > 80 || !RegExp(r'^[A-Za-z0-9_+\-]+$').hasMatch(name)) {
    throw const FormatException('Invalid reaction name');
  }
  final unicode = node['unicode'];
  if (unicode != null && unicode is! String) {
    throw const FormatException('Invalid reaction unicode');
  }
  final actorId = requiredString(objectJson(node['user']), 'id');
  if (!_isGraphIdType(actorId, const {'User'})) {
    throw const FormatException('Invalid reaction user');
  }
  return WorkItemActivityReaction(
    name: name,
    unicode: unicode as String?,
    actorId: actorId,
  );
}

bool _hasWorkItemActivityReaction(
  List<WorkItemActivityReaction> reactions, {
  required String actorId,
  required String name,
}) => reactions.any(
  (reaction) => reaction.actorId == actorId && reaction.name == name,
);

void _requireEmptyWorkItemActivityReactionErrors(Object? raw) {
  if (raw is! List || raw.any((error) => error is! String) || raw.isNotEmpty) {
    throw const FormatException('Unconfirmed reaction mutation');
  }
}

void _requireSameWorkItemActivityReactionNote(
  _WorkItemActivityEditNote current,
  _WorkItemActivityEditNote expected, {
  bool compareUpdatedAt = true,
}) {
  final currentNote = current.note;
  final expectedNote = expected.note;
  if (current.internal != expected.internal ||
      current.discussionId != expected.discussionId ||
      current.discussionCreatedAt != expected.discussionCreatedAt ||
      currentNote.id != expectedNote.id ||
      currentNote.system != expectedNote.system ||
      currentNote.body != expectedNote.body ||
      currentNote.createdAt != expectedNote.createdAt ||
      (compareUpdatedAt && currentNote.updatedAt != expectedNote.updatedAt) ||
      currentNote.author?.id != expectedNote.author?.id) {
    throw const FormatException('Changed reaction note');
  }
}
