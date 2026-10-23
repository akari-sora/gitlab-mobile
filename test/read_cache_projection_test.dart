import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/read_cache_projection.dart';

final _instance = GitLabInstance.parse('https://gitlab.example/root');
final _now = DateTime.utc(2026, 10, 23, 12);
const _sha = '0123456789abcdef0123456789abcdef01234567';
final _binding = DiskBinding(accountKey: '${_instance.key}#7', generation: 4);

final class _Lease implements DiskCommitLease {
  @override
  bool isCurrent = true;
  @override
  void revoke() => isCurrent = false;
}

final class _Input {
  const _Input(this.candidate, this.value);
  final DiskWriteCandidate candidate;
  final Object value;
  Uri get uri => candidate.uri;
  ReadCacheBodyKind get bodyKind => candidate.bodyKind;
}

Map<String, Object?> _actor([int id = 1]) => {
  'id': id,
  'username': 'user$id',
  'name': 'User $id',
  'avatar_url': 'https://gitlab.example/root/uploads/$id.png',
  'web_url': 'https://gitlab.example/root/user$id',
  'email': 'must-strip@example.invalid',
};

Map<String, Object?> _project([int id = 1]) => {
  'id': id,
  'name': 'Project $id',
  'path_with_namespace': 'group/project$id',
  'description': null,
  'visibility': 'private',
  'default_branch': null,
  'star_count': 2,
  'forks_count': 3,
  'open_issues_count': 4,
  'last_activity_at': null,
  'license': null,
  'web_url': 'https://gitlab.example/root/group/project$id',
  'avatar_url': null,
  'archived': false,
  'namespace': {
    'id': 9,
    'name': 'group',
    'full_path': 'group',
    'kind': 'group',
    'extra': 1,
  },
  'import_url': 'https://secret.invalid/repo',
  'runners_token': 'secret',
  'requestOptions': {'private_token': 'secret'},
};

Map<String, Object?> _issue({int project = 1, int iid = 2}) => {
  'id': 100 + iid,
  'iid': iid,
  'project_id': project,
  'title': 'Issue $iid',
  'description': null,
  'references': {
    'short': '#$iid',
    'relative': '#$iid',
    'full': 'group/project#$iid',
    'url': 'strip',
  },
  'state': 'opened',
  'confidential': false,
  'created_at': '2026-10-22T10:00:00Z',
  'updated_at': '2026-10-22T11:00:00Z',
  'closed_at': null,
  'due_date': null,
  'web_url': 'https://gitlab.example/root/group/project/-/issues/$iid',
  'author': _actor(),
  'assignee': null,
  'assignees': <Object?>[],
  'labels': [
    {
      'id': 5,
      'name': 'bug',
      'color': '#f00',
      'text_color': '#FFFFFF',
      'description': 'strip',
      'extra': true,
    },
  ],
  'milestone': null,
  'user_notes_count': 0,
  'upvotes': 0,
  'downvotes': 0,
  'task_completion_status': {'count': 2, 'completed_count': 1, 'extra': true},
  'time_stats': {
    'time_estimate': 0,
    'total_time_spent': 0,
    'human_time_estimate': null,
    'human_total_time_spent': null,
  },
  'token': 'strip',
  'downloadURL': 'https://evil.invalid/signed?token=x',
};

Map<String, Object?> _mr({int project = 1, int iid = 3}) => {
  'id': 200 + iid,
  'iid': iid,
  'project_id': project,
  'title': 'MR $iid',
  'description': null,
  'references': {
    'short': '!$iid',
    'relative': '!$iid',
    'full': 'group/project!$iid',
  },
  'merge_user': null,
  'merge_when_pipeline_succeeds': true,
  'auto_merge_enabled': false,
  'state': 'opened',
  'created_at': '2026-10-22T10:00:00Z',
  'updated_at': '2026-10-22T11:00:00Z',
  'merged_at': null,
  'closed_at': null,
  'web_url': 'https://gitlab.example/root/group/project/-/merge_requests/$iid',
  'source_branch': 'feature',
  'target_branch': 'main',
  'source_project_id': project,
  'target_project_id': project,
  'sha': _sha,
  'diff_refs': null,
  'draft': false,
  'work_in_progress': false,
  'merge_status': 'can_be_merged',
  'detailed_merge_status': 'mergeable',
  'changes_count': '1',
  'diverged_commits_count': 0,
  'rebase_in_progress': false,
  'has_conflicts': false,
  'author': _actor(),
  'assignee': null,
  'assignees': <Object?>[],
  'reviewers': <Object?>[],
  'labels': [
    {
      'id': 5,
      'name': 'bug',
      'color': '#f00',
      'text_color': '#FFFFFF',
      'description': 'strip',
      'extra': true,
    },
  ],
  'milestone': null,
  'user_notes_count': 0,
  'upvotes': 0,
  'downvotes': 0,
  'head_pipeline': null,
  'time_stats': {
    'time_estimate': 0,
    'total_time_spent': 0,
    'human_time_estimate': null,
    'human_total_time_spent': null,
  },
};

Map<String, Object?> _note([int id = 5]) => {
  'id': id,
  'body': 'public note',
  'created_at': '2026-10-22T10:00:00Z',
  'updated_at': '2026-10-22T11:00:00Z',
  'system': false,
  'internal': false,
  'confidential': false,
  'noteable_id': 102,
  'noteable_iid': 2,
  'noteable_type': 'Issue',
  'author': _actor(),
  'resolvable': false,
  'resolved': false,
  'resolved_by': null,
  'position': null,
  'private_token': 'strip',
};

ReadCachePublicIssueProof _proof({
  DiskBinding? binding,
  ReadCacheProofLineage lineage = ReadCacheProofLineage.network,
  bool single = true,
  bool? confidential = false,
  int privacyEpoch = 3,
  DateTime? fetchedAt,
  Map<String, int> scopes = const {'global': 0, 'project:1': 8},
}) => ReadCachePublicIssueProof(
  binding: binding ?? _binding,
  identity: const ReadCacheIssueIdentity(1, 2),
  fetchedAt: fetchedAt ?? _now.subtract(const Duration(seconds: 29)),
  lineage: lineage,
  singleIssue: single,
  confidential: confidential,
  privacyEpoch: privacyEpoch,
  scopeVersions: scopes,
);

ReadCacheProjectionContext _context({
  DiskBinding? binding,
  Iterable<ReadCachePublicIssueProof>? proofs,
  Set<ReadCacheIssueIdentity> confidential = const {},
  Set<String> shas = const {_sha},
  int privacyEpoch = 3,
  Map<String, int> scopes = const {
    'global': 0,
    'project:1': 8,
    'userLists': 8,
    'groupWorkItems': 8,
    'projectLists': 8,
  },
  Map<String, int> aliases = const {'group/project1': 1},
  Map<(int, int), int> verifiedMrs = const {(1, 3): 203},
  ReadCacheTerminalJobProof? terminal,
}) => ReadCacheProjectionContext(
  instance: _instance,
  binding: binding ?? _binding,
  now: _now,
  privacyEpoch: privacyEpoch,
  scopeVersions: scopes,
  publicIssues: proofs ?? [_proof()],
  confidentialIssues: confidential,
  confirmedShas: shas,
  verifiedProjectAliases: aliases,
  verifiedMergeRequestIds: verifiedMrs,
  terminalJob: terminal,
);

