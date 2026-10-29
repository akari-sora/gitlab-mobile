import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/quick_actions.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';

import '../mr7_sandbox.dart';
import 'sandbox_contract.dart';

/// Synthetic production-chain candidates for breakdown §5.2 / §9. Wave 3b
/// supplies the sealed widget, activity and no-op observers. The wave-3d (!253)
/// production request seams below opened 11 formerly closed variants in 7B2k:
/// state close/reopen, milestone set/clear/closed-current/expired-current,
/// labels add/remove/clear, comment and opaque reply. They are a record, not
/// closure reasons.
const mr7GraphqlWave3dSeams = <String, String>{
  'B2-O1-state':
      'Delivered: the state witness compares the lowercase tool argument with the production CLOSE/REOPEN enum and still checks lifecycle and no-op.',
  'B2-O1-labels':
      'Delivered: the label witness reads an omitted addLabelIds or removeLabelIds side as empty and still requires complete before/after sets, disjointness and exact dispatch binding.',
  'B2-S2-milestone':
      'Delivered: only the sealed production milestone documents may select the nullable group owner projection, and every returned owner must be null or the sandbox namespace; no group selector is open.',
  'B2-S1-created-note':
      'Delivered: the guard binds only the exact Note returned by a successful comment or reply to a fresh REST ownership read before core readback; no uncreated Note is prebound.',
};
const mr7GraphqlApprovedText =
    '  Approved synthetic **Markdown**\r\nsecond line  \n';
const _workItemSeams =
    'Wave-3b WorkItem observers and wave-3d production request seams '
    'installed; remaining closures are typed per variant.';
const _todoClosed =
    'NOT_RUN/closed: 7-D4/7-D5/7-D7; the project-only todo seam '
    'does not prove shared group/account-global scopes, and acknowledgement '
    'alone is not independent result/scope evidence.';

final class Mr7GraphqlVariant {
  const Mr7GraphqlVariant(
    this.name,
    this.arguments, {
    this.precondition =
        'Synthetic target exists in this run\'s project and '
        'requested fields differ from the fresh opening snapshot.',
    this.closedReason,
    this.noChange = false,
  });

  final String name;
  final Map<String, Object?> arguments;
  final String precondition;
  final String? closedReason;
  final bool noChange;
}

final class Mr7GraphqlOperation {
  const Mr7GraphqlOperation({
    required this.operation,
    required this.tier,
    required this.preconditions,
    required this.readback,
    required this.variants,
    this.closedReason = _workItemSeams,
  });

  final String operation;
  final String tier;
  final String preconditions;
  final String readback;
  final List<Mr7GraphqlVariant> variants;
  final String closedReason;

  String get confirmation => tier == 'T4'
      ? 'Product approval with typed #3 plus explicit sandbox host confirmation.'
      : 'Product confirmEach approval plus explicit sandbox host confirmation.';

  String get isolation =>
      'Baseline before setup, complete paginated UTC '
      'window with two passes after each case and cleanup; every event and '
      'mutation ledger target must be this run\'s project. Any gap, 429, '
      'foreign or non-project event stops the session.';

  String get cleanup =>
      'One suite finalizer revalidates ID, path, owner, '
      'nonce and private personal namespace; deletes only this run\'s project '
      'and independently checks owner, parent inventory and deletion lookup. '
      'Uncertainty, pending mutation or identity/epoch drift retains quarantine '
      'and prevents cleanup and all later writes; never retry/reset.';

  String get live =>
      'NOT_RUN: no live transport, credentials, server version, '
      'feature/tier or permission evidence. Missing/unsupported widgets, '
      'uncreatable fixtures, incomplete connections, rejected permissions or '
      'uncertain readback keep the entire operation closed.';

  List<String> get chain => [
    'API preread: $preconditions',
    'Production AiRunner -> catalogue -> PolicyAiWriteCoordinator -> '
        'GitLabAiWritePort.$operation',
    confirmation,
    'Final transport: revalidate sandbox ID/path/owner, seal document and '
        'variables, fence epoch/429/close, send at most once.',
    'Independent readback: $readback',
    isolation,
    cleanup,
  ];

  String scenarioId(Mr7GraphqlVariant variant) =>
      'b2-$operation-${variant.name}';

  Mr7ClosedRefusal? refusal(Mr7GraphqlVariant variant) {
    if (operation.endsWith('Todo')) {
      return const Mr7ClosedRefusal(
        Mr7ClosureCause.scopeExcluded,
        'sharedTodoScopesUnproven',
      );
    }
    if (operation == 'updateWorkItemAssignees' && variant.name == 'multiple') {
      return const Mr7ClosedRefusal(
        Mr7ClosureCause.scopeExcluded,
        'otherMembersExcluded',
      );
    }
    if (operation == 'updateWorkItemHealthStatus' ||
        operation == 'updateWorkItemWeight') {
      return Mr7ClosedRefusal(
        Mr7ClosureCause.unsupportedServer,
        operation == 'updateWorkItemHealthStatus'
            ? 'healthWidgetNotModeled'
            : 'weightWidgetNotModeled',
      );
    }
    return null;
  }

