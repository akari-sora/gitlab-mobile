import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'ai_history_codec.dart';
import 'ai_journal_key_store.dart';
import 'ai_stores.dart';

enum AiJournalState {
  prepared,
  dispatching,
  succeeded,
  failedCertain,
  writeUncertain,
  notExecuted,
  resolvedByUser,
}

enum AiJournalKeyStatus {
  found,
  uninitialized,
  keyMissing,
  removed,
  unavailable,
  unknownFormat,
  overSize,
}

final class AiJournalException implements Exception {
  const AiJournalException(this.reason);
  final String reason;
  @override
  String toString() => 'AiJournalException($reason)';
}

/// The integration layer must use the same account fence as account cleanup.
/// The journal also serializes its own short transactions independently.
abstract interface class AiJournalAccountFence {
  Future<T> run<T>(String accountKey, Future<T> Function() action);
  bool isCleaning(String accountKey);
}

final class AiConflictKey {
  const AiConflictKey(this.parts);
  final List<String> parts;

  bool intersects(AiConflictKey other) {
    if (parts.isEmpty || other.parts.isEmpty) return false;
    final common = min(parts.length, other.parts.length);
    for (var i = 0; i < common; i++) {
      if (parts[i] != other.parts[i]) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is AiConflictKey && jsonEncode(parts) == jsonEncode(other.parts);
  @override
  int get hashCode => Object.hashAll(parts);
}

final class AiBudgetRequest {
  const AiBudgetRequest({
    required this.accountKey,
    required this.conversationId,
    required this.runId,
    this.tier4 = false,
    this.persistConversation = true,
    this.affectedResources = 1,
  });
  final String accountKey;
  final String conversationId;
  final String runId;
  final bool tier4;
  final bool persistConversation;
  final int affectedResources;

  Map<String, Object?> _json() => {
    'account': accountKey,
    'conversation': conversationId,
    'run': runId,
    'tier4': tier4,
    'persistent': persistConversation,
    'resources': affectedResources,
  };
}

final class AiBudgetHold {
  AiBudgetHold._(
    this.token,
    this.request,
    this._ownerEpoch,
    this._proposalEpoch,
  );
  final String token;
  final AiBudgetRequest request;
  final int _ownerEpoch;
  final int _proposalEpoch;
}

/// Only prevalidated, redacted metadata belongs here. There is intentionally no
/// payload, provider replay, attachment content, upload URL or schedule HMAC.
final class AiJournalDraft {
  AiJournalDraft({
    required this.executionId,
    required this.accountKey,
    required this.conversationId,
    required this.runId,
    required this.operationId,
    required Set<AiConflictKey> writeKeys,
    Set<AiConflictKey> dependencyKeys = const {},
    required this.payloadSha256,
    required this.releaseName,
    this.instance = '',
    this.sessionGeneration = 0,
    this.normalizedTarget = '',
    this.lastCommitId,
    this.headSha,
    this.updatedAt,
    this.mergeCheckSummary,
    this.policyRevision = 0,
    this.summary = '',
    this.tier4 = false,
    this.persistConversation = true,
    this.affectedResources = 1,
    this.budgetHold,
    this.confirmed = false,
    this.bypass = false,
  }) : writeKeys = _freezeKeys(writeKeys),
       dependencyKeys = _freezeKeys(dependencyKeys);

  final String executionId;
  final String accountKey;
  final String conversationId;
  final String runId;
  final String operationId;
  final Set<AiConflictKey> writeKeys;
  final Set<AiConflictKey> dependencyKeys;
  final String payloadSha256;
  final String releaseName;
  final String instance;
  final int sessionGeneration;
  final String normalizedTarget;
  final String? lastCommitId;
  final String? headSha;
  final String? updatedAt;
  final String? mergeCheckSummary;
  final int policyRevision;
  final String summary;
  final bool tier4;
  final bool persistConversation;
  final int affectedResources;
  final AiBudgetHold? budgetHold;
  final bool confirmed;
  final bool bypass;

  AiBudgetRequest get _request => AiBudgetRequest(
    accountKey: accountKey,
    conversationId: conversationId,
    runId: runId,
    tier4: tier4,
    persistConversation: persistConversation,
    affectedResources: affectedResources,
  );
}

final class AiJournalEntry {
  AiJournalEntry._(Map<String, Object?> json)
    : _data = Map.unmodifiable(json),
      writeKeys = _keys(json['writes']),
      dependencyKeys = _keys(json['dependencies']);
  final Map<String, Object?> _data;
  String get executionId => _data['execution']! as String;
  String get processId => _data['process']! as String;
  String get accountKey => _data['account']! as String;
  String get conversationId => _data['conversation']! as String;
  String get runId => _data['run']! as String;
  String get operationId => _data['operation']! as String;
  final Set<AiConflictKey> writeKeys;
  final Set<AiConflictKey> dependencyKeys;
  String get payloadSha256 => _data['payloadSha256']! as String;
  String get releaseName => _data['releaseName']! as String;
  AiJournalState get state =>
      AiJournalState.values.byName(_data['state']! as String);
  int get sequence => _data['sequence']! as int;
  DateTime? get dispatchedAt => _dateOrNull(_data['dispatchedAt']);
  String? get observation => _data['observation'] as String?;
  Set<AiConflictKey> get _allKeys => {...writeKeys, ...dependencyKeys};
  bool get _isolates =>
      state == AiJournalState.dispatching ||
      state == AiJournalState.writeUncertain;
  AiBudgetRequest get _request => _requestFromJson(_object(_data['budget']));

  AiJournalEntry _change(Map<String, Object?> values) =>
      AiJournalEntry._({..._data, ...values});
}

final class AiJournalMutation {
  const AiJournalMutation({
    required this.entry,
    this.budgetRefunded = false,
    this.confirmMarkRestored = false,
  });
  final AiJournalEntry entry;
  final bool budgetRefunded;
  final bool confirmMarkRestored;
}

final class AiJournalReset {
  AiJournalReset._(
    this.accountKey,
    this.token,
    this._epoch,
    this._proposalEpoch,
    this.verifiedUsername,
  );
  final String accountKey;
  final String token;
  final int _epoch;
  final int _proposalEpoch;
  final String? verifiedUsername;
}

final class AiRemovalJob {
  AiRemovalJob._(this._owner, this.accountKey, this.token);
  final AiWriteJournal _owner;
  final String accountKey;
  final String token;
  final Completer<void> _cancelSignal = Completer<void>();
  bool _finalConfirmed = false;
  bool get cancelRequestedBeforeFinalConfirm =>
      !_finalConfirmed && _cancelSignal.isCompleted;
  Future<void> get cancellation => _cancelSignal.future;
  void requestCancel() {
    if (!_finalConfirmed && !_cancelSignal.isCompleted) {
      _cancelSignal.complete();
    }
  }

  bool holds(String token) =>
      token == this.token && identical(_owner._removals[accountKey], this);
  void confirmFinal() {
    if (!holds(token) || cancelRequestedBeforeFinalConfirm) {
      throw const AiJournalException('removalCancelled');
    }
    if (_finalConfirmed) return;
    _finalConfirmed = true;
    _owner.bumpProposalEpoch(accountKey);
  }

  /// Use for the final dialog's cancel branch, synchronously invalidating old
  /// approvals and releasing this hold. Stop-dialog cancellation uses release.
  void cancelFinal() {
    if (!holds(token) || _finalConfirmed) return;
    _owner.bumpProposalEpoch(accountKey);
    requestCancel();
    release(token);
  }

  void release(String token) {
    if (holds(token)) _owner._removals.remove(accountKey);
  }
}

final class AiWriteJournal {
  AiWriteJournal._();
  static final AiWriteJournal instance = AiWriteJournal._();

  /// Isolated owners are for tests and host integration before singleton setup.
  AiWriteJournal({
    required AiJournalKeyStore keys,
    required Directory applicationSupport,
    AiJournalAccountFence? fence,
    AiJournalFiles? files,
    String? processId,
  }) : _keysStore = keys,
       _files = files ?? AiJournalFiles(applicationSupport),
       _fence = fence {
    if (processId != null) _processId = processId;
  }

  static const ciphertextLimit = 1024 * 1024;
  static const maxEntries = 200;
  static const maxConversations = 2000;
  static const resetConfirmationDuration = Duration(hours: 24);
  String _processId = _randomId();
  String get processId => _processId;
  DateTime Function()? now;
  AiJournalKeyStore? _keysStore;
  AiJournalFiles? _files;
  AiJournalAccountFence? _fence;
  final Map<String, _Account> _accounts = {};
  final Map<String, String> _executionAccounts = {};
  final Map<String, AiRemovalJob> _removals = {};
  final Map<String, AiJournalReset> _resets = {};
  final Map<String, Future<void>> _tails = {};
  final Map<String, AiBudgetHold> _holds = {};
  final Set<String> _seenExecutions = {};
  final Map<String, AiJournalEntry> _retiredExecutions = {};
  final Map<String, AiJournalEntry> _lateAudit = {};
  List<AiJournalEntry> get lateAudit => List.unmodifiable(_lateAudit.values);

  /// No memory-key fallback: production cannot write until explicitly wired.
  void configure({
    required AiJournalKeyStore keys,
    required Directory applicationSupport,
    required AiJournalAccountFence fence,
  }) {
    if (_keysStore != null) throw const AiJournalException('alreadyConfigured');
    _keysStore = keys;
    _files = AiJournalFiles(applicationSupport);
    _fence = fence;
  }

  _Account _account(String key) => _accounts.putIfAbsent(key, _Account.new);
  DateTime get _now => (now?.call() ?? DateTime.now()).toUtc();
  AiJournalKeyStore get _store =>
      _keysStore ?? (throw const AiJournalException('notConfigured'));
  AiJournalFiles get _disk =>
      _files ?? (throw const AiJournalException('notConfigured'));
  int proposalEpoch(String accountKey) => _account(accountKey).proposalEpoch;
  void bumpProposalEpoch(String accountKey) {
    _account(accountKey).proposalEpoch++;
    _holds.removeWhere((_, hold) => hold.request.accountKey == accountKey);
  }

  bool tombstoneFlag(String accountKey) =>
      _account(accountKey).tombstone ||
      _account(accountKey).tombstoneReadUnavailable;
  void noteTombstoneSet(String accountKey) =>
      _account(accountKey).tombstone = true;
  void noteTombstoneCleared(String accountKey) {
    _account(accountKey).tombstone = false;
    _account(accountKey).tombstoneReadUnavailable = false;
  }

  bool removalHeld(String accountKey) => _removals.containsKey(accountKey);
  bool recovered(String accountKey) => _account(accountKey).recovered;
  AiJournalKeyStatus? recoveryStatus(String accountKey) =>
      _account(accountKey).status;
  List<AiJournalEntry> entries(String accountKey) =>
      List.unmodifiable(_account(accountKey).data.entries.values);
  int conversationWriteCount(String accountKey, String conversationId) =>
      (_account(accountKey).data.counts[conversationId]?.writes ?? 0) +
      (_account(accountKey).ephemeral[conversationId]?.writes ?? 0);
  int getConversationCount(String accountKey) =>
      _account(accountKey).data.counts.length;

  Future<T> _locked<T>(String account, Future<T> Function() action) {
    final prior = _tails[account] ?? Future<void>.value();
    final run = prior.then(
      (_) => _fence == null ? action() : _fence!.run(account, action),
    );
    final tail = run.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _tails[account] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_tails[account], tail)) _tails.remove(account);
      }),
    );
    return run;
  }

  Future<bool> _tombstone(String account) async {
    try {
      final read = await _store.readTombstone(account);
      if (read.failure != null ||
          read.status == AiStoreReadStatus.unavailable) {
        _account(account).tombstoneReadUnavailable = true;
        throw const AiJournalException('unavailable');
      }
      _account(account).tombstoneReadUnavailable = false;
      if (read.value == true) noteTombstoneSet(account);
      return tombstoneFlag(account);
    } on AiJournalException {
      rethrow;
    } on Object {
      _account(account).tombstoneReadUnavailable = true;
      throw const AiJournalException('unavailable');
    }
  }

  Future<AiJournalKeyStatus> keyStatus(String accountKey) =>
      _locked(accountKey, () => _load(accountKey));

  Future<AiJournalKeyStatus> _load(String account) async {
    final owner = _account(account);
    AiJournalKeyStatus status;
    try {
      final tombstone = await _tombstone(account);
      final marker = await _store.readResetPending(account);
      final key = await _store.readKey(account);
      if (marker.failure != null ||
          key.failure != null ||
          marker.status == AiStoreReadStatus.unavailable ||
          key.status == AiStoreReadStatus.unavailable) {
        status = AiJournalKeyStatus.unavailable;
      } else if (marker.status == AiStoreReadStatus.found) {
        status = AiJournalKeyStatus.unknownFormat;
      } else if (key.status == AiStoreReadStatus.absent) {
        status = await _disk.exists(account)
            ? AiJournalKeyStatus.keyMissing
            : tombstone
            ? AiJournalKeyStatus.removed
            : AiJournalKeyStatus.uninitialized;
      } else if (key.value?.length != 32) {
        status = AiJournalKeyStatus.unknownFormat;
      } else {
        final bytes = await _disk.read(account);
        final data = bytes == null
            ? _Snapshot()
            : _Snapshot.decode(
                await AiHistoryCipher.decryptJson(
                  bytes,
                  key.value!,
                  account,
                  AiJournalFiles.fileName,
                  maxPlaintextBytes: ciphertextLimit,
                ),
                account,
              );
        // A failed terminal write is uncertain in memory even if disk still
        // says dispatching. A fresh read must never erase that overlay.
        for (final id in owner.uncertain) {
          final entry = data.entries[id];
          if (entry?.state == AiJournalState.dispatching) {
            data.entries[id] = entry!._change({'state': 'writeUncertain'});
          }
        }
        owner.data = data;
        owner.key = Uint8List.fromList(key.value!);
        for (final entry in data.entries.values) {
          final existing = _executionAccounts[entry.executionId];
          if (existing != null && existing != account) {
            throw const FormatException();
          }
          _executionAccounts[entry.executionId] = account;
          _seenExecutions.add(entry.executionId);
        }
        status = AiJournalKeyStatus.found;
      }
    } on _OverSize {
      status = AiJournalKeyStatus.overSize;
    } on FileSystemException {
      status = AiJournalKeyStatus.unavailable;
    } on AiJournalException catch (error) {
      status = error.reason == 'unavailable'
          ? AiJournalKeyStatus.unavailable
          : AiJournalKeyStatus.unknownFormat;
    } on Object {
      status = AiJournalKeyStatus.unknownFormat;
    }
    owner.status = status;
    return status;
  }

  Future<void> ensureInitialized(String accountKey) =>
      _locked(accountKey, () async {
        _gate(accountKey, requireRecovered: false);
        if (await _load(accountKey) != AiJournalKeyStatus.uninitialized) {
          throw const AiJournalException('notUninitialized');
        }
        await _initialize(accountKey);
      });

  Future<void> _initialize(String accountKey) async {
    final owner = _account(accountKey);
    final epoch = owner.ownerEpoch;
    final key = Uint8List.fromList(AiHistoryCipher.newKey());
    await _store.writeKey(accountKey, key);
    final readback = await _store.readKey(accountKey);
    if (readback.failure != null ||
        readback.value == null ||
        !_sameBytes(key, readback.value!)) {
      throw const AiJournalException('unavailable');
    }
    owner.key = key;
    await _save(
      accountKey,
      _Snapshot(),
      epoch: epoch,
      allowNew: true,
      mayCommit: () => _canStart(accountKey),
    );
    owner.status = AiJournalKeyStatus.found;
  }

  void _gate(String account, {bool requireRecovered = true}) {
    if (requireRecovered && !_account(account).recovered) {
      throw const AiJournalException('recoveryPending');
    }
    if (!_canStart(account)) throw const AiJournalException('accountBlocked');
  }

  bool _canStart(String account) =>
      !tombstoneFlag(account) &&
      !_removals.containsKey(account) &&
      !_resets.containsKey(account) &&
      !(_fence?.isCleaning(account) ?? false);

  Future<_Snapshot> _ready(String account) async {
    _gate(account);
    final status = await _load(account);
    if (status == AiJournalKeyStatus.uninitialized) {
      await _initialize(account);
    } else if (status != AiJournalKeyStatus.found) {
      throw AiJournalException(_account(account).status!.name);
    }
    _gate(account);
    return _account(account).data.copy();
  }

  Future<void> _save(
    String account,
    _Snapshot data, {
    required int epoch,
    bool allowNew = false,
    bool Function()? mayCommit,
  }) async {
    _prune(data);
    if (data.entries.length > maxEntries ||
        data.counts.length > maxConversations) {
      throw const AiJournalException('storageLimit');
    }
    final owner = _account(account);
    final key = owner.key ?? (throw const AiJournalException('keyMissing'));
    final json = data.json();
    if (utf8.encode(jsonEncode(json)).length + 29 > ciphertextLimit) {
      throw const AiJournalException('storageLimit');
    }
    final encrypted = await AiHistoryCipher.encryptJson(
      json,
      key,
      account,
      AiJournalFiles.fileName,
    );
    if (encrypted.length > ciphertextLimit) {
      throw const AiJournalException('storageLimit');
    }
    await _disk.write(
      account,
      encrypted,
      mayCommit: () =>
          owner.ownerEpoch == epoch &&
          (allowNew || !owner.deleted) &&
          (mayCommit?.call() ?? true),
    );
    owner.data = data;
    owner.deleted = false;
  }

  Future<AiBudgetHold?> tryReserve(AiBudgetRequest request) =>
      _locked(request.accountKey, () async {
        final data = await _ready(request.accountKey);
        _prune(data);
        if (!_budgetAllows(data, request)) return null;
        final owner = _account(request.accountKey);
        final hold = AiBudgetHold._(
          _randomId(),
          request,
          owner.ownerEpoch,
          owner.proposalEpoch,
        );
        _holds[hold.token] = hold;
        return hold;
      });

  Future<void> refund(AiBudgetHold hold) =>
      _locked(hold.request.accountKey, () async {
        if (!identical(_holds[hold.token], hold)) return;
        if (_account(hold.request.accountKey).data.entries.values.any(
          (entry) => entry._data['hold'] == hold.token,
        )) {
          throw const AiJournalException('holdAttached');
        }
        _holds.remove(hold.token);
      });

  bool _budgetAllows(
    _Snapshot data,
    AiBudgetRequest request, {
    String? excludingHold,
  }) {
    if (request.accountKey.isEmpty ||
        request.conversationId.isEmpty ||
        request.runId.isEmpty ||
        request.affectedResources < 1 ||
        request.affectedResources > 20) {
      return false;
    }
    final owner = _account(request.accountKey);
    final pending = <AiBudgetRequest>[
      for (final entry in data.entries.values)
        if (entry.state == AiJournalState.prepared) entry._request,
      for (final hold in _holds.values)
        if (hold.request.accountKey == request.accountKey &&
            hold.token != excludingHold)
          hold.request,
    ];
    final recent = data.entries.values.where(
      (entry) =>
          entry.dispatchedAt != null &&
          entry.state != AiJournalState.notExecuted &&
          !entry.dispatchedAt!.isBefore(
            _now.subtract(const Duration(minutes: 60)),
          ),
    );
    final persisted = data.counts[request.conversationId];
    final transient = owner.ephemeral[request.conversationId];
    final conversation = _Count(
      (persisted?.writes ?? 0) + (transient?.writes ?? 0),
      (persisted?.tier4 ?? 0) + (transient?.tier4 ?? 0),
      _now,
    );
    final runEntries = data.entries.values.where(
      (entry) =>
          entry.runId == request.runId &&
          entry.dispatchedAt != null &&
          entry.state != AiJournalState.notExecuted,
    );
    final inMemoryRun = owner.runs[request.runId];
    final run = _Count(
      max(inMemoryRun?.writes ?? 0, runEntries.length),
      max(
        inMemoryRun?.tier4 ?? 0,
        runEntries.where((entry) => entry._request.tier4).length,
      ),
      _now,
    );
    int held(bool Function(AiBudgetRequest) test) => pending.where(test).length;
    bool cap(int used, int reservations, int limit) =>
        used + reservations < limit;
    return cap(recent.length, pending.length, 60) &&
        (!request.tier4 ||
            cap(
              recent.where((entry) => entry._request.tier4).length,
              held((r) => r.tier4),
              10,
            )) &&
        cap(
          conversation.writes,
          held((r) => r.conversationId == request.conversationId),
          40,
        ) &&
        (!request.tier4 ||
            cap(
              conversation.tier4,
              held(
                (r) => r.conversationId == request.conversationId && r.tier4,
              ),
              10,
            )) &&
        cap(run.writes, held((r) => r.runId == request.runId), 8) &&
        (!request.tier4 ||
            cap(
              run.tier4,
              held((r) => r.runId == request.runId && r.tier4),
              3,
            )) &&
        data.counts.length +
                {
                  for (final pendingRequest in pending)
                    if (pendingRequest.persistConversation &&
                        !data.counts.containsKey(pendingRequest.conversationId))
                      pendingRequest.conversationId,
                  if (request.persistConversation &&
                      !data.counts.containsKey(request.conversationId))
                    request.conversationId,
                }.length <=
            maxConversations;
  }

  Future<AiJournalMutation> prepare({required AiJournalDraft draft}) =>
      _locked(draft.accountKey, () async {
        final data = await _ready(draft.accountKey);
        final owner = _account(draft.accountKey);
        final epoch = owner.ownerEpoch;
        final proposal = owner.proposalEpoch;
        _validateDraft(draft);
        if (_seenExecutions.contains(draft.executionId)) {
          throw const AiJournalException('duplicateExecution');
        }
        if (_isolated(data, {...draft.writeKeys, ...draft.dependencyKeys})) {
          throw const AiJournalException('isolated');
        }
        if (_needsConfirmation(data, {
              ...draft.writeKeys,
              ...draft.dependencyKeys,
            }) &&
            !draft.confirmed &&
            !draft.bypass) {
          throw const AiJournalException('confirmationRequired');
        }
        final hold = draft.budgetHold;
        if (hold != null &&
            (!identical(_holds[hold.token], hold) ||
                hold._ownerEpoch != epoch ||
                hold._proposalEpoch != proposal ||
                jsonEncode(hold.request._json()) !=
                    jsonEncode(draft._request._json()))) {
          throw const AiJournalException('invalidHold');
        }
        _prune(data);
        if (!_budgetAllows(data, draft._request, excludingHold: hold?.token)) {
          throw const AiJournalException('budgetExceeded');
        }
        final entry = AiJournalEntry._({
          'execution': draft.executionId,
          'process': processId,
          'account': draft.accountKey,
          'conversation': draft.conversationId,
          'run': draft.runId,
          'operation': draft.operationId,
          'writes': _keysJson(draft.writeKeys),
          'dependencies': _keysJson(draft.dependencyKeys),
          'payloadSha256': draft.payloadSha256,
          'releaseName': draft.releaseName,
          'instance': draft.instance,
          'generation': draft.sessionGeneration,
          'target': draft.normalizedTarget,
          'last_commit_id': draft.lastCommitId,
          'headSha': draft.headSha,
          'updated_at': draft.updatedAt,
          'mergeCheckSummary': draft.mergeCheckSummary,
          'policyRevision': draft.policyRevision,
          'summary': draft.summary,
          'state': 'prepared',
          'sequence': ++data.sequence,
          'createdAt': _now.toIso8601String(),
          'dispatchedAt': null,
          'observation': null,
          'budget': draft._request._json(),
          'hold': hold?.token,
          'consumedMarks': <Object?>[],
          'confirmed': draft.confirmed,
          'bypass': draft.bypass,
          'ownerEpoch': epoch,
          'proposalEpoch': proposal,
        });
        data.entries[entry.executionId] = entry;
        await _save(
          draft.accountKey,
          data,
          epoch: epoch,
          mayCommit: () =>
              _canStart(draft.accountKey) && owner.proposalEpoch == proposal,
        );
        if (hold != null) _holds.remove(hold.token);
        _executionAccounts[entry.executionId] = draft.accountKey;
        _seenExecutions.add(entry.executionId);
        return AiJournalMutation(entry: entry);
      });

  Future<AiJournalMutation> markDispatching({
    required String executionId,
  }) => _mutateEntry(executionId, (account, data, entry) async {
    _gate(account);
    if (await _tombstone(account)) {
      throw const AiJournalException('accountBlocked');
    }
    _gate(account);
    if (entry.processId != processId ||
        entry.state != AiJournalState.prepared ||
        entry._data['ownerEpoch'] != _account(account).ownerEpoch ||
        entry._data['proposalEpoch'] != proposalEpoch(account)) {
      throw const AiJournalException('invalidTransition');
    }
    if (_isolated(data, entry._allKeys, excluding: executionId)) {
      throw const AiJournalException('isolated');
    }
    if (_needsConfirmation(data, entry._allKeys) &&
        entry._data['confirmed'] != true &&
        entry._data['bypass'] != true) {
      throw const AiJournalException('confirmationRequired');
    }
    final consumed = data.marks
        .where((mark) => entry._allKeys.any(mark.intersects))
        .toSet();
    data.marks.removeAll(consumed);
    final result = entry._change({
      'state': 'dispatching',
      'dispatchedAt': _now.toIso8601String(),
      'consumedMarks': _keysJson(consumed),
    });
    data.entries[executionId] = result;
    if (entry._request.persistConversation) {
      _increment(data.counts, entry.conversationId, entry._request.tier4, 1);
    }
    await _save(
      account,
      data,
      epoch: _account(account).ownerEpoch,
      mayCommit: () =>
          _canStart(account) &&
          entry._data['proposalEpoch'] == proposalEpoch(account),
    );
    if (!entry._request.persistConversation) {
      _increment(
        _account(account).ephemeral,
        entry.conversationId,
        entry._request.tier4,
        1,
      );
    }
    _increment(_account(account).runs, entry.runId, entry._request.tier4, 1);
    return AiJournalMutation(entry: result);
  });

  Future<AiJournalMutation> finish({
    required String executionId,
    required AiJournalState terminal,
  }) async {
    try {
      return await _mutateEntry(executionId, (account, data, entry) async {
        final prepared = entry.state == AiJournalState.prepared;
        if (!prepared &&
            entry.processId == processId &&
            entry._data['ownerEpoch'] != _account(account).ownerEpoch) {
          throw const AiJournalException('staleOwner');
        }
        if (!(prepared && terminal == AiJournalState.notExecuted) &&
            !(entry.state == AiJournalState.dispatching &&
                const {
                  AiJournalState.succeeded,
                  AiJournalState.failedCertain,
                  AiJournalState.writeUncertain,
                }.contains(terminal))) {
          throw const AiJournalException('invalidTransition');
        }
        final result = entry._change({'state': terminal.name});
        data.entries[executionId] = result;
        try {
          await _save(account, data, epoch: _account(account).ownerEpoch);
        } on Object {
          if (!prepared) {
            _account(account).uncertain.add(executionId);
            _account(account).data.entries[executionId] = entry._change({
              'state': 'writeUncertain',
            });
          }
          rethrow;
        }
        return AiJournalMutation(entry: result, budgetRefunded: prepared);
      });
    } on AiJournalException catch (error) {
      final retired = _retiredExecutions[executionId];
      if (retired != null &&
          (error.reason == 'staleOwner' ||
              error.reason == 'unknownExecution')) {
        _lateAudit[executionId] = retired._change({'state': 'writeUncertain'});
      }
      rethrow;
    }
  }

  Future<AiJournalMutation> revertDispatchingToNotExecuted({
    required String executionId,
  }) => _mutateEntry(executionId, (account, data, entry) async {
    if (entry.processId != processId ||
        entry._data['ownerEpoch'] != _account(account).ownerEpoch ||
        entry.state != AiJournalState.dispatching) {
      throw const AiJournalException('invalidTransition');
    }
    final marks = _keys(entry._data['consumedMarks']);
    data.marks.addAll(marks);
    final result = entry._change({
      'state': 'notExecuted',
      'consumedMarks': <Object?>[],
    });
    data.entries[executionId] = result;
    if (entry._request.persistConversation) {
      _increment(data.counts, entry.conversationId, entry._request.tier4, -1);
    }
    await _save(account, data, epoch: _account(account).ownerEpoch);
    if (!entry._request.persistConversation) {
      _increment(
        _account(account).ephemeral,
        entry.conversationId,
        entry._request.tier4,
        -1,
      );
    }
    _increment(_account(account).runs, entry.runId, entry._request.tier4, -1);
    return AiJournalMutation(
      entry: result,
      budgetRefunded: true,
      confirmMarkRestored: marks.isNotEmpty,
    );
  });

  Future<T> _mutateEntry<T>(
    String executionId,
    Future<T> Function(String, _Snapshot, AiJournalEntry) mutate,
  ) {
    final account = _executionAccounts[executionId];
    if (account == null) {
      return Future.error(const AiJournalException('unknownExecution'));
    }
    final requestedEpoch = _account(account).ownerEpoch;
    return _locked(account, () async {
      final owner = _account(account);
      if (requestedEpoch != owner.ownerEpoch ||
          owner.deleted ||
          _resets.containsKey(account)) {
        throw const AiJournalException('staleOwner');
      }
      if (await _load(account) != AiJournalKeyStatus.found) {
        throw AiJournalException(owner.status!.name);
      }
      final entry = owner.data.entries[executionId];
      if (entry == null) {
        throw const AiJournalException('staleOwner');
      }
      return mutate(account, owner.data.copy(), entry);
    });
  }

  bool isolated(String accountKey, Set<AiConflictKey> keys) {
    final owner = _account(accountKey);
    if (!owner.recovered ||
        owner.status != AiJournalKeyStatus.found ||
        !_canStart(accountKey)) {
      return true;
    }
    return _isolated(owner.data, keys);
  }

  bool _isolated(
    _Snapshot data,
    Set<AiConflictKey> keys, {
    String? excluding,
  }) => data.entries.values.any(
    (entry) =>
        entry.executionId != excluding &&
        entry._isolates &&
        entry._allKeys.any((lock) => keys.any(lock.intersects)),
  );
  bool requiresConfirmation(String accountKey, Set<AiConflictKey> keys) =>
      _needsConfirmation(_account(accountKey).data, keys);
  bool _needsConfirmation(_Snapshot data, Set<AiConflictKey> keys) =>
      (data.resetUntil != null && _now.isBefore(data.resetUntil!)) ||
      data.marks.any((mark) => keys.any(mark.intersects));
  bool recentlyReset(String accountKey) =>
      _account(accountKey).data.resetUntil?.isAfter(_now) ?? false;

  Future<void> recordObservation({
    required String executionId,
    required String summary,
  }) => _mutateEntry(executionId, (account, data, entry) async {
    if (entry.state != AiJournalState.writeUncertain) {
      throw const AiJournalException('invalidTransition');
    }
    _metadata(summary, 4096);
    data.entries[executionId] = entry._change({'observation': summary});
    await _save(account, data, epoch: _account(account).ownerEpoch);
  });

  Future<void> releaseByUser({
    required String executionId,
    required String typedName,
  }) => _mutateEntry(executionId, (account, data, entry) async {
    if (entry.state != AiJournalState.writeUncertain ||
        typedName != entry.releaseName) {
      throw const AiJournalException('confirmationRequired');
    }
    data.entries[executionId] = entry._change({'state': 'resolvedByUser'});
    data.marks.addAll(entry._allKeys);
    await _save(account, data, epoch: _account(account).ownerEpoch);
    _account(account).uncertain.remove(executionId);
  });

  /// Updates an existing counter only; proposals and zero-write conversations
  /// never allocate rows. Call on writable-segment sends, at most once a day.
  Future<void> touchConversation(String accountKey, String conversationId) =>
      _locked(accountKey, () async {
        final data = await _ready(accountKey);
        final count = data.counts[conversationId];
        if (count == null ||
            _now.difference(count.lastUsed) < const Duration(days: 1)) {
          return;
        }
        data.counts[conversationId] = _Count(count.writes, count.tier4, _now);
        await _save(accountKey, data, epoch: _account(accountKey).ownerEpoch);
      });

  Future<void> recoverAfterAccountsLoaded(Iterable<String> accountKeys) async {
    final accounts = accountKeys.toSet();
    for (final account in accounts) {
      _account(account).recovered = false;
    }
    final inventory = await _store.inventoryAccounts();
    final orphanHashes = await _disk.accountHashes();
    for (final account in accounts) {
      await _locked(account, () async {
        final owner = _account(account);
        owner.recovered = false;
        try {
          if (await _tombstone(account)) {
            await _load(account);
            // Cleanup itself is owned by the host tombstone pipeline. This
            // owner never silently clears the account's durable tombstone.
            return;
          }
          final marker = await _store.readResetPending(account);
          if (marker.failure != null ||
              marker.status == AiStoreReadStatus.unavailable) {
            owner.status = AiJournalKeyStatus.unavailable;
            return;
          }
          if (marker.value != null) {
            await _resumeReset(account, marker.value!);
            _resets.remove(account);
          }
          await _disk.cleanupTemporary(account);
          final status = await _load(account);
          if (status == AiJournalKeyStatus.uninitialized) {
            owner.recovered = true;
            return;
          }
          if (status != AiJournalKeyStatus.found) return;
          final data = owner.data.copy();
          var changed = false;
          for (final entry in List.of(data.entries.values)) {
            if (entry.processId == processId) continue;
            if (entry.state == AiJournalState.prepared ||
                entry.state == AiJournalState.dispatching) {
              changed = true;
              data.entries[entry.executionId] = entry._change({
                'state': entry.state == AiJournalState.prepared
                    ? 'notExecuted'
                    : 'writeUncertain',
              });
            }
          }
          if (changed) await _save(account, data, epoch: owner.ownerEpoch);
          owner.recovered = true;
        } on Object {
          owner.status = AiJournalKeyStatus.unavailable;
        }
      });
      orphanHashes.remove(AiJournalFiles.accountHash(account));
    }
    for (final orphan in inventory.difference(accounts)) {
      await _locked(orphan, () async {
        await _deleteJournal(orphan);
        await _store.deleteResetPending(orphan);
      });
      orphanHashes.remove(AiJournalFiles.accountHash(orphan));
    }
    for (final hash in orphanHashes) {
      await _disk.deleteHash(hash);
    }
  }

  Future<AiJournalReset> beginReset(
    String accountKey, {
    String? verifiedUsername,
  }) async {
    if (_removals.containsKey(accountKey) ||
        _resets.containsKey(accountKey) ||
        tombstoneFlag(accountKey) ||
        (_fence?.isCleaning(accountKey) ?? false)) {
      throw const AiJournalException('accountBlocked');
    }
    final owner = _account(accountKey);
    for (final entry in owner.data.entries.values) {
      if (entry.state == AiJournalState.dispatching) {
        owner.uncertain.add(entry.executionId);
        _retiredExecutions[entry.executionId] = entry;
      }
    }
    owner.ownerEpoch++;
    bumpProposalEpoch(accountKey);
    final reset = AiJournalReset._(
      accountKey,
      _randomId(),
      owner.ownerEpoch,
      owner.proposalEpoch,
      verifiedUsername,
    );
    _resets[accountKey] = reset;
    _holds.removeWhere((_, hold) => hold.request.accountKey == accountKey);
    return reset;
  }

  /// UI must have verified foreground/current-account identity and generation.
  /// Passing verifiedUsername to beginReset additionally binds the raw name.
  Future<void> completeReset(
    AiJournalReset reset, {
    required String typedUsername,
  }) => _locked(reset.accountKey, () async {
    final account = reset.accountKey;
    if (!identical(_resets[account], reset) ||
        _account(account).ownerEpoch != reset._epoch ||
        proposalEpoch(account) != reset._proposalEpoch ||
        !RegExp(r'^@[^\s@]+$').hasMatch(typedUsername) ||
        (reset.verifiedUsername != null &&
            typedUsername != reset.verifiedUsername)) {
      throw const AiJournalException('confirmationRequired');
    }
    if (_removals.containsKey(account) || await _tombstone(account)) {
      throw const AiJournalException('accountBlocked');
    }
    final confirmedAt = _now;
    // Nothing is deleted unless this durable write succeeds.
    await _store.writeResetPending(account, confirmedAt);
    await _resumeReset(account, confirmedAt);
    _account(account).recovered = true;
    _resets.remove(account);
  });

  void cancelReset(AiJournalReset reset) {
    if (identical(_resets[reset.accountKey], reset)) {
      _resets.remove(reset.accountKey);
    }
  }

  Future<void> _resumeReset(String account, DateTime confirmedAt) async {
    final owner = _account(account);
    owner.ownerEpoch++;
    owner.recovered = false;
    await _disk.delete(account);
    owner.deleted = true;
    await _store.deleteKey(account);
    final key = Uint8List.fromList(AiHistoryCipher.newKey());
    await _store.writeKey(account, key);
    final read = await _store.readKey(account);
    if (read.failure != null ||
        read.value == null ||
        !_sameBytes(key, read.value!)) {
      throw const AiJournalException('unavailable');
    }
    owner.key = key;
    final initial = _Snapshot()
      ..resetUntil = (_now.isAfter(confirmedAt) ? _now : confirmedAt).add(
        resetConfirmationDuration,
      );
    await _save(account, initial, epoch: owner.ownerEpoch, allowNew: true);
    await _store.deleteResetPending(account);
    owner.status = AiJournalKeyStatus.found;
    owner.uncertain.clear();
    owner.ephemeral.clear();
    owner.runs.clear();
    _executionAccounts.removeWhere((_, value) => value == account);
    _holds.removeWhere((_, hold) => hold.request.accountKey == account);
  }

  AiRemovalJob beginRemoval(String accountKey) {
    if (_removals.containsKey(accountKey) || _resets.containsKey(accountKey)) {
      throw const AiJournalException('removalInProgress');
    }
    final job = AiRemovalJob._(this, accountKey, _randomId());
    _removals[accountKey] = job;
    return job;
  }

  /// Called immediately before the host's clearAiAccountData, with the hold
  /// still active. A sequence watermark survives wall-clock adjustments.
  Future<void> markRemovalStarted(AiRemovalJob job) =>
      _locked(job.accountKey, () async {
        if (!job.holds(job.token) || !job._finalConfirmed) {
          throw const AiJournalException('invalidRemovalToken');
        }
        final status = await _load(job.accountKey);
        if (status == AiJournalKeyStatus.unavailable) {
          throw const AiJournalException('unavailable');
        }
        if (status != AiJournalKeyStatus.found) return;
        final owner = _account(job.accountKey);
        final data = owner.data.copy()..removalSequence = owner.data.sequence;
        await _save(
          job.accountKey,
          data,
          epoch: owner.ownerEpoch,
          mayCommit: () => job.holds(job.token),
        );
      });

  /// All tombstone entry points must call this before deleting journal data.
  /// Unreadable data follows the explicit name-confirmed removal path; an
  /// unavailable key refuses cleanup. Orphans are separately proven by startup.
  Future<bool> mayCleanupTombstone(String accountKey) =>
      _locked(accountKey, () async {
        final status = await _load(accountKey);
        if (status == AiJournalKeyStatus.unavailable) {
          throw const AiJournalException('unavailable');
        }
        if (status != AiJournalKeyStatus.found) return true;
        final data = _account(accountKey).data;
        return !data.entries.values.any(
          (entry) =>
              entry._isolates &&
              (data.removalSequence == null ||
                  entry.sequence > data.removalSequence!),
        );
      });

  /// The host sets the tombstone before this and clears it only after all other
  /// cleanup succeeds. Late callbacks cannot recreate files once deletion starts.
  Future<void> clearForRemoval(String accountKey) =>
      _locked(accountKey, () async {
        if (!tombstoneFlag(accountKey)) {
          throw const AiJournalException('tombstoneRequired');
        }
        // The synchronous flag can be set before a failed marker write. It
        // blocks new work but does not authorize deletion of durable state.
        final marker = await _store.readTombstone(accountKey);
        if (marker.failure != null ||
            marker.status == AiStoreReadStatus.unavailable) {
          throw const AiJournalException('unavailable');
        }
        if (marker.value != true) {
          throw const AiJournalException('tombstoneRequired');
        }
        final status = await _load(accountKey);
        if (status == AiJournalKeyStatus.unavailable) {
          throw const AiJournalException('unavailable');
        }
        final data = _account(accountKey).data;
        if (status == AiJournalKeyStatus.found &&
            data.entries.values.any(
              (entry) =>
                  entry._isolates &&
                  (data.removalSequence == null ||
                      entry.sequence > data.removalSequence!),
            )) {
          throw const AiJournalException('retryAccountRemoval');
        }
        await _deleteJournal(accountKey);
        await _store.deleteResetPending(accountKey);
      });

  Future<void> _deleteJournal(String account) async {
    final owner = _account(account);
    for (final entry in owner.data.entries.values) {
      if (entry._isolates) _retiredExecutions[entry.executionId] = entry;
    }
    owner.ownerEpoch++;
    owner.deleted = true;
    owner.recovered = false;
    await _disk.delete(account);
    await _store.deleteKey(account);
    owner.key = null;
    owner.data = _Snapshot();
    owner.ephemeral.clear();
    owner.runs.clear();
    owner.uncertain.clear();
    _holds.removeWhere((_, hold) => hold.request.accountKey == account);
    _executionAccounts.removeWhere((_, value) => value == account);
  }

  void _increment(Map<String, _Count> table, String id, bool tier4, int delta) {
    final old = table[id] ?? _Count(0, 0, _now);
    final count = _Count(
      old.writes + delta,
      old.tier4 + (tier4 ? delta : 0),
      _now,
    );
    if (count.writes <= 0) {
      table.remove(id);
    } else {
      table[id] = count;
    }
  }

  void _prune(_Snapshot data) {
    final hour = _now.subtract(const Duration(minutes: 60));
    final week = _now.subtract(const Duration(days: 7));
    final eligible =
        data.entries.values
            .where(
              (entry) =>
                  !entry._isolates &&
                  entry.state != AiJournalState.prepared &&
                  (entry.dispatchedAt ??
                          DateTime.parse(entry._data['createdAt']! as String))
                      .isBefore(hour),
            )
            .toList()
          ..sort((a, b) => a.sequence.compareTo(b.sequence));
    for (final entry in eligible) {
      if (data.entries.length > maxEntries ||
          DateTime.parse(entry._data['createdAt']! as String).isBefore(week)) {
        data.entries.remove(entry.executionId);
      }
    }
    data.counts.removeWhere(
      (_, count) =>
          count.lastUsed.isBefore(_now.subtract(const Duration(days: 90))),
    );
  }
}

