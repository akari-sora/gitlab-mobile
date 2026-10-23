import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../../../features/ai/ai_write_journal.dart';
import '../../failure.dart';
import '../../gitlab_api.dart';
// Shared model namespace for the snippet family, delivered separately.
// ignore: unused_import
import '../../models.dart';
// ignore: unused_import
import '../../snippet_models.dart';
import '../../suggestion.dart';
import '../../upload_names.dart';
import '../exact_edit.dart';
import 'ci_rules.dart';
import 'schedule_params.dart';
import 'sensitive_paths.dart';
import 'target_binding.dart';
import 'write_ledger.dart';
import 'write_preview.dart';
import 'write_tier.dart' show AiTierFacts;

export '../../../features/ai/ai_write_journal.dart'
    show AiConflictKey, AiJournalState;
export 'write_ledger.dart' show AiWriteScope;
export 'write_preview.dart';

part 'gitlab_write_port_files.dart';
part 'gitlab_write_port_refs.dart';
part 'gitlab_write_port_merge.dart';
part 'gitlab_write_port_ci.dart';
part 'gitlab_write_port_snippets.dart';
part 'gitlab_write_port_deletes.dart';
part 'gitlab_write_port_project.dart';

/// A family preflight refusal; journal failures retain their separate type.
final class AiWriteRefused implements Exception {
  const AiWriteRefused(this.reason);
  final String reason;
}

/// The caller resolves attachment ids and applies write-text policy first.
final class AiWriteRequest {
  AiWriteRequest({
    required this.operationId,
    required this.executionId,
    required AiWriteScope scope,
    required Map<String, Object?> arguments,
    List<int>? uploadBytes,
    this.sendTimeout,
    Set<AiCreatedRef> segmentCreated = const {},
    List<int>? scheduleHmacKey,
  }) : scope = AiWriteScope(
         accountKey: scope.accountKey,
         instance: scope.instance,
         grants: List.unmodifiable(scope.grants),
       ),
       arguments = _freezeMap(arguments),
       segmentCreated = Set.unmodifiable(segmentCreated),
       scheduleHmacKey = scheduleHmacKey == null
           ? null
           : List.unmodifiable(scheduleHmacKey),
       uploadBytes = uploadBytes == null
           ? null
           : List.unmodifiable(uploadBytes);

  final String operationId;
  final String executionId;
  final AiWriteScope scope;
  final Map<String, Object?> arguments;
  final List<int>? uploadBytes;
  final Duration? sendTimeout;
  final Set<AiCreatedRef> segmentCreated;

  /// Process-local only; never part of the payload digest or a preview.
  final List<int>? scheduleHmacKey;
}

sealed class AiWriteOutcome {
  const AiWriteOutcome(this.mutationCount);
  final int mutationCount;
}

final class AiWriteNotSent extends AiWriteOutcome {
  const AiWriteNotSent() : super(0);
}

final class AiWriteSettled extends AiWriteOutcome {
  AiWriteSettled({
    required this.state,
    required this.resultCode,
    required this.releaseName,
    required Set<AiConflictKey> writeKeys,
    required Set<AiConflictKey> dependencyKeys,
    this.httpStatus,
    this.readbackVerified = false,
    Map<String, Object?> projection = const {},
    this.uploadMarkdown,
  }) : writeKeys = Set.unmodifiable(writeKeys),
       dependencyKeys = Set.unmodifiable(dependencyKeys),
       projection = Map.unmodifiable(projection),
       super(1);

  final AiJournalState state;
  final int? httpStatus;
  final bool readbackVerified;
  final String resultCode;
  final String releaseName;
  final Set<AiConflictKey> writeKeys;
  final Set<AiConflictKey> dependencyKeys;
  final Map<String, Object?> projection;

  /// `upload_attachment` only: GitLab's `markdown` for the upload, raw. It
  /// holds the upload's secret path, so it is never projected: the
  /// coordinator keeps it in memory for `[[attachment:att-<n>]]` (§3.1).
  final String? uploadMarkdown;
}

/// Return null to use the ordinary REST classification. Failures distinguish
/// the mutation from its independent readback, including readback-only 401s.
typedef AiResultClassifier = AiWriteSettled? Function(
  AiWritePrepared prepared, {
  Object? result,
  Object? readback,
  Object? mutationError,
  Object? readbackError,
});

