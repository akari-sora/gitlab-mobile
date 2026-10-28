import 'dart:async';

import '../failure.dart';
import '../gitlab_api.dart';
import '../rate_budget.dart';
import '../read_cache_disk_contract.dart';
import '../request_meter.dart';
import 'offline_repository_coordinator.dart';
import 'snapshot_schema.dart';

/// Permission/version probes run independently of presentation subscriptions.
final class SnapshotProber {
  factory SnapshotProber({
    required GitLabApi api,
    required OfflineRepositoryCoordinator coordinator,
    required DiskBinding binding,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  }) => (_owners[coordinator] ??= <DiskBinding, SnapshotProber>{}).putIfAbsent(
    binding,
    () => SnapshotProber._(
      api,
      coordinator,
      binding,
      clock ?? DateTime.now,
      delay ?? Future<void>.delayed,
    ),
  );
  SnapshotProber._(
    this.api,
    this.coordinator,
    this.binding,
    this._clock,
    this._delay,
  );
  static final _owners = Expando<Map<DiskBinding, SnapshotProber>>();
  final GitLabApi api;
  final OfflineRepositoryCoordinator coordinator;
  final DiskBinding binding;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final _flights = <(int?, bool), Future<void>>{};
  Future<void> _probeTail = Future<void>.value();
  Future<void> _admissionTail = Future<void>.value();
  DateTime? _lastRequest;

  Future<void> probeAll({int? projectId, bool ifDue = false}) {
    final scope = (projectId, ifDue);
    final active = _flights[scope];
    if (active != null) return active;
    late final Future<void> operation;
    operation = _probeTail.then((_) => _probe(projectId, ifDue)).whenComplete(
      () {
        if (identical(_flights[scope], operation)) _flights.remove(scope);
      },
    );
    _flights[scope] = operation;
    _probeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _waitForBudget(Duration duration) async {
    final wake = Completer<void>();
    final leases = api.runBudget.activeLeases;
    final reservations = api.runBudget.unconsumedReservations;
    void signal() {
      if (!wake.isCompleted) wake.complete();
    }

    final rates = api.rateBudget.stream.listen((_) => signal());
    final runs = api.runBudget.changes.listen((_) {
      if (api.runBudget.activeLeases < leases ||
          api.runBudget.unconsumedReservations < reservations) {
        signal();
      }
    });
    final lifecycle = coordinator.changes.listen((owner) {
      if (owner.accountKey == binding.accountKey) signal();
    });
    try {
      await Future.any<void>([
        wake.future,
        _delay(
          duration <= Duration.zero
              ? const Duration(milliseconds: 1)
              : duration > const Duration(seconds: 30)
              ? const Duration(seconds: 30)
              : duration,
        ),
      ]);
    } finally {
      await rates.cancel();
      await runs.cancel();
      await lifecycle.cancel();
    }
  }

  Future<T> _metered<T>(Future<T> Function() operation) async {
    checkOfflineApiBinding(api, binding);
    final permit = coordinator.capture(binding, 0);
    RunBudgetLease? lease;
    final meter = RequestMeter(
      includeOAuthTokens: true,
      beforeRequest: () {
        final admission = _admissionTail.then((_) async {
          while (true) {
            checkOfflineApiBinding(api, binding);
            permit.check();
            if (coordinator.state(binding.accountKey) !=
                OfflineRepositoryState.ready) {
              throw const SnapshotOperationException(
                SnapshotFailure.offlineCacheDisabled,
              );
            }
            final rate = api.rateBudget.snapshot();
            if (rate.level != RateLevel.normal ||
                !api.rateBudget.mayStart(RateRequestClass.global)) {
              final until =
                  api.rateBudget.retryAtFor(RateRequestClass.global) ??
                  rate.limitingBucket?.resetAt;
              await _waitForBudget(
                until?.difference(_clock()) ?? const Duration(seconds: 30),
              );
              continue;
            }
            final previous = _lastRequest;
            if (previous != null) {
              final wait =
                  const Duration(seconds: 2) - _clock().difference(previous);
              if (wait > Duration.zero) {
                await _delay(wait);
                permit.check();
                continue;
              }
            }
            if (lease == null || lease!.remaining == 0) {
              lease?.release();
              lease = api.runBudget.acquire(3);
              if (lease != null && lease!.granted == 0) {
                lease!.release();
                lease = null;
              }
              if (lease == null) {
                await _waitForBudget(const Duration(seconds: 30));
                continue;
              }
            }
            permit.check();
            return;
          }
        });
        _admissionTail = admission.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        );
        return admission;
      },
      onRequest: () {
        checkOfflineApiBinding(api, binding);
        permit.check();
        lease!.consume(1);
        _lastRequest = _clock();
      },
    );
    try {
      while (true) {
        try {
          final result = await meter.runAsync(operation);
          checkOfflineApiBinding(api, binding);
          permit.check();
          return result;
        } on ApiFailure catch (error) {
          if (error.kind != FailureKind.rateLimited) rethrow;
          permit.check();
          await _waitForBudget(
            error.retryAt?.difference(_clock()) ?? const Duration(seconds: 30),
          );
        }
      }
    } finally {
      lease?.release();
    }
  }

