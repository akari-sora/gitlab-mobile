import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../gitlab_api.dart';
import '../read_cache_disk_contract.dart';
import 'snapshot_schema.dart';
import 'snapshot_probe.dart';
import 'snapshot_store.dart';

enum OfflineRepositoryState {
  closed,
  offlineReadOnly,
  ready,
  cleaning,
  unavailable,
  needsNewerApp,
}

enum OfflineKeyStatus { found, absent, unavailable }

final class OfflineKeyRead {
  const OfflineKeyRead(this.status, [this.bytes]);
  final OfflineKeyStatus status;
  final Uint8List? bytes;
}

abstract interface class OfflineRepositoryKeys {
  Future<OfflineKeyRead> read(String accountKey);
  Future<void> write(String accountKey, Uint8List bytes);
  Future<void> delete(String accountKey);
  Future<bool> hasMarker(String accountKey);
  Future<void> writeMarker(String accountKey, String operationId);
  Future<void> deleteMarker(String accountKey);
}

final class SnapshotOperationException implements Exception {
  const SnapshotOperationException(this.failure);
  final SnapshotFailure failure;
}

void checkOfflineApiBinding(GitLabApi api, DiskBinding binding) {
  if (api.isClosed ||
      !api.isReadCacheBound ||
      api.readCacheAccountKey != binding.accountKey ||
      api.readCacheGeneration != binding.generation ||
      !binding.accountKey.startsWith('${api.instance.key}#')) {
    throw const SnapshotOperationException(SnapshotFailure.sessionEnded);
  }
}

/// Every main-isolate rename checks the three live epochs. Worker writes are
/// additionally drained by their stop/ack/kill barrier before deletion.
final class SnapshotPermit {
  SnapshotPermit._(
    this._owner,
    this.binding,
    this.projectId,
    this.accountEpoch,
    this.projectEpoch,
    this.jobId,
    this.jobEpoch,
    this._job,
  );
  final OfflineRepositoryCoordinator _owner;
  final DiskBinding binding;
  final int projectId, accountEpoch, projectEpoch;
  final String? jobId;
  final int? jobEpoch;
  final _OfflineJob? _job;
  bool get isCurrent => _owner._current(this);
  void check() {
    if (!isCurrent) {
      throw SnapshotOperationException(
        _owner._account(binding.accountKey).revoked.contains(projectId)
            ? SnapshotFailure.accessLost
            : SnapshotFailure.sessionEnded,
      );
    }
  }
}