/// Process-local, single-use capability. Cannot be forged or moved to a peer.
final class AiWritePrepared {
  AiWritePrepared._({
    required this.request,
    required this.releaseName,
    required Set<AiConflictKey> writeKeys,
    required Set<AiConflictKey> dependencyKeys,
    required Object owner,
    required Future<Object?> Function() mutation,
    Future<Object?> Function(Object? result)? readback,
    this.todoTarget,
    this.projectPath,
    this.projectVisibility,
    // Reserved for the family parts added after this foundation.
    // ignore: unused_element_parameter
    this.confirmName,
    // Reserved for the family parts added after this foundation.
    // ignore: unused_element_parameter
    this.facts = const AiTierFacts(),
    List<AiTargetRef> bindingTargets = const [],
    // Reserved for the family parts added after this foundation.
    // ignore: unused_element_parameter
    this.bindingDigest = '',
    // Reserved for the family parts added after this foundation.
    // ignore: unused_element_parameter
    this.journal = const AiJournalBindings(),
    AiWritePreview? preview,
    // Reserved for the family parts added after this foundation.
    // ignore: unused_element_parameter
    this.textScan,
    AiCreatedRef? createdOnSuccess,
    AiCreatedRef? Function()? resolveCreatedOnSuccess,
    this.classify,
  }) : _createdOnSuccess = createdOnSuccess,
       _resolveCreatedOnSuccess = resolveCreatedOnSuccess,
       writeKeys = Set.unmodifiable(writeKeys),
       dependencyKeys = Set.unmodifiable(dependencyKeys),
       bindingTargets = List.unmodifiable(bindingTargets),
       preview = preview ?? AiFieldsPreview(request.arguments),
       _owner = owner,
       _mutation = mutation,
       _readback = readback;

  final AiWriteRequest request;
  final String releaseName;
  final Set<AiConflictKey> writeKeys;
  final Set<AiConflictKey> dependencyKeys;

  /// `markTodoDone` only: the issue or merge request the pre-read todo is
  /// about, as GitLab returned it (null for other targets). The model gives
  /// only the global todo id (§2).
  final ({int projectId, String resource, int iid})? todoTarget;

  /// The target project's `path_with_namespace` and `visibility` from this
  /// prepare's fresh project read (null for a todo, or when GitLab gave no
  /// visibility).
  final String? projectPath;
  final String? projectVisibility;
  final String? confirmName;
  final AiTierFacts facts;
  final List<AiTargetRef> bindingTargets;
  final String bindingDigest;
  final AiJournalBindings journal;
  final AiWritePreview preview;
  final AiTextScan? textScan;
  final AiCreatedRef? _createdOnSuccess;
  final AiCreatedRef? Function()? _resolveCreatedOnSuccess;

  /// Read by the coordinator only after the commit and journal both succeed.
  AiCreatedRef? get createdOnSuccess =>
      _resolveCreatedOnSuccess?.call() ?? _createdOnSuccess;
  final AiResultClassifier? classify;
  final Object _owner;
  final Future<Object?> Function() _mutation;
  final Future<Object?> Function(Object? result)? _readback;
  bool _used = false;
}

abstract interface class AiGitLabWritePort {
  Future<AiWritePrepared> prepare(AiWriteRequest request);
  Future<AiWriteOutcome> commit(
    AiWritePrepared prepared, {
    required bool Function() mayStart,
  });
}

/// REST only. Journal flush, approval, policy and execution permits belong to
/// the coordinator. This port never retries a mutation or writes to disk.
final class GitLabAiWritePort implements AiGitLabWritePort {
  GitLabAiWritePort(
    this._api, {
    required this.accountKey,
    AiResultClassifier? resultClassifier,
  }) : _resultClassifier = resultClassifier;

  final GitLabApi _api;
  final String accountKey;
  final AiResultClassifier? _resultClassifier;
  final Object _owner = Object();
  final Set<String> _claimedExecutions = <String>{};

  static const uploadMinimumSendTimeout = Duration(seconds: 15);
  static const uploadMaximumSendTimeout = Duration(minutes: 4);
  static const uploadBytesPerSecond = 128 * 1024;

  static Duration uploadSendTimeout(int byteCount) {
    if (byteCount < 0) throw const ApiFailure(FailureKind.validation);
    final micros =
        (byteCount * Duration.microsecondsPerSecond +
            uploadBytesPerSecond -
            1) ~/
        uploadBytesPerSecond;
    return Duration(
      microseconds: math.min(
        uploadMaximumSendTimeout.inMicroseconds,
        math.max(uploadMinimumSendTimeout.inMicroseconds, micros),
      ),
    );
  }

