import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';

import '../mr7_sandbox.dart';
import 'sandbox_contract.dart';

/// Inventory and typed closed definitions for breakdown §5.2 / §9 rows
/// 10, 16, 24, 25 and 29. These are synthetic candidates, never live evidence.
///
/// B2-S1/S2/S3 are installed. The sealed observer's closed operation mapping
/// still excludes the project WorkItem operations below. Neither a legacy
/// query nor a preservation snapshot substitutes for a sealed effect observer.
const mr7GraphqlSeamRequests = <String, String>{
  'B2-O1':
      'Add a sealed WorkItem parent observer for updateWorkItemState, '
      'Status, Dates, Assignees, Milestone, Content, Labels, '
      'setWorkItemNotifications and setIncidentStatus. Bind the actual '
      'workItemUpdate/workItemSubscribe/issueSetEscalationStatus selector, '
      'fresh actor and exact project-owned WorkItem/Issue. Verify requested '
      'fields and complete assignee/label sets independently; preserve omitted '
      'fields with the existing input.id-bound snapshot for WorkItems. '
      'Incident input uses projectPath+iid: add exact selector fencing and '
      'snapshot binding for that currently unsupported mutation root. The current '
      'parent-only graph observer allows only setStar/setSubscribed/'
      'cancelAutoMerge, and no collection mapping admits these operations.',
  'B2-O2':
      'Add sealed mappings for createWorkItemActivityComment/Reply, '
      'editWorkItemActivityNote, deleteWorkItemActivityNote and '
      'setWorkItemActivityNoteReaction. Bind the actual mutation selector, '
      'WorkItem, opaque discussion/replyId, exact Note and actor/project; '
      'traverse complete widget/discussion/note/reaction connections. '
      'Deletion must prove exact-note absence. Reaction removal uses '
      'note/name/user selectors, not a manufactured returned AwardEmoji ID. '
      'Generic createNote/updateNote/deleteNote/addAwardEmoji mappings do '
      'not admit these production operation IDs.',
  'B2-O3':
      'Observe zero-dispatch WorkItem no-ops through a sealed parent-state '
      'witness bound to the prepared production target and exact arguments '
      'before reporting PASS. The runner currently returns PASS from core '
      'noChange before constructing any observer; Mr7ParentStateObservation '
      'supports only star, REST subscription and auto-merge. Applies to '
      'state/status/dates/milestone/content/labels/note-edit/reaction/'
      'notifications/incident no-ops; paid weight remains unsupported.',
};

const _workItemSeams =
    'NOT_RUN/closed: B2-O1/O2/O3; the installed sealed observers '
    'do not support these production WorkItem operation IDs or their no-ops.';
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

  Mr7ClosedRefusal refusal(Mr7GraphqlVariant variant) {
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
    if (variant.noChange) {
      return const Mr7ClosedRefusal(
        Mr7ClosureCause.observerUnavailable,
        'workItemNoOpObserverUnavailable',
      );
    }
    return Mr7ClosedRefusal(
      Mr7ClosureCause.observerUnavailable,
      operation.contains('Activity')
          ? 'workItemActivityObserverUnavailable'
          : 'workItemParentObserverUnavailable',
    );
  }

  String closureDetail(Mr7GraphqlVariant variant) => switch (refusal(
    variant,
  ).code) {
    'sharedTodoScopesUnproven' => _todoClosed,
    'otherMembersExcluded' => variant.closedReason!,
    'healthWidgetNotModeled' || 'weightWidgetNotModeled' =>
      'NOT_RUN/closed: this synthetic server does not honestly model the '
          'paid/tier widget and its own-versus-rolled-up result.',
    'workItemNoOpObserverUnavailable' => mr7GraphqlSeamRequests['B2-O3']!,
    'workItemActivityObserverUnavailable' => mr7GraphqlSeamRequests['B2-O2']!,
    _ => mr7GraphqlSeamRequests['B2-O1']!,
  };

  Mr7Scenario scenario(Mr7GraphqlVariant variant) {
    // The coordinator reads freshness before creating its port/registry.
    // Retain that exact run identity and boundary, never an account constant.
    Mr7SandboxSession? openedSession;
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
      expectedMutations: variant.noChange ? 0 : 1,
      utterance: (p) => operation.endsWith('Todo')
          ? 'Perform $operation only on synthetic todo '
                '${variant.arguments['todoId']} in ${p.path}.'
          : 'Perform $operation on synthetic work item #3 in ${p.path}.',
      call: (p) => AiToolCall(
        id: scenarioId(variant),
        name: operation,
        arguments: {
          if (!operation.endsWith('Todo')) ...{
            'projectId': p.projectId,
            'iid': 3,
          },
          ...variant.arguments,
          if (operation == 'updateWorkItemAssignees' &&
              variant.name == 'replace-owner')
            'assigneeUsernames': [p.namespace],
          'reason': 'Explicit synthetic sandbox operation requested.',
        },
      ),
      resource: (_) => const AiResourceRef(kind: AiResourceKind.issue, id: 3),
      paths: (_) => const {'POST graphql'},
      // Closed definitions never enter fixture/provider execution. Install exact
      // production seals only when the complete operation-bound observer exists.
      freshness: (session, _) async {
        final p = session.identity!;
        final fixture = await session.read('projects/${p.projectId}/issues/3');
        if (fixture['id'] != 31 ||
            fixture['iid'] != 3 ||
            fixture['project_id'] != p.projectId ||
            fixture['confidential'] != false ||
            fixture['updated_at'] is! String) {
          throw const Mr7Refused('graphqlFixtureIdentity');
        }
        openedSession = session;
        return AiWriteFreshness(
          updatedAt: fixture['updated_at']! as String,
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
          generation: 1, // The 7B0 runner's fixed synthetic session generation.
          isCurrent: () =>
              identical(session.identity, identity) &&
              !session.quarantined &&
              session.boundaryValid() &&
              !api.isClosed,
        );
      },
      observe: _observeUnavailable,
    );
  }
}

// Defense in depth if a caller drops the typed closure. Never return true from
// identity-only, mutation-response, preservation-only, event-only or ack evidence.
Future<bool> _observeUnavailable(Mr7Readback observer, Mr7Identity p) async {
  throw const Mr7Refused('graphqlIndependentReadbackUnavailable');
}

/// Synthetic prerequisite for the delivered WorkItem-binding seam regressions.
void configureMr7GraphqlFixtures(Mr7SyntheticGitLab server) {
  server.routes['GET projects/${server.projectId}/issues/3'] = (_) => mr7Json({
    'id': 31,
    'iid': 3,
    'project_id': server.projectId,
    'confidential': false,
    'updated_at': '2026-10-29T00:00:00Z',
    'title': 'Synthetic Work Item',
  });
}

/// Definitions for inventory and refusal probes. All are currently closed;
/// compose receipts with mr7GraphqlClosedVariants(), not this scenarios list.
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
        'capability': 'closed',
        'closureCause': row.refusal(variant).cause.name,
        'reason': row.refusal(variant).code,
        'closureDetail': row.closureDetail(variant),
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
          'labels': ['Synthetic A'],
        },
        precondition:
            'Complete current label set is empty; Synthetic A resolves to one project-owned ID.',
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
          'labels': ['Synthetic B'],
        },
        precondition:
            'Current set is Synthetic A; disjoint delta adds B and removes A.',
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
