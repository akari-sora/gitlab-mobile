// 7B1 definitions and synthetic server fixtures only. No live adapter or gate.
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/features/ai/ai_attachment_session.dart';
import 'package:gitlab_mobile/features/workspace/attachment_picker.dart';

import '../mr7_sandbox.dart'
    show
        Mr7Scenario,
        Mr7ScenarioFixtures,
        Mr7ClosedVariant,
        Mr7ClosedRefusal,
        Mr7ClosureCause;
import 'sandbox_contract.dart';

const mr7RestPlanRows = [8, 9, 14, 19, 20, 23, 32];

/// Subrows that a one-call, foreground synthetic scenario cannot close.
const mr7RestEvidenceGaps = <int, String>{
  8:
      'Actual product tier/decision/fixed reasons need a receipt projection; '
      'scenario.tier is declared metadata. Host confirmation is not app UI.',
  9:
      'Edited confirmations use E and preserved fields use FIX1. REST updated_at '
      'preflight is not atomic server CAS; snippet/delete cases belong to 7B3.',
  14:
      'Synthetic text policy is exercised; internal-note creation has no ledger '
      'argument. Device confirmation and all 24 locales remain NOT_RUN.',
  19:
      'Shared production budget/journal exercise 39/40/41, the account window '
      'and restart in host tests; real process death and live quota are NOT_RUN.',
  20:
      'Draft create/update do not publish. Whole-batch scan, external sandbox '
      'drafts and max20 publication are 7B3 publishDraftNotes cases, NOT_RUN here.',
  23:
      'U verifies memory-only intake, multipart byte/hash observation and '
      'metadata-only synthetic provider delivery. Real picker/process and live '
      'provider evidence remain NOT_RUN.',
  32:
      'Shared placeholder/provenance and scripted turns are available. Live '
      'same-field, crossnonce, restored-history and hiddenSpan evidence and '
      'device UI remain NOT_RUN.',
};

/// A closed variant is deliberately not an executable fake success case.
final class Mr7RestCase {
  const Mr7RestCase({
    required this.operation,
    required this.variant,
    required this.tier,
    this.scenario,
    this.closedReason,
    this.refusal,
    this.initialFields = const {},
    this.fixture = 'Only run-owned synthetic private-project resources.',
  }) : assert((scenario == null) != (closedReason == null)),
       assert((scenario == null) == (refusal != null));

