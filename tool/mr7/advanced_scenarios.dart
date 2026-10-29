// Synthetic 7B3 definitions. Import only from host tooling/tests, never the app.
import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';

import '../mr7_sandbox.dart';
import 'sandbox_contract.dart';

const mr7AdvancedOwnedRows = {8, 9, 18, 20, 26, 30, 31, 32};
const mr7AdvancedHead = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const mr7AdvancedNextHead = 'dddddddddddddddddddddddddddddddddddddddd';
const mr7AdvancedMergeCommit = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const mr7AdvancedSquashCommit = 'ffffffffffffffffffffffffffffffffffffffff';
const mr7AdvancedEditedText = 'Reviewed synthetic text';
const _isolation =
    'Complete two-pass owner events window includes setup, scenario and cleanup; '
    'every event and mutation belongs to the fresh sandbox; unreadable, missing '
    'or foreign events quarantine the session. Events alone are not an audit log.';
const _cleanup =
    'One finalizer deletes only this run project after ID/path/owner revalidation '
    'and complete parent inventory; uncertain or unverified writes retain it. '
    'No reset, unlock, retry, personal snippet or account-global cleanup.';
// Observation requirements for the complete inventory below. _upgrade assigns
// the current executable definition or its specific typed disposition.
const _nameSeam = 'Exact project-bound path/name/SHA observation is required.';
const _absenceSeam =
    'Complete independent parent inventory is required; 404 is ambiguous.';
const _contentSeam = 'Exact revision-bound independent raw bytes are required.';
const _projectFieldsSeam =
    'Presence-sensitive original field and identity snapshots are required.';
const _mergeIdentitySeam =
    'Original MR ID/iid/actor and state snapshots are required.';
const _live =
    'Live NOT_RUN without owner credentials and instance feature/version checks. '
    'Missing fixture, unsupported feature, forbidden/unknown scope, uncertain '
    'send or unverified observation keeps the entire operation closed.';

/// A variant is either executable through 7B0 or explicitly closed with a seam.
/// A synthetic PASS never releases an operation or fills live/device evidence.
final class Mr7AdvancedCase {
  const Mr7AdvancedCase({
    required this.operation,
    required this.variant,
    required this.tier,
    required this.preread,
    required this.write,
    required this.readback,
    this.scenario,
    this.closedReason,
    this.refusal,
  });

  final String operation;
  final String variant;
  final String tier;
  final String preread;
  final String write;
  final String readback;
  final Mr7Scenario? scenario;
  final String? closedReason;
  final Mr7ClosedRefusal? refusal;
  String get id => 'b3-$operation-$variant';
  String get preconditions =>
      'Fresh private project in owner personal namespace, synthetic fixtures '
      'only, no fork, deployment, webhook, secrets, members or private runners. '
      '$preread';
  String get confirmation =>
      '$tier under the five production autonomy levels; T4 needs a typed '
      'target when approval is required, except retry/play. Bound bypass may '
      'execute non-hardLine without product approval unless a fixed reason '
      'requires confirmation; hardLine always needs typed approval. Sandbox '
      'also requires an explicit host confirmation, including bypass.';
  List<String> get chain => [preread, confirmation, write, readback];
  String get isolation => _isolation;
  String get cleanup => operation == 'deleteProject'
      ? 'Terminal last case: no subsequent writes and no finalizer re-delete. '
            'Observe retention/deletion, fresh actor and complete parent '
            'namespace inventory; otherwise NOT_VERIFIED/quarantine.'
      : _cleanup;
  String get notRun => '${closedReason ?? ''} $_live'.trim();

  /// Used only with production policy to prove a closed receipt row. An
  /// accidental candidate selection refuses before creating a provider call.
  Mr7Scenario get closedReceiptScenario => Mr7Scenario(
    id: id,
    suite: 'advanced',
    operation: operation,
    variant: variant,
    tier: tier,
    closed: refusal,
    call: (_) => throw const Mr7Refused('advancedVariantClosed'),
    paths: (_) => const {},
    observe: (_, _) async => false,
  );

  Mr7ClosedVariant get closedVariant => Mr7ClosedVariant(
    id: id,
    suite: 'advanced',
    operation: operation,
    variant: variant,
    tier: tier,
    refusal: refusal!,
  );
}

Mr7AdvancedCase _runnable(
  String operation,
  String variant,
  String tier, {
  required String preread,
  required String write,
  required String readback,
  required AiTargetKind targetKind,
  required Map<String, Object?> arguments,
  required String mutation,
  required String observation,
  required bool Function(Map<String, Object?> row) check,
  bool Function(Map<String, Object?> row, Mr7Identity identity)? identityCheck,
  Future<bool> Function(Mr7Readback, Mr7Identity)? observe,
  Set<String> Function(Mr7Identity)? observerPaths,
  List<Mr7SnapshotSpec> Function(Mr7Identity)? preRead,
  Mr7ParentStateObservation Function(Mr7Identity)? noChangeObservation,
}) {
  final id = 'b3-$operation-$variant';
  final owningKind = aiWriteProposalTargetKind(
    productionAiLedger.find(operation)!,
  );
  final effect =
      observe ??
      (Mr7Readback observer, Mr7Identity p) async {
        final row = await observer.read(
          observation.replaceAll('{project}', '${p.projectId}'),
        );
        return check(row) && (identityCheck?.call(row, p) ?? true);
      };
  final definition = Mr7Scenario(
    id: id,
    suite: 'advanced',
    operation: operation,
    variant: variant,
    tier: tier,
    targetKind: targetKind,
    targetKinds: {
      owningKind,
      targetKind,
      if (operation == 'createTag') AiTargetKind.ref,
    },
    fixture: (session, p) async {
      final attached = Mr7AdvancedFixture.attached(session.server);
      final fixture = attached != null && !attached._used
          ? attached
          : Mr7AdvancedFixture(
              session.server,
              variant: variant,
              operation: operation,
            );
      fixture._used = true;
      fixture.configureProject();
      // Project field presence is intentional fixture data, never normalized
      // by an observer or copied from the acknowledgement.
      session.server.project!.putIfAbsent(
        'description',
        () => 'Original description',
      );
      if (operation == 'mergeRequest' && variant == 'auto-merge') {
        final before = await session.read(
          'projects/${p.projectId}/merge_requests/3',
        );
        if (before['id'] != 33 ||
            before['iid'] != 3 ||
            before['project_id'] != p.projectId ||
            before['sha'] != mr7AdvancedHead ||
            before['state'] != 'opened' ||
            before['auto_merge_enabled'] != false) {
          throw const Mr7Refused('advancedPrecondition');
        }
      }
      if (operation == 'approveMergeRequest' ||
          operation == 'cancelAutoMerge') {
        final before = await session.read(
          'projects/${p.projectId}/merge_requests/3',
        );
        final approvals = before['approved_by'];
        if (before['id'] is! int ||
            before['iid'] != 3 ||
            before['project_id'] != p.projectId ||
            before['state'] != 'opened' ||
            before['user'] is! Map ||
            (before['user'] as Map)['can_merge'] != true ||
            (operation == 'approveMergeRequest' &&
                (approvals is! List || approvals.isNotEmpty)) ||
            (operation == 'cancelAutoMerge' &&
                before['auto_merge_enabled'] != true)) {
          throw const Mr7Refused('advancedPrecondition');
        }
      }
      return const Mr7ScenarioFixtures();
    },
    preRead:
        preRead ??
        (operation.contains('Merge') || operation == 'mergeRequest'
            ? (p) => [
                Mr7SnapshotSpec(
                  path: 'projects/${p.projectId}/merge_requests/3',
                  fields: {
                    'sha',
                    'state',
                    'user',
                    'approved_by',
                    'auto_merge_enabled',
                  },
                  unchangedFields:
                      operation == 'approveMergeRequest' ||
                          operation == 'cancelAutoMerge'
                      ? {'sha', 'state', 'user'}
                      : {},
                ),
              ]
            : null),
    noChangeObservation: noChangeObservation,
    utterance: (p) =>
        'Perform $operation $variant only in synthetic project ${p.path}. '
        'Merge request !3, pipeline 12, job 21 and snippet #42 are fixtures.',
    resource: (_) => operation.contains('Merge') || operation == 'mergeRequest'
        ? const AiResourceRef(kind: AiResourceKind.mergeRequest, id: 3)
        : const AiResourceRef(kind: AiResourceKind.file, id: 1),
    call: (p) => AiToolCall(
      id: id,
      name: operation,
      arguments: {'projectId': p.projectId, ...arguments},
    ),
    paths: (p) => {mutation.replaceAll('{project}', '${p.projectId}')},
    readbackPaths: (p, _) =>
        observerPaths?.call(p) ??
        {observation.replaceAll('{project}', '${p.projectId}')},
    observe: (observer, p) async {
      if (operation == 'mergeRequest' && variant == 'auto-merge') {
        final rows = observer.snapshot?.metadata['resources'] as List?;
        if (rows == null ||
            rows.length != 1 ||
            ((rows.single as Map)['fieldDigests']
                    as Map)['auto_merge_enabled'] !=
                mr7Digest({'present': true, 'value': false})) {
          return false;
        }
      }
      final before = observer.verifiedRequests;
      final verified = await effect(observer, p);
      // The runner's later identity/snapshot reads cannot supply effect evidence.
      return verified && observer.verifiedRequests > before;
    },
  );
  return Mr7AdvancedCase(
    operation: operation,
    variant: variant,
    tier: tier,
    preread: preread,
    write: write,
    readback: readback,
    scenario: definition,
  );
}