  @override
  Future<AiWritePrepared> prepare(AiWriteRequest request) async {
    final op = request.operationId;
    final capability = productionAiLedger.find(op);
    if (capability == null ||
        request.executionId.isEmpty ||
        request.scope.accountKey != accountKey ||
        request.scope.resolvedInstance?.key != _api.instance.key) {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final a = request.arguments;
    final allowed = _arguments(op);
    if (allowed == null ||
        a.keys.any((key) => !allowed.contains(key)) ||
        (op != 'upload_attachment' &&
            (request.uploadBytes != null || request.sendTimeout != null))) {
      throw const ApiFailure(FailureKind.validation);
    }
    for (final prepareFamily in [
      _prepareFiles,
      _prepareRefs,
      _prepareMerge,
      _prepareCi,
      _prepareSnippets,
      _prepareDeletes,
      _prepareProject,
    ]) {
      final prepared = await prepareFamily(request);
      if (prepared != null) return prepared;
    }
    final user = await _api.currentUser();
    if ('${_api.instance.key}#${user.id}' != accountKey) {
      throw const ApiFailure(FailureKind.unauthenticated);
    }
    if (op == 'markTodoDone') {
      return _prepareTodo(request, user.username, user.id);
    }
    final project = _positive(a, 'projectId');
    final iid = a.containsKey('iid') ? _positive(a, 'iid') : null;
    final resource = switch (capability.scopeClass) {
      AiScopeClass.workItem => 'issues',
      AiScopeClass.mergeRequest => 'merge_requests',
      AiScopeClass.resource => _resource(a),
      _ => null,
    };
    if (!_granted(
      request.scope,
      project,
      resource,
      iid,
      projectOnly: capability.scopeClass == AiScopeClass.project,
      upload: capability.scopeClass == AiScopeClass.projectUpload,
    )) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    final p = await _api.record(['projects', '$project']);
    if (p['id'] != project) throw const ApiFailure(FailureKind.invalidResponse);
    final projectName = _responseText(p, 'path_with_namespace');
    final projectKey = <String>[accountKey, 'project:$project'];
    var target = projectKey;
    var releaseName = projectName;
    Map<String, dynamic>? parent;
    if (resource != null) {
      if (iid == null) throw const ApiFailure(FailureKind.validation);
      parent = await _api.record(['projects', '$project', resource, '$iid']);
      if (parent['project_id'] != project || parent['iid'] != iid) {
        throw const ApiFailure(FailureKind.forbidden);
      }
      target = [
        ...projectKey,
        resource == 'issues' ? 'workItem' : 'mergeRequest',
        '$iid',
      ];
      releaseName = '${resource == 'issues' ? '#' : '!'}${parent['iid']}';
    }
    final dependencies = <AiConflictKey>{};
    var keys = <AiConflictKey>{_key(target)};
    Future<Object?> Function()? mutation;
    Future<Object?> Function(Object?)? readback;
    AiCreatedRef? created;
    final ownerPath = [
      'projects',
      '$project',
      ?resource,
      if (iid != null) '$iid',
    ];
    final fields = _fieldKeys(op) != null
        ? _fields(a, op)
        : <String, dynamic>{};
    switch (op) {
      case 'setStar':
        final value = _boolean(a, 'starred');
        mutation = () => _api.setStar(project, value);
        keys = {
          _key([...projectKey, 'star', '${user.id}']),
        };
      case 'setSubscribed':
        final value = _boolean(a, 'subscribed');
        mutation = () => _api.setSubscribed(project, resource!, iid!, value);
        keys = {
          _key([...target, 'subscription', '${user.id}']),
        };
      case 'createIssue':
        mutation = () => _api.createIssue(project, fields);
        keys = {
          _key([...projectKey, 'workItem']),
        };
        readback = (result) => _api.record([
          'projects',
          '$project',
          'issues',
          '${_resultInt(result, 'iid')}',
        ]);
      case 'updateIssue':
        mutation = () => _api.updateIssue(project, iid!, fields);
        readback = (_) => _api.record(ownerPath);
      case 'createMergeRequest':
        mutation = () => _api.createMergeRequest(project, fields);
        keys = {
          _key([...projectKey, 'mergeRequest']),
        };
        readback = (result) => _api.record([
          'projects',
          '$project',
          'merge_requests',
          '${_resultInt(result, 'iid')}',
        ]);
      case 'updateMergeRequest':
        mutation = () => _api.updateMergeRequest(project, iid!, fields);
        readback = (_) => _api.record(ownerPath);
      case 'unapproveMergeRequest':
        mutation = () => _api.unapproveMergeRequest(project, iid!);
      case 'createTodo':
        mutation = () => _api.createTodo(project, resource!, iid!);
        keys = {
          _key([...target, 'todo', '${user.id}']),
        };
      case 'createNote':
        final body = _text(a, 'body');
        mutation = () => _api.createNote(project, resource!, iid!, body);
        keys = {
          _key([...target, 'notes']),
        };
        readback = (result) =>
            _api.record([...ownerPath, 'notes', '${_resultInt(result, 'id')}']);
      case 'updateNote':
        final note = _positive(a, 'noteId');
        final path = [...ownerPath, 'notes', '$note'];
        final value = await _api.record(path);
        _ownNote(value, note, user.id);
        final body = _text(a, 'body');
        mutation = () => _api.updateNote(project, resource!, iid!, note, body);
        keys = {
          _key([...target, 'notes', '$note']),
        };
        readback = (_) => _api.record(path);
      case 'addAwardEmoji':
      case 'removeAwardEmoji':
        final note = a.containsKey('noteId') ? _positive(a, 'noteId') : null;
        if (note != null) {
          final value = await _api.record([...ownerPath, 'notes', '$note']);
          if (value['id'] != note) {
            throw const ApiFailure(FailureKind.forbidden);
          }
          target = [...target, 'notes', '$note'];
        }
        if (op == 'addAwardEmoji') {
          final name = _text(a, 'name');
          if (!RegExp(r'^[a-zA-Z0-9_+-]{1,100}$').hasMatch(name)) {
            throw const ApiFailure(FailureKind.validation);
          }
          mutation = () =>
              _api.addAwardEmoji(project, resource!, iid!, name, note: note);
          keys = {
            _key([...target, 'award', '${user.id}', name]),
          };
        } else {
          final award = _positive(a, 'awardId');
          final value = await _api.record([
            ...ownerPath,
            if (note != null) ...['notes', '$note'],
            'award_emoji',
            '$award',
          ]);
          _ownNote(value, award, user.id);
          mutation = () => _api.removeAwardEmoji(
            project,
            resource!,
            iid!,
            award,
            note: note,
          );
          keys = {
            _key([
              ...target,
              'award',
              '${user.id}',
              _responseText(value, 'name'),
            ]),
          };
        }
      case 'createDiscussion':
        final body = _text(a, 'body');
        final position = await _position(a, project, resource!, iid!, parent!);
        mutation = () => _api.createDiscussion(
          project,
          resource,
          iid,
          body,
          position: position,
        );
        keys = {
          _key([...target, 'discussions']),
        };
      case 'createDiscussionNote':
      case 'updateDiscussionNote':
      case 'setDiscussionResolved':
        final discussion = _text(a, 'discussionId');
        if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(discussion)) {
          throw const ApiFailure(FailureKind.validation);
        }
        final path = [...ownerPath, 'discussions', discussion];
        final value = await _api.record(path);
        if (value['id'] != discussion) {
          throw const ApiFailure(FailureKind.forbidden);
        }
        keys = {
          _key([...target, 'discussions', discussion]),
        };
        if (op == 'setDiscussionResolved') {
          if (resource != 'merge_requests') {
            throw const ApiFailure(FailureKind.unsupported);
          }
          final resolved = _boolean(a, 'resolved');
          mutation = () => _api.setDiscussionResolved(
            project,
            resource!,
            iid!,
            discussion,
            resolved,
          );
        } else {
          final body = _text(a, 'body');
          if (op == 'createDiscussionNote') {
            mutation = () => _api.createDiscussionNote(
              project,
              resource!,
              iid!,
              discussion,
              body,
            );
          } else {
            final note = _positive(a, 'noteId');
            final notes = value['notes'];
            if (notes is! List) {
              throw const ApiFailure(FailureKind.invalidResponse);
            }
            final found = notes.whereType<Map<String, dynamic>>().where(
              (n) => n['id'] == note,
            );
            if (found.length != 1) {
              throw const ApiFailure(FailureKind.forbidden);
            }
            _ownNote(found.single, note, user.id);
            keys.add(_key([...target, 'notes', '$note']));
            mutation = () => _api.updateDiscussionNote(
              project,
              resource!,
              iid!,
              discussion,
              note,
              body,
            );
          }
        }
        readback = (_) => _api.record(path);
      case 'createDraftNote':
      case 'updateDraftNote':
        final body = _text(a, 'body');
        if (op == 'createDraftNote') {
          final position = await _position(
            a,
            project,
            resource!,
            iid!,
            parent!,
          );
          final commitId = a.containsKey('commitId')
              ? _text(a, 'commitId')
              : null;
          if (commitId != null &&
              (parent['diff_refs'] is! Map ||
                  (parent['diff_refs'] as Map)['head_sha'] != commitId)) {
            throw const ApiFailure(FailureKind.conflict);
          }
          mutation = () async {
            final result = await _api.createDraftNote(
              project,
              iid,
              body,
              commitId: commitId,
              position: position,
            );
            created = AiCreatedRef(accountKey: accountKey,
                kind: AiTargetKind.note, projectId: project,
                id: _resultInt(result, 'id'), parentIid: iid);
            return result;
          };
          keys = {
            _key([...target, 'draftNotes']),
          };
        } else {
          final note = _positive(a, 'noteId');
          final path = [...ownerPath, 'draft_notes', '$note'];
          final value = await _api.record(path);
          if (value['id'] != note) {
            throw const ApiFailure(FailureKind.forbidden);
          }
          // GitLab's draft-note endpoint is current-user scoped.
          mutation = () => _api.updateDraftNote(project, iid!, note, body);
          keys = {
            _key([...target, 'draftNotes', '$note']),
          };
          readback = (_) => _api.record(path);
        }
      case 'createLabel':
        mutation = () => _api.createLabel(project, fields);
        keys = {
          _key([...projectKey, 'labels']),
        };
      case 'updateLabel':
        final id = _positive(a, 'labelId');
        final path = ['projects', '$project', 'labels', '$id'];
        await _verifyId(path, id);
        mutation = () => _api.updateLabel(project, id, fields);
        keys = {
          _key([...projectKey, 'labels', '$id']),
        };
        readback = (_) => _api.record(path);
      case 'createMilestone':
        mutation = () => _api.createMilestone(project, fields);
        keys = {
          _key([...projectKey, 'milestones']),
        };
      case 'updateMilestone':
      case 'setMilestoneState':
        final id = _positive(a, 'milestoneId');
        final path = ['projects', '$project', 'milestones', '$id'];
        await _verifyId(path, id);
        if (op == 'updateMilestone') {
          mutation = () => _api.updateMilestone(project, id, fields);
        } else {
          final event = _text(a, 'stateEvent');
          if (!const {'activate', 'close'}.contains(event)) {
            throw const ApiFailure(FailureKind.validation);
          }
          mutation = () => _api.setMilestoneState(project, id, event);
        }
        keys = {
          _key([...projectKey, 'milestones', '$id']),
        };
        readback = (_) => _api.record(path);
      case 'createBoard':
        final name = _text(a, 'name');
        mutation = () => _api.createBoard(project, name);
        keys = {
          _key([...projectKey, 'boards']),
        };
      case 'renameBoard':
      case 'setBoardSystemListHidden':
      case 'createBoardList':
      case 'moveBoardList':
        final board = _positive(a, 'boardId');
        final path = ['projects', '$project', 'boards', '$board'];
        await _verifyId(path, board);
        keys = {
          _key([...projectKey, 'boards', '$board']),
        };
        switch (op) {
          case 'renameBoard':
            final name = _text(a, 'name');
            mutation = () => _api.renameBoard(project, board, name);
          case 'setBoardSystemListHidden':
            final list = _text(a, 'list');
            if (!const {'backlog', 'closed'}.contains(list)) {
              throw const ApiFailure(FailureKind.validation);
            }
            final hidden = _boolean(a, 'hidden');
            mutation = () =>
                _api.setBoardSystemListHidden(project, board, list, hidden);
          case 'createBoardList':
            final label = _positive(a, 'labelId');
            await _verifyId([
              'projects',
              '$project',
              'labels',
              '$label',
            ], label);
            mutation = () => _api.createBoardList(project, board, label);
          case 'moveBoardList':
            final list = _positive(a, 'listId');
            await _verifyId([...path, 'lists', '$list'], list);
            final position = a['position'];
            if (position is! int || position < 0) {
              throw const ApiFailure(FailureKind.validation);
            }
            mutation = () => _api.moveBoardList(project, board, list, position);
        }
      case 'moveBoardCard':
        mutation = () => _api.moveBoardCard(project, iid!, fields);
        readback = (_) => _api.record(ownerPath);
      case 'upload_attachment':
        final bytes = request.uploadBytes;
        final filename = _text(a, 'filename');
        if (bytes == null ||
            bytes.isEmpty ||
            bytes.any((v) => v < 0 || v > 255) ||
            !projectUploadNamesOk(
              '00000000000000000000000000000000',
              filename,
            ) ||
            filename.length > 255 ||
            filename.contains(RegExp(r'[/\\\x00-\x1f\x7f]')) ||
            filename == '.' ||
            filename == '..') {
          throw const ApiFailure(FailureKind.validation);
        }
        if (bytes.length > GitLabApi.maxUploadBytes) {
          throw const ApiFailure(FailureKind.attachmentTooLarge);
        }
        final timeout = uploadSendTimeout(bytes.length);
        if (request.sendTimeout != null && request.sendTimeout != timeout) {
          throw const ApiFailure(FailureKind.validation);
        }
        final type = a.containsKey('contentType')
            ? _text(a, 'contentType')
            : null;
        if (type != null &&
            !RegExp(
              r'^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$',
            ).hasMatch(type)) {
          throw const ApiFailure(FailureKind.validation);
        }
        mutation = () => _api.uploadProjectFile(
          project,
          filename: filename,
          bytes: bytes,
          contentType: type,
          sendTimeout: timeout,
        );
        releaseName = filename;
        keys = {
          _key([...projectKey, 'upload', sha256.convert(bytes).toString()]),
        };
    }
    if (mutation == null) throw const ApiFailure(FailureKind.unsupported);
    final visibility = p['visibility'];
    final classifier = op == 'unapproveMergeRequest'
        ? (
            AiWritePrepared prepared, {
            Object? result,
            Object? readback,
            Object? mutationError,
            Object? readbackError,
          }) {
            if (mutationError is ApiFailure &&
                const {405, 406, 409, 422}.contains(mutationError.status)) {
              return _outcome(
                prepared,
                AiJournalState.failedCertain,
                mutationError.kind.name,
                status: mutationError.status,
              );
            }
            return _resultClassifier?.call(
              prepared,
              result: result,
              readback: readback,
              mutationError: mutationError,
              readbackError: readbackError,
            );
          }
        : _resultClassifier;
    return AiWritePrepared._(
      request: request,
      classify: classifier,
      releaseName: releaseName,
      writeKeys: keys,
      dependencyKeys: dependencies,
      owner: _owner,
      mutation: mutation,
      readback: readback,
      resolveCreatedOnSuccess: () => created,
      projectPath: projectName,
      projectVisibility: visibility is String ? visibility : null,
    );
  }

