import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/offline/offline_repository_coordinator.dart';
import '../../core/offline/snapshot_schema.dart';
import '../../core/offline/snapshot_store.dart';
import '../../core/read_cache_cipher.dart';
import '../../core/read_cache_disk_contract.dart';
import '../../core/read_cache_files.dart';
import 'read_cache_key_store.dart';
import 'read_cache_settings_store.dart';
import 'offline_repository_namespace.dart';

enum ReadCacheDiskState {
  closed,
  offlineReadOnly,
  ready,
  cleaning,
  disabled,
  unavailable,
}

/// C2 owns account cleanup even when the offline implementation is not loaded.
/// The registered participant owns its epochs, workers and maintenance lock.
/// [fence] and [open] must change admission synchronously. [stopAndWait] must
/// acknowledge quiescence (including main-isolate commits), using stop/ack/kill
/// for workers; a timeout is never permission to delete under a live writer.
abstract interface class ReadCacheNamespace {
  String get name;
  void fence(String accountKey);
  Future<void> stopAndWait(String accountKey);
  Future<void> deleteKey(String accountKey);
  Future<void> deleteDirectory(String accountKey);
  void open(DiskBinding binding, ReadCacheDiskState mode);

  /// An unreadable marker must throw, rather than report absence.
  Future<bool> hasMarker(String accountKey);
}

/// C3a supplies authoritative HTTP classification and project epoch/deletion.
/// Ordinary C2 eviction, including no-store, is not project revocation.
abstract interface class ReadCacheNamespaceSecurity {
  DiskInvalidationFence invalidatePermission(
    DiskBinding binding,
    int projectId,
  );
}

enum ReadCacheSettingChangeResult {
  complete,
  cleanupPending,
  storageUnavailable,
}

/// Device-wide cleanup survives account changes and failed marker writes in
/// this process. A stored off preference makes startup repeat the whole sweep.
final class ReadCacheSettingsSnapshot {
  const ReadCacheSettingsSnapshot({
    required this.setting,
    required this.deviceOffPending,
    required this.deviceOffInFlight,
  });

  final ReadCacheSettingsState setting;
  final bool deviceOffPending, deviceOffInFlight;
}

/// Schedulers return a cancellation function. Tests can advance the same clock
/// used for queue deadlines and caller timeouts without delaying native I/O.
typedef ReadCacheScheduler =
    void Function() Function(Duration delay, void Function() callback);

final class ReadCacheDiskStats {
  const ReadCacheDiskStats(
    this.queuedEntries,
    this.queuedBytes,
    this.dropped, {
    this.retainedEntries = 0,
    this.unindexedEntries = 0,
    this.retainedBytes = 0,
    this.diskUsageBytes,
  });
  final int queuedEntries, queuedBytes, dropped;
  final int retainedEntries, unindexedEntries;

  /// Encrypted bytes of the indexed entries known to this process (C2e, read
  /// only for the settings page). No names, keys or paths.
  final int retainedBytes;

  /// Confirmed whole-device usage, or null when it cannot be established.
  /// Currently only a confirmed empty device sweep reports a number (zero).
  /// Indexed entry bytes must never be used as a fallback for this value.
  final int? diskUsageBytes;
}

/// The only owner of read-cache keys, intents and transactions. No production
/// reader/writer is attached in C2c. In particular the singleton starts both
/// unconfigured and without user controls; neither condition proves disk empty.
final class ReadCacheDiskCoordinator {
  ReadCacheDiskCoordinator({
    ReadCacheKeyStore? keys,
    ReadCacheFileStore? files,
    ReadCacheSettingsStore? settings,
    Object? coordinationScope,
    DateTime Function()? clock,
    ReadCacheScheduler? schedule,
    bool controlsInstalled = false,
  }) : _keys = keys,
       _files = files,
       _settings = settings,
       _domain = coordinationScope == null
           ? _processDomain
           : (_scopes[coordinationScope] ??= _Domain()),
       _clock = clock ?? DateTime.now,
       _schedule = schedule ?? _timer {
    if (controlsInstalled) _domain.controlsInstalled = true;
  }

  static final instance = ReadCacheDiskCoordinator();
  static final _processDomain = _Domain();
  static final _scopes = Expando<_Domain>();
  static final _random = Random.secure();
  static const queueByteLimit = 2 * 1024 * 1024;
  static const batchEntries = 32;
  static const batchDelay = Duration(seconds: 2);
  static const barrierLimit = Duration(seconds: 5);

  ReadCacheKeyStore? _keys;
  ReadCacheFileStore? _files;
  ReadCacheSettingsStore? _settings;
  final _Domain _domain;
  final DateTime Function() _clock;
  final ReadCacheScheduler _schedule;
  Map<DiskBinding, ReadCacheNotice> get _notices => _domain.notices;
  Map<DiskBinding, ReadCacheNotice> get _signedOut => _domain.signedOut;
  Set<ReadCacheNoticeSink> get _subscribers => _domain.subscribers;

  bool get configured => _keys != null && _files != null && _settings != null;
  bool get startupRecovered => _domain.recovered;
  bool get controlsInstalled => _domain.controlsInstalled;
  String? get diskRetainedAccountKey => _domain.diskRetainedAccountKey;
  ReadCacheDiskState state(String accountKey) {
    final account = _account(accountKey);
    return account.offlineRefusalBlocked && !account.cleanup
        ? ReadCacheDiskState.unavailable
        : account.state;
  }

  ReadCacheNotice? notice(DiskBinding binding) => _notices[binding];
  List<ReadCacheNotice> get signedOutNotices =>
      List.unmodifiable(_signedOut.values);

  /// Read-only C2e accessors: the login retry needs each signed-out binding,
  /// and the settings page shows the effective device preference.
  Map<DiskBinding, ReadCacheNotice> get signedOutSnapshot =>
      Map.unmodifiable(_signedOut);
  ReadCacheSettingsState get setting => _domain.setting;
  bool get deviceOffPending =>
      _domain.deviceOffPending || _domain.deviceOffOperations > 0;

  /// Read-only (C2e size line): a device-off sweep, or any account's full
  /// clear, is in progress or unfinished anywhere on this device.
  bool get cleanupPendingAnywhere =>
      deviceOffPending ||
      _domain.accounts.values.any((account) => account.intent?.full ?? false);
  ReadCacheSettingsSnapshot get settingsSnapshot => ReadCacheSettingsSnapshot(
    setting: setting,
    deviceOffPending: deviceOffPending,
    deviceOffInFlight: _domain.deviceOffOperations > 0,
  );

  ReadCacheDiskStats get stats => ReadCacheDiskStats(
    _domain.accounts.values.fold(0, (n, a) => n + a.pending.length),
    _domain.accounts.values.fold(0, (n, a) => n + a.queuedBytes),
    _domain.dropped,
    retainedEntries: _domain.accounts.values.fold(
      0,
      (n, a) => n + a.entries.length,
    ),
    unindexedEntries: _domain.accounts.values.fold(
      0,
      (n, a) => n + a.unindexed.length,
    ),
    retainedBytes: _domain.accounts.values.fold(
      0,
      (n, a) => a.entries.values.fold(n, (m, r) => m + r.index.sizeBytes),
    ),
    diskUsageBytes: configured && !deviceOffPending
        ? _domain.diskUsageBytes
        : null,
  );

  void configure({
    required ReadCacheKeyStore keys,
    required ReadCacheFileStore files,
    required ReadCacheSettingsStore settings,
  }) {
    // Configuration never opens a gate or forgets a pending clear.
    _keys = keys;
    _files = files;
    _settings = settings;
  }

  void installUserControls() => _domain.controlsInstalled = true;

  /// The C3 owner shares this coordinator's storage and coordination scope.
  OfflineRepositoryCoordinator? get offlineRepository {
    if (!configured) return null;
    final existing = _domain.namespace ?? _domain.pendingOfflineNamespace;
    if (existing is OfflineRepositoryNamespace) return existing.coordinator;
    if (existing != null) return null;
    final participant = OfflineRepositoryNamespace(
      coordinator: identical(_domain, _processDomain)
          ? OfflineRepositoryCoordinator.instance
          : OfflineRepositoryCoordinator(clock: _clock),
      keys: _keys!,
      files: _files!,
    );
    _domain.pendingOfflineNamespace = participant;
    return participant.coordinator;
  }

  Future<bool> readOfflineRefused(String accountKey) async {
    if (!configured) {
      throw const ReadCacheStoreException(
        ReadCacheStoreFailure(
          ReadCacheStoreFailureKind.unavailable,
          'readOfflineRefusal',
        ),
      );
    }
    if (_account(accountKey).offlineRefusalBlocked) return true;
    final result = await _keys!.readOfflineRefusal(accountKey);
    if (result.status == ReadCacheStoreReadStatus.unavailable) {
      throw ReadCacheStoreException(result.failure!);
    }
    return result.status == ReadCacheStoreReadStatus.found;
  }

  Future<void> writeOfflineRefused(String accountKey, DateTime when) {
    if (!configured) {
      throw const ReadCacheStoreException(
        ReadCacheStoreFailure(
          ReadCacheStoreFailureKind.unavailable,
          'writeOfflineRefusal',
        ),
      );
    }
    return _keys!.writeOfflineRefusal(accountKey, when);
  }

  Future<void> deleteOfflineRefused(String accountKey) async {
    if (!configured) {
      throw const ReadCacheStoreException(
        ReadCacheStoreFailure(
          ReadCacheStoreFailureKind.unavailable,
          'deleteOfflineRefusal',
        ),
      );
    }
    final account = _account(accountKey);
    account.offlineRefusalDeletes++;
    try {
      await _keys!.deleteOfflineRefusal(accountKey);
      account.offlineRefusalPending = false;
    } on Object {
      // Delete may have succeeded before readback failed. Keep treating the
      // marker as present until a later verified removal succeeds.
      account.offlineRefusalPending = true;
      account.epoch++;
      _dropQueue(account);
      (_domain.namespace ?? _domain.pendingOfflineNamespace)?.fence(accountKey);
      rethrow;
    } finally {
      account.offlineRefusalDeletes--;
    }
  }

  /// Bind C3's HTTP sinks now; join B4 only when disk activation can open it.
  /// A never-opened participant has no work to drain and must not turn empty
  /// account cleanup into marker writes while storage remains closed.
  void bindOfflineRepository(GitLabApi api, DiskBinding binding) {
    if (!configured) return;
    var participant = _domain.namespace ?? _domain.pendingOfflineNamespace;
    if (participant == null) {
      final offline = OfflineRepositoryNamespace(
        coordinator: identical(_domain, _processDomain)
            ? OfflineRepositoryCoordinator.instance
            : OfflineRepositoryCoordinator(clock: _clock),
        keys: _keys!,
        files: _files!,
      );
      _domain.pendingOfflineNamespace = offline;
      participant = offline;
    }
    if (participant is OfflineRepositoryNamespace) {
      participant.coordinator.bindApi(api, binding);
    }
  }

  void _installOfflineNamespace() {
    final pending = _domain.pendingOfflineNamespace;
    if (_domain.namespace == null && pending != null) {
      register(pending);
      _domain.pendingOfflineNamespace = null;
    }
  }

  /// Storage cleanup does not depend on registration, so startup can erase
  /// old offline data before C3 constructs its runtime participant.
  void register(ReadCacheNamespace namespace) {
    if (namespace.name != 'offline_repo') {
      throw ArgumentError('Unsupported read-cache namespace');
    }
    final previous = _domain.namespace;
    if (previous != null && !identical(previous, namespace)) {
      throw StateError('Read-cache namespace already registered');
    }
    _domain.namespace = namespace;
    for (final account in _domain.accounts.values) {
      namespace.fence(account.key);
    }
    // A late participant stays fenced until activation checks both markers.
  }

  void retainDiskAccount(String? key, {required Object sessionOwner}) {
    if (!ownsStartupSession(sessionOwner)) return;
    if (key != null) _account(key);
    _domain.diskRetainedAccountKey = key;
  }