Iterable<Mr7AdvancedCase> _closed(
  String operation,
  String tier,
  List<String> variants, {
  required String preread,
  required String write,
  required String readback,
  required String reason,
}) sync* {
  for (final variant in variants) {
    yield Mr7AdvancedCase(
      operation: operation,
      variant: variant,
      tier: tier,
      preread: preread,
      write: write,
      readback: readback,
      closedReason: reason,
    );
  }
}

/// Full current production-ledger enumeration for the 7B3 families. Unsupported
/// variants stay visible here so adding a convenient happy path cannot hide gaps.
List<Mr7AdvancedCase> _listedAdvancedCases() => [
  for (final op in ['edit_file', 'createFile', 'deleteFile', 'applySuggestion'])
    ..._closed(
      op,
      op == 'deleteFile' ? 'T4 -> hardLine (CI)' : 'T3 -> T4/hardLine',
      [
        'ordinary-ref',
        'default-ref',
        'protected-ref',
        'cas-drift',
        'ci-config',
        'same-field-upload-roundtrip',
        'cross-nonce-provenance',
        if (op == 'applySuggestion') 'suggestion-version',
      ],
      preread:
          'GET project, branch SHA, file version/content or exact MR '
          'discussion/suggestion IDs; bind last_commit_id and upload provenance.',
      write:
          'Production named $op wrapper, one CAS-bound write on fixture ref.',
      readback:
          'Independent exact path/SHA/content or suggestion state; deletion '
          'also needs authenticated complete parent listing.',
      reason: op == 'deleteFile' ? _absenceSeam : _nameSeam,
    ),
  for (final op in [
    'createBranch',
    'deleteBranch',
    'createTag',
    'deleteTag',
    'createRelease',
    'updateRelease',
    'deleteRelease',
  ])
    ..._closed(
      op,
      ['createBranch', 'createRelease', 'updateRelease'].contains(op)
          ? 'T3'
          : 'T4',
      ['ordinary-ref', 'default-ref', 'protected-ref', 'sha-drift'],
      preread:
          'GET exact source commit and branch/tag/release; bind name, SHA, '
          'default/protection flags and description version. Protected/default '
          'branch deletion must refuse with zero mutations.',
      write: 'Production named $op wrapper; immutable source SHA for creation.',
      readback:
          'Independent named ref/release fields and SHA; deletion requires '
          'complete parent listing plus fresh actor/target identity.',
      reason: op.startsWith('delete') ? _absenceSeam : _nameSeam,
    ),
  for (final variant in [
    'ordinary',
    'default-target',
    'protected-target',
    'squash',
    'auto-merge',
    'ci-default',
    'ci-custom',
  ])
    _runnable(
      'mergeRequest',
      variant,
      variant.startsWith('ci-')
          ? 'hardLine'
          : ['default-target', 'protected-target'].contains(variant)
          ? 'T4'
          : 'T3',
      preread:
          'GET MR SHA/diff_refs, complete diffs/commits/closes_issues, '
          'target protection/default and project CI config. Reprepare same snapshot.',
      write:
          'mergeRequest with pinned SHA, explicit squash/auto/source-removal flags.',
      readback:
          'Independent returned MR ID/iid/project, pinned head and merge commit '
          'SHA, distinct squash commit for squash, or newly enabled auto-merge '
          'flag; scheduling is not completed merge.',
      targetKind: AiTargetKind.merge,
      arguments: {
        'iid': 3,
        'squash': variant == 'squash',
        'autoMerge': variant == 'auto-merge',
        'removeSourceBranch': false,
      },
      mutation: 'PUT projects/{project}/merge_requests/3/merge',
      observation: 'projects/{project}/merge_requests/3',
      check: (r) =>
          r['sha'] == mr7AdvancedHead &&
          (variant == 'auto-merge'
              ? r['state'] == 'opened' && r['auto_merge_enabled'] == true
              : r['state'] == 'merged' &&
                    r['merge_commit_sha'] == mr7AdvancedMergeCommit &&
                    (variant != 'squash' ||
                        r['squash_commit_sha'] == mr7AdvancedSquashCommit)),
    ),
  ..._closed(
    'mergeRequest',
    'T3 -> T4/hardLine',
    [
      'source-branch-removal',
      'closing-issues',
      'foreign-closing-issues',
      'head-drift',
      'diff-snapshot-drift',
      'ci-config-drift',
      'fork-source',
    ],
    preread:
        'Complete MR snapshot, closures and source/target project ownership; '
        'foreign closures/fork are forbidden; drift refuses before send.',
    write:
        'Pinned merge with source-removal option only for same-project fixture.',
    readback:
        'Independent MR plus source ref absence and each closing issue state.',
    reason:
        'NOT_RUN/closed: 7B0 observer binds every observation to mutation '
        'returned ID, so secondary source-ref/issue effects need a scoped seam; '
        'fork/foreign issue mutations are outside project authorization.',
  ),
  ..._closed(
    'approveMergeRequest',
    'T4',
    ['sha-bound'],
    preread:
        'GET same-project opened MR and exact head SHA; instance must allow '
        'owner approval without adding members.',
    write: 'approveMergeRequest with pinned SHA, typed !3.',
    readback:
        'Independent returned MR identity and approved_by owner numeric ID.',
    reason:
        '$_mergeIdentitySeam Prove readable prior approvals and a newly added '
        'approval by the validated owner, not a pre-existing or different actor.',
  ),
  ..._closed(
    'approveMergeRequest',
    'T4',
    ['head-drift', 'approval-unavailable', 'protected-approval-escalation'],
    preread:
        'GET approval capability, opened MR, head and protection snapshot.',
    write: 'No write when head moves or instance requires another member.',
    readback:
        'Independent same-head owner approval, never another member fixture.',
    reason:
        'NOT_RUN/closed: feature/permission and protected approval fixture '
        'must exist without another member; drift is a zero-write negative case.',
  ),
  ..._closed(
    'cancelAutoMerge',
    'T3',
    ['current-endpoint'],
    preread: 'GET opened same-project MR, auto-merge enabled and can_merge.',
    write: 'POST cancel_auto_merge with empty body, once.',
    readback: 'Independent exact MR, readable auto-merge flag now false.',
    reason:
        '$_mergeIdentitySeam Prove auto-merge was enabled and can_merge was '
        'true; production only records the latter for its preview.',
  ),
  ..._closed(
    'cancelAutoMerge',
    'T3',
    ['deprecated-fallback', '409-no-change'],
    preread: 'GET auto-merge state; 404/405 alone may select legacy endpoint.',
    write: 'Bounded current then deprecated endpoint; 409 must not retry.',
    readback: 'Independent MR flags; no-change remains no-change.',
    reason:
        'NOT_RUN/closed: fallback returns status without numeric resource ID; '
        '409 no-change receipt has no independent observation in 7B0.',
  ),
  ..._closed(
    'rebaseMergeRequest',
    'T3',
    ['accepted', 'async-completion', 'late-reply'],
    preread: 'GET opened MR SHA/source branch, bind async identity.',
    write: 'rebaseMergeRequest once; accepted async work is not completion.',
    readback:
        'Independent exact MR rebase_in_progress/merge_error and new SHA.',
    reason:
        'NOT_RUN/closed: rebase acknowledgement lacks numeric resource ID; '
        'needs bounded asynchronous observation, no resend.',
  ),
  ..._closed(
    'publishDraftNotes',
    'T3',
    [
      'whole-batch',
      'external-drafts',
      'batch-20',
      'batch-21-refused',
      'unsafe-last-draft',
      'batch-cas-drift',
    ],
    preread:
        'GET complete draft batch, max 20, scan every body including '
        'sandbox drafts created outside the current conversation segment.',
    write:
        'One bulk_publish only after frozen whole-batch scan and confirmation.',
    readback:
        'Complete independent draft list proves each published ID absent '
        'and notes under the same MR prove publication.',
    reason: _absenceSeam,
  ),
  ..._closed(
    'deleteDraftNote',
    'T4',
    ['owned-draft', 'external-draft', 'cas-drift'],
    preread: 'GET exact MR/draft ID, author/body version; typed !3.',
    write: 'deleteDraftNote for this synthetic draft only.',
    readback: 'Independent complete draft list and parent/actor identity.',
    reason: _absenceSeam,
  ),
  _runnable(
    'createPipeline',
    'echo-only',
    'T4',
    preread:
        'GET sandbox branch; only synthetic echo CI, no deployments, '
        'secrets, private runners or stored variable/input reads.',
    write: 'createPipeline on checked ref, no variables.',
    readback:
        'Independent returned pipeline ID, project, ref and pending status.',
    targetKind: AiTargetKind.ref,
    arguments: {'ref': 'mr7-topic'},
    mutation: 'POST projects/{project}/pipeline',
    observation: 'projects/{project}/pipelines/13',
    check: (r) => r['ref'] == 'mr7-topic' && r['status'] == 'pending',
  ),
  for (final variant in ['new-variable-escalation', 'no-runner'])
    ..._closed(
      'createPipeline',
      variant == 'new-variable-escalation' ? 'hardLine' : 'T4',
      [variant],
      preread:
          'Validate synthetic variable names and runner availability; '
          'never read existing variables/inputs.',
      write: 'New variables are synthetic-only; no live variables authorized.',
      readback: 'Independent returned pipeline and safe echo execution.',
      reason:
          'NOT_RUN/closed: no live runner/variable authorization; variable '
          'escalation remains a synthetic gate requirement, not live coverage.',
    ),
  for (final op in ['pipelineAction', 'jobAction'])
    for (final action
        in op == 'jobAction'
            ? ['cancel', 'retry', 'play']
            : ['cancel', 'retry'])
      _runnable(
        op,
        action,
        action == 'cancel' ? 'T3' : 'T4',
        preread:
            'GET exact ${op == 'jobAction' ? 'job and parent pipeline, name/stage' : 'pipeline'} '
            'ID/ref/state. Never read stored variables or inputs.',
        write:
            '$op $action with empty body; retry/play ordinary confirmation '
            'has no typed name; bound bypass may auto-execute, host still confirms.',
        readback:
            'Independent exact returned ID/ref/status and parent; retry job '
            'may have a new ID. Live stored-parameter behavior remains §22.3 NOT_RUN.',
        targetKind: op == 'jobAction'
            ? AiTargetKind.job
            : AiTargetKind.pipeline,
        arguments: {
          if (op == 'jobAction') 'jobId': 21 else 'pipelineId': 12,
          'action': action,
        },
        mutation: op == 'jobAction'
            ? 'POST projects/{project}/jobs/21/$action'
            : 'POST projects/{project}/pipelines/12/$action',
        observation: op == 'jobAction'
            ? 'projects/{project}/jobs/${action == 'retry' ? 22 : 21}'
            : 'projects/{project}/pipelines/12',
        check: (r) =>
            r['ref'] == 'mr7-topic' &&
            r['status'] == (action == 'cancel' ? 'canceled' : 'pending') &&
            (op != 'jobAction' ||
                (r['pipeline'] is Map &&
                    (r['pipeline'] as Map)['id'] == 12 &&
                    r['name'] == 'synthetic-echo' &&
                    r['stage'] == 'test')),
      ),
  ..._closed(
    'playPipelineSchedule',
    'T4 -> hardLine',
    [
      'empty-parameters',
      'stored-variables',
      'stored-inputs',
      'unreadable-parameters',
      'hmac-drift',
      'schedule-unavailable',
    ],
    preread:
        'GET owned synthetic echo schedule; explicit empty parameters T4; '
        'nonempty/unreadable hardLine, process-key HMAC snapshot. No live values.',
    write: 'playPipelineSchedule once, no supplied variables/inputs.',
    readback:
        'Independent exact schedule and newly created pipeline within '
        'bounded window; retained parameter behavior needs actual server proof.',
    reason:
        '$_absenceSeam Schedule response is message-only; cannot bind a '
        'new pipeline. Schedule fixtures unavailable in sandbox stay closed; '
        '§22.3 parameter reuse is NOT_RUN.',
  ),
  ..._closed(
    'deletePipeline',
    'T4',
    ['owned-pipeline', 'ambiguous-404'],
    preread:
        'GET exact synthetic pipeline/ref/status, typed numeric pipeline ID.',
    write: 'deletePipeline once.',
    readback: 'Complete independent pipeline list plus actor/project checks.',
    reason: _absenceSeam,
  ),
  ..._closed(
    'createSnippet',
    'T2 -> hardLine',
    [
      'private-project',
      'new-nonprivate',
      'personal-excluded',
      'cross-nonce-provenance',
    ],
    preread:
        'GET project visibility; synthetic file/body and same-field upload '
        'provenance; new nonprivate requires hardLine typed project path.',
    write: 'createSnippet only in project, never personal endpoint.',
    readback: 'Independent exact snippet/file set, visibility and raw content.',
    reason: _contentSeam,
  ),
  for (final raised in [false, true])
    _runnable(
      'updateSnippetMetadata',
      raised ? 'visibility-raised' : 'private',
      raised ? 'hardLine' : 'T2',
      preread:
          'GET exact project snippet, full file set, updated_at, title and '
          'visibility; resend unchanged metadata only from that snapshot.',
      write: 'updateSnippetMetadata; visibility increase requires typed #42.',
      readback:
          'Independent numeric snippet identity, exact title/description, '
          'visibility and unchanged complete file set.',
      targetKind: AiTargetKind.snippet,
      arguments: {
        'snippetId': 42,
        'fields': {
          'title': 'Updated synthetic snippet',
          'description': 'Synthetic metadata',
          'visibility': raised ? 'public' : 'private',
        },
      },
      mutation: 'PUT projects/{project}/snippets/42',
      observation: 'projects/{project}/snippets/42',
      check: (r) =>
          r['title'] == 'Updated synthetic snippet' &&
          r['description'] == mr7AdvancedEditedText &&
          r['visibility'] == (raised ? 'public' : 'private') &&
          _filePaths(r).join(',') == 'a.txt,b.txt',
    ),
  ..._closed(
    'updateSnippetMetadata',
    'T2 -> hardLine',
    ['file-set-cas-drift', 'provenance', 'personal-excluded'],
    preread: 'GET exact file-set/revision and source metadata provenance.',
    write: 'Refuse a changed file-set or personal/foreign target before PUT.',
    readback: 'Independent metadata; no mutation response used as evidence.',
    reason:
        'NOT_RUN/closed: exact provenance/CAS variants need their own '
        'candidate evidence; personal targets are outside the sandbox.',
  ),
  for (final op in ['updateSnippet', 'updateSnippetFiles'])
    ..._closed(
      op,
      'T2',
      [
        'exact-edit',
        'file-set-cas-drift',
        'provenance',
        if (op == 'updateSnippetFiles') ...[
          'create-file',
          'move-file',
          'update-file',
        ],
        'personal-excluded',
      ],
      preread:
          'GET snippet/file-set/revision, bracket affected raw reads; '
          'exact fragment edits and provenance must match.',
      write: 'Production named $op once with at most two file actions.',
      readback:
          'Independent full file-set and every changed raw byte at revision.',
      reason: _contentSeam,
    ),
  _runnable(
    'deleteSnippetFile',
    'one-of-two',
    'T4',
    preread:
        'GET two-file project snippet, exact revision and deleted file '
        'content; last-file deletion is refused; typed a.txt.',
    write: 'deleteSnippetFile PUT removes only a.txt, preserving b.txt.',
    readback:
        'Independent existing snippet metadata, complete file set exactly b.txt.',
    targetKind: AiTargetKind.snippet,
    arguments: {'snippetId': 42, 'path': 'a.txt'},
    mutation: 'PUT projects/{project}/snippets/42',
    observation: 'projects/{project}/snippets/42',
    check: (r) =>
        _filePaths(r).join(',') == 'b.txt' && r['visibility'] == 'private',
  ),
  ..._closed(
    'deleteSnippetFile',
    'T4',
    ['last-file-refused', 'file-set-cas-drift', 'personal-excluded'],
    preread: 'GET complete file set, revision and ownership.',
    write: 'Zero writes for last file, drift or personal target.',
    readback: 'Independent retained snippet and complete file set.',
    reason:
        'NOT_RUN/closed: negative CAS/last-file variants require dedicated '
        'evidence; personal snippets are outside project authorization.',
  ),
  ..._closed(
    'deleteSnippet',
    'T4',
    ['owned-project', 'file-set-cas-drift', 'personal-excluded'],
    preread: 'GET exact snippet and all affected files, max four; typed #42.',
    write: 'Delete only this run synthetic project snippet, never personal.',
    readback: 'Fresh actor and complete parent snippet list proves ID absent.',
    reason: _absenceSeam,
  ),
  for (final op in [
    'deleteNote',
    'deleteDiscussionNote',
    'deleteIssue',
    'deleteMergeRequest',
    'deleteLabel',
    'deleteMilestone',
    'deleteBoard',
    'deleteBoardList',
  ])
    ..._closed(
      op,
      'T4',
      ['owned-fixture', 'version-drift', 'ambiguous-404'],
      preread:
          'GET exact synthetic $op target, parent, author and version; '
          'bind project/numeric IDs and typed target.',
      write: 'One production named $op deletion of the run-owned fixture.',
      readback:
          'Independent complete parent inventory plus fresh actor/project '
          'identity; never infer deletion from acknowledgement or 404 alone.',
      reason: _absenceSeam,
    ),
  for (final op in [
    'deletePackage',
    'deletePackageFile',
    'deleteContainerRepository',
    'deleteContainerTag',
  ])
    ..._closed(
      op,
      'T4',
      [
        'owned-registry-fixture',
        'feature-unavailable',
        'fixture-unavailable',
        'retention-pending',
      ],
      preread:
          'GET run-created package/file or project-bound registry repository/'
          'tag identity, digest, deletability and permission; no owner data.',
      write: 'One named $op only for a fixture created by this run.',
      readback:
          'Independent complete registry inventory and deletion/retention '
          'state, exact project/resource identity.',
      reason:
          '$_absenceSeam No safe registry fixture creation seam; container '
          'port uses registry/repositories/:id, refused by project-only read guard.',
    ),
  ..._closed(
    'editProject',
    'hardLine',
    ['name', 'description'],
    preread:
        'GET sandbox ID/path/owner/private status and both current name/'
        'description; omitted-field CAS must stay bound.',
    write:
        'editProject PUT resends only name/description; typed full project path.',
    readback: 'Independent exact sandbox identity and both final fields.',
    reason: _projectFieldsSeam,
  ),
  ..._closed(
    'editProject',
    'hardLine',
    ['omitted-field-cas-drift', 'protection-refused', 'transfer-refused'],
    preread:
        'GET both fields and fixed sandbox identity immediately before send.',
    write:
        'No protection, transfer, visibility or external-integration fields.',
    readback:
        'Independent unchanged identity/fields; forbidden fields zero writes.',
    reason:
        'NOT_RUN/closed: negative CAS/forbidden-field checks cannot establish '
        'a successful variant; protection/transfer writes are outside authorization.',
  ),
  ..._closed(
    'deleteProject',
    'hardLine',
    ['terminal-deleted', 'retention-pending', 'ambiguous-404'],
    preread:
        'Last suite case only; fresh numeric ID/full path/owner/nonce and '
        'actor verified before DELETE; typed full path.',
    write:
        'Terminal AI deleteProject once; no subsequent writes or finalizer re-delete.',
    readback:
        'Independent deletion request, retention state, fresh actor and '
        'complete parent namespace inventory; 404 alone is insufficient.',
    reason:
        '$_absenceSeam Terminal parent/actor observation is unavailable to '
        'Mr7Readback; harness cleanup does not prove AI deleteProject.',
  ),
  for (final op in [
    'createProject',
    'forkProject',
    'markAllTodosDone',
    'batchApplySuggestions',
  ])
    ..._closed(
      op,
      op == 'batchApplySuggestions'
          ? 'T3'
          : op == 'markAllTodosDone'
          ? 'T4'
          : 'hardLine',
      ['excluded'],
      preread:
          'Project sandbox authorization cannot cover personal namespace/'
          'account-global resources; batch suggestions are model-hidden.',
      write: 'No mutation; explicit 7B0 excluded-operation guard.',
      readback: 'No operation success claim; assert zero scenario mutations.',
      reason:
          'NOT_RUN/closed: binding §3 7-D4/7-D5 and §5.2 exclusion; '
          'harness project setup is not createProject evidence.',
    ),
];

