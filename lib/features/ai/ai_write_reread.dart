import '../../core/ai/tools/write_ledger.dart' show AiWriteLimits;
import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/instance.dart';
import '../../core/models.dart';
import '../../core/request_meter.dart';
import 'ai_write_journal.dart';

// Plan v6 §7.6 「重新讀取以確認（只產生觀察，不解除）」 and the GitLab link of
// an interrupted AI write (§15 row 5).
//
// A re-read issues at most AiWriteLimits.rereadHttp GET requests through the
// existing read wrappers, stores what it saw as the entry's observation and
// never changes the entry's state. Releasing the lock still needs the typed
// name (AiWriteJournal.releaseByUser). The observation holds fixed codes and
// numbers only, never titles, bodies or other server text.

/// What the re-read found for its subject. [absent] follows the ambiguous 404
/// rule: not found, or not visible to this account.
enum AiRereadPresence { present, absent, unknown }

/// The resource the re-read looked at.
enum AiRereadSubject {
  project,
  issue,
  mergeRequest,
  note,
  discussion,
  draftNote,
  label,
  milestone,
  board,
  award,
  upload,
  todo,
}

/// A fixed code beside the presence: the subject's state, or why the
/// presence is unknown.
enum AiRereadDetail {
  opened,
  closed,
  merged,
  locked,
  active,
  subscribed,
  notSubscribed,
  resolved,
  unresolved,
  pending,
  notPending,

  /// A create whose result cannot be matched without stored content.
  notComparable,

  /// The entry's target has a shape this version cannot read.
  unsupported,
  forbidden,
  rateLimited,
  unavailable,
  budgetExhausted,
}

final class AiRereadObservation {
  const AiRereadObservation({
    required this.presence,
    required this.subject,
    required this.observedAt,
    this.detail,
    this.matches,
  });

  static const prefix = 'reread.v1';

  final AiRereadPresence presence;
  final AiRereadSubject subject;
  final AiRereadDetail? detail;

  /// Reserved for create observations that have a conservative server identity.
  /// This version does not infer identity from a device-clock window or count.
  final int? matches;
  final DateTime observedAt;

  /// One line for [AiJournalEntry.observation].
  String encode() => [
    prefix,
    presence.name,
    subject.name,
    detail?.name ?? '-',
    matches?.toString() ?? '-',
    observedAt.toUtc().toIso8601String(),
  ].join(';');

  /// Null for anything [encode] did not write, such as an older code.
  static AiRereadObservation? decode(String? value) {
    final parts = value?.split(';');
    if (parts == null || parts.length != 6 || parts[0] != prefix) return null;
    final presence = _byName(AiRereadPresence.values, parts[1]);
    final subject = _byName(AiRereadSubject.values, parts[2]);
    final detail = parts[3] == '-'
        ? null
        : _byName(AiRereadDetail.values, parts[3]);
    final matches = parts[4] == '-' ? null : int.tryParse(parts[4]);
    final at = DateTime.tryParse(parts[5]);
    if (presence == null ||
        subject == null ||
        (parts[3] != '-' && detail == null) ||
        (parts[4] != '-' && (matches == null || matches < 0)) ||
        at == null ||
        !at.isUtc) {
      return null;
    }
    return AiRereadObservation(
      presence: presence,
      subject: subject,
      detail: detail,
      matches: matches,
      observedAt: at,
    );
  }
}

final class AiRereadResult {
  const AiRereadResult({
    required this.observation,
    required this.requests,
    this.projectPath,
  });
  final AiRereadObservation observation;

  /// GitLab requests made, at most [AiWriteLimits.rereadHttp].
  final int requests;

  /// `path_with_namespace` read for the entry's numeric project id, already
  /// checked by [aiJournalTargetWebUri]'s rules. Not stored in the journal.
  final String? projectPath;
}