  String closureDetail(Mr7GraphqlVariant variant) => switch (refusal(
    variant,
  )?.code) {
    'sharedTodoScopesUnproven' => _todoClosed,
    'otherMembersExcluded' => variant.closedReason!,
    'healthWidgetNotModeled' || 'weightWidgetNotModeled' =>
      'NOT_RUN/closed: synthetic paid/tier and own-versus-rolled-up semantics are unsupported.',
    _ => '',
  };
  Mr7Scenario scenario(Mr7GraphqlVariant variant) {
    Mr7SandboxSession? openedSession;
    Mr7GraphqlFixture? fixture;
    Map<String, Object?> effective = {};
    Map<String, Object?> arguments(Mr7Identity p) => {
      if (!operation.endsWith('Todo')) 'projectId': p.projectId,
      if (!operation.endsWith('Todo')) 'iid': 3,
      ...variant.arguments,
      if (operation == 'updateWorkItemAssignees' &&
          variant.name == 'replace-owner')
        'assigneeUsernames': [p.namespace],
      'reason': 'Explicit synthetic sandbox operation requested.',
    };
    Mr7StateObservation witness(Mr7Identity p, {Mr7MutationResult? result}) {
      final f = fixture!;
      f.observing = true;
      final a = {...effective};
      // Match the real coordinator's Markdown policy before binding the
      // independent witness to the effective approved payload.
      for (final field in ['description', 'body']) {
        if (a[field] case final String text) {
          a[field] = neutralizeForGitLabDraft(text);
        }
      }
      if (operation == 'createWorkItemActivityComment' ||
          operation == 'createWorkItemActivityReply') {
        a['body'] = (a['body'] as String).trim();
      }
      if (!operation.contains('Activity')) {
        return Mr7WorkItemObservation(
          workItemId: _gid,
          iid: 3,
          operation: operation,
          arguments: a,
          milestoneState: variant.name == 'closed-current' ? 'closed' : null,
          milestoneExpired: variant.name == 'expired-current' ? true : null,
        );
      }
      return Mr7WorkItemActivityObservation(
        workItemId: _gid,
        iid: 3,
        operation: operation,
        noteId: operation.startsWith('create')
            ? result!.stringId!
            : 'gid://gitlab/Note/${a['noteId']}',
        body: operation == 'deleteWorkItemActivityNote'
            ? 'Synthetic original'
            : a['body'] as String?,
        discussionId: _discussion,
        replyId: _reply,
        emojiName: a['name'] as String?,
        add: a['add'] as bool?,
      );
    }

    return Mr7Scenario(
      id: scenarioId(variant),
      suite: 'graphql',
      operation: operation,
      variant: variant.name,
      tier: tier,
      closed: refusal(variant),
      targetKind: operation.endsWith('Todo')
          ? AiTargetKind.todo
          : AiTargetKind.issue,
      targetKinds: operation.endsWith('Todo')
          ? null
          : {AiTargetKind.project, AiTargetKind.issue, AiTargetKind.note},
      expectedMutations: variant.noChange ? 0 : 1,
      utterance: (p) =>
          'Perform $operation on synthetic issue #3 in ${p.path}.',
      call: (p) => AiToolCall(
        id: scenarioId(variant),
        name: operation,
        arguments: arguments(p),
      ),
      resource: (_) => const AiResourceRef(kind: AiResourceKind.issue, id: 3),
      paths: (_) => const {'POST graphql'},
      fixture: (session, p) async {
        openedSession = session;
        final f =
            _fixtures[session.server] ??
            configureMr7GraphqlFixtures(session.server);
        fixture = f;
        f.open(p, operation, variant);
        await f.bind(session);
        return f.seals(session, arguments(p));
      },
      preRead: !operation.contains('Activity') && !operation.endsWith('Todo')
          ? (p) => [
              Mr7SnapshotSpec.workItem(
                path: 'projects/${p.projectId}/issues/3',
                workItemId: _gid,
              ),
            ]
          : null,
      freshness: (session, request) async {
        final p = session.identity!;
        final parent = await session.read('projects/${p.projectId}/issues/3');
        if (parent['id'] != 31 ||
            parent['iid'] != 3 ||
            parent['project_id'] != p.projectId ||
            parent['confidential'] != false) {
          throw const Mr7Refused('graphqlFixtureIdentity');
        }
        openedSession = session;
        effective = Map<String, Object?>.from(request.arguments);
        return const AiWriteFreshness(
          visibilityUnreadable: false,
          sourceVisibilityUnreadable: false,
          targetVisibility: 'private',
        );
      },
      createRegistry: (api) {
        final session = openedSession;
        final identity = session?.identity;
        if (session == null ||
            identity == null ||
            session.quarantined ||
            !session.boundaryValid() ||
            api.instance.key != session.instance.toString()) {
          throw const Mr7Refused('graphqlRegistryUnbound');
        }
        return createAiWorkspaceWorkItemWriteRegistry(
          api: api,
          accountKey: '${api.instance.key}#${identity.userId}',
          instanceKey: api.instance.key,
          generation: 1,
          isCurrent: () =>
              identical(session.identity, identity) &&
              !session.quarantined &&
              session.boundaryValid() &&
              !api.isClosed,
        );
      },
      resultPath: switch (operation) {
        'createWorkItemActivityComment' ||
        'createWorkItemActivityReply' => ['data', 'createNote', 'note'],
        'editWorkItemActivityNote' => ['data', 'updateNote', 'note'],
        'deleteWorkItemActivityNote' ||
        'setWorkItemActivityNoteReaction' => const [],
        'setWorkItemNotifications' => ['data', 'workItemSubscribe', 'workItem'],
        'setIncidentStatus' => ['data', 'issueSetEscalationStatus', 'issue'],
        _ => ['data', 'workItemUpdate', 'workItem'],
      },
      readbackPaths: (p, result) => {
        'projects/${p.projectId}/issues/3',
        if (operation.contains('Activity')) ...{
          'projects/${p.projectId}/issues/3/notes/51',
          'projects/${p.projectId}/issues/3/notes/52',
          'projects/${p.projectId}/issues/3/notes/53',
          if (operation == 'createWorkItemActivityReply')
            'projects/${p.projectId}/issues/3/notes/54',
        },
      },
      noChangeObservation: variant.noChange ? (p) => witness(p) : null,
      observe: (observer, p) async =>
          observer.observe(witness(p, result: observer.result)),
    );
  }
}

// Defense in depth if a caller drops the typed closure. Never return true from
// identity-only, mutation-response, preservation-only, event-only or ack evidence.
Future<bool> _observeUnavailable(Mr7Readback observer, Mr7Identity p) async {
  throw const Mr7Refused('graphqlIndependentReadbackUnavailable');
}

/// Complete definitions, including executable and typed-closed rows.
List<Mr7Scenario> mr7GraphqlScenarios() => [
  for (final operation in mr7GraphqlOperations)
    for (final variant in operation.variants) operation.scenario(variant),
];

/// Feed these to the runner's existing closedVariants parameter. Unlike its
/// executable-definition rows, these do not hardcode a project scope for the
/// excluded group/account-global targets. No provider or call is executed.
List<Mr7ClosedVariant> mr7GraphqlClosedVariants() => [
  for (final scenario in [
    ...mr7GraphqlScenarios(),
    ...mr7GraphqlGroupRefusals(),
  ])
    if (scenario.closed != null)
      Mr7ClosedVariant(
        id: scenario.id,
        suite: scenario.suite,
        operation: scenario.operation,
        variant: scenario.variant,
        tier: scenario.tier,
        refusal: scenario.closed!,
      ),
];

/// Dispositions accompany, rather than rewrite, the runner's raw receipt.
/// A refusal regression passing does not promote a positive operation to PASS.
List<Map<String, Object?>> mr7GraphqlCoverage() => [
  for (final row in mr7GraphqlOperations)
    for (final variant in row.variants)
      {
        'id': row.scenarioId(variant),
        'operation': row.operation,
        'variant': variant.name,
        'tier': row.tier,
        'scope': row.operation.endsWith('Todo') ? variant.name : 'project',
        'status': 'NOT_RUN',
        'capability': row.refusal(variant) == null ? 'executable' : 'closed',
        if (row.refusal(variant) case final refusal?) ...{
          'closureCause': refusal.cause.name,
          'reason': refusal.code,
          'closureDetail': row.closureDetail(variant),
        },
        'preconditions': [
          row.preconditions,
          if (variant.precondition.isNotEmpty) variant.precondition,
        ],
        'chain': row.chain,
        'live': row.live,
        'closesOnlyWhen':
            'Required variants have production-policy exact-SHA '
            'live API/confirmation/write/independent-readback/isolation '
            'evidence; synthetic or candidate evidence cannot close the row.',
      },
];