_Input _candidate(
  List<String> path,
  Object value, {
  ReadCacheBodyKind kind = ReadCacheBodyKind.json,
  Map<String, String>? query,
  String? accept,
  DiskBinding? binding,
  DateTime? fetchedAt,
  int responseBytes = 128,
  bool typedPinned = false,
  bool cacheable = true,
  bool noStore = false,
  bool firstPage = true,
  bool projectLicense = true,
  String method = 'GET',
  Uri? next,
  int privacyEpoch = 3,
  Map<String, int>? scopes,
  Set<String> tags = const {},
  _Lease? lease,
}) {
  final effectiveQuery =
      query ??
      (projectLicense && path.length == 2 && path.first == 'projects'
          ? const {'license': 'true'}
          : null);
  final effectiveScopes =
      scopes ??
      {
        'global': 0,
        if (path.length == 1 && path.single == 'projects')
          'projectLists': 8
        else if (path.first == 'groups' &&
            path.length == 3 &&
            const {'issues', 'merge_requests'}.contains(path.last))
          'groupWorkItems': 8
        else if (path.length == 1 &&
            const {'issues', 'merge_requests'}.contains(path.single))
          'userLists': 8
        else
          'project:1': 8,
      };
  return _Input(
    DiskWriteCandidate(
      binding: binding ?? _binding,
      uri: _instance.api(path, effectiveQuery),
      logicalAccept:
          accept ??
          (kind == ReadCacheBodyKind.text ||
                  kind == ReadCacheBodyKind.terminalLog
              ? 'text/plain'
              : 'application/json'),
      bodyKind: kind,
      fetchedAt: fetchedAt ?? _now,
      responseBytes: responseBytes,
      lease: lease ?? _Lease(),
      typedPinned: typedPinned,
      cacheable: cacheable,
      noStore: noStore,
      firstPage: firstPage,
      method: method,
      next: next,
      privacyEpoch: privacyEpoch,
      scopeVersions: effectiveScopes,
      scopeTags: tags,
    ),
    value,
  );
}

ProjectedDiskEntry? _projected(
  _Input input, {
  ReadCacheProjectionContext? context,
}) => projectReadCacheResponse(
  input.candidate,
  input.value,
  context ?? _context(),
);

Set<String> _keys(Object? value) =>
    (value! as Map<String, Object?>).keys.toSet();