/// Re-reads the target of an interrupted write and records the observation.
///
/// Throws [AiJournalException] without any request when the entry is not
/// interrupted (`notInterrupted`), when its original request may still be in
/// flight (`inFlight`, §15 row 5) or when [api] is not [accountKey]'s client
/// (`accountMismatch`). Only GET requests are made.
Future<AiRereadResult> rereadInterruptedWrite({
  required AiWriteJournal journal,
  required String accountKey,
  required String executionId,
  required GitLabApi api,
  DateTime Function()? now,
}) async {
  final entry = journal.rereadableEntry(accountKey, executionId);
  final userId = _userIdOf(accountKey, api.instance);
  if (userId == null ||
      entry.accountKey != accountKey ||
      entry.instanceKey != api.instance.key) {
    throw const AiJournalException('accountMismatch');
  }
  final reads = _Reads(api);
  _Seen seen;
  try {
    // Never reads, or records, through another account's credentials.
    final user = await reads.user();
    if (user.id != userId) throw const AiJournalException('accountMismatch');
    seen = await _observe(reads, entry);
  } on AiJournalException {
    rethrow;
  } on _Exhausted {
    seen = const _Seen.unknown(
      AiRereadSubject.project,
      AiRereadDetail.budgetExhausted,
    );
  } on ApiFailure catch (failure) {
    seen = _Seen.unknown(AiRereadSubject.project, _detailFor(failure));
  } on Object {
    seen = const _Seen.unknown(
      AiRereadSubject.project,
      AiRereadDetail.unavailable,
    );
  }
  final observation = AiRereadObservation(
    presence: seen.presence,
    subject: seen.subject,
    detail: seen.detail,
    matches: seen.matches,
    observedAt: (now ?? DateTime.now)().toUtc(),
  );
  // Recorded only while the entry is still interrupted. This never resolves
  // it: the state stays writeUncertain and the lock stays.
  journal.rereadableEntry(accountKey, executionId);
  await journal.recordObservation(
    executionId: executionId,
    summary: observation.encode(),
  );
  return AiRereadResult(
    observation: observation,
    requests: reads.used,
    projectPath: seen.projectPath,
  );
}

/// The GitLab page for an entry's target, built only from the verified
/// [instance] and the numeric ids and project path in the entry, or a
/// [projectPath] the caller read for the entry's numeric project id (such as
/// [AiRereadResult.projectPath]). Never from a server `web_url`.
///
/// Without a usable project path the link is the project's numeric address,
/// `/projects/<id>`, which GitLab redirects to the project. Null when the
/// entry belongs to another instance or account, or names nothing a page
/// can show: a to-do without a project, or an upload, whose file address
/// needs the secret the journal never keeps.
Uri? aiJournalTargetWebUri(
  GitLabInstance instance,
  AiJournalEntry entry, {
  String? projectPath,
}) {
  if (entry.instanceKey != instance.key ||
      _userIdOf(entry.accountKey, instance) == null) {
    return null;
  }
  AiConflictKey? key;
  for (final candidate in entry.writeKeys) {
    if (candidate.parts.length >= 2 &&
        candidate.parts.first == entry.accountKey &&
        _projectIdOf(candidate.parts[1]) != null) {
      key = candidate;
      break;
    }
  }
  if (key == null) return null;
  final project = _projectIdOf(key.parts[1])!;
  final rest = key.parts.sublist(2);
  if (rest.isNotEmpty && rest.first == 'upload') return null;
  final path =
      _projectPathOrNull(projectPath) ??
      (_releaseIsProjectPath(rest)
          ? _projectPathOrNull(entry.releaseName)
          : null);
  if (path == null) return instance.projectWeb('projects/$project');
  switch (rest) {
    case ['workItem']:
      return instance.projectWeb('$path/-/issues');
    case ['mergeRequest']:
      return instance.projectWeb('$path/-/merge_requests');
    case [final kind, final iid, ...final tail]
        when (kind == 'workItem' || kind == 'mergeRequest') &&
            _idOf(iid) != null:
      final page = kind == 'workItem' ? 'issues' : 'merge_requests';
      final uri = instance.projectWeb('$path/-/$page/${_idOf(iid)}');
      final note = switch (tail) {
        ['notes', final id, ...] => _idOf(id),
        _ => null,
      };
      return note == null ? uri : uri.replace(fragment: 'note_$note');
    case ['labels', ...]:
      return instance.projectWeb('$path/-/labels');
    case ['milestones', ...]:
      // Milestone pages are addressed by iid; the key holds the global id.
      return instance.projectWeb('$path/-/milestones');
    case ['boards', final id] when _idOf(id) != null:
      return instance.projectWeb('$path/-/boards/${_idOf(id)}');
    case ['boards', ...]:
      return instance.projectWeb('$path/-/boards');
    default:
      return instance.projectWeb(path);
  }
}