  @override
  Future<AiWriteOutcome> commit(
    AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) {
    if (!identical(prepared._owner, _owner) ||
        prepared._used ||
        !_claimedExecutions.add(prepared.request.executionId)) {
      return Future.value(const AiWriteNotSent());
    }
    prepared._used = true;
    if (!mayStart()) return Future.value(const AiWriteNotSent());
    return _settle(prepared, prepared._mutation, classify: prepared.classify);
  }

  Future<AiWriteOutcome> _settle(
    AiWritePrepared p,
    Future<Object?> Function() mutation, {
    AiResultClassifier? classify,
  }) async {
    AiWriteSettled? classified({
      Object? result,
      Object? readback,
      Object? mutationError,
      Object? readbackError,
    }) {
      try {
        return classify?.call(
          p,
          result: result,
          readback: readback,
          mutationError: mutationError,
          readbackError: readbackError,
        );
      } catch (_) {
        return _outcome(p, AiJournalState.writeUncertain, 'invalidResponse');
      }
    }

    Object? result;
    Object? readback;
    try {
      result = await mutation();
    } on ApiFailure catch (failure) {
      final override = classified(mutationError: failure);
      if (override != null) return override;
      final certain =
          failure.status == 401 ||
          const {
            FailureKind.validation,
            FailureKind.forbidden,
            FailureKind.invisible,
            FailureKind.conflict,
            FailureKind.rateLimited,
            FailureKind.unsupported,
            FailureKind.attachmentTooLarge,
          }.contains(failure.kind);
      return _outcome(
        p,
        certain ? AiJournalState.failedCertain : AiJournalState.writeUncertain,
        failure.status == 401
            ? (gitLabMutation401ResultCode(failure) ?? 'sessionExpired')
            : failure.kind.name,
        status: failure.status,
      );
    } catch (error) {
      return classified(mutationError: error) ??
          _outcome(p, AiJournalState.writeUncertain, 'invalidResponse');
    }
    if (p._readback != null) {
      try {
        readback = await p._readback(result);
      } catch (error) {
        // A readback 401 is never the mutation's known HTTP refusal.
        return classified(result: result, readbackError: error) ??
            _outcome(p, AiJournalState.writeUncertain, 'readbackFailed');
      }
    }
    final override = classified(result: result, readback: readback);
    if (override != null) return override;
    final projection = <String, Object?>{};
    if (result is Map) {
      for (final key in const ['id', 'iid', 'state', 'resolved', 'position']) {
        final value = result[key];
        if (value is int ||
            value is bool ||
            (key == 'state' &&
                const {
                  'opened',
                  'closed',
                  'active',
                  'merged',
                }.contains(value))) {
          projection[key] = value;
        }
      }
    }
    final markdown = result is Map ? result['markdown'] : null;
    return _outcome(
      p,
      AiJournalState.succeeded,
      'succeeded',
      readbackVerified: p._readback != null,
      projection: projection,
      uploadMarkdown:
          p.request.operationId == 'upload_attachment' && markdown is String
          ? markdown
          : null,
    );
  }