  DiskInvalidationFence invalidateProjectPermission(
    DiskBinding binding,
    int projectId,
  ) {
    if (projectId <= 0) throw ArgumentError.value(projectId, 'projectId');
    if (binding != _domain.active && binding != _domain.offlineBinding) {
      final stale = _Fence()..revoke();
      stale.finish(Future.value(_none), Future.value());
      return stale;
    }
    final namespace = _domain.namespace;
    if (namespace is ReadCacheNamespaceSecurity) {
      return (namespace as ReadCacheNamespaceSecurity).invalidatePermission(
        binding,
        projectId,
      );
    }
    namespace?.fence(binding.accountKey);
    throw StateError('Namespace security handler unavailable');
  }

  /// Every verified activation installs all fences before publishing its new
  /// binding. Deletion remains on the shared asynchronous I/O lane.
  void fenceOtherAccounts(
    DiskBinding target, {
    Object? sessionOwner,
    Set<String> accountKeys = const {},
  }) {
    if (sessionOwner != null && !ownsStartupSession(sessionOwner)) return;
    for (final key in accountKeys) {
      _account(key);
    }
    final retained = diskRetainedAccountKey;
    if (retained != null) _account(retained);
    _account(target.accountKey);
    for (final account in List.of(_domain.accounts.values)) {
      if (account.key == target.accountKey ||
          (account.cleanup && account.intent?.accountWide == true)) {
        continue;
      }
      final binding = _domain.active?.accountKey == account.key
          ? _domain.active!
          : DiskBinding(accountKey: account.key, generation: 0);
      unawaited(clear(binding, ReadCacheCleanupOperation.signOut));
    }
  }

  /// Read-only C3 qualification while C2 is closed. An absent/unavailable key
  /// never repairs storage, creates a key, or deletes existing ciphertext.
  Future<ReadCacheStoreRead<Uint8List>> readOfflineEligibilityKey(
    String accountKey,
  ) async {
    final account = _account(accountKey);
    final epoch = account.epoch;
    bool current() =>
        configured &&
        _domain.recovered &&
        _domain.setting == ReadCacheSettingsState.enabled &&
        !deviceOffPending &&
        _domain.preferenceChanges == 0 &&
        diskRetainedAccountKey == accountKey &&
        !account.offlineRefusalBlocked &&
        account.state == ReadCacheDiskState.closed &&
        account.epoch == epoch &&
        account.intent?.accountWide != true;
    const blocked = ReadCacheStoreRead<Uint8List>.unavailable(
      ReadCacheStoreFailure(
        ReadCacheStoreFailureKind.unavailable,
        'offlineEligibility',
      ),
    );
    if (!current()) return blocked;
    final marker = await _keys!.readMarker(accountKey);
    final offlineMarker = await _keys!.readOfflineMarker(accountKey);
    final refused = await _keys!.readOfflineRefusal(accountKey);
    if (!current() ||
        marker.status != ReadCacheStoreReadStatus.absent ||
        offlineMarker.status != ReadCacheStoreReadStatus.absent ||
        refused.status != ReadCacheStoreReadStatus.absent) {
      return blocked;
    }
    try {
      final namespace = _domain.namespace ?? _domain.pendingOfflineNamespace;
      if (await namespace?.hasMarker(accountKey) ?? false) {
        return blocked;
      }
    } on Object {
      return blocked;
    }
    final key = await _keys!.readOfflineKey(accountKey);
    return current() ? key : blocked;
  }