Mr7Parent _originalMr(Mr7Readback observer) {
  final rows = observer.snapshot?.metadata['resources'] as List?;
  if (rows == null || rows.length != 1) {
    throw const Mr7Refused('advancedSnapshotMissing');
  }
  final row = rows.single as Map;
  return Mr7Parent.mergeRequest(id: row['id'] as int, iid: row['iid'] as int);
}

Mr7AdvancedCase _upgrade(Mr7AdvancedCase c) {
  Mr7AdvancedCase run({
    required AiTargetKind kind,
    required Map<String, Object?> args,
    required String mutation,
    required Set<String> Function(Mr7Identity) paths,
    required Future<bool> Function(Mr7Readback, Mr7Identity) observe,
    String? tier,
    List<Mr7SnapshotSpec> Function(Mr7Identity)? preRead,
    Mr7ParentStateObservation Function(Mr7Identity)? noChange,
  }) => _runnable(
    c.operation,
    c.variant,
    tier ?? c.tier,
    preread: c.preread,
    write: c.write,
    readback: c.readback,
    targetKind: kind,
    arguments: args,
    mutation: mutation,
    observation: '',
    check: (_) => false,
    observe: observe,
    observerPaths: paths,
    preRead: preRead,
    noChangeObservation: noChange,
  );
  Set<String> mrPaths(Mr7Identity p) => {
    'projects/${p.projectId}/merge_requests/3',
  };
  if (c.operation == 'editProject' &&
      ['name', 'description'].contains(c.variant)) {
    final field = c.variant;
    final omitted = field == 'name' ? 'description' : 'name';
    final expected = field == 'name'
        ? 'Synthetic renamed display'
        : 'Synthetic project description';
    return run(
      kind: AiTargetKind.project,
      args: {field: expected},
      mutation: 'PUT projects/{project}',
      paths: (p) => {'projects/${p.projectId}'},
      preRead: (p) => [
        Mr7SnapshotSpec(
          path: 'projects/${p.projectId}',
          fields: {'name', 'description'},
          unchangedFields: {omitted},
        ),
      ],
      observe: (o, p) async =>
          (await o.read('projects/${p.projectId}'))[field] == expected,
    );
  }
  if (c.operation == 'approveMergeRequest' && c.variant == 'sha-bound') {
    return run(
      kind: AiTargetKind.mergeRequest,
      args: {'iid': 3},
      mutation: 'POST projects/{project}/merge_requests/3/approve',
      paths: (p) => {
        ...mrPaths(p),
        'projects/${p.projectId}/merge_requests/3/approvals',
      },
      observe: (o, _) => o.observe(
        Mr7ApprovalObservation(parent: _originalMr(o), approved: true),
      ),
    );
  }
  if (c.operation == 'cancelAutoMerge' && c.variant == 'current-endpoint') {
    return run(
      kind: AiTargetKind.mergeRequest,
      args: {'iid': 3},
      mutation: 'POST projects/{project}/merge_requests/3/cancel_auto_merge',
      paths: mrPaths,
      noChange: (_) => const Mr7ParentStateObservation(
        parent: Mr7Parent.mergeRequest(id: 33, iid: 3),
        state: Mr7ParentState.autoMerge,
        expected: false,
      ),
      observe: (o, _) => o.observe(
        Mr7ParentStateObservation(
          parent: _originalMr(o),
          state: Mr7ParentState.autoMerge,
          expected: false,
        ),
      ),
    );
  }
  if (c.operation == 'rebaseMergeRequest' &&
      ['accepted', 'async-completion'].contains(c.variant)) {
    return run(
      kind: AiTargetKind.mergeRequest,
      args: {'iid': 3},
      mutation: 'POST projects/{project}/merge_requests/3/rebase',
      paths: mrPaths,
      observe: (o, _) async {
        final row = await o.observe(
          Mr7RebaseObservation(
            parent: _originalMr(o),
            sha: mr7AdvancedNextHead,
            interval: Duration.zero,
          ),
        );
        return row['sha'] == mr7AdvancedNextHead;
      },
    );
  }
  if (c.operation == 'deleteDraftNote' &&
      ['owned-draft', 'external-draft'].contains(c.variant)) {
    return run(
      kind: AiTargetKind.note,
      args: {'iid': 3, 'noteId': 8},
      mutation: 'DELETE projects/{project}/merge_requests/3/draft_notes/8',
      preRead: (p) => [
        Mr7SnapshotSpec(
          path: 'projects/${p.projectId}/merge_requests/3',
          fields: {'sha'},
          unchangedFields: {'sha'},
        ),
      ],
      paths: (p) => {
        ...mrPaths(p),
        'projects/${p.projectId}/merge_requests/3/draft_notes',
      },
      observe: (o, _) async {
        await o.observe(
          Mr7ListObservation(
            parent: _originalMr(o),
            kind: Mr7ListKind.draftNotes,
            expectedIds: {},
          ),
        );
        return true;
      },
    );
  }
  if (c.operation == 'deletePipeline' && c.variant == 'owned-pipeline') {
    return run(
      kind: AiTargetKind.pipeline,
      args: {'pipelineId': 12},
      mutation: 'DELETE projects/{project}/pipelines/12',
      paths: (p) => {
        'projects/${p.projectId}',
        'projects/${p.projectId}/pipelines',
      },
      observe: (o, _) async {
        await o.observe(
          Mr7ListObservation(
            parent: const Mr7Parent.project(),
            kind: Mr7ListKind.pipelines,
            expectedIds: {},
          ),
        );
        return true;
      },
    );
  }
  if (c.variant == 'ordinary-ref' &&
      ['createBranch', 'createTag'].contains(c.operation)) {
    final branch = c.operation == 'createBranch';
    final collection = branch ? 'branches' : 'tags';
    return run(
      kind: branch ? AiTargetKind.newBranch : AiTargetKind.tag,
      args: {
        if (branch) 'branch': 'mr7-new' else 'tag_name': 'mr7-new',
        'ref': 'mr7-topic',
      },
      mutation: 'POST projects/{project}/repository/$collection',
      paths: (p) => {'projects/${p.projectId}/repository/$collection/mr7-new'},
      observe: (o, _) async {
        await o.observe(
          Mr7RefObservation(
            kind: branch ? Mr7RefKind.branch : Mr7RefKind.tag,
            name: 'mr7-new',
            sha: mr7AdvancedHead,
          ),
        );
        return true;
      },
    );
  }
  if (c.variant == 'ordinary-ref' &&
      ['deleteBranch', 'deleteTag', 'deleteRelease'].contains(c.operation)) {
    final branch = c.operation == 'deleteBranch';
    final release = c.operation == 'deleteRelease';
    final collection = release
        ? 'releases'
        : 'repository/${branch ? 'branches' : 'tags'}';
    return run(
      kind: release
          ? AiTargetKind.release
          : branch
          ? AiTargetKind.branch
          : AiTargetKind.tag,
      args: {if (branch) 'branch': 'mr7-topic' else 'tag_name': 'mr7-tag'},
      mutation:
          'DELETE projects/{project}/$collection/${branch ? 'mr7-topic' : 'mr7-tag'}',
      paths: (p) => {
        'projects/${p.projectId}',
        'projects/${p.projectId}/$collection',
      },
      observe: (o, _) async {
        await o.observe(
          Mr7ListObservation(
            parent: const Mr7Parent.project(),
            kind: release
                ? Mr7ListKind.releases
                : branch
                ? Mr7ListKind.branches
                : Mr7ListKind.tags,
            expectedIds: branch ? {'mr7-target'} : {},
          ),
        );
        return true;
      },
    );
  }
  if (c.variant == 'ordinary-ref' &&
      ['createRelease', 'updateRelease'].contains(c.operation)) {
    final create = c.operation == 'createRelease';
    return run(
      kind: create ? AiTargetKind.tag : AiTargetKind.release,
      args: {
        if (!create) 'tag_name': 'mr7-tag',
        'fields': {
          if (create) 'tag_name': 'mr7-tag',
          'name': 'Synthetic release',
          'description': 'Initial synthetic text',
        },
      },
      mutation:
          '${create ? 'POST' : 'PUT'} projects/{project}/releases${create ? '' : '/mr7-tag'}',
      paths: (p) => {'projects/${p.projectId}/releases/mr7-tag'},
      observe: (o, _) async {
        final row = await o.observe(
          const Mr7ReleaseObservation(
            tag: 'mr7-tag',
            name: 'Synthetic release',
            sha: mr7AdvancedHead,
          ),
        );
        return row['description'] == mr7AdvancedEditedText;
      },
    );
  }
  if (c.operation == 'deleteSnippet' && c.variant == 'owned-project') {
    return run(
      kind: AiTargetKind.snippet,
      args: {'snippetId': 42},
      mutation: 'DELETE projects/{project}/snippets/42',
      paths: (p) => {
        'projects/${p.projectId}',
        'projects/${p.projectId}/snippets',
      },
      observe: (o, _) async {
        await o.observe(
          Mr7ListObservation(
            parent: const Mr7Parent.project(),
            kind: Mr7ListKind.snippets,
            expectedIds: {},
          ),
        );
        return true;
      },
    );
  }
  if (c.scenario != null &&
      !c.operation.contains('Snippet') &&
      c.operation != 'createPipeline') {
    return c;
  }
  final (cause, code, reason) = _closedDisposition(c);
  return Mr7AdvancedCase(
    operation: c.operation,
    variant: c.variant,
    tier: c.tier,
    preread: c.preread,
    write: c.write,
    readback: c.readback,
    refusal: Mr7ClosedRefusal(cause, code),
    closedReason: reason,
  );
}

