import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';

import '../failure.dart';
import '../gitlab_api.dart';
import '../rate_budget.dart';
import '../read_cache_disk_contract.dart';
import '../request_meter.dart';
import 'offline_repository_coordinator.dart';
import 'snapshot_probe.dart';
import 'snapshot_schema.dart';
import 'snapshot_store.dart';
import 'snapshot_worker.dart';

enum SnapshotJobPhase {
  queued,
  resolving,
  listing,
  waitingBudget,
  waitingRateLimit,
  downloading,
  finalizing,
  paused,
  failed,
  complete,
  cancelled,
  alreadyCurrent,
}

final class SnapshotSaveRequest {
  const SnapshotSaveRequest({
    required this.projectId,
    required this.projectPath,
    required this.projectName,
    required this.defaultBranch,
    required this.refKind,
    required this.refName,
    required this.consentAt,
    this.subPath = '',
    this.replaces,
  });
  final int projectId;
  final String projectPath, projectName, defaultBranch, refName, subPath;
  final SnapshotRefKind refKind;
  final DateTime consentAt;
  final String? replaces;
}

final class SnapshotSaveJob {
  SnapshotSaveJob._(this.id, this.request, this.resumeRecord);
  final String id;
  final SnapshotSaveRequest request;
  final SnapshotRecord? resumeRecord;
  SnapshotJobPhase phase = SnapshotJobPhase.queued;
  SnapshotFailure? failure;
  SnapshotWorkerProgress? progress;
  SnapshotRecord? snapshot;
  DateTime? retryAt;
  int page = 0, requests = 0;
  bool _pause = false, _cancel = false;
  CancelToken? _token;
  SnapshotPermit? _permit;
  final _completion = Completer<SnapshotRecord?>();
  Future<SnapshotRecord?> get completion => _completion.future;
}

/// One queue per account generation, shared by every UI adapter.
final class SnapshotSaveQueue {
  factory SnapshotSaveQueue({
    required GitLabApi api,
    required OfflineRepositoryCoordinator coordinator,
    required DiskBinding binding,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  }) =>
      (_queues[coordinator] ??= <DiskBinding, SnapshotSaveQueue>{}).putIfAbsent(
        binding,
        () => SnapshotSaveQueue._(
          api,
          coordinator,
          binding,
          clock ?? DateTime.now,
          delay ?? Future<void>.delayed,
        ),
      );
  SnapshotSaveQueue._(
    this.api,
    this.coordinator,
    this.binding,
    this._clock,
    this._delay,
  );
  static final _queues = Expando<Map<DiskBinding, SnapshotSaveQueue>>();
  final GitLabApi api;
  final OfflineRepositoryCoordinator coordinator;
  final DiskBinding binding;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final _changes = StreamController<SnapshotSaveJob>.broadcast(sync: true);
  final _pending = <SnapshotSaveJob>[];
  Stream<SnapshotSaveJob> get changes => _changes.stream;
  SnapshotSaveJob? active;
  DateTime? _archiveStarted;
  bool _foreground = true;
  Completer<void>? _foregroundWaiter;
  List<SnapshotSaveJob> get queued => List.unmodifiable(_pending);

  void setForeground(bool value) {
    _foreground = value;
    if (value) {
      final waiter = _foregroundWaiter;
      _foregroundWaiter = null;
      if (waiter != null && !waiter.isCompleted) waiter.complete();
    }
  }