  /// Inspect an authenticated index without opening the namespace or writing.
  Future<SnapshotIndex?> offlineEligibilityIndex(
    String accountKey,
  ) async {
    final epoch = _account(accountKey).epoch;
    final revision = _domain.startupRevision;
    final initial = await readOfflineEligibilityKey(accountKey);
    if (!initial.isFound || initial.value == null) return null;
    try {
      final store = SnapshotStore(
        supportRoot: await _files!.offlineSupportDirectory(),
        accountKey: accountKey,
        rootKey: initial.value!,
      );
      final index = await store.readIndex();
      if (index == null) return null;
      var complete = false;
      for (final record in index.snapshots) {
        if (record.status != SnapshotStatus.complete) continue;
        try {
          if (await store.readTree(record) != null) {
            complete = true;
            break;
          }
        } on SnapshotStoreException catch (error) {
          if (error.code != SnapshotStoreError.corrupt &&
              error.code != SnapshotStoreError.authenticationFailed &&
              error.code != SnapshotStoreError.tooLarge) {
            rethrow;
          }
        } on SnapshotSchemaException catch (error) {
          if (error.code == SnapshotSchemaError.newerSchema) rethrow;
        }
      }
      if (!complete) return null;
      final finalKey = await readOfflineEligibilityKey(accountKey);
      final bytes = finalKey.value;
      if (!finalKey.isFound ||
          bytes == null ||
          bytes.length != initial.value!.length ||
          _account(accountKey).epoch != epoch ||
          _domain.startupRevision != revision) {
        return null;
      }
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] != initial.value![i]) return null;
      }
      return index;
    } on Object {
      return null;
    }
  }

  /// Reserved for the current SessionController's C3c `_enterOffline` path.
  /// This changes cache admission only; it creates no API client or UI mode.
  Future<bool> enterOfflineReadOnly(
    DiskBinding binding, {
    required Object sessionOwner,
  }) async {
    if (!ownsStartupSession(sessionOwner) ||
        binding.generation <= _domain.revokedThrough ||
        binding.generation <= _domain.highestGeneration) {
      return false;
    }
    final account = _account(binding.accountKey);
    final epoch = account.epoch;
    final key = await readOfflineEligibilityKey(binding.accountKey);
    if (!key.isFound ||
        !configured ||
        !_domain.recovered ||
        deviceOffPending ||
        _domain.preferenceChanges != 0 ||
        _domain.setting != ReadCacheSettingsState.enabled ||
        diskRetainedAccountKey != binding.accountKey ||
        account.epoch != epoch ||
        account.state != ReadCacheDiskState.closed ||
        account.cleanup ||
        account.intent != null ||
        binding.generation <= _domain.revokedThrough ||
        !ownsStartupSession(sessionOwner) ||
        binding.generation <= _domain.highestGeneration) {
      return false;
    }
    if (_domain.namespace == null && offlineRepository == null) return false;
    _installOfflineNamespace();
    account.epoch++;
    account.state = ReadCacheDiskState.offlineReadOnly;
    _domain.highestGeneration = binding.generation;
    _domain.offlineBinding = binding;
    _domain.namespace?.open(binding, ReadCacheDiskState.offlineReadOnly);
    return true;
  }

  void closeOfflineReadOnly(
    DiskBinding binding, {
    required Object sessionOwner,
  }) {
    if (!ownsStartupSession(sessionOwner) ||
        _domain.offlineBinding != binding) {
      return;
    }
    final account = _account(binding.accountKey);
    account.epoch++;
    account.state = ReadCacheDiskState.closed;
    _domain.revokedThrough = max(_domain.revokedThrough, binding.generation);
    _domain.offlineBinding = null;
    final namespace = _domain.namespace;
    if (namespace is OfflineRepositoryNamespace) {
      namespace.coordinator.closeReadOnly(binding);
    } else {
      namespace?.fence(binding.accountKey);
    }
  }

  void Function() subscribe(ReadCacheNoticeSink sink) {
    _subscribers.add(sink);
    return () => _subscribers.remove(sink);
  }

  ApiFailure reportCleanup(DiskBinding binding, ReadCacheCleanupState state) {
    final value = ReadCacheNotice(ApiFailure.readCacheCleanup(state));
    _notices[binding] = value;
    if (state.disposition ==
        ReadCacheCleanupDisposition.signedOutCleanupPending) {
      _signedOut[binding] = value;
    }
    for (final sink in List.of(_subscribers)) {
      try {
        sink(value);
      } on Object {
        // Observers cannot replace a transport outcome or lose the snapshot.
      }
    }
    return value.failure;
  }

  void supersedeNotice(DiskBinding binding) {
    _notices.remove(binding);
    _signedOut.remove(binding);
  }

  /// A partial clear closes disk immediately. A later AI/store failure can
  /// still retain the account; update only its existing removal notices.
  void finishAccountRemoval(String accountKey, {required bool removed}) {
    final disposition = removed
        ? ReadCacheCleanupDisposition.diskClosed
        : ReadCacheCleanupDisposition.accountRetained;
    for (final entry in List.of(_notices.entries)) {
      final state = entry.value.failure.cleanup!;
      if (entry.key.accountKey != accountKey ||
          state.operation != ReadCacheCleanupOperation.accountRemoval ||
          state.disposition == disposition) {
        continue;
      }
      reportCleanup(
        entry.key,
        ReadCacheCleanupState(
          operation: state.operation,
          disposition: disposition,
          code: state.code,
          clearResult: state.clearResult,
        ),
      );
    }
  }

  /// A replacement controller takes startup ownership once. Retired callers
  /// cannot reclaim it by publishing another decision or disposing later.
  void claimStartupSession(Object owner) {
    _domain.startupOwner = owner;
    revokeStartup(owner);
  }

  bool ownsStartupSession(Object owner) =>
      identical(_domain.startupOwner, owner);

  /// Reserve a scan epoch at enqueue, including its time waiting for old I/O.
  Object? beginStartupScan(Object owner) {
    if (!revokeStartup(owner)) return null;
    _domain.startupScanRevision = _domain.startupRevision;
    return _domain.startupScan = Object();
  }

  /// A deadline can revoke only its own round; a current owner's decision
  /// change can revoke any older round without releasing its native I/O tail.
  bool revokeStartup(Object owner, {Object? scan}) {
    if (!ownsStartupSession(owner) ||
        (scan != null && !identical(scan, _domain.startupScan))) {
      return false;
    }
    _domain.startupRevision++;
    _domain.startupScan = null;
    _domain.recovered = false;
    return true;
  }

  /// Retire background sign-out deadlines without claiming cleanup stopped.
  /// The serialized I/O tail still owns cleanup and replacement activation.
  void releaseSession(Object owner) {
    revokeStartup(owner);
    for (final release in List.of(
      _domain.waits[owner] ?? const <void Function()>{},
    )) {
      release();
    }
    if (ownsStartupSession(owner)) _domain.startupOwner = null;
  }

  _Account _account(String key) =>
      _domain.accounts.putIfAbsent(key, () => _Account(key));

  /// One process-wide serialized I/O section also makes device capacity and
  /// root sweeps atomic with respect to every account transaction. Wrappers
  /// share it, not the identity of a particular key-store instance.
  Future<T> _serial<T>(_Account? account, Future<T> Function() action) {
    final result = Completer<T>();
    account?.work++;
    _domain.work++;
    _domain.tail = _domain.tail.then((_) async {
      try {
        result.complete(await action());
      } on Object catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        _domain.work--;
        if (account != null) account.work--;
      }
    });
    return result.future;
  }

  /// Guard each primitive before caller-specific miss/cleanup catches can
  /// consume its error. Commit closures run synchronously on this isolate.
  Future<T> _file<T>(
    FutureOr<T> Function() action, {
    bool clearingRoot = false,
    bool recoverySweep = false,
  }) async {
    // Any file operation invalidates the previous empty-root proof. Failure
    // cannot turn cleared in-memory indexes into a claim of zero disk usage.
    _domain.diskUsageBytes = null;
    try {
      return await action();
    } on Object catch (error) {
      // Any clearRoot failure conservatively fences the entire device, even
      // ordinary I/O: the failed last resort cannot establish a trusted root.
      if (clearingRoot ||
          (error is ReadCacheFileException &&
              error.code == ReadCacheFileFailure.untrustedPath)) {
        await _fenceUntrustedPath(
          clearRoot: !clearingRoot && !recoverySweep,
          rootFailed: clearingRoot,
        );
      }
      rethrow;
    }
  }

  Future<void> _fenceUntrustedPath({
    required bool clearRoot,
    required bool rootFailed,
  }) async {
    _domain.recovered = false;
    _domain.pathRevision++;
    // Reuse the existing full-clear reason/notice labels for path incidents.
    // Recovery treats these markers identically; settingsClear reports the
    // existing diskClosed disposition without adding a separate UI operation.
    final intents = <_Account, _Intent>{
      for (final account in _domain.accounts.values)
        account: _fullIntent(account, ReadCacheClearReason.accountClear),
    };
    // Fences are installed for every account before any native await. Persist
    // their replacement intents before the destructive root operation.
    final markers = Future.wait([
      for (final entry in intents.entries) _persist(entry.key, entry.value),
    ]);
    final expired = Completer<void>();
    final cancel = _schedule(barrierLimit, expired.complete);
    try {
      // A stuck secure-store lane must not indefinitely prevent root cleanup.
      // Its late acknowledgement still belongs to the pending full intent.
      await Future.any<void>([markers.then((_) {}), expired.future]);
    } finally {
      cancel();
    }
    var failed = rootFailed;
    if (clearRoot) {
      try {
        // Already inside the shared I/O lane. Enqueuing would deadlock; guarding
        // this last-resort call again would recurse on an unremovable path.
        await _files!.clearRoot();
      } on Object {
        failed = true;
        // One attempt only. Recovery or explicit cleanup owns a future retry.
      }
    }
    for (final entry in intents.entries) {
      final account = entry.key;
      account.entries.clear();
      account.unindexed.clear();
      account.indexTrusted = false;
      account.indexDirty = false;
      if (failed) {
        final active = _domain.active;
        final binding = active?.accountKey == account.key
            ? active!
            : account.sessionFence ??
                  DiskBinding(accountKey: account.key, generation: 0);
        reportCleanup(
          binding,
          _cleanup(
            ReadCacheCleanupOperation.settingsClear,
            DiskClearResult(
              keyGoneConfirmed: false,
              directoryGoneConfirmed: false,
              markerDurable: entry.value.durable,
              complete: false,
            ),
            ReadCacheCleanupCode.cleanupFailed,
          ),
        );
      }
    }
  }

  Future<void> get quiesced => _domain.tail;

  bool _gates(DiskBinding binding) =>
      configured &&
      _domain.controlsInstalled &&
      _domain.foreground &&
      _domain.preferenceChanges == 0 &&
      !deviceOffPending &&
      _domain.recovered &&
      _domain.setting == ReadCacheSettingsState.enabled &&
      _domain.active == binding &&
      !_account(binding.accountKey).offlineRefusalBlocked &&
      !_account(binding.accountKey).cleanup;

  bool _ready(DiskBinding binding) =>
      _gates(binding) &&
      _account(binding.accountKey).state == ReadCacheDiskState.ready;

  bool _blocked(_Account account, ProjectedDiskEntry entry) =>
      account.invalidations.any((i) => _matches(entry, i));

  /// Binding is supplied only by a verified activation caller. It can arrive
  /// before recovery; the rendezvous never interprets accountsLoaded as ready.
  Future<bool> activate(DiskBinding binding) {
    if (binding.generation < _domain.highestGeneration ||
        binding.generation <= _domain.revokedThrough ||
        (binding.generation == _domain.highestGeneration &&
            _domain.latestVerified != null &&
            _domain.latestVerified != binding)) {
      return Future.value(false);
    }
    final offline = _domain.offlineBinding;
    if (offline != null) {
      _domain.namespace?.fence(offline.accountKey);
      _account(offline.accountKey).epoch++;
      _account(offline.accountKey).state = ReadCacheDiskState.closed;
      _domain.offlineBinding = null;
    }
    _domain.highestGeneration = binding.generation;
    _domain.latestVerified = binding;
    final previous = _domain.active;
    if (previous != binding && previous != null) revoke(previous);
    _domain.active = binding;
    final account = _account(binding.accountKey);
    if (account.cleanup &&
        account.clearComplete &&
        account.intent == null &&
        account.sessionFence != binding) {
      account.cleanup = false;
      account.state = ReadCacheDiskState.closed;
    }
    if (!_gates(binding)) return Future.value(false);
    return _serial(account, () => _prepare(binding));
  }

  Future<bool> _prepare(DiskBinding binding) async {
    final account = _account(binding.accountKey);
    if (!_gates(binding)) return false;
    final epoch = account.epoch;
    bool current() => _gates(binding) && epoch == account.epoch;
    final marker = await _keys!.readMarker(account.key);
    if (!current()) return false;
    if (marker.status == ReadCacheStoreReadStatus.unavailable) {
      _unavailable(account, binding);
      return false;
    }
    if (marker.isFound) {
      final intent = account.intent;
      final ownedScope =
          intent != null &&
          intent.valid &&
          !intent.full &&
          intent.revision == account.revision &&
          marker.value == intent.marker;
      if (!ownedScope) {
        final namespaceOnly =
            marker.value is ReadCacheClearMarker &&
            (marker.value! as ReadCacheClearMarker).namespaceOnly;
        final full = _fullIntent(
          account,
          namespaceOnly
              ? ReadCacheClearReason.scopeInvalidation
              : ReadCacheClearReason.accountClear,
          accountWide: !namespaceOnly,
        );
        await _clearNow(account, full, hadWork: true);
        return false;
      }
    }
    final read = await _keys!.readKey(account.key);
    if (!current()) return false;
    if (read.status == ReadCacheStoreReadStatus.unavailable) {
      _unavailable(account, binding);
      return false;
    }
    try {
      if (read.isFound) {
        account.keyBytes = read.value;
      } else {
        final directory = await _file(
          () => _files!.accountDirectoryState(account.key),
        );
        final names = await _file(() => _files!.accountDirectoryNames());
        if (!current()) return false;
        if (directory == ReadCacheDirectoryState.hasFiles ||
            (directory == ReadCacheDirectoryState.absent &&
                names.contains(
                  ReadCacheCipher.accountDirectoryName(account.key),
                ))) {
          final intent = _fullIntent(account, ReadCacheClearReason.keyRepair);
          if (intent.accountWide) return false;
          final cleared = await _clearNow(account, intent, hadWork: true);
          if (!cleared.complete || _domain.active != binding) return false;
          // Key repair owns this fence; no other clear may have superseded it.
          if (account.intent != null || account.epoch != epoch + 1) {
            return false;
          }
          account.cleanup = false;
        }
        if (!_gates(binding)) return false;
        final creationEpoch = account.epoch;
        final bytes = Uint8List.fromList(
          List.generate(32, (_) => _random.nextInt(256)),
        );
        await _keys!.writeKey(account.key, bytes);
        if (!_gates(binding) || account.epoch != creationEpoch) {
          // A late secure write is drained before the queued clear deletes it.
          return false;
        }
        final confirmed = await _keys!.readKey(account.key);
        if (!_gates(binding) || account.epoch != creationEpoch) return false;
        if (!confirmed.isFound || !_sameBytes(bytes, confirmed.value!)) {
          _unavailable(account, binding);
          return false;
        }
        account.keyBytes = confirmed.value;
      }
      if (!_gates(binding)) return false;
      final preparedEpoch = account.epoch;
      await _loadIndex(
        account,
        () => _gates(binding) && account.epoch == preparedEpoch,
      );
      if (!_gates(binding) || account.epoch != preparedEpoch) return false;
      _installOfflineNamespace();
      final namespace = _domain.namespace;
      var namespaceReady = false;
      if (namespace != null) {
        final marker = await _keys!.readOfflineMarker(account.key);
        if (!_gates(binding) || account.epoch != preparedEpoch) return false;
        namespaceReady =
            marker.status == ReadCacheStoreReadStatus.absent &&
            !await namespace.hasMarker(account.key);
        if (!_gates(binding) || account.epoch != preparedEpoch) return false;
      }
      account.state = ReadCacheDiskState.ready;
      _domain.offlineBinding = null;
      if (namespaceReady) namespace!.open(binding, ReadCacheDiskState.ready);
      account.retryAttempt = 0;
      account.cancelRetry?.call();
      account.cancelRetry = null;
      return true;
    } on ReadCacheStoreException catch (error) {
      account.indexTrusted = false;
      if (error.failure.kind == ReadCacheStoreFailureKind.unavailable) {
        _unavailable(account, binding);
      } else if (!account.cleanup) {
        account.state = ReadCacheDiskState.closed;
      }
      return false;
    } on Object {
      account.indexTrusted = false;
      if (!account.cleanup) account.state = ReadCacheDiskState.closed;
      return false;
    }
  }

  void _unavailable(_Account account, DiskBinding binding) {
    if (account.cleanup) return;
    account.state = ReadCacheDiskState.unavailable;
    account.keyBytes = null;
    account.cancelRetry?.call();
    if (account.retryAttempt >= 3) return;
    final seconds = [1, 5, 30][account.retryAttempt++];
    account.cancelRetry = _schedule(Duration(seconds: seconds), () {
      account.cancelRetry = null;
      if (_gates(binding)) unawaited(activate(binding));
    });
  }

  Future<void> _loadIndex(_Account account, bool Function() current) async {
    // A partially reconstructed map cannot prove a scoped deletion set.
    account.indexTrusted = false;
    final key = account.keyBytes!;
    ReadCacheIndex? index;
    var readable = true;
    try {
      index = await _file(() => _files!.readIndex(account.key, key));
    } on ReadCacheCodecException {
      // A damaged index never proves a deletion set. Full clear is the fallback.
      readable = false;
    }
    final metadata = {
      for (final m in index?.entries ?? <ReadCacheIndexEntry>[]) m.fileName: m,
    };
    if (!current()) return;
    account.entries.clear();
    final names = await _file(() => _files!.entryFiles(account.key, key));
    if (!current()) return;
    for (final name in names) {
      if (!current()) return;
      ProjectedDiskEntry? entry;
      try {
        entry = await _file(
          () => _files!.readEntryFile(account.key, key, name),
        );
      } on ReadCacheCodecException {
        // Individually corrupt, unsupported or expired cache entries are misses.
      }
      if (!current()) return;
      if (entry == null) {
        await _file(() => _files!.evict(account.key, key, name));
        continue;
      }
      final expected = await const ReadCacheCipher().entryFileName(
        key,
        entry.canonicalKey,
      );
      if (!current()) return;
      if (expected != name) {
        await _file(() => _files!.evict(account.key, key, name));
        continue;
      }
      final publication = account.unindexed[entry.canonicalKey];
      if (publication != null && !publication.isCurrent) {
        await _file(() => _files!.evict(account.key, key, name));
        account.unindexed.remove(entry.canonicalKey);
        continue;
      }
      account.entries[entry.canonicalKey] = _Record(
        entry,
        ReadCacheIndexEntry(
          fileName: name,
          sizeBytes: entry.serializedLength + readCacheEnvelopeOverhead,
          fetchedAt: entry.fetchedAt,
          lastUsedAt: metadata[name]?.lastUsedAt ?? entry.fetchedAt,
          cacheClass: entry.cacheClass,
          scopeTags: entry.scopeTags,
          issueIdentities: entry.issueIdentities,
        ),
      );
    }
    if (!current()) return;
    await _file(() => _files!.removeStaleTemporaryFiles(account.key, key));
    if (!current()) return;
    account.unindexed.removeWhere(
      (name, _) => !account.entries.containsKey(name),
    );
    account.indexTrusted =
        readable &&
        account.unindexed.isEmpty &&
        ((index == null && account.entries.isEmpty) ||
            (index != null &&
                metadata.length == account.entries.length &&
                account.entries.values.every(
                  (r) => metadata.containsKey(r.index.fileName),
                )));
    account.indexDirty = !account.indexTrusted;
  }

  Future<ProjectedDiskEntry?> lookup(DiskLookup lookup) {
    if (!_ready(lookup.binding) || !lookup.lease.isCurrent) {
      return Future.value(null);
    }
    final account = _account(lookup.binding.accountKey);
    final epoch = account.epoch;
    final lease = _CommitLease(
      () =>
          _ready(lookup.binding) &&
          epoch == account.epoch &&
          account.unindexed[lookup.canonicalKey]?.isCurrent != false &&
          lookup.lease.isCurrent,
    );
    account.reads.add(lease);
    return _serial(account, () async {
      try {
        if (!lease.isCurrent) return null;
        final keyRead = await _keys!.readKey(account.key);
        if (!lease.isCurrent) return null;
        if (keyRead.status == ReadCacheStoreReadStatus.unavailable) {
          _unavailable(account, lookup.binding);
          return null;
        }
        if (!keyRead.isFound) {
          final intent = _fullIntent(account, ReadCacheClearReason.keyRepair);
          if (intent.accountWide) return null;
          await _clearNow(account, intent, hadWork: true);
          return null;
        }
        ProjectedDiskEntry? value;
        var rejected = false;
        try {
          value = await _file(
            () => _files!.readEntry(
              account.key,
              keyRead.value,
              lookup.canonicalKey,
              expectedBodyKind: lookup.bodyKind,
            ),
          );
        } on ReadCacheCodecException catch (error) {
          if (error.error != ReadCacheCodecError.bindingMismatch) rethrow;
          rejected = true;
        } on ReadCacheFileException catch (error) {
          if (error.code != ReadCacheFileFailure.tooLarge) rethrow;
          rejected = true;
        }
        if (!lease.isCurrent) return null;
        final record = account.entries[lookup.canonicalKey];
        // A cold miss changes no deletion set. A rejected file still needs
        // eviction when it was never represented by an in-memory record.
        if (value == null && (record != null || rejected)) {
          final name =
              record?.index.fileName ??
              await const ReadCacheCipher().entryFileName(
                keyRead.value!,
                lookup.canonicalKey,
              );
          if (!lease.isCurrent) return null;
          await _file(() => _files!.evict(account.key, keyRead.value, name));
          account.entries.remove(lookup.canonicalKey);
          account.unindexed.remove(lookup.canonicalKey);
          account.indexTrusted = false;
          account.indexDirty = true;
        } else if (value != null && record != null) {
          account.entries[lookup.canonicalKey] = _Record(
            value,
            _used(record.index, _clock()),
          );
          account.indexDirty = true;
        }
        return value != null && !_blocked(account, value) ? value : null;
      } on Object {
        return null;
      } finally {
        account.reads.remove(lease);
      }
    });
  }

  void accept(DiskWriteCandidate candidate, ProjectedDiskEntry entry) {
    final binding = candidate.binding;
    if (!_ready(binding) ||
        !candidate.lease.isCurrent ||
        !candidate.cacheable ||
        candidate.noStore ||
        !candidate.firstPage ||
        candidate.method != 'GET' ||
        binding.accountKey != entry.accountKey) {
      return;
    }
    int bytes;
    try {
      bytes = const ReadCacheCipher().encodeEntry(entry).length;
    } on Object {
      _domain.dropped++;
      return;
    }
    if (bytes > queueByteLimit) {
      _domain.dropped++;
      return;
    }
    final account = _account(binding.accountKey);
    if (_blocked(account, entry)) return;
    final epoch = account.epoch;
    final work = _Write(
      entry,
      bytes,
      _CommitLease(
        () =>
            _ready(binding) &&
            account.epoch == epoch &&
            candidate.lease.isCurrent,
      ),
    );
    while (account.pending.isNotEmpty &&
        account.queuedBytes + bytes > queueByteLimit) {
      _drop(account, account.pending.removeFirst());
    }
    account.pending.add(work);
    account.queuedBytes += bytes;
    account.batchDeadline ??= _clock().add(batchDelay);
    _scheduleBatch(binding);
    if (account.pending.length >= batchEntries) {
      unawaited(_flush(binding, force: false));
    }
  }

  void _scheduleBatch(DiskBinding binding) {
    final account = _account(binding.accountKey);
    if (account.cancelBatch != null ||
        (account.pending.isEmpty && !account.indexDirty)) {
      return;
    }
    account.batchDeadline ??= _clock().add(batchDelay);
    final delay = account.batchDeadline!.difference(_clock());
    account.cancelBatch = _schedule(
      delay.isNegative ? Duration.zero : delay,
      () {
        account.cancelBatch = null;
        unawaited(_flush(binding, force: false));
      },
    );
  }

  Future<void> flush(DiskBinding binding) => _flush(binding, force: true);

  Future<void> _flush(DiskBinding binding, {required bool force}) {
    final account = _account(binding.accountKey);
    account.flushForced |= force;
    final running = account.flush;
    if (running != null) return running;
    if (!_ready(binding) || (account.pending.isEmpty && !account.indexDirty)) {
      account.flushForced = false;
      return Future.value();
    }
    late final Future<void> flight;
    flight =
        _serial(account, () async {
          try {
            while (_ready(binding)) {
              if (account.pending.isEmpty && !account.indexDirty) return;
              if (!account.flushForced &&
                  account.pending.isNotEmpty &&
                  account.pending.length < batchEntries &&
                  _clock().isBefore(account.batchDeadline!)) {
                _scheduleBatch(binding);
                return;
              }
              final epoch = account.epoch;
              final indexRevision = account.indexRevision;
              bool current() => _ready(binding) && account.epoch == epoch;
              final deadline = _clock().add(batchDelay);
              account.cancelBatch?.call();
              account.cancelBatch = null;
              final keyRead = await _keys!.readKey(account.key);
              if (!current()) return;
              if (keyRead.status == ReadCacheStoreReadStatus.unavailable) {
                _dropQueue(account);
                _unavailable(account, binding);
                return;
              }
              if (!keyRead.isFound) {
                final intent = _fullIntent(
                  account,
                  ReadCacheClearReason.keyRepair,
                );
                if (intent.accountWide) return;
                await _clearNow(account, intent, hadWork: true);
                return;
              }
              account.keyBytes = keyRead.value;
              await _evictStalePublications(account, current);
              if (!current()) return;
              var processed = 0;
              while (account.pending.isNotEmpty &&
                  current() &&
                  processed < batchEntries &&
                  (processed == 0 || _clock().isBefore(deadline))) {
                final work = account.pending.removeFirst();
                account.queuedBytes -= work.bytes;
                account.inFlight.add(work);
                processed++;
                try {
                  if (!work.lease.isCurrent) continue;
                  if (!await _makeRoom(
                    account,
                    work.bytes +
                        readCacheEnvelopeOverhead +
                        readCacheIndexLimit +
                        readCacheEnvelopeOverhead,
                    () => work.lease.isCurrent,
                  )) {
                    _domain.dropped++;
                    continue;
                  }
                  if (!work.lease.isCurrent) continue;
                  if (processed > 1 && !_clock().isBefore(deadline)) {
                    // Capacity checks can yield past the deadline. Commit the
                    // completed batch before staging another entry.
                    account.pending.addFirst(work);
                    account.queuedBytes += work.bytes;
                    break;
                  }
                  final staged = await _file(
                    () => _files!.stageEntry(
                      work.entry,
                      account.keyBytes,
                      mayCommit: () => work.lease.isCurrent,
                    ),
                  );
                  if (staged == null) continue;
                  await _file(() {
                    if (staged.commit() != ReadCacheCommitResult.committed) {
                      return;
                    }
                    account.entries[work.entry.canonicalKey] = _Record(
                      work.entry,
                      ReadCacheIndexEntry(
                        fileName: staged.fileName,
                        sizeBytes: staged.ciphertextBytes,
                        fetchedAt: work.entry.fetchedAt,
                        lastUsedAt: _clock().toUtc(),
                        cacheClass: work.entry.cacheClass,
                        scopeTags: work.entry.scopeTags,
                        issueIdentities: work.entry.issueIdentities,
                      ),
                    );
                    account.unindexed[work.entry.canonicalKey] = work.lease;
                    account.indexDirty = true;
                  });
                } finally {
                  account.inFlight.remove(work);
                }
              }
              bool indexCurrent() =>
                  current() && account.indexRevision == indexRevision;
              while (account.indexDirty && indexCurrent()) {
                if (await _commitIndex(account, indexCurrent)) break;
                if (!indexCurrent() ||
                    !account.unindexed.values.any(
                      (lease) => !lease.isCurrent,
                    )) {
                  break;
                }
                await _evictStalePublications(account, indexCurrent);
              }
              if (!current()) return;
              if (account.pending.isEmpty) {
                account.cancelBatch?.call();
                account.cancelBatch = null;
                account.batchDeadline = null;
                if (account.indexDirty) _scheduleBatch(binding);
                return;
              }
              account.batchDeadline = _clock().add(batchDelay);
            }
          } on Object {
            if (!account.cleanup) account.state = ReadCacheDiskState.closed;
            _dropQueue(account);
          } finally {
            account.flushForced = false;
          }
        }).whenComplete(() {
          if (identical(account.flush, flight)) account.flush = null;
        });
    account.flush = flight;
    return flight;
  }

  Future<void> _evictStalePublications(
    _Account account,
    bool Function() current,
  ) async {
    for (final publication in account.unindexed.entries.toList()) {
      if (!current()) return;
      if (publication.value.isCurrent) continue;
      final record = account.entries[publication.key];
      if (record != null) {
        await _file(
          () => _files!.evict(
            account.key,
            account.keyBytes,
            record.index.fileName,
          ),
        );
        account.entries.remove(publication.key);
      }
      account.unindexed.remove(publication.key);
      account.indexDirty = true;
    }
  }

  Future<bool> _makeRoom(
    _Account account,
    int incoming,
    bool Function() current,
  ) async {
    final unavailable = <_Account>{};
    while (current()) {
      final usage = await _file(
        () => _files!.usage(account.key, account.keyBytes),
      );
      if (!current()) return false;
      final accountFull =
          usage.accountBytes + incoming > readCacheAccountByteLimit;
      final deviceFull =
          usage.deviceBytes + incoming > readCacheDeviceByteLimit;
      if (!accountFull && !deviceFull) return true;
      final candidates = <(_Account, _Record)>[
        for (final owner in _domain.accounts.values)
          if (owner.keyBytes != null &&
              !owner.cleanup &&
              (!accountFull || owner == account) &&
              !unavailable.contains(owner))
            for (final entry in owner.entries.values) (owner, entry),
      ]..sort((a, b) => a.$2.index.lastUsedAt.compareTo(b.$2.index.lastUsedAt));
      if (candidates.isEmpty) return false;
      final (owner, victim) = candidates.first;
      final key = await _keys!.readKey(owner.key);
      if (!current()) return false;
      if (!key.isFound) {
        unavailable.add(owner);
        continue;
      }
      await _file(
        () => _files!.evict(owner.key, key.value, victim.index.fileName),
      );
      if (!current()) return false;
      owner.entries.remove(victim.entry.canonicalKey);
      owner.unindexed.remove(victim.entry.canonicalKey);
      owner.indexTrusted = false;
      owner.indexDirty = true;
    }
    return false;
  }

  Future<bool> _commitIndex(_Account account, bool Function() current) async {
    bool permitted() =>
        current() && account.unindexed.values.every((lease) => lease.isCurrent);
    while (permitted()) {
      final index = ReadCacheIndex(
        entries: account.entries.values.map((e) => e.index).toList(),
      );
      late int indexBytes;
      try {
        indexBytes = const ReadCacheCipher().encodeIndex(index).length;
      } on ReadCacheCodecException {
        if (account.entries.isEmpty) rethrow;
        final oldest = account.entries.values.reduce(
          (a, b) => a.index.lastUsedAt.isBefore(b.index.lastUsedAt) ? a : b,
        );
        await _file(
          () => _files!.evict(
            account.key,
            account.keyBytes,
            oldest.index.fileName,
          ),
        );
        account.entries.remove(oldest.entry.canonicalKey);
        account.unindexed.remove(oldest.entry.canonicalKey);
        continue;
      }
      if (!await _makeRoom(
        account,
        indexBytes + readCacheEnvelopeOverhead,
        permitted,
      )) {
        if (!permitted()) return false;
        throw const ReadCacheFileException(ReadCacheFileFailure.capacity);
      }
      if (!permitted()) return false;
      if (index.entries.length != account.entries.length) continue;
      final staged = await _file(
        () => _files!.stageIndex(
          account.key,
          account.keyBytes,
          index,
          mayCommit: permitted,
        ),
      );
      if (staged == null) return false;
      return _file(() {
        if (staged.commit() == ReadCacheCommitResult.committed) {
          account.indexTrusted = true;
          account.indexDirty = false;
          account.unindexed.clear();
          return true;
        }
        return false;
      });
    }
    return false;
  }

  void _drop(_Account account, _Write work) {
    account.queuedBytes -= work.bytes;
    work.lease.revoke();
    _domain.dropped++;
  }

  void _dropQueue(_Account account) {
    while (account.pending.isNotEmpty) {
      _drop(account, account.pending.removeFirst());
    }
    account.cancelBatch?.call();
    account.cancelBatch = null;
    account.batchDeadline = null;
  }

  void revoke(DiskBinding binding) {
    final account = _account(binding.accountKey);
    if (_domain.active != binding) return;
    _domain.namespace?.fence(binding.accountKey);
    _domain.revokedThrough = max(_domain.revokedThrough, binding.generation);
    account.epoch++;
    account.state = account.cleanup
        ? ReadCacheDiskState.cleaning
        : ReadCacheDiskState.closed;
    _dropQueue(account);
    for (final work in account.inFlight) {
      work.lease.revoke();
    }
    for (final lease in account.reads) {
      lease.revoke();
    }
    if (_domain.active == binding) _domain.active = null;
  }

  void background() {
    _domain.foreground = false;
    _suspendAccounts();
  }

  void _suspendAccounts() {
    for (final account in _domain.accounts.values) {
      account.epoch++;
      _dropQueue(account);
      for (final work in account.inFlight) {
        work.lease.revoke();
      }
      // C3 workers retain their own admission/epochs while backgrounded (B9).
      if (!account.cleanup &&
          account.state != ReadCacheDiskState.offlineReadOnly) {
        account.state = ReadCacheDiskState.closed;
      }
    }
  }

  Future<bool> resume(DiskBinding binding) async {
    _domain.foreground = true;
    if (!configured) return false;
    _domain.setting = await _settings!.read();
    return activate(binding);
  }

  _Intent _fullIntent(
    _Account account,
    ReadCacheClearReason reason, {
    bool accountWide = true,
  }) {
    // Key repair and uncertain C2 projections must not erase saved projects.
    accountWide = accountWide && reason != ReadCacheClearReason.keyRepair;
    final current = account.intent;
    // A pending account-wide clear stays the owner. A C2 fallback must not
    // replace its intent, marker, or completion proof.
    if (!accountWide && current != null && current.accountWide) {
      return current;
    }
    account.epoch++;
    account.cleanup = true;
    account.clearComplete = false;
    account.state = ReadCacheDiskState.cleaning;
    account.cancelRetry?.call();
    account.cancelRetry = null;
    _dropQueue(account);
    for (final work in account.inFlight) {
      work.lease.revoke();
    }
    for (final lease in account.reads) {
      lease.revoke();
    }
    account.keyBytes = null;
    if (accountWide) {
      _domain.namespace?.fence(account.key);
      if (_domain.offlineBinding?.accountKey == account.key) {
        _domain.offlineBinding = null;
      }
    }
    final intent = _Intent(
      _marker(reason, namespaceOnly: !accountWide),
      ++account.revision,
      full: true,
      accountWide: accountWide,
    );
    account.intent = intent;
    return intent;
  }

  ReadCacheClearMarker _marker(
    ReadCacheClearReason reason, {
    bool namespaceOnly = false,
  }) => ReadCacheClearMarker(
    intentId: List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join(),
    reason: reason,
    requestedAt: _clock().toUtc(),
    namespaceOnly: namespaceOnly,
  );

  Future<T> _markerSerial<T>(_Account account, Future<T> Function() action) {
    final result = Completer<T>();
    account.markerTail = account.markerTail.then((_) async {
      try {
        result.complete(await action());
      } on Object catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<bool> _persist(_Account account, _Intent intent) =>
      _markerSerial(account, () => _persistNow(account, intent));

  Future<bool> _persistNow(_Account account, _Intent intent) async {
    try {
      if (account.intent != intent || !intent.valid) return false;
      if (!intent.durable) await _keys!.writeMarker(account.key, intent.marker);
      final read = await _keys!.readMarker(account.key);
      intent.durable = read.isFound && read.value == intent.marker;
      return intent.durable;
    } on Object {
      intent.durable = false;
      return false;
    }
  }

  Future<bool> _removeIntent(_Account account, _Intent intent) =>
      _markerSerial(account, () => _removeIntentNow(account, intent));

  Future<bool> _removeIntentNow(_Account account, _Intent intent) async {
    if (account.intent != intent || !intent.durable || !intent.valid) {
      return false;
    }
    try {
      final read = await _keys!.readMarker(account.key);
      if (account.intent != intent ||
          !intent.valid ||
          !read.isFound ||
          read.value != intent.marker) {
        return false;
      }
      await _keys!.deleteMarker(account.key);
      if (account.intent != intent || !intent.valid) {
        // The native delete was already in flight when this owner was revoked.
        // Restore the current pending intent before releasing the I/O section.
        var pending = account.intent;
        if (pending != null) {
          if (!pending.valid) {
            pending = _fullIntent(
              account,
              pending.accountWide
                  ? ReadCacheClearReason.accountClear
                  : ReadCacheClearReason.scopeInvalidation,
              accountWide: pending.accountWide,
            );
          }
          pending.durable = false;
          await _persistNow(account, pending);
        }
        return false;
      }
      account.intent = null;
      return true;
    } on Object {
      if (account.intent != intent || !intent.valid) {
        var pending = account.intent;
        if (pending != null) {
          if (!pending.valid) {
            pending = _fullIntent(
              account,
              pending.accountWide
                  ? ReadCacheClearReason.accountClear
                  : ReadCacheClearReason.scopeInvalidation,
              accountWide: pending.accountWide,
            );
          }
          pending.durable = false;
          await _persistNow(account, pending);
        }
      }
      return false;
    }
  }

  Future<bool> _directoryGone(String accountKey) async {
    final state = await _file(() => _files!.accountDirectoryState(accountKey));
    final names = await _file(() => _files!.accountDirectoryNames());
    return state == ReadCacheDirectoryState.absent &&
        !names.contains(ReadCacheCipher.accountDirectoryName(accountKey));
  }

  Future<bool> _offlineDirectoryGone(String accountKey) async {
    final state = await _files!.offlineAccountDirectoryState(accountKey);
    final names = await _files!.offlineAccountDirectoryNames();
    return state == ReadCacheDirectoryState.absent &&
        !names.contains(ReadCacheCipher.accountDirectoryName(accountKey));
  }

  Future<bool> _stopNamespace(String accountKey) async {
    try {
      await _domain.namespace?.stopAndWait(accountKey);
      return true;
    } on Object {
      return false;
    }
  }

  Future<bool> _deleteOfflineKey(String accountKey) async {
    var ok = true;
    try {
      await _domain.namespace?.deleteKey(accountKey);
    } on Object {
      ok = false;
    }
    try {
      await _keys!.deleteOfflineKey(accountKey);
      return ok &&
          (await _keys!.readOfflineKey(accountKey)).status ==
              ReadCacheStoreReadStatus.absent;
    } on Object {
      return false;
    }
  }

  Future<bool> _deleteOfflineDirectory(String accountKey) async {
    var ok = true;
    try {
      await _domain.namespace?.deleteDirectory(accountKey);
    } on Object {
      ok = false;
    }
    try {
      await _files!.clearOfflineAccount(accountKey);
      return await _offlineDirectoryGone(accountKey) && ok;
    } on Object {
      return false;
    }
  }

  Future<bool> _deleteOfflineMarkers(String accountKey) async {
    var ok = true;
    try {
      await _keys!.deleteOfflineRefusal(accountKey);
    } on Object {
      ok = false;
    }
    try {
      await _keys!.deleteOfflineMarker(accountKey);
    } on Object {
      ok = false;
    }
    return ok;
  }

  Future<bool> _recoverOfflineClear(String accountKey) async {
    _domain.namespace?.fence(accountKey);
    if (!await _stopNamespace(accountKey)) return false;
    final keyGone = await _deleteOfflineKey(accountKey);
    final directoryGone = await _deleteOfflineDirectory(accountKey);
    if (!keyGone || !directoryGone) return false;
    try {
      await _keys!.deleteOfflineMarker(accountKey);
      return true;
    } on Object {
      return false;
    }
  }

  Future<bool> _clearMalformedInventory(
    ReadCacheSecureInventory inventory,
  ) async {
    final c2 = inventory.malformedNames.any(
      (name) =>
          name.startsWith(ReadCacheKeyStore.keyPrefix) ||
          name.startsWith(ReadCacheKeyStore.markerPrefix),
    );
    final offline = inventory.malformedNames.any(
      (name) =>
          name.startsWith(ReadCacheKeyStore.offlineKeyPrefix) ||
          name.startsWith(ReadCacheKeyStore.offlineMarkerPrefix) ||
          name.startsWith(ReadCacheKeyStore.offlineRefusalPrefix),
    );
    if (offline) {
      for (final account in _domain.accounts.values) {
        _domain.namespace?.fence(account.key);
      }
      for (final account in _domain.accounts.values) {
        if (!await _stopNamespace(account.key)) return false;
      }
    }
    // Paths never come from undecodable secure-storage input.
    if (c2) {
      await _file(() => _files!.clearRoot(), clearingRoot: true);
      if ((await _file(() => _files!.accountDirectoryNames())).isNotEmpty) {
        return false;
      }
    }
    if (offline) {
      await _files!.clearOfflineRoot();
      if ((await _files!.offlineAccountDirectoryNames()).isNotEmpty) {
        return false;
      }
    }
    for (final name in inventory.malformedNames) {
      await _keys!.deleteInventoryName(name);
    }
    return true;
  }

  Future<bool> _empty(
    _Account account,
    ReadCacheSecureInventory inventory,
    bool hadWork, {
    bool accountWide = true,
  }) async =>
      inventory.status == ReadCacheStoreReadStatus.found &&
      inventory.malformedNames.isEmpty &&
      !inventory.keys.containsKey(account.key) &&
      !inventory.markers.containsKey(account.key) &&
      !hadWork &&
      account.pending.isEmpty &&
      account.inFlight.isEmpty &&
      account.reads.isEmpty &&
      await _directoryGone(account.key) &&
      (!accountWide ||
          (!inventory.containsAccount(account.key) &&
              _domain.namespace == null &&
              await _offlineDirectoryGone(account.key)));

  Future<DiskClearResult> _clearNow(
    _Account account,
    _Intent intent, {
    required bool hadWork,
    Future<bool>? markerReady,
  }) async {
    if (!configured) return _none;
    final pathRevision = _domain.pathRevision;
    // Revoked callers can have abandoned an already dispatched native marker
    // write. Drain that lane before taking the inventory used to prove empty.
    await account.markerTail;
    final inventory = await _keys!.readInventory();
    try {
      if (await _empty(
        account,
        inventory,
        hadWork,
        accountWide: intent.accountWide,
      )) {
        if (account.intent != intent || !intent.valid) return _none;
        account.intent = null;
        account.clearComplete = true;
        intent.completed = true;
        return const DiskClearResult(
          keyGoneConfirmed: true,
          directoryGoneConfirmed: true,
          markerDurable: false,
          complete: true,
        );
      }
    } on Object {
      // Unknown is not empty. Still attempt both independent explicit deletes.
      // A path incident during this proof retires this attempt below; a later
      // removal retry can join the replacement intent after root cleanup.
    }
    // Caller timeout or a same-owner join must still allow late key/directory
    // deletion. Only a new path incident retires this work entirely; marker
    // persistence/removal retain their separate exact-owner checks.
    if (pathRevision != _domain.pathRevision) return _none;
    final durable = await (markerReady ?? _persist(account, intent));
    if (intent.accountWide && !await _stopNamespace(account.key)) {
      return DiskClearResult(
        keyGoneConfirmed: false,
        directoryGoneConfirmed: false,
        markerDurable: durable,
        complete: false,
      );
    }
    var keyGone = false, directoryGone = false;
    try {
      await _keys!.deleteKey(account.key);
      keyGone =
          (await _keys!.readKey(account.key)).status ==
          ReadCacheStoreReadStatus.absent;
    } on Object {
      // Directory deletion proceeds even if secure storage is unavailable.
    }
    final offlineKeyGone =
        !intent.accountWide || await _deleteOfflineKey(account.key);
    try {
      await _file(() => _files!.clearAccount(account.key));
      directoryGone = await _directoryGone(account.key);
    } on Object {
      // Neither an acknowledgement nor an I/O error is evidence of absence.
    }
    if (pathRevision != _domain.pathRevision) {
      return DiskClearResult(
        keyGoneConfirmed: keyGone && offlineKeyGone,
        directoryGoneConfirmed: false,
        markerDurable: false,
        complete: false,
      );
    }
    final offlineDirectoryGone =
        !intent.accountWide || await _deleteOfflineDirectory(account.key);
    final offlineMarkersGone =
        !intent.accountWide ||
        (offlineKeyGone &&
            offlineDirectoryGone &&
            await _deleteOfflineMarkers(account.key));
    keyGone = keyGone && offlineKeyGone;
    directoryGone = directoryGone && offlineDirectoryGone;
    // A path incident installed a replacement owner. Preserve deletion proofs
    // for removal without completing or modifying that replacement intent.
    if (pathRevision != _domain.pathRevision) {
      return DiskClearResult(
        keyGoneConfirmed: keyGone,
        directoryGoneConfirmed: directoryGone,
        markerDurable: false,
        complete: false,
      );
    }
    account.entries.clear();
    account.unindexed.clear();
    account.indexTrusted = false;
    account.indexDirty = false;
    var complete = false;
    if (keyGone &&
        directoryGone &&
        offlineMarkersGone &&
        durable &&
        inventory.status == ReadCacheStoreReadStatus.found &&
        inventory.malformedNames.isEmpty) {
      complete = await _removeIntent(account, intent);
      if (complete) {
        account.invalidations.clear();
        account.clearComplete = true;
        intent.completed = true;
        // Retained selection belongs to the current session/startup owner.
        // This clear may be finishing after a newer same-account activation.
      }
    }
    return DiskClearResult(
      keyGoneConfirmed: keyGone,
      directoryGoneConfirmed: directoryGone,
      markerDurable: durable,
      complete: complete,
    );
  }

  Future<DiskClearResult> clear(
    DiskBinding binding,
    ReadCacheCleanupOperation operation, {
    Object? sessionOwner,
    void Function(ApiFailure)? onFailure,
  }) {
    final account = _account(binding.accountKey);
    final pathRevision = _domain.pathRevision;
    _domain.startupRevision++;
    if (operation == ReadCacheCleanupOperation.accountRemoval ||
        operation == ReadCacheCleanupOperation.signOut) {
      account.sessionFence = binding;
    }
    final hadWork =
        _domain.work > 0 ||
        account.work > 0 ||
        account.pending.isNotEmpty ||
        account.inFlight.isNotEmpty ||
        account.reads.isNotEmpty;
    final intent = _fullIntent(account, ReadCacheClearReason.accountClear);
    // Persist before waiting for old file/key work. The intent lane is separate
    // from the draining I/O lane, so a paused isolate cannot delay the marker.
    final preferencePending = _domain.preferenceChanges > 0;
    final markerReady = configured && hadWork && !preferencePending
        ? _persist(account, intent)
        : null;
    final future = _serial(account, () async {
      if (pathRevision != _domain.pathRevision) return _none;
      var result = await _clearNow(
        account,
        intent,
        // A preceding preference sweep drains the historical work. Prove empty
        // again here instead of starting a late marker for that drained work.
        hadWork: hadWork && !preferencePending,
        markerReady: markerReady,
      );
      // A preceding barrier may have completed this exact full-clear owner.
      // Never join across a path incident, which installs a replacement owner.
      // A narrower fallback must not satisfy an account-wide clear: the proof
      // stays on that owner and its revision, after its own scope was emptied.
      if (pathRevision == _domain.pathRevision &&
          !result.complete &&
          intent.completed &&
          intent.accountWide &&
          intent.revision == account.revision &&
          account.intent == null &&
          intent.valid) {
        result = const DiskClearResult(
          keyGoneConfirmed: true,
          directoryGoneConfirmed: true,
          markerDurable: false,
          complete: true,
        );
      }
      if (result.complete && account.intent == null && intent.valid) {
        // Activation decides whether the verified binding may reopen its fence.
        account.state = account.cleanup
            ? ReadCacheDiskState.cleaning
            : ReadCacheDiskState.closed;
        supersedeNotice(binding);
      }
      return result;
    });
    return _wait(
      binding,
      operation,
      future,
      () {
        if (pathRevision == _domain.pathRevision && account.intent == intent) {
          intent.valid = false;
          account.epoch++;
          account.cleanup = true;
          account.state = ReadCacheDiskState.cleaning;
        }
      },
      sessionOwner: sessionOwner,
      onFailure: onFailure,
    ).then((result) {
      if (result.complete &&
          pathRevision == _domain.pathRevision &&
          intent.valid &&
          operation == ReadCacheCleanupOperation.settingsClear &&
          _domain.active == binding) {
        unawaited(activate(binding));
      }
      return result;
    });
  }

  Future<void> clearReadCacheDisk(String accountKey) async {
    final binding = _domain.active?.accountKey == accountKey
        ? _domain.active!
        : DiskBinding(accountKey: accountKey, generation: 0);
    ApiFailure? failure;
    final result = await clear(
      binding,
      ReadCacheCleanupOperation.accountRemoval,
      onFailure: (value) => failure = value,
    );
    if (!result.keyGoneConfirmed && !result.directoryGoneConfirmed) {
      throw failure ??
          ApiFailure.readCacheCleanup(
            _cleanup(
              ReadCacheCleanupOperation.accountRemoval,
              result,
              ReadCacheCleanupCode.cleanupFailed,
            ),
          );
    }
  }

  ReadCacheCleanupState _cleanup(
    ReadCacheCleanupOperation operation,
    DiskClearResult result,
    ReadCacheCleanupCode code,
  ) => ReadCacheCleanupState(
    operation: operation,
    disposition: switch (operation) {
      ReadCacheCleanupOperation.mutation =>
        ReadCacheCleanupDisposition.requestBlockedBeforeSend,
      ReadCacheCleanupOperation.privacyRead =>
        ReadCacheCleanupDisposition.legalNetworkValueReturned,
      ReadCacheCleanupOperation.accountRemoval =>
        result.keyGoneConfirmed || result.directoryGoneConfirmed
            ? ReadCacheCleanupDisposition.diskClosed
            : ReadCacheCleanupDisposition.accountRetained,
      ReadCacheCleanupOperation.signOut =>
        ReadCacheCleanupDisposition.signedOutCleanupPending,
      _ => ReadCacheCleanupDisposition.diskClosed,
    },
    code: code,
    clearResult: result,
  );

  Future<DiskClearResult> _wait(
    DiskBinding binding,
    ReadCacheCleanupOperation operation,
    Future<DiskClearResult> underlying,
    void Function() timeout, {
    bool Function(DiskClearResult)? succeeded,
    Object? sessionOwner,
    void Function(ApiFailure)? onFailure,
  }) {
    final result = Completer<DiskClearResult>();
    // Keep the actual wait outcome with this invocation. Notices may move or
    // be superseded synchronously by observers before the caller resumes.
    void report(DiskClearResult value, ReadCacheCleanupCode code) {
      final state = _cleanup(operation, value, code);
      final failure = reportCleanup(binding, state);
      onFailure?.call(failure);
    }

    final cancel = _schedule(barrierLimit, () {
      timeout();
      report(_none, ReadCacheCleanupCode.barrierTimedOut);
      result.complete(_none);
    });
    void release() {
      if (result.isCompleted) return;
      cancel();
      report(_none, ReadCacheCleanupCode.cleanupFailed);
      result.complete(_none);
    }

    // Confirmed removal jobs outlive their page/controller. Their deadlines,
    // and transport-owned mutation/privacy barriers, keep their own lifetime.
    if (sessionOwner != null) {
      (_domain.waits[sessionOwner] ??= {}).add(release);
    }
    unawaited(
      underlying.then(
        (value) {
          if (result.isCompleted) return;
          cancel();
          if (!(succeeded?.call(value) ?? value.complete)) {
            report(value, ReadCacheCleanupCode.cleanupFailed);
          }
          result.complete(value);
        },
        onError: (Object _, StackTrace _) {
          if (result.isCompleted) return;
          cancel();
          report(_none, ReadCacheCleanupCode.cleanupFailed);
          result.complete(_none);
        },
      ),
    );
    return result.future.whenComplete(() {
      final waits = _domain.waits[sessionOwner];
      waits?.remove(release);
      if (waits?.isEmpty ?? false) _domain.waits.remove(sessionOwner);
    });
  }

  DiskInvalidationFence invalidate(DiskInvalidation invalidation) {
    final binding = invalidation.binding;
    final account = _account(binding.accountKey);
    final pathRevision = _domain.pathRevision;
    final fence = _Fence();
    if (invalidation.kind == DiskInvalidationKind.account) {
      final barrier = clear(binding, ReadCacheCleanupOperation.signOut);
      fence.finish(barrier, quiesced);
      return fence;
    }
    account.invalidations.add(invalidation);
    account.indexRevision++;
    bool matches(ProjectedDiskEntry entry) => _matches(entry, invalidation);
    for (final work in account.pending.toList()) {
      if (matches(work.entry)) {
        account.pending.remove(work);
        _drop(account, work);
      }
    }
    for (final work in account.inFlight) {
      if (matches(work.entry)) work.lease.revoke();
    }
    for (final record in account.entries.values) {
      if (matches(record.entry)) {
        account.unindexed[record.entry.canonicalKey]?.revoke();
      }
    }
    // A read may have passed its disk await. Reject all active reads rather than
    // guess which body it will contain; subsequent unrelated reads stay allowed.
    for (final lease in account.reads) {
      lease.revoke();
    }
    // A full-clear fence already owns the marker. Join it without introducing
    // a scope intent that could outlive the completed clear.
    final preferencePending = _domain.preferenceChanges > 0;
    final intent = preferencePending
        ? null
        : account.cleanup
        ? account.intent
        : (account.intent ??= _Intent(
            _marker(
              ReadCacheClearReason.scopeInvalidation,
              namespaceOnly: true,
            ),
            ++account.revision,
            full: false,
            accountWide: false,
          ));
    if (intent != null && !intent.full) intent.users++;
    final proveEmpty = !account.indexTrusted && !_ready(binding);
    final markerReady = intent != null && !intent.full && !proveEmpty
        ? _persist(account, intent)
        : null;
    final operation = invalidation.kind == DiskInvalidationKind.privacy
        ? ReadCacheCleanupOperation.privacyRead
        : ReadCacheCleanupOperation.mutation;
    var scopeSucceeded = false;
    final raw = _serial(account, () async {
      try {
        if (!configured ||
            !fence.isCurrent ||
            pathRevision != _domain.pathRevision) {
          return _none;
        }
        if (preferencePending && !account.cleanup) {
          // Settings owns the sweep until this serial section starts. Do not
          // dispatch a marker write behind its final inventory proof.
          final full = _fullIntent(
            account,
            ReadCacheClearReason.scopeInvalidation,
            accountWide: false,
          );
          return await _clearNow(account, full, hadWork: false);
        }
        if (account.cleanup) {
          // Queued barriers, including another account's on this shared lane,
          // may join an ordinary live full clear. A path incident retires older
          // work at the revision check above before it can take the new owner.
          if (account.clearComplete && account.intent == null) {
            account.invalidations.remove(invalidation);
            return const DiskClearResult(
              keyGoneConfirmed: true,
              directoryGoneConfirmed: true,
              markerDurable: false,
              complete: true,
            );
          }
          final full = account.intent;
          if (full == null || !full.full || !full.valid) return _none;
          return await _clearNow(account, full, hadWork: true);
        }
        if (intent == null ||
            intent.full ||
            !intent.valid ||
            account.intent != intent) {
          return _none;
        }
        if (proveEmpty) await account.markerTail;
        if (proveEmpty &&
            await _empty(
              account,
              await _keys!.readInventory(),
              false,
              accountWide: false,
            )) {
          if (!fence.isCurrent ||
              account.intent != intent ||
              !intent.valid ||
              account.cleanup ||
              account.pending.isNotEmpty ||
              account.inFlight.isNotEmpty ||
              account.reads.isNotEmpty) {
            return _none;
          }
          intent.users--;
          if (intent.users == 0) account.intent = null;
          scopeSucceeded = true;
          account.invalidations.remove(invalidation);
          return const DiskClearResult(
            keyGoneConfirmed: true,
            directoryGoneConfirmed: true,
            markerDurable: false,
            complete: true,
          );
        }
        final durable = await (markerReady ?? _persist(account, intent));
        if (account.intent?.accountWide == true && account.intent != intent) {
          return _none;
        }
        if (!durable || !account.indexTrusted) {
          final full = _fullIntent(
            account,
            ReadCacheClearReason.scopeInvalidation,
            accountWide: false,
          );
          return await _clearNow(account, full, hadWork: true);
        }
        final key = await _keys!.readKey(account.key);
        if (account.intent?.accountWide == true && account.intent != intent) {
          return _none;
        }
        if (!key.isFound) {
          final full = _fullIntent(
            account,
            ReadCacheClearReason.scopeInvalidation,
            accountWide: false,
          );
          return await _clearNow(account, full, hadWork: true);
        }
        account.keyBytes = key.value;
        for (final record in account.entries.values.toList()) {
          if (!matches(record.entry)) continue;
          await _file(
            () => _files!.evict(account.key, key.value, record.index.fileName),
          );
          account.entries.remove(record.entry.canonicalKey);
          account.unindexed.remove(record.entry.canonicalKey);
        }
        bool current() =>
            fence.isCurrent &&
            pathRevision == _domain.pathRevision &&
            account.intent == intent &&
            !account.cleanup;
        if (!current()) return _none;
        await _evictStalePublications(account, current);
        if (!current()) return _none;
        while (!await _commitIndex(account, current)) {
          if (!current()) return _none;
          // Match flush's progress check. Escalate if a refusal cannot be
          // explained by a stale publication instead of retrying without work.
          if (!account.unindexed.values.any((lease) => !lease.isCurrent)) {
            final full = _fullIntent(
              account,
              ReadCacheClearReason.scopeInvalidation,
              accountWide: false,
            );
            return await _clearNow(account, full, hadWork: true);
          }
          await _evictStalePublications(account, current);
        }
        if (!current()) return _none;
        intent.users--;
        if (intent.users == 0 && !await _removeIntent(account, intent)) {
          return _none;
        }
        scopeSucceeded = true;
        account.invalidations.remove(invalidation);
        // These are account-clear facts, not a false claim that retained data
        // or its key is gone. A scoped barrier signals success by resolving;
        // failure rejects with readCacheCleanup. Its full-clear fallback must
        // instead prove complete. The adapter must preserve that distinction.
        return DiskClearResult(
          keyGoneConfirmed: false,
          directoryGoneConfirmed: false,
          markerDurable: intent.durable,
          complete: false,
        );
      } on Object {
        if (pathRevision != _domain.pathRevision ||
            account.intent != intent ||
            intent?.accountWide == true) {
          return _none;
        }
        final full = _fullIntent(
          account,
          ReadCacheClearReason.scopeInvalidation,
          accountWide: false,
        );
        return await _clearNow(account, full, hadWork: true);
      }
    });
    final waited = _wait(binding, operation, raw, () {
      fence.revoke();
      if (pathRevision != _domain.pathRevision ||
          account.intent != intent ||
          intent == null ||
          intent.accountWide) {
        return;
      }
      intent.valid = false;
      _fullIntent(
        account,
        ReadCacheClearReason.scopeInvalidation,
        accountWide: false,
      );
    }, succeeded: (value) => scopeSucceeded || value.complete);
    final barrier = waited.then((result) {
      if (scopeSucceeded || result.complete) return result;
      if (pathRevision == _domain.pathRevision &&
          !account.cleanup &&
          account.intent?.accountWide != true) {
        _fullIntent(
          account,
          ReadCacheClearReason.scopeInvalidation,
          accountWide: false,
        );
      }
      throw ApiFailure.readCacheCleanup(
        _notices[binding]?.failure.cleanup ??
            _cleanup(operation, result, ReadCacheCleanupCode.cleanupFailed),
      );
    });
    fence.finish(barrier, quiesced);
    return fence;
  }

  /// Reads a complete inventory before either orphan sweep. Ordinary unknown
  /// settings/storage never authorize filesystem work. The caller owns the
  /// session decision and retries with a new revision when membership changes.
  Future<bool> recover(
    ReadCacheStartupDecision decision, {
    required Set<String> accountKeys,
    Object? sessionOwner,
    Object? startupScan,
  }) async {
    bool ownerCurrent() => sessionOwner == null
        ? _domain.startupOwner == null
        : ownsStartupSession(sessionOwner);
    if (!ownerCurrent() ||
        (startupScan != null &&
            (!identical(startupScan, _domain.startupScan) ||
                _domain.startupScanRevision != _domain.startupRevision))) {
      return false;
    }
    final revision = startupScan == null
        ? ++_domain.startupRevision
        : _domain.startupRevision;
    final pathRevision = _domain.pathRevision;
    bool current() =>
        ownerCurrent() &&
        (startupScan == null || identical(startupScan, _domain.startupScan)) &&
        revision == _domain.startupRevision &&
        pathRevision == _domain.pathRevision;
    _domain.recovered = false;
    if (!configured || !decision.readable || _domain.preferenceChanges > 0) {
      return false;
    }
    final setting = await _settings!.read();
    if (!current() || setting == ReadCacheSettingsState.unavailable) {
      return false;
    }
    _domain.setting = setting;
    if (setting == ReadCacheSettingsState.disabled) {
      _domain.deviceOffPending = true;
      _domain.deviceOffConfirmed = false;
      _domain.diskUsageBytes = null;
    }
    final inventory = await _keys!.readInventory();
    if (!current() || inventory.status != ReadCacheStoreReadStatus.found) {
      return false;
    }
    for (final key in {...accountKeys, ...inventory.accountKeys}) {
      _account(key);
    }
    for (final account in _domain.accounts.values) {
      account.epoch++;
      _dropQueue(account);
      account.state = ReadCacheDiskState.closed;
      _domain.namespace?.fence(account.key);
    }
    final retained =
        !decision.signOutPending &&
            !deviceOffPending &&
            setting == ReadCacheSettingsState.enabled
        ? <String>{
            if (accountKeys.contains(decision.resumeAccountKey))
              decision.resumeAccountKey!,
            if (accountKeys.contains(diskRetainedAccountKey))
              diskRetainedAccountKey!,
          }
        : <String>{};
    final success = await _serial<bool>(null, () async {
      if (!current()) return false;
      var ok = true;
      if (inventory.malformedNames.isNotEmpty) {
        try {
          if (!await _clearMalformedInventory(inventory)) return false;
        } on Object {
          return false;
        }
      }
      for (final key in {
        ...inventory.pendingAccountKeys,
        ...inventory.accountKeys.where((k) => !retained.contains(k)),
        ..._domain.accounts.values
            .where((a) => a.intent?.full == true && a.intent!.valid)
            .map((a) => a.key),
      }) {
        if (!current()) return false;
        final account = _account(key);
        final marker = inventory.markers[key];
        final retainedAccount = retained.contains(key);
        if (retainedAccount &&
            marker == null &&
            inventory.offlineMarkers.containsKey(key)) {
          if (!await _recoverOfflineClear(key)) ok = false;
          continue;
        }
        // Legacy/unknown markers still mean full-account recovery. Only new,
        // explicitly scoped v2 repair markers authorize C2-only cleanup.
        final namespaceOnly =
            retainedAccount &&
            marker?.value is ReadCacheClearMarker &&
            (marker!.value! as ReadCacheClearMarker).namespaceOnly;
        final intent = _fullIntent(
          account,
          namespaceOnly
              ? ReadCacheClearReason.scopeInvalidation
              : ReadCacheClearReason.startup,
          accountWide: !namespaceOnly,
        );
        final result = await _clearNow(account, intent, hadWork: true);
        if (namespaceOnly && inventory.offlineMarkers.containsKey(key)) {
          if (!await _recoverOfflineClear(key)) ok = false;
        }
        if (pathRevision != _domain.pathRevision) return false;
        if (result.complete) {
          account.cleanup = account.sessionFence != null;
          account.state = account.cleanup
              ? ReadCacheDiskState.cleaning
              : ReadCacheDiskState.closed;
        } else {
          ok = false;
        }
      }
      if (!current()) return false;
      try {
        // This path retains recovery's explicit root escalation below.
        await _file(
          () => _files!.clearAccountDirectoriesExcept(retained),
          recoverySweep: true,
        );
      } on ReadCacheFileException catch (error) {
        if (error.code != ReadCacheFileFailure.untrustedPath) return false;
        try {
          await _file(() => _files!.clearRoot(), clearingRoot: true);
        } on Object {
          return false;
        }
        // The new full intents require a fresh inventory/decision even after
        // root cleanup succeeds; this recovery pass cannot reopen the cache.
        return false;
      } on Object {
        return false;
      }
      try {
        await _files!.clearOfflineAccountDirectoriesExcept(retained);
      } on Object {
        return false;
      }
      try {
        final names = await _file(() => _files!.accountDirectoryNames());
        final retainedNames = retained
            .map(ReadCacheCipher.accountDirectoryName)
            .toSet();
        if (names.any((name) => !retainedNames.contains(name)) ||
            (await _files!.offlineAccountDirectoryNames()).any(
              (name) => !retainedNames.contains(name),
            )) {
          return false;
        }
      } on Object {
        return false;
      }
      final confirmed = await _keys!.readInventory();
      if (confirmed.status != ReadCacheStoreReadStatus.found ||
          confirmed.malformedNames.isNotEmpty ||
          confirmed.pendingAccountKeys.isNotEmpty ||
          confirmed.accountKeys.any((k) => !retained.contains(k))) {
        return false;
      }
      return ok &&
          revision == _domain.startupRevision &&
          pathRevision == _domain.pathRevision;
    });
    if (!success || !current()) return false;
    if (retained.isEmpty) {
      // This pass proved both the root and the entire inventory empty.
      _domain.deviceOffPending = false;
      _domain.deviceOffConfirmed = true;
      _domain.diskUsageBytes = 0;
    }
    _domain.recovered = true;
    _domain.diskRetainedAccountKey =
        retained.contains(decision.resumeAccountKey)
        ? decision.resumeAccountKey
        : retained.contains(diskRetainedAccountKey)
        ? diskRetainedAccountKey
        : null;
    final active = _domain.active;
    if (active != null) {
      if (retained.contains(active.accountKey)) {
        await activate(active);
      } else {
        // A pre-scan activation cannot override the session's resume decision.
        // Fence delayed duplicates; a later session supplies a newer generation.
        revoke(active);
        _domain.active = null;
      }
    }
    return _domain.recovered && pathRevision == _domain.pathRevision;
  }

  Future<DiskClearResult> retryCleanup(
    DiskBinding binding,
    ReadCacheCleanupOperation operation,
  ) => clear(binding, operation);

  /// Compatibility wrapper. New controls should use [setEnabledResult] to
  /// distinguish an unproven device-off cleanup from a storage failure.
  Future<bool> setEnabled(bool enabled) async =>
      await setEnabledResult(enabled) == ReadCacheSettingChangeResult.complete;

  /// Refuses an enable without writing the preference while device-off is
  /// pending or in flight, even if none of its markers could be persisted.
  Future<ReadCacheSettingChangeResult> setEnabledResult(bool enabled) {
    if (!configured) {
      return Future.value(ReadCacheSettingChangeResult.storageUnavailable);
    }
    if (enabled && deviceOffPending) {
      return Future.value(ReadCacheSettingChangeResult.cleanupPending);
    }
    if (!enabled) _beginDeviceOff();
    final future = _preferenceChange(() => _storeEnabled(enabled));
    return enabled
        ? future
        : future.whenComplete(() => _domain.deviceOffOperations--);
  }

  void _beginDeviceOff() {
    _domain.deviceOffOperations++;
    _domain.deviceOffPending = true;
    _domain.deviceOffConfirmed = false;
    _domain.diskUsageBytes = null;
    for (final account in _domain.accounts.values) {
      _domain.namespace?.fence(account.key);
    }
    _domain.offlineBinding = null;
  }

  Future<T> _preferenceChange<T>(Future<T> Function() action) {
    _domain.preferenceChanges++;
    _domain.startupRevision++;
    _domain.recovered = false;
    _suspendAccounts();
    final future = _domain.preferenceTail.then((_) async {
      try {
        return await action();
      } finally {
        _domain.preferenceChanges--;
        _domain.recovered = false;
        _domain.startupRevision++;
      }
    });
    _domain.preferenceTail = future.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return future;
  }

  /// Repeats the complete device sweep, including foreign accounts/orphans
  /// and final root/inventory confirmation. It never writes the preference.
  /// Unavailable inventory authorizes no file or key deletion. Completion is
  /// device-wide; markerDurable is false because there is no device marker.
  Future<DiskClearResult> retryDeviceOff() {
    if (!configured) return Future.value(_none);
    _beginDeviceOff();
    return _preferenceChange(() async {
      if (!await _sweepDeviceOff()) return _none;
      return const DiskClearResult(
        keyGoneConfirmed: true,
        directoryGoneConfirmed: true,
        markerDurable: false,
        complete: true,
      );
    }).whenComplete(() => _domain.deviceOffOperations--);
  }

  Future<ReadCacheSettingChangeResult> _storeEnabled(bool enabled) async {
    // An off requested after this call was queued takes precedence. Also
    // inspect a fresh process's preference before its first enable write:
    // stored 0 is durable evidence that a device sweep must be proven first.
    if (enabled) {
      if (deviceOffPending) return ReadCacheSettingChangeResult.cleanupPending;
      if (!_domain.deviceOffConfirmed &&
          _domain.setting != ReadCacheSettingsState.enabled) {
        _domain.setting = await _settings!.read();
        if (deviceOffPending) {
          return ReadCacheSettingChangeResult.cleanupPending;
        }
        if (_domain.setting == ReadCacheSettingsState.disabled) {
          _domain.deviceOffPending = true;
          return ReadCacheSettingChangeResult.cleanupPending;
        }
        if (_domain.setting == ReadCacheSettingsState.unavailable) {
          return ReadCacheSettingChangeResult.storageUnavailable;
        }
      }
    }
    final stored = await _settings!.writeEnabled(enabled);
    if (!stored) _domain.setting = ReadCacheSettingsState.unavailable;
    if (stored) {
      _domain.setting = enabled
          ? ReadCacheSettingsState.enabled
          : ReadCacheSettingsState.disabled;
    }
    if (!enabled && !await _sweepDeviceOff()) {
      return ReadCacheSettingChangeResult.cleanupPending;
    }
    // Re-enabling still requires a fresh startup decision and verified binding.
    return stored
        ? ReadCacheSettingChangeResult.complete
        : ReadCacheSettingChangeResult.storageUnavailable;
  }

  Future<bool> _sweepDeviceOff() async {
    _domain.deviceOffPending = true;
    _domain.deviceOffConfirmed = false;
    // Include accounts whose first key write is not in secure inventory yet.
    // Fence/persist before drain; inventory and the final proof share the I/O
    // section with that late write, so no success can race its completion.
    final intents = <String, _Intent>{};
    final markers = <String, Future<bool>>{};
    for (final account in _domain.accounts.values) {
      final intent = _fullIntent(account, ReadCacheClearReason.accountClear);
      intents[account.key] = intent;
      if (account.work > 0 || _domain.work > 0) {
        markers[account.key] = _persist(account, intent);
      }
    }
    final cleared = await _serial<bool>(null, () async {
      final inventory = await _keys!.readInventory();
      if (inventory.status != ReadCacheStoreReadStatus.found) return false;
      for (final key in inventory.accountKeys) {
        _account(key);
      }
      try {
        if (inventory.malformedNames.isNotEmpty &&
            !await _clearMalformedInventory(inventory)) {
          return false;
        }
        for (final key in {...intents.keys, ...inventory.accountKeys}) {
          final account = _account(key);
          final intent = intents[key] ??= _fullIntent(
            account,
            ReadCacheClearReason.accountClear,
          );
          final result = await _clearNow(
            account,
            intent,
            hadWork: markers.containsKey(key),
            markerReady: markers[key],
          );
          if (!result.complete &&
              !(account.intent == null && account.clearComplete)) {
            return false;
          }
          // Recovery's activate compares the verified binding with this fence.
          account.cleanup = account.sessionFence != null;
        }
        await _file(() => _files!.clearAccountDirectoriesExcept({}));
        await _files!.clearOfflineAccountDirectoriesExcept({});
        final confirmed = await _keys!.readInventory();
        if (confirmed.status != ReadCacheStoreReadStatus.found ||
            !confirmed.isEmpty ||
            (await _file(() => _files!.accountDirectoryNames())).isNotEmpty ||
            (await _files!.offlineAccountDirectoryNames()).isNotEmpty) {
          return false;
        }
        for (final account in _domain.accounts.values) {
          account.state = _domain.setting == ReadCacheSettingsState.disabled
              ? ReadCacheDiskState.disabled
              : ReadCacheDiskState.unavailable;
        }
        _domain.deviceOffPending = false;
        _domain.deviceOffConfirmed = true;
        _domain.diskUsageBytes = 0;
        return true;
      } on Object {
        return false;
      }
    });
    if (!cleared) {
      for (final key in intents.keys) {
        final account = _account(key);
        final pending = account.intent;
        if (pending != null && pending.full && pending.valid) {
          await _persist(account, pending);
        }
        final active = _domain.active;
        final binding = active?.accountKey == key
            ? active!
            : account.sessionFence ??
                  DiskBinding(accountKey: key, generation: 0);
        reportCleanup(
          binding,
          _cleanup(
            ReadCacheCleanupOperation.settingsClear,
            DiskClearResult(
              keyGoneConfirmed: false,
              directoryGoneConfirmed: false,
              markerDurable: pending?.durable ?? false,
              complete: false,
            ),
            ReadCacheCleanupCode.cleanupFailed,
          ),
        );
      }
      return false;
    }
    for (final binding in List.of(_notices.keys)) {
      if (_notices[binding]?.failure.cleanup?.operation ==
          ReadCacheCleanupOperation.settingsClear) {
        supersedeNotice(binding);
      }
    }
    return true;
  }
}

const _none = DiskClearResult(
  keyGoneConfirmed: false,
  directoryGoneConfirmed: false,
  markerDurable: false,
  complete: false,
);

void Function() _timer(Duration delay, void Function() callback) {
  final timer = Timer(delay, callback);
  return timer.cancel;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var different = 0;
  for (var i = 0; i < a.length; i++) {
    different |= a[i] ^ b[i];
  }
  return different == 0;
}

ReadCacheIndexEntry _used(ReadCacheIndexEntry entry, DateTime now) =>
    ReadCacheIndexEntry(
      fileName: entry.fileName,
      sizeBytes: entry.sizeBytes,
      fetchedAt: entry.fetchedAt,
      lastUsedAt: now.toUtc(),
      cacheClass: entry.cacheClass,
      scopeTags: entry.scopeTags,
      issueIdentities: entry.issueIdentities,
    );

bool _matches(ProjectedDiskEntry entry, DiskInvalidation invalidation) {
  if (invalidation.kind == DiskInvalidationKind.account) return true;
  if (invalidation.kind == DiskInvalidationKind.mutation && entry.pinned) {
    return false;
  }
  if (invalidation.canonicalKey == entry.canonicalKey) return true;
  if (invalidation.scopeTags.contains('global') ||
      entry.scopeTags.any(invalidation.scopeTags.contains)) {
    return true;
  }
  if (entry.issueIdentities.any(invalidation.issueIdentities.contains)) {
    return true;
  }
  // Privacy also evicts project issue-list keys even when their current page
  // does not contain that issue. Identity matches above cover cross-scope links.
  try {
    final decoded = jsonDecode(entry.canonicalKey);
    if (decoded is List && decoded.length >= 3 && decoded[2] is String) {
      final path = decoded[2] as String;
      if (invalidation.path case final uri?) {
        if (path == uri.path || path.startsWith('${uri.path}/')) return true;
      }
      if (invalidation.kind == DiskInvalidationKind.privacy) {
        for (final issue in invalidation.issueIdentities) {
          if (path.endsWith('/projects/${issue.projectId}/issues')) return true;
        }
      }
    }
  } on Object {
    // Unknown key shape cannot be used as path evidence.
    return invalidation.path != null;
  }
  return false;
}

final class _Domain {
  Object? startupOwner, startupScan;
  ReadCacheNamespace? namespace;
  OfflineRepositoryNamespace? pendingOfflineNamespace;
  String? diskRetainedAccountKey;
  DiskBinding? offlineBinding;
  final waits = Map<Object, Set<void Function()>>.identity();
  final notices = <DiskBinding, ReadCacheNotice>{};
  final signedOut = <DiskBinding, ReadCacheNotice>{};
  final subscribers = <ReadCacheNoticeSink>{};
  final accounts = <String, _Account>{};
  Future<void> tail = Future.value();
  Future<void> preferenceTail = Future.value();
  bool recovered = false, controlsInstalled = false, foreground = true;
  bool deviceOffPending = false, deviceOffConfirmed = false;
  int deviceOffOperations = 0;
  int? diskUsageBytes;
  ReadCacheSettingsState setting = ReadCacheSettingsState.unavailable;
  DiskBinding? active;
  DiskBinding? latestVerified;
  int highestGeneration = -1, revokedThrough = -1, preferenceChanges = 0;
  int dropped = 0, startupRevision = 0, startupScanRevision = 0;
  int pathRevision = 0, work = 0;
}

final class _Account {
  _Account(this.key);
  final String key;
  Future<void> markerTail = Future.value();
  ReadCacheDiskState state = ReadCacheDiskState.closed;
  int epoch = 0, revision = 0, work = 0, queuedBytes = 0, retryAttempt = 0;
  bool cleanup = false, indexTrusted = false;
  bool indexDirty = false, flushForced = false;
  bool clearComplete = false;
  bool offlineRefusalPending = false;
  int offlineRefusalDeletes = 0;
  bool get offlineRefusalBlocked =>
      offlineRefusalPending || offlineRefusalDeletes > 0;
  DiskBinding? sessionFence;
  int indexRevision = 0;
  final invalidations = <DiskInvalidation>{};
  Uint8List? keyBytes;
  final pending = Queue<_Write>();
  final inFlight = <_Write>{};
  final unindexed = <String, _CommitLease>{};
  final reads = <_CommitLease>{};
  final entries = <String, _Record>{};
  _Intent? intent;
  Future<void>? flush;
  DateTime? batchDeadline;
  void Function()? cancelBatch, cancelRetry;
}

final class _Intent {
  _Intent(
    this.marker,
    this.revision, {
    required this.full,
    this.accountWide = true,
  });
  final ReadCacheClearMarker marker;
  final int revision;
  final bool full;
  final bool accountWide;
  bool durable = false, valid = true, completed = false;
  int users = 0;
}

final class _CommitLease implements DiskCommitLease {
  _CommitLease(this._check);
  final bool Function() _check;
  bool _current = true;
  @override
  bool get isCurrent => _current && _check();
  @override
  void revoke() => _current = false;
}

final class _Write {
  _Write(this.entry, this.bytes, this.lease);
  final ProjectedDiskEntry entry;
  final int bytes;
  final _CommitLease lease;
}

final class _Record {
  _Record(this.entry, this.index);
  final ProjectedDiskEntry entry;
  final ReadCacheIndexEntry index;
}

final class _Fence implements DiskInvalidationFence {
  bool _current = true;
  late Future<DiskClearResult> _barrier;
  late Future<void> _quiesced;
  void finish(Future<DiskClearResult> barrier, Future<void> quiesced) {
    _barrier = barrier;
    _quiesced = quiesced;
  }

  @override
  bool get isCurrent => _current;
  @override
  Future<DiskClearResult> get barrier => _barrier;
  @override
  Future<void> get quiesced => _quiesced;
  @override
  void revoke() => _current = false;
}