final class _Account {
  _Snapshot data = _Snapshot();
  Uint8List? key;
  AiJournalKeyStatus? status;
  bool recovered = false;
  bool tombstone = false;
  bool tombstoneReadUnavailable = false;
  bool deleted = false;
  int proposalEpoch = 0;
  int ownerEpoch = 0;
  final Set<String> uncertain = {};
  final Map<String, _Count> ephemeral = {};
  final Map<String, _Count> runs = {};
}

final class _Count {
  const _Count(this.writes, this.tier4, this.lastUsed);
  final int writes;
  final int tier4;
  final DateTime lastUsed;
  List<Object?> json() => [writes, tier4, lastUsed.toIso8601String()];
}

final class _Snapshot {
  int sequence = 0;
  int? removalSequence;
  DateTime? resetUntil;
  final Map<String, AiJournalEntry> entries = {};
  final Map<String, _Count> counts = {};
  final Set<AiConflictKey> marks = {};
  Map<String, Object?> json() => {
    'version': 1,
    'sequence': sequence,
    'removalSequence': removalSequence,
    'resetUntil': resetUntil?.toIso8601String(),
    'entries': entries.values.map((e) => e._data).toList(),
    'counts': counts.map((key, value) => MapEntry(key, value.json())),
    'marks': _keysJson(marks),
  };
  _Snapshot copy() => _Snapshot()
    ..sequence = sequence
    ..removalSequence = removalSequence
    ..resetUntil = resetUntil
    ..entries.addAll(entries)
    ..counts.addAll(counts)
    ..marks.addAll(marks);