const mr7GraphqlOperations = <Mr7GraphqlOperation>[
  Mr7GraphqlOperation(
    operation: 'updateWorkItemState',
    tier: 'T2',
    preconditions:
        'Fresh project WorkItem GID/IID/type, revision, lifecycle '
        'and updateWorkItem permission; OPEN and CLOSED fixtures.',
    readback:
        'Exact WorkItem GID, project and requested OPEN/CLOSED lifecycle '
        'from an uncached request; lifecycle is separate from custom status.',
    variants: [
      Mr7GraphqlVariant('close', {
        'stateEvent': 'close',
      }, precondition: 'Fixture lifecycle is OPEN.'),
      Mr7GraphqlVariant('reopen', {
        'stateEvent': 'reopen',
      }, precondition: 'Fixture lifecycle is CLOSED.'),
      Mr7GraphqlVariant(
        'no-op',
        {'stateEvent': 'close'},
        precondition: 'Fixture already CLOSED; consume target without send.',
        noChange: true,
      ),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'updateWorkItemStatus',
    tier: 'T2',
    preconditions:
        'STATUS widget and current allowed custom-status candidate, '
        'revision/lock version and real API-bound status/dates/health registry.',
    readback:
        'Exact WorkItem/project, selected status ID and acknowledged '
        'revision; synchronous registry START/settlement and no stale rollback.',
    variants: [
      Mr7GraphqlVariant(
        'candidate',
        {'candidateId': 'gid://gitlab/WorkItems::Status/41'},
        precondition:
            'Current custom status differs; 41 is a fresh allowed candidate.',
      ),
      Mr7GraphqlVariant(
        'no-op',
        {'candidateId': 'gid://gitlab/WorkItems::Status/41'},
        precondition: 'Candidate already selected.',
        noChange: true,
      ),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'updateWorkItemDates',
    tier: 'T2',
    preconditions:
        'Fresh date widget, server CE/EE capability probe, permission '
        'and shared production registry; inherited support must be observed.',
    readback:
        'Exact WorkItem/project, manual/inherited mode, explicit null '
        'versus date values and unchanged unrelated fields; no invented EE fallback.',
    variants: [
      Mr7GraphqlVariant(
        'manual-ce',
        {'mode': 'manual', 'startDate': '2026-11-01', 'dueDate': '2026-11-02'},
        precondition:
            'CE probe selects the manual-date protocol; both dates initially null.',
      ),
      Mr7GraphqlVariant(
        'manual-ee',
        {'mode': 'manual', 'startDate': '2026-11-01', 'dueDate': '2026-11-02'},
        precondition:
            'EE probe confirms manual-date mode; both dates initially null.',
      ),
      Mr7GraphqlVariant(
        'clear-start',
        {'mode': 'manual', 'clearStart': true},
        precondition:
            'Manual start is 2026-11-01; preserve due date 2026-11-02.',
      ),
      Mr7GraphqlVariant(
        'clear-due',
        {'mode': 'manual', 'clearDue': true},
        precondition:
            'Manual due is 2026-11-02; preserve start date 2026-11-01.',
      ),
      Mr7GraphqlVariant('clear-both', {
        'mode': 'manual',
        'clearStart': true,
        'clearDue': true,
      }, precondition: 'Both manual dates are non-null.'),
      Mr7GraphqlVariant(
        'inherited',
        {'mode': 'inherited'},
        precondition:
            'EE probe confirms inherited dates; current mode is manual and inherited values are independently readable.',
      ),
      Mr7GraphqlVariant(
        'no-op',
        {'mode': 'manual', 'startDate': '2026-11-01', 'dueDate': '2026-11-02'},
        precondition:
            'Current mode is manual and both dates exactly match the request.',
        noChange: true,
      ),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'updateWorkItemHealthStatus',
    tier: 'T2',
    preconditions:
        'HEALTH_STATUS widget, read/admin permission, revision and '
        'API-bound registry; own health stays separate from rolled-up health.',
    readback:
        'Exact WorkItem/project, nullable own health and acknowledged revision.',
    variants: [
      Mr7GraphqlVariant(
        'onTrack',
        {'healthStatus': 'onTrack'},
        precondition: 'Own health is atRisk; rolled-up health stays unchanged.',
      ),
      Mr7GraphqlVariant('needsAttention', {
        'healthStatus': 'needsAttention',
      }, precondition: 'Own health is onTrack.'),
      Mr7GraphqlVariant('atRisk', {
        'healthStatus': 'atRisk',
      }, precondition: 'Own health is onTrack.'),
      Mr7GraphqlVariant('none', {
        'healthStatus': 'none',
      }, precondition: 'Own health is non-null; none explicitly clears it.'),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'updateWorkItemAssignees',
    tier: 'T2',
    preconditions:
        'Complete current/candidate assignee connection and metadata '
        'permission; only the synthetic owner may be assigned in live scope.',
    readback:
        'Exact WorkItem/project and complete requested opaque assignee-ID '
        'set with terminal pagination; truncated connections never imply empty.',
    variants: [
      Mr7GraphqlVariant(
        'replace-owner',
        {
          'assigneeUsernames': ['synthetic-owner'],
        },
        precondition:
            'Complete current assignee set is empty; owner is an allowed candidate.',
      ),
      Mr7GraphqlVariant('clear', {
        'assigneeUsernames': <String>[],
      }, precondition: 'Complete current set contains only the owner.'),
      Mr7GraphqlVariant(
        'multiple',
        {
          'assigneeUsernames': ['synthetic-owner', 'synthetic-other'],
        },
        closedReason:
            'NOT_RUN/closed: 7-D8 forbids adding other members; '
            'a multi-user live fixture cannot be created within this authorization.',
      ),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'updateWorkItemMilestone',
    tier: 'T2',
    preconditions:
        'Synthetic project-owned milestone, full current metadata '
        'and fresh permission; preserve current closed/expired assignments.',
    readback:
        'Exact WorkItem/project and exact milestone ID or explicit null; '
        'clearing does not depend on a successful candidate search.',
    variants: [
      Mr7GraphqlVariant(
        'set',
        {'milestoneTitle': 'Synthetic milestone'},
        precondition:
            'Current milestone is null; unique active synthetic project milestone exists.',
      ),
      Mr7GraphqlVariant(
        'clear',
        {'clearMilestone': true},
        precondition:
            'Current project milestone is non-null; candidate-search failure does not block clearing.',
      ),
      Mr7GraphqlVariant(
        'closed-current',
        {'milestoneTitle': 'Synthetic milestone'},
        precondition:
            'Current milestone has this exact title and server state closed; preserve it without send.',
        noChange: true,
      ),
      Mr7GraphqlVariant(
        'expired-current',
        {'milestoneTitle': 'Synthetic milestone'},
        precondition:
            'Current milestone has this exact title and server expired=true; preserve it without send.',
        noChange: true,
      ),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'updateWorkItemWeight',
    tier: 'T2',
    preconditions:
        'WEIGHT widget, fresh admin permission and revision; own '
        'weight remains separate from rolled-up totals.',
    readback:
        'Exact WorkItem/project and own weight; null and zero are distinct.',
    variants: [
      Mr7GraphqlVariant('set', {
        'weight': 2,
      }, precondition: 'Own weight is 1; rolled-up totals are separate.'),
      Mr7GraphqlVariant('zero', {
        'weight': 0,
      }, precondition: 'Own weight is 1; zero is not null.'),
      Mr7GraphqlVariant('clear', {
        'clearWeight': true,
      }, precondition: 'Own weight is 2; clear must read back null.'),
      Mr7GraphqlVariant(
        'no-op',
        {'weight': 2},
        precondition: 'Own weight is already 2.',
        noChange: true,
      ),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'updateWorkItemContent',
    tier: 'T2',
    preconditions:
        'Fresh content/revision/update permission; synthetic '
        'plain title and Markdown without quick actions or real mentions.',
    readback:
        'Exact WorkItem/project, title and byte-exact Markdown including '
        'whitespace; unchanged fields stay unchanged, absent widget is explicit.',
    variants: [
      Mr7GraphqlVariant('title', {'title': 'Synthetic revised title'}),
      Mr7GraphqlVariant('description', {
        'description': '  Synthetic **Markdown**\n\n',
      }),
      Mr7GraphqlVariant('both', {
        'title': 'Synthetic revised title',
        'description': 'Synthetic body',
      }),
      Mr7GraphqlVariant('title-without-description-widget', {
        'title': 'Synthetic revised title',
      }, precondition: 'DESCRIPTION widget is absent; only title may change.'),
      Mr7GraphqlVariant(
        'no-op',
        {'title': 'Synthetic Work Item'},
        precondition:
            'Title already exactly matches; description remains unchanged.',
        noChange: true,
      ),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'updateWorkItemLabels',
    tier: 'T2',
    preconditions:
        'Project-owned synthetic label IDs, complete current and '
        'candidate connections, scoped-label policy and metadata permission.',
    readback:
        'Exact WorkItem/project and complete label-ID set; verify disjoint '
        'add/remove delta and refuse partial candidate/current connections.',
    variants: [
      Mr7GraphqlVariant(
        'add',
        {
          'labels': ['Synthetic A', 'Synthetic B'],
        },
        precondition:
            'Complete current label set is empty; A and B each resolve to a project-owned ID.',
      ),
      Mr7GraphqlVariant(
        'remove',
        {
          'labels': ['Synthetic A'],
        },
        precondition:
            'Current set is Synthetic A plus Synthetic B; remove only B.',
      ),
      Mr7GraphqlVariant(
        'replace',
        {
          'labels': ['Synthetic B', 'Synthetic C'],
        },
        precondition:
            'Current set is Synthetic A; disjoint delta adds B and C and removes A.',
      ),
      Mr7GraphqlVariant(
        'clear',
        {'labels': <String>[]},
        precondition:
            'Complete current set is Synthetic A; desired set is empty.',
      ),
      Mr7GraphqlVariant(
        'no-op',
        {
          'labels': ['Synthetic A'],
        },
        precondition: 'Complete current set is exactly Synthetic A.',
        noChange: true,
      ),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'createWorkItemActivityComment',
    tier: 'T2',
    preconditions:
        'Fresh activity permission and exact parent identity; '
        'ordinary public synthetic Markdown only, no internal/system notes.',
    readback:
        'Mutation-returned exact Note GID, exact parent/project/actor, '
        'ordinary non-internal body and independent note lookup.',
    variants: [
      Mr7GraphqlVariant('comment', {'body': 'Synthetic comment'}),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'createWorkItemActivityReply',
    tier: 'T2',
    preconditions:
        'Complete fresh activity/notes, synthetic anchor note 51 '
        'and its opaque server replyId; never manufacture the reply identifier.',
    readback:
        'Exact returned Note GID/body/actor/project and original discussion '
        'with unchanged opaque replyId from an independent read.',
    variants: [
      Mr7GraphqlVariant('opaque-reply', {
        'anchorNoteId': 51,
        'body': 'Synthetic reply',
      }),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'editWorkItemActivityNote',
    tier: 'T2',
    preconditions:
        'Complete ordinary synthetic note locator, fresh adminNote '
        'permission and original body/revision; no internal/system/quick-action edit.',
    readback:
        'Exact Note GID/project/parent/discussion and byte-exact revised '
        'Markdown; no-op consumes the target without mutation.',
    variants: [
      Mr7GraphqlVariant('edit', {'noteId': 51, 'body': '  Synthetic edit\n'}),
      Mr7GraphqlVariant(
        'no-op',
        {'noteId': 51, 'body': 'Synthetic original'},
        precondition: 'Exact current ordinary note body is Synthetic original.',
        noChange: true,
      ),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'deleteWorkItemActivityNote',
    tier: 'T4',
    preconditions:
        'Exact ordinary synthetic note 51, fresh adminNote '
        'permission and revision; typed target #3 is never auto-filled.',
    readback:
        'Empty mutation errors plus same actor/project/parent and exact '
        'note absence in a complete independent parent/note read; 404 alone fails.',
    variants: [
      Mr7GraphqlVariant('delete-exact-note', {'noteId': 51}),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'setWorkItemActivityNoteReaction',
    tier: 'T1',
    preconditions:
        'Synthetic ordinary note 51, awardEmoji permission, actor '
        'and fully paginated reaction connection; no internal/system note.',
    readback:
        'Complete exact-note/project reactions filtered by actor, emoji '
        'and add/remove intent; AwardEmoji ID is not a Note ID.',
    variants: [
      Mr7GraphqlVariant('add', {
        'noteId': 51,
        'name': 'thumbsup',
        'add': true,
      }, precondition: 'Complete reaction connection has no owner thumbsup.'),
      Mr7GraphqlVariant(
        'remove',
        {'noteId': 51, 'name': 'thumbsup', 'add': false},
        precondition:
            'Complete connection contains exactly the owner thumbsup to remove.',
      ),
      Mr7GraphqlVariant(
        'no-op',
        {'noteId': 51, 'name': 'thumbsup', 'add': true},
        precondition: 'Complete connection already contains owner thumbsup.',
        noChange: true,
      ),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'setWorkItemNotifications',
    tier: 'T1',
    preconditions:
        'Fresh authenticated actor and NOTIFICATIONS widget; '
        'do not infer subscription permission from updateWorkItem.',
    readback:
        'Exact WorkItem/project/actor and requested subscribed boolean; '
        'absent widget does not mean false and cannot close the live row.',
    variants: [
      Mr7GraphqlVariant('enable', {
        'enabled': true,
      }, precondition: 'Present notifications widget says subscribed=false.'),
      Mr7GraphqlVariant('disable', {
        'enabled': false,
      }, precondition: 'Present notifications widget says subscribed=true.'),
      Mr7GraphqlVariant(
        'no-op',
        {'enabled': true},
        precondition:
            'Present notifications widget already says subscribed=true.',
        noChange: true,
      ),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'setIncidentStatus',
    tier: 'T2',
    preconditions:
        'Synthetic project Incident, exact Issue/WorkItem identity '
        'and escalation revision; instance supports incident escalation.',
    readback:
        'Exact incident ID/IID/project and escalationStatus from '
        'independent query; escalation remains separate from lifecycle.',
    variants: [
      Mr7GraphqlVariant(
        'TRIGGERED',
        {'status': 'TRIGGERED'},
        precondition:
            'Incident escalation is RESOLVED; lifecycle is unchanged.',
      ),
      Mr7GraphqlVariant('ACKNOWLEDGED', {
        'status': 'ACKNOWLEDGED',
      }, precondition: 'Incident escalation is TRIGGERED.'),
      Mr7GraphqlVariant('RESOLVED', {
        'status': 'RESOLVED',
      }, precondition: 'Incident escalation is ACKNOWLEDGED.'),
      Mr7GraphqlVariant(
        'no-op',
        {'status': 'ACKNOWLEDGED'},
        precondition: 'Incident escalation is already ACKNOWLEDGED.',
        noChange: true,
      ),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'snoozeTodo',
    tier: 'T1',
    closedReason: _todoClosed,
    preconditions:
        'Owner todo with complete project/group/account-global '
        'ownership proof; no account-wide mutation is authorized.',
    readback:
        'Core remains ack-only. Extra independent target/result '
        'observation cannot unlock uncertainty or authorize shared external scopes.',
    variants: [
      Mr7GraphqlVariant('project', {
        'todoId': 61,
        'until': '2026-10-30T00:00:00Z',
      }),
      Mr7GraphqlVariant('group', {
        'todoId': 62,
        'until': '2026-10-30T00:00:00Z',
      }),
      Mr7GraphqlVariant('account-global', {
        'todoId': 63,
        'until': '2026-10-30T00:00:00Z',
      }),
    ],
  ),
  Mr7GraphqlOperation(
    operation: 'unsnoozeTodo',
    tier: 'T1',
    closedReason: _todoClosed,
    preconditions:
        'Owner snoozed todo with complete ownership/connection '
        'proof; group/account-global writes remain outside authorization.',
    readback:
        'Core ack-only semantics are preserved; missing independent '
        'project-bound result proof keeps the whole shared operation closed.',
    variants: [
      Mr7GraphqlVariant('project', {'todoId': 61}),
      Mr7GraphqlVariant('group', {'todoId': 62}),
      Mr7GraphqlVariant('account-global', {'todoId': 63}),
    ],
  ),
];

/// Group aliases are refusal-only definitions; use mr7GraphqlClosedVariants()
/// for receipts. No group is created, resolved or written.
List<Mr7Scenario> mr7GraphqlGroupRefusals() => [
  for (final operation in mr7GraphqlOperations.where(
    (row) =>
        row.operation != 'setIncidentStatus' && !row.operation.endsWith('Todo'),
  ))
    for (final variant in ['alias', 'renamed', 'foreign', 'descendant'])
      Mr7Scenario(
        id: 'b2-group-${operation.operation}-$variant',
        suite: 'graphql',
        operation: _groupAlias(operation.operation),
        variant: variant,
        tier: operation.tier,
        closed: const Mr7ClosedRefusal(
          Mr7ClosureCause.scopeExcluded,
          'groupAliasesExcluded',
        ),
        targetKind: AiTargetKind.groupWorkItem,
        expectedMutations: 0,
        call: (_) => AiToolCall(
          id: 'b2-group-${operation.operation}-$variant',
          name: _groupAlias(operation.operation),
          arguments: {
            'groupFullPath': switch (variant) {
              'renamed' => 'synthetic-renamed',
              'foreign' => 'synthetic-foreign',
              'descendant' => 'synthetic-group/child',
              _ => 'synthetic-group',
            },
            'iid': 3,
            ...operation.variants.first.arguments,
            'reason': 'Synthetic refusal negative; no group write authorized.',
          },
        ),
        paths: (_) => const {'POST graphql'},
        observe: _observeUnavailable,
      ),
];

String _groupAlias(String operation) =>
    operation.replaceFirst('WorkItem', 'GroupWorkItem');

const _gid = 'gid://gitlab/WorkItem/31';
const _labelA = 'gid://gitlab/ProjectLabel/701';
const _labelB = 'gid://gitlab/ProjectLabel/702';
const _labelC = 'gid://gitlab/ProjectLabel/703';
const _milestone = 'gid://gitlab/Milestone/501';
const _statusA = 'gid://gitlab/WorkItems::Status/40';
const _statusB = 'gid://gitlab/WorkItems::Status/41';
const _discussion = 'gid://gitlab/Discussion/opaque-thread';
const _reply = 'gid://gitlab/IndividualNoteDiscussion/opaque-reply';
const _revision = '2026-10-29T00:00:00Z';
final _fixtures = Expando<Mr7GraphqlFixture>();

/// A private, memory-only server model. Observer faults never alter production
/// responses, and sealing uses a separate copy with no sandbox side effects.
Mr7GraphqlFixture configureMr7GraphqlFixtures(
  Mr7SyntheticGitLab server, {
  String? fault,
}) {
  final fixture = Mr7GraphqlFixture._(server, fault);
  _fixtures[server] = fixture;
  server.routes['GET projects/${server.projectId}/issues/3'] = (_) =>
      mr7Json(fixture.parent);
  server.routes['POST /install/api/graphql'] = fixture.graph;
  return fixture;
}

final class Mr7GraphqlFixture {
  Mr7GraphqlFixture._(this.server, this.fault);
  final Mr7SyntheticGitLab server;
  final String? fault;
  late Mr7Identity identity;
  late String operation;
  late Mr7GraphqlVariant variant;
  Map<String, Object?> _state = {};
  Map<String, Object?> _seed = {};
  bool observing = false;
  int productionReads = 0;
  int observerReads = 0;
  int continuationReads = 0;
  final observerNotePages = <Map<String, Object?>>[];
  final preWrites = <Map<String, Object?>>[];
  final mutations = <Map<String, Object?>>[];
  Map<String, Object?> _copy(Map<String, Object?> value) =>
      (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();
  Map<String, Object?> get seed => _copy(_seed);
  // GitLab returns a new Note ID for every create. One session can run both
  // create variants, and the guard refuses a returned Note that is already bound.
  String get createdNote =>
      operation == 'createWorkItemActivityReply' ? '54' : '52';
  Map<String, Object?> get current => _copy(_state);
  String get _owner => 'gid://gitlab/User/${identity.userId}';
  Map<String, Object?> get _project => {
    'id': 'gid://gitlab/Project/${identity.projectId}',
    'fullPath': identity.path,
  };
  Map<String, Object?> get parent => {
    'id': 31,
    'iid': 3,
    'project_id': server.projectId,
    'confidential': false,
    'updated_at': _revision,
    'title': _state['title'] ?? 'Synthetic Work Item',
    'state': _state['state'] == 'CLOSED' ? 'closed' : 'opened',
  };
  Map<String, Object?> _label(String id) => {
    'id': id,
    'title': id == _labelA
        ? 'Synthetic A'
        : id == _labelB
        ? 'Synthetic B'
        : 'Synthetic C',
    'color': '#ffffff',
    'textColor': '#000000',
  };
  Map<String, Object?> get _milestoneValue => {
    'id': _milestone,
    'iid': '21',
    'title': 'Synthetic milestone',
    'state': 'active',
    'expired': false,
    'dueDate': null,
    'startDate': null,
    'webPath': '/${identity.path}/-/milestones/21',
    'project': _project,
    'group': null,
  };
  Map<String, Object?> _status(String id) => {
    'id': id,
    'name': id == _statusA ? 'To do' : 'In progress',
    'iconName': 'status_running',
    'color': '#000000',
    'position': 1,
    'description': null,
    'category': id == _statusA ? 'TO_DO' : 'IN_PROGRESS',
  };
  void open(Mr7Identity p, String op, Mr7GraphqlVariant v) {
    identity = p;
    operation = op;
    variant = v;
    observing = false;
    productionReads = 0;
    observerReads = 0;
    continuationReads = 0;
    observerNotePages.clear();
    preWrites.clear();
    mutations.clear();
    _state = {
      'state': 'OPEN',
      'title': 'Synthetic Work Item',
      'description': 'Synthetic original description',
      'descriptionPresent': true,
      'status': _statusA,
      'startDate': '2026-11-01',
      'dueDate': '2026-11-02',
      'isFixed': true,
      'rollUp': false,
      'assignees': <String>[],
      'labels': <String>[],
      'milestone': null,
      'subscribed': false,
      'escalation': 'TRIGGERED',
      'notes': <String, Object?>{
        '51': 'Synthetic original',
        '53': 'Other synthetic note',
      },
      'awards': <Map<String, Object?>>[],
    };
    switch (op) {
      case 'updateWorkItemState':
        if (v.name != 'close') _state['state'] = 'CLOSED';
      case 'updateWorkItemStatus':
        if (v.noChange) _state['status'] = _statusB;
      case 'updateWorkItemDates':
        if (v.name.startsWith('manual-')) {
          _state['startDate'] = null;
          _state['dueDate'] = null;
        }
      case 'updateWorkItemAssignees':
        if (v.name == 'clear') _state['assignees'] = [_owner];
      case 'updateWorkItemMilestone':
        if (v.name != 'set') {
          _state['milestone'] = {
            ..._milestoneValue,
            if (v.name == 'closed-current') 'state': 'closed',
            if (v.name == 'expired-current') 'expired': true,
          };
        }
      case 'updateWorkItemContent':
        if (v.name == 'title-without-description-widget') {
          _state['descriptionPresent'] = false;
        }
      case 'updateWorkItemLabels':
        _state['labels'] = switch (v.name) {
          'remove' => [_labelA, _labelB],
          'replace' || 'clear' || 'no-op' => [_labelA],
          _ => <String>[],
        };
      case 'setWorkItemActivityNoteReaction':
        _state['awards'] = <Map<String, Object?>>[
          {
            'name': 'thumbsup',
            'unicode': '👍',
            'user': {'id': 'gid://gitlab/User/8'},
          },
          if (v.name != 'add')
            {
              'name': 'thumbsup',
              'unicode': '👍',
              'user': {'id': _owner},
            },
        ];
      case 'setWorkItemNotifications':
        _state['subscribed'] = v.name != 'enable';
      case 'setIncidentStatus':
        _state['escalation'] = switch (v.name) {
          'TRIGGERED' => 'RESOLVED',
          'RESOLVED' || 'no-op' => 'ACKNOWLEDGED',
          _ => 'TRIGGERED',
        };
    }
    _seed = current;
  }

  Future<void> bind(Mr7SandboxSession session) async {
    final base = 'projects/${identity.projectId}';
    await session.bindWorkItemGraphResource(_gid, path: '$base/issues/3');
    for (final number in [701, 702, 703]) {
      server.routes['GET $base/labels/$number'] = (_) => mr7Json({
        'id': number,
        'project_id': identity.projectId,
        'name': number == 701
            ? 'Synthetic A'
            : number == 702
            ? 'Synthetic B'
            : 'Synthetic C',
        'is_project_label': true,
      });
      await session.bindGraphResource(
        'gid://gitlab/ProjectLabel/$number',
        path: '$base/labels/$number',
      );
    }
    server.routes['GET $base/milestones/501'] = (_) => mr7Json({
      'id': 501,
      'iid': 21,
      'project_id': identity.projectId,
      'title': 'Synthetic milestone',
    });
    await session.bindGraphResource(_milestone, path: '$base/milestones/501');
    for (final number in [51, 52, 53, 54]) {
      server.routes['GET $base/issues/3/notes/$number'] = (_) => mr7Json({
        'id': number,
        'project_id': identity.projectId,
        'noteable_id': 31,
        'author': {'id': identity.userId},
        'system': false,
        'internal': false,
      });
    }
    if (operation.contains('Activity') &&
        !operation.startsWith('createWorkItemActivityComment')) {
      await session.bindGraphResource(
        'gid://gitlab/Note/51',
        path: '$base/issues/3/notes/51',
      );
    }
  }

  Map<String, Object?> _connection(
    List<Object?> nodes,
    Object? after, {
    bool page = false,
  }) {
    if (!page || nodes.length < 2) {
      return {
        'nodes': nodes,
        'pageInfo': {'hasNextPage': false, 'endCursor': null},
      };
    }
    if (after != null) continuationReads++;
    return {
      'nodes': after == null ? nodes.take(1).toList() : nodes.skip(1).toList(),
      'pageInfo': {
        'hasNextPage': after == null,
        'endCursor': after == null ? 'opaque-next' : null,
      },
    };
  }

  Map<String, Object?> _note(String number) => {
    'id': 'gid://gitlab/Note/$number',
    'body': (_state['notes'] as Map)[number],
    'createdAt': '2026-09-01T01:02:03Z',
    'updatedAt': _revision,
    'system': false,
    'internal': false,
    'noteableType': 'Issue',
    'noteableId': 31,
    'author': {
      'id': _owner,
      'name': identity.namespace,
      'username': identity.namespace,
    },
    'project': _project,
    'userPermissions': {'adminNote': true, 'awardEmoji': true},
    'discussion': {
      'id': _discussion,
      'replyId': _reply,
      'createdAt': '2026-09-01T01:02:03Z',
    },
  };
  Map<String, Object?> _thread(Object? after) {
    final notes = Map<String, Object?>.from(_state['notes'] as Map);
    if (observing && fault == 'deletion-retained') {
      notes['51'] = 'Synthetic original';
    }
    final ids = notes.keys.toList();
    final page = _connection(
      [
        for (final id in ids) {..._note(id), 'body': notes[id]},
      ],
      after,
      page: observing && ids.length > 1,
    );
    if (observing) observerNotePages.add(_copy(page));
    return {
      'id': _discussion,
      'replyId': _reply,
      'createdAt': '2026-09-01T01:02:03Z',
      'notes': page,
    };
  }

  Map<String, Object?> _item(String doc, Map<dynamic, dynamic> vars) {
    final type = RegExp(
      r'onlyTypes:\s*\[([A-Z_]+)\]',
    ).firstMatch(doc)?.group(1);
    final types = type != null
        ? [type]
        : doc.contains('WorkItemWidgetNotes')
        ? ['NOTES']
        : <String>[];
    final widgets = <Map<String, Object?>>[];
    for (final type in types) {
      final widget = <String, Object?>{'type': type};
      switch (type) {
        case 'DESCRIPTION':
          if (_state['descriptionPresent'] == false) continue;
          widget.addAll({
            'description': _state['description'],
            'edited': false,
            'lastEditedAt': null,
          });
        case 'STATUS':
          widget['status'] = _status(_state['status'] as String);
        case 'START_AND_DUE_DATE':
          for (final field in ['startDate', 'dueDate', 'rollUp', 'isFixed']) {
            if (RegExp('\\b$field\\b').hasMatch(doc)) {
              widget[field] = _state[field];
            }
          }
          for (final field in [
            'startDateSourcingWorkItem',
            'dueDateSourcingWorkItem',
            'startDateSourcingMilestone',
            'dueDateSourcingMilestone',
          ]) {
            if (doc.contains(field)) widget[field] = null;
          }
        case 'ASSIGNEES':
          widget['allowsMultipleAssignees'] = false;
          widget['assignees'] = _connection([
            for (final id in _state['assignees'] as List)
              {
                'id': id,
                'name': identity.namespace,
                'username': identity.namespace,
              },
          ], vars['after']);
        case 'MILESTONE':
          widget['milestone'] = _state['milestone'];
        case 'LABELS':
          var labels = (_state['labels'] as List).cast<String>();
          if (observing && fault == 'partial-label-set') {
            labels = labels.take(1).toList();
          }
          widget['labels'] = _connection(
            labels.map(_label).toList(),
            vars['after'],
            page: observing,
          );
        case 'NOTIFICATIONS':
          widget['subscribed'] = _state['subscribed'];
        case 'NOTES':
          widget['discussionLocked'] = false;
          widget['discussions'] = _connection([_thread(null)], vars['after']);
      }
      widgets.add(widget);
    }
    return {
      'id': _gid,
      'iid': '3',
      'title': _state['title'],
      'state': _state['state'],
      'createdAt': '2026-09-01T01:02:03Z',
      'updatedAt': observing && fault == 'stale-page' && vars['after'] != null
          ? '2026-10-29T00:00:01Z'
          : _revision,
      'lockVersion': 1,
      'webUrl':
          'https://gitlab.invalid/install/${identity.path}/-/work_items/3',
      'project': _project,
      'namespace': {
        'id': 'gid://gitlab/Namespaces::ProjectNamespace/${identity.projectId}',
        'fullPath': identity.path,
      },
      'workItemType': {
        'id': 'gid://gitlab/WorkItems::Type/99',
        'name': operation == 'setIncidentStatus' ? 'Incident' : 'Issue',
        'widgetDefinitions': [
          {
            'type': 'STATUS',
            'allowedStatuses': [_status(_statusA), _status(_statusB)],
          },
          {'type': 'START_AND_DUE_DATE'},
          {'type': 'LABELS', 'allowsScopedLabels': true},
        ],
      },
      'userPermissions': {
        'readWorkItem': true,
        'setWorkItemMetadata': true,
        'updateWorkItem': true,
        'createNote': true,
      },
      'widgets': widgets,
    };
  }

  Map<String, Object?> get _incident => {
    'id': 'gid://gitlab/Issue/31',
    'iid': '3',
    'projectId': identity.projectId,
    'state': 'opened',
    'severity': null,
    'escalationStatus': _state['escalation'],
    'updatedAt': _revision,
  };

  ResponseBody graph(RequestOptions request) {
    final body = request.data as Map;
    final doc = body['query'] as String;
    final vars = body['variables'] as Map;
    if (doc.trimLeft().startsWith('mutation')) return _mutate(doc, vars);
    if (observing) {
      observerReads++;
    } else {
      productionReads++;
    }
    if (variant.name == 'manual-ce' &&
        doc.contains('isFixed') &&
        doc.contains('START_AND_DUE_DATE')) {
      return mr7Json({
        'errors': [
          {
            'message':
                'Field isFixed does not exist on WorkItemWidgetStartAndDueDate',
            'extensions': {
              'code': 'undefinedField',
              'typeName': 'WorkItemWidgetStartAndDueDate',
              'fieldName': 'isFixed',
            },
          },
        ],
      });
    }
    final actor = {
      'id': observing && fault == 'foreign-actor'
          ? 'gid://gitlab/User/99'
          : _owner,
    };
    if (doc.contains('MobileIncidentStatus') || doc.contains('Mr7Incident')) {
      return mr7Json({
        'data': {
          'currentUser': actor,
          'project': {
            ..._project,
            'issues': _connection([_incident], null),
          },
        },
      });
    }
    if (doc.contains('MobileProjectAssigneeCandidates')) {
      return mr7Json({
        'data': {
          'currentUser': actor,
          'project': {
            ..._project,
            'autocompleteUsers': [
              {
                'id': _owner,
                'name': identity.namespace,
                'username': identity.namespace,
              },
            ],
          },
        },
      });
    }
    if (doc.contains('MobileProjectWorkItemMilestones')) {
      return mr7Json({
        'data': {
          'currentUser': actor,
          'project': {
            ..._project,
            'milestones': _connection([_milestoneValue], vars['after']),
          },
        },
      });
    }
    if (doc.contains('MobileProjectWorkItemLabelCandidates') ||
        doc.contains('MobileProjectLabelCandidates')) {
      return mr7Json({
        'data': {
          'currentUser': actor,
          'project': {
            ..._project,
            'labels': _connection([
              _label(_labelA),
              _label(_labelB),
              _label(_labelC),
            ], vars['after']),
          },
        },
      });
    }
    if (doc.contains('query MobileProjectWorkItem(')) {
      return mr7Json({
        'data': {
          'project': {
            ..._project,
            'workItems': _connection([_item(doc, vars)], null),
          },
        },
      });
    }
    final item = _item(doc, vars);
    final data = <String, Object?>{'currentUser': actor, 'workItem': item};
    if (vars.containsKey('noteId')) {
      final number = (vars['noteId'] as String).split('/').last;
      final exists = (_state['notes'] as Map).containsKey(number);
      data['note'] = exists ? _note(number) : null;
      if (exists && doc.contains('awardEmoji')) {
        (data['note'] as Map)['awardEmoji'] = _connection(
          (_state['awards'] as List).cast<Object?>(),
          vars['after'],
          page: observing,
        );
      }
    }
    if (vars.containsKey('anchorNoteId')) {
      final number = (vars['anchorNoteId'] as String).split('/').last;
      data['anchor'] = {..._note(number), 'discussion': _thread(vars['after'])};
    }
    return mr7Json({'data': data});
  }

  ResponseBody _mutate(String doc, Map<dynamic, dynamic> vars) {
    final input = Map<String, Object?>.from(vars['input'] as Map);
    preWrites.add(current);
    mutations.add(_copy(input));
    server.scenarioWrites++;
    server.addEvent(target: identity.projectId);
    var root = 'workItemUpdate';
    if (doc.contains('createNote(')) {
      root = 'createNote';
      (_state['notes'] as Map)[createdNote] = input['body'];
    } else if (doc.contains('updateNote(')) {
      root = 'updateNote';
      (_state['notes'] as Map)['51'] = input['body'];
    } else if (doc.contains('destroyNote(')) {
      root = 'destroyNote';
      (_state['notes'] as Map).remove('51');
    } else if (doc.contains('awardEmojiAdd(') ||
        doc.contains('awardEmojiRemove(')) {
      final add = doc.contains('awardEmojiAdd(');
      root = add ? 'awardEmojiAdd' : 'awardEmojiRemove';
      final awards = _state['awards'] as List;
      if (add) {
        awards.add({
          'name': input['name'],
          'unicode': '👍',
          'user': {'id': _owner},
        });
      } else {
        awards.removeWhere(
          (a) => a['name'] == input['name'] && a['user']['id'] == _owner,
        );
      }
    } else if (doc.contains('issueSetEscalationStatus(')) {
      root = 'issueSetEscalationStatus';
      _state['escalation'] = input['status'];
    } else if (doc.contains('workItemSubscribe(')) {
      root = 'workItemSubscribe';
      _state['subscribed'] = input['subscribed'];
    } else {
      if (input.containsKey('stateEvent')) {
        _state['state'] = input['stateEvent'] == 'CLOSE' ? 'CLOSED' : 'OPEN';
      }
      if (input.containsKey('title')) _state['title'] = input['title'];
      for (final pair in [
        ('descriptionWidget', 'description'),
        ('statusWidget', 'status'),
        ('startAndDueDateWidget', 'dates'),
        ('assigneesWidget', 'assignees'),
        ('milestoneWidget', 'milestone'),
        ('labelsWidget', 'labels'),
      ]) {
        final value = input[pair.$1];
        if (value is! Map) continue;
        switch (pair.$2) {
          case 'description':
            _state['description'] = value['description'];
          case 'status':
            _state['status'] = value['status'];
          case 'dates':
            for (final field in ['startDate', 'dueDate', 'isFixed', 'rollUp']) {
              if (value.containsKey(field)) _state[field] = value[field];
            }
          case 'assignees':
            _state['assignees'] = List<String>.from(
              value['assigneeIds'] as List,
            );
          case 'milestone':
            _state['milestone'] = value['milestoneId'] == null
                ? null
                : _milestoneValue;
          case 'labels':
            final labels = List<String>.from(_state['labels'] as List);
            labels.removeWhere(
              (id) =>
                  (value['removeLabelIds'] as List? ?? const []).contains(id),
            );
            labels.addAll(
              (value['addLabelIds'] as List? ?? const []).cast<String>(),
            );
            labels.sort();
            _state['labels'] = labels;
        }
      }
    }
    return mr7Json({
      'data': {
        root: {
          'errors': <String>[],
          if (root == 'workItemUpdate' || root == 'workItemSubscribe')
            'workItem': _item(doc, vars),
          if (root == 'issueSetEscalationStatus') 'issue': _incident,
          if (root == 'createNote' || root == 'updateNote')
            'note': _note(root == 'createNote' ? createdNote : '51'),
          if (root == 'awardEmojiAdd')
            'awardEmoji': {
              'name': input['name'],
              'unicode': '👍',
              'user': {'id': _owner},
            },
        },
      },
    });
  }

  Future<Mr7ScenarioFixtures> seals(
    Mr7SandboxSession session,
    Map<String, Object?> args,
  ) async {
    final reads = <String, Set<String>>{};
    final documents = <String>{};
    final variables = <String>{};
    final editable = args.containsKey('body')
        ? 'body'
        : args.containsKey('description')
        ? 'description'
        : null;
    for (final arguments in [
      args,
      if (editable != null && !variant.noChange)
        {...args, editable: neutralizeForGitLabDraft(mr7GraphqlApprovedText)},
    ]) {
      final dryServer =
          Mr7SyntheticGitLab(
              userId: identity.userId,
              namespace: identity.namespace,
            )
            ..project = session.server.project == null
                ? null
                : _copy(session.server.project!)
            ..projectId = identity.projectId;
      final dry = configureMr7GraphqlFixtures(dryServer)
        ..open(identity, operation, variant);
      final adapter = _GraphqlCapture(dryServer, (request) {
        final body = request.data as Map;
        final document = body['query'] as String;
        final digest = mr7Digest(body['variables']);
        if (document.trimLeft().startsWith('mutation')) {
          documents.add(document);
          variables.add(digest);
        } else {
          reads.putIfAbsent(document, () => {}).add(digest);
        }
      });
      final api = GitLabApi(
        instance: GitLabInstance.parse(session.instance.toString()),
        token: 'synthetic-gitlab-pat',
        dio: Dio()..httpClientAdapter = adapter,
      );
      final account = '${api.instance.key}#${identity.userId}';
      try {
        final writer = port.GitLabAiWritePort(
          api,
          accountKey: account,
          workItemWriteRegistry: createAiWorkspaceWorkItemWriteRegistry(
            api: api,
            accountKey: account,
            instanceKey: api.instance.key,
            generation: 1,
            isCurrent: () => true,
          ),
          sessionGeneration: 1,
          isCurrent: () => true,
        );
        final prepared = await writer.prepare(
          port.AiWriteRequest(
            operationId: operation,
            executionId: 'seal-${variant.name}',
            scope: AiWriteScope(
              accountKey: account,
              grants: [
                AiScopeGrant(
                  kind: AiScopeKind.project,
                  projectId: identity.projectId,
                  projectPath: identity.path,
                ),
              ],
            ),
            arguments: {...arguments}..remove('reason'),
          ),
        );
        prepared.bindGraphBeforeMutation(() async {});
        final outcome = await writer.commit(prepared, mayStart: () => true);
        if (outcome is port.AiWriteNotSent) {
          throw StateError('Unsealable $operation: ${outcome.reasonCode}');
        }
        // Keep the actual candidate model pristine; only the isolated copy wrote.
        if (dry.preWrites.length > 1) {
          throw const Mr7Refused('graphqlFixtureReplay');
        }
      } finally {
        api.close();
      }
    }
    return Mr7ScenarioFixtures(
      graphReadDocuments: reads,
      graphDocuments: documents,
      graphVariablesDigests: variables,
    );
  }
}

final class _GraphqlCapture implements HttpClientAdapter {
  _GraphqlCapture(this.server, this.capture);
  final Mr7SyntheticGitLab server;
  final void Function(RequestOptions) capture;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) {
    if (options.data is Map && (options.data as Map)['query'] is String) {
      capture(options);
    }
    return server.respond(options);
  }

  @override
  void close({bool force = false}) {}
}
