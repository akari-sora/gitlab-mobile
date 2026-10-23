import 'dart:async';
import 'dart:io' show HttpDate, HttpException;
import 'dart:math' as math;

enum RateRequestClass {
  create,
  groupList,
  projectList,
  search,
  archive,
  global,
}

enum RateLevel { normal, low, critical }

final class RateBucketSnapshot {
  const RateBucketSnapshot({
    required this.name,
    required this.limit,
    required this.remaining,
    required this.resetAt,
    required this.level,
  });

  final String name;
  final int limit;
  final int remaining;
  final DateTime resetAt;
  final RateLevel level;

  int get reserve => math.min(3, math.max(1, (limit * 0.05).ceil()));

  @override
  bool operator ==(Object other) =>
      other is RateBucketSnapshot &&
      other.name == name &&
      other.limit == limit &&
      other.remaining == remaining &&
      other.resetAt == resetAt &&
      other.level == level;

  @override
  int get hashCode => Object.hash(name, limit, remaining, resetAt, level);
}

final class RateBudgetSnapshot {
  RateBudgetSnapshot({
    required this.level,
    required Map<String, RateBucketSnapshot> buckets,
    required Map<RateRequestClass, DateTime> cooldowns,
  }) : buckets = Map.unmodifiable(buckets),
       cooldowns = Map.unmodifiable(cooldowns);

  final RateLevel level;
  final Map<String, RateBucketSnapshot> buckets;
  final Map<RateRequestClass, DateTime> cooldowns;

  /// The bucket with the least usable remaining capacity.
  RateBucketSnapshot? get limitingBucket {
    RateBucketSnapshot? result;
    for (final bucket in buckets.values) {
      if (result == null ||
          bucket.remaining - bucket.reserve <
              result.remaining - result.reserve) {
        result = bucket;
      }
    }
    return result;
  }
}

final class GitLabRateBudget {
  GitLabRateBudget({
    DateTime Function()? now,
    Duration Function(int attempt)? backoff,
    double Function()? jitter,
  }) : _now = now ?? DateTime.now,
       _backoff = backoff ?? _defaultBackoff,
       _jitter = jitter ?? math.Random().nextDouble;

  final DateTime Function() _now;
  final Duration Function(int attempt) _backoff;
  final double Function() _jitter;
  final Map<String, _Bucket> _buckets = <String, _Bucket>{};
  final Map<RateRequestClass, _Cooldown> _cooldowns =
      <RateRequestClass, _Cooldown>{};
  final StreamController<RateBudgetSnapshot> _changes =
      StreamController<RateBudgetSnapshot>.broadcast(sync: true);
  Timer? _timer;
  int _sequence = 0;
  final Map<RateRequestClass, int> _fallbackAttempts =
      <RateRequestClass, int>{};
  final Map<RateRequestClass, int> _last429Sequences =
      <RateRequestClass, int>{};
  final Map<RateRequestClass, int> _lastSuccessSequences =
      <RateRequestClass, int>{};
  bool _closed = false;

  Stream<RateBudgetSnapshot> get stream => _changes.stream;

  int nextSequence() => ++_sequence;

  RateBudgetSnapshot snapshot() {
    final expired = _expireAndSchedule();
    final result = _snapshotNow();
    if (expired) _publish(result);
    return result;
  }

  RateBudgetSnapshot _snapshotNow() {
    final buckets = <String, RateBucketSnapshot>{};
    var level = RateLevel.normal;
    for (final entry in _buckets.entries) {
      final bucketLevel = _level(entry.value, _now());
      if (bucketLevel.index > level.index) level = bucketLevel;
      buckets[entry.key] = RateBucketSnapshot(
        name: entry.key,
        limit: entry.value.limit,
        remaining: entry.value.remaining,
        resetAt: entry.value.resetAt,
        level: bucketLevel,
      );
    }
    return RateBudgetSnapshot(
      level: level,
      buckets: buckets,
      cooldowns: <RateRequestClass, DateTime>{
        for (final entry in _cooldowns.entries) entry.key: entry.value.until,
      },
    );
  }

  DateTime? retryAtFor(RateRequestClass requestClass) {
    final expired = _expireAndSchedule();
    if (expired) _publish(_snapshotNow());
    final global = _cooldowns[RateRequestClass.global]?.until;
    final specific = _cooldowns[requestClass]?.until;
    if (global == null) return specific;
    if (specific == null) return global;
    return global.isAfter(specific) ? global : specific;
  }

  /// Checks only the global and matching per-class server cooldowns.
  bool mayStart(RateRequestClass requestClass) =>
      !_closed && retryAtFor(requestClass) == null;

  /// Adds the app's critical-level AI throttle to [mayStart].
  ///
  /// Cleanup reads may bypass the app throttle, but never a server cooldown.
  bool mayStartAi(RateRequestClass requestClass, {bool cleanup = false}) {
    if (!mayStart(requestClass)) return false;
    return cleanup || snapshot().level != RateLevel.critical;
  }

