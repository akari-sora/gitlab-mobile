// 7B1 definitions and synthetic server fixtures only. No live adapter or gate.
import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';

import '../mr7_sandbox.dart' show Mr7Scenario;
import 'sandbox_contract.dart';

const mr7RestPlanRows = [8, 9, 14, 19, 20, 23, 32];

/// Subrows that a one-call, foreground synthetic scenario cannot close.
const mr7RestEvidenceGaps = <int, String>{
  8:
      'Actual product tier/decision/fixed reasons need a receipt projection; '
      'scenario.tier is declared metadata. Host confirmation is not app UI.',
  9:
      'Confirmation edits need an editedText approval hook. REST updated_at '
      'preflight is not atomic server CAS; snippet/delete cases belong to 7B3.',
  14:
      'Synthetic text policy is exercised; internal-note creation has no ledger '
      'argument. Device confirmation and all 24 locales remain NOT_RUN.',
  19:
      '7B0 creates a fresh budget/run per scenario and an ephemeral journal per invocation. '
      '39/40/41 production reservations, account-hour limits and restart need '
      'a bounded shared-budget/journal injection seam; live quota is NOT_RUN.',
  20:
      'Draft create/update do not publish. Whole-batch scan, external sandbox '
      'drafts and max20 publication are 7B3 publishDraftNotes cases, NOT_RUN here.',
  23:
      'Attachment session injection, multipart and binary observation are '
      'unavailable; real picker, process cleanup and provider delivery NOT_RUN.',
  32:
      'Shared placeholder/provenance state and scripted multi-call turns are '
      'unavailable: same-field, crossnonce, restored history and hiddenSpan '
      'roundtrips remain NOT_RUN; no reconstructed upload is claimed.',
};

/// A closed variant is deliberately not an executable fake success case.
final class Mr7RestCase {
  const Mr7RestCase({
    required this.operation,
    required this.variant,
    required this.tier,
    this.scenario,
    this.closedReason,
    this.initialFields = const {},
    this.fixture = 'Only run-owned synthetic private-project resources.',
  }) : assert((scenario == null) != (closedReason == null));

  final String operation;
  final String variant;
  final String tier;
  final Mr7Scenario? scenario;
  final String? closedReason;
  final String fixture;
  final Map<String, Object?> initialFields;
  String get id => 'b1-$operation-$variant';
  String get live => 'NOT_RUN';
  String get confirmation => tier == 'hardLine'
      ? 'Product approval plus exact typed pre-read target, including bypass; '
            'additional explicit sandbox confirmation.'
      : 'Production autonomy matrix (T1/T2); confirmEach requires product '
            'approval; every send also requires explicit sandbox confirmation.';
  String get chain =>
      'GET /user and project by ID/path; fresh API resource '
      'version/fields; production AiRunner -> coordinator proposal/confirmation '
      '-> named GitLabAiWritePort write once -> separate uncached observer '
      'GET of exact returned identity and expected fields.';
  String get events =>
      'Complete baseline before setup, per-case checks, delayed '
      'second pass and final window through cleanup; every event is sandbox '
      'bound. Foreign/missing project or incomplete events stop the session.';
  String get cleanup =>
      '7B0 finalizer deletes only this run-created project '
      'after identity/parent-inventory readback; uncertain/pending writes or '
      'identity/event failures retain quarantine. No per-case broad deletion.';
  String get closure =>
      closedReason ??
      'Synthetic PASS never releases a tool. Live NOT_RUN without owner '
          'credentials/provider configuration; absent feature/403 or unavailable '
          'sandbox fixture closes the entire operation; uncertain send/readback '
          'stops later cases, retains quarantine and forbids retry.';
}

const _discussionSeam =
    '7B0 REST observer requires numeric returned IDs; '
    'discussion IDs are strings. Need a sealed discussion/membership observer, '
    'not an invented numeric ID or acknowledgement readback.';
const _milestoneSeam =
    'Milestone GET uses global id, but 7B0 chooses returned '
    'iid for the path whenever present. Need typed resource ID routing; '
    'fixtures must not make id == iid to conceal the mismatch.';
