part of 'gitlab_write_port.dart';

typedef AiProjectWorkItemDetailReader =
    Future<WorkItemGraphDetail> Function(Project project, int iid);

typedef AiWorkItemActivityFirstReader =
    Future<WorkItemActivityPage> Function(WorkItemGraphSummary expected);

typedef AiWorkItemActivityNextReader =
    Future<WorkItemActivityPage> Function(
      WorkItemActivityContinuation continuation,
    );

typedef AiWorkItemDiscussionNotesNextReader =
    Future<WorkItemDiscussionNotesPage> Function(
      WorkItemDiscussionNotesContinuation continuation,
    );

final class AiProjectWorkItemLocation {
  const AiProjectWorkItemLocation({
    required this.project,
    required this.detail,
  });

  final Project project;
  final WorkItemGraphDetail detail;
}

final class AiWorkItemActivityNoteLocation {
  const AiWorkItemActivityNoteLocation({
    required this.discussion,
    required this.note,
    required this.replyTarget,
  });

  final WorkItemActivityDiscussion discussion;
  final WorkItemActivityNote note;
  final WorkItemActivityReplyTarget? replyTarget;
}

/// Resolves a project Work Item only from the conversation's immutable grant.
///
/// The injected reader must stay bound to the account, instance and generation
/// that produced [scope]. This helper deliberately accepts no API object.
Future<AiProjectWorkItemLocation> resolveAiProjectWorkItem(
  AiWriteScope scope,
  int projectId,
  int iid, {
  required AiProjectWorkItemDetailReader readDetail,
}) async {
  if (projectId <= 0 || iid <= 0) {
    throw const AiWriteRefused('workItemUnverifiable');
  }
  final grants = scope.grants.where(
    (grant) =>
        grant.projectId == projectId &&
        (grant.kind == AiScopeKind.project ||
            (grant.kind == AiScopeKind.workItem && grant.iid == iid)),
  );
  String? projectPath;
  for (final grant in grants) {
    final path = grant.projectPath;
    if (path == null || !_validAiProjectPath(path)) {
      throw const AiWriteRefused('workItemUnverifiable');
    }
    if (projectPath != null && projectPath != path) {
      throw const AiWriteRefused('workItemUnverifiable');
    }
    projectPath = path;
  }
  if (projectPath == null) {
    throw const AiWriteRefused('workItemUnverifiable');
  }

  final project = Project(id: projectId, name: projectPath, path: projectPath);
  final detail = await readDetail(project, iid);
  final summary = detail.summary;
  final expectedProjectId = 'gid://gitlab/Project/$projectId';
  final projectRef = summary.project;
  final namespaceRef = summary.namespace;
  if (!_validAiWorkItemId(summary.id) ||
      summary.iid != iid ||
      projectRef?.id != expectedProjectId ||
      projectRef?.fullPath != projectPath ||
      namespaceRef == null ||
      !_validAiProjectWorkItemNamespace(namespaceRef, projectPath)) {
    throw const AiWriteRefused('workItemUnverifiable');
  }
  return AiProjectWorkItemLocation(project: project, detail: detail);
}

/// Locates one ordinary numeric note with at most two logical activity reads.
///
/// A result is returned only after every continuation that can affect the
/// target's identity, parent or uniqueness has been exhausted. When two reads
/// cannot prove that, this helper refuses instead of treating a partial page as
/// absence. The injected first reader must disable the legacy fallback.
Future<AiWorkItemActivityNoteLocation> locateAiWorkItemActivityNote(
  WorkItemGraphDetail detail,
  int noteId, {
  required AiWorkItemActivityFirstReader first,
  required AiWorkItemActivityNextReader next,
  required AiWorkItemDiscussionNotesNextReader notesNext,
}) async {
  if (noteId <= 0) throw const AiWriteRefused('noteMissing');
  var reads = 0;
  final discussions = <String, WorkItemActivityDiscussion>{};
  final notes = <String, _AiLocatedActivityNote>{};
  final pendingNotes = <_AiPendingNotes>[];
  WorkItemActivityContinuation? pendingActivity;

  void addActivityPage(WorkItemActivityPage page) {
    _requireAiActivityIdentity(page, detail.summary);
    if (!page.controlsSupported ||
        page.snapshot.availability != WorkItemActivityAvailability.present ||
        page.snapshot.discussions.availability !=
            WorkItemActivityConnectionAvailability.present) {
      throw const AiWriteRefused('activityUnverifiable');
    }
    final pageDiscussionIds = <String>{};
    for (final discussion in page.snapshot.discussions.items) {
      if (discussions.containsKey(discussion.id)) {
        throw const AiWriteRefused('activityUnverifiable');
      }
      if (!_validAiDiscussionId(discussion.id) ||
          !_validAiReplyId(discussion.replyId) ||
          discussion.notes.availability !=
              WorkItemActivityConnectionAvailability.present) {
        throw const AiWriteRefused('activityUnverifiable');
      }
      pageDiscussionIds.add(discussion.id);
      discussions[discussion.id] = discussion;
      _addAiActivityNotes(
        notes,
        discussion,
        discussion.notes.items,
        page.replyTargetsByNote,
      );
      final continuation = page.nextNotesByDiscussion[discussion.id];
      if (continuation != null) {
        pendingNotes.add((discussion: discussion, continuation: continuation));
      }
    }
    if (page.nextNotesByDiscussion.keys.any(
          (id) => !pageDiscussionIds.contains(id),
        ) ||
        page.replyTargetsByDiscussion.keys.any(
          (id) => !pageDiscussionIds.contains(id),
        )) {
      throw const AiWriteRefused('activityUnverifiable');
    }
    pendingActivity = page.nextDiscussions;
  }

  reads += 1;
  addActivityPage(await first(detail.summary));

  final continuationCount =
      pendingNotes.length + (pendingActivity == null ? 0 : 1);
  if (continuationCount > 1) {
    throw const AiWriteRefused('activityUnverifiable');
  }
  if (continuationCount == 1) {
    if (reads >= 2) throw const AiWriteRefused('activityUnverifiable');
    reads += 1;
    if (pendingNotes.isNotEmpty) {
      final pending = pendingNotes.single;
      final page = await notesNext(pending.continuation);
      if (page.workItemId != detail.summary.id ||
          page.discussionId != pending.discussion.id ||
          page.notes.availability !=
              WorkItemActivityConnectionAvailability.present ||
          page.next != null) {
        throw const AiWriteRefused('activityUnverifiable');
      }
      _addAiActivityNotes(
        notes,
        pending.discussion,
        page.notes.items,
        page.replyTargetsByNote,
      );
      pendingNotes.clear();
    } else {
      final continuation = pendingActivity!;
      pendingActivity = null;
      addActivityPage(await next(continuation));
      if (pendingActivity != null || pendingNotes.isNotEmpty) {
        throw const AiWriteRefused('activityUnverifiable');
      }
    }
  }

  final matches = notes.entries
      .where((entry) => _aiNoteNumericId(entry.key) == noteId)
      .map((entry) => entry.value)
      .toList(growable: false);
  if (matches.isEmpty) throw const AiWriteRefused('noteMissing');
  if (matches.length != 1) {
    throw const AiWriteRefused('activityUnverifiable');
  }
  final found = matches.single;
  if (found.note.system) {
    throw const AiWriteRefused('activityUnverifiable');
  }
  return AiWorkItemActivityNoteLocation(
    discussion: found.discussion,
    note: found.note,
    replyTarget: found.replyTarget,
  );
}