/// Process owner: admission, epochs, worker barriers and one maintenance lock
/// per account. Security handling never depends on a UI subscription.
final class OfflineRepositoryCoordinator {
  OfflineRepositoryCoordinator({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;
  static final instance = OfflineRepositoryCoordinator();
  final DateTime Function() _clock;
  final _accounts = <String, _OfflineAccount>{};
  final _changes = StreamController<DiskBinding>.broadcast(sync: true);
  OfflineRepositoryKeys? _keys;
  Future<Directory> Function()? _root;
  Future<void> Function(String)? _deleteDirectory;
  Future<void> Function(Directory, String)? _excludeBackup;
  Stream<DiskBinding> get changes => _changes.stream;
  bool get configured => _keys != null && _root != null;

  void configure({
    required OfflineRepositoryKeys keys,
    required Future<Directory> Function() supportRoot,
    required Future<void> Function(String) deleteDirectory,
    Future<void> Function(Directory, String)? excludeBackup,
  }) {
    _keys = keys;
    _root = supportRoot;
    _deleteDirectory = deleteDirectory;
    _excludeBackup = excludeBackup;
  }

  _OfflineAccount _account(String key) =>
      _accounts.putIfAbsent(key, () => _OfflineAccount());
  OfflineRepositoryState state(String key) => _account(key).state;

  void bindApi(GitLabApi api, DiskBinding binding) {
    checkOfflineApiBinding(api, binding);
    _account(binding.accountKey).api = api;
    api.bindOfflineAccess(
      binding: binding,
      onAccessLoss: accessLost,
      onValidatedJson: validated,
      onAmbiguousAccessLoss: (owner, projectId) {
        if (owner != binding) return;
        unawaited(
          SnapshotProber(
            api: api,
            coordinator: this,
            binding: owner,
            clock: _clock,
          ).validateProject(projectId).catchError((Object _) {}),
        );
      },
    );
  }

  void open(DiskBinding binding, {bool readOnly = false}) {
    final a = _account(binding.accountKey);
    if (a.localCleanupPending) return;
    a.epoch++;
    a.binding = binding;
    a.state = readOnly
        ? OfflineRepositoryState.offlineReadOnly
        : OfflineRepositoryState.ready;
    a.store = null;
    a.storeKey = null;
    a.revoked.clear();
    a.validationTicket = null;
    _emit(binding);
    if (!readOnly) unawaited(_activate(binding));
  }

  Future<void> _activate(DiskBinding binding) async {
    final a = _account(binding.accountKey);
    if (a.validationTicket != null) return;
    final ticket = a.validationTicket = Object();
    try {
      final permit = capture(binding, 0);
      final updated = await maintain<bool>(permit, (store, index) async {
        var current = index;
        if (a.jobs.isEmpty) {
          final recovered = await store.recover(
            now: _clock(),
            workersRunning: false,
            mayCommit: () => permit.isCurrent,
          );
          current = recovered;
        }
        if (current == null) return false;
        await store.writeIndex(
          current.copyWith(lastValidatedAt: _clock().toUtc()),
          expectedRevision: store.revision,
          mayCommit: () => permit.isCurrent,
        );
        return true;
      });
      if (updated == true && permit.isCurrent) a.validatedAt = _clock();
    } on Object {
      // A subsequent explicit access exposes the retained typed failure/state.
    } finally {
      if (identical(a.validationTicket, ticket)) a.validationTicket = null;
    }
    final api = a.api;
    if (api != null &&
        a.binding == binding &&
        a.state == OfflineRepositoryState.ready) {
      unawaited(
        SnapshotProber(
          api: api,
          coordinator: this,
          binding: binding,
          clock: _clock,
        ).probeAll(ifDue: true).catchError((Object _) {}),
      );
    }
  }

  void fence(String key) {
    final a = _account(key);
    a.epoch++;
    a.state = OfflineRepositoryState.cleaning;
    a.store = null;
    a.storeKey = null;
    for (final job in a.jobs.values) {
      job.epoch++;
      job.cancel();
    }
    if (a.binding != null) _emit(a.binding!);
  }

  SnapshotPermit capture(DiskBinding binding, int projectId, {String? jobId}) {
    final a = _account(binding.accountKey);
    final p = SnapshotPermit._(
      this,
      binding,
      projectId,
      a.epoch,
      a.projectEpochs[projectId] ?? 0,
      jobId,
      jobId == null ? null : a.jobs[jobId]?.epoch,
      jobId == null ? null : a.jobs[jobId],
    );
    p.check();
    return p;
  }

  bool _current(SnapshotPermit p) {
    final a = _account(p.binding.accountKey);
    return configured &&
        a.binding == p.binding &&
        (a.state == OfflineRepositoryState.ready ||
            a.state == OfflineRepositoryState.offlineReadOnly) &&
        a.epoch == p.accountEpoch &&
        (a.projectEpochs[p.projectId] ?? 0) == p.projectEpoch &&
        !a.revoked.contains(p.projectId) &&
        (p.jobId == null ||
            (a.jobs[p.jobId]?.epoch == p.jobEpoch && p.jobEpoch != null));
  }

  Future<SnapshotPermit> registerJob(
    DiskBinding binding,
    int projectId,
    String jobId, {
    required void Function() cancel,
    required Future<void> Function() stop,
  }) async {
    capture(binding, projectId).check();
    if (!validSnapshotId(jobId)) {
      throw const SnapshotOperationException(SnapshotFailure.storageError);
    }
    final a = _account(binding.accountKey);
    return _locked(a, () async {
      capture(binding, projectId).check();
      if (a.state != OfflineRepositoryState.ready || a.jobs.isNotEmpty) {
        throw const SnapshotOperationException(
          SnapshotFailure.offlineCacheDisabled,
        );
      }
      a.jobs[jobId] = _OfflineJob(projectId, cancel, stop);
      return capture(binding, projectId, jobId: jobId);
    });
  }

  void finishJob(SnapshotPermit p) {
    final a = _account(p.binding.accountKey);
    if (p._job != null && identical(a.jobs[p.jobId], p._job)) {
      a.jobs.remove(p.jobId);
    }
  }

  void invalidateJob(SnapshotPermit p) {
    final job = _account(p.binding.accountKey).jobs[p.jobId];
    if (job != null && job.epoch == p.jobEpoch) {
      job.epoch++;
      job.cancel();
    }
  }

  Future<void> stopAndWait(String key) async {
    final a = _account(key);
    final jobs = List.of(a.jobs.values);
    for (final job in jobs) {
      job.cancel();
    }
    await Future.wait(jobs.map((job) => job.stop()));
    await a.tail;
    a.jobs.clear();
  }

  Future<T> _locked<T>(_OfflineAccount a, Future<T> Function() body) {
    final result = a.tail.then((_) => body());
    a.tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<T?> maintain<T>(
    SnapshotPermit p,
    Future<T> Function(SnapshotStore, SnapshotIndex?) body, {
    DateTime? consentAt,
    bool allowReadOnly = false,
  }) async {
    final a = _account(p.binding.accountKey);
    var corruptIndex = false;
    try {
      return await _locked(a, () async {
        p.check();
        if (a.state != OfflineRepositoryState.ready && !allowReadOnly) {
          throw const SnapshotOperationException(
            SnapshotFailure.offlineCacheDisabled,
          );
        }
        try {
          final store = await _loadStore(p, create: consentAt != null);
          p.check();
          if (store == null) return null;
          SnapshotIndex? index;
          try {
            index = await store.readIndex();
          } on SnapshotSchemaException catch (e) {
            corruptIndex = e.code != SnapshotSchemaError.newerSchema;
            rethrow;
          } on SnapshotStoreException catch (e) {
            corruptIndex =
                e.code == SnapshotStoreError.corrupt ||
                e.code == SnapshotStoreError.authenticationFailed ||
                e.code == SnapshotStoreError.tooLarge;
            rethrow;
          }
          p.check();
          final value = await body(store, index);
          p.check();
          try {
            await _excludeBackup?.call(store.supportRoot, p.binding.accountKey);
          } on Object {
            // Backup exclusion remains best effort after directories are created.
          }
          p.check();
          return value;
        } on SnapshotSchemaException catch (error) {
          if (error.code == SnapshotSchemaError.newerSchema && p.isCurrent) {
            a.epoch++;
            a.state = OfflineRepositoryState.needsNewerApp;
            _emit(p.binding);
          } else if (corruptIndex &&
              p.isCurrent &&
              a.state == OfflineRepositoryState.ready) {
            a.localCleanupPending = true;
            fence(p.binding.accountKey);
          }
          rethrow;
        } on SnapshotStoreException catch (error) {
          if (error.code == SnapshotStoreError.newerSchema && p.isCurrent) {
            a.epoch++;
            a.state = OfflineRepositoryState.needsNewerApp;
            _emit(p.binding);
          } else if (corruptIndex &&
              p.isCurrent &&
              a.state == OfflineRepositoryState.ready) {
            a.localCleanupPending = true;
            fence(p.binding.accountKey);
          }
          rethrow;
        }
      });
    } on Object {
      if (corruptIndex && a.binding == p.binding && a.localCleanupPending) {
        try {
          await clearAll(p.binding);
        } on Object {
          /* keep the fence */
        }
      }
      rethrow;
    }
  }

  Future<SnapshotStore?> _loadStore(
    SnapshotPermit p, {
    required bool create,
  }) async {
    final a = _account(p.binding.accountKey);
    if (await _keys!.hasMarker(p.binding.accountKey)) {
      throw const SnapshotOperationException(
        SnapshotFailure.offlineCacheDisabled,
      );
    }
    p.check();
    var key = await _keys!.read(p.binding.accountKey);
    p.check();
    if (key.status == OfflineKeyStatus.unavailable) {
      a.state = OfflineRepositoryState.unavailable;
      a.epoch++;
      a.store = null;
      a.storeKey = null;
      _emit(p.binding);
      throw const SnapshotOperationException(SnapshotFailure.keyUnavailable);
    }
    if (a.store != null) {
      if (key.status == OfflineKeyStatus.found &&
          key.bytes != null &&
          a.storeKey != null &&
          _sameBytes(a.storeKey!, key.bytes!)) {
        return a.store;
      }
      a.state = OfflineRepositoryState.unavailable;
      a.epoch++;
      a.store = null;
      a.storeKey = null;
      _emit(p.binding);
      throw const SnapshotOperationException(SnapshotFailure.keyUnavailable);
    }
    if (key.status == OfflineKeyStatus.absent && !create) return null;
    final root = await _root!();
    p.check();
    if (key.status == OfflineKeyStatus.absent) {
      final probe = SnapshotStore(
        supportRoot: root,
        accountKey: p.binding.accountKey,
        rootKey: Uint8List(32),
      );
      if (probe.usage() != 0) {
        throw const SnapshotOperationException(SnapshotFailure.keyUnavailable);
      }
      final random = Random.secure();
      final bytes = Uint8List.fromList(
        List.generate(32, (_) => random.nextInt(256)),
      );
      p.check();
      await _keys!.write(p.binding.accountKey, bytes);
      p.check();
      key = await _keys!.read(p.binding.accountKey);
      p.check();
      if (key.status != OfflineKeyStatus.found ||
          key.bytes == null ||
          !_sameBytes(bytes, key.bytes!)) {
        a.state = OfflineRepositoryState.unavailable;
        throw const SnapshotOperationException(SnapshotFailure.keyUnavailable);
      }
    }
    if (key.status != OfflineKeyStatus.found ||
        key.bytes == null ||
        key.bytes!.length != 32) {
      a.state = OfflineRepositoryState.unavailable;
      throw const SnapshotOperationException(SnapshotFailure.keyUnavailable);
    }
    final store = SnapshotStore(
      supportRoot: root,
      accountKey: p.binding.accountKey,
      rootKey: key.bytes!,
    );
    try {
      await _excludeBackup?.call(root, p.binding.accountKey);
    } on Object {
      // Backup exclusion is best effort; adapter records the failure.
    }
    p.check();
    a.store = store;
    a.storeKey = Uint8List.fromList(key.bytes!);
    return store;
  }

  Future<List<SnapshotRecord>> snapshots(DiskBinding binding) async {
    final p = capture(binding, 0);
    return await maintain(
          p,
          (store, index) async => List<SnapshotRecord>.unmodifiable(
            (index?.snapshots ?? const <SnapshotRecord>[]).where(
              (s) =>
                  s.status != SnapshotStatus.superseded &&
                  !_account(binding.accountKey).revoked.contains(s.projectId),
            ),
          ),
          allowReadOnly: true,
        ) ??
        const [];
  }

  /// Run recovery and deferred GC only while no worker can be admitted.
  Future<void> recover(DiskBinding binding) async {
    final permit = capture(binding, 0);
    final a = _account(binding.accountKey);
    await maintain<void>(permit, (store, index) async {
      if (a.state != OfflineRepositoryState.ready || a.jobs.isNotEmpty) {
        return;
      }
      await store.recover(
        now: _clock(),
        workersRunning: false,
        mayCommit: () => permit.isCurrent,
      );
    });
  }

  void validated(DiskBinding binding) {
    final a = _account(binding.accountKey);
    if (a.binding != binding || a.state != OfflineRepositoryState.ready) return;
    final elapsed = a.validatedAt == null
        ? null
        : _clock().difference(a.validatedAt!);
    if (elapsed != null &&
        !elapsed.isNegative &&
        elapsed < const Duration(days: 1)) {
      return;
    }
    unawaited(_activate(binding));
  }

  Future<bool> hasMarker(String key) async =>
      !configured || await _keys!.hasMarker(key);
  Future<void> deleteKey(String key) async {
    await _keys!.delete(key);
    _account(key).store = null;
    _account(key).storeKey = null;
    final readback = await _keys!.read(key);
    if (readback.status != OfflineKeyStatus.absent) {
      throw const SnapshotOperationException(SnapshotFailure.storageError);
    }
  }

  Future<void> deleteDirectory(String key) =>
      _locked(_account(key), () => _deleteDirectory!(key));
  void _emit(DiskBinding binding) => _changes.add(binding);
  static String newId() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void accessLost(OfflineAccessLoss event) {
    final a = _account(event.binding.accountKey);
    if (a.binding != event.binding || a.state != OfflineRepositoryState.ready) {
      return;
    }
    a.projectEpochs.update(event.projectId, (v) => v + 1, ifAbsent: () => 1);
    a.revoked.add(event.projectId);
    for (final job in a.jobs.values.where(
      (j) => j.projectId == event.projectId,
    )) {
      job.epoch++;
      job.cancel();
    }
    _emit(event.binding);
    final accountEpoch = a.epoch;
    Future<void> remove() async {
      try {
        await _removeProject(event.binding, event.projectId);
      } catch (error, stack) {
        // An unsuccessful project deletion must not lose its fence on restart.
        // Escalate only while this event still owns the account binding.
        if (a.binding == event.binding &&
            ((a.state == OfflineRepositoryState.ready &&
                    a.epoch == accountEpoch) ||
                (a.state == OfflineRepositoryState.unavailable &&
                    a.epoch == accountEpoch + 1))) {
          try {
            await clearAll(event.binding);
          } on Object {
            // The durable marker or the in-memory fence remains pending.
          }
        }
        Error.throwWithStackTrace(error, stack);
      }
    }

    final previous = a.removals[event.projectId];
    final removal = previous == null
        ? remove()
        : previous.catchError((Object _) {}).then((_) => remove());
    a.removals[event.projectId] = removal;
    unawaited(removal.catchError((Object _) {}));
  }

  Future<void> permissionRemoval(DiskBinding binding, int projectId) {
    accessLost(
      OfflineAccessLoss(
        binding: binding,
        projectId: projectId,
        scope: OfflineAccessScope.project,
        status: 403,
      ),
    );
    return _account(binding.accountKey).removals[projectId] ??
        Future<void>.value();
  }

  Future<void> _removeProject(DiskBinding binding, int projectId) async {
    final a = _account(binding.accountKey);
    final epoch = a.epoch;
    final affected = List.of(
      a.jobs.values.where((j) => j.projectId == projectId),
    );
    await Future.wait(affected.map((j) => j.stop()));
    await _locked(a, () async {
      bool current() =>
          a.binding == binding &&
          a.epoch == epoch &&
          a.state == OfflineRepositoryState.ready &&
          a.revoked.contains(projectId);
      if (!current()) return;
      final files = await _loadStore(capture(binding, 0), create: false);
      if (!current() || files == null) return;
      final index = await files.readIndex();
      if (!current() || index == null) return;
      final removed = index.snapshots
          .where((s) => s.projectId == projectId)
          .toList();
      if (removed.isEmpty) return;
      for (final record in removed) {
        files.deleteTree(record.id, mayCommit: current);
      }
      final updated = index.copyWith(
        snapshots: index.snapshots
            .where((s) => s.projectId != projectId)
            .toList(),
        gcPending: true,
        removedNotice: SnapshotRemovedNotice(
          (index.removedNotice?.count ?? 0) + removed.length,
          _clock().toUtc(),
        ),
      );
      await files.writeIndex(
        updated,
        expectedRevision: files.revision,
        mayCommit: current,
      );
      _emit(binding);
    });
  }

  Future<void> projectValidated(DiskBinding binding, int projectId) async {
    final a = _account(binding.accountKey);
    if (a.binding != binding ||
        a.state != OfflineRepositoryState.ready ||
        !a.revoked.contains(projectId)) {
      return;
    }
    final epoch = a.epoch;
    final projectEpoch = a.projectEpochs[projectId];
    await (a.removals[projectId] ?? Future<void>.value());
    if (a.binding == binding &&
        a.state == OfflineRepositoryState.ready &&
        a.epoch == epoch &&
        a.projectEpochs[projectId] == projectEpoch) {
      a.revoked.remove(projectId);
    }
  }

  Future<void> deleteSnapshot(DiskBinding binding, String id) async {
    if (!validSnapshotId(id)) {
      throw const SnapshotOperationException(SnapshotFailure.storageError);
    }
    final a = _account(binding.accountKey);
    final job = a.jobs[id];
    if (job != null) {
      job.epoch++;
      job.cancel();
      await job.stop();
    }
    final p = capture(binding, 0);
    await maintain<void>(p, (files, index) async {
      if (index == null) return;
      files.deleteTree(id, mayCommit: () => p.isCurrent);
      final updated = index.copyWith(
        snapshots: index.snapshots.where((s) => s.id != id).toList(),
        gcPending: true,
      );
      await files.writeIndex(
        updated,
        expectedRevision: files.revision,
        mayCommit: () => p.isCurrent,
      );
      if (a.state == OfflineRepositoryState.ready && a.jobs.isEmpty) {
        await files.collectGarbage(updated, mayCommit: () => p.isCurrent);
      }
    }, allowReadOnly: true);
    p.check();
    _emit(binding);
  }

  Future<void> clearAll(DiskBinding binding) {
    final a = _account(binding.accountKey);
    final existing = a.clearFuture;
    if (existing != null) return existing;
    late final Future<void> operation;
    operation = _clearAll(binding).whenComplete(() {
      if (identical(a.clearFuture, operation)) a.clearFuture = null;
    });
    a.clearFuture = operation;
    return operation;
  }

  Future<void> _clearAll(DiskBinding binding) async {
    final a = _account(binding.accountKey);
    if (!configured || a.binding != binding) {
      throw const SnapshotOperationException(SnapshotFailure.sessionEnded);
    }
    final readOnly = a.state == OfflineRepositoryState.offlineReadOnly;
    a.localCleanupPending = true;
    fence(binding.accountKey);
    final epoch = a.epoch;
    bool current() =>
        a.binding == binding &&
        a.epoch == epoch &&
        a.state == OfflineRepositoryState.cleaning;
    var marker = false;
    try {
      try {
        await _keys!.writeMarker(binding.accountKey, newId());
        marker = await _keys!.hasMarker(binding.accountKey);
      } on Object {
        marker = false;
      }
      if (!current()) {
        throw const SnapshotOperationException(SnapshotFailure.sessionEnded);
      }
      await stopAndWait(binding.accountKey);
      if (!current()) {
        throw const SnapshotOperationException(SnapshotFailure.sessionEnded);
      }
      var keyGone = false, directoryGone = false;
      try {
        await deleteKey(binding.accountKey);
        keyGone = true;
      } on Object {
        keyGone = false;
      }
      if (!current()) {
        throw const SnapshotOperationException(SnapshotFailure.sessionEnded);
      }
      try {
        await deleteDirectory(binding.accountKey);
        directoryGone = true;
      } on Object {
        directoryGone = false;
      }
      if (!current()) {
        throw const SnapshotOperationException(SnapshotFailure.sessionEnded);
      }
      if (marker && keyGone && directoryGone) {
        await _keys!.deleteMarker(binding.accountKey);
        if (await _keys!.hasMarker(binding.accountKey)) {
          throw const SnapshotOperationException(SnapshotFailure.storageError);
        }
        if (!current()) {
          throw const SnapshotOperationException(SnapshotFailure.sessionEnded);
        }
        a.localCleanupPending = false;
        a.epoch++;
        a.state = readOnly
            ? OfflineRepositoryState.offlineReadOnly
            : OfflineRepositoryState.ready;
        a.revoked.clear();
        _emit(binding);
        return;
      }
      throw const SnapshotOperationException(SnapshotFailure.storageError);
    } finally {
      // Failed cleanup retains its synchronous fence.
    }
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

final class _OfflineAccount {
  OfflineRepositoryState state = OfflineRepositoryState.closed;
  DiskBinding? binding;
  GitLabApi? api;
  SnapshotStore? store;
  Uint8List? storeKey;
  int epoch = 0;
  final projectEpochs = <int, int>{};
  final revoked = <int>{};
  final jobs = <String, _OfflineJob>{};
  Future<void> tail = Future<void>.value();
  final removals = <int, Future<void>>{};
  DateTime? validatedAt;
  bool localCleanupPending = false;
  Object? validationTicket;
  Future<void>? clearFuture;
}

final class _OfflineJob {
  _OfflineJob(this.projectId, this.cancel, this.stop);
  final int projectId;
  final void Function() cancel;
  final Future<void> Function() stop;
  int epoch = 0;
}