(Mr7ClosureCause, String, String) _closedDisposition(Mr7AdvancedCase c) {
  if (c.operation.contains('Package') || c.operation.contains('Container')) {
    return (
      Mr7ClosureCause.fixtureUnavailable,
      'registryFixtureUnavailable',
      'No run-created registry publish/push/ownership/inventory lifecycle; owner data is excluded.',
    );
  }
  if (c.variant.contains('personal') ||
      [
        'createProject',
        'forkProject',
        'markAllTodosDone',
        'batchApplySuggestions',
      ].contains(c.operation)) {
    return (
      Mr7ClosureCause.scopeExcluded,
      'bindingScopeExcluded',
      'Binding 7-D4/7-D5 and 5.2 exclude personal/account-global or model-hidden batch operations.',
    );
  }
  if (c.variant.contains('foreign') || c.variant == 'fork-source') {
    return (
      Mr7ClosureCause.scopeExcluded,
      'foreignEffectExcluded',
      'Cross-project effects are outside sandbox authorization.',
    );
  }
  if ((c.operation == 'editProject' &&
          c.variant == 'omitted-field-cas-drift') ||
      (c.operation == 'approveMergeRequest' && c.variant == 'head-drift') ||
      (c.operation == 'publishDraftNotes' && c.variant.contains('drift'))) {
    return (
      Mr7ClosureCause.releasePolicy,
      'casDriftRefused',
      'Dedicated production-path probes prove zero dispatch after late CAS drift; this is refusal evidence, not successful operation coverage.',
    );
  }
  if (c.variant.contains('drift')) {
    return (
      Mr7ClosureCause.releasePolicy,
      'casDriftProbePending',
      'CAS drift must refuse before dispatch; this inventory row has no complete dedicated production-path probe in this subset.',
    );
  }
  if (c.variant.contains('provenance')) {
    return (
      Mr7ClosureCause.releasePolicy,
      'provenanceProbePending',
      'The exact field/source/nonce provenance refusal has no complete dedicated production-path probe in this subset.',
    );
  }
  if (c.operation == 'deleteBranch' &&
      ['default-ref', 'protected-ref'].contains(c.variant)) {
    return (
      Mr7ClosureCause.releasePolicy,
      'protectedDefaultDeleteRefused',
      'Production refuses default/protected branch deletion; separate negative tests prove zero writes, not deletion success.',
    );
  }
  if (c.variant.contains('refused') ||
      c.variant == 'unsafe-last-draft' ||
      c.variant == 'ambiguous-404') {
    return (
      Mr7ClosureCause.releasePolicy,
      'refusalOrIncompleteEvidence',
      'Refusal or ambiguous evidence cannot establish successful operation coverage; zero-write/fail-stop probes are separate evidence.',
    );
  }
  if (c.operation == 'playPipelineSchedule') {
    if (['stored-variables', 'stored-inputs'].contains(c.variant)) {
      return (
        Mr7ClosureCause.scopeExcluded,
        'scheduleParametersExcluded',
        '7-D8 excludes schedule variables; stored-parameter reuse remains the unproved section 22.3 live gap.',
      );
    }
    if (c.variant == 'schedule-unavailable') {
      return (
        Mr7ClosureCause.fixtureUnavailable,
        'scheduleFixtureUnavailable',
        'No run-created owned synthetic schedule fixture is demonstrated.',
      );
    }
    if (c.variant == 'unreadable-parameters') {
      return (
        Mr7ClosureCause.releasePolicy,
        'scheduleParametersUnreadable',
        'Unreadable schedule parameters cannot establish safe echo-only execution or close section 22.3.',
      );
    }
    return (
      Mr7ClosureCause.observerUnavailable,
      'schedulePipelineUnbound',
      'No sealed schedule-to-new-pipeline correlation; retained parameters remain 22.3 NOT_RUN.',
    );
  }
  if (c.operation == 'createPipeline' && c.variant == 'echo-only') {
    return (
      Mr7ClosureCause.fixtureUnavailable,
      'echoPipelineFixtureUnbound',
      'The new pipeline is not bound to independently observed echo-only configuration and its complete job set.',
    );
  }
  if (['edit_file', 'createFile'].contains(c.operation)) {
    return (
      Mr7ClosureCause.releasePolicy,
      'fileHeadReadNotSupported',
      'The guarded writer classifies production file HEAD reads as mutations; no HEAD/read dispatch seam is wired.',
    );
  }
  if (c.operation.contains('Snippet') && c.variant != 'new-nonprivate') {
    return (
      Mr7ClosureCause.releasePolicy,
      'fragmentCheckerNotWired',
      'The runner coordinator does not wire the production fragment checker required by snippet paths, metadata and file text.',
    );
  }
  if (c.operation == 'deleteFile' ||
      c.operation == 'applySuggestion' ||
      c.operation == 'deleteBoardList') {
    return (
      Mr7ClosureCause.observerUnavailable,
      'secondaryEffectObserverMissing',
      'Need a sealed repository-tree absence/suggestion effect/board-list observer bound to the actual dispatch.',
    );
  }
  if (c.operation == 'publishDraftNotes') {
    return (
      Mr7ClosureCause.observerUnavailable,
      'publishedNotesUnbound',
      'Draft absence alone does not prove corresponding published notes and exact text.',
    );
  }
  if (c.operation == 'cancelAutoMerge') {
    if (c.variant == '409-no-change') {
      return (
        Mr7ClosureCause.fixtureUnavailable,
        'noChangeFixtureUnproven',
        'S8 is available, but this subset has no honest concurrent-cancel fixture after the final snapshot fence; 409 alone leaves enabled state unverified.',
      );
    }
    return (
      Mr7ClosureCause.observerUnavailable,
      'legacyCancelObserverMissing',
      'Parent-state witness only binds one current-endpoint dispatch, not the legacy fallback.',
    );
  }
  if (c.operation == 'deleteProject') {
    return (
      Mr7ClosureCause.observerUnavailable,
      'terminalParentObserverMissing',
      'AI terminal deletion needs separate actor and namespace inventory evidence; finalizer is not evidence.',
    );
  }
  if (c.operation == 'createSnippet' && c.variant == 'new-nonprivate') {
    return (
      Mr7ClosureCause.observerUnavailable,
      'nonprivateContentObserverMissing',
      'S4 enforces private visibility; a new nonprivate snippet needs an explicitly bound content witness.',
    );
  }
  if ([
        'approval-unavailable',
        'protected-approval-escalation',
      ].contains(c.variant) ||
      c.variant == 'no-runner') {
    return (
      Mr7ClosureCause.fixtureUnavailable,
      'ownerOnlyFixtureUnavailable',
      'No owner-only feature/permission/runner fixture is demonstrated; other members remain excluded by 7-D8.',
    );
  }
  if (c.variant == 'late-reply') {
    return (
      Mr7ClosureCause.releasePolicy,
      'lateReplyIncompleteEvidence',
      'An accepted or late response does not prove bounded independent completion.',
    );
  }
  return (
    Mr7ClosureCause.releasePolicy,
    'scenarioChainNotImplemented',
    'Executable seams may exist, but this packet subset has no complete independently tested chain for this variant.',
  );
}