  AiWriteSettled _outcome(
    AiWritePrepared p,
    AiJournalState state,
    String code, {
    int? status,
    Map<String, Object?> projection = const {},
    String? uploadMarkdown,
    bool readbackVerified = false,
  }) => AiWriteSettled(
    state: state,
    resultCode: code,
    httpStatus: status,
    readbackVerified: readbackVerified,
    releaseName: p.releaseName,
    writeKeys: p.writeKeys,
    dependencyKeys: p.dependencyKeys,
    projection: projection,
    uploadMarkdown: uploadMarkdown,
  );

  Future<void> _verifyId(List<String> path, int id) async {
    final value = await _api.record(path);
    if (value['id'] != id) throw const ApiFailure(FailureKind.forbidden);
  }

  Future<AiWritePrepared> _prepareTodo(
    AiWriteRequest r,
    String username,
    int userId,
  ) async {
    final id = _positive(r.arguments, 'todoId');
    final grants = r.scope.grants;
    if (grants.isEmpty) throw const ApiFailure(FailureKind.forbidden);
    Map<String, dynamic>? todo;
    Uri? next;
    for (var page = 0; page < 4; page++) {
      final values = await _api.records(
        ['todos'],
        query: const {'per_page': '100'},
        next: next,
      );
      for (final value in values.items) {
        if (value['id'] == id) todo = value;
      }
      if (todo != null || values.next == null) break;
      next = values.next;
    }
    if (todo == null) throw const ApiFailure(FailureKind.forbidden);
    final project = todo['project'];
    final target = todo['target'];
    final type = todo['target_type'];
    final resource = type == 'Issue'
        ? 'issues'
        : type == 'MergeRequest'
        ? 'merge_requests'
        : null;
    final global = grants.any((g) => g.kind == AiScopeKind.accountGlobal);
    final projectId = project is Map ? project['id'] : null;
    final iid = target is Map ? target['iid'] : null;
    if (!global &&
        (projectId is! int ||
            iid is! int ||
            resource == null ||
            !_granted(r.scope, projectId, resource, iid))) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    return AiWritePrepared._(
      request: r,
      classify: _resultClassifier,
      releaseName: '@$username',
      writeKeys: {
        _key([accountKey, 'todos', '$id']),
        if (projectId is int && iid is int && resource != null)
          _key([
            accountKey,
            'project:$projectId',
            resource == 'issues' ? 'workItem' : 'mergeRequest',
            '$iid',
            'todo',
            '$userId',
          ]),
      },
      dependencyKeys: const {},
      owner: _owner,
      mutation: () => _api.markTodoDone(id),
      todoTarget: projectId is int && iid is int && resource != null
          ? (projectId: projectId, resource: resource, iid: iid)
          : null,
    );
  }

