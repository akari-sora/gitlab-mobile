import 'release_policy_support.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/exact_edit.dart' as exact;
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/graphql_write_classify.dart';
import 'package:gitlab_mobile/core/ai/tools/graphql_write_hooks.dart';
import 'package:gitlab_mobile/core/ai/tools/release_policy.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

const mr6b3Account = 'https://example.com/gitlab#7';
const mr6b3Conversation = 'mr6b3-graph-conversation';
const mr6b3Timeout = Duration(seconds: 20);
const mr6b3Scope = AiWriteScope(
  accountKey: mr6b3Account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.workItem,
      projectId: 9,
      projectPath: 'team/example-9',
      iid: 3,
    ),
  ],
);

const mr6b3WriteKey = AiConflictKey([
  mr6b3Account,
  'project:9',
  'workItem',
  '3',
]);

/// Deliberately independent of VisibleProductionLedger: graph rows and their
/// boundary must not be made visible by the MR6b-2 support shim (m2).
final class Mr6b3Ledger implements AiCapabilityLedger {
  const Mr6b3Ledger();

  static const state = AiCapability(
    operationId: 'updateWorkItemState',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    httpCap: 21,
    arguments: {
      'projectId': AiArgSpec(AiArgType.integer, required: true),
      'iid': AiArgSpec(AiArgType.integer, required: true),
      'stateEvent': AiArgSpec(
        AiArgType.string,
        required: true,
        enumValues: ['close', 'reopen'],
      ),
    },
  );

  static const assignees = AiCapability(
    operationId: 'updateWorkItemAssignees',
    baseTier: AiWriteTier.t2,
    scopeClass: AiScopeClass.workItem,
    boundary: AiWriteBoundary.graph,
    httpCap: 37,
    arguments: {
      'projectId': AiArgSpec(AiArgType.integer, required: true),
      'iid': AiArgSpec(AiArgType.integer, required: true),
      'assigneeUsernames': AiArgSpec(AiArgType.stringList, required: true),
    },
  );

  static const rows = <AiCapability>[state, assignees];

  @override
  AiCapability? find(String operationId) {
    for (final row in rows) {
      if (row.operationId == operationId) return row;
    }
    return null;
  }

  @override
  List<AiCapability> get modelVisible => rows;
}

enum Mr6b3MutationMode {
  noop,
  preflightRefused,
  hookReturnedResult,
  hookReturnedError,
  unawaitedBefore,
  accepted,
}

final class Mr6b3GraphPort implements port.AiGitLabWritePort {
  Mr6b3MutationMode mode = Mr6b3MutationMode.accepted;
  Object? acceptedValue = const GraphWriteResult(
    mutationSent: true,
    acknowledged: true,
    readbackVerified: true,
  );
  Object? acceptedError;
  void Function()? beforeBoundary;
  void Function()? afterBeforeMutation;
  int prepareCount = 0;
  int mutationCalls = 0;
  int sends = 0;
  final events = <String>[];

  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) async {
    prepareCount++;
    return port.AiWritePrepared.graph(
      request: request,
      releaseName: '#3',
      writeKeys: {mr6b3WriteKey},
      owner: this,
      bindingDigest: 'mr6b3-stable-binding',
      mutation: (hooks) => _mutate(request, hooks),
    );
  }

  Future<Object?> _mutate(port.AiWriteRequest request, GraphHooks hooks) async {
    mutationCalls++;
    events.add('entered:${request.operationId}');
    switch (mode) {
      case Mr6b3MutationMode.noop:
        events.add('noop');
        return const GraphWriteResult(noChange: true);
      case Mr6b3MutationMode.preflightRefused:
        events.add('preflightRefused');
        throw const port.AiWriteRefused('syntheticPreflight');
      case Mr6b3MutationMode.hookReturnedResult:
        beforeBoundary?.call();
        await hooks.beforeMutation();
        events.add('beforeReturned');
        return const GraphWriteResult();
      case Mr6b3MutationMode.hookReturnedError:
        beforeBoundary?.call();
        await hooks.beforeMutation();
        events.add('beforeReturned');
        throw StateError('syntheticAfterHookFailure');
      case Mr6b3MutationMode.unawaitedBefore:
        beforeBoundary?.call();
        unawaited(hooks.beforeMutation().catchError((Object _) {}));
        events.add('beforeUnawaited');
        return const GraphWriteResult();
      case Mr6b3MutationMode.accepted:
        beforeBoundary?.call();
        await hooks.beforeMutation();
        events.add('beforeReturned');
        afterBeforeMutation?.call();
        if (!hooks.mayStart()) {
          events.add('mayStartFalse');
          throw const port.AiWriteRefused('syntheticNotAccepted');
        }
        events.add('accepted');
        sends++;
        final error = acceptedError;
        if (error != null) throw error;
        return acceptedValue;
    }
  }

  @override
  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) => prepared.commitGraph(mayStart: mayStart);
}

