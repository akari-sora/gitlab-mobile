import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';

Map<String, List<String>> rateHeaders({
  required int limit,
  required int remaining,
  required DateTime reset,
  String name = 'user',
}) => <String, List<String>>{
  'rAtElImIt-NaMe': <String>[name],
  'RateLimit-Limit': <String>['$limit'],
  'RATELIMIT-REMAINING': <String>['$remaining'],
  'RateLimit-ResetTime': <String>[reset.toIso8601String()],
};

void main() {
  late DateTime now;
  late GitLabRateBudget budget;

  setUp(() {
    now = DateTime.utc(2026, 10, 23, 1);
    budget = GitLabRateBudget(now: () => now, jitter: () => 0);
  });

  tearDown(() => budget.close());

  group('level formula matches small limits and strict reset thresholds', () {
    final cases =
        <
          ({
            String name,
            int limit,
            int remaining,
            Duration untilReset,
            RateLevel expected,
          })
        >[
          (
            name: 'limit 1 full',
            limit: 1,
            remaining: 1,
            untilReset: const Duration(seconds: 60),
            expected: RateLevel.low,
          ),
          (
            name: 'limit 1 after one request',
            limit: 1,
            remaining: 0,
            untilReset: const Duration(seconds: 60),
            expected: RateLevel.critical,
          ),
          (
            name: 'limit 2 full',
            limit: 2,
            remaining: 2,
            untilReset: const Duration(seconds: 60),
            expected: RateLevel.normal,
          ),
          (
            name: 'limit 2 after one request',
            limit: 2,
            remaining: 1,
            untilReset: const Duration(seconds: 60),
            expected: RateLevel.low,
          ),
          (
            name: 'limit 3 full',
            limit: 3,
            remaining: 3,
            untilReset: const Duration(seconds: 60),
            expected: RateLevel.normal,
          ),
          (
            name: 'limit 3 after one request',
            limit: 3,
            remaining: 2,
            untilReset: const Duration(seconds: 60),
            expected: RateLevel.normal,
          ),
          (
            name: 'critical just below 10 seconds',
            limit: 100,
            remaining: 0,
            untilReset: const Duration(seconds: 9, microseconds: 999999),
            expected: RateLevel.normal,
          ),
          (
            name: 'critical at 10 seconds',
            limit: 100,
            remaining: 0,
            untilReset: const Duration(seconds: 10),
            expected: RateLevel.normal,
          ),
          (
            name: 'critical just above 10 seconds',
            limit: 100,
            remaining: 0,
            untilReset: const Duration(seconds: 10, microseconds: 1),
            expected: RateLevel.critical,
          ),
          (
            name: 'low just below 20 seconds',
            limit: 100,
            remaining: 14,
            untilReset: const Duration(seconds: 19, microseconds: 999999),
            expected: RateLevel.normal,
          ),
          (
            name: 'low at 20 seconds',
            limit: 100,
            remaining: 14,
            untilReset: const Duration(seconds: 20),
            expected: RateLevel.normal,
          ),
          (
            name: 'low just above 20 seconds',
            limit: 100,
            remaining: 14,
            untilReset: const Duration(seconds: 20, microseconds: 1),
            expected: RateLevel.low,
          ),
        ];

    for (final testCase in cases) {
      test(testCase.name, () {
        final observed = GitLabRateBudget(now: () => now);
        addTearDown(observed.close);
        final reset = now.add(testCase.untilReset);
        observed.noteResponse(
          headers: rateHeaders(
            limit: testCase.limit,
            remaining: testCase.remaining,
            reset: reset,
            name: testCase.name,
          ),
          statusCode: 200,
          requestClass: RateRequestClass.global,
          sequence: 1,
          trusted: true,
        );
        final snapshot = observed.snapshot();
        final bucket = snapshot.buckets[testCase.name];

        expect(snapshot.buckets, hasLength(1), reason: testCase.name);
        expect(bucket, isNotNull, reason: testCase.name);
        expect(bucket?.name, testCase.name, reason: testCase.name);
        expect(bucket?.limit, testCase.limit, reason: testCase.name);
        expect(bucket?.remaining, testCase.remaining, reason: testCase.name);
        expect(bucket?.resetAt, reset, reason: testCase.name);
        expect(bucket?.level, testCase.expected, reason: testCase.name);
        expect(snapshot.level, testCase.expected, reason: testCase.name);
      });
    }
  });

  test('send ordering cannot raise remaining in the same window', () {
    final reset = now.add(const Duration(minutes: 5));
    budget.noteResponse(
      headers: rateHeaders(limit: 100, remaining: 8, reset: reset),
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: 2,
      trusted: true,
    );
    budget.noteResponse(
      headers: rateHeaders(limit: 100, remaining: 80, reset: reset),
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: 1,
      trusted: true,
    );
    budget.noteResponse(
      headers: rateHeaders(limit: 100, remaining: 10, reset: reset),
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: 3,
      trusted: true,
    );

    expect(budget.snapshot().buckets['user']?.remaining, 8);
  });

  test('responses populate independently named buckets', () {
    final reset = now.add(const Duration(minutes: 5));
    budget.noteResponse(
      headers: rateHeaders(
        limit: 100,
        remaining: 20,
        reset: reset,
        name: 'newer',
      ),
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: 2,
      trusted: true,
    );
    budget.noteResponse(
      headers: rateHeaders(
        limit: 50,
        remaining: 10,
        reset: reset,
        name: 'older',
      ),
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: 1,
      trusted: true,
    );

    expect(
      budget.snapshot().buckets.keys,
      containsAll(<String>['newer', 'older']),
    );
  });

  test('unknown and untrusted responses do not clear an active limit', () {
    budget.noteResponse(
      headers: rateHeaders(
        limit: 100,
        remaining: 0,
        reset: now.add(const Duration(minutes: 5)),
      ),
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: 1,
      trusted: true,
    );
    budget.noteResponse(
      headers: const <String, List<String>>{},
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: 2,
      trusted: true,
    );
    budget.noteResponse(
      headers: rateHeaders(
        limit: 100,
        remaining: 100,
        reset: now.add(const Duration(minutes: 6)),
      ),
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: 3,
      trusted: false,
    );

    expect(budget.snapshot().level, RateLevel.critical);
  });

  test(
    'rejects remaining above limit and uses server Date for clock skew',
    () {
      final serverDate = DateTime.utc(2026, 10, 22, 23);
      final serverReset = serverDate.add(const Duration(minutes: 2));
      budget.noteResponse(
        headers: <String, List<String>>{
          'Date': <String>['Thu, 22 Oct 2026 23:00:00 GMT'],
          'RateLimit-Limit': <String>['20'],
          'RateLimit-Remaining': <String>['2'],
          'RateLimit-Reset': <String>[
            '${serverReset.millisecondsSinceEpoch ~/ 1000}',
          ],
        },
        statusCode: 200,
        requestClass: RateRequestClass.global,
        sequence: 1,
        trusted: true,
      );
      expect(
        budget.snapshot().buckets['default']?.resetAt,
        now.add(const Duration(minutes: 2)),
      );

      budget.noteResponse(
        headers: <String, List<String>>{
          'RateLimit-Limit': <String>['20'],
          'RateLimit-Remaining': <String>['21'],
          'RateLimit-ResetTime': <String>[
            now.add(const Duration(minutes: 3)).toIso8601String(),
          ],
        },
        statusCode: 200,
        requestClass: RateRequestClass.global,
        sequence: 2,
        trusted: true,
      );
      expect(budget.snapshot().buckets['default']?.remaining, 2);
    },
  );

  test('Retry-After wins and cooldowns are isolated by request class', () {
    budget.noteResponse(
      headers: <String, List<String>>{
        'Retry-After': <String>['120'],
        'RateLimit-ResetTime': <String>[
          now.add(const Duration(minutes: 10)).toIso8601String(),
        ],
      },
      statusCode: 429,
      requestClass: RateRequestClass.groupList,
      sequence: 1,
      trusted: true,
    );

    expect(
      budget.retryAtFor(RateRequestClass.groupList),
      now.add(const Duration(minutes: 2)),
    );
    expect(budget.mayStart(RateRequestClass.groupList), isFalse);
    expect(budget.mayStart(RateRequestClass.projectList), isTrue);
    expect(budget.mayStart(RateRequestClass.create), isTrue);
  });

  test('late 429 still sets its class cooldown after a newer success', () {
    budget.noteResponse(
      headers: const <String, List<String>>{},
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: 2,
      trusted: true,
    );
    budget.noteResponse(
      headers: const <String, List<String>>{
        'Retry-After': <String>['60'],
      },
      statusCode: 429,
      requestClass: RateRequestClass.global,
      sequence: 1,
      trusted: true,
    );

    expect(
      budget.retryAtFor(RateRequestClass.global),
      now.add(const Duration(minutes: 1)),
    );
  });

  test('late 429 cannot shorten an existing class cooldown', () {
    budget.noteResponse(
      headers: const <String, List<String>>{
        'Retry-After': <String>['300'],
      },
      statusCode: 429,
      requestClass: RateRequestClass.global,
      sequence: 2,
      trusted: true,
    );
    budget.noteResponse(
      headers: const <String, List<String>>{
        'Retry-After': <String>['60'],
      },
      statusCode: 429,
      requestClass: RateRequestClass.global,
      sequence: 1,
      trusted: true,
    );

    expect(
      budget.retryAtFor(RateRequestClass.global),
      now.add(const Duration(minutes: 5)),
    );
  });

  test('HTTP-date Retry-After uses server Date to correct clock skew', () {
    budget.noteResponse(
      headers: const <String, List<String>>{
        'Date': <String>['Thu, 22 Oct 2026 23:00:00 GMT'],
        'Retry-After': <String>['Thu, 22 Oct 2026 23:03:00 GMT'],
      },
      statusCode: 429,
      requestClass: RateRequestClass.search,
      sequence: 1,
      trusted: true,
    );

    expect(
      budget.retryAtFor(RateRequestClass.search),
      now.add(const Duration(minutes: 3)),
    );
  });

  test('huge and signed numeric headers are unknown and never throw', () {
    expect(
      () => budget.noteResponse(
        headers: const <String, List<String>>{
          'RateLimit-Limit': <String>['+100'],
          'RateLimit-Remaining': <String>['1'],
          'RateLimit-Reset': <String>['999999999999999999999999999999'],
          'RateLimit-ResetTime': <String>['8640000000001'],
          'Retry-After': <String>['+1'],
        },
        statusCode: 200,
        requestClass: RateRequestClass.global,
        sequence: 1,
        trusted: true,
      ),
      returnsNormally,
    );
    expect(budget.snapshot().buckets, isEmpty);
  });

  test('global cooldown applies to every class while create is not global', () {
    budget.noteResponse(
      headers: const <String, List<String>>{
        'Retry-After': <String>['60'],
      },
      statusCode: 429,
      requestClass: RateRequestClass.create,
      sequence: 1,
      trusted: true,
    );
    expect(budget.mayStart(RateRequestClass.create), isFalse);
    expect(budget.mayStart(RateRequestClass.search), isTrue);

    budget.noteResponse(
      headers: const <String, List<String>>{
        'Retry-After': <String>['60'],
      },
      statusCode: 429,
      requestClass: RateRequestClass.global,
      sequence: 2,
      trusted: true,
    );
    expect(budget.mayStart(RateRequestClass.search), isFalse);
  });

  test('missing 429 headers respect per-class cooldown caps', () {
    budget.close();
    budget = GitLabRateBudget(
      now: () => now,
      backoff: (_) => const Duration(hours: 30),
      jitter: () => 1,
    );
    budget.noteResponse(
      headers: const <String, List<String>>{},
      statusCode: 429,
      requestClass: RateRequestClass.create,
      sequence: 1,
      trusted: true,
    );
    budget.noteResponse(
      headers: const <String, List<String>>{},
      statusCode: 429,
      requestClass: RateRequestClass.archive,
      sequence: 2,
      trusted: true,
    );

    expect(
      budget.retryAtFor(RateRequestClass.create),
      now.add(const Duration(hours: 24)),
    );
    expect(
      budget.retryAtFor(RateRequestClass.archive),
      now.add(const Duration(minutes: 15)),
    );
  });

  test('default fallback reaches the 15 minute cap per request class', () {
    for (var sequence = 1; sequence <= 5; sequence++) {
      budget.noteResponse(
        headers: const <String, List<String>>{},
        statusCode: 429,
        requestClass: RateRequestClass.archive,
        sequence: sequence,
        trusted: true,
      );
    }
    budget.noteResponse(
      headers: const <String, List<String>>{},
      statusCode: 429,
      requestClass: RateRequestClass.search,
      sequence: 6,
      trusted: true,
    );

    expect(
      budget.retryAtFor(RateRequestClass.archive),
      now.add(const Duration(minutes: 15)),
    );
    expect(
      budget.retryAtFor(RateRequestClass.search),
      now.add(const Duration(seconds: 60)),
    );
  });

  test('timer removes expired cooldown and emits recovery snapshot', () async {
    final events = <RateBudgetSnapshot>[];
    final subscription = budget.stream.listen(events.add);
    budget.noteResponse(
      headers: <String, List<String>>{
        'RateLimit-ResetTime': <String>[
          now.add(const Duration(milliseconds: 40)).toIso8601String(),
        ],
      },
      statusCode: 429,
      requestClass: RateRequestClass.search,
      sequence: 1,
      trusted: true,
    );
    now = now.add(const Duration(milliseconds: 50));
    await Future<void>.delayed(
      const Duration(milliseconds: 80),
    ).timeout(const Duration(seconds: 2));

    expect(budget.retryAtFor(RateRequestClass.search), isNull);
    expect(events.last.cooldowns, isEmpty);
    await subscription.cancel();
  });

  test('polling after expiry publishes recovery exactly once', () async {
    final events = <RateBudgetSnapshot>[];
    final subscription = budget.stream.listen(events.add);
    budget.noteResponse(
      headers: <String, List<String>>{
        'RateLimit-ResetTime': <String>[
          now.add(const Duration(minutes: 5)).toIso8601String(),
        ],
      },
      statusCode: 429,
      requestClass: RateRequestClass.search,
      sequence: 1,
      trusted: true,
    );
    events.clear();
    now = now.add(const Duration(minutes: 6));

    final recovered = budget.snapshot();
    await Future<void>.delayed(Duration.zero);

    expect(recovered.cooldowns, isEmpty);
    expect(events, hasLength(1));
    expect(events.single.cooldowns, isEmpty);
    await subscription.cancel();
  });

  test('stale success cannot reset fallback attempts', () {
    budget.noteResponse(
      headers: const <String, List<String>>{},
      statusCode: 429,
      requestClass: RateRequestClass.archive,
      sequence: 2,
      trusted: true,
    );
    expect(
      budget.retryAtFor(RateRequestClass.archive),
      now.add(const Duration(seconds: 60)),
    );

    budget.noteResponse(
      headers: rateHeaders(
        limit: 100,
        remaining: 50,
        reset: now.add(const Duration(minutes: 10)),
      ),
      statusCode: 200,
      requestClass: RateRequestClass.archive,
      sequence: 1,
      trusted: true,
    );
    budget.noteResponse(
      headers: const <String, List<String>>{},
      statusCode: 429,
      requestClass: RateRequestClass.archive,
      sequence: 3,
      trusted: true,
    );

    expect(
      budget.retryAtFor(RateRequestClass.archive),
      now.add(const Duration(seconds: 120)),
    );
  });

  test('newer success without rate headers resets fallback attempts', () {
    budget.noteResponse(
      headers: const <String, List<String>>{},
      statusCode: 429,
      requestClass: RateRequestClass.archive,
      sequence: 1,
      trusted: true,
    );
    now = now.add(const Duration(seconds: 61));
    budget.noteResponse(
      headers: const <String, List<String>>{},
      statusCode: 200,
      requestClass: RateRequestClass.archive,
      sequence: 2,
      trusted: true,
    );
    budget.noteResponse(
      headers: const <String, List<String>>{},
      statusCode: 429,
      requestClass: RateRequestClass.archive,
      sequence: 3,
      trusted: true,
    );

    expect(
      budget.retryAtFor(RateRequestClass.archive),
      now.add(const Duration(seconds: 60)),
    );
  });

  test('newer success keeps a late older 429 out of fallback streak', () {
    budget.noteResponse(
      headers: const <String, List<String>>{},
      statusCode: 200,
      requestClass: RateRequestClass.archive,
      sequence: 2,
      trusted: true,
    );
    budget.noteResponse(
      headers: const <String, List<String>>{},
      statusCode: 429,
      requestClass: RateRequestClass.archive,
      sequence: 1,
      trusted: true,
    );
    expect(
      budget.retryAtFor(RateRequestClass.archive),
      now.add(const Duration(seconds: 60)),
    );

    now = now.add(const Duration(seconds: 61));
    budget.noteResponse(
      headers: const <String, List<String>>{},
      statusCode: 429,
      requestClass: RateRequestClass.archive,
      sequence: 3,
      trusted: true,
    );

    expect(
      budget.retryAtFor(RateRequestClass.archive),
      now.add(const Duration(seconds: 60)),
    );
  });

  test('allocator caps concurrency and tracks unconsumed reservations', () {
    final allocator = RunBudgetAllocator(budget);
    final first = allocator.acquire(100)!;
    final second = allocator.acquire(100)!;
    final third = allocator.acquire(100)!;

    expect(first.granted, 40);
    expect(second.granted, 40);
    expect(third.granted, 40);
    expect(allocator.acquire(1), isNull);
    first.consume(15);
    expect(allocator.unconsumedReservations, 105);
    first.release();
    expect(allocator.activeLeases, 2);
    expect(allocator.acquire(10)?.granted, 10);
  });

  test('allocator subtracts reserve and outstanding unconsumed leases', () {
    budget.noteResponse(
      headers: rateHeaders(
        limit: 100,
        remaining: 50,
        reset: now.add(const Duration(minutes: 5)),
      ),
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: 1,
      trusted: true,
    );
    final allocator = RunBudgetAllocator(budget);
    final first = allocator.acquire(40)!;
    final second = allocator.acquire(40)!;

    expect(first.granted, 40);
    expect(second.granted, 3); // floor((50 - 3 reserve - 40 held) / 2)
    first.consume(30);
    first.release();
    expect(allocator.unconsumedReservations, 3);
    expect(allocator.acquire(40)?.granted, 22);
  });

  test('existing leases survive a lower server budget', () {
    final allocator = RunBudgetAllocator(budget);
    final lease = allocator.acquire(40)!;
    budget.noteResponse(
      headers: rateHeaders(
        limit: 100,
        remaining: 0,
        reset: now.add(const Duration(minutes: 5)),
      ),
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: 1,
      trusted: true,
    );

    expect(lease.remaining, 40);
    expect(allocator.acquire(1), isNull);
    expect(budget.mayStart(RateRequestClass.projectList), isTrue);
    expect(budget.mayStartAi(RateRequestClass.projectList), isFalse);
    expect(
      budget.mayStartAi(RateRequestClass.projectList, cleanup: true),
      isTrue,
    );
  });
}
