part of 'gitlab_api.dart';

final _workItemActivityDestroyNoteMutation = '''
mutation MobileDestroyWorkItemActivityNote(\$input: DestroyNoteInput!) {
  destroyNote(input: \$input) { errors }
}
''';

final _workItemActivityDeleteReadbackQuery =
    '''
query MobileWorkItemActivityDeleteReadback(
  \$workItemId: WorkItemID!
  \$noteId: NoteID!
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
  }
}
''';

/// Fresh server permission for deleting one existing ordinary public note.
/// Activity reading remains independent when an older schema lacks this path.
final class WorkItemActivityDeleteAccess {
  const WorkItemActivityDeleteAccess._({
    required this.canDeleteNote,
    required this.target,
  });

  final bool canDeleteNote;
  final WorkItemActivityDeleteTarget? target;
}

/// One delete attempt bound to the API owner, actor and displayed note revision.
final class WorkItemActivityDeleteTarget {
  WorkItemActivityDeleteTarget._({
    required GitLabApi owner,
    required _WorkItemActivityIdentity identity,
    required String actorId,
    required _WorkItemActivityEditNote original,
  }) : _owner = owner,
       _identity = identity,
       _actorId = actorId,
       _original = original;

  final GitLabApi _owner;
  final _WorkItemActivityIdentity _identity;
  final String _actorId;
  final _WorkItemActivityEditNote _original;
  bool _consumed = false;

  WorkItemActivityNote get note => _original.note;
}

extension WorkItemActivityDeleteApi on GitLabApi {
  Future<WorkItemActivityDeleteAccess> workItemActivityDeleteAccess(
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
    final preflight = await _readActivityEditPreflight(
      identity,
      noteId: expectedNote.id,
      discussionId: discussion.id,
      discussionCreatedAt: discussion.createdAt,
      isCurrent: isCurrent,
    );
    _requireDisplayedActivityNote(preflight.value.note, expectedNote);
    return WorkItemActivityDeleteAccess._(
      canDeleteNote: preflight.canEditNote,
      target: preflight.canEditNote
          ? WorkItemActivityDeleteTarget._(
              owner: this,
              identity: identity,
              actorId: preflight.actorId!,
              original: preflight.value,
            )
          : null,
    );
  }

  /// Deletes one validated public note. GitLab's mutation has no deleted-note
  /// payload or compare-and-swap revision. An empty mutation error list plus an
  /// independent read showing the same actor and parent while the exact note
  /// key is explicitly null is the strongest available acknowledgement. Once
  /// sent, every other outcome is uncertain and this target cannot be replayed.
  Future<void> deleteWorkItemActivityNote(
    WorkItemActivityDeleteTarget target, {
    bool Function()? isCurrent,
  }) async {
    _requireActivityOwner(target._owner);
    if (target._consumed) {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
    final preflight = await _readActivityEditPreflight(
      target._identity,
      noteId: target.note.id,
      discussionId: target._original.discussionId,
      discussionCreatedAt: target._original.discussionCreatedAt,
      isCurrent: isCurrent,
    );
    if (!preflight.canEditNote) {
      throw ApiFailure(
        FailureKind.forbidden,
        title: l10n.cannotDeleteThisComment,
        detail: l10n.noPermissionDeleteComment,
      );
    }
    if (preflight.actorId != target._actorId) {
      throw const ApiFailure(FailureKind.cancelled);
    }
    _requireDisplayedActivityNote(preflight.value.note, target.note);
    _requireCurrentWorkItemRequest(isCurrent);
    if (target._consumed) {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
    target._consumed = true;

    try {
      final response = await _send(
        instance.graphQL,
        method: 'POST',
        graphMutation: true,
        data: {
          'query': _workItemActivityDestroyNoteMutation,
          'variables': {
            'input': {'id': target.note.id},
          },
        },
      );
      _requireCurrentWorkItemRequest(isCurrent);
      final payload = objectJson(
        _workItemGraphData(response.bytes)['destroyNote'],
      );
      final errors = payload['errors'];
      if (errors is! List ||
          errors.any((error) => error is! String) ||
          errors.isNotEmpty) {
        throw const FormatException('Unconfirmed note deletion');
      }
    } on Object {
      throw const ApiFailure(FailureKind.writeUncertain);
    }

    try {
      _requireCurrentWorkItemRequest(isCurrent);
      final response = await _read(
        instance.graphQL,
        method: 'POST',
        graphQuery: true,
        data: {
          'query': _workItemActivityDeleteReadbackQuery,
          'variables': {
            'workItemId': target._identity.id,
            'noteId': target.note.id,
          },
        },
      );
      _requireCurrentWorkItemRequest(isCurrent);
      final data = _workItemGraphData(response.bytes);
      if (data['currentUser'] == null || data['workItem'] == null) {
        throw const FormatException('Missing deletion readback scope');
      }
      final actorId = requiredString(objectJson(data['currentUser']), 'id');
      if (actorId != target._actorId ||
          !_isGraphIdType(actorId, const {'User'})) {
        throw const FormatException('Changed deletion readback actor');
      }
      _requireActivityIdentity(
        _parseAttributeIdentity(objectJson(data['workItem'])),
        target._identity,
      );
      if (!data.containsKey('note') || data['note'] != null) {
        throw const FormatException('Note deletion not independently visible');
      }
    } on Object {
      throw const ApiFailure(FailureKind.writeUncertain);
    }
  }
}