  SnapshotSaveJob enqueue(
    SnapshotSaveRequest request, {
    SnapshotRecord? resume,
  }) {
    checkOfflineApiBinding(api, binding);
    coordinator.capture(binding, request.projectId).check();
    if (coordinator.state(binding.accountKey) != OfflineRepositoryState.ready) {
      throw const SnapshotOperationException(
        SnapshotFailure.offlineCacheDisabled,
      );
    }
    if (_pending.length >= 5) {
      // C3a uses storageFull for both queue admission and disk capacity. C3b
      // must distinguish this pre-enqueue refusal from a failed save job.
      throw const SnapshotOperationException(SnapshotFailure.storageFull);
    }
    if (request.projectId <= 0 ||
        request.projectName.runes.length > 255 ||
        utf8.encode(request.projectPath).length > 1024 ||
        utf8.encode(request.refName).length > 1024 ||
        request.refName.isEmpty ||
        !validSnapshotPath(request.subPath, allowEmpty: true) ||
        (resume != null &&
            (resume.projectId != request.projectId ||
                resume.refKind != request.refKind ||
                resume.refName != request.refName ||
                resume.subPath != request.subPath ||
                !const {
                  SnapshotStatus.paused,
                  SnapshotStatus.failed,
                }.contains(resume.status)))) {
      throw const SnapshotOperationException(SnapshotFailure.invalidTree);
    }
    final job = SnapshotSaveJob._(
      resume?.id ?? OfflineRepositoryCoordinator.newId(),
      request,
      resume,
    );
    _pending.add(job);
    _emit(job);
    unawaited(_pump());
    return job;
  }

  void pause(SnapshotSaveJob job) {
    if (job._completion.isCompleted) return;
    job._pause = true;
    if (_pending.remove(job)) {
      _phase(job, SnapshotJobPhase.paused);
      job._completion.complete(null);
      return;
    }
    if (job._permit != null) coordinator.invalidateJob(job._permit!);
    job._token?.cancel();
  }

  Future<void> cancel(SnapshotSaveJob job) async {
    if (job._completion.isCompleted) return;
    job._cancel = true;
    if (_pending.remove(job)) {
      job.phase = SnapshotJobPhase.cancelled;
      job._completion.complete(null);
      _emit(job);
      return;
    }
    if (job._permit != null) coordinator.invalidateJob(job._permit!);
    job._token?.cancel();
    await job.completion;
  }

  Future<void> _pump() async {
    if (active != null || _pending.isEmpty) return;
    final job = active = _pending.removeAt(0);
    try {
      var record = await _run(job);
      if (job.failure == SnapshotFailure.network &&
          !job._pause &&
          !job._cancel &&
          coordinator.state(binding.accountKey) ==
              OfflineRepositoryState.ready) {
        _phase(job, SnapshotJobPhase.paused);
        await Future.any<void>([
          _delay(const Duration(seconds: 30)),
          job._token!.whenCancel.then<void>((_) {}),
        ]);
        while (!_foreground && !job._pause && !job._cancel) {
          final waiter = _foregroundWaiter ??= Completer<void>();
          await Future.any<void>([
            waiter.future,
            job._token!.whenCancel.then<void>((_) {}),
          ]);
          if (job._token!.isCancelled) break;
        }
        if (!job._pause &&
            !job._cancel &&
            !job._token!.isCancelled &&
            coordinator.state(binding.accountKey) ==
                OfflineRepositoryState.ready) {
          record = await _run(job);
        }
      }
      if (job._cancel) {
        try {
          await coordinator.deleteSnapshot(binding, job.id);
        } on Object {
          // A revoked account retains its fence and owns pending cleanup.
        }
        job.failure = null;
        _phase(job, SnapshotJobPhase.cancelled);
        record = null;
      } else if (job._pause) {
        final paused = job.snapshot;
        if (paused != null) {
          try {
            final permit = coordinator.capture(binding, job.request.projectId);
            await coordinator.maintain<void>(permit, (store, index) async {
              if (index == null) return;
              final updated = paused.copyWith(
                status: SnapshotStatus.paused,
                interrupted: false,
                clearFailure: true,
              );
              await store.writeIndex(
                index.copyWith(
                  snapshots: [
                    for (final item in index.snapshots)
                      if (item.id == job.id) updated else item,
                  ],
                ),
                expectedRevision: store.revision,
                mayCommit: () => permit.isCurrent,
              );
              job.snapshot = updated;
            });
          } on Object {
            // Invalidated work cannot publish a late presentation status.
          }
        }
        job.failure = null;
        _phase(job, SnapshotJobPhase.paused);
      }
      if (!job._completion.isCompleted) job._completion.complete(record);
    } on Object catch (error) {
      job.failure = snapshotFailure(error);
      _phase(job, SnapshotJobPhase.failed);
      if (!job._completion.isCompleted) job._completion.complete(null);
    } finally {
      active = null;
      unawaited(_pump());
    }
  }

