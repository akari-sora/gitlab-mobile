import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/graphql_write_classify.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/group_work_item_identity.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr6b3_support.dart';

const g0eAccount = mr6b3Account;
const g0ePath = 'team/sub';
const g0eScope = AiWriteScope(
  accountKey: g0eAccount,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.groupWorkItem,
      groupId: 7,
      groupFullPath: g0ePath,
      iid: 5,
    ),
  ],
);

VerifiedGroupWorkItemIdentity g0eIdentity(
  Object api, {
  int groupId = 7,
  String fullPath = g0ePath,
  int iid = 5,
  String workItemGid = 'gid://gitlab/WorkItem/91',
  int generation = 7,
  int readEpoch = 1,
}) => VerifiedGroupWorkItemIdentity.fromServerEvidence(
  instance: GitLabInstance.parse('https://example.com/gitlab'),
  expectedUserId: 7,
  actorUserId: 7,
  expectedGroupId: groupId,
  expectedFullPath: fullPath,
  expectedIid: iid,
  namespace: {
    'id': 'gid://gitlab/Group/$groupId',
    'fullPath': fullPath,
    'workItem': {
      'id': workItemGid,
      'iid': iid,
      'project': null,
      'namespace': {'id': 'gid://gitlab/Group/$groupId', 'fullPath': fullPath},
    },
  },
  apiOwner: api,
  generation: generation,
  readEpoch: readEpoch,
)!;

/// Synthetic capabilities exercise shared seams while production rows stay
/// empty. These fixtures deliberately state their own arguments and caps.
final class G0eLedger implements AiCapabilityLedger {
  const G0eLedger({this.visible = true});
  final bool visible;
  static const ids = <String>{
    'updateGroupWorkItemState',
    'updateGroupWorkItemContent',
    'editGroupWorkItemActivityNote',
    'updateGroupWorkItemLabels',
    'setGroupWorkItemActivityNoteReaction',
    'setGroupWorkItemNotifications',
  };

  @override
  AiCapability? find(String operationId) {
    if (!ids.contains(operationId)) return productionAiLedger.find(operationId);
    final t1 = operationId.startsWith('set');
    return AiCapability(
      operationId: operationId,
      modelVisible: visible,
      scopeClass: AiScopeClass.groupWorkItem,
      boundary: AiWriteBoundary.graph,
      baseTier: t1 ? AiWriteTier.t1 : AiWriteTier.t2,
      httpCap: 21,
      editableField: operationId == 'updateGroupWorkItemContent'
          ? 'description'
          : operationId == 'editGroupWorkItemActivityNote'
          ? 'body'
          : null,
      arguments: {
        'groupId': const AiArgSpec(AiArgType.integer, required: true),
        'iid': const AiArgSpec(AiArgType.integer, required: true),
        if (operationId == 'updateGroupWorkItemState')
          'stateEvent': const AiArgSpec(
            AiArgType.string,
            required: true,
            enumValues: ['close', 'reopen'],
          ),
        if (operationId == 'updateGroupWorkItemContent') ...{
          'description': const AiArgSpec(
            AiArgType.string,
            text: AiTextRole.quickActionMarkdown,
          ),
          'title': const AiArgSpec(
            AiArgType.string,
            text: AiTextRole.plainContent,
          ),
        },
        if (operationId == 'editGroupWorkItemActivityNote') ...{
          'noteId': const AiArgSpec(AiArgType.integer, required: true),
          'body': const AiArgSpec(
            AiArgType.string,
            required: true,
            text: AiTextRole.quickActionMarkdown,
          ),
        },
        if (operationId == 'updateGroupWorkItemLabels')
          'labels': const AiArgSpec(AiArgType.stringList, required: true),
        if (operationId == 'setGroupWorkItemActivityNoteReaction') ...{
          'noteId': const AiArgSpec(AiArgType.integer, required: true),
          'name': const AiArgSpec(AiArgType.string, required: true),
          'add': const AiArgSpec(AiArgType.boolean, required: true),
        },
        if (operationId == 'setGroupWorkItemNotifications')
          'enabled': const AiArgSpec(AiArgType.boolean, required: true),
      },
    );
  }

  @override
  List<AiCapability> get modelVisible =>
      visible ? [for (final id in ids) find(id)!] : const [];
}