  static _Snapshot decode(Map<String, Object?> json, String account) {
    if (!_hasKeys(json, const {
          'version',
          'sequence',
          'removalSequence',
          'resetUntil',
          'entries',
          'counts',
          'marks',
        }) ||
        json['version'] != 1 ||
        json['sequence'] is! int ||
        (json['sequence']! as int) < 0 ||
        json['entries'] is! List<Object?>) {
      throw const FormatException();
    }
    final result = _Snapshot()..sequence = json['sequence']! as int;
    result.removalSequence = json['removalSequence'] as int?;
    if (result.removalSequence != null &&
        (result.removalSequence! < 0 ||
            result.removalSequence! > result.sequence)) {
      throw const FormatException();
    }
    result.resetUntil = _dateOrNull(json['resetUntil']);
    result.marks.addAll(_keys(json['marks']));
    final sequences = <int>{};
    for (final raw in json['entries']! as List<Object?>) {
      final map = _object(raw);
      if (!_hasKeys(map, const {
        'execution',
        'process',
        'account',
        'conversation',
        'run',
        'operation',
        'writes',
        'dependencies',
        'payloadSha256',
        'releaseName',
        'instance',
        'generation',
        'target',
        'last_commit_id',
        'headSha',
        'updated_at',
        'mergeCheckSummary',
        'policyRevision',
        'summary',
        'state',
        'sequence',
        'createdAt',
        'dispatchedAt',
        'observation',
        'budget',
        'hold',
        'consumedMarks',
        'confirmed',
        'bypass',
        'ownerEpoch',
        'proposalEpoch',
      })) {
        throw const FormatException();
      }
      final entry = AiJournalEntry._(map);
      for (final name in [
        'execution',
        'process',
        'account',
        'conversation',
        'run',
        'operation',
        'payloadSha256',
        'releaseName',
        'instance',
        'target',
        'summary',
        'createdAt',
      ]) {
        if (map[name] is! String) throw const FormatException();
      }
      if (entry.accountKey != account ||
          entry.sequence < 1 ||
          entry.sequence > result.sequence ||
          !sequences.add(entry.sequence) ||
          result.entries.containsKey(entry.executionId) ||
          entry.writeKeys.isEmpty ||
          entry.releaseName.isEmpty ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.payloadSha256)) {
        throw const FormatException();
      }
      for (final name in [
        'generation',
        'policyRevision',
        'ownerEpoch',
        'proposalEpoch',
      ]) {
        if (map[name] is! int || (map[name]! as int) < 0) {
          throw const FormatException();
        }
      }
      for (final name in [
        'last_commit_id',
        'headSha',
        'updated_at',
        'mergeCheckSummary',
        'observation',
        'hold',
      ]) {
        if (map[name] != null && map[name] is! String) {
          throw const FormatException();
        }
      }
      if (map['confirmed'] is! bool || map['bypass'] is! bool) {
        throw const FormatException();
      }
      _dateOrNull(map['createdAt']);
      _dateOrNull(map['dispatchedAt']);
      _keys(map['consumedMarks']);
      final budget = entry._request;
      if (budget.accountKey != account ||
          budget.conversationId != entry.conversationId ||
          budget.runId != entry.runId) {
        throw const FormatException();
      }
      // Touch state to reject unknown enum values before exposing the snapshot.
      if (entry.state != AiJournalState.prepared &&
          entry.state != AiJournalState.notExecuted &&
          entry.dispatchedAt == null) {
        throw const FormatException();
      }
      for (final key in entry._allKeys) {
        if (key.parts.first != account) throw const FormatException();
      }
      result.entries[entry.executionId] = entry;
    }
    for (final pair in _object(json['counts']).entries) {
      final row = pair.value! as List<Object?>;
      if (pair.key.isEmpty ||
          row.length != 3 ||
          row[0] is! int ||
          row[1] is! int ||
          (row[0]! as int) < 1 ||
          (row[0]! as int) > 40 ||
          (row[1]! as int) < 0 ||
          (row[1]! as int) > 10 ||
          (row[1]! as int) > (row[0]! as int)) {
        throw const FormatException();
      }
      result.counts[pair.key] = _Count(
        row[0]! as int,
        row[1]! as int,
        _dateOrNull(row[2])!,
      );
    }
    if (result.entries.length > AiWriteJournal.maxEntries ||
        result.counts.length > AiWriteJournal.maxConversations) {
      throw const FormatException();
    }
    for (final mark in result.marks) {
      if (mark.parts.first != account) throw const FormatException();
    }
    return result;
  }
}

