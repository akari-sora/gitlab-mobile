import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/rate_budget.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';

import 'ai/release_policy_support.dart';
import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';

const _deadline = Duration(seconds: 20);

AiProviderConfig _config() => const AiProviderConfig(
  id: 'fixture-provider',
  name: 'Fixture',
  presetId: 'custom',
  baseUrl: 'https://provider.example/v1',
  format: AiFormat.chatCompletions,
  model: 'fixture-model',
  authStyle: AiAuthStyle.bearer,
  caps: AiCaps(
    tokenLimitField: AiTokenLimitField.maxTokens,
    requiresKey: false,
  ),
  allowLanCleartext: false,
  toolsEnabled: false,
  recipientRevision: 1,
);

Future<void> _until(bool Function() predicate) async {
  final elapsed = Stopwatch()..start();
  while (!predicate() && elapsed.elapsed < const Duration(seconds: 10)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(predicate(), isTrue, reason: 'fixture did not settle');
}

final class _Harness {
  final workspace = WorkspaceFixture();
  final settings = AiSettingsController(MemoryAiStore());
  DateTime now = DateTime.utc(2026, 10, 23, 12);
  late final GitLabApi api;
  late final SessionController session;
  late final FakeAdapter gitlab;
  final List<AiChatController> controllers = [];

  Future<void> initialize() async {
    gitlab = FakeAdapter((request) async {
      if (request.uri.path.endsWith('/issues/3')) {
        return jsonResponse(workspace.issue(3, 'initial title'));
      }
      if (request.uri.path.endsWith('/issues/3/notes')) {
        return jsonResponse(<Object?>[]);
      }
      return workspace.respond(request);
    });
    api = GitLabApi(
      instance: workspace.account.instance,
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = gitlab,
      readCacheClock: () => now,
    );
    final accounts = MemoryAccountStore()
      ..accounts = [workspace.account]
      ..lastActive = workspace.account.key;
    session = SessionController(
      accounts,
      readCache: accounts.readCache,
      createApi: (instance, credential, oauth, onOAuthRotated) => api,
    );
    await session.initialize();
    await settings.initialize();
    final provider = await settings.saveProvider(_config());
    await settings.loadAccount(workspace.account.key);
    await settings.grantConsent(
      workspace.account.key,
      aiConversationConsentContract(
        settings,
        workspace.account.key,
        provider,
        releasePolicy: fixtureReleasePolicy,
      ),
      const {'synthetic': true},
    );
    addTearDown(() {
      for (final controller in controllers) {
        controller.dispose();
      }
      settings.dispose();
      session.dispose();
      workspace.api.close();
      api.close();
    });
  }

  Future<AiChatController> controller() async {
    final controller = AiChatController(
      releasePolicy: fixtureReleasePolicy,
      appInForeground: () => true,
      origin: const AiGeneralOrigin(),
      session: session,
      settings: settings,
      runningCount: () => 0,
      now: () => now,
    );
    controllers.add(controller);
    await _until(() => controller.phase == AiChatPhase.idle);
    expect(controller.blocker, AiChatBlocker.none);
    return controller;
  }

  void rateCritical({required int limit, required DateTime reset}) {
    api.rateBudget.noteResponse(
      headers: <String, List<String>>{
        'ratelimit-limit': <String>['$limit'],
        'ratelimit-remaining': <String>['0'],
        'ratelimit-resettime': <String>[reset.toIso8601String()],
      },
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: api.rateBudget.nextSequence(),
      trusted: true,
    );
  }
}

void main() {
  test('U-4 critical send pause clears 10 seconds before reset', () async {
    final harness = _Harness();
    await harness.initialize();
    final controller = await harness.controller();
    final reset = harness.now.add(const Duration(seconds: 185));
    harness.rateCritical(limit: 100, reset: reset);
    expect(
      controller.sendBlockReason,
      AiChatSendBlockReason.criticalRateBudget,
    );

    final expected = GitLabRateBudget.criticalClearedAt(reset);
    expect(expected, reset.subtract(const Duration(seconds: 10)));
    expect(controller.sendBlockedUntil, expected);
  });

  test('U-5 released lease notifies so run budget block clears', () async {
    final harness = _Harness();
    await harness.initialize();
    final controller = await harness.controller();
    expect(controller.sendBlockReason, isNull);

    final first = controller.budgetAllocator.acquire(40)!;
    final second = controller.budgetAllocator.acquire(40)!;
    final third = controller.budgetAllocator.acquire(40)!;
    expect(controller.budgetAllocator.activeLeases, 3);
    expect(
      controller.sendBlockReason,
      AiChatSendBlockReason.runBudgetUnavailable,
    );

    var notifications = 0;
    void listener() => notifications++;
    controller.addListener(listener);
    first.release();
    await Future<void>.delayed(Duration.zero);
    controller.removeListener(listener);

    expect(notifications, greaterThan(0), reason: 'release must notify');
    expect(controller.sendBlockReason, isNull);
    second.release();
    third.release();
    expect(controller.budgetAllocator.activeLeases, 0);
  });

  test('N-1 over-grant consumption saturates without throwing', () async {
    final now = DateTime.utc(2026, 10, 23, 12);
    final budget = GitLabRateBudget(now: () => now);
    addTearDown(budget.close);
    final allocator = RunBudgetAllocator(budget);
    addTearDown(allocator.close);
    final lease = allocator.acquire(5)!;
    expect(lease.granted, 5);
    expect(lease.remaining, 5);

    expect(() => lease.consume(8), returnsNormally);
    expect(lease.remaining, 0);
    expect(lease.remaining, isNonNegative);
    expect(lease.overrun, 3);
  });

  test('N-3 two expired sources are both re-read once', () async {
    final cacheNow = DateTime.utc(2026, 10, 23, 12);
    var deliveryNow = cacheNow;
    var metadataReads = 0;
    var notesReads = 0;
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/notes')) {
        notesReads++;
        return jsonResponse([
          {'id': 4, 'body': 'old note'},
        ]);
      }
      metadataReads++;
      return jsonResponse({'iid': 3, 'title': 'old issue'});
    });
    final api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = adapter,
      readCacheClock: () => cacheNow,
    );
    api.bindReadCache('${api.instance.key}#7', 1);
    addTearDown(api.close);
    const issuePath = ['projects', '9', 'issues', '3'];
    const notesPath = ['projects', '9', 'issues', '3', 'notes'];
    const notesQuery = {
      'order_by': 'created_at',
      'sort': 'desc',
      'per_page': '30',
    };
    await api.cachedRecord(issuePath).timeout(_deadline);
    await api.cachedRecords(notesPath, query: notesQuery).timeout(_deadline);
    expect(adapter.requests, hasLength(2));
    deliveryNow = deliveryNow.add(const Duration(seconds: 61));

    // Both cached sources are expired from the delivery clock, so the port
    // re-reads each one once and still fails because the cache clock has not
    // advanced. The old code re-read only the oldest source (3 requests).
    await expectLater(
      GitLabAiReadPort(
        api,
        9,
        now: () => deliveryNow,
      ).issue(3).timeout(_deadline),
      throwsA(isA<ApiFailure>()),
    );
    expect(metadataReads, 2, reason: 'stale metadata is re-read once');
    expect(notesReads, 2, reason: 'stale notes are also re-read once');
    expect(adapter.requests, hasLength(4));
  });

  test('N-3 two expired sources succeed after one re-read each', () async {
    var cacheNow = DateTime.utc(2026, 10, 23, 12);
    var deliveryNow = cacheNow;
    var metadataReads = 0;
    var notesReads = 0;
    final adapter = FakeAdapter((request) {
      // Re-reads land on the delivery clock, so they come back fresh.
      if (deliveryNow.isAfter(cacheNow)) cacheNow = deliveryNow;
      if (request.uri.path.endsWith('/notes')) {
        notesReads++;
        return jsonResponse([
          {'id': 4, 'body': notesReads == 1 ? 'stale note' : 'fresh note'},
        ]);
      }
      metadataReads++;
      return jsonResponse({
        'iid': 3,
        'title': metadataReads == 1 ? 'stale title' : 'fresh title',
      });
    });
    final api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = adapter,
      readCacheClock: () => cacheNow,
    );
    api.bindReadCache('${api.instance.key}#7', 1);
    addTearDown(api.close);
    const issuePath = ['projects', '9', 'issues', '3'];
    const notesPath = ['projects', '9', 'issues', '3', 'notes'];
    const notesQuery = {
      'order_by': 'created_at',
      'sort': 'desc',
      'per_page': '30',
    };
    await api.cachedRecord(issuePath).timeout(_deadline);
    await api.cachedRecords(notesPath, query: notesQuery).timeout(_deadline);
    expect(adapter.requests, hasLength(2));
    deliveryNow = deliveryNow.add(const Duration(seconds: 61));

    // Both sources are expired from the delivery clock, so each is re-read
    // once; the re-reads land fresh, so the composition is delivered.
    final read = await GitLabAiReadPort(
      api,
      9,
      now: () => deliveryNow,
    ).issue(3).timeout(_deadline);
    expect(read.value['title'], 'fresh title');
    expect(
      ((read.value['notes'] as List<Object?>).single
          as Map<String, dynamic>)['body'],
      'fresh note',
    );
    expect(read.freshnessRetried, isTrue);
    expect(read.requestCount, 2);
    expect(read.fetchedAt, deliveryNow);
    expect(metadataReads, 2, reason: 'stale metadata is re-read once');
    expect(notesReads, 2, reason: 'stale notes are also re-read once');
    expect(adapter.requests, hasLength(4));
  });

  test('critical clear publishes recovery before reset', () async {
    var now = DateTime.utc(2026, 10, 23, 12);
    final budget = GitLabRateBudget(now: () => now);
    addTearDown(budget.close);
    final events = <RateBudgetSnapshot>[];
    final subscription = budget.stream.listen(events.add);
    addTearDown(subscription.cancel);
    final reset = now.add(const Duration(seconds: 60));
    budget.noteResponse(
      headers: <String, List<String>>{
        'ratelimit-limit': <String>['100'],
        'ratelimit-remaining': <String>['0'],
        'ratelimit-resettime': <String>[reset.toIso8601String()],
      },
      statusCode: 200,
      requestClass: RateRequestClass.global,
      sequence: budget.nextSequence(),
      trusted: true,
    );
    expect(budget.snapshot().level, RateLevel.critical);
    events.clear();

    // T=10: the critical level already cleared, but the bucket is alive.
    // Polling must still publish the recovery instead of staying silent
    // until the reset itself.
    now = now.add(const Duration(seconds: 50));
    expect(budget.snapshot().level, RateLevel.normal);
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events.single.level, RateLevel.normal);
  });

  test('U-5 re-entrant acquire on release does not throw or leak', () async {
    final now = DateTime.utc(2026, 10, 23, 12);
    final budget = GitLabRateBudget(now: () => now);
    addTearDown(budget.close);
    final allocator = RunBudgetAllocator(budget);
    addTearDown(allocator.close);
    final first = allocator.acquire(40)!;
    final second = allocator.acquire(40)!;
    final third = allocator.acquire(40)!;
    expect(allocator.activeLeases, 3);

    // Mimics the summary page: on a release notification it immediately
    // sends, which acquires a lease on the same event delivery.
    Object? failure;
    RunBudgetLease? resumed;
    var attempted = false;
    final subscription = allocator.changes.listen((_) {
      if (!attempted && allocator.activeLeases == 2) {
        attempted = true;
        try {
          resumed = allocator.acquire(40);
        } catch (error) {
          failure = error;
        }
      }
    });
    addTearDown(subscription.cancel);

    first.release();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(failure, isNull, reason: 're-entrant acquire must not throw');
    expect(resumed, isNotNull, reason: 're-entrant acquire returns a lease');
    expect(allocator.activeLeases, 3);
    second.release();
    third.release();
    resumed!.release();
    expect(allocator.activeLeases, 0, reason: 'no ownerless lease remains');
  });
}