Future<_Seen> _observe(_Reads reads, AiJournalEntry entry) async {
  final parts = entry.writeKeys.first.parts;
  if (parts.length < 2 || parts.first != entry.accountKey) {
    return const _Seen.unknown(
      AiRereadSubject.project,
      AiRereadDetail.unsupported,
    );
  }
  if (parts.length == 3 && parts[1] == 'todos') {
    final todo = _idOf(parts[2]);
    if (todo == null) {
      return const _Seen.unknown(
        AiRereadSubject.todo,
        AiRereadDetail.unsupported,
      );
    }
    final scan = await _scan(
      reads,
      ['todos'],
      const {'per_page': '100'},
      match: (item) => item['id'] == todo,
      firstMatchEnough: true,
    );
    return scan.matches > 0
        ? const _Seen(
            AiRereadPresence.present,
            AiRereadSubject.todo,
            detail: AiRereadDetail.pending,
          )
        : scan.complete
        ? const _Seen(
            AiRereadPresence.absent,
            AiRereadSubject.todo,
            detail: AiRereadDetail.notPending,
          )
        : _Seen.unknown(AiRereadSubject.todo, scan.failure);
  }
  final project = _projectIdOf(parts[1]);
  if (project == null) {
    return const _Seen.unknown(
      AiRereadSubject.project,
      AiRereadDetail.unsupported,
    );
  }
  final read = await _get(reads, ['projects', '$project']);
  if (read.value case final value? when value['id'] != project) {
    return const _Seen.unknown(
      AiRereadSubject.project,
      AiRereadDetail.unavailable,
    );
  }
  if (read.value == null) return read.seen(AiRereadSubject.project);
  final path = _projectPathOrNull(read.value!['path_with_namespace']);
  final seen = await _observeInProject(reads, project, parts.sublist(2));
  return seen.withPath(path);
}

Future<_Seen> _observeInProject(
  _Reads reads,
  int project,
  List<String> rest,
) async {
  final base = ['projects', '$project'];
  switch (rest) {
    case [] || ['star', _]:
      return const _Seen(AiRereadPresence.present, AiRereadSubject.project);
    case [final kind] when kind == 'workItem' || kind == 'mergeRequest':
      final subject = kind == 'workItem'
          ? AiRereadSubject.issue
          : AiRereadSubject.mergeRequest;
      // The journal intentionally stores neither create bodies nor a server
      // timestamp that identifies the accepted request. Author plus a count
      // around the device's dispatch clock can match an unrelated create, so
      // the conservative result is unknown until either content or server-time
      // identity is available.
      return _Seen.unknown(subject, AiRereadDetail.notComparable);
    case [final kind, final rawIid, ...final tail]
        when kind == 'workItem' || kind == 'mergeRequest':
      return _observeResource(
        reads,
        project,
        kind == 'workItem' ? 'issues' : 'merge_requests',
        rawIid,
        tail,
      );
    case ['labels', final id]:
      return _direct(reads, [...base, 'labels'], id, AiRereadSubject.label);
    case ['milestones', final id]:
      return _direct(
        reads,
        [...base, 'milestones'],
        id,
        AiRereadSubject.milestone,
        detail: (value) => _stateDetail(value['state']),
      );
    case ['boards', final id]:
      return _direct(reads, [...base, 'boards'], id, AiRereadSubject.board);
    case ['labels']:
      return const _Seen.unknown(
        AiRereadSubject.label,
        AiRereadDetail.notComparable,
      );
    case ['milestones']:
      return const _Seen.unknown(
        AiRereadSubject.milestone,
        AiRereadDetail.notComparable,
      );
    case ['boards']:
      return const _Seen.unknown(
        AiRereadSubject.board,
        AiRereadDetail.notComparable,
      );
    case ['upload', _]:
      return const _Seen.unknown(
        AiRereadSubject.upload,
        AiRereadDetail.notComparable,
      );
    default:
      return const _Seen.unknown(
        AiRereadSubject.project,
        AiRereadDetail.unsupported,
      );
  }
}