List<Mr7AdvancedCase> mr7AdvancedCases() =>
    _listedAdvancedCases().map(_upgrade).toList();
List<Mr7ClosedVariant> mr7AdvancedClosedVariants() => [
  for (final c in mr7AdvancedCases())
    if (c.scenario == null) c.closedVariant,
];

List<Mr7Scenario> mr7AdvancedScenarios() => [
  for (final c in mr7AdvancedCases())
    if (c.scenario != null) c.scenario!,
];

List<String> _filePaths(Map<String, Object?> row) =>
    [for (final file in row['files']! as List) (file as Map)['path']! as String]
      ..sort();

/// In-memory server routes only. Each write records its sandbox event and uses
/// the real guarded adapter; observations below never consult this fixture.
final class Mr7AdvancedFixture {
  Mr7AdvancedFixture(
    this.server, {
    this.variant = 'ordinary',
    this.operation = '',
  }) {
    _fixtures[server] = this;
    final p = server.projectId;
    mr = {
      'id': 33,
      'iid': 3,
      'project_id': p,
      'state': 'opened',
      'sha': mr7AdvancedHead,
      'source_project_id': p,
      'target_project_id': p,
      'source_branch': 'mr7-topic',
      'target_branch': 'mr7-target',
      'description': '',
      'changes_count': '1',
      'diff_refs': {
        'head_sha': mr7AdvancedHead,
        'base_sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'start_sha': 'cccccccccccccccccccccccccccccccccccccccc',
      },
      'auto_merge_enabled': operation == 'cancelAutoMerge',
      'merge_commit_sha': null,
      'squash_commit_sha': null,
      'author': {'id': 7},
      'user': {'can_merge': true},
      'approved_by': <Object?>[],
    };
    pipeline = {
      'id': 12,
      'project_id': p,
      'ref': 'mr7-topic',
      'status': operation == 'pipelineAction' && variant == 'retry'
          ? 'failed'
          : 'running',
    };
    job = {
      'id': 21,
      'project_id': p,
      'ref': 'mr7-topic',
      'status': operation == 'jobAction' && variant == 'play'
          ? 'manual'
          : operation == 'jobAction' && variant == 'retry'
          ? 'failed'
          : 'running',
      'name': 'synthetic-echo',
      'stage': 'test',
      'pipeline': {'id': 12, 'project_id': p},
    };
    snippet = {
      'id': 42,
      'project_id': p,
      'title': 'Synthetic snippet',
      'description': '',
      'visibility': 'private',
      'updated_at': '2026-10-29T00:00:00Z',
      'file_name': 'a.txt',
    };
    _syncFiles();
    final routes = server.routes;
    routes['GET projects/$p'] = (_) {
      if (server.project == null) return mr7Json({}, status: 404);
      configureProject();
      return mr7Json(server.project);
    };
    routes['GET projects/$p/merge_requests/3'] = (_) => mr7Json(mr);
    routes['GET projects/$p/repository/branches/mr7-target'] = (_) => mr7Json({
      'name': 'mr7-target',
      'protected': variant == 'protected-target',
      'default': variant == 'default-target',
      'commit': {'id': mr7AdvancedHead},
    });
    routes['GET projects/$p/repository/branches/mr7-topic'] = (_) => mr7Json({
      'name': 'mr7-topic',
      'protected': false,
      'default': false,
      'commit': {'id': mr7AdvancedHead},
    });
    routes['GET projects/$p/merge_requests/3/diffs'] = (_) => mr7Json([
      {
        'old_path': variant == 'ci-custom'
            ? 'ci/echo.yml'
            : variant == 'ci-default'
            ? '.gitlab-ci.yml'
            : 'synthetic.txt',
        'new_path': variant == 'ci-custom'
            ? 'ci/echo.yml'
            : variant == 'ci-default'
            ? '.gitlab-ci.yml'
            : 'synthetic.txt',
        'new_file': false,
        'deleted_file': false,
        'renamed_file': false,
        'diff': '@@ -1 +1 @@\n-before\n+synthetic\n',
      },
    ]);
    routes['GET projects/$p/merge_requests/3/commits'] = (_) => mr7Json([
      {'id': mr7AdvancedHead, 'message': 'Synthetic echo only'},
    ]);
    routes['GET projects/$p/merge_requests/3/closes_issues'] = (_) =>
        mr7Json([]);
    routes['GET projects/$p/merge_requests/3/draft_notes'] = (_) =>
        mr7Json(drafts);
    routes['POST projects/$p/merge_requests/3/draft_notes/bulk_publish'] = (r) {
      drafts.clear();
      return _changed(r, const {}, status: 204);
    };
    routes['PUT projects/$p/merge_requests/3/merge'] = (r) {
      final body = r.data! as Map;
      mr['state'] = body['auto_merge'] == true ? 'opened' : 'merged';
      mr['auto_merge_enabled'] = body['auto_merge'] == true;
      mr['merge_commit_sha'] = body['auto_merge'] == true
          ? null
          : mr7AdvancedMergeCommit;
      mr['squash_commit_sha'] =
          body['auto_merge'] != true && body['squash'] == true
          ? mr7AdvancedSquashCommit
          : null;
      return _changed(r, mr);
    };
    routes['POST projects/$p/merge_requests/3/approve'] = (r) {
      mr['approved_by'] = [
        {
          'user': {'id': 7},
        },
      ];
      return _changed(r, mr);
    };
    routes['GET projects/$p/merge_requests/3/approvals'] = (_) => mr7Json({
      'id': mr['id'],
      'iid': mr['iid'],
      'project_id': p,
      'approved': (mr['approved_by']! as List).isNotEmpty,
      'approved_by': mr['approved_by'],
    });
    routes['POST projects/$p/merge_requests/3/rebase'] = (r) {
      rebasePolls = variant == 'async-completion' ? 2 : 0;
      rebasing = true;
      return _changed(r, {'rebase_in_progress': true}, status: 202);
    };
    routes['GET projects/$p/merge_requests/3'] = (r) {
      if (rebasing && r.queryParameters['include_rebase_in_progress'] == true) {
        mr['rebase_in_progress'] = rebasePolls-- > 0;
        mr['merge_error'] = null;
        if (mr['rebase_in_progress'] == false) mr['sha'] = mr7AdvancedNextHead;
      }
      return mr7Json(mr);
    };
    routes['GET projects/$p/merge_requests/3/draft_notes/8'] = (_) =>
        drafts.isEmpty ? mr7Json({}, status: 404) : mr7Json(drafts.single);
    routes['DELETE projects/$p/merge_requests/3/draft_notes/8'] = (r) {
      drafts.clear();
      return _changed(r, const {}, status: 204);
    };
    routes['GET projects/$p/merge_requests/3/draft_notes'] = (_) =>
        _page(drafts);
    routes['POST projects/$p/merge_requests/3/cancel_auto_merge'] = (r) {
      if (variant == '409-no-change') {
        return _changed(r, const {}, status: 409, event: false);
      }
      mr['auto_merge_enabled'] = false;
      return _changed(r, mr);
    };
    routes['POST projects/$p/pipeline'] = (r) {
      pipeline = {...pipeline, 'id': 13, 'status': 'pending'};
      return _changed(r, pipeline, status: 201);
    };
    for (final id in [12, 13]) {
      routes['GET projects/$p/pipelines/$id'] = (_) =>
          pipelineDeleted ? mr7Json({}, status: 404) : mr7Json(pipeline);
    }
    routes['GET projects/$p/pipelines'] = (_) =>
        _page(pipelineDeleted ? [] : [pipeline]);
    routes['DELETE projects/$p/pipelines/12'] = (r) {
      pipelineDeleted = true;
      return _changed(r, const {}, status: 204);
    };
    for (final action in ['cancel', 'retry']) {
      routes['POST projects/$p/pipelines/12/$action'] = (r) {
        if (action == 'retry' &&
            !{'failed', 'canceled'}.contains(pipeline['status'])) {
          return mr7Json({}, status: 409);
        }
        pipeline['status'] = action == 'cancel' ? 'canceled' : 'pending';
        return _changed(r, pipeline);
      };
    }
    for (final id in [21, 22]) {
      routes['GET projects/$p/jobs/$id'] = (_) => mr7Json(job);
    }
    for (final action in ['cancel', 'retry', 'play']) {
      routes['POST projects/$p/jobs/21/$action'] = (r) {
        if ((action == 'play' && job['status'] != 'manual') ||
            (action == 'retry' &&
                !{'failed', 'canceled'}.contains(job['status']))) {
          return mr7Json({}, status: 409);
        }
        job['id'] = action == 'retry' ? 22 : 21;
        job['status'] = action == 'cancel' ? 'canceled' : 'pending';
        return _changed(r, job);
      };
    }
    routes['GET projects/$p/snippets/42'] = (_) {
      _syncFiles();
      return mr7Json(snippet);
    };
    for (final path in ['a.txt', 'b.txt']) {
      routes['GET projects/$p/snippets/42/files/main/$path/raw'] = (_) =>
          ResponseBody.fromString('Synthetic file ${path[0]}\n', 200);
    }
    routes['GET projects/$p/snippets'] = (_) =>
        _page(snippetDeleted ? [] : [snippet]);
    routes['DELETE projects/$p/snippets/42'] = (r) {
      snippetDeleted = true;
      return _changed(r, const {}, status: 204);
    };
    routes['PUT projects/$p/snippets/42'] = (r) {
      final body = r.data! as Map;
      for (final key in ['title', 'description', 'visibility']) {
        if (body.containsKey(key)) snippet[key] = body[key];
      }
      for (final action in body['files'] as List? ?? const []) {
        if (action is Map && action['action'] == 'delete') {
          files.remove(action['file_path']);
        }
      }
      snippet['updated_at'] = server.serverTime.toIso8601String();
      _syncFiles();
      return _changed(r, snippet);
    };
    routes['PUT projects/$p'] = (r) {
      final body = r.data! as Map;
      server.project!.addAll({
        'name': body['name'],
        'description': body['description'],
      });
      return _changed(r, server.project!);
    };
    _repositoryRoutes();
  }