final class Mr6b3JournalKeyStore extends MemoryAiJournalKeyStore {
  void Function()? onReadTombstone;
  bool failNextTombstone = false;

  @override
  Future<AiStoreRead<bool>> readTombstone(String accountKey) {
    final callback = onReadTombstone;
    onReadTombstone = null;
    callback?.call();
    if (failNextTombstone) {
      failNextTombstone = false;
      return Future.value(
        const AiStoreRead<bool>.unavailable(
          AiStoreFailure(AiStoreFailureKind.unavailable, 'readTombstone'),
        ),
      );
    }
    return super.readTombstone(accountKey);
  }
}

final class Mr6b3JournalFiles extends AiJournalFiles {
  Mr6b3JournalFiles(super.root);

  Completer<void>? _entered;
  Completer<void>? _release;
  int? _barrierWrite;
  bool _barrierAfterPersist = false;
  int writeCount = 0;
  int? failWriteNumber;

  Future<void> armBarrier({
    int writesBeforeBarrier = 0,
    bool afterPersist = false,
  }) {
    _entered = Completer<void>();
    _release = Completer<void>();
    _barrierWrite = writeCount + writesBeforeBarrier + 1;
    _barrierAfterPersist = afterPersist;
    return _entered!.future.timeout(mr6b3Timeout);
  }

  void releaseBarrier() {
    final release = _release;
    if (release != null && !release.isCompleted) release.complete();
  }

  @override
  Future<void> write(
    String account,
    Uint8List bytes, {
    required bool Function() mayCommit,
  }) async {
    writeCount++;
    final entered = _entered;
    final release = _release;
    final blocked =
        entered != null && !entered.isCompleted && writeCount == _barrierWrite;
    if (blocked && !_barrierAfterPersist) {
      entered.complete();
      await release!.future.timeout(mr6b3Timeout);
    }
    if (writeCount == failWriteNumber) {
      throw const FileSystemException('syntheticMr6b3JournalFailure');
    }
    await super.write(account, bytes, mayCommit: mayCommit);
    if (blocked && _barrierAfterPersist) {
      entered.complete();
      await release!.future.timeout(mr6b3Timeout);
    }
    if (blocked) {
      _entered = null;
      _release = null;
      _barrierWrite = null;
      _barrierAfterPersist = false;
    }
  }
}

final class Mr6b3Policy {
  AiAutonomyLevel level = AiAutonomyLevel.confirmEach;
  bool alive = true;
  bool consentValid = true;
  bool clientMayStart = true;
  int revision = 1;
}

final class Mr6b3Harness {
  Mr6b3Harness._({
    required this.root,
    required this.files,
    required this.keys,
    required this.journal,
    required this.port,
    required this.releasePolicy,
  });