/// A graph double, never a production group producer. The real port's group
/// parts remain inert. A live epoch predicate lets tests revoke an opening.
final class G0eGraphPort implements port.AiGitLabWritePort {
  G0eGraphPort(this.api);
  final Object api;
  int epoch = 0;
  int prepares = 0;
  int mutations = 0;
  bool live = true;
  bool supplyCurrentPredicate = true;
  bool? targetConfidential;
  ({int groupId, String groupFullPath, int iid, String workItemGid})?
  groupTodoTarget;
  void Function()? afterBeforeMutation;
  VerifiedGroupWorkItemIdentity Function(int epoch)? identityForEpoch;
  final currentFields = <String, String>{
    'title': 'Original',
    'description': 'Original body',
    'body': 'Original note',
    'labels': '[]',
  };
  final events = <String>[];
  port.AiWritePrepared? lastPrepared;
  port.AiWriteRequest? dispatched;

  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) async {
    prepares++;
    final openedEpoch = ++epoch;
    events.add('open:$openedEpoch');
    final identity =
        identityForEpoch?.call(openedEpoch) ??
        g0eIdentity(api, readEpoch: openedEpoch);
    return lastPrepared = port.AiWritePrepared.graph(
      request: request,
      owner: this,
      releaseName: '$g0ePath#5',
      groupIdentity: identity,
      targetConfidential: targetConfidential,
      groupTodoTarget: groupTodoTarget,
      groupIdentityIsCurrent: supplyCurrentPredicate
          ? () => live && epoch == openedEpoch
          : null,
      writeKeys: {
        const AiConflictKey([g0eAccount, 'groupId:7', 'workItem', '5']),
      },
      currentFields: currentFields,
      textBindingDigest: (_) => 'g0e-opening',
      textMutation: (hooks, boundRequest) async {
        dispatched = boundRequest;
        await hooks.beforeMutation();
        afterBeforeMutation?.call();
        events.add('start');
        if (!hooks.mayStart()) return const GraphWriteResult();
        events.add('send');
        mutations++;
        return const GraphWriteResult(
          mutationSent: true,
          acknowledged: true,
          readbackVerified: true,
        );
      },
    );
  }

  @override
  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) => prepared.commitGraph(mayStart: mayStart);
}

final class G0eHarness {
  G0eHarness._(this.base, this.api)
    : graph = G0eGraphPort(api),
      placeholders = text.UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
        accountKey: g0eAccount,
        conversationId: 'g0e-seams',
      );

  static Future<G0eHarness> create({
    G0eLedger ledger = const G0eLedger(),
  }) async {
    final harness = G0eHarness._(await Mr6b3Harness.create(), Object());
    harness.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: harness.scope,
        level: harness.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'g0e-synthetic',
        writePolicyRevision: 1,
        sessionGeneration: 7,
        appInForeground: true,
        ownerApi: harness.api,
        currentResource: harness.currentResource,
      ),
      createPort: () => harness.graph,
      journal: harness.base.journal,
      conversationId: 'g0e-seams',
      budget: () => harness.budget,
      readFreshness: (request) async {
        harness.freshnessReads++;
        return AiWriteFreshness(
          targetVisibility: harness.visibility,
          // Target confidentiality remains unknown until the opening.
          // Source evidence and accumulated pollution are independent.
          visibilityUnreadable: true,
          sourceVisibilityUnreadable: harness.sourceVisibilityUnreadable,
          polluted: harness.polluted,
          provenance: harness.priorProvenance,
        );
      },
      placeholders: harness.placeholders,
      knownSecrets: () => harness.secrets,
      safeDisplay: (value) => value,
      ledger: ledger,
    );
    harness.beginRun();
    return harness;
  }

  final Mr6b3Harness base;
  final Object api;
  final G0eGraphPort graph;
  final text.UploadPlaceholderTable placeholders;
  var budget = AiToolBudget(maxGitLabRequests: 40);
  late PolicyAiWriteCoordinator coordinator;
  AiWriteScope scope = g0eScope;
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;
  AiTargetRef currentResource = AiTargetRef(
    kind: AiTargetKind.groupWorkItem,
    groupId: 7,
    groupFullPath: g0ePath,
    iid: 5,
  );
  String? visibility = 'private';
  bool sourceVisibilityUnreadable = false;
  bool polluted = false;
  int freshnessReads = 0;
  Set<String> secrets = {};
  Map<String, text.AiFieldProvenance> priorProvenance = {};
  int calls = 0;

  void beginRun([String utterance = 'Update this group work item.']) {
    budget = AiToolBudget(maxGitLabRequests: 40);
    coordinator.beginRun(utterance);
    coordinator.beginTurn();
  }

  AiToolCall call(String operation, Map<String, Object?> arguments) =>
      AiToolCall(
        id: 'g0e-${calls++}',
        name: operation,
        arguments: {
          'groupId': 7,
          'iid': 5,
          ...arguments,
          'reason': 'Requested.',
        },
      );

  Future<void> dispose() async {
    coordinator.stop();
    await base.dispose();
  }
}