  void _emit(SnapshotSaveJob job) => _changes.add(job);
  void _phase(SnapshotSaveJob job, SnapshotJobPhase phase) {
    job.phase = phase;
    _emit(job);
  }

  Future<void> _wait(SnapshotSaveJob job, Duration duration) async {
    final token = job._token!;
    await Future.any<void>([
      _delay(duration.isNegative ? Duration.zero : duration),
      token.whenCancel.then<void>((_) {}),
    ]);
    job._permit!.check();
  }

  Future<T> _rateCall<T>(SnapshotSaveJob job, Future<T> Function() call) async {
    final sendingPhase = job.phase;
    while (true) {
      job._permit!.check();
      if (job.phase != sendingPhase) _phase(job, sendingPhase);
      try {
        checkOfflineApiBinding(api, binding);
        final result = await call();
        checkOfflineApiBinding(api, binding);
        return result;
      } on ApiFailure catch (error) {
        if (error.kind != FailureKind.rateLimited) rethrow;
        job.retryAt = error.retryAt;
        _phase(job, SnapshotJobPhase.waitingRateLimit);
        await _wait(
          job,
          error.retryAt?.difference(_clock()) ?? const Duration(seconds: 30),
        );
      }
    }
  }

  Future<SnapshotRecord?> _run(SnapshotSaveJob job) async {
    final token = job._token = CancelToken();
    Future<SnapshotWorker>? startingWorker;
    SnapshotWorker? worker;
    void Function()? cancelArchive;
    job.failure = null;
    job.page = 0;
    final permit = job._permit = await coordinator.registerJob(
      binding,
      job.request.projectId,
      job.id,
      cancel: () {
        token.cancel();
        cancelArchive?.call();
      },
      stop: () async {
        token.cancel();
        cancelArchive?.call();
        await (worker ?? await startingWorker)?.stop();
      },
    );
    if (job._pause || job._cancel) coordinator.invalidateJob(permit);
    RunBudgetLease? lease;
    var remaining = 2;
    Future<void> waitBudget() async {
      final allocator = api.runBudget;
      final activeLeases = allocator.activeLeases;
      final reservations = allocator.unconsumedReservations;
      bool changedBudget() =>
          allocator.activeLeases != activeLeases ||
          allocator.unconsumedReservations != reservations;
      _phase(job, SnapshotJobPhase.waitingBudget);
      final changed = Completer<void>();
      void wake() {
        if (!changed.isCompleted) changed.complete();
      }

      final rates = api.rateBudget.stream.listen((_) => wake());
      final runs = allocator.changes.listen((_) {
        if (changedBudget()) wake();
      });
      try {
        if (changedBudget()) wake();
        await Future.any<void>([
          changed.future,
          _delay(const Duration(seconds: 30)),
          token.whenCancel.then<void>((_) {}),
        ]);
      } finally {
        await rates.cancel();
        await runs.cancel();
      }
      permit.check();
    }

    final meter = RequestMeter(
      includeOAuthTokens: true,
      beforeRequest: () async {
        checkOfflineApiBinding(api, binding);
        permit.check();
        final sendingPhase = job.phase;
        final listing = sendingPhase == SnapshotJobPhase.listing;
        bool normal() =>
            api.rateBudget.snapshot().level == RateLevel.normal &&
            api.rateBudget.mayStart(RateRequestClass.global);
        while (true) {
          if (listing && !normal()) {
            lease?.release();
            lease = null;
            _phase(job, SnapshotJobPhase.waitingRateLimit);
            final rate = api.rateBudget.snapshot();
            await _wait(
              job,
              (api.rateBudget.retryAtFor(RateRequestClass.global) ??
                          rate.limitingBucket?.resetAt)
                      ?.difference(_clock()) ??
                  const Duration(seconds: 30),
            );
            continue;
          }
          while (lease == null || lease!.remaining == 0) {
            lease?.release();
            lease = api.runBudget.acquire(math.min(math.max(remaining, 1), 40));
            if (lease != null && lease!.granted == 0) {
              lease!.release();
              lease = null;
            }
            if (lease == null) await waitBudget();
            permit.check();
          }
          if (listing && !normal()) continue;
          if (job.phase != sendingPhase) _phase(job, sendingPhase);
          permit.check();
          return;
        }
      },
      onRequest: () {
        checkOfflineApiBinding(api, binding);
        permit.check();
        lease!.consume(1);
        remaining = math.max(1, remaining - 1);
        job.requests++;
      },
    );
    SnapshotRecord? record;
    SnapshotTree? tree;
    SnapshotStore? files;
    try {
      return await meter.runAsync(() async {
        _phase(job, SnapshotJobPhase.resolving);
        permit.check();
        final resume = job.snapshot ?? job.resumeRecord;
        if (resume != null &&
            _clock().difference(resume.createdAt) < const Duration(hours: 24) &&
            !_clock().isBefore(resume.createdAt)) {
          final verified = await _rateCall(
            job,
            () => api.cachedRecord(
              [
                'projects',
                '${resume.projectId}',
                'repository',
                'commits',
                resume.sha,
              ],
              fresh: true,
              allowDisk: false,
            ),
          );
          permit.check();
          if (verified.dropped ||
              verified.superseded ||
              verified.value['id'] != resume.sha) {
            throw const SnapshotOperationException(
              SnapshotFailure.resolveFailed,
            );
          }
          await coordinator.maintain<void>(permit, (store, index) async {
            if (index == null ||
                !index.snapshots.any((s) => s.id == resume.id)) {
              return;
            }
            files = store;
            tree = await store.readTree(resume);
            record = resume.copyWith(
              status: SnapshotStatus.saving,
              clearFailure: true,
              interrupted: false,
            );
            await store.writeIndex(
              index.copyWith(
                snapshots: [
                  for (final s in index.snapshots)
                    if (s.id == resume.id) record! else s,
                ],
              ),
              expectedRevision: store.revision,
              mayCommit: () => permit.isCurrent,
            );
          });
        }
        if (record == null || tree == null) {
          final resolved = await _rateCall(
            job,
            () => api.resolveOfflineRef(
              projectId: job.request.projectId,
              kind: job.request.refKind == SnapshotRefKind.branch
                  ? OfflineRefKind.branch
                  : OfflineRefKind.tag,
              name: job.request.refName,
            ),
          );
          permit.check();
          if (resolved.committedAt == null) {
            throw const SnapshotOperationException(
              SnapshotFailure.resolveFailed,
            );
          }
          record = SnapshotRecord(
            id: job.id,
            projectId: job.request.projectId,
            projectPath: job.request.projectPath,
            projectName: job.request.projectName,
            defaultBranch: job.request.defaultBranch,
            refKind: job.request.refKind,
            refName: job.request.refName,
            sha: resolved.sha,
            objectFormat: resolved.sha.length == 40
                ? SnapshotObjectFormat.sha1
                : SnapshotObjectFormat.sha256,
            subPath: job.request.subPath,
            commitTitle: String.fromCharCodes(
              (resolved.commitTitle ?? '').runes.take(200),
            ),
            committedAt: resolved.committedAt!,
            status: SnapshotStatus.saving,
            createdAt: _clock().toUtc(),
            replaces: job.request.replaces,
          );
          var sameVersion = false;
          await coordinator.maintain<void>(permit, (store, index) async {
            final current =
                index ??
                SnapshotIndex(
                  accountKey: binding.accountKey,
                  lastValidatedAt: _clock().toUtc(),
                  consentAt: job.request.consentAt.toUtc(),
                  snapshots: [],
                );
            SnapshotRecord? replaced;
            for (final s in current.snapshots) {
              if (s.id == job.request.replaces) replaced = s;
            }
            if (job.request.replaces != null &&
                (replaced == null ||
                    replaced.projectId != record!.projectId ||
                    replaced.refKind != record!.refKind ||
                    replaced.refName != record!.refName ||
                    replaced.subPath != record!.subPath ||
                    replaced.status != SnapshotStatus.complete)) {
              throw const SnapshotOperationException(
                SnapshotFailure.invalidTree,
              );
            }
            if (replaced != null &&
                replaced.sha == record!.sha &&
                await store.hasReadableSnapshot(replaced)) {
              sameVersion = true;
              return;
            }
            if (job.request.replaces == null &&
                current.snapshots.where((s) => s.id != job.id).length >=
                    snapshotCountLimit) {
              throw const SnapshotOperationException(
                SnapshotFailure.storageFull,
              );
            }
            if (store.usage() + (replaced?.storedBytes ?? 0) >
                snapshotAccountLimit) {
              throw const SnapshotOperationException(
                SnapshotFailure.storageFull,
              );
            }
            await store.writeIndex(
              current.copyWith(
                snapshots: [
                  ...current.snapshots.where((s) => s.id != job.id),
                  record!,
                ],
              ),
              expectedRevision: store.revision,
              mayCommit: () => permit.isCurrent,
            );
            files = store;
          }, consentAt: job.request.consentAt);
          permit.check();
          if (sameVersion) {
            _phase(job, SnapshotJobPhase.alreadyCurrent);
            return null;
          }
          while (!api.rateBudget.mayStart(RateRequestClass.global) ||
              api.rateBudget.snapshot().level != RateLevel.normal) {
            _phase(job, SnapshotJobPhase.waitingRateLimit);
            await _wait(
              job,
              api.rateBudget.snapshot().limitingBucket?.resetAt.difference(
                    _clock(),
                  ) ??
                  const Duration(seconds: 30),
            );
          }
          final validator = OfflineTreeValidator(
            sha: record!.sha,
            subPath: record!.subPath,
          );
          OfflineTreeCursor? cursor;
          final entries = <SnapshotTreeEntry>[];
          lease?.release();
          lease = null;
          remaining = 50;
          do {
            if (job.page > 0) {
              while (api.rateBudget.snapshot().level != RateLevel.normal ||
                  !api.rateBudget.mayStart(RateRequestClass.global)) {
                _phase(job, SnapshotJobPhase.waitingRateLimit);
                await _wait(
                  job,
                  api.rateBudget.snapshot().limitingBucket?.resetAt.difference(
                        _clock(),
                      ) ??
                      const Duration(seconds: 30),
                );
              }
              if (api.rateBudget.snapshot().limitingBucket == null) {
                await _wait(job, const Duration(milliseconds: 200));
              }
            }
            _phase(job, SnapshotJobPhase.listing);
            final page = await _rateCall(
              job,
              () => api.repositoryTreePage(
                projectId: record!.projectId,
                sha: record!.sha,
                subPath: record!.subPath,
                cursor: cursor,
                cancelToken: token,
              ),
            );
            permit.check();
            validator.add(page);
            entries.addAll(
              page.entries.map(
                (e) => SnapshotTreeEntry(
                  path: e['path'] as String,
                  type: SnapshotEntryType.values.byName(e['type'] as String),
                  mode: e['mode'] as String,
                  id: e['id'] as String,
                  state: SnapshotEntryState.pending,
                ),
              ),
            );
            cursor = page.next;
            job.page++;
            if (cursor != null && job.page >= 50) {
              throw const SnapshotOperationException(
                SnapshotFailure.tooManyEntries,
              );
            }
          } while (cursor != null);
          validator.finish();
          tree = SnapshotTree(
            snapshotId: job.id,
            sha: record!.sha,
            subPath: record!.subPath,
            entries: entries,
          );
          await coordinator.maintain<void>(permit, (store, index) async {
            await store.writeTree(
              tree!,
              format: record!.objectFormat,
              complete: false,
              mayCommit: () => permit.isCurrent,
            );
          });
        }
        permit.check();
        lease?.release();
        lease = null;
        remaining = 1;
        while (!api.rateBudget.mayStart(RateRequestClass.archive)) {
          job.retryAt = api.rateBudget.retryAtFor(RateRequestClass.archive);
          _phase(job, SnapshotJobPhase.waitingRateLimit);
          await _wait(
            job,
            job.retryAt?.difference(_clock()) ?? const Duration(seconds: 30),
          );
        }
        _phase(job, SnapshotJobPhase.downloading);
        final archive = await _rateCall(
          job,
          () => api.repositoryArchive(
            projectId: record!.projectId,
            sha: record!.sha,
            subPath: record!.subPath,
            cancelToken: token,
            beforeSend: () async {
              final previous = _archiveStarted;
              if (previous != null) {
                final wait =
                    const Duration(seconds: 15) - _clock().difference(previous);
                if (wait > Duration.zero) await _wait(job, wait);
              }
              permit.check();
              _archiveStarted = _clock();
            },
          ),
        );
        cancelArchive = archive.cancel;
        permit.check();
        worker = await (startingWorker = SnapshotWorker.start(
          store: files!,
          tree: tree!,
          format: record!.objectFormat,
          jobEpoch: permit.jobEpoch!,
        ));
        permit.check();
        final result = await worker!.run(
          archive.stream,
          onProgress: (progress) {
            if (!permit.isCurrent) return;
            job.progress = progress;
            _emit(job);
          },
        );
        permit.check();
        _phase(job, SnapshotJobPhase.finalizing);
        final notSaved = <SnapshotEntryState, int>{};
        var saved = 0;
        for (final entry in result.tree.entries) {
          if (entry.type == SnapshotEntryType.blob &&
              entry.state == SnapshotEntryState.saved) {
            saved++;
          }
          if (SnapshotRecord.missingStates.contains(entry.state)) {
            notSaved.update(entry.state, (n) => n + 1, ifAbsent: () => 1);
          }
        }
        final complete = record!.copyWith(
          status: SnapshotStatus.complete,
          clearFailure: true,
          interrupted: false,
          savedAt: _clock().toUtc(),
          entryCount: result.tree.entries.length,
          savedCount: saved,
          notSaved: notSaved,
          storedBytes: result.storedBytes,
        );
        await coordinator.maintain<void>(permit, (store, index) async {
          if (index == null || !index.snapshots.any((s) => s.id == job.id)) {
            throw const SnapshotOperationException(
              SnapshotFailure.storageError,
            );
          }
          await store.writeTree(
            result.tree,
            format: complete.objectFormat,
            complete: true,
            mayCommit: () => permit.isCurrent,
          );
          if (await store.readTree(complete) == null) {
            throw const SnapshotOperationException(
              SnapshotFailure.storageError,
            );
          }
          await store.writeIndex(
            index.copyWith(
              gcPending: true,
              snapshots: [
                for (final s in index.snapshots)
                  if (s.id == job.id)
                    complete
                  else if (s.id == complete.replaces)
                    s.copyWith(status: SnapshotStatus.superseded)
                  else
                    s,
              ],
            ),
            expectedRevision: store.revision,
            mayCommit: () => permit.isCurrent,
          );
          final readback = await store.readIndex();
          if (readback == null ||
              !readback.snapshots.any(
                (s) =>
                    s.id == complete.id && s.status == SnapshotStatus.complete,
              )) {
            throw const SnapshotOperationException(
              SnapshotFailure.storageError,
            );
          }
        });
        permit.check();
        job.snapshot = record = complete;
        _phase(job, SnapshotJobPhase.complete);
        return complete;
      });
    } on Object catch (error) {
      lease?.release();
      lease = null;
      cancelArchive?.call();
      try {
        await (worker ?? await startingWorker)?.stop();
      } on Object {
        /* start failed */
      }
      var failure = snapshotFailure(error);
      if (!job._cancel &&
          !job._pause &&
          error is ApiFailure &&
          error.status == 404 &&
          permit.isCurrent) {
        try {
          final prober = SnapshotProber(
            api: api,
            coordinator: coordinator,
            binding: binding,
            clock: _clock,
            delay: _delay,
          );
          if (record == null) {
            await prober.validateProject(job.request.projectId);
          } else {
            await prober.checkCommit(
              projectId: record!.projectId,
              sha: record!.sha,
            );
          }
          failure = SnapshotFailure.versionGone;
        } on Object catch (probeError) {
          failure = snapshotFailure(probeError);
          try {
            permit.check();
          } on SnapshotOperationException catch (revoked) {
            failure = revoked.failure;
          }
        }
      }
      if (job._cancel) {
        try {
          await coordinator.deleteSnapshot(binding, job.id);
        } on Object {
          /* keep fence */
        }
        _phase(job, SnapshotJobPhase.cancelled);
      } else {
        job.failure = job._pause ? null : failure;
        if (record != null) {
          try {
            final statusPermit = coordinator.capture(
              binding,
              job.request.projectId,
            );
            await coordinator.maintain<void>(statusPermit, (
              store,
              index,
            ) async {
              if (index == null ||
                  !index.snapshots.any((s) => s.id == job.id)) {
                return;
              }
              final updated = record!.copyWith(
                status: job._pause || job.failure == SnapshotFailure.network
                    ? SnapshotStatus.paused
                    : SnapshotStatus.failed,
                failure: job.failure,
                clearFailure: job.failure == null,
                interrupted: job.failure == SnapshotFailure.network,
              );
              await store.writeIndex(
                index.copyWith(
                  snapshots: [
                    for (final s in index.snapshots)
                      if (s.id == job.id) updated else s,
                  ],
                ),
                expectedRevision: store.revision,
                mayCommit: () => statusPermit.isCurrent,
              );
              job.snapshot = updated;
            });
          } on Object {
            /* revoked work cannot write a late status */
          }
        }
        _phase(
          job,
          job._pause ? SnapshotJobPhase.paused : SnapshotJobPhase.failed,
        );
      }
      return null;
    } finally {
      lease?.release();
      cancelArchive?.call();
      try {
        await (worker ?? await startingWorker)?.stop();
      } on Object {
        /* start failed */
      }
      coordinator.finishJob(permit);
      try {
        await coordinator.recover(binding);
      } on Object {
        /* explicit access reports state */
      }
    }
  }
}