const _todoSeam =
    '7B0 refuses account /todos reads/writes and has no bounded '
    'todo-list observer. Project/group/accountGlobal final-target negatives '
    'must all pass under 7-D4/D5; project-only evidence cannot open this row.';
const _uploadSeam =
    '7B0 supplies no AiAttachmentSession or shared placeholder '
    'state; upload response has no numeric id and observer cannot read bytes. '
    'Need memory-only attachment injection and a sealed upload observer.';
const _editedTextSeam =
    'Host approve exposes typedName only, no editedText '
    'hook. Need exact edited payload/digest re-confirmation through the '
    'product coordinator.';

/// Mirrors every rows_t12 production operation, including explicit closures.
/// A composed entrypoint installs fixtures, then passes [mr7RestScenarios] to
/// runMr7Sandbox. It must supply one session with a bounded sufficient budget;
/// the 7B0 CLI still registers only its own contract fixture.
List<Mr7RestCase> mr7RestCases() {
  final cases = <Mr7RestCase>[];
  void add(
    String operation,
    String variant,
    Map<String, Object?> arguments,
    String mutation,
    String read,
    Map<String, Object?> expected, {
    String? opening,
    String? resource,
    String tier = 'T2',
    bool polluted = false,
    bool unknownVisibility = false,
    Map<String, Object?> initialFields = const {},
    String fixture = 'Run-owned synthetic fixture; no external users or refs.',
  }) {
    final id = 'b1-$operation-$variant';
    final row = productionAiLedger.find(operation)!;
    String bind(String path, Mr7Identity p) =>
        path.replaceAll('{p}', '${p.projectId}');
    final scenario = Mr7Scenario(
      id: id,
      suite: 'rest',
      operation: operation,
      variant: variant,
      tier: tier,
      targetKind: aiWriteProposalTargetKind(
        row,
        mergeRequest: resource == 'merge_requests',
      ),
      utterance: (p) =>
          'Perform $operation on synthetic project ${p.path}'
          '${resource == 'merge_requests'
              ? ' !1'
              : resource == 'issues'
              ? ' #1'
              : ''}.',
      resource: (_) => AiResourceRef(
        kind: resource == 'merge_requests'
            ? AiResourceKind.mergeRequest
            : AiResourceKind.issue,
        id: 1,
      ),
      call: (p) => AiToolCall(
        id: id,
        name: operation,
        arguments: {
          'projectId': p.projectId,
          ...arguments,
          'reason': 'Explicit synthetic sandbox request.',
        },
      ),
      paths: (p) => {bind(mutation, p)},
      freshness: (session, request) async {
        final p = session.identity!;
        final project = await session.read('projects/${p.projectId}');
        final current = opening == null
            ? project
            : await session.read(bind(opening, p));
        if (!_matches(current, initialFields)) {
          throw const Mr7Refused('fixturePrecondition');
        }
        final fields = request.arguments['fields'];
        return AiWriteFreshness(
          updatedAt: current['updated_at'] as String?,
          headSha: (current['diff_refs'] as Map?)?['head_sha'] as String?,
          visibilityUnreadable: unknownVisibility,
          sourceVisibilityUnreadable: unknownVisibility,
          targetVisibility: project['visibility'] as String?,
          polluted: polluted,
          facts: AiTierFacts(
            confidentialLowered:
                current['confidential'] == true &&
                fields is Map &&
                fields['confidential'] == false,
          ),
          currentFields: {
            for (final field in ['body', 'description', 'title', 'note'])
              if (current[field] is String) field: current[field]! as String,
          },
        );
      },
      readbackPaths: (p, result) => {
        bind(read, p)
            .replaceAll('{id}', '${result.returnedId}')
            .replaceAll('{iid}', '${result.returnedIid}'),
      },
      observe: (observer, p) async {
        final value = await observer.read(observer.paths.single);
        return _matches(value, expected) &&
            (!value.containsKey('project_id') ||
                value['project_id'] == p.projectId);
      },
    );
    cases.add(
      Mr7RestCase(
        operation: operation,
        variant: variant,
        tier: tier,
        scenario: scenario,
        fixture: fixture,
        initialFields: initialFields,
      ),
    );
  }

  void closed(String operation, Iterable<String> variants, String reason) {
    for (final variant in variants) {
      cases.add(
        Mr7RestCase(
          operation: operation,
          variant: variant,
          tier: productionAiLedger.find(operation)!.baseTier == AiWriteTier.t1
              ? 'T1'
              : 'T2',
          closedReason: reason,
        ),
      );
    }
  }

  for (final starred in [true, false]) {
    add(
      'setStar',
      starred ? 'star' : 'unstar',
      {'starred': starred},
      'POST projects/{p}/${starred ? 'star' : 'unstar'}',
      'projects/{p}',
      {'starred': starred},
      tier: 'T1',
      initialFields: {'starred': !starred},
    );
  }
  closed(
    'setStar',
    ['already-matching-304'],
    '304 contains no returned id. Need an explicit no-change observer seam; '
        '7B0 currently quarantines 3xx and cannot certify this variant.',
  );

  for (final resource in ['issues', 'merge_requests']) {
    final side = resource == 'issues' ? 'issue' : 'mr';
    final noteId = resource == 'issues' ? 301 : 302;
    final parent = 'projects/{p}/$resource/1';
    for (final note in [false, true]) {
      final awardPath = '$parent/${note ? 'notes/$noteId/' : ''}award_emoji';
      final variant = '$side${note ? '-note' : ''}';
      add(
        'addAwardEmoji',
        variant,
        {
          'resource': resource,
          'iid': 1,
          'name': 'thumbsup',
          if (note) 'noteId': noteId,
        },
        'POST $awardPath',
        '$awardPath/{id}',
        {
          'name': 'thumbsup',
          'user': {'id': 7},
        },
        opening: parent,
        resource: resource,
        tier: 'T1',
      );
      closed(
        'removeAwardEmoji',
        [variant],
        'DELETE returns 204 with no id. Need complete bounded award-list '
            'absence plus actor/parent verification; a 404 alone is insufficient.',
      );
    }
    for (final subscribed in [true, false]) {
      add(
        'setSubscribed',
        '$side-${subscribed ? 'on' : 'off'}',
        {'resource': resource, 'iid': 1, 'subscribed': subscribed},
        'POST $parent/${subscribed ? 'subscribe' : 'unsubscribe'}',
        parent,
        {'subscribed': subscribed},
        opening: parent,
        resource: resource,
        tier: 'T1',
        initialFields: {'subscribed': !subscribed},
      );
    }
    closed(
      'setSubscribed',
      ['$side-already-matching-304'],
      '304 has no response id; 7B0 marks 3xx uncertain. Need no-change '
          'classification and a separately bound parent-state observer.',
    );
    add(
      'createNote',
      side,
      {'resource': resource, 'iid': 1, 'body': 'Synthetic note.'},
      'POST $parent/notes',
      '$parent/notes/{id}',
      {
        'body': 'Synthetic note.',
        'author': {'id': 7},
      },
      opening: parent,
      resource: resource,
    );
    add(
      'updateNote',
      side,
      {
        'resource': resource,
        'iid': 1,
        'noteId': noteId,
        'body': 'Synthetic edited note.',
      },
      'PUT $parent/notes/$noteId',
      '$parent/notes/$noteId',
      {
        'body': 'Synthetic edited note.',
        'author': {'id': 7},
      },
      opening: '$parent/notes/$noteId',
      resource: resource,
    );
    closed(
      'createTodo',
      [side],
      'Response is an account todo; there is no project GET by todo id. '
          'Need a target-bound complete todo observer without widening scope.',
    );
    closed('createDiscussion', [
      '$side-unpositioned',
      if (resource == 'merge_requests') '$side-positioned',
    ], _discussionSeam);
    for (final operation in ['createDiscussionNote', 'updateDiscussionNote']) {
      closed(operation, [side], _discussionSeam);
    }
  }
  closed('markTodoDone', [
    'project-issue',
    'project-mr',
    'foreign-project',
    'group-target',
    'accountGlobal-target',
  ], _todoSeam);
  closed(
    'unapproveMergeRequest',
    ['approved', 'already-unapproved'],
    'Independent approved_by requires GET .../approvals; 7B0 demands a '
        'numeric terminal path segment. Need a sealed approval-state observer.',
  );
  closed('setDiscussionResolved', ['resolve', 'unresolve'], _discussionSeam);

  for (final operation in [
    'createIssue',
    'updateIssue',
    'createMergeRequest',
    'updateMergeRequest',
  ]) {
    final issue = operation.endsWith('Issue');
    final create = operation.startsWith('create');
    final resource = issue ? 'issues' : 'merge_requests';
    final fields = <String, Object?>{
      'title': 'Synthetic title.',
      'description': 'Synthetic description.',
      'labels': 'synthetic',
      'assignee_ids': [7],
      'milestone_id': 501,
      if (!issue) 'reviewer_ids': [7],
      if (create && !issue) ...{
        'source_branch': 'synthetic',
        'target_branch': 'main',
      },
    };
    add(
      operation,
      'private',
      {'fields': fields, if (!create) 'iid': 1},
      '${create ? 'POST' : 'PUT'} projects/{p}/$resource${create ? '' : '/1'}',
      'projects/{p}/$resource/${create ? '{iid}' : '1'}',
      {
        'title': 'Synthetic title.',
        'description': 'Synthetic description.',
        'labels': ['synthetic'],
        'assignees': [
          {'id': 7},
        ],
        'milestone': {'id': 501},
        if (create && !issue) ...{
          'source_branch': 'synthetic',
          'target_branch': 'main',
        },
        if (!issue)
          'reviewers': [
            {'id': 7},
          ],
      },
      opening: create ? null : 'projects/{p}/$resource/1',
      resource: create ? null : resource,
      fixture:
          'Own issue/MR, owner user 7, synthetic label/milestone; MR '
          'branches in this sandbox only; no forks or external CI.',
    );
    closed(operation, ['confirmation-edited-text'], _editedTextSeam);
    if (!create) {
      for (final event in ['close', 'reopen']) {
        add(
          operation,
          event,
          {
            'iid': 1,
            'fields': {'state_event': event},
          },
          'PUT projects/{p}/$resource/1',
          'projects/{p}/$resource/1',
          {'state': event == 'close' ? 'closed' : 'opened'},
          initialFields: {'state': event == 'close' ? 'opened' : 'closed'},
          opening: 'projects/{p}/$resource/1',
          resource: resource,
        );
      }
    }
  }
  add(
    'createIssue',
    'confidential',
    {
      'fields': {
        'title': 'Synthetic confidential issue.',
        'confidential': true,
      },
    },
    'POST projects/{p}/issues',
    'projects/{p}/issues/{iid}',
    {'title': 'Synthetic confidential issue.', 'confidential': true},
  );
  add(
    'updateIssue',
    'confidential-lowered',
    {
      'iid': 1,
      'fields': {'confidential': false},
    },
    'PUT projects/{p}/issues/1',
    'projects/{p}/issues/1',
    {'confidential': false},
    opening: 'projects/{p}/issues/1',
    resource: 'issues',
    tier: 'hardLine',
    fixture: 'Seed issue is confidential; fresh API evidence raises hardLine.',
  );

  for (final variant in [
    'quick-action',
    'mention',
    'polluted',
    'unknown-visibility',
  ]) {
    final body = switch (variant) {
      'quick-action' => 'Synthetic note.\n/close',
      'mention' => 'Synthetic @synthetic-user.',
      _ => 'Synthetic note.',
    };
    final expected = switch (variant) {
      'quick-action' => 'Synthetic note.\n /close',
      'mention' => 'Synthetic `@synthetic-user`.',
      _ => body,
    };
    add(
      'createNote',
      variant,
      {'resource': 'issues', 'iid': 1, 'body': body},
      'POST projects/{p}/issues/1/notes',
      'projects/{p}/issues/1/notes/{id}',
      {'body': expected},
      opening: 'projects/{p}/issues/1',
      resource: 'issues',
      polluted: variant == 'polluted',
      unknownVisibility: variant == 'unknown-visibility',
    );
  }
  closed(
    'createNote',
    ['internal-note'],
    'Ledger has no internal argument; do not forge an unsupported capability.',
  );

  for (final create in [true, false]) {
    final operation = create ? 'createDraftNote' : 'updateDraftNote';
    for (final variant
        in create
            ? [
                'plain',
                'commit',
                'positioned',
                'external-sandbox-draft-present',
                'twenty-sandbox-drafts-present',
              ]
            : ['own', 'external-sandbox']) {
      add(
        operation,
        variant,
        {
          'iid': 1,
          'body': 'Synthetic draft.',
          if (!create) 'noteId': variant == 'external-sandbox' ? 402 : 401,
          if (variant == 'commit') 'commitId': _head,
          if (variant == 'positioned') 'position': _position,
        },
        '${create ? 'POST' : 'PUT'} projects/{p}/merge_requests/1/draft_notes'
            '${create
                ? ''
                : variant == 'external-sandbox'
                ? '/402'
                : '/401'}',
        'projects/{p}/merge_requests/1/draft_notes/${create
            ? '{id}'
            : variant == 'external-sandbox'
            ? '402'
            : '401'}',
        {
          'note': 'Synthetic draft.',
          if (variant == 'commit') 'commit_id': _head,
          if (variant == 'positioned') 'position': _position,
        },
        opening: create
            ? 'projects/{p}/merge_requests/1'
            : 'projects/{p}/merge_requests/1/draft_notes/${variant == 'external-sandbox' ? '402' : '401'}',
        resource: 'merge_requests',
        fixture:
            'Current-owner drafts only; id402 is another client draft '
            'in this same sandbox, not another user. Seed 20 untrusted '
            'synthetic drafts. No bulk publication/max20 claim.',
      );
    }
  }
  for (final create in [true, false]) {
    final operation = create ? 'createLabel' : 'updateLabel';
    add(
      operation,
      'name-color-description',
      {
        'fields': {
          'name': 'synthetic-new',
          'color': '#336699',
          'description': 'Synthetic label.',
        },
        if (!create) 'labelId': 701,
      },
      '${create ? 'POST' : 'PUT'} projects/{p}/labels${create ? '' : '/701'}',
      'projects/{p}/labels/${create ? '{id}' : '701'}',
      {
        'name': 'synthetic-new',
        'color': '#336699',
        'description': 'Synthetic label.',
      },
      opening: create ? null : 'projects/{p}/labels/701',
    );
  }
  add(
    'createLabel',
    'plain-slash',
    {
      'fields': {
        'name': 'synthetic-plain',
        'color': '#336699',
        'description': 'Synthetic plain content.\n/close',
      },
    },
    'POST projects/{p}/labels',
    'projects/{p}/labels/{id}',
    {
      'name': 'synthetic-plain',
      'color': '#336699',
      'description': 'Synthetic plain content.\n/close',
    },
  );
  closed('createMilestone', ['title-description-dates'], _milestoneSeam);
  closed('updateMilestone', ['title-description-dates'], _milestoneSeam);
  closed('setMilestoneState', ['close', 'activate'], _milestoneSeam);
  add(
    'createBoard',
    'name',
    {'name': 'Synthetic board.'},
    'POST projects/{p}/boards',
    'projects/{p}/boards/{id}',
    {'name': 'Synthetic board.'},
  );
  add(
    'renameBoard',
    'name',
    {'boardId': 801, 'name': 'Synthetic renamed board.'},
    'PUT projects/{p}/boards/801',
    'projects/{p}/boards/801',
    {'name': 'Synthetic renamed board.'},
    opening: 'projects/{p}/boards/801',
  );
  for (final list in ['backlog', 'closed']) {
    for (final hidden in [true, false]) {
      add(
        'setBoardSystemListHidden',
        '$list-${hidden ? 'hidden' : 'shown'}',
        {'boardId': 801, 'list': list, 'hidden': hidden},
        'PUT projects/{p}/boards/801',
        'projects/{p}/boards/801',
        {'hide_${list}_list': hidden},
        initialFields: {'hide_${list}_list': !hidden},
        opening: 'projects/{p}/boards/801',
      );
    }
  }
  add(
    'createBoardList',
    'label',
    {'boardId': 801, 'labelId': 701},
    'POST projects/{p}/boards/801/lists',
    'projects/{p}/boards/801/lists/{id}',
    {
      'label': {'id': 701},
    },
    opening: 'projects/{p}/boards/801',
  );
  for (final position in [0, 2]) {
    add(
      'moveBoardList',
      'position-$position',
      {'boardId': 801, 'listId': 901, 'position': position},
      'PUT projects/{p}/boards/801/lists/901',
      'projects/{p}/boards/801/lists/901',
      {'position': position},
      initialFields: {'position': position == 0 ? 1 : 0},
      opening: 'projects/{p}/boards/801/lists/901',
    );
  }
  for (final event in ['labels', 'close', 'reopen']) {
    add(
      'moveBoardCard',
      event,
      {
        'iid': 1,
        'fields': {
          if (event == 'labels') 'labels': 'synthetic-new',
          if (event != 'labels') 'state_event': event,
        },
      },
      'PUT projects/{p}/issues/1',
      'projects/{p}/issues/1',
      {
        if (event == 'labels') 'labels': ['synthetic-new'],
        if (event != 'labels') 'state': event == 'close' ? 'closed' : 'opened',
      },
      opening: 'projects/{p}/issues/1',
      resource: 'issues',
      initialFields: {
        if (event != 'labels') 'state': event == 'close' ? 'opened' : 'closed',
      },
    );
  }
  closed(
    'createBoardList',
    ['paid-list-feature-unavailable'],
    'Instance feature/permission must be observed live; unavailable means '
        'NOT_RUN and closes the entire tool. Do not fake a paid feature PASS.',
  );
  closed('upload_attachment', [
    'multipart-memory',
    'slow-timeout',
    'metadata-only-provider',
    'same-field-roundtrip',
    'crossnonce',
    'restored-history',
    'hiddenSpan',
    'picker-process-cleanup',
  ], _uploadSeam);
  for (final row in aiT12Rows.where((r) => r.editableField != null)) {
    if (!cases.any(
      (c) =>
          c.operation == row.operationId &&
          c.variant == 'confirmation-edited-text',
    )) {
      closed(row.operationId, ['confirmation-edited-text'], _editedTextSeam);
    }
  }
  return List.unmodifiable(cases);
}