bool _hasKeys(Map<String, Object?> value, Set<String> expected) =>
    value.length == expected.length && value.keys.every(expected.contains);

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, Object?>) throw const FormatException();
  return value;
}

DateTime? _dateOrNull(Object? value) {
  if (value == null) return null;
  final date = DateTime.parse(value as String);
  if (!date.isUtc) throw const FormatException();
  return date;
}

Set<AiConflictKey> _freezeKeys(Iterable<AiConflictKey> keys) =>
    Set.unmodifiable(
      keys.map((key) => AiConflictKey(List.unmodifiable(key.parts))),
    );
Set<AiConflictKey> _keys(Object? value) {
  if (value is! List<Object?>) throw const FormatException();
  final keys = <AiConflictKey>{};
  for (final raw in value) {
    if (raw is! List<Object?> ||
        raw.isEmpty ||
        raw.any((part) => part is! String || part.isEmpty)) {
      throw const FormatException();
    }
    final key = AiConflictKey(List<String>.unmodifiable(raw.cast<String>()));
    if (!keys.add(key)) throw const FormatException();
  }
  return Set.unmodifiable(keys);
}

List<List<String>> _keysJson(Iterable<AiConflictKey> keys) =>
    keys.map((key) => key.parts).toList();
AiBudgetRequest _requestFromJson(Map<String, Object?> map) {
  if (map.length != 6 ||
      map['account'] is! String ||
      map['conversation'] is! String ||
      map['run'] is! String ||
      map['tier4'] is! bool ||
      map['persistent'] is! bool ||
      map['resources'] is! int ||
      (map['resources']! as int) < 1 ||
      (map['resources']! as int) > 20) {
    throw const FormatException();
  }
  return AiBudgetRequest(
    accountKey: map['account']! as String,
    conversationId: map['conversation']! as String,
    runId: map['run']! as String,
    tier4: map['tier4']! as bool,
    persistConversation: map['persistent']! as bool,
    affectedResources: map['resources']! as int,
  );
}