  Future<Map<String, dynamic>?> _position(
    Map<String, Object?> a,
    int project,
    String resource,
    int iid,
    Map<String, dynamic> parent,
  ) async {
    if (!a.containsKey('position')) return null;
    if (resource != 'merge_requests') {
      throw const ApiFailure(FailureKind.unsupported);
    }
    final raw = a['position'];
    if (raw is! Map<String, Object?> ||
        raw.keys.any(
          (k) => !const {
            'position_type',
            'base_sha',
            'start_sha',
            'head_sha',
            'old_path',
            'new_path',
            'old_line',
            'new_line',
          }.contains(k),
        ) ||
        raw['position_type'] != 'text') {
      throw const ApiFailure(FailureKind.validation);
    }
    final refs = parent['diff_refs'];
    if (refs is! Map ||
        const [
          'base_sha',
          'start_sha',
          'head_sha',
        ].any((k) => raw[k] is! String || raw[k] != refs[k])) {
      throw const ApiFailure(FailureKind.conflict);
    }
    for (final k in const ['old_line', 'new_line']) {
      if (raw.containsKey(k) && (raw[k] is! int || (raw[k]! as int) <= 0)) {
        throw const ApiFailure(FailureKind.validation);
      }
    }
    if (!raw.containsKey('old_line') && !raw.containsKey('new_line')) {
      throw const ApiFailure(FailureKind.validation);
    }
    final changes = await _api.record([
      'projects',
      '$project',
      'merge_requests',
      '$iid',
      'changes',
    ]);
    final files = changes['changes'];
    if (files is! List ||
        !files.whereType<Map<String, dynamic>>().any(
          (f) =>
              f['old_path'] == raw['old_path'] &&
              f['new_path'] == raw['new_path'],
        )) {
      throw const ApiFailure(FailureKind.forbidden);
    }
    return Map<String, dynamic>.from(raw);
  }
}

