import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/failure.dart';
import '../../core/gitlab_api.dart';
import '../../core/models.dart';
import '../../core/rate_budget.dart';
import '../cache/read_cache_disk_coordinator.dart';
import '../security/app_lock.dart';

/// Flip only with the account-keyed OfflineApp and its network/lock boundary.
const bool offlineModeShellReady = false;

@visibleForTesting
bool? offlineModeShellReadyForTesting;

bool get offlineModeEnabled =>
    offlineModeShellReadyForTesting ?? offlineModeShellReady;

final class OfflineEligibility {
  const OfflineEligibility(this.account, this.lastValidatedAt);
  final Account account;
  final DateTime lastValidatedAt;
}

final class OfflineSession {
  OfflineSession({
    required this.account,
    required this.validationTicket,
    required this.lastValidatedAt,
    required this.generation,
  });
  final Account account;
  final DateTime lastValidatedAt;
  final int generation;
  int validationTicket;
  bool connectionRestored = false;
}

/// Qualification only reads closed storage. The probe owns no content client.
final class OfflineGate with WidgetsBindingObserver {
  OfflineGate({
    required this.readCache,
    AppLockController? appLock,
    DateTime Function()? clock,
  }) : _lock = appLock,
       _clock = clock ?? DateTime.now,
       _rateBudget = GitLabRateBudget(now: clock);

  final ReadCacheDiskCoordinator readCache;
  final DateTime Function() _clock;
  AppLockController? _lock;
  GitLabRateBudget _rateBudget;
  GitLabRateBudget get rateBudget => _rateBudget;
  Future<IdentityVerdict>? _flight;
  IdentityVerdict? _lastVerdict;
  DateTime? _lastManual, _validatedAt;
  Timer? _retry, _hourly;
  Future<void> Function()? _onProbe;
  void Function()? _onExpire;
  bool _foreground = true, _observing = false, _disposed = false;
  int _attempt = 0;

  bool get probing => _flight != null;
  bool get lockReadable => _lock?.loaded == true && !_lock!.loadFailed;
  DateTime get now => _clock();
  DateTime? get nextRetryAt => _nextRetryAt;
  DateTime? _nextRetryAt;

  void bindAppLock(AppLockController lock) => _lock = lock;

  void resetBudget() {
    _rateBudget.close();
    _rateBudget = GitLabRateBudget(now: _clock);
  }

  static bool recent(DateTime validatedAt, DateTime now) =>
      !validatedAt.isAfter(now.add(const Duration(minutes: 5))) &&
      now.difference(validatedAt) <= const Duration(days: 30);

  Future<bool> _waitForLock() async {
    final lock = _lock;
    if (lock == null) return false;
    if (lock.loaded) return !lock.loadFailed;
    final loaded = Completer<void>();
    void changed() {
      if (lock.loaded && !loaded.isCompleted) loaded.complete();
    }

    lock.addListener(changed);
    try {
      await loaded.future.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      return false;
    } finally {
      lock.removeListener(changed);
    }
    return !_disposed && lockReadable;
  }

  Future<OfflineEligibility?> check(
    Account account, {
    required bool Function() isCurrent,
  }) async {
    if (!offlineModeEnabled || !await _waitForLock() || !isCurrent()) {
      return null;
    }
    // main owns startup recovery. Qualification does not start another scan.
    final deadline = DateTime.now().add(ReadCacheDiskCoordinator.barrierLimit);
    while (!readCache.startupRecovered && isCurrent() && !_disposed) {
      if (DateTime.now().isAfter(deadline)) return null;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (_disposed || !isCurrent() || !lockReadable) return null;
    final index = await readCache.offlineEligibilityIndex(account.key);
    if (_disposed ||
        !isCurrent() ||
        !lockReadable ||
        index == null ||
        !recent(index.lastValidatedAt, now)) {
      return null;
    }
    return OfflineEligibility(account, index.lastValidatedAt);
  }

  Future<IdentityVerdict> probe(
    Future<IdentityVerdict> Function() action, {
    bool manual = false,
  }) {
    final flight = _flight;
    if (flight != null) return flight;
    final retryAt = rateBudget.retryAtFor(RateRequestClass.global);
    if (retryAt != null && now.isBefore(retryAt)) {
      final verdict = IdentityNoVerdict(
        ApiFailure(FailureKind.rateLimited, retryAt: retryAt),
      );
      _lastVerdict = verdict;
      return Future.value(verdict);
    }
    if (manual &&
        _lastManual != null &&
        now.difference(_lastManual!) < const Duration(seconds: 3) &&
        _lastVerdict != null) {
      return Future.value(_lastVerdict!);
    }
    if (manual) _lastManual = now;
    late final Future<IdentityVerdict> result;
    result = Future<IdentityVerdict>.sync(action)
        .then((verdict) {
          if (identical(_flight, result)) _lastVerdict = verdict;
          return verdict;
        })
        .whenComplete(() {
          if (identical(_flight, result)) _flight = null;
        });
    _flight = result;
    return result;
  }

  void start({
    required DateTime lastValidatedAt,
    required Future<void> Function() onProbe,
    required void Function() onExpire,
  }) {
    _validatedAt = lastValidatedAt;
    _onProbe = onProbe;
    _onExpire = onExpire;
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    _hourly?.cancel();
    _hourly = Timer.periodic(const Duration(hours: 1), (_) {
      if (_foreground) recheckAge();
    });
  }

  void scheduleRetry() {
    _retry?.cancel();
    if (_disposed || !_foreground || _onProbe == null) return;
    const seconds = [15, 30, 60, 120, 300];
    final index = _attempt < seconds.length ? _attempt : seconds.length - 1;
    _attempt++;
    var at = now.add(Duration(seconds: seconds[index]));
    final limited = rateBudget.retryAtFor(RateRequestClass.global);
    if (limited != null && limited.isAfter(at)) at = limited;
    _nextRetryAt = at;
    _retry = Timer(at.difference(now), () {
      _nextRetryAt = null;
      if (_foreground && recheckAge()) unawaited(_onProbe!());
    });
  }

  void connectionSucceeded() {
    _attempt = 0;
    _retry?.cancel();
    _nextRetryAt = null;
  }

  bool recheckAge() {
    final at = _validatedAt;
    if (at != null && !recent(at, now)) {
      _onExpire?.call();
      return false;
    }
    return true;
  }

  void setForeground(bool value) {
    _foreground = value;
    if (!value) {
      _retry?.cancel();
      _nextRetryAt = null;
    } else if (_onProbe != null && recheckAge()) {
      unawaited(_onProbe!());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) setForeground(true);
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      setForeground(false);
    }
  }

  void stop() {
    _flight = null;
    _retry?.cancel();
    _hourly?.cancel();
    _nextRetryAt = null;
    _onProbe = null;
    _onExpire = null;
    _validatedAt = null;
    _attempt = 0;
    _lastManual = null;
    _lastVerdict = null;
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _observing = false;
  }

  void dispose() {
    _disposed = true;
    stop();
    rateBudget.close();
  }
}