Future<_Seen> _observeResource(
  _Reads reads,
  int project,
  String resource,
  String rawIid,
  List<String> tail,
) async {
  final subject = resource == 'issues'
      ? AiRereadSubject.issue
      : AiRereadSubject.mergeRequest;
  final iid = _idOf(rawIid);
  if (iid == null) {
    return _Seen.unknown(subject, AiRereadDetail.unsupported);
  }
  final owner = ['projects', '$project', resource, '$iid'];
  final read = await _get(reads, owner);
  final value = read.value;
  if (value == null) return read.seen(subject);
  if (value['iid'] != iid || value['project_id'] != project) {
    return _Seen.unknown(subject, AiRereadDetail.unavailable);
  }
  switch (tail) {
    case [] || ['todo', _]:
      return _Seen(
        AiRereadPresence.present,
        subject,
        detail: _stateDetail(value['state']),
      );
    case ['subscription', _]:
      final subscribed = value['subscribed'];
      return _Seen(
        AiRereadPresence.present,
        subject,
        detail: subscribed == true
            ? AiRereadDetail.subscribed
            : subscribed == false
            ? AiRereadDetail.notSubscribed
            : null,
      );
    case [final kind] when kind == 'notes' || kind == 'discussions':
      final created = kind == 'notes'
          ? AiRereadSubject.note
          : AiRereadSubject.discussion;
      return _Seen.unknown(created, AiRereadDetail.notComparable);
    case ['notes', final id]:
      return _direct(reads, [...owner, 'notes'], id, AiRereadSubject.note);
    case ['notes', final id, 'award', final user, final name]:
      final note = _idOf(id);
      if (note == null) {
        return const _Seen.unknown(
          AiRereadSubject.note,
          AiRereadDetail.unsupported,
        );
      }
      return _award(reads, [...owner, 'notes', '$note'], user, name);
    case ['award', final user, final name]:
      return _award(reads, owner, user, name);
    case ['discussions', final id, ...]:
      if (!RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id)) {
        return const _Seen.unknown(
          AiRereadSubject.discussion,
          AiRereadDetail.unsupported,
        );
      }
      final discussion = await _get(reads, [...owner, 'discussions', id]);
      final found = discussion.value;
      if (found == null) return discussion.seen(AiRereadSubject.discussion);
      if (found['id'] != id) {
        return const _Seen.unknown(
          AiRereadSubject.discussion,
          AiRereadDetail.unavailable,
        );
      }
      return _Seen(
        AiRereadPresence.present,
        AiRereadSubject.discussion,
        detail: _resolvedDetail(found['notes']),
      );
    case ['draftNotes']:
      return const _Seen.unknown(
        AiRereadSubject.draftNote,
        AiRereadDetail.notComparable,
      );
    case ['draftNotes', final id] when resource == 'merge_requests':
      return _direct(
        reads,
        [...owner, 'draft_notes'],
        id,
        AiRereadSubject.draftNote,
      );
    default:
      return _Seen.unknown(subject, AiRereadDetail.unsupported);
  }
}