  final String operation;
  final String variant;
  final String tier;
  final Mr7Scenario? scenario;
  final String? closedReason;
  final Mr7ClosedRefusal? refusal;
  Mr7ClosedVariant? get closedVariant => refusal == null
      ? null
      : Mr7ClosedVariant(
          id: id,
          suite: 'rest',
          operation: operation,
          variant: variant,
          tier: tier,
          refusal: refusal!,
        );
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

const _todoSeam =
    '7-D4/D5 keeps markTodoDone closed: account /todos and shared '
    'group/accountGlobal scopes are outside this project sandbox.';

const mr7RestEditOriginal = 'Synthetic edit proposal.';
const mr7RestEditText = 'Edited synthetic content.';
const mr7RestUploadText = 'synthetic-rest-attachment-content-729403';
const _thread = 'synthetic-thread';

Set<String> _parentFields(String operation) => switch (operation) {
  'updateIssue' || 'moveBoardCard' => {
    'title',
    'description',
    'labels',
    'assignees',
    'milestone',
    'state',
    'confidential',
    'severity',
  },
  'updateMergeRequest' => {
    'title',
    'description',
    'labels',
    'assignees',
    'milestone',
    'state',
    'reviewers',
    'source_branch',
    'target_branch',
  },
  _ => <String>{},
};

String _observedField(String input) => switch (input) {
  'state_event' => 'state',
  'assignee_ids' => 'assignees',
  'reviewer_ids' => 'reviewers',
  'milestone_id' => 'milestone',
  _ => input,
};

Map<String, Object?> _observedUpdates(Map<String, Object?> input) => {
  for (final entry in input.entries)
    _observedField(entry.key): switch (entry.key) {
      'state_event' => switch (entry.value) {
        'close' => 'closed',
        'activate' => 'active',
        _ => 'opened',
      },
      'labels' => (entry.value! as String).split(','),
      'assignee_ids' || 'reviewer_ids' => [
        for (final id in entry.value! as List) {'id': id},
      ],
      'milestone_id' => entry.value == null ? null : {'id': entry.value},
      _ => entry.value,
    },
};

Mr7Parent _parent(String resource, {bool note = false}) => resource == 'issues'
    ? (note
          ? const Mr7Parent.issueNote(id: 1001, iid: 1, noteId: 301)
          : const Mr7Parent.issue(id: 1001, iid: 1))
    : (note
          ? const Mr7Parent.mergeRequestNote(id: 2001, iid: 1, noteId: 302)
          : const Mr7Parent.mergeRequest(id: 2001, iid: 1));

/// Mirrors every rows_t12 production operation, including explicit closures.
/// A composed entrypoint installs fixtures, then passes [mr7RestScenarios] to
/// runMr7Sandbox. Each batch needs a bounded budget and its own finalizer;
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
    Future<bool> Function(Mr7Readback, Mr7Identity)? observe,
    Set<String> Function(Mr7Identity, Mr7MutationPermit)? readbackPaths,
    Future<Mr7ScenarioFixtures> Function(Mr7SandboxSession, Mr7Identity)? setup,
    Mr7ParentStateObservation Function(Mr7Identity)? noChangeObservation,
    String fixture = 'Run-owned synthetic fixture; no external users or refs.',
  }) {
    final id = 'b1-$operation-$variant';
    final row = productionAiLedger.find(operation)!;
    final parentFields = _parentFields(operation);
    final changedFields =
        (arguments['fields'] as Map?)?.keys
            .cast<String>()
            .map(_observedField)
            .toSet() ??
        <String>{};
    String bind(String path, Mr7Identity p) =>
        path.replaceAll('{p}', '${p.projectId}');
    final scenario = Mr7Scenario(
      id: id,
      suite: 'rest',
      operation: operation,
      variant: variant,
      tier: tier,
      fixture: setup,
      preRead: parentFields.isEmpty
          ? null
          : (p) => [
              Mr7SnapshotSpec(
                path: bind(opening!, p),
                fields: {...parentFields, 'updated_at'},
                unchangedFields: parentFields.difference(changedFields),
              ),
            ],
      noChangeObservation: noChangeObservation,
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
        if (mutation.startsWith('PUT ')) {
          final input = fields is Map
              ? Map<String, Object?>.from(fields)
              : <String, Object?>{
                  for (final field in ['body', 'position', 'resolved'])
                    if (request.arguments.containsKey(field))
                      field: request.arguments[field],
                };
          final requested = _observedUpdates(input);
          var originals = [current];
          if (operation == 'updateDiscussionNote' ||
              operation == 'setDiscussionResolved') {
            final thread = await session.read(
              'projects/${p.projectId}/${request.arguments['resource']}/'
              '${request.arguments['iid']}/discussions/'
              '${request.arguments['discussionId']}',
            );
            _noteIds(thread);
            originals = (thread['notes']! as List)
                .map((note) => Map<String, Object?>.from(note as Map))
                .where(
                  (note) =>
                      operation == 'setDiscussionResolved' ||
                      note['id'] == request.arguments['noteId'],
                )
                .toList();
          }
          if (requested.isEmpty ||
              originals.isEmpty ||
              originals.any(
                (original) => requested.entries.any(
                  (entry) =>
                      !original.containsKey(entry.key) ||
                      _matches(original[entry.key], entry.value),
                ),
              )) {
            throw const Mr7Refused('fixturePrecondition');
          }
        }
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
      readbackPaths:
          readbackPaths ??
          (p, result) => {
            bind(read, p)
                .replaceAll('{id}', '${result.returnedId}')
                .replaceAll('{iid}', '${result.returnedIid}'),
          },
      observe:
          observe ??
          (observer, p) async {
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

  void closed(
    String operation,
    Iterable<String> variants,
    String reason, {
    required Mr7ClosureCause cause,
    required String code,
  }) {
    for (final variant in variants) {
      cases.add(
        Mr7RestCase(
          operation: operation,
          variant: variant,
          tier: productionAiLedger.find(operation)!.baseTier == AiWriteTier.t1
              ? 'T1'
              : 'T2',
          closedReason: reason,
          refusal: Mr7ClosedRefusal(cause, code),
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
  add(
    'setStar',
    'already-matching-304',
    {'starred': false},
    'POST projects/{p}/unstar',
    'projects/{p}',
    {'starred': false},
    tier: 'T1',
    initialFields: {'starred': false},
    noChangeObservation: (_) => const Mr7ParentStateObservation(
      parent: Mr7Parent.project(),
      state: Mr7ParentState.starred,
      expected: false,
    ),
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
        fixture:
            'Owner has only thumbsdown on the issue/MR; notes have no awards. '
            'Adding thumbsup is new for this actor and exact parent; duplicate '
            'actor/parent/name POSTs return 404 without a write or event.',
      );
      Set<Object> remainingAwards = {};
      add(
        'removeAwardEmoji',
        variant,
        {
          'resource': resource,
          'iid': 1,
          'awardId': 601,
          if (note) 'noteId': noteId,
        },
        'DELETE $awardPath/601',
        awardPath,
        const {},
        tier: 'T1',
        opening: parent,
        resource: resource,
        setup: (session, p) async {
          final path = awardPath.replaceAll('{p}', '${p.projectId}');
          final response = await session.writer.get<Object?>(
            path,
            queryParameters: {'page': 1, 'per_page': 100},
          );
          final values = response.data;
          if (values is! List ||
              values.length > 100 ||
              response.headers.value('x-total') != '${values.length}' ||
              response.headers.value('x-page') != '1' ||
              response.headers.value('x-total-pages') != '1' ||
              response.headers.value('x-per-page') != '100' ||
              response.headers.value('x-next-page') != '') {
            throw const Mr7Refused('awardFixtureIncomplete');
          }
          final ids = <Object>{};
          for (final value in values) {
            if (value is! Map ||
                value['id'] is! int ||
                !ids.add(value['id'] as int)) {
              throw const Mr7Refused('awardFixtureIncomplete');
            }
          }
          if (!ids.remove(601)) throw const Mr7Refused('awardFixtureMissing');
          remainingAwards = Set.unmodifiable(ids);
          return const Mr7ScenarioFixtures();
        },
        readbackPaths: (p, _) => {
          parent.replaceAll('{p}', '${p.projectId}'),
          if (note) '$parent/notes/$noteId'.replaceAll('{p}', '${p.projectId}'),
          awardPath.replaceAll('{p}', '${p.projectId}'),
        },
        observe: (observer, _) async {
          await observer.observe(
            Mr7ListObservation(
              parent: _parent(resource, note: note),
              kind: Mr7ListKind.awards,
              expectedIds: remainingAwards,
            ),
          );
          return true;
        },
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
    add(
      'setSubscribed',
      '$side-already-matching-304',
      {'resource': resource, 'iid': 1, 'subscribed': false},
      'POST $parent/unsubscribe',
      parent,
      {'subscribed': false},
      tier: 'T1',
      opening: parent,
      resource: resource,
      initialFields: {'subscribed': false},
      noChangeObservation: (_) => Mr7ParentStateObservation(
        parent: _parent(resource),
        state: Mr7ParentState.subscribed,
        expected: false,
      ),
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
      'T proves the final project target, but Mr7TodoObservation only supports '
          'snooze/unsnooze. A created-Todo actor/project/parent observer is '
          'missing; an acknowledgement cannot establish creation (7-D7).',
      cause: Mr7ClosureCause.observerUnavailable,
      code: 'createdTodoObserverUnavailable',
    );
    for (final positioned in [false, if (resource == 'merge_requests') true]) {
      final variant = '$side-${positioned ? 'positioned' : 'unpositioned'}';
      final note = resource == 'issues'
          ? 12001
          : positioned
          ? 12003
          : 12002;
      add(
        'createDiscussion',
        variant,
        {
          'resource': resource,
          'iid': 1,
          'body': 'Synthetic discussion $variant.',
          if (positioned) 'position': _position,
        },
        'POST $parent/discussions',
        '',
        const {},
        opening: parent,
        resource: resource,
        readbackPaths: (p, result) => {
          parent.replaceAll('{p}', '${p.projectId}'),
          '$parent/discussions/${result.returnedGlobalId}'.replaceAll(
            '{p}',
            '${p.projectId}',
          ),
        },
        observe: (observer, _) async {
          final value = await observer.observe(
            Mr7DiscussionObservation(
              parent: _parent(resource),
              discussionId: observer.result.stringId!,
              noteIds: {note},
              resolved: false,
            ),
          );
          return _matches(value['notes'], [
            {
              'id': note,
              'body': 'Synthetic discussion $variant.',
              'author': {'id': 7},
              if (positioned) 'position': _position,
            },
          ]);
        },
      );
    }
    for (final operation in ['createDiscussionNote', 'updateDiscussionNote']) {
      final create = operation == 'createDiscussionNote';
      final seed = resource == 'issues' ? 311 : 312;
      Set<int> beforeIds = {};
      add(
        operation,
        side,
        {
          'resource': resource,
          'iid': 1,
          'discussionId': _thread,
          if (!create) 'noteId': seed,
          'body': 'Synthetic discussion note.',
        },
        '${create ? 'POST' : 'PUT'} $parent/discussions/$_thread/notes${create ? '' : '/$seed'}',
        '',
        const {},
        opening: parent,
        resource: resource,
        setup: (session, p) async {
          final value = await session.read(
            'projects/${p.projectId}/$resource/1/discussions/$_thread',
          );
          beforeIds = _noteIds(value);
          return const Mr7ScenarioFixtures();
        },
        readbackPaths: (p, _) => {
          parent.replaceAll('{p}', '${p.projectId}'),
          '$parent/discussions/$_thread'.replaceAll('{p}', '${p.projectId}'),
        },
        observe: (observer, _) async {
          final id = observer.result.id!;
          if (create
              ? beforeIds.contains(id)
              : id != seed || !beforeIds.contains(id)) {
            return false;
          }
          final value = await observer.observe(
            Mr7DiscussionObservation(
              parent: _parent(resource),
              discussionId: _thread,
              noteIds: {...beforeIds, id},
              resolved: false,
            ),
          );
          return (value['notes']! as List)
              .whereType<Map<Object?, Object?>>()
              .any(
                (n) => _matches(n, {
                  'id': id,
                  'body': 'Synthetic discussion note.',
                  'author': {'id': 7},
                }),
              );
        },
      );
    }
  }
  closed(
    'markTodoDone',
    [
      'project-issue',
      'project-mr',
      'foreign-project',
      'group-target',
      'accountGlobal-target',
    ],
    _todoSeam,
    cause: Mr7ClosureCause.scopeExcluded,
    code: 'accountTodoScopeExcluded',
  );
  add(
    'unapproveMergeRequest',
    'approved',
    {'iid': 1},
    'POST projects/{p}/merge_requests/1/unapprove',
    '',
    const {},
    opening: 'projects/{p}/merge_requests/1',
    resource: 'merge_requests',
    readbackPaths: (p, _) => {
      'projects/${p.projectId}/merge_requests/1',
      'projects/${p.projectId}/merge_requests/1/approvals',
    },
    observe: (observer, _) => observer.observe(
      const Mr7ApprovalObservation(
        parent: Mr7Parent.mergeRequest(id: 2001, iid: 1),
        approved: false,
      ),
    ),
  );
  closed(
    'unapproveMergeRequest',
    ['already-unapproved'],
    'An already-unapproved 405/406/409/422 is failedCertain in production; '
        'it is not a successful unapproval or a recognized verified no-op.',
    cause: Mr7ClosureCause.unsupportedServer,
    code: 'alreadyUnapprovedCertainRefusal',
  );
  for (final resolved in [true, false]) {
    Set<int> noteIds = {};
    add(
      'setDiscussionResolved',
      resolved ? 'resolve' : 'unresolve',
      {
        'resource': 'merge_requests',
        'iid': 1,
        'discussionId': _thread,
        'resolved': resolved,
      },
      'PUT projects/{p}/merge_requests/1/discussions/$_thread',
      '',
      const {},
      opening: 'projects/{p}/merge_requests/1',
      resource: 'merge_requests',
      setup: (session, p) async {
        final value = await session.read(
          'projects/${p.projectId}/merge_requests/1/discussions/$_thread',
        );
        noteIds = _noteIds(value);
        if ((value['notes']! as List).any(
          (n) => (n as Map)['resolved'] == resolved,
        )) {
          throw const Mr7Refused('fixturePrecondition');
        }
        return const Mr7ScenarioFixtures();
      },
      readbackPaths: (p, _) => {
        'projects/${p.projectId}/merge_requests/1',
        'projects/${p.projectId}/merge_requests/1/discussions/$_thread',
      },
      observe: (observer, _) async {
        await observer.observe(
          Mr7DiscussionObservation(
            parent: const Mr7Parent.mergeRequest(id: 2001, iid: 1),
            discussionId: _thread,
            noteIds: noteIds,
            resolved: resolved,
          ),
        );
        return true;
      },
    );
  }

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
    cause: Mr7ClosureCause.unsupportedServer,
    code: 'internalNoteArgumentUnavailable',
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
      if (!create) {
        closed(
          operation,
          [variant],
          'Body-only draft edits also need independently captured position/commit_id '
          'preservation; FIX1 does not permit draft-note snapshots.',
          cause: Mr7ClosureCause.observerUnavailable,
          code: 'draftNoteSnapshotUnavailable',
        );
        continue;
      }
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
  for (final create in [true, false]) {
    const changedFields = {'title', 'description', 'start_date', 'due_date'};
    Map<String, Object?> omittedFields(Map<String, Object?> value) => {
      for (final entry in value.entries)
        if (!changedFields.contains(entry.key) && entry.key != 'updated_at')
          entry.key: entry.value,
    };
    Map<String, Object?> preserved = {};
    add(
      create ? 'createMilestone' : 'updateMilestone',
      'title-description-dates',
      {
        'fields': {
          'title': 'Synthetic milestone.',
          'description': 'Synthetic milestone description.',
          'start_date': '2026-10-28',
          'due_date': '2026-11-30',
        },
        if (!create) 'milestoneId': 501,
      },
      '${create ? 'POST' : 'PUT'} projects/{p}/milestones${create ? '' : '/501'}',
      'projects/{p}/milestones/{id}',
      const {},
      opening: create ? null : 'projects/{p}/milestones/501',
      setup: create
          ? null
          : (session, p) async {
              final before = await session.read(
                'projects/${p.projectId}/milestones/501',
              );
              if (before['id'] != 501 ||
                  before['iid'] != 3 ||
                  before['project_id'] != p.projectId ||
                  !const {'active', 'closed'}.contains(before['state'])) {
                throw const Mr7Refused('fixturePrecondition');
              }
              preserved = omittedFields(before);
              return const Mr7ScenarioFixtures();
            },
      observe: (observer, _) async {
        final value = await observer.observe(
          Mr7MilestoneObservation(
            id: observer.result.id!,
            iid: observer.result.iid!,
          ),
        );
        final omitted = omittedFields(value);
        return _matches(value, {
              'title': 'Synthetic milestone.',
              'description': 'Synthetic milestone description.',
              'start_date': '2026-10-28',
              'due_date': '2026-11-30',
            }) &&
            (create ||
                _matches(omitted, preserved) && _matches(preserved, omitted));
      },
    );
  }
  closed(
    'setMilestoneState',
    ['close', 'activate'],
    'M proves global ID/iid and state; FIX1 cannot snapshot milestones. '
        'Preserving omitted title/description/dates needs a typed milestone snapshot.',
    cause: Mr7ClosureCause.observerUnavailable,
    code: 'milestoneSnapshotUnavailable',
  );
  add(
    'createBoard',
    'name',
    {'name': 'Synthetic board.'},
    'POST projects/{p}/boards',
    'projects/{p}/boards/{id}',
    {'name': 'Synthetic board.'},
  );
  closed(
    'renameBoard',
    ['name'],
    'Renaming must preserve both system-list flags; FIX1 cannot snapshot boards.',
    cause: Mr7ClosureCause.observerUnavailable,
    code: 'boardSnapshotUnavailable',
  );
  for (final list in ['backlog', 'closed']) {
    for (final hidden in [true, false]) {
      closed(
        'setBoardSystemListHidden',
        ['$list-${hidden ? 'hidden' : 'shown'}'],
        'Changing one system-list flag must preserve the name and other flag; '
            'FIX1 cannot snapshot boards.',
        cause: Mr7ClosureCause.observerUnavailable,
        code: 'boardSnapshotUnavailable',
      );
    }
  }
  add(
    'createBoardList',
    'label',
    {'boardId': 801, 'labelId': 702},
    'POST projects/{p}/boards/801/lists',
    'projects/{p}/boards/801/lists/{id}',
    {
      'label': {'id': 702},
    },
    opening: 'projects/{p}/boards/801',
    fixture:
        'Board 801 has list 901 for label 701, retained for list moves. '
        'Valid label 702 is unused on this board; duplicate label-list POSTs '
        'return 400 without a write or event.',
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
    cause: Mr7ClosureCause.fixtureUnavailable,
    code: 'paidBoardListFixtureUnavailable',
  );
  for (final variant in ['multipart-memory', 'metadata-only-provider']) {
    final id = 'b1-upload_attachment-$variant';
    add(
      'upload_attachment',
      variant,
      {'attachmentId': 'att-1'},
      'POST projects/{p}/uploads',
      'projects/{p}/uploads/mr7-observation',
      const {},
      setup: (session, _) async {
        final attachments = AiAttachmentSession(
          accountKey: '${session.instance}#${session.expectedUserId}',
          conversationId: id,
          fileCapBytes: 1024,
        );
        final result = await attachments.reserveAndRead(
          picker: const _MemoryPicker(),
          uploadToolInSegment: true,
          intake: AiAttachmentIntake(
            filename: 'rest-fixture.txt',
            length: utf8.encode(mr7RestUploadText).length,
            mediaType: 'text/plain',
            open: () => Stream.value(
              Uint8List.fromList(utf8.encode(mr7RestUploadText)),
            ),
          ),
        );
        if (result.status != AiAttachStatus.stored) {
          attachments.discardAll();
          throw const Mr7Refused('attachmentFixtureUnavailable');
        }
        return Mr7ScenarioFixtures(attachments: attachments);
      },
      observe: (observer, _) => observer.observe(
        Mr7UploadObservation(
          byteCount: utf8.encode(mr7RestUploadText).length,
          sha256: sha256.convert(utf8.encode(mr7RestUploadText)).toString(),
        ),
      ),
    );
  }
  closed(
    'upload_attachment',
    ['slow-timeout'],
    'A lost or timed-out upload reply stays writeUncertain and stops the run; '
        'no response or retry can certify its effect.',
    cause: Mr7ClosureCause.observerUnavailable,
    code: 'uploadTimeoutUncertain',
  );
  closed(
    'upload_attachment',
    ['same-field-roundtrip', 'crossnonce', 'restored-history', 'hiddenSpan'],
    'The shared conversation/script seams exist; the complete provenance '
        'roundtrip variants are pending in this pass, not plain upload successes.',
    cause: Mr7ClosureCause.fixtureUnavailable,
    code: 'provenanceScenarioPending',
  );
  closed(
    'upload_attachment',
    ['picker-process-cleanup'],
    'A memory-only host fixture cannot prove actual picker or OS process cleanup.',
    cause: Mr7ClosureCause.scopeExcluded,
    code: 'devicePickerProcessEvidenceRequired',
  );
  for (final row in aiT12Rows.where((r) => r.editableField != null)) {
    final missingSnapshot = switch (row.operationId) {
      'updateLabel' => ('labelSnapshotUnavailable', 'label name/color'),
      'updateMilestone' => (
        'milestoneSnapshotUnavailable',
        'milestone title/dates',
      ),
      'renameBoard' => (
        'boardSnapshotUnavailable',
        'board hide_backlog_list/hide_closed_list',
      ),
      'updateDraftNote' => (
        'draftNoteSnapshotUnavailable',
        'draft position/commit_id',
      ),
      _ => null,
    };
    if (missingSnapshot != null) {
      closed(
        row.operationId,
        ['confirmation-edited-text'],
        'E supports re-confirmation, but preserving omitted ${missingSnapshot.$2} '
        'needs a typed child snapshot; FIX1 only accepts projects and issues/MRs.',
        cause: Mr7ClosureCause.observerUnavailable,
        code: missingSnapshot.$1,
      );
      continue;
    }
    final source = cases.firstWhere(
      (c) => c.operation == row.operationId && c.scenario != null,
    );
    cases.add(
      Mr7RestCase(
        operation: source.operation,
        variant: 'confirmation-edited-text',
        tier: source.tier,
        scenario: _editedScenario(source.scenario!, row.editableField!),
      ),
    );
  }
  return List.unmodifiable(cases);
}

List<Mr7Scenario> mr7RestScenarios() => [
  for (final c in mr7RestCases())
    if (c.scenario != null) c.scenario!,
];

List<Mr7ClosedVariant> mr7RestClosedVariants() => [
  for (final c in mr7RestCases())
    if (c.closedVariant != null) c.closedVariant!,
];

Mr7Scenario _editedScenario(Mr7Scenario source, String field) {
  final id = 'b1-${source.operation}-confirmation-edited-text';
  final operation = source.operation;
  final discussion = operation.contains('Discussion');
  Set<int> beforeIds = {};
  bool resolved = false;
  Map<String, Object?> arguments(Mr7Identity p) {
    final args = Map<String, Object?>.from(source.call(p).arguments! as Map);
    if (args['fields'] is Map) {
      args['fields'] = {
        if (operation.startsWith('create'))
          ...Map<String, Object?>.from(args['fields']! as Map),
        field: mr7RestEditOriginal,
      };
    } else {
      args[field] = mr7RestEditOriginal;
    }
    return args;
  }

  String resource(Mr7Identity p) =>
      arguments(p)['resource'] as String? ??
      (operation.contains('MergeRequest') || operation.contains('Draft')
          ? 'merge_requests'
          : 'issues');
  String? originalPath(Mr7Identity p) => switch (operation) {
    'updateIssue' => 'projects/${p.projectId}/issues/1',
    'updateMergeRequest' => 'projects/${p.projectId}/merge_requests/1',
    _ => null,
  };
  final preserved = _parentFields(operation).difference({field});
  return Mr7Scenario(
    id: id,
    suite: 'rest',
    operation: operation,
    variant: 'confirmation-edited-text',
    tier: source.tier,
    targetKind: source.targetKind,
    targetKinds: source.targetKinds,
    call: (p) => AiToolCall(id: id, name: operation, arguments: arguments(p)),
    paths: source.paths,
    freshness: source.freshness,
    resource: source.resource,
    utterance: source.utterance,
    fixture: (session, p) async {
      if (discussion && operation != 'createDiscussion') {
        final value = await session.read(
          'projects/${p.projectId}/${resource(p)}/1/discussions/$_thread',
        );
        beforeIds = _noteIds(value);
        resolved = ((value['notes']! as List).first as Map)['resolved'] == true;
      }
      return const Mr7ScenarioFixtures();
    },
    preRead: (p) => originalPath(p) == null
        ? []
        : [
            Mr7SnapshotSpec(
              path: originalPath(p)!,
              fields: {field, ...preserved, 'updated_at'},
              unchangedFields: preserved,
            ),
          ],
    readbackPaths: (p, result) => {
      if (discussion) ...{
        'projects/${p.projectId}/${resource(p)}/1',
        'projects/${p.projectId}/${resource(p)}/1/discussions/${operation == 'createDiscussion' ? result.returnedGlobalId : _thread}',
      } else
        ...source.readbackPaths!(p, result),
      if (originalPath(p) != null) originalPath(p)!,
    },
    observe: (observer, p) async {
      Map<String, Object?> value;
      if (discussion) {
        final noteId = operation == 'createDiscussion'
            ? 12004
            : observer.result.id!;
        if (operation == 'createDiscussionNote' && beforeIds.contains(noteId) ||
            operation == 'updateDiscussionNote' &&
                (noteId != arguments(p)['noteId'] ||
                    !beforeIds.contains(noteId))) {
          return false;
        }
        value = await observer.observe(
          Mr7DiscussionObservation(
            parent: _parent(resource(p)),
            discussionId: operation == 'createDiscussion'
                ? observer.result.stringId!
                : _thread,
            noteIds: operation == 'createDiscussion'
                ? {noteId}
                : {...beforeIds, noteId},
            resolved: operation == 'createDiscussion' ? false : resolved,
          ),
        );
        return (value['notes']! as List).whereType<Map<Object?, Object?>>().any(
          (n) => _matches(n, {
            'id': noteId,
            'body': mr7RestEditText,
            'author': {'id': p.userId},
          }),
        );
      }
      if (operation.contains('Milestone')) {
        value = await observer.observe(
          Mr7MilestoneObservation(
            id: observer.result.id!,
            iid: observer.result.iid!,
          ),
        );
      } else {
        value = await observer.read(observer.paths.single);
      }
      final args = arguments(p);
      final input = args['fields'] is Map
          ? Map<String, Object?>.from(args['fields']! as Map)
          : <String, Object?>{
              operation.contains('Draft') ? 'note' : field: mr7RestEditText,
            };
      input[args['fields'] is Map
              ? field
              : operation.contains('Draft')
              ? 'note'
              : field] =
          mr7RestEditText;
      final expected = _observedUpdates(input);
      if (operation == 'updateNote' ||
          operation == 'createNote' ||
          operation == 'createDraftNote') {
        expected['author'] = {'id': p.userId};
      }
      return _matches(value, expected);
    },
  );
}

Set<int> _noteIds(Map<String, Object?> thread) {
  final notes = thread['notes'];
  final ids = <int>{};
  if (notes is! List || notes.isEmpty || notes.length > 2000) {
    throw const Mr7Refused('discussionFixtureIncomplete');
  }
  for (final note in notes) {
    if (note is! Map || note['id'] is! int || !ids.add(note['id'] as int)) {
      throw const Mr7Refused('discussionFixtureIncomplete');
    }
  }
  return Set.unmodifiable(ids);
}

final class _MemoryPicker implements AttachmentPicker {
  const _MemoryPicker();
  @override
  Future<PickedAttachment?> pickFile() async => null;
  @override
  Future<PickedAttachment?> pickImage() async => null;
}

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
      if (resource == 'issues') 'severity': 'low',
      'assignees': <Object?>[],
      'milestone': null,
      if (resource == 'merge_requests') ...{
        'reviewers': <Object?>[],
        'source_branch': 'synthetic',
        'target_branch': 'main',
      },
      'subscribed':
          operation == 'setSubscribed' &&
          variant == '${resource == 'issues' ? 'issue' : 'mr'}-off',
      'labels': <String>[],
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
      'noteable_id': resource == 'issues' ? 1001 : 2001,
    });
    record('$parent/award_emoji/601', {
      ...base(601),
      'name': 'thumbsdown',
      'user': {'id': server.userId},
      'awardable_id': resource == 'issues' ? 1001 : 2001,
      'awardable_type': resource == 'issues' ? 'Issue' : 'MergeRequest',
    });
    record('$parent/notes/$noteId/award_emoji/601', {
      ...base(601),
      'name': 'thumbsdown',
      'user': {'id': server.userId},
      'awardable_id': noteId,
      'awardable_type': 'Note',
    });
    final seed = resource == 'issues' ? 311 : 312;
    record('$parent/discussions/$_thread', {
      'id': _thread,
      'project_id': server.projectId,
      'notes': [
        {
          ...base(seed),
          'body': 'Synthetic original discussion.',
          'author': {'id': server.userId},
          'noteable_id': resource == 'issues' ? 1001 : 2001,
          'resolved':
              operation == 'setDiscussionResolved' && variant == 'unresolve',
        },
      ],
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
  record('$root/labels/702', {
    ...base(702),
    'name': 'synthetic-list',
    'color': '#336699',
    'description': 'Synthetic unused board label.',
  });
  record('$root/milestones/501', {
    ...base(501),
    'iid': 3,
    'title': 'Synthetic original milestone title.',
    'description': 'Synthetic original milestone.',
    'start_date': '2026-10-01',
    'due_date': '2026-12-01',
    'state': operation == 'setMilestoneState' && variant == 'activate'
        ? 'closed'
        : 'active',
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
          value['state'] = e.value == 'close'
              ? 'closed'
              : e.value == 'activate'
              ? 'active'
              : 'opened';
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
        if (value['subscribed'] == (action == 'subscribe')) {
          return mr7Json({}, status: 304);
        }
        value['subscribed'] = action == 'subscribe';
        return written(value);
      };
    }
    for (final note in [false, true]) {
      final path = '$parent/${note ? 'notes/$noteId/' : ''}award_emoji';
      server.routes['GET $path'] = (_) {
        final values = records.entries
            .where(
              (e) =>
                  e.key.startsWith('$path/') &&
                  !e.key.substring(path.length + 1).contains('/'),
            )
            .map((e) => e.value)
            .toList();
        return mr7Json(
          values,
          headers: {
            'x-page': ['1'],
            'x-next-page': [''],
            'x-total': ['${values.length}'],
            'x-total-pages': ['1'],
            'x-per-page': ['100'],
          },
        );
      };
      server.routes['DELETE $path/601'] = (_) {
        if (records.remove('$path/601') == null) {
          return mr7Json({}, status: 404);
        }
        written(const {});
        return mr7Json({}, status: 204);
      };
      server.routes['POST $path'] = (request) {
        final name = body(request)['name'];
        if (records.entries.any(
          (entry) =>
              entry.key.startsWith('$path/') &&
              _matches(entry.value, {
                'name': name,
                'user': {'id': server.userId},
              }),
        )) {
          return mr7Json({'error': 'duplicateAwardEmoji'}, status: 404);
        }
        final id = nextId++;
        final value = {
          ...base(id),
          'name': name,
          'user': {'id': server.userId},
          'awardable_id': note
              ? noteId
              : resource == 'issues'
              ? 1001
              : 2001,
          'awardable_type': note
              ? 'Note'
              : resource == 'issues'
              ? 'Issue'
              : 'MergeRequest',
        };
        record('$path/$id', value);
        return written(value, create: true);
      };
    }
    server.routes['POST $parent/discussions'] = (request) {
      final input = body(request);
      final edited = input['body'] == mr7RestEditText;
      final id = edited
          ? 12004
          : resource == 'issues'
          ? 12001
          : input.containsKey('position')
          ? 12003
          : 12002;
      final value = {
        'id': 'synthetic-created-$id',
        'project_id': server.projectId,
        'notes': [
          {
            ...base(id),
            ...input,
            'author': {'id': server.userId},
            'noteable_id': resource == 'issues' ? 1001 : 2001,
            'resolved': false,
          },
        ],
      };
      record('$parent/discussions/${value['id']}', value);
      return written(value, create: true);
    };
    final thread = '$parent/discussions/$_thread';
    server.routes['POST $thread/notes'] = (request) {
      final value = {
        ...base(nextId++),
        ...body(request),
        'author': {'id': server.userId},
        'noteable_id': resource == 'issues' ? 1001 : 2001,
        'resolved':
            ((records[thread]!['notes']! as List).first as Map)['resolved'],
      };
      (records[thread]!['notes']! as List).add(value);
      return written(value, create: true);
    };
    final seed = resource == 'issues' ? 311 : 312;
    server.routes['PUT $thread/notes/$seed'] = (request) {
      final value = (records[thread]!['notes']! as List)
          .cast<Map<String, Object?>>()
          .singleWhere((n) => n['id'] == seed);
      fields(value, body(request));
      return written(value);
    };
    if (resource == 'merge_requests') {
      server.routes['PUT $thread'] = (request) {
        for (final value in records[thread]!['notes']! as List) {
          (value as Map)['resolved'] = body(request)['resolved'];
        }
        return written(records[thread]!);
      };
    }
  }
  for (final action in ['star', 'unstar']) {
    server.routes['POST $root/$action'] = (_) {
      final project = server.project!;
      if (project['starred'] == (action == 'star')) {
        return mr7Json({}, status: 304);
      }
      project['starred'] = action == 'star';
      return written(project, create: true);
    };
  }
  final approvals = <int>{if (variant != 'already-unapproved') server.userId};
  server.routes['GET $root/merge_requests/1/approvals'] = (_) => mr7Json({
    ...base(2001),
    'iid': 1,
    'approved_by': [
      for (final id in approvals)
        {
          'user': {'id': id},
        },
    ],
  });
  server.routes['POST $root/merge_requests/1/unapprove'] = (_) {
    if (!approvals.remove(server.userId)) return mr7Json({}, status: 409);
    return written(records['$root/merge_requests/1']!);
  };
  server.routes['POST $root/uploads'] = (_) => written({
    'alt': 'rest-fixture.txt',
    'url': '/uploads/0123456789abcdef0123456789abcdef/rest-fixture.txt',
    'markdown':
        '[rest-fixture.txt](/uploads/0123456789abcdef0123456789abcdef/rest-fixture.txt)',
  }, create: true);
  create('$root/merge_requests/1/draft_notes');
  update('$root/merge_requests/1/draft_notes/401');
  update('$root/merge_requests/1/draft_notes/402');
  create('$root/labels');
  update('$root/labels/701');
  create('$root/milestones', iid: true);
  // Milestone API routes use global IDs even when the response has an iid.
  final milestoneCreate = server.routes['POST $root/milestones']!;
  server.routes['POST $root/milestones'] = (request) async {
    final allocatedId = nextId;
    final allocatedIid = nextIid;
    final response = await milestoneCreate(request);
    final value = records.remove('$root/milestones/$allocatedIid')!;
    server.routes.remove('GET $root/milestones/$allocatedIid');
    record('$root/milestones/$allocatedId', value);
    return response;
  };
  update('$root/milestones/501');
  create('$root/boards');
  update('$root/boards/801');
  server.routes['POST $root/boards/801/lists'] = (request) {
    final labelId = body(request)['label_id'];
    if (!records.containsKey('$root/labels/$labelId') ||
        records.entries.any(
          (entry) =>
              entry.key.startsWith('$root/boards/801/lists/') &&
              _matches(entry.value, {
                'label': {'id': labelId},
              }),
        )) {
      return mr7Json({'error': 'invalidOrDuplicateBoardLabel'}, status: 400);
    }
    final id = nextId++;
    final value = {
      ...base(id),
      'position': 2,
      'label': {'id': labelId},
    };
    record('$root/boards/801/lists/$id', value);
    return written(value, create: true);
  };
  update('$root/boards/801/lists/901');
}