void _metadata(String value, int maxBytes) {
  if (utf8.encode(value).length > maxBytes ||
      value.contains('\n') ||
      value.contains('\r')) {
    throw const AiJournalException('invalidMetadata');
  }
}

void _validateDraft(AiJournalDraft draft) {
  if (draft.executionId.isEmpty ||
      draft.operationId.isEmpty ||
      draft.releaseName.isEmpty ||
      draft.writeKeys.isEmpty ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(draft.payloadSha256) ||
      draft.sessionGeneration < 0 ||
      draft.policyRevision < 0) {
    throw const AiJournalException('invalidDraft');
  }
  for (final value in [
    draft.executionId,
    draft.conversationId,
    draft.runId,
    draft.operationId,
    draft.instance,
    draft.normalizedTarget,
    draft.summary,
    draft.lastCommitId ?? '',
    draft.headSha ?? '',
    draft.updatedAt ?? '',
    draft.mergeCheckSummary ?? '',
  ]) {
    _metadata(value, 4096);
  }
  _metadata(draft.releaseName, 16384);
  for (final key in {...draft.writeKeys, ...draft.dependencyKeys}) {
    if (key.parts.isEmpty ||
        key.parts.first != draft.accountKey ||
        key.parts.any((part) => part.isEmpty)) {
      throw const AiJournalException('invalidKey');
    }
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

String _randomId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256),
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

final class _OverSize implements Exception {}

/// Bounded journal-only filesystem. History cleanup cannot reach this sibling
/// directory. The trusted support root and every ancestor reject symlinks.
class AiJournalFiles {
  AiJournalFiles(this.applicationSupport);
  final Directory applicationSupport;
  static const fileName = 'journal.v1.enc';
  static String accountHash(String account) =>
      sha256.convert(utf8.encode(account)).toString().substring(0, 32);
  String? _canonicalSupport;
  String get _root =>
      '${_canonicalSupport ??= applicationSupport.resolveSymbolicLinksSync()}/ai_write_journal';
  String pathFor(String account) => '$_root/${accountHash(account)}/$fileName';

  Future<bool> exists(String account) async {
    _checkPath(pathFor(account), finalFile: true);
    return _type(pathFor(account)) == FileSystemEntityType.file;
  }

  Future<Uint8List?> read(String account) async {
    final path = pathFor(account);
    _checkPath(path, finalFile: true);
    if (_type(path) == FileSystemEntityType.notFound) return null;
    if (File(path).lengthSync() > AiWriteJournal.ciphertextLimit) {
      throw _OverSize();
    }
    final bytes = await Isolate.run(() => _boundedRead(path));
    if (bytes.length > AiWriteJournal.ciphertextLimit) throw _OverSize();
    _checkPath(path, finalFile: true);
    return bytes;
  }

  Future<void> write(
    String account,
    Uint8List bytes, {
    required bool Function() mayCommit,
  }) async {
    final path = pathFor(account);
    _checkPath(path, finalFile: true);
    Directory(File(path).parent.path).createSync(recursive: true);
    _checkPath(path, finalFile: true);
    if (_type('$path.tmp') != FileSystemEntityType.notFound) {
      throw FileSystemException('unsafeTemporary', path);
    }
    final temp = await Isolate.run(() => _writeTemporary(path, bytes));
    try {
      _checkPath(path, finalFile: true);
      if (!mayCommit()) throw const AiJournalException('staleOwner');
      if (_type(temp) != FileSystemEntityType.file) {
        throw FileSystemException('unsafeTemporary', temp);
      }
      File(temp).renameSync(path);
    } finally {
      if (_type(temp) == FileSystemEntityType.file) File(temp).deleteSync();
    }
  }

  Future<void> cleanupTemporary(String account) async {
    final directory = File(pathFor(account)).parent;
    _checkPath(directory.path);
    if (_type(directory.path) == FileSystemEntityType.notFound) return;
    final pattern = RegExp(r'^journal\.v1\.enc\.[a-f0-9]{32}\.tmp$');
    for (final entity in directory.listSync(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (!pattern.hasMatch(name)) continue;
      if (_type(entity.path) != FileSystemEntityType.file) {
        throw FileSystemException('unsafeTemporary', entity.path);
      }
      File(entity.path).deleteSync();
    }
  }

  Future<void> delete(String account) => deleteHash(accountHash(account));
  Future<void> deleteHash(String hash) async {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(hash)) {
      throw const FormatException();
    }
    final path = '$_root/$hash';
    _checkPath(path);
    if (_type(path) == FileSystemEntityType.notFound) return;
    // Do not traverse arbitrary directories or links during deletion.
    final files = Directory(path).listSync(followLinks: false);
    for (final entity in files) {
      if (_type(entity.path) != FileSystemEntityType.file) {
        throw FileSystemException('unsafeJournalEntity', entity.path);
      }
    }
    for (final entity in files) {
      File(entity.path).deleteSync();
    }
    Directory(path).deleteSync();
  }

  Future<Set<String>> accountHashes() async {
    _checkPath(_root);
    if (_type(_root) == FileSystemEntityType.notFound) return {};
    final result = <String>{};
    for (final entity in Directory(_root).listSync(followLinks: false)) {
      final name = entity.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(name) ||
          _type(entity.path) != FileSystemEntityType.directory) {
        throw FileSystemException('unsafeJournalDirectory', entity.path);
      }
      result.add(name);
    }
    return result;
  }
}