  void noteResponse({
    required Map<String, List<String>> headers,
    required int statusCode,
    required RateRequestClass requestClass,
    required int sequence,
    required bool trusted,
  }) {
    if (_closed || !trusted) return;
    final normalized = <String, List<String>>{
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    };
    final now = _now();
    final name = _one(normalized, 'ratelimit-name') ?? 'default';
    final limit = _nonNegativeInt(normalized, 'ratelimit-limit');
    final remaining = _nonNegativeInt(normalized, 'ratelimit-remaining');
    final resetAt = _resetAt(normalized, now);

    if (limit != null &&
        limit > 0 &&
        remaining != null &&
        remaining <= limit &&
        resetAt != null &&
        resetAt.isAfter(now)) {
      final previous = _buckets[name];
      if (previous == null || sequence >= previous.sequence) {
        final sameWindow = previous != null && previous.resetAt == resetAt;
        _buckets[name] = _Bucket(
          limit: limit,
          remaining: sameWindow
              ? math.min(previous.remaining, remaining)
              : remaining,
          resetAt: resetAt,
          sequence: sequence,
        );
      }
    }

    if (statusCode == 429) {
      final last429Sequence = _last429Sequences[requestClass];
      final isNewer429 = last429Sequence == null || sequence > last429Sequence;
      if (isNewer429) _last429Sequences[requestClass] = sequence;
      final lastSuccessSequence = _lastSuccessSequences[requestClass];
      final advancesFallback =
          isNewer429 &&
          (lastSuccessSequence == null || sequence > lastSuccessSequence);
      final cooldownAt =
          resetAt ??
          _fallbackReset(now, requestClass, advance: advancesFallback);
      final capped = _capCooldown(now, cooldownAt, requestClass);
      final previous = _cooldowns[requestClass];
      if (previous == null || capped.isAfter(previous.until)) {
        _cooldowns[requestClass] = _Cooldown(capped);
      }
    } else if (statusCode >= 200 && statusCode < 300) {
      final lastSuccessSequence = _lastSuccessSequences[requestClass];
      if (lastSuccessSequence == null || sequence > lastSuccessSequence) {
        _lastSuccessSequences[requestClass] = sequence;
      }
      if (sequence > (_last429Sequences[requestClass] ?? sequence)) {
        _fallbackAttempts.remove(requestClass);
      }
    }
    _expireAndSchedule();
    _publish(_snapshotNow());
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    unawaited(_changes.close());
  }

  DateTime _fallbackReset(
    DateTime now,
    RateRequestClass requestClass, {
    required bool advance,
  }) {
    final attempts = _fallbackAttempts[requestClass] ?? 0;
    final attempt = advance ? attempts : math.max(0, attempts - 1);
    if (advance) _fallbackAttempts[requestClass] = attempts + 1;
    final base = _backoff(attempt);
    final jittered = Duration(
      milliseconds: (base.inMilliseconds * (1 + _jitter() * 0.2)).round(),
    );
    return _capCooldown(now, now.add(jittered), requestClass);
  }

  DateTime _capCooldown(
    DateTime now,
    DateTime proposed,
    RateRequestClass requestClass,
  ) {
    final maximum = requestClass == RateRequestClass.create
        ? const Duration(hours: 24)
        : const Duration(minutes: 15);
    final cap = now.add(maximum);
    return proposed.isAfter(cap) ? cap : proposed;
  }

  DateTime? _resetAt(Map<String, List<String>> headers, DateTime now) {
    final retryAfter = _one(headers, 'retry-after');
    final retrySeconds = _strictNonNegativeInt(retryAfter);
    if (retrySeconds != null) {
      return now.add(Duration(seconds: math.min(retrySeconds, 86400)));
    }
    final retryDate = _parseDate(retryAfter);
    if (retryDate != null) {
      final serverDate = _parseDate(_one(headers, 'date'));
      final delay = serverDate == null
          ? retryDate.difference(now)
          : retryDate.difference(serverDate);
      if (!delay.isNegative) {
        return now.add(
          delay > const Duration(hours: 24) ? const Duration(hours: 24) : delay,
        );
      }
    }

    final resetEpoch = _nonNegativeInt(headers, 'ratelimit-reset');
    if (resetEpoch != null) {
      final serverDate = _parseDate(_one(headers, 'date'));
      final serverReset = _epochSeconds(resetEpoch);
      if (serverDate != null && serverReset != null) {
        final delta = serverReset.difference(serverDate.toUtc());
        if (!delta.isNegative) return now.add(delta);
      }
    }

    final resetTime = _one(headers, 'ratelimit-resettime');
    final resetTimeEpoch = _strictNonNegativeInt(resetTime);
    final parsed = resetTimeEpoch == null
        ? _parseDate(resetTime)
        : _epochSeconds(resetTimeEpoch);
    if (parsed != null && parsed.isAfter(now)) return parsed;
    return null;
  }