/// A GET of one resource by numeric id, checked against that id.
Future<_Seen> _direct(
  _Reads reads,
  List<String> collection,
  String rawId,
  AiRereadSubject subject, {
  AiRereadDetail? Function(Json value)? detail,
}) async {
  final id = _idOf(rawId);
  if (id == null) return _Seen.unknown(subject, AiRereadDetail.unsupported);
  final read = await _get(reads, [...collection, '$id']);
  final value = read.value;
  if (value == null) return read.seen(subject);
  if (value['id'] != id) {
    return _Seen.unknown(subject, AiRereadDetail.unavailable);
  }
  return _Seen(AiRereadPresence.present, subject, detail: detail?.call(value));
}

Future<_Seen> _award(
  _Reads reads,
  List<String> owner,
  String rawUser,
  String name,
) async {
  final user = _idOf(rawUser);
  if (user == null) {
    return const _Seen.unknown(
      AiRereadSubject.award,
      AiRereadDetail.unsupported,
    );
  }
  final scan = await _scan(
    reads,
    [...owner, 'award_emoji'],
    const {'per_page': '100'},
    match: (item) => item['name'] == name && _userOf(item) == user,
    firstMatchEnough: true,
  );
  if (scan.matches > 0) {
    return const _Seen(AiRereadPresence.present, AiRereadSubject.award);
  }
  if (scan.complete) {
    return const _Seen(AiRereadPresence.absent, AiRereadSubject.award);
  }
  return _Seen.unknown(AiRereadSubject.award, scan.failure);
}

/// Reads pages until the list ends, [past] says the rest is older than the
/// window, a match is enough, or the request budget runs out.
Future<_Scan> _scan(
  _Reads reads,
  List<String> path,
  Map<String, String> query, {
  required bool Function(Json item) match,
  bool Function(Json item)? past,
  bool firstMatchEnough = false,
}) async {
  var matches = 0;
  Uri? next;
  while (true) {
    final ApiPage<Json> page;
    try {
      page = await reads.page(path, query, next);
    } on _Exhausted {
      return _Scan(matches, AiRereadDetail.budgetExhausted);
    } on ApiFailure catch (failure) {
      return _Scan(matches, _detailFor(failure));
    } on Object {
      return _Scan(matches, AiRereadDetail.unavailable);
    }
    for (final item in page.items) {
      if (past?.call(item) ?? false) return _Scan(matches, null);
      if (match(item)) matches++;
    }
    if (page.next == null) return _Scan(matches, null);
    if (firstMatchEnough && matches > 0) return _Scan(matches, null);
    next = page.next;
  }
}

final class _Scan {
  const _Scan(this.matches, this.failure);
  final int matches;

  /// Null when the scan saw everything it needed.
  final AiRereadDetail? failure;
  bool get complete => failure == null;
}

final class _Got {
  const _Got.value(Json this.value) : absent = false, failure = null;
  const _Got.absent() : value = null, absent = true, failure = null;
  const _Got.failed(AiRereadDetail this.failure) : value = null, absent = false;
  final Json? value;
  final bool absent;
  final AiRereadDetail? failure;

  _Seen seen(AiRereadSubject subject) => absent
      ? _Seen(AiRereadPresence.absent, subject)
      : _Seen.unknown(subject, failure);
}

Future<_Got> _get(_Reads reads, List<String> path) async {
  try {
    return _Got.value(await reads.record(path));
  } on _Exhausted {
    return const _Got.failed(AiRereadDetail.budgetExhausted);
  } on ApiFailure catch (failure) {
    // 404 is ambiguous: not found, or not visible to this account.
    return failure.kind == FailureKind.invisible
        ? const _Got.absent()
        : _Got.failed(_detailFor(failure));
  } on Object {
    return const _Got.failed(AiRereadDetail.unavailable);
  }
}

final class _Seen {
  const _Seen(
    this.presence,
    this.subject, {
    this.detail,
    this.matches,
    this.projectPath,
  });
  const _Seen.unknown(this.subject, this.detail)
    : presence = AiRereadPresence.unknown,
      matches = null,
      projectPath = null;
  final AiRereadPresence presence;
  final AiRereadSubject subject;
  final AiRereadDetail? detail;
  final int? matches;
  final String? projectPath;