FileSystemEntityType _type(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false);
void _checkPath(String path, {bool finalFile = false}) {
  final absolute = File(path).absolute.path;
  final parts = absolute
      .split(Platform.pathSeparator)
      .where((part) => part.isNotEmpty)
      .toList();
  var current = '';
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] == '.' || parts[i] == '..') {
      throw FileSystemException('unsafeJournalPath', path);
    }
    current += '${Platform.pathSeparator}${parts[i]}';
    final type = _type(current);
    final expected = finalFile && i == parts.length - 1
        ? FileSystemEntityType.file
        : FileSystemEntityType.directory;
    if (type != FileSystemEntityType.notFound && type != expected) {
      throw FileSystemException('unsafeJournalPath', current);
    }
  }
}

Uint8List _boundedRead(String path) {
  final handle = File(path).openSync();
  try {
    return handle.readSync(AiWriteJournal.ciphertextLimit + 1);
  } finally {
    handle.closeSync();
  }
}

String _writeTemporary(String path, Uint8List bytes) {
  for (var attempt = 0; attempt < 8; attempt++) {
    final file = File('$path.${_randomId()}.tmp');
    try {
      file.createSync(exclusive: true);
    } on FileSystemException {
      if (_type(file.path) != FileSystemEntityType.notFound) continue;
      rethrow;
    }
    try {
      final handle = file.openSync(mode: FileMode.writeOnly);
      try {
        handle.writeFromSync(bytes);
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
      return file.path;
    } on Object {
      if (_type(file.path) == FileSystemEntityType.file) file.deleteSync();
      rethrow;
    }
  }
  throw FileSystemException('temporaryCreationFailed', path);
}