List<Mr7Scenario> mr7RestScenarios() => [
  for (final c in mr7RestCases())
    if (c.scenario != null) c.scenario!,
];

bool _matches(Object? actual, Object? expected) {
  if (expected is Map) {
    return actual is Map &&
        expected.entries.every(
          (e) => actual.containsKey(e.key) && _matches(actual[e.key], e.value),
        );
  }
  if (expected is List) {
    return actual is List &&
        actual.length == expected.length &&
        List.generate(
          expected.length,
          (i) => i,
        ).every((i) => _matches(actual[i], expected[i]));
  }
  return actual == expected;
}

const _head = '1111111111111111111111111111111111111111';
const _position = <String, Object?>{
  'position_type': 'text',
  'base_sha': '2222222222222222222222222222222222222222',
  'start_sha': '3333333333333333333333333333333333333333',
  'head_sha': _head,
  'old_path': 'synthetic.txt',
  'new_path': 'synthetic.txt',
  'new_line': 1,
};

/// Install serialized API routes on 7B0's synthetic server. The independent
/// observer receives only wire records, never this fixture's record map.
/// Seed data is fixture setup, not evidence of AI writes or live creation.
/// For isolated variants, [scenario] selects the opposite initial state. A
/// serial run instead obtains those states from the preceding real mutations.
void configureMr7RestFixtures(
  Mr7SyntheticGitLab server, {
  Mr7Scenario? scenario,
}) {
  final root = 'projects/${server.projectId}';
  final records = <String, Map<String, Object?>>{};
  final operation = scenario?.operation;
  final variant = scenario?.variant;
  // 7B0 creates its synthetic project internally. Seed the isolated unstar
  // fixture once at its first serialized lookup, before any proposal/freshness
  // read, then expose actual stored state for every subsequent read.
  var projectSeeded = false;
  server.routes['GET $root'] = (_) {
    final project = server.project;
    if (project == null) return mr7Json({}, status: 404);
    if (!projectSeeded) {
      if (operation == 'setStar' && variant == 'unstar') {
        project['starred'] = true;
      }
      projectSeeded = true;
    }
    return mr7Json(project);
  };
  var nextId = 10000;
  var nextIid = 10;
  void record(String path, Map<String, Object?> value) {
    records[path] = value;
    server.routes['GET $path'] = (_) => mr7Json(records[path]);
  }

  Map<String, Object?> base(int id) => {
    'id': id,
    'project_id': server.projectId,
    'updated_at': '2026-10-29T00:00:00.000Z',
  };
  for (final resource in ['issues', 'merge_requests']) {
    final parent = '$root/$resource/1';
    final noteId = resource == 'issues' ? 301 : 302;
    record(parent, {
      ...base(resource == 'issues' ? 1001 : 2001),
      'iid': 1,
      'title': 'Synthetic original.',
      'description': 'Synthetic original.',
      'state':
          variant == 'reopen' &&
              (operation == 'updateMergeRequest' &&
                      resource == 'merge_requests' ||
                  (operation == 'updateIssue' ||
                          operation == 'moveBoardCard') &&
                      resource == 'issues')
          ? 'closed'
          : 'opened',
      'confidential': resource == 'issues',
      'subscribed':
          operation == 'setSubscribed' &&
          variant == '${resource == 'issues' ? 'issue' : 'mr'}-off',
      'labels': ['synthetic'],
      if (resource == 'merge_requests')
        'diff_refs': {
          'base_sha': _position['base_sha'],
          'start_sha': _position['start_sha'],
          'head_sha': _head,
        },
    });
    record('$parent/notes/$noteId', {
      ...base(noteId),
      'body': 'Synthetic original.',
      'author': {'id': server.userId},
      'noteable_iid': 1,
    });
    record('$parent/award_emoji/601', {
      ...base(601),
      'name': 'thumbsup',
      'user': {'id': server.userId},
    });
  }
  record('$root/merge_requests/1/changes', {
    'changes': [
      {
        'old_path': 'synthetic.txt',
        'new_path': 'synthetic.txt',
        'diff': '@@ -1 +1 @@\n-before\n+after\n',
      },
    ],
  });
  for (final branch in ['main', 'synthetic']) {
    record('$root/repository/branches/$branch', {
      'name': branch,
      'commit': {'id': _head},
      'protected': false,
      'default': branch == 'main',
    });
  }
  for (var n = 0; n < 20; n++) {
    record('$root/merge_requests/1/draft_notes/${401 + n}', {
      ...base(401 + n),
      'note': n == 1
          ? 'Other synthetic client /close @synthetic-user.'
          : 'Synthetic original.',
      'author': {'id': server.userId},
    });
  }
  record('$root/labels/701', {
    ...base(701),
    'name': 'synthetic',
    'color': '#112233',
    'description': 'Synthetic original.',
  });
  record('$root/milestones/501', {
    ...base(501),
    'iid': 3,
    'title': 'Synthetic milestone.',
    'state': 'active',
  });
  record('$root/boards/801', {
    ...base(801),
    'name': 'Synthetic original.',
    'hide_backlog_list':
        operation == 'setBoardSystemListHidden' && variant == 'backlog-shown',
    'hide_closed_list':
        operation == 'setBoardSystemListHidden' && variant == 'closed-shown',
  });
  record('$root/boards/801/lists/901', {
    ...base(901),
    'position': operation == 'moveBoardList' && variant == 'position-2' ? 0 : 1,
    'label': {'id': 701},
  });

  Map<String, Object?> body(RequestOptions request) =>
      Map<String, Object?>.from(request.data as Map);
  void fields(Map<String, Object?> value, Map<String, Object?> input) {
    for (final e in input.entries) {
      switch (e.key) {
        case 'new_name':
          value['name'] = e.value;
        case 'state_event':
          value['state'] = e.value == 'close' ? 'closed' : 'opened';
        case 'labels':
          value['labels'] = (e.value! as String).split(',');
        case 'assignee_ids':
          value['assignees'] = [
            for (final id in e.value! as List) {'id': id},
          ];
        case 'reviewer_ids':
          value['reviewers'] = [
            for (final id in e.value! as List) {'id': id},
          ];
        case 'milestone_id':
          value['milestone'] = {'id': e.value};
        default:
          value[e.key] = e.value;
      }
    }
    value['updated_at'] = server.serverTime.toIso8601String();
  }

  ResponseBody written(Map<String, Object?> value, {bool create = false}) {
    server.scenarioWrites++;
    server.addEvent(target: server.projectId);
    if (server.lostWriteReply) throw const Mr7Refused('replyLostAfterSend');
    return mr7Json(
      server.wrongWriteReply ? {'id': 999999} : value,
      status: create ? 201 : 200,
    );
  }

  void update(String path, {String? method}) {
    server.routes['${method ?? 'PUT'} $path'] = (request) {
      final value = records[path]!;
      fields(value, body(request));
      return written(value);
    };
  }

  void create(String path, {bool iid = false}) {
    server.routes['POST $path'] = (request) {
      final input = body(request);
      if (path == '$root/merge_requests' &&
          ['source_branch', 'target_branch'].any(
            (key) =>
                !records.containsKey('$root/repository/branches/${input[key]}'),
          )) {
        return mr7Json({'error': 'syntheticBranchMissing'}, status: 400);
      }
      final id = nextId++;
      final value = {...base(id), if (iid) 'iid': nextIid++};
      if (path.endsWith('/notes') || path.endsWith('/draft_notes')) {
        value['author'] = {'id': server.userId};
      }
      fields(value, input);
      record('$path/${iid ? value['iid'] : id}', value);
      return written(value, create: true);
    };
  }

  for (final resource in ['issues', 'merge_requests']) {
    final parent = '$root/$resource/1';
    final noteId = resource == 'issues' ? 301 : 302;
    create('$root/$resource', iid: true);
    update(parent);
    create('$parent/notes');
    update('$parent/notes/$noteId');
    for (final action in ['subscribe', 'unsubscribe']) {
      server.routes['POST $parent/$action'] = (_) {
        final value = records[parent]!;
        value['subscribed'] = action == 'subscribe';
        return written(value);
      };
    }
    for (final note in [false, true]) {
      final path = '$parent/${note ? 'notes/$noteId/' : ''}award_emoji';
      server.routes['POST $path'] = (request) {
        final id = nextId++;
        final value = {
          ...base(id),
          'name': body(request)['name'],
          'user': {'id': server.userId},
        };
        record('$path/$id', value);
        return written(value, create: true);
      };
    }
  }
  create('$root/merge_requests/1/draft_notes');
  update('$root/merge_requests/1/draft_notes/401');
  update('$root/merge_requests/1/draft_notes/402');
  create('$root/labels');
  update('$root/labels/701');
  create('$root/boards');
  update('$root/boards/801');
  server.routes['POST $root/boards/801/lists'] = (request) {
    final id = nextId++;
    final value = {
      ...base(id),
      'position': 2,
      'label': {'id': body(request)['label_id']},
    };
    record('$root/boards/801/lists/$id', value);
    return written(value, create: true);
  };
  update('$root/boards/801/lists/901');
}