  static Future<Mr6b3Harness> create({
    AiReleasePolicyView? releasePolicy,
  }) async {
    final root = Directory.systemTemp.createTempSync('mr6b3-dispatch-');
    final files = Mr6b3JournalFiles(root);
    final keys = Mr6b3JournalKeyStore();
    final journal = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      files: files,
      processId: 'mr6b3-dispatch',
    );
    await journal.recoverAfterAccountsLoaded([mr6b3Account]);
    await journal.ensureInitialized(mr6b3Account);
    final harness = Mr6b3Harness._(
      root: root,
      files: files,
      keys: keys,
      journal: journal,
      port: Mr6b3GraphPort(),
      releasePolicy: releasePolicy ?? fixtureReleasePolicy,
    );
    harness.coordinator = harness._newCoordinator();
    harness.beginRun();
    return harness;
  }

  final Directory root;
  final Mr6b3JournalFiles files;
  final Mr6b3JournalKeyStore keys;
  final AiWriteJournal journal;
  final Mr6b3GraphPort port;
  final AiReleasePolicyView releasePolicy;
  final Mr6b3Policy policy = Mr6b3Policy();
  String Function(String)? safeDisplay;
  DateTime clock = DateTime.utc(2026, 10, 23, 12);
  late AiToolBudget budget;
  late PolicyAiWriteCoordinator coordinator;
  int _callId = 0;

  PolicyAiWriteCoordinator _newCoordinator() => PolicyAiWriteCoordinator(
    releasePolicy: releasePolicy,
    snapshot: () => AiWritePolicySnapshot(
      appInForeground: true,
      scope: mr6b3Scope,
      level: policy.level,
      ceiling: AiAutonomyLevel.bypass,
      consentHash: 'mr6b3-consent',
      writePolicyRevision: policy.revision,
      scopeRevision: 1,
      sessionGeneration: 7,
      alive: policy.alive,
      consentValid: policy.consentValid,
      clientMayStart: policy.clientMayStart,
    ),
    createPort: () => port,
    journal: journal,
    conversationId: mr6b3Conversation,
    budget: () => budget,
    readFreshness: (_) async => const AiWriteFreshness(
      updatedAt: '2026-10-23T00:00:00Z',
      visibilityUnreadable: false,
    ),
    placeholders: text.UploadPlaceholderTable(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
    ),
    knownSecrets: () => const {},
    safeDisplay: (value) => safeDisplay?.call(value) ?? value,
    ledger: const Mr6b3Ledger(),
    checkFragments:
        (
          scan, {
          required knownSecrets,
          required instance,
          required visibility,
        }) {
          final result = exact.checkFragments(
            scan,
            knownSecrets: knownSecrets,
            instance: instance,
            visibility: visibility,
          );
          return (
            blockCode: result.blockCode,
            confirmReasons: result.confirmReasons,
          );
        },
    now: () => clock,
  );

  void beginRun() {
    budget = AiToolBudget(maxGitLabRequests: 40);
    coordinator.beginRun('Update issue #3 in team/example-9.');
    coordinator.beginTurn();
  }

  AiToolCall call(String operation, Map<String, Object?> arguments) =>
      AiToolCall(
        id: 'mr6b3-${_callId++}',
        name: operation,
        arguments: {...arguments, 'reason': 'synthetic MR6b3 request'},
      );

  Future<AiWriteProposal?> proposeState() => coordinator.propose(
    call('updateWorkItemState', const {
      'projectId': 9,
      'iid': 3,
      'stateEvent': 'close',
    }),
  );

  Future<AiWriteProposal?> proposeAssignees(Object? usernames) =>
      coordinator.propose(
        call('updateWorkItemAssignees', {
          'projectId': 9,
          'iid': 3,
          'assigneeUsernames': usernames,
        }),
      );

  Future<AiWriteOutcome> approve(AiWriteProposal proposal) => coordinator
      .approve(proposal, typedName: proposal.tier.typedName)
      .timeout(mr6b3Timeout);

  Future<void> seedConfirmMark() async {
    const execution = 'mr6b3-seed-mark';
    await journal.prepare(
      draft: AiJournalDraft(
        executionId: execution,
        accountKey: mr6b3Account,
        conversationId: 'mr6b3-seed',
        runId: 'mr6b3-seed-run',
        operationId: 'updateWorkItemState',
        writeKeys: {mr6b3WriteKey},
        payloadSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        releaseName: '#3',
      ),
    );
    await journal.markDispatching(executionId: execution);
    await journal.finish(
      executionId: execution,
      terminal: AiJournalState.writeUncertain,
    );
    await journal.releaseByUser(executionId: execution, typedName: '#3');
  }

  Future<Map<String, Object?>> readDurableJournal() =>
      AiHistoryCipher.decryptJson(
        File(files.pathFor(mr6b3Account)).readAsBytesSync(),
        keys.keys[mr6b3Account]!,
        mr6b3Account,
        AiJournalFiles.fileName,
      );

  Future<void> dispose() async {
    files.releaseBarrier();
    coordinator.stop('disposed');
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Object api401() => const ApiFailure(FailureKind.unauthenticated, status: 401);