  Future<void> validateProject(int projectId) async {
    await _metered(() => api.verifyOfflineProject(projectId));
    await coordinator.projectValidated(binding, projectId);
  }

  Future<bool> checkCommit({required int projectId, required String sha}) =>
      _metered(
        () => api.offlineCommitAvailable(projectId: projectId, sha: sha),
      );

  Future<OfflineVersionProbe> checkVersion(SnapshotRecord snapshot) => _metered(
    () => api.probeOfflineVersion(
      projectId: snapshot.projectId,
      kind: snapshot.refKind == SnapshotRefKind.branch
          ? OfflineRefKind.branch
          : OfflineRefKind.tag,
      name: snapshot.refName,
      sha: snapshot.sha,
    ),
  );

  Future<void> _probe(int? projectId, bool ifDue) async {
    final permit = coordinator.capture(binding, 0);
    if (coordinator.state(binding.accountKey) != OfflineRepositoryState.ready) {
      return;
    }
    final records = await coordinator.maintain<List<SnapshotRecord>>(permit, (
      store,
      index,
    ) async {
      if (index == null) return const [];
      final last = index.lastProbeAt;
      if (ifDue &&
          last != null &&
          !_clock().isBefore(last) &&
          _clock().difference(last) < const Duration(hours: 24)) {
        return const [];
      }
      return index.snapshots
          .where(
            (s) =>
                s.status == SnapshotStatus.complete &&
                (projectId == null || s.projectId == projectId),
          )
          .toList();
    });
    var complete = true;
    for (final record in records ?? const <SnapshotRecord>[]) {
      permit.check();
      late final SnapshotPermit projectPermit;
      try {
        projectPermit = coordinator.capture(binding, record.projectId);
      } on SnapshotOperationException catch (error) {
        permit.check();
        if (error.failure == SnapshotFailure.accessLost) {
          complete = false;
          continue;
        }
        rethrow;
      }
      OfflineVersionProbe result;
      try {
        result = await checkVersion(record);
      } on ApiFailure catch (error) {
        permit.check();
        if ((error.status == 403 || error.status == 404) &&
            !projectPermit.isCurrent) {
          complete = false;
          continue;
        }
        rethrow;
      }
      permit.check();
      projectPermit.check();
      await coordinator.maintain<void>(projectPermit, (store, index) async {
        if (index == null) return;
        await store.writeIndex(
          index.copyWith(
            snapshots: [
              for (final s in index.snapshots)
                if (s.id == record.id &&
                    s.sha == record.sha &&
                    s.projectId == record.projectId &&
                    s.status == SnapshotStatus.complete)
                  s.copyWith(
                    headSha: result.headSha,
                    probe: switch (result.state) {
                      OfflineVersionState.ok => SnapshotProbe.ok,
                      OfflineVersionState.refGone => SnapshotProbe.refGone,
                      OfflineVersionState.commitGone =>
                        SnapshotProbe.commitGone,
                    },
                    probedAt: _clock().toUtc(),
                  )
                else
                  s,
            ],
          ),
          expectedRevision: store.revision,
          mayCommit: () => projectPermit.isCurrent,
        );
      });
    }
    if (complete && projectId == null && (records?.isNotEmpty ?? false)) {
      await coordinator.maintain<void>(permit, (store, index) async {
        if (index != null) {
          await store.writeIndex(
            index.copyWith(lastProbeAt: _clock().toUtc()),
            expectedRevision: store.revision,
            mayCommit: () => permit.isCurrent,
          );
        }
      });
    }
  }
}