void main() {
  group('E01-E19 closed endpoint table', () {
    final terminalProof = ReadCacheTerminalJobProof(
      binding: _binding,
      projectId: 1,
      jobId: 9,
      status: 'success',
      finishedAt: _now.subtract(const Duration(minutes: 1)),
      fetchedAt: _now.subtract(const Duration(seconds: 1)),
      lineage: ReadCacheProofLineage.network,
      erased: false,
    );
    final log = ReadCacheTerminalLog(
      projectId: 1,
      jobId: 9,
      finishedAt: terminalProof.finishedAt,
      startOffset: 0,
      nextOffset: 3,
      totalBytes: 3,
      isEof: true,
      truncated: false,
      bytes: utf8.encode('log'),
    );
    final cases =
        <
          ({
            String id,
            _Input candidate,
            Set<String> keys,
            ReadCacheProjectionContext? context,
          })
        >[
          (
            id: 'E01 project',
            candidate: _candidate(['projects', '1'], _project()),
            keys: {
              'id',
              'name',
              'path_with_namespace',
              'description',
              'visibility',
              'default_branch',
              'star_count',
              'forks_count',
              'open_issues_count',
              'last_activity_at',
              'license',
              'web_url',
              'avatar_url',
              'archived',
              'namespace',
            },
            context: null,
          ),
          (
            id: 'E02 issue page',
            candidate: _candidate(
              ['issues'],
              [_issue()],
              kind: ReadCacheBodyKind.page,
              query: {'with_labels_details': 'true'},
            ),
            keys: {
              'id',
              'iid',
              'project_id',
              'title',
              'description',
              'references',
              'state',
              'confidential',
              'created_at',
              'updated_at',
              'closed_at',
              'due_date',
              'web_url',
              'author',
              'assignee',
              'assignees',
              'labels',
              'milestone',
              'user_notes_count',
              'upvotes',
              'downvotes',
              'task_completion_status',
              'time_stats',
            },
            context: null,
          ),
          (
            id: 'E03 issue',
            candidate: _candidate(['projects', '1', 'issues', '2'], _issue()),
            keys: {
              'id',
              'iid',
              'project_id',
              'title',
              'description',
              'references',
              'state',
              'confidential',
              'created_at',
              'updated_at',
              'closed_at',
              'due_date',
              'web_url',
              'author',
              'assignee',
              'assignees',
              'labels',
              'milestone',
              'user_notes_count',
              'upvotes',
              'downvotes',
              'task_completion_status',
              'time_stats',
            },
            context: null,
          ),
          (
            id: 'E04 issue note',
            candidate: _candidate([
              'projects',
              '1',
              'issues',
              '2',
              'notes',
              '5',
            ], _note()),
            keys: {
              'id',
              'body',
              'created_at',
              'updated_at',
              'system',
              'internal',
              'confidential',
              'noteable_id',
              'noteable_iid',
              'noteable_type',
              'author',
              'resolvable',
              'resolved',
              'resolved_by',
              'position',
            },
            context: null,
          ),
          (
            id: 'E05 issue discussion',
            candidate: _candidate(
              ['projects', '1', 'issues', '2', 'discussions', 'thread'],
              {
                'id': 'thread',
                'individual_note': false,
                'notes': [_note()],
              },
            ),
            keys: {'id', 'individual_note', 'notes'},
            context: null,
          ),
          (
            id: 'E06 emoji',
            candidate: _candidate(
              ['projects', '1', 'issues', '2', 'award_emoji'],
              [
                {
                  'id': 1,
                  'name': 'thumbsup',
                  'user': _actor(),
                  'created_at': '2026-10-22T10:00:00Z',
                  'updated_at': '2026-10-22T11:00:00Z',
                },
              ],
              kind: ReadCacheBodyKind.page,
            ),
            keys: {'id', 'name', 'user', 'created_at', 'updated_at'},
            context: null,
          ),
          (
            id: 'E07 related MR',
            candidate: _candidate(
              ['projects', '1', 'issues', '2', 'related_merge_requests'],
              [
                {
                  ..._mr(),
                  'issues': [_issue(project: 2, iid: 7)],
                },
              ],
              kind: ReadCacheBodyKind.page,
            ),
            keys: {
              ..._mr().keys.where((k) => !{'token', 'downloadURL'}.contains(k)),
              'issues',
            },
            context: null,
          ),
          (
            id: 'E08 linked issue',
            candidate: _candidate(
              ['projects', '1', 'issues', '2', 'links'],
              [
                {
                  ..._issue(project: 2, iid: 8),
                  'issue_link_id': 4,
                  'link_type': 'relates_to',
                },
              ],
              kind: ReadCacheBodyKind.page,
            ),
            keys: {
              ..._issue().keys.where(
                (k) => !{'token', 'downloadURL'}.contains(k),
              ),
              'issue_link_id',
              'link_type',
            },
            context: null,
          ),
          (
            id: 'E09 MR page',
            candidate: _candidate(
              ['merge_requests'],
              [_mr()],
              kind: ReadCacheBodyKind.page,
              query: {'with_labels_details': 'true'},
            ),
            keys: _mr().keys
                .where((k) => !{'token', 'downloadURL'}.contains(k))
                .toSet(),
            context: null,
          ),
          (
            id: 'E10 MR',
            candidate: _candidate([
              'projects',
              '1',
              'merge_requests',
              '3',
            ], _mr()),
            keys: _mr().keys
                .where((k) => !{'token', 'downloadURL'}.contains(k))
                .toSet(),
            context: null,
          ),
          (
            id: 'E11 approvals',
            candidate: _candidate(
              ['projects', '1', 'merge_requests', '3', 'approvals'],
              {
                'id': 203,
                'iid': 3,
                'project_id': 1,
                'approvals_required': 2,
                'approvals_left': 1,
                'approved_by': [
                  {'user': _actor()},
                ],
                'rules': ['strip'],
              },
            ),
            keys: {
              'id',
              'iid',
              'project_id',
              'approvals_required',
              'approvals_left',
              'approved_by',
            },
            context: null,
          ),
          (
            id: 'E12 MR note',
            candidate: _candidate([
              'projects',
              '1',
              'merge_requests',
              '3',
              'notes',
              '5',
            ], _note()),
            keys: {
              'id',
              'body',
              'created_at',
              'updated_at',
              'system',
              'internal',
              'confidential',
              'noteable_id',
              'noteable_iid',
              'noteable_type',
              'author',
              'resolvable',
              'resolved',
              'resolved_by',
              'position',
            },
            context: null,
          ),
          (
            id: 'E13 MR discussion',
            candidate: _candidate(
              ['projects', '1', 'merge_requests', '3', 'discussions', 'thread'],
              {
                'id': 'thread',
                'individual_note': false,
                'notes': [_note()],
              },
            ),
            keys: {'id', 'individual_note', 'notes'},
            context: null,
          ),
          (
            id: 'E14 pipeline',
            candidate: _candidate(
              ['projects', '1', 'pipelines', '6'],
              {
                'id': 6,
                'iid': 1,
                'project_id': 1,
                'name': 'pipe',
                'status': 'success',
                'source': 'push',
                'ref': 'main',
                'sha': _sha,
                'web_url':
                    'https://gitlab.example/root/group/project/-/pipelines/6',
                'created_at': '2026-10-22T10:00:00Z',
                'updated_at': '2026-10-22T11:00:00Z',
                'started_at': null,
                'finished_at': null,
                'duration': null,
                'queued_duration': null,
                'user': _actor(),
                'variables': ['strip'],
              },
            ),
            keys: {
              'id',
              'iid',
              'project_id',
              'name',
              'status',
              'source',
              'ref',
              'sha',
              'web_url',
              'created_at',
              'updated_at',
              'started_at',
              'finished_at',
              'duration',
              'queued_duration',
              'user',
            },
            context: null,
          ),
          (
            id: 'E15 job',
            candidate: _candidate(
              ['projects', '1', 'jobs', '9'],
              {
                'id': 9,
                'name': 'test',
                'status': 'success',
                'stage': 'test',
                'ref': 'main',
                'created_at': '2026-10-22T10:00:00Z',
                'started_at': null,
                'finished_at': null,
                'erased_at': null,
                'duration': null,
                'queued_duration': null,
                'failure_reason': null,
                'web_url': 'https://gitlab.example/root/group/project/-/jobs/9',
                'user': _actor(),
                'pipeline': {
                  'id': 6,
                  'iid': 1,
                  'project_id': 1,
                  'status': 'success',
                  'ref': 'main',
                  'sha': _sha,
                },
                'artifacts_file': {'filename': 'a.zip', 'size': 4},
                'artifacts': [
                  {'download_url': 'strip'},
                ],
                'runner': {'token': 'strip'},
              },
            ),
            keys: {
              'id',
              'name',
              'status',
              'stage',
              'ref',
              'created_at',
              'started_at',
              'finished_at',
              'erased_at',
              'duration',
              'queued_duration',
              'failure_reason',
              'web_url',
              'user',
              'pipeline',
              'artifacts_file',
            },
            context: null,
          ),
          (
            id: 'E16 tree',
            candidate: _candidate(
              ['projects', '1', 'repository', 'tree'],
              [
                {
                  'id': _sha,
                  'name': 'README.md',
                  'type': 'blob',
                  'path': 'README.md',
                  'mode': '100644',
                  'extra': 'strip',
                },
              ],
              kind: ReadCacheBodyKind.page,
              query: {'ref': _sha},
            ),
            keys: {'id', 'name', 'type', 'path', 'mode'},
            context: null,
          ),
          (
            id: 'E17 file',
            candidate: _candidate(
              ['projects', '1', 'repository', 'files', 'README.md'],
              {
                'file_name': 'README.md',
                'file_path': 'README.md',
                'size': 2,
                'encoding': 'base64',
                'content': base64.encode(utf8.encode('ok')),
                'content_sha256': _sha,
                'ref': _sha,
                'blob_id': _sha,
                'commit_id': _sha,
                'last_commit_id': _sha,
                'execute_filemode': false,
                'download_url': 'strip',
              },
              query: {'ref': _sha},
            ),
            keys: {
              'file_name',
              'file_path',
              'size',
              'encoding',
              'content',
              'content_sha256',
              'ref',
              'blob_id',
              'commit_id',
              'last_commit_id',
              'execute_filemode',
            },
            context: null,
          ),
          (
            id: 'E18 MR version',
            candidate: _candidate(
              ['projects', '1', 'merge_requests', '3', 'versions', '4'],
              {
                'id': 4,
                'created_at': '2026-10-22T10:00:00Z',
                'base_commit_sha': _sha,
                'start_commit_sha': _sha,
                'head_commit_sha': _sha,
                'state': 'collected',
                'real_size': '1',
                'diffs': [
                  {
                    'old_path': 'a',
                    'new_path': 'b',
                    'a_mode': '100644',
                    'b_mode': '100644',
                    'new_file': false,
                    'renamed_file': false,
                    'deleted_file': false,
                    'generated_file': false,
                    'collapsed': false,
                    'too_large': false,
                    'diff': 'x',
                    'extra': 'strip',
                  },
                ],
              },
              typedPinned: true,
            ),
            keys: {
              'id',
              'created_at',
              'base_commit_sha',
              'start_commit_sha',
              'head_commit_sha',
              'state',
              'real_size',
              'diffs',
            },
            context: null,
          ),
          (
            id: 'E19 terminal log',
            candidate: _candidate(
              ['projects', '1', 'jobs', '9', 'trace'],
              log,
              kind: ReadCacheBodyKind.terminalLog,
              typedPinned: true,
            ),
            keys: const {},
            context: _context(terminal: terminalProof),
          ),
        ];

    for (final c in cases) {
      test('${c.id} accepts and emits its exact schema', () {
        final entry = _projected(c.candidate, context: c.context);
        expect(entry, isNotNull, reason: c.id);
        if (c.id == 'E19 terminal log') {
          expect(entry!.body, isA<ReadCacheTerminalLog>());
        } else {
          final body = entry!.body;
          final item = c.candidate.bodyKind == ReadCacheBodyKind.page
              ? (body as Map<String, Object?>)['items']! as List<Object?>
              : null;
          expect(
            _keys(item == null ? body : item.single),
            c.keys,
            reason: c.id,
          );
        }
      });
    }

    test(
      'all wider classify families and untyped pinned paths are rejected',
      () {
        final rejects = [
          _candidate(['groups'], <Object?>[], kind: ReadCacheBodyKind.page),
          _candidate(['groups', '1'], {'id': 1}),
          _candidate(
            ['groups', '1', 'subgroups'],
            <Object?>[],
            kind: ReadCacheBodyKind.page,
          ),
          _candidate(
            ['groups', '1', 'descendant_groups'],
            <Object?>[],
            kind: ReadCacheBodyKind.page,
          ),
          _candidate(
            ['groups', '1', 'projects'],
            [_project()],
            kind: ReadCacheBodyKind.page,
          ),
          _candidate(
            ['users', '1', 'starred_projects'],
            [_project()],
            kind: ReadCacheBodyKind.page,
          ),
          for (final resource in ['branches', 'tags', 'commits'])
            _candidate(
              ['projects', '1', 'repository', resource],
              <Object?>[],
              kind: ReadCacheBodyKind.page,
            ),
          _candidate(
            ['projects', '1', 'pipelines'],
            <Object?>[],
            kind: ReadCacheBodyKind.page,
          ),
          _candidate(
            ['projects', '1', 'jobs'],
            <Object?>[],
            kind: ReadCacheBodyKind.page,
          ),
          _candidate(
            ['projects', '1', 'pipelines', '6', 'jobs'],
            <Object?>[],
            kind: ReadCacheBodyKind.page,
          ),
          for (final resource in [
            'members',
            'starrers',
            'forks',
            'labels',
            'milestones',
            'releases',
          ])
            _candidate(
              ['projects', '1', resource],
              <Object?>[],
              kind: ReadCacheBodyKind.page,
            ),
          _candidate(
            ['projects', '1', 'merge_requests', '3', 'award_emoji'],
            <Object?>[],
            kind: ReadCacheBodyKind.page,
          ),
          _candidate(
            ['projects', 'group/project1', 'issues'],
            <Object?>[],
            kind: ReadCacheBodyKind.page,
          ),
          _candidate(
            ['projects', '1', 'merge_requests', '3', 'versions'],
            <Object?>[],
            kind: ReadCacheBodyKind.page,
          ),
          _candidate(['todos'], <Object?>[], kind: ReadCacheBodyKind.page),
          _candidate(['events'], <Object?>[], kind: ReadCacheBodyKind.page),
          _candidate(
            ['users', '1', 'events'],
            <Object?>[],
            kind: ReadCacheBodyKind.page,
          ),
          _candidate(['search'], <Object?>[], kind: ReadCacheBodyKind.page),
          _candidate(
            ['projects', '1', 'merge_requests', '3', 'versions', '4'],
            {'id': 4},
            typedPinned: false,
          ),
          _candidate(
            ['projects', '1', 'jobs', '9', 'trace'],
            log,
            kind: ReadCacheBodyKind.terminalLog,
            typedPinned: false,
          ),
        ];
        for (final candidate in rejects) {
          expect(
            _projected(candidate),
            isNull,
            reason: candidate.uri.toString(),
          );
        }
      },
    );

    test(
      'list and detail variants use the same independently fixed schemas',
      () {
        final projectPage = _projected(
          _candidate(['projects'], [_project()], kind: ReadCacheBodyKind.page),
        )!;
        expect(_keys(((projectPage.body as Map)['items'] as List).single), {
          'id',
          'name',
          'path_with_namespace',
          'description',
          'visibility',
          'default_branch',
          'star_count',
          'forks_count',
          'open_issues_count',
          'last_activity_at',
          'license',
          'web_url',
          'avatar_url',
          'archived',
          'namespace',
        });
        for (final candidate in [
          _candidate(
            ['projects', '1', 'issues', '2', 'notes'],
            [_note()],
            kind: ReadCacheBodyKind.page,
          ),
          _candidate(
            ['projects', '1', 'issues', '2', 'discussions'],
            [
              {
                'id': 'thread',
                'individual_note': false,
                'notes': [_note()],
              },
            ],
            kind: ReadCacheBodyKind.page,
          ),
          _candidate(
            ['projects', '1', 'merge_requests', '3', 'notes'],
            [_note()],
            kind: ReadCacheBodyKind.page,
          ),
          _candidate(
            ['projects', '1', 'merge_requests', '3', 'discussions'],
            [
              {
                'id': 'thread',
                'individual_note': false,
                'notes': [_note()],
              },
            ],
            kind: ReadCacheBodyKind.page,
          ),
        ]) {
          expect(
            _projected(candidate),
            isNotNull,
            reason: candidate.uri.toString(),
          );
        }
      },
    );
  });

  test(
    'My Work, Inbox, group and project issue/MR query shapes remain eligible',
    () {
      final fixtures = [
        _candidate(
          ['issues'],
          [_issue()],
          kind: ReadCacheBodyKind.page,
          query: {
            'scope': 'assigned_to_me',
            'state': 'opened',
            'with_labels_details': 'true',
          },
        ),
        _candidate(
          ['issues'],
          [_issue()],
          kind: ReadCacheBodyKind.page,
          query: {
            'scope': 'created_by_me',
            'state': 'opened',
            'with_labels_details': 'true',
          },
        ),
        _candidate(
          ['groups', '4', 'issues'],
          [_issue()],
          kind: ReadCacheBodyKind.page,
          query: {
            'state': 'opened',
            'order_by': 'updated_at',
            'sort': 'desc',
            'with_labels_details': 'true',
          },
        ),
        _candidate(
          ['projects', '1', 'issues'],
          [_issue()],
          kind: ReadCacheBodyKind.page,
          query: {
            'scope': 'all',
            'state': 'opened',
            'order_by': 'relative_position',
            'sort': 'asc',
            'with_labels_details': 'true',
            'labels': 'bug,urgent',
            'assignee_id': '7',
            'milestone': 'M1',
            'weight': '3',
          },
        ),
        _candidate(
          ['merge_requests'],
          [_mr()],
          kind: ReadCacheBodyKind.page,
          query: {
            'scope': 'all',
            'reviewer_id': '7',
            'state': 'opened',
            'with_labels_details': 'true',
          },
        ),
        _candidate(
          ['groups', '4', 'merge_requests'],
          [_mr()],
          kind: ReadCacheBodyKind.page,
          query: {
            'state': 'opened',
            'order_by': 'updated_at',
            'sort': 'desc',
            'with_labels_details': 'true',
          },
        ),
        _candidate(
          ['merge_requests'],
          [_mr()],
          kind: ReadCacheBodyKind.page,
          query: {
            'scope': 'created_by_me',
            'state': 'opened',
            'with_labels_details': 'true',
          },
        ),
      ];
      for (final fixture in fixtures) {
        final entry = _projected(fixture);
        expect(entry, isNotNull, reason: fixture.uri.toString());
        final item = ((entry!.body as Map)['items'] as List).single as Map;
        expect(item['labels'], [
          {'id': 5, 'name': 'bug', 'color': '#f00', 'text_color': '#FFFFFF'},
        ]);
        expect(_keys(item['references']), {'short', 'relative', 'full'});
        expect((item['references'] as Map).values, everyElement(isA<String>()));
        if (item.containsKey('merge_user')) {
          for (final name in [
            'merge_user',
            'assignee',
            'milestone',
            'merged_at',
            'closed_at',
          ]) {
            expect(item.containsKey(name), isTrue, reason: name);
            expect(item[name], isNull, reason: name);
          }
          expect(item['merge_when_pipeline_succeeds'], true);
          expect(item['auto_merge_enabled'], false);
        } else {
          for (final name in [
            'assignee',
            'milestone',
            'closed_at',
            'due_date',
          ]) {
            expect(item.containsKey(name), isTrue, reason: name);
            expect(item[name], isNull, reason: name);
          }
        }
      }
    },
  );

  group('closed nested schemas', () {
    test(
      'nested actor, namespace, references, label and time-stat keys are exact',
      () {
        final issue =
            ((_projected(
                              _candidate(
                                ['issues'],
                                [_issue()],
                                kind: ReadCacheBodyKind.page,
                              ),
                            )!.body
                            as Map)['items']
                        as List)
                    .single
                as Map;
        expect(_keys(issue['author']), {
          'id',
          'username',
          'name',
          'avatar_url',
          'web_url',
        });
        expect(_keys(issue['references']), {'short', 'relative', 'full'});
        expect(_keys((issue['labels'] as List).single), {
          'id',
          'name',
          'color',
          'text_color',
        });
        expect(_keys(issue['task_completion_status']), {
          'count',
          'completed_count',
        });
        expect(_keys(issue['time_stats']), {
          'time_estimate',
          'total_time_spent',
          'human_time_estimate',
          'human_total_time_spent',
        });
        final project =
            _projected(_candidate(['projects', '1'], _project()))!.body as Map;
        expect(_keys(project['namespace']), {
          'id',
          'name',
          'full_path',
          'kind',
        });
      },
    );

    test(
      'labels accept strings, empty, and detailed four-field objects; strip extras',
      () {
        for (final labels in <List<Object?>>[
          <Object?>[],
          ['bug', 'urgent'],
          [
            {
              'id': 1,
              'name': 'bug',
              'color': '#f00',
              'text_color': '#A1b2C3',
              'description': 'strip',
              'extra': 1,
            },
          ],
        ]) {
          final issue = _issue()..['labels'] = labels;
          final entry = _projected(
            _candidate(['issues'], [issue], kind: ReadCacheBodyKind.page),
          )!;
          final projected =
              ((entry.body as Map)['items'] as List).single as Map;
          expect(
            projected['labels'],
            labels.isEmpty || labels.first is String
                ? labels
                : [
                    {
                      'id': 1,
                      'name': 'bug',
                      'color': '#f00',
                      'text_color': '#A1b2C3',
                    },
                  ],
          );
        }
      },
    );

    test(
      'invalid colour omits only that field; wrong types/null/mixed labels reject page',
      () {
        final badColour = _issue()
          ..['labels'] = [
            {'id': 1, 'name': 'bug', 'color': 'red', 'text_color': '#xyz'},
          ];
        final entry = _projected(
          _candidate(['issues'], [badColour], kind: ReadCacheBodyKind.page),
        )!;
        expect(
          (((entry.body as Map)['items'] as List).single as Map)['labels'],
          [
            {'id': 1, 'name': 'bug'},
          ],
        );
        for (final labels in <Object?>[
          null,
          [
            'ok',
            {'name': 'x', 'color': '#fff'},
          ],
          [null],
          [
            {'name': 'x', 'color': 7},
          ],
          [
            {'name': 'x', 'color': null},
          ],
          [
            {'name': 7, 'color': '#fff'},
          ],
        ]) {
          final issue = _issue()..['labels'] = labels;
          expect(
            _projected(
              _candidate(['issues'], [issue], kind: ReadCacheBodyKind.page),
            ),
            isNull,
            reason: '$labels',
          );
        }
      },
    );

    test(
      'references, merge_user and auto-merge booleans preserve null/non-null contracts',
      () {
        final nullableBody =
            _projected(
                  _candidate(['projects', '1', 'merge_requests', '3'], _mr()),
                )!.body
                as Map;
        for (final name in [
          'merge_user',
          'assignee',
          'milestone',
          'merged_at',
          'closed_at',
        ]) {
          expect(nullableBody.containsKey(name), isTrue, reason: name);
          expect(nullableBody[name], isNull, reason: name);
        }
        expect(nullableBody['merge_when_pipeline_succeeds'], true);
        expect(nullableBody['auto_merge_enabled'], false);

        final mr = _mr()
          ..['merge_user'] = _actor(7)
          ..['diff_refs'] = {
            'base_sha': _sha,
            'head_sha': _sha,
            'start_sha': _sha,
            'extra': 'strip',
          };
        final body =
            _projected(
                  _candidate(['projects', '1', 'merge_requests', '3'], mr),
                )!.body
                as Map;
        expect(_keys(body['references']), {'short', 'relative', 'full'});
        expect(_keys(body['merge_user']), {
          'id',
          'username',
          'name',
          'avatar_url',
          'web_url',
        });
        expect(body['merge_when_pipeline_succeeds'], true);
        expect(body['auto_merge_enabled'], false);
        for (final mutation in <void Function(Map<String, Object?>)>[
          (v) => v['merge_user'] = 7,
          (v) => v['merge_when_pipeline_succeeds'] = null,
          (v) => v['references'] = {'short': 7},
        ]) {
          final invalid = _mr();
          mutation(invalid);
          expect(
            _projected(
              _candidate(['projects', '1', 'merge_requests', '3'], invalid),
            ),
            isNull,
          );
        }
      },
    );

    test(
      'legal nullable supplements survive and any other wrong type rejects whole response',
      () {
        expect(
          _projected(
            _candidate(['issues'], [_issue()], kind: ReadCacheBodyKind.page),
          ),
          isNotNull,
        );
        final invalid = _issue()..['assignee'] = 'nobody';
        expect(
          _projected(
            _candidate(
              ['issues'],
              [_issue(), invalid],
              kind: ReadCacheBodyKind.page,
            ),
          ),
          isNull,
        );
      },
    );

    test(
      'optional unsafe URLs are omitted and allowed URLs require HTTPS same origin/subpath without adornment',
      () {
        final unsafe = _project()
          ..['web_url'] = 'https://user@gitlab.example/root/group/project1'
          ..['avatar_url'] =
              'https://gitlab.example/root/uploads/a.png?token=x';
        final body =
            _projected(_candidate(['projects', '1'], unsafe))!.body as Map;
        expect(body, isNot(contains('web_url')));
        expect(body, isNot(contains('avatar_url')));
        final variants = [
          'http://gitlab.example/root/a',
          'https://evil.example/root/a',
          'https://gitlab.example/outside/a',
          'https://gitlab.example/root/a#x',
          'https://gitlab.example/root/a?x=1',
          'https://gitlab.example/root/a/../b',
        ];
        for (final url in variants) {
          final value = _project()..['web_url'] = url;
          expect(
            (_projected(_candidate(['projects', '1'], value))!.body as Map),
            isNot(contains('web_url')),
            reason: url,
          );
        }
      },
    );

    test(
      'tokens, import_url, headers, downloadURL and requestOptions never leak',
      () {
        final encoded = jsonEncode(
          _projected(
            _candidate(['issues'], [_issue()], kind: ReadCacheBodyKind.page),
          )!.body,
        );
        for (final forbidden in [
          'token',
          'import_url',
          'headers',
          'downloadURL',
          'requestOptions',
          'runners_token',
          'secret',
        ]) {
          expect(encoded, isNot(contains(forbidden)));
        }
      },
    );
  });

  group('whole-response guards and raw V11 walker', () {
    test(
      'missing/type/identity/guard failures reject whole pages without row filtering',
      () {
        final mutations = <void Function(Map<String, Object?>)>[
          (v) => v.remove('iid'),
          (v) => v['iid'] = '2',
          (v) => v['project_id'] = 9,
          (v) => v['confidential'] = true,
          (v) => v['confidential'] = null,
        ];
        for (final mutate in mutations) {
          final bad = _issue();
          mutate(bad);
          expect(
            _projected(
              _candidate(
                ['projects', '1', 'issues'],
                [_issue(), bad],
                kind: ReadCacheBodyKind.page,
              ),
            ),
            isNull,
          );
        }
      },
    );

    test(
      'raw walker catches stripped unknown, nested, and cross-project issues and indexes all public identities',
      () {
        final raw = _mr()
          ..['unknown'] = {'issue': _issue(project: 2, iid: 8)}
          ..['related_issues'] = [_issue(project: 3, iid: 9)];
        final entry = _projected(
          _candidate(['projects', '1', 'merge_requests', '3'], raw),
        )!;
        expect(entry.issueIdentities, {
          const ReadCacheIssueIdentity(2, 8),
          const ReadCacheIssueIdentity(3, 9),
        });
        final hiddenPrivate = _mr()
          ..['unknown'] = {
            'nested': {
              'issue': (_issue(project: 8, iid: 4)..['confidential'] = true),
            },
          };
        expect(
          _projected(
            _candidate(['projects', '1', 'merge_requests', '3'], hiddenPrivate),
          ),
          isNull,
        );
      },
    );

    test('M408 issue notes require a fresh public parent proof', () {
      final candidate = _candidate(
        ['projects', '1', 'issues', '2', 'notes'],
        [_note()],
        kind: ReadCacheBodyKind.page,
      );
      expect(
        _projected(candidate, context: _context(proofs: const [])),
        isNull,
      );
      expect(_projected(candidate), isNotNull);
    });

    test('M409 every discussion note is guarded with internal precedence', () {
      final base = {
        'id': 'd',
        'individual_note': false,
        'notes': [_note(1), _note(2)],
      };
      expect(
        _projected(
          _candidate(
            ['projects', '1', 'issues', '2', 'discussions'],
            [base],
            kind: ReadCacheBodyKind.page,
          ),
        ),
        isNotNull,
      );
      for (final note in <Map<String, Object?>>[
        _note()
          ..['internal'] = true
          ..['confidential'] = false,
        _note()
          ..['internal'] = false
          ..['confidential'] = true,
        _note()
          ..remove('internal')
          ..remove('confidential'),
        _note()
          ..remove('internal')
          ..['confidential'] = true,
        _note()
          ..['internal'] = 'false'
          ..['confidential'] = false,
        _note()
          ..['internal'] = false
          ..['confidential'] = null,
      ]) {
        final discussion = {
          'id': 'd',
          'individual_note': false,
          'notes': [_note(1), note],
        };
        expect(
          _projected(
            _candidate(
              ['projects', '1', 'issues', '2', 'discussions'],
              [discussion],
              kind: ReadCacheBodyKind.page,
            ),
          ),
          isNull,
        );
      }
    });
  });

  group('fresh parent evidence', () {
    final notes = _candidate(
      ['projects', '1', 'issues', '2', 'notes'],
      [_note()],
      kind: ReadCacheBodyKind.page,
    );
    test(
      'accepts only same-client fresh network single public identity and current epochs',
      () {
        expect(_projected(notes), isNotNull);
        final rejected = [
          _proof(lineage: ReadCacheProofLineage.disk),
          _proof(single: false),
          _proof(confidential: true),
          _proof(confidential: null),
          _proof(fetchedAt: _now.subtract(const Duration(seconds: 30))),
          _proof(fetchedAt: _now.add(const Duration(microseconds: 1))),
          _proof(
            binding: DiskBinding(
              accountKey: _binding.accountKey,
              generation: 5,
            ),
          ),
          _proof(
            binding: DiskBinding(
              accountKey: '${_instance.key}#8',
              generation: 4,
            ),
          ),
          ReadCachePublicIssueProof(
            binding: _binding,
            identity: const ReadCacheIssueIdentity(1, 3),
            fetchedAt: _now,
            lineage: ReadCacheProofLineage.network,
            singleIssue: true,
            confidential: false,
            privacyEpoch: 3,
          ),
          _proof(privacyEpoch: 2),
          _proof(scopes: const {'project:1': 7}),
        ];
        for (final proof in rejected) {
          expect(_projected(notes, context: _context(proofs: [proof])), isNull);
        }
        expect(
          _projected(
            notes,
            context: _context(
              confidential: {const ReadCacheIssueIdentity(1, 2)},
            ),
          ),
          isNull,
        );
      },
    );

    test(
      'parent proof requires explicit current global and project snapshots',
      () {
        for (final proof in <ReadCachePublicIssueProof>[
          _proof(scopes: const {}),
          _proof(scopes: const {'project:1': 8}),
          _proof(scopes: const {'global': 0}),
          _proof(scopes: const {'global': 0, 'project:1': 7}),
        ]) {
          expect(_projected(notes, context: _context(proofs: [proof])), isNull);
        }
        expect(
          _projected(
            notes,
            context: _context(proofs: [_proof()], scopes: const {'global': 0}),
          ),
          isNull,
        );
      },
    );
  });

  group('mutable scope snapshots', () {
    final issues = _candidate(
      ['issues'],
      [_issue()],
      kind: ReadCacheBodyKind.page,
    );

    test('empty, incomplete, missing-current and stale snapshots reject', () {
      final rejected = <_Input>[
        _candidate(
          ['issues'],
          [_issue()],
          kind: ReadCacheBodyKind.page,
          scopes: const {},
        ),
        _candidate(
          ['issues'],
          [_issue()],
          kind: ReadCacheBodyKind.page,
          scopes: const {'userLists': 8},
        ),
        _candidate(
          ['issues'],
          [_issue()],
          kind: ReadCacheBodyKind.page,
          scopes: const {'global': 0},
        ),
        _candidate(
          ['issues'],
          [_issue()],
          kind: ReadCacheBodyKind.page,
          scopes: const {'global': 0, 'userLists': 7},
        ),
        _candidate(
          ['issues'],
          [_issue()],
          kind: ReadCacheBodyKind.page,
          scopes: const {'global': 0, 'userLists': 8, 'notCurrent': 1},
        ),
      ];
      for (final input in rejected) {
        expect(_projected(input), isNull);
      }
      expect(
        _projected(issues, context: _context(scopes: const {'global': 0})),
        isNull,
      );
    });

    test(
      'derived tags persist; unrelated current scopes need not be snapshotted',
      () {
        final entry = _projected(
          issues,
          context: _context(
            scopes: const {'global': 0, 'userLists': 8, 'unrelated': 99},
          ),
        );
        expect(entry, isNotNull);
        expect(entry!.scopeTags, {'global', 'userLists'});
        expect(entry.scopeVersions, {'global': 0, 'userLists': 8});
      },
    );

    test('candidate tags require matching snapshots', () {
      expect(
        _projected(
          _candidate(
            ['issues'],
            [_issue()],
            kind: ReadCacheBodyKind.page,
            tags: const {'extra'},
          ),
        ),
        isNull,
      );
      final entry = _projected(
        _candidate(
          ['issues'],
          [_issue()],
          kind: ReadCacheBodyKind.page,
          scopes: const {'global': 0, 'userLists': 8, 'extra': 4},
          tags: const {'extra'},
        ),
        context: _context(
          scopes: const {'global': 0, 'userLists': 8, 'extra': 4},
        ),
      );
      expect(entry!.scopeTags, {'global', 'userLists', 'extra'});
    });

    test('pinned entries ignore and persist no mutable scope state', () {
      final tree = _candidate(
        ['projects', '1', 'repository', 'tree'],
        [
          {
            'id': _sha,
            'name': 'a',
            'type': 'blob',
            'path': 'a',
            'mode': '100644',
          },
        ],
        kind: ReadCacheBodyKind.page,
        query: const {'ref': _sha},
        scopes: const {},
        tags: const {'not-current'},
      );
      final entry = _projected(tree, context: _context(scopes: const {}));
      expect(entry, isNotNull);
      expect(entry!.scopeVersions, isEmpty);
      expect(entry.scopeTags, isEmpty);
    });
  });

  group('canonical key and admission', () {
    test(
      'generation is absent while Accept/account/instance/semantic query remain distinct',
      () {
        String? key({
          DiskBinding? binding,
          GitLabInstance? instance,
          String accept = 'application/json',
          Map<String, String>? query,
        }) => readCacheDurableKey(
          binding: binding ?? _binding,
          instance: instance ?? _instance,
          uri: (instance ?? _instance).api(['issues'], query),
          logicalAccept: accept,
        );
        final a = key(query: {'state': 'opened', 'scope': 'all'});
        final generation = key(
          binding: DiskBinding(accountKey: _binding.accountKey, generation: 99),
          query: {'scope': 'all', 'state': 'opened'},
        );
        expect(generation, a);
        expect(a, isNot(contains('generation')));
        expect(key(accept: 'text/plain'), isNot(a));
        expect(
          key(
            binding: DiskBinding(
              accountKey: '${_instance.key}#8',
              generation: 4,
            ),
          ),
          isNot(a),
        );
        final other = GitLabInstance.parse('https://gitlab.example/other');
        expect(
          key(
            instance: other,
            binding: DiskBinding(accountKey: '${other.key}#7', generation: 4),
          ),
          isNot(a),
        );
        expect(key(query: {'state': 'closed'}), isNot(a));
      },
    );

    test('duplicate, pagination, sensitive, search and unsafe URIs reject', () {
      final uris = [
        Uri.parse(
          'https://gitlab.example/root/api/v4/issues?state=opened&state=closed',
        ),
        _instance.api(['issues'], {'page': '2'}),
        _instance.api(['issues'], {'private_token': 'x'}),
        _instance.api(['issues'], {'search': 'needle'}),
        Uri.parse('https://gitlab.example/root/api/v4/issues/%2e%2e'),
      ];
      for (final uri in uris) {
        expect(
          readCacheDurableKey(
            binding: _binding,
            instance: _instance,
            uri: uri,
            logicalAccept: 'application/json',
          ),
          isNull,
          reason: uri.toString(),
        );
      }
    });

    test(
      'alias is detail-only and requires verified raw path/id correspondence',
      () {
        final aliasUri = _instance.api(['projects', 'group/project1']);
        final key = readCacheDurableKey(
          binding: _binding,
          instance: _instance,
          uri: aliasUri,
          logicalAccept: 'application/json',
          verifiedProjectAliases: const {'group/project1': 1},
        );
        expect(key, isNotNull);
        expect(key, contains('/root/api/v4/projects/1'));
        expect(
          _projected(_candidate(['projects', 'group/project1'], _project())),
          isNotNull,
        );
        expect(
          _projected(_candidate(['projects', 'group/project1'], _project(2))),
          isNull,
        );
        expect(
          _projected(
            _candidate(
              ['projects', 'group/project1', 'issues'],
              <Object?>[],
              kind: ReadCacheBodyKind.page,
            ),
          ),
          isNull,
        );
        expect(
          readCacheDurableKey(
            binding: _binding,
            instance: _instance,
            uri: aliasUri,
            logicalAccept: 'application/json',
          ),
          isNull,
        );
      },
    );

    test('project detail requires the network license=true superset', () {
      expect(
        _projected(
          _candidate(['projects', '1'], _project(), projectLicense: false),
        ),
        isNull,
      );
      expect(
        _projected(
          _candidate(
            ['projects', '1'],
            _project(),
            query: const {'license': 'false'},
          ),
        ),
        isNull,
      );
      expect(_projected(_candidate(['projects', '1'], _project())), isNotNull);
    });

    test('approvals global id is accepted only with trusted MR identity', () {
      final withoutId = <String, Object?>{
        'iid': 3,
        'project_id': 1,
        'approvals_required': 2,
        'approvals_left': 1,
        'approved_by': <Object?>[],
      };
      expect(
        _projected(
          _candidate([
            'projects',
            '1',
            'merge_requests',
            '3',
            'approvals',
          ], withoutId),
          context: _context(verifiedMrs: const {}),
        ),
        isNotNull,
      );
      for (final context in [
        _context(verifiedMrs: const {}),
        _context(verifiedMrs: const {(1, 3): 999}),
      ]) {
        expect(
          _projected(
            _candidate(
              ['projects', '1', 'merge_requests', '3', 'approvals'],
              {...withoutId, 'id': 203},
            ),
            context: context,
          ),
          isNull,
        );
      }
    });

    test(
      'continuations reject raw relative traversal before URI resolution',
      () {
        _Input pageWith(Uri next) => _candidate(
          ['issues'],
          [_issue()],
          kind: ReadCacheBodyKind.page,
          next: next,
        );
        expect(_projected(pageWith(Uri.parse('../v4/issues?page=2'))), isNull);
        expect(
          _projected(pageWith(Uri.parse('%2e%2e/v4/issues?page=2'))),
          isNull,
        );
        final legal = _projected(pageWith(Uri.parse('?page=2')));
        expect(legal, isNotNull);
        expect((legal!.body as Map)['next'], contains('page=2'));
      },
    );

    test('common candidate admission gates are fail closed', () {
      final lease = _Lease()..revoke();
      final candidates = [
        _candidate(['projects', '1'], _project(), cacheable: false),
        _candidate(['projects', '1'], _project(), noStore: true),
        _candidate(['projects', '1'], _project(), firstPage: false),
        _candidate(['projects', '1'], _project(), method: 'POST'),
        _candidate(['projects', '1'], _project(), privacyEpoch: 2),
        _candidate(
          ['projects', '1'],
          _project(),
          fetchedAt: _now.add(const Duration(seconds: 1)),
        ),
        _candidate(['projects', '1'], _project(), lease: lease),
      ];
      for (final candidate in candidates) {
        expect(_projected(candidate), isNull);
      }
    });

    test('deleting project is rejected rather than projected as ordinary', () {
      final deleting = _project()..['marked_for_deletion_on'] = '2026-10-24';
      expect(
        _projected(
          _candidate(
            ['projects'],
            [_project(), deleting],
            kind: ReadCacheBodyKind.page,
          ),
        ),
        isNull,
      );
    });
  });

  group('pinned proof, structural and byte bounds', () {
    test('File, Tree and README raw require confirmed exact lowercase SHA', () {
      final tree = _candidate(
        ['projects', '1', 'repository', 'tree'],
        [
          {
            'id': _sha,
            'name': 'a',
            'type': 'blob',
            'path': 'a',
            'mode': '100644',
          },
        ],
        kind: ReadCacheBodyKind.page,
        query: {'ref': _sha},
      );
      final raw = _candidate(
        ['projects', '1', 'repository', 'files', 'README.md', 'raw'],
        'hello',
        kind: ReadCacheBodyKind.text,
        query: {'ref': _sha},
      );
      expect(_projected(tree), isNotNull);
      expect(_projected(raw), isNotNull);
      expect(_projected(tree, context: _context(shas: const {})), isNull);
      expect(_projected(raw, context: _context(shas: const {})), isNull);
      final upper = _sha.toUpperCase();
      expect(
        _projected(
          _candidate(
            ['projects', '1', 'repository', 'tree'],
            <Object?>[],
            kind: ReadCacheBodyKind.page,
            query: {'ref': upper},
          ),
          context: _context(shas: {upper}),
        ),
        isNull,
      );
    });

    test('depth 32/33, array 4096/4097 and nodes 32768/32769 are exact', () {
      Object nested(int targetDepth) {
        Object value = 0;
        // Page root is depth 1, row map depth 2, extra starts at depth 3.
        for (var depth = 3; depth < targetDepth; depth++) {
          value = {'x': value};
        }
        return value;
      }

      final depth32 = _project()..['extra'] = nested(32);
      final depth33 = _project()..['extra'] = nested(33);
      expect(
        _projected(
          _candidate(['projects'], [depth32], kind: ReadCacheBodyKind.page),
        ),
        isNotNull,
      );
      expect(
        _projected(
          _candidate(['projects'], [depth33], kind: ReadCacheBodyKind.page),
        ),
        isNull,
      );
      final array4096 = _project()
        ..['extra'] = List<Object?>.filled(4096, null);
      final array4097 = _project()
        ..['extra'] = List<Object?>.filled(4097, null);
      expect(
        _projected(
          _candidate(['projects'], [array4096], kind: ReadCacheBodyKind.page),
        ),
        isNotNull,
      );
      expect(
        _projected(
          _candidate(['projects'], [array4097], kind: ReadCacheBodyKind.page),
        ),
        isNull,
      );
      Map<String, Object?> nodeFixture(int nodes) {
        final row = <String, Object?>{
          'id': 1,
          'name': 'p',
          'path_with_namespace': 'g/p',
        };
        // root list + row + 3 required scalars + extra map + 8 arrays = 14.
        var remaining = nodes - 14;
        final buckets = <String, Object?>{};
        for (var i = 0; i < 8; i++) {
          final length = remaining.clamp(0, 4096);
          buckets['b$i'] = List<Object?>.filled(length, null);
          remaining -= length;
        }
        row['extra'] = buckets;
        return row;
      }

      expect(
        _projected(
          _candidate(
            ['projects'],
            [nodeFixture(32768)],
            kind: ReadCacheBodyKind.page,
          ),
        ),
        isNotNull,
      );
      expect(
        _projected(
          _candidate(
            ['projects'],
            [nodeFixture(32769)],
            kind: ReadCacheBodyKind.page,
          ),
        ),
        isNull,
      );
    });

    test(
      'JSON and file cap include metadata and E19 validates proof, offsets, UTF-8 and 2 MiB serialized cap',
      () {
        final empty = _project()..['description'] = '';
        final base = _projected(_candidate(['projects', '1'], empty))!;
        final exact = _project()
          ..['description'] =
              'x' * (readCacheEntryLimit - base.serializedLength);
        expect(_projected(_candidate(['projects', '1'], exact)), isNotNull);
        final over = _project()
          ..['description'] =
              'x' * (readCacheEntryLimit - base.serializedLength + 1);
        expect(_projected(_candidate(['projects', '1'], over)), isNull);

        final fileBytes = List<int>.filled(readCacheEntryLimit, 65);
        final file = {
          'file_name': 'a',
          'file_path': 'a',
          'size': fileBytes.length,
          'encoding': 'base64',
          'content': base64.encode(fileBytes),
          'ref': _sha,
        };
        expect(
          _projected(
            _candidate(
              ['projects', '1', 'repository', 'files', 'a'],
              file,
              query: {'ref': _sha},
              responseBytes: 100,
            ),
          ),
          isNull,
        );

        final proof = ReadCacheTerminalJobProof(
          binding: _binding,
          projectId: 1,
          jobId: 9,
          status: 'failed',
          finishedAt: _now.subtract(const Duration(minutes: 1)),
          fetchedAt: _now,
          lineage: ReadCacheProofLineage.network,
          erased: false,
        );
        ReadCacheTerminalLog terminal(
          List<int> bytes, {
          int start = 0,
          int? next,
          int? total,
          bool eof = true,
          bool? truncated,
        }) => ReadCacheTerminalLog(
          projectId: 1,
          jobId: 9,
          finishedAt: proof.finishedAt,
          startOffset: start,
          nextOffset: next ?? start + bytes.length,
          totalBytes: total ?? start + bytes.length,
          isEof: eof,
          truncated: truncated ?? start > 0,
          bytes: bytes,
        );
        _Input terminalCandidate(ReadCacheTerminalLog value) => _candidate(
          ['projects', '1', 'jobs', '9', 'trace'],
          value,
          kind: ReadCacheBodyKind.terminalLog,
          typedPinned: true,
          responseBytes: 100,
        );
        expect(
          _projected(
            terminalCandidate(terminal(utf8.encode('尾🙂'))),
            context: _context(terminal: proof),
          ),
          isNotNull,
        );
        final badProofs = [
          ReadCacheTerminalJobProof(
            binding: _binding,
            projectId: 2,
            jobId: 9,
            status: 'failed',
            finishedAt: proof.finishedAt,
            fetchedAt: _now,
            lineage: ReadCacheProofLineage.network,
            erased: false,
          ),
          ReadCacheTerminalJobProof(
            binding: _binding,
            projectId: 1,
            jobId: 8,
            status: 'failed',
            finishedAt: proof.finishedAt,
            fetchedAt: _now,
            lineage: ReadCacheProofLineage.network,
            erased: false,
          ),
          ReadCacheTerminalJobProof(
            binding: _binding,
            projectId: 1,
            jobId: 9,
            status: 'running',
            finishedAt: proof.finishedAt,
            fetchedAt: _now,
            lineage: ReadCacheProofLineage.network,
            erased: false,
          ),
          ReadCacheTerminalJobProof(
            binding: _binding,
            projectId: 1,
            jobId: 9,
            status: 'failed',
            finishedAt: proof.finishedAt,
            fetchedAt: _now,
            lineage: ReadCacheProofLineage.disk,
            erased: false,
          ),
          ReadCacheTerminalJobProof(
            binding: _binding,
            projectId: 1,
            jobId: 9,
            status: 'failed',
            finishedAt: proof.finishedAt,
            fetchedAt: _now.subtract(const Duration(seconds: 30)),
            lineage: ReadCacheProofLineage.network,
            erased: false,
          ),
          ReadCacheTerminalJobProof(
            binding: _binding,
            projectId: 1,
            jobId: 9,
            status: 'failed',
            finishedAt: proof.finishedAt,
            fetchedAt: _now,
            lineage: ReadCacheProofLineage.network,
            erased: true,
          ),
        ];
        for (final badProof in badProofs) {
          expect(
            _projected(
              terminalCandidate(terminal(utf8.encode('log'))),
              context: _context(terminal: badProof),
            ),
            isNull,
          );
        }
        for (final invalid in [
          terminal([0x80]),
          terminal([1, 2], next: 3),
          terminal([1], total: 2),
          terminal([1], eof: false),
          terminal([1], truncated: true),
        ]) {
          expect(
            _projected(
              terminalCandidate(invalid),
              context: _context(terminal: proof),
            ),
            isNull,
          );
        }
        final huge = terminal(List<int>.filled(readCacheTerminalLogLimit, 65));
        final truncated = _projected(
          terminalCandidate(huge),
          context: _context(terminal: proof),
        );
        expect(truncated, isNotNull);
        expect(
          truncated!.serializedLength,
          lessThanOrEqualTo(readCacheTerminalLogLimit),
        );
        expect((truncated.body as ReadCacheTerminalLog).truncated, isTrue);
        expect(
          (truncated.body as ReadCacheTerminalLog).startOffset,
          greaterThan(0),
        );
      },
    );
  });
}