AiConflictKey _key(List<String> parts) =>
    AiConflictKey(List.unmodifiable(parts));

bool _granted(
  AiWriteScope scope,
  int project,
  String? resource,
  int? iid, {
  bool projectOnly = false,
  bool upload = false,
}) => scope.grants.any(
  (g) =>
      g.projectId == project &&
      (g.kind == AiScopeKind.project ||
          (upload &&
              (g.kind == AiScopeKind.workItem ||
                  g.kind == AiScopeKind.mergeRequest)) ||
          (!projectOnly &&
              iid != null &&
              g.iid == iid &&
              ((g.kind == AiScopeKind.workItem && resource == 'issues') ||
                  (g.kind == AiScopeKind.mergeRequest &&
                      resource == 'merge_requests')))),
);

int _positive(Map<String, Object?> a, String key) {
  final value = a[key];
  if (value is! int || value <= 0) {
    throw const ApiFailure(FailureKind.validation);
  }
  return value;
}

String _text(Map<String, Object?> a, String key) {
  final value = a[key];
  if (value is! String || value.trim().isEmpty) {
    throw const ApiFailure(FailureKind.validation);
  }
  return value;
}

bool _boolean(Map<String, Object?> a, String key) {
  final value = a[key];
  if (value is! bool) throw const ApiFailure(FailureKind.validation);
  return value;
}