/// Shared typed failure mapping; it never includes repository content or paths.
SnapshotFailure snapshotFailure(Object error) => switch (error) {
  SnapshotOperationException(:final failure) => failure,
  SnapshotWorkerException(:final failure) => failure,
  OfflineRequestFailure(:final kind) => switch (kind) {
    OfflineRequestFailureKind.resolveFailed => SnapshotFailure.resolveFailed,
    OfflineRequestFailureKind.invalidTree => SnapshotFailure.invalidTree,
    OfflineRequestFailureKind.tooManyEntries => SnapshotFailure.tooManyEntries,
    OfflineRequestFailureKind.treeTooLarge => SnapshotFailure.treeTooLarge,
    OfflineRequestFailureKind.serverForbidsStorage =>
      SnapshotFailure.serverForbidsStorage,
    OfflineRequestFailureKind.archiveTooLarge =>
      SnapshotFailure.archiveTooLarge,
  },
  SnapshotStoreException(:final code) => switch (code) {
    SnapshotStoreError.capacity => SnapshotFailure.storageFull,
    SnapshotStoreError.deviceFull => SnapshotFailure.deviceFull,
    SnapshotStoreError.revoked => SnapshotFailure.sessionEnded,
    _ => SnapshotFailure.storageError,
  },
  SnapshotSchemaException(:final code) => switch (code) {
    SnapshotSchemaError.tooLarge => SnapshotFailure.treeTooLarge,
    _ => SnapshotFailure.storageError,
  },
  ApiFailure(:final kind) => switch (kind) {
    FailureKind.network || FailureKind.server => SnapshotFailure.network,
    FailureKind.rateLimited => SnapshotFailure.rateLimited,
    FailureKind.forbidden ||
    FailureKind.unauthenticated => SnapshotFailure.accessLost,
    FailureKind.invisible => SnapshotFailure.versionGone,
    FailureKind.cancelled => SnapshotFailure.sessionEnded,
    _ => SnapshotFailure.resolveFailed,
  },
  _ => SnapshotFailure.storageError,
};