  bool _expireAndSchedule() {
    if (_closed) return false;
    final now = _now();
    final oldBucketCount = _buckets.length;
    final oldCooldownCount = _cooldowns.length;
    _buckets.removeWhere((_, bucket) => !bucket.resetAt.isAfter(now));
    _cooldowns.removeWhere((_, cooldown) => !cooldown.until.isAfter(now));
    _timer?.cancel();
    DateTime? next;
    for (final at in <DateTime>[
      ..._buckets.values.map((bucket) => bucket.resetAt),
      ..._cooldowns.values.map((cooldown) => cooldown.until),
    ]) {
      if (next == null || at.isBefore(next)) next = at;
    }
    if (next != null) {
      final delay = next.difference(now);
      _timer = Timer(delay.isNegative ? Duration.zero : delay, () {
        if (_expireAndSchedule()) _publish(_snapshotNow());
      });
    }
    return oldBucketCount != _buckets.length ||
        oldCooldownCount != _cooldowns.length;
  }

  void _publish(RateBudgetSnapshot value) {
    if (!_closed) _changes.add(value);
  }

  static Duration _defaultBackoff(int attempt) {
    final seconds = 60 * (1 << math.min(attempt, 4));
    return Duration(seconds: math.min(seconds, 900));
  }

  static RateLevel _level(_Bucket bucket, DateTime now) {
    final seconds = bucket.resetAt.difference(now).inMilliseconds / 1000;
    final reserve = math.min(3, math.max(1, (bucket.limit * 0.05).ceil()));
    if (bucket.remaining < reserve && seconds > 10) {
      return RateLevel.critical;
    }
    final low = math.min(15, math.max(2, (bucket.limit * 0.15).ceil()));
    if (bucket.remaining < low && seconds > 20) return RateLevel.low;
    return RateLevel.normal;
  }

  static String? _one(Map<String, List<String>> headers, String name) {
    final values = headers[name];
    if (values == null || values.length != 1) return null;
    final value = values.single.trim();
    return value.isEmpty ? null : value;
  }

  static int? _nonNegativeInt(Map<String, List<String>> headers, String name) {
    return _strictNonNegativeInt(_one(headers, name));
  }

  static int? _strictNonNegativeInt(String? raw) {
    if (raw == null || !RegExp(r'^\d+$').hasMatch(raw)) return null;
    return int.tryParse(raw);
  }

  static DateTime? _epochSeconds(int seconds) {
    // DateTime's documented range is +/- 100,000,000 days from the epoch.
    if (seconds > 8640000000000) return null;
    try {
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    } on RangeError {
      return null;
    }
  }

  static DateTime? _parseDate(String? value) {
    if (value == null) return null;
    final iso = DateTime.tryParse(value);
    if (iso != null) return iso;
    try {
      return HttpDate.parse(value);
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }
}

final class RunBudgetAllocator {
  RunBudgetAllocator(this.rateBudget);

  final GitLabRateBudget rateBudget;
  final Set<RunBudgetLease> _leases = <RunBudgetLease>{};

  int get activeLeases => _leases.length;

  int get unconsumedReservations =>
      _leases.fold<int>(0, (total, lease) => total + lease.remaining);

  RunBudgetLease? acquire(int max) {
    if (max < 0) throw RangeError.value(max, 'max');
    if (_leases.length >= 3) return null;
    final snapshot = rateBudget.snapshot();
    if (snapshot.level == RateLevel.critical) return null;
    final activeRuns = _leases.length + 1;
    final bucket = snapshot.limitingBucket;
    final allocation = bucket == null
        ? math.min(max, 40)
        : math.min(
            max,
            math.min(
              40,
              math.max(
                    0,
                    bucket.remaining - bucket.reserve - unconsumedReservations,
                  ) ~/
                  activeRuns,
            ),
          );
    final lease = RunBudgetLease._(this, allocation);
    _leases.add(lease);
    return lease;
  }

  void _release(RunBudgetLease lease) {
    _leases.remove(lease);
  }
}

final class RunBudgetLease {
  RunBudgetLease._(this._owner, this.granted) : _remaining = granted;

  final RunBudgetAllocator _owner;
  final int granted;
  int _remaining;
  bool _released = false;

  int get remaining => _remaining;
  bool get isReleased => _released;

  void consume(int count) {
    if (_released) throw StateError('The rate-budget lease was released.');
    if (count < 0 || count > _remaining) {
      throw RangeError.range(count, 0, _remaining, 'count');
    }
    _remaining -= count;
  }

  void release() {
    if (_released) return;
    _released = true;
    _owner._release(this);
  }
}

final class _Bucket {
  const _Bucket({
    required this.limit,
    required this.remaining,
    required this.resetAt,
    required this.sequence,
  });

  final int limit;
  final int remaining;
  final DateTime resetAt;
  final int sequence;
}

final class _Cooldown {
  const _Cooldown(this.until);

  final DateTime until;
}