String _resource(Map<String, Object?> a) {
  final value = _text(a, 'resource');
  if (!const {'issues', 'merge_requests'}.contains(value)) {
    throw const ApiFailure(FailureKind.unsupported);
  }
  return value;
}

String _responseText(Map<String, dynamic> a, String key) {
  final value = a[key];
  if (value is! String || value.isEmpty) {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
  return value;
}

int _resultInt(Object? value, String key) {
  if (value is! Map<String, Object?>) {
    throw const ApiFailure(FailureKind.invalidResponse);
  }
  return _positive(value, key);
}

void _ownNote(Map<String, dynamic> value, int id, int user) {
  final author = value['author'] ?? value['user'];
  if (value['id'] != id || author is! Map || author['id'] != user) {
    throw const ApiFailure(FailureKind.forbidden);
  }
}

Map<String, Object?> _freezeMap(Map<String, Object?> value) {
  Object? freeze(Object? v) {
    if (v is Map<String, Object?>) {
      return Map<String, Object?>.unmodifiable(
        v.map((k, v) => MapEntry(k, freeze(v))),
      );
    }
    if (v is List) return List<Object?>.unmodifiable(v.map(freeze));
    if (v == null || v is String || v is bool || v is int || v is double) {
      return v;
    }
    throw const ApiFailure(FailureKind.validation);
  }

  // Reject non-JSON values, non-finite numbers and cyclic input before awaits.
  try {
    return freeze(jsonDecode(jsonEncode(value)))! as Map<String, Object?>;
  } catch (_) {
    throw const ApiFailure(FailureKind.validation);
  }
}

Map<String, dynamic> _fields(Map<String, Object?> a, String op) {
  final raw = a['fields'];
  final allowed = _fieldKeys(op);
  if (raw is! Map<String, Object?> ||
      raw.isEmpty ||
      allowed == null ||
      raw.keys.any((key) => !allowed.contains(key))) {
    throw const ApiFailure(FailureKind.validation);
  }
  if (op == 'createIssue' &&
      raw.containsKey('issue_type') &&
      !const {'issue', 'task', 'incident'}.contains(raw['issue_type'])) {
    throw const ApiFailure(FailureKind.validation);
  }
  if (raw.containsKey('state_event') &&
      !const {'close', 'reopen'}.contains(raw['state_event'])) {
    throw const ApiFailure(FailureKind.validation);
  }
  for (final key in const ['assignee_ids', 'reviewer_ids']) {
    if (raw.containsKey(key) &&
        (raw[key] is! List ||
            (raw[key]! as List).any((v) => v is! int || v <= 0))) {
      throw const ApiFailure(FailureKind.validation);
    }
  }
  if (raw.containsKey('confidential') && raw['confidential'] is! bool) {
    throw const ApiFailure(FailureKind.validation);
  }
  if (raw.containsKey('milestone_id') &&
      raw['milestone_id'] != null &&
      (raw['milestone_id'] is! int || (raw['milestone_id']! as int) < 0)) {
    throw const ApiFailure(FailureKind.validation);
  }
  if (raw.containsKey('severity') &&
      !const {
        'unknown',
        'low',
        'medium',
        'high',
        'critical',
      }.contains(raw['severity'])) {
    throw const ApiFailure(FailureKind.validation);
  }
  for (final key in allowed.difference(const {
    'assignee_ids',
    'reviewer_ids',
    'confidential',
    'milestone_id',
  })) {
    if (raw.containsKey(key) && raw[key] is! String) {
      throw const ApiFailure(FailureKind.validation);
    }
  }
  if (op.startsWith('create')) {
    for (final key
        in op == 'createMergeRequest'
            ? const ['title', 'source_branch', 'target_branch']
            : op == 'createLabel'
            ? const ['name', 'color']
            : const ['title']) {
      _text(raw, key);
    }
  }
  return Map<String, dynamic>.from(raw);
}

Set<String>? _fieldKeys(String operation) => productionAiLedger
    .find(operation)
    ?.arguments['fields']
    ?.properties.keys.toSet();

Set<String>? _arguments(String operation) =>
    productionAiLedger.find(operation)?.arguments.entries
        .where((entry) => entry.value.portVisible)
        .map((entry) => entry.key)
        .toSet();
