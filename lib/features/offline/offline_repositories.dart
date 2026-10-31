import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/gitlab_api.dart';
import '../../core/offline/offline_repository_coordinator.dart';
import '../../core/offline/snapshot_probe.dart';
import '../../core/offline/snapshot_reader.dart';
import '../../core/offline/snapshot_save.dart';
import '../../core/offline/snapshot_schema.dart';
import '../../core/read_cache_disk_contract.dart';
import '../../core/repository_reader.dart';

/// Presentation adapter only. Session activation, security sinks and fences
/// remain owned by the process coordinator, including after this is disposed.
final class OfflineRepositories extends ChangeNotifier {
  OfflineRepositories({
    required this.binding,
    required this.coordinator,
    this.api,
  }) {
    _coordinatorSubscription = coordinator.changes.listen((changed) {
      if (changed.accountKey != binding.accountKey || _disposed) return;
      _revision++;
      _snapshots = const [];
      _index = null;
      _usedBytes = 0;
      _failure = null;
      _loading = false;
      _hasLoaded = false;
      notifyListeners();
      unawaited(refresh());
    });
    if (api != null) {
      _queue = SnapshotSaveQueue(
        api: api!,
        coordinator: coordinator,
        binding: binding,
      );
      _jobSubscription = _queue!.changes.listen((job) {
        if (_disposed) return;
        notifyListeners();
        if (const {
          SnapshotJobPhase.complete,
          SnapshotJobPhase.paused,
          SnapshotJobPhase.failed,
          SnapshotJobPhase.cancelled,
          SnapshotJobPhase.alreadyCurrent,
        }.contains(job.phase)) {
          unawaited(refresh());
        }
      });
    }
    unawaited(refresh());
    if (canSave) unawaited(probe());
  }

  final DiskBinding binding;
  final OfflineRepositoryCoordinator coordinator;
  final GitLabApi? api;
  StreamSubscription<DiskBinding>? _coordinatorSubscription;
  StreamSubscription<SnapshotSaveJob>? _jobSubscription;
  SnapshotSaveQueue? _queue;
  List<SnapshotRecord> _snapshots = const [];
  SnapshotIndex? _index;
  int _usedBytes = 0, _revision = 0;
  bool _disposed = false, _loading = false, _hasLoaded = false;
  SnapshotFailure? _failure;

  OfflineRepositoryState get state => coordinator.state(binding.accountKey);
  bool get loading => _loading;

  /// Whether [snapshots] holds a successful read. False before the first one
  /// and again once a change or a failed read has dropped the list, so the
  /// next read is a first load (a skeleton, not a bar over nothing).
  bool get hasLoaded => _hasLoaded;
  SnapshotFailure? get failure => _failure;
  List<SnapshotRecord> get snapshots => _snapshots;
  int get usedBytes => _usedBytes;
  int get availableBytes =>
      (snapshotAccountLimit - _usedBytes).clamp(0, snapshotAccountLimit);
  DateTime? get consentAt => _index?.consentAt;
  DateTime? get lastValidatedAt => _index?.lastValidatedAt;
  DateTime? get lastProbeAt => _index?.lastProbeAt;
  SnapshotRemovedNotice? get removedNotice => _index?.removedNotice;
  bool get canSave {
    if (_disposed || api == null || state != OfflineRepositoryState.ready) {
      return false;
    }
    try {
      checkOfflineApiBinding(api!, binding);
      coordinator.capture(binding, 0).check();
      return true;
    } on SnapshotOperationException {
      return false;
    }
  }

  SnapshotSaveJob? get activeJob => _queue?.active;
  List<SnapshotSaveJob> get queuedJobs => _queue?.queued ?? const [];

  Future<void> refresh() async {
    if (_disposed) return;
    final revision = ++_revision;
    _loading = true;
    _failure = null;
    notifyListeners();
    try {
      final permit = coordinator.capture(binding, 0);
      final records = await coordinator.snapshots(binding);
      final metadata = await coordinator.maintain<(SnapshotIndex?, int)>(
        permit,
        (store, index) async => (index, store.usage()),
        allowReadOnly: true,
      );
      permit.check();
      if (_disposed || revision != _revision) return;
      _snapshots = records;
      _index = metadata?.$1;
      _usedBytes = metadata?.$2 ?? 0;
      _hasLoaded = true;
    } on Object catch (error) {
      if (_disposed || revision != _revision) return;
      _snapshots = const [];
      _index = null;
      _usedBytes = 0;
      _hasLoaded = false;
      _failure = snapshotFailure(error);
    } finally {
      if (!_disposed && revision == _revision) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> probe({int? projectId}) async {
    if (!canSave) return;
    try {
      await SnapshotProber(
        api: api!,
        coordinator: coordinator,
        binding: binding,
      ).probeAll(projectId: projectId);
      if (!_disposed) await refresh();
    } on Object catch (error) {
      if (_disposed) return;
      _failure = snapshotFailure(error);
      notifyListeners();
    }
  }

  /// Explicit online proof can reopen a project only after removal has drained.
  Future<void> validateProject(int projectId) async {
    if (!canSave) {
      throw const SnapshotOperationException(
        SnapshotFailure.offlineCacheDisabled,
      );
    }
    await SnapshotProber(
      api: api!,
      coordinator: coordinator,
      binding: binding,
    ).validateProject(projectId);
    if (!_disposed) await refresh();
  }

  SnapshotSaveJob save(SnapshotSaveRequest request, {SnapshotRecord? resume}) {
    if (!canSave) {
      throw const SnapshotOperationException(
        SnapshotFailure.offlineCacheDisabled,
      );
    }
    return _queue!.enqueue(request, resume: resume);
  }

  void pause(SnapshotSaveJob job) => _queue?.pause(job);
  Future<void> cancel(SnapshotSaveJob job) async => _queue?.cancel(job);
  void setForeground(bool foreground) => _queue?.setForeground(foreground);

  Future<void> remove(String snapshotId) async {
    await coordinator.deleteSnapshot(binding, snapshotId);
    if (!_disposed) await refresh();
  }

  Future<void> clearAll() async {
    await coordinator.clearAll(binding);
    if (!_disposed) await refresh();
  }

  SnapshotRepositoryReader reader(SnapshotRecord snapshot) {
    final separator = binding.accountKey.lastIndexOf('#');
    if (_disposed ||
        separator <= 0 ||
        snapshot.status != SnapshotStatus.complete ||
        !_snapshots.any((s) => s.id == snapshot.id && s.sha == snapshot.sha)) {
      throw const SnapshotOperationException(SnapshotFailure.sessionEnded);
    }
    return SnapshotRepositoryReader(
      owner: ReaderOwner(
        accountKey: binding.accountKey,
        generation: binding.generation,
        instanceKey: binding.accountKey.substring(0, separator),
        projectId: snapshot.projectId,
        sha: snapshot.sha,
        subPath: snapshot.subPath,
        snapshotId: snapshot.id,
      ),
      coordinator: coordinator,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    unawaited(_coordinatorSubscription?.cancel());
    unawaited(_jobSubscription?.cancel());
    super.dispose();
  }
}