  final Mr7SyntheticGitLab server;
  final String variant;
  final String operation;
  bool _used = false;
  bool _projectConfigured = false;
  static final _fixtures = Expando<Mr7AdvancedFixture>();
  static Mr7AdvancedFixture? attached(Mr7SyntheticGitLab server) =>
      _fixtures[server];
  late Map<String, Object?> mr;
  late Map<String, Object?> pipeline;
  late Map<String, Object?> job;
  late Map<String, Object?> snippet;
  final files = <String>{'a.txt', 'b.txt'};
  final drafts = <Map<String, Object?>>[
    {
      'id': 8,
      'note': 'Synthetic review text',
      'author': {'id': 7, 'username': 'synthetic-owner'},
    },
  ];
  final mutations = <RequestOptions>[];
  bool loseReply = false;
  bool pipelineDeleted = false;
  bool snippetDeleted = false;
  bool rebasing = false;
  int rebasePolls = 0;
  bool branchDeleted = false;
  bool tagDeleted = false;
  bool releaseDeleted = false;
  bool releaseExists = true;
  Map<String, Object?>? newRef;
  late Map<String, Object?> release;

  void configureProject() {
    if (_projectConfigured) return;
    _projectConfigured = true;
    // Absence is deliberately unreadable in production and raises every path
    // to hardLine. This fixture explicitly uses GitLab's default local config.
    server.project!['ci_config_path'] = variant == 'ci-custom'
        ? 'ci/echo.yml'
        : '';
    server.project!['default_branch'] = variant == 'default-target'
        ? 'mr7-target'
        : variant == 'default-ref'
        ? 'mr7-topic'
        : 'main';
  }