  _Seen withPath(String? path) => _Seen(
    presence,
    subject,
    detail: detail,
    matches: matches,
    projectPath: path,
  );
}

/// Counts every GitLab request and refuses the one past the limit.
final class _Reads {
  _Reads(this._api);
  final GitLabApi _api;
  final RequestMeter _meter = RequestMeter();
  int get used => _meter.count;

  void _take() {
    // A GET may be replayed once after an OAuth 401. Reserve room for that
    // physical replay before dispatch; the meter then reports actual sends.
    final maximum = _api.credential is OAuthCredential ? 2 : 1;
    if (used + maximum > AiWriteLimits.rereadHttp) throw const _Exhausted();
  }

  Future<GitLabUser> user() async {
    _take();
    return _meter.runAsync(_api.currentUser);
  }

  Future<Json> record(List<String> path) async {
    _take();
    return _meter.runAsync(() => _api.record(path));
  }

  Future<ApiPage<Json>> page(
    List<String> path,
    Map<String, String> query,
    Uri? next,
  ) async {
    _take();
    return _meter.runAsync(() => _api.records(path, query: query, next: next));
  }
}

final class _Exhausted implements Exception {
  const _Exhausted();
}

AiRereadDetail _detailFor(ApiFailure failure) => switch (failure.kind) {
  FailureKind.forbidden => AiRereadDetail.forbidden,
  FailureKind.rateLimited => AiRereadDetail.rateLimited,
  _ => AiRereadDetail.unavailable,
};

AiRereadDetail? _stateDetail(Object? state) => switch (state) {
  'opened' => AiRereadDetail.opened,
  'closed' => AiRereadDetail.closed,
  'merged' => AiRereadDetail.merged,
  'locked' => AiRereadDetail.locked,
  'active' => AiRereadDetail.active,
  _ => null,
};

AiRereadDetail? _resolvedDetail(Object? notes) {
  if (notes is! List) return null;
  final resolvable = [
    for (final note in notes)
      if (note is Map && note['resolvable'] == true) note,
  ];
  if (resolvable.isEmpty) return null;
  return resolvable.every((note) => note['resolved'] == true)
      ? AiRereadDetail.resolved
      : AiRereadDetail.unresolved;
}

int? _userOf(Json item) {
  final user = item['user'];
  return user is Map && user['id'] is int ? user['id'] as int : null;
}

/// The user id of `instance.key#id` when the key belongs to [instance].
int? _userIdOf(String accountKey, GitLabInstance instance) {
  final prefix = '${instance.key}#';
  if (!accountKey.startsWith(prefix)) return null;
  return _idOf(accountKey.substring(prefix.length));
}

int? _projectIdOf(String part) =>
    part.startsWith('project:') ? _idOf(part.substring(8)) : null;

int? _idOf(String value) {
  if (!RegExp(r'^[1-9][0-9]{0,17}$').hasMatch(value)) return null;
  return int.parse(value);
}

/// Operations whose release name is the project's `path_with_namespace`.
bool _releaseIsProjectPath(List<String> rest) => switch (rest) {
  [] || ['star', _] || ['workItem'] || ['mergeRequest'] => true,
  ['labels' || 'milestones' || 'boards', ...] => true,
  _ => false,
};

/// A GitLab namespace path: two or more segments of letters, digits, `_`,
/// `-` and `.`, with no `.` or `..` segment that could leave the instance's
/// installation path.
String? _projectPathOrNull(Object? value) {
  if (value is! String) return null;
  final segments = value.split('/');
  if (segments.length < 2) return null;
  for (final segment in segments) {
    if (segment == '.' ||
        segment == '..' ||
        !RegExp(r'^[A-Za-z0-9_.][A-Za-z0-9_.-]*$').hasMatch(segment)) {
      return null;
    }
  }
  return value;
}

T? _byName<T extends Enum>(List<T> values, String name) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}
