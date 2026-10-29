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
const _isolation =
    'Complete two-pass owner events window includes setup, scenario and cleanup; '
    'every event and mutation belongs to the fresh sandbox; unreadable, missing '
    'or foreign events quarantine the session. Events alone are not an audit log.';
const _cleanup =
    'One finalizer deletes only this run project after ID/path/owner revalidation '
    'and complete parent inventory; uncertain or unverified writes retain it. '
    'No reset, unlock, retry, personal snippet or account-global cleanup.';
const _nameSeam =
    'NOT_RUN/closed: 7B0 observer requires numeric returned ID and numeric path; '
    'needs a project-bound name/path/SHA observer, without invented IDs.';
const _absenceSeam =
    'NOT_RUN/closed: 7B0 observer cannot verify empty acknowledgements, complete '
    'parent lists or absence; 404 alone is ambiguous. Keep core ack semantics.';
const _contentSeam =
    'NOT_RUN/closed: 7B0 observer cannot independently read raw snippet bytes '
    'at the pinned file revision; metadata alone does not prove content.';
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
    this.blockedScenario,
    this.closedReason,
  });

  final String operation;
  final String variant;
  final String tier;
  final String preread;
  final String write;
  final String readback;
  final Mr7Scenario? scenario;
  final Mr7Scenario? blockedScenario;
  final String? closedReason;
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
    call: (_) => throw const Mr7Refused('advancedVariantClosed'),
    paths: (_) => const {},
    observe: (_, _) async => false,
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
}) {
  final id = 'b3-$operation-$variant';
  final owningKind = aiWriteProposalTargetKind(
    productionAiLedger.find(operation)!,
  );
  final needsTargetSet = owningKind != targetKind;
  final definition = Mr7Scenario(
    id: id,
    suite: 'advanced',
    operation: operation,
    variant: variant,
    tier: tier,
    targetKind: targetKind,
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
    readbackPaths: (p, _) => {
      observation.replaceAll('{project}', '${p.projectId}'),
    },
    observe: (observer, p) async {
      final row = await observer.read(
        observation.replaceAll('{project}', '${p.projectId}'),
      );
      return check(row) && (identityCheck?.call(row, p) ?? true);
    },
  );
  return Mr7AdvancedCase(
    operation: operation,
    variant: variant,
    tier: tier,
    preread: preread,
    write: write,
    readback: readback,
    scenario: needsTargetSet ? null : definition,
    blockedScenario: needsTargetSet ? definition : null,
    closedReason: needsTargetSet
        ? 'NOT_RUN/closed: isolated 7B0 scenario permits only $targetKind; '
              'production needs owning $owningKind and bound $targetKind. Request '
              'an explicit per-scenario target-kind set; do not add dummy cases '
              'to widen candidate policy. This case refuses before API preparation.'
        : null,
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
List<Mr7AdvancedCase> mr7AdvancedCases() => [
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
          'Independent returned MR ID/iid/project, SHA and merged state or '
          'auto-merge scheduled flag; scheduling is not completed merge.',
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
              : r['state'] == 'merged'),
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
  _runnable(
    'approveMergeRequest',
    'sha-bound',
    'T4',
    preread:
        'GET same-project opened MR and exact head SHA; instance must allow '
        'owner approval without adding members.',
    write: 'approveMergeRequest with pinned SHA, typed !3.',
    readback:
        'Independent returned MR identity and approved_by owner numeric ID.',
    targetKind: AiTargetKind.mergeRequest,
    arguments: {'iid': 3},
    mutation: 'POST projects/{project}/merge_requests/3/approve',
    observation: 'projects/{project}/merge_requests/3',
    check: (r) =>
        r['sha'] == mr7AdvancedHead &&
        (r['approved_by'] as List).any(
          (a) => a is Map && a['user'] is Map && (a['user'] as Map)['id'] == 7,
        ),
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
  _runnable(
    'cancelAutoMerge',
    'current-endpoint',
    'T3',
    preread: 'GET opened same-project MR, auto-merge enabled and can_merge.',
    write: 'POST cancel_auto_merge with empty body, once.',
    readback: 'Independent exact MR, readable auto-merge flag now false.',
    targetKind: AiTargetKind.mergeRequest,
    arguments: {'iid': 3},
    mutation: 'POST projects/{project}/merge_requests/3/cancel_auto_merge',
    observation: 'projects/{project}/merge_requests/3',
    check: (r) => r['auto_merge_enabled'] == false && r['state'] == 'opened',
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
          r['description'] == 'Synthetic metadata' &&
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
  for (final variant in ['name', 'description'])
    _runnable(
      'editProject',
      variant,
      'hardLine',
      preread:
          'GET sandbox ID/path/owner/private status and both current name/'
          'description; omitted-field CAS must stay bound.',
      write:
          'editProject PUT resends only name/description; typed full project path.',
      readback: 'Independent exact sandbox identity and both final fields.',
      targetKind: AiTargetKind.project,
      arguments: {
        if (variant == 'name')
          'name': 'Synthetic renamed display'
        else
          'description': 'Synthetic project description',
      },
      mutation: 'PUT projects/{project}',
      observation: 'projects/{project}',
      check: (r) => variant == 'name'
          ? r['name'] == 'Synthetic renamed display' &&
                (r['description'] ?? '') == ''
          : r['description'] == 'Synthetic project description',
      identityCheck: (r, p) =>
          variant != 'description' || r['name'] == 'mr7-${p.nonce}',
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
  Mr7AdvancedFixture(this.server, {this.variant = 'ordinary'}) {
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
      'auto_merge_enabled': true,
      'author': {'id': 7},
      'user': {'can_merge': true},
      'approved_by': <Object?>[],
    };
    pipeline = {
      'id': 12,
      'project_id': p,
      'ref': 'mr7-topic',
      'status': 'running',
    };
    job = {
      'id': 21,
      'project_id': p,
      'ref': 'mr7-topic',
      'status': 'running',
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
    routes['POST projects/$p/merge_requests/3/cancel_auto_merge'] = (r) {
      mr['auto_merge_enabled'] = false;
      return _changed(r, mr);
    };
    routes['POST projects/$p/pipeline'] = (r) {
      pipeline = {...pipeline, 'id': 13, 'status': 'pending'};
      return _changed(r, pipeline, status: 201);
    };
    for (final id in [12, 13]) {
      routes['GET projects/$p/pipelines/$id'] = (_) => mr7Json(pipeline);
    }
    for (final action in ['cancel', 'retry']) {
      routes['POST projects/$p/pipelines/12/$action'] = (r) {
        pipeline['status'] = action == 'cancel' ? 'canceled' : 'pending';
        return _changed(r, pipeline);
      };
    }
    for (final id in [21, 22]) {
      routes['GET projects/$p/jobs/$id'] = (_) => mr7Json(job);
    }
    for (final action in ['cancel', 'retry', 'play']) {
      routes['POST projects/$p/jobs/21/$action'] = (r) {
        job['id'] = action == 'retry' ? 22 : 21;
        job['status'] = action == 'cancel' ? 'canceled' : 'pending';
        return _changed(r, job);
      };
    }
    routes['GET projects/$p/snippets/42'] = (_) {
      _syncFiles();
      return mr7Json(snippet);
    };
    routes['GET projects/$p/snippets/42/files/main/a.txt/raw'] = (_) =>
        ResponseBody.fromString('Synthetic file a\n', 200);
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
  }

  final Mr7SyntheticGitLab server;
  final String variant;
  late Map<String, Object?> mr;
  late Map<String, Object?> pipeline;
  late Map<String, Object?> job;
  late Map<String, Object?> snippet;
  final files = <String>{'a.txt', 'b.txt'};
  final drafts = <Map<String, Object?>>[
    {'id': 8, 'note': 'Synthetic review text'},
  ];
  final mutations = <RequestOptions>[];
  bool loseReply = false;

  void configureProject() {
    if (variant == 'default-target') {
      server.project!['default_branch'] = 'mr7-target';
    }
    if (variant == 'ci-custom') {
      server.project!['ci_config_path'] = 'ci/echo.yml';
    }
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
  }) {
    mutations.add(request);
    server.scenarioWrites++;
    server.addEvent(target: server.projectId);
    if (loseReply) throw const Mr7Refused('replyLostAfterSend');
    return mr7Json(value, status: status);
  }
}