  ResponseBody _page(List<Object?> values) => mr7Json(
    values,
    headers: {
      'x-page': ['1'],
      'x-per-page': ['100'],
      'x-total': ['${values.length}'],
      'x-total-pages': ['1'],
      'x-next-page': [''],
    },
  );

  void _repositoryRoutes() {
    final p = server.projectId;
    final routes = server.routes;
    Map<String, Object?> branch(String name) => {
      'name': name,
      'protected':
          (name == 'mr7-target' && variant == 'protected-target') ||
          (name == 'mr7-topic' && variant == 'protected-ref'),
      'default':
          (name == 'mr7-target' && variant == 'default-target') ||
          (name == 'mr7-topic' && variant == 'default-ref'),
      'commit': {'id': mr7AdvancedHead},
    };
    routes['GET projects/$p/repository/branches/mr7-topic'] = (_) =>
        mr7Json(branch('mr7-topic'));
    routes['GET projects/$p/repository/commits/mr7-topic'] = (_) =>
        mr7Json({'id': mr7AdvancedHead});
    for (final collection in ['branches', 'tags']) {
      routes['POST projects/$p/repository/$collection'] = (r) {
        final body = r.data! as Map;
        newRef = {
          'name': body[collection == 'branches' ? 'branch' : 'tag_name'],
          'commit': {'id': body['ref']},
          'protected': false,
          'default': false,
        };
        return _changed(r, newRef!, status: 201);
      };
      routes['GET projects/$p/repository/$collection/mr7-new'] = (_) =>
          mr7Json(newRef);
    }
    final tag = {
      'name': 'mr7-tag',
      'commit': {'id': mr7AdvancedHead},
    };
    routes['GET projects/$p/repository/tags/mr7-tag'] = (_) => mr7Json(tag);
    routes['GET projects/$p/repository/branches'] = (_) =>
        _page([if (!branchDeleted) branch('mr7-topic'), branch('mr7-target')]);
    routes['GET projects/$p/repository/tags'] = (_) =>
        _page([if (!tagDeleted) tag]);
    routes['DELETE projects/$p/repository/branches/mr7-topic'] = (r) {
      branchDeleted = true;
      return _changed(r, const {}, status: 204);
    };
    routes['DELETE projects/$p/repository/tags/mr7-tag'] = (r) {
      tagDeleted = true;
      return _changed(r, const {}, status: 204);
    };
    release = {
      'tag_name': 'mr7-tag',
      'name': 'Synthetic release',
      'description': 'Original synthetic release',
      'commit': {'id': mr7AdvancedHead},
    };
    releaseExists = operation != 'createRelease';
    routes['GET projects/$p/releases/mr7-tag'] = (_) =>
        releaseExists && !releaseDeleted
        ? mr7Json(release)
        : mr7Json({}, status: 404);
    routes['GET projects/$p/releases'] = (_) =>
        _page([if (releaseExists && !releaseDeleted) release]);
    for (final method in ['POST', 'PUT']) {
      routes['$method projects/$p/releases${method == 'POST' ? '' : '/mr7-tag'}'] =
          (r) {
            if ((method == 'POST' && releaseExists) ||
                (method == 'PUT' && !releaseExists)) {
              return mr7Json({}, status: 409);
            }
            releaseExists = true;
            release.addAll(Map<String, Object?>.from(r.data! as Map));
            return _changed(r, release, status: method == 'POST' ? 201 : 200);
          };
    }
    routes['DELETE projects/$p/releases/mr7-tag'] = (r) {
      releaseDeleted = true;
      return _changed(r, const {}, status: 204);
    };
  }

  void _syncFiles() {
    snippet['files'] = [
      for (final path in files)
        {
          'path': path,
          'raw_url':
              'https://gitlab.invalid/install/${server.project?['path_with_namespace']}/'
              '-/snippets/42/raw/main/$path',
        },
    ];
  }

  ResponseBody _changed(
    RequestOptions request,
    Map<String, Object?> value, {
    int status = 200,
    bool event = true,
  }) {
    mutations.add(request);
    server.scenarioWrites++;
    if (event) server.addEvent(target: server.projectId);
    if (loseReply) throw const Mr7Refused('replyLostAfterSend');
    return mr7Json(value, status: status);
  }
}