typedef _AiPendingNotes = ({
  WorkItemActivityDiscussion discussion,
  WorkItemDiscussionNotesContinuation continuation,
});

typedef _AiLocatedActivityNote = ({
  WorkItemActivityDiscussion discussion,
  WorkItemActivityNote note,
  WorkItemActivityReplyTarget? replyTarget,
});

void _addAiActivityNotes(
  Map<String, _AiLocatedActivityNote> found,
  WorkItemActivityDiscussion discussion,
  List<WorkItemActivityNote> notes,
  Map<String, WorkItemActivityReplyTarget> replyTargetsByNote,
) {
  for (final note in notes) {
    final numericId = _aiNoteNumericId(note.id);
    final author = note.author;
    if (numericId == null ||
        note.updatedAt.isBefore(note.createdAt) ||
        (!note.system &&
            (author == null ||
                !_validAiUserId(author.id) ||
                author.username.isEmpty ||
                author.username != author.username.trim())) ||
        found.keys.any((id) => _aiNoteNumericId(id) == numericId)) {
      throw const AiWriteRefused('activityUnverifiable');
    }
    found[note.id] = (
      discussion: discussion,
      note: note,
      replyTarget: replyTargetsByNote[note.id],
    );
  }
}

void _requireAiActivityIdentity(
  WorkItemActivityPage page,
  WorkItemGraphSummary expected,
) {
  final snapshot = page.snapshot;
  if (snapshot.workItemId != expected.id ||
      snapshot.iid != expected.iid ||
      snapshot.project?.id != expected.project?.id ||
      snapshot.project?.fullPath != expected.project?.fullPath ||
      snapshot.namespace?.id != expected.namespace?.id ||
      snapshot.namespace?.fullPath != expected.namespace?.fullPath) {
    throw const AiWriteRefused('activityUnverifiable');
  }
}

bool _validAiProjectPath(String value) =>
    value == value.trim() &&
    value.length <= 1024 &&
    RegExp(r'^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$').hasMatch(value);

bool _validAiWorkItemId(String value) =>
    RegExp(r'^gid://gitlab/WorkItem/[1-9][0-9]*$').hasMatch(value);

bool _validAiProjectWorkItemNamespace(
  GraphResourceRef namespace,
  String projectPath,
) {
  if (_validAiOpaqueGid(namespace.id, const {'Namespaces::ProjectNamespace'}) &&
      namespace.fullPath == projectPath) {
    return true;
  }
  final separator = projectPath.lastIndexOf('/');
  return separator > 0 &&
      _validAiOpaqueGid(namespace.id, const {'Group'}) &&
      namespace.fullPath == projectPath.substring(0, separator);
}

bool _validAiDiscussionId(String value) =>
    _validAiOpaqueGid(value, const {'Discussion'});

bool _validAiReplyId(String value) =>
    _validAiOpaqueGid(value, const {'Discussion', 'IndividualNoteDiscussion'});

int? _aiNoteNumericId(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'gid' ||
      uri.host != 'gitlab' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.pathSegments.length != 2 ||
      !const {'Note', 'DiscussionNote'}.contains(uri.pathSegments.first)) {
    return null;
  }
  final id = int.tryParse(uri.pathSegments.last);
  return id == null || id <= 0 ? null : id;
}

bool _validAiUserId(String value) =>
    RegExp(r'^gid://gitlab/User/[1-9][0-9]*$').hasMatch(value);

bool _validAiOpaqueGid(String value, Set<String> types) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'gid' &&
      uri.host == 'gitlab' &&
      uri.userInfo.isEmpty &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      uri.pathSegments.length == 2 &&
      types.contains(uri.pathSegments.first) &&
      uri.pathSegments.last.isNotEmpty;
}
