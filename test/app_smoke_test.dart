import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/main.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';

Future<void> _settleReadCache(WidgetTester tester, SessionController session) async {
  for (var i = 0; i < 100 && !session.readCache.startupRecovered; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(session.readCache.startupRecovered, isTrue,
    reason: 'readable=${session.readCacheStartupDecision?.readable}; '
      'current=${session.readCacheStartupDecision == null ? false : session.isReadCacheDecisionCurrent(session.readCacheStartupDecision!)}; '
      'active=${session.active != null}; pending=${session.pendingSignOutCleanup}');
  var quiesced = false;
  unawaited(session.readCache.quiesced.then((_) => quiesced = true));
  for (var i = 0; i < 100 && !quiesced; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(quiesced, isTrue);
  var recovered = false;
  unawaited(startupRecoveryQuiescedForTesting(session).then((_) => recovered = true));
  for (var i = 0; i < 100 && !recovered; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(recovered, isTrue);
}

void main() {
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AiHistoryCoordinator.debugReset(store: MemoryAiStore());
    // Configure the process singleton outside a widget's disposable fake zone.
    final sessionStore = MemoryAccountStore();
    final session = SessionController(sessionStore, readCache: sessionStore.readCache);
    await session.initialize();
    await startAiWriteJournal(session);
    session.dispose();
  });
  testWidgets('full application boots to the login screen', (tester) async {
    final adapter = FakeAdapter((_) => jsonResponse([]));
    final session = controllerFor(MemoryAccountStore(), adapter);
    addTearDown(session.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWithValue(session)],
      child: const GitLabMobileApp(),
    ));
    await tester.pumpAndSettle();
    await _settleReadCache(tester, session);
    expect(find.byKey(const Key('instanceField')), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(adapter.requests, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('authenticated shell reaches projects and opens locator', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final adapter = FakeAdapter((request) => request.uri.path.endsWith('/user')
      ? jsonResponse({'id': 7, 'username': 'tester'}) : jsonResponse([]));
    final session = controllerFor(MemoryAccountStore(), adapter);
    addTearDown(session.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWithValue(session)],
      child: const GitLabMobileApp(),
    ));
    await tester.pumpAndSettle();
    // Dio's asynchronous stream processing must use real async scheduling,
    // rather than wait for work trapped in the widget test's fake clock.
    await tester.runAsync(() => session.connect('https://example.com', 'synthetic-test-token'));
    // Observable bounded sync:
    // Wait until authentication transition completes and initial feed loading finishes.
    // RecordsFeed mounts RowsSkeleton (a pulsing placeholder) while loading.
    // pumpAndSettle() cannot settle while it or a CircularProgressIndicator is animating.
    // We pump real async and test clock bounded by observable state:
    // - NavigationBar is mounted (AuthenticatedApp mounted)
    // - CircularProgressIndicator and RowsSkeleton are gone (projects feed finished loading)
    // - Projects request has been initiated by RecordsFeed
    var settled = false;
    for (var cycle = 0; cycle < 100; cycle++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      final hasNavBar = find.byType(NavigationBar).evaluate().isNotEmpty;
      final hasSpinner = find.byType(CircularProgressIndicator).evaluate().isNotEmpty ||
          find.byWidgetPredicate((w) => w is Skeleton).evaluate().isNotEmpty;
      final hasProjectsRequest = adapter.requests.any((r) => r.uri.path.contains('projects'));
      if (hasNavBar && !hasSpinner && hasProjectsRequest) {
        settled = true;
        break;
      }
    }
    if (!settled) {
      fail(
        'Smoke test failed to reach observable settled state within bounded wait:\n'
        '  session.active: ${session.active?.user.username}\n'
        '  requests: ${adapter.requests.map((r) => r.uri.toString()).toList()}\n'
        '  hasNavBar: ${find.byType(NavigationBar).evaluate().isNotEmpty}\n'
        '  hasSpinner: ${find.byType(CircularProgressIndicator).evaluate().isNotEmpty}\n'
        '  binding.hasScheduledFrame: ${tester.binding.hasScheduledFrame}',
      );
    }
    await tester.pumpAndSettle();
    await _settleReadCache(tester, session);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('我的工作'), findsOneWidget, reason: 'the shell opens on Home');
    await tester.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('探索')));
    await tester.pumpAndSettle();
    expect(find.text('我的專案'), findsOneWidget);
    await tester.tap(find.byTooltip('以連結或路徑開啟'));
    await tester.pumpAndSettle();
    expect(find.text('開啟專案'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('resume scaffold shows the username and can switch accounts', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
    final saved = Account(
      instance: GitLabInstance.parse('https://example.com'),
      user: const GitLabUser(id: 7, username: 'tester', name: 'Tester'),
      token: 'synthetic-test-token',
    );
    final store = MemoryAccountStore()
      ..accounts = [saved]
      ..lastActive = saved.key;
    final deferred = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => deferred.future);
    final session = controllerFor(store, adapter);
    addTearDown(session.dispose);
    addTearDown(() {
      if (!deferred.isCompleted) {
        deferred.complete(jsonResponse({'id': 7, 'username': 'tester'}));
      }
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWithValue(session)],
      child: const GitLabMobileApp(),
    ));
    for (var i = 0; i < 20 && find.text('正在恢復 @tester').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(find.text('正在恢復 @tester'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('正在恢復 @tester')).flagsCollection.isLiveRegion,
      isTrue,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('改用其他帳號'), findsOneWidget);
    expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
    expect(find.byKey(const Key('instanceField')), findsNothing);
    await tester.tap(find.text('改用其他帳號'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('instanceField')), findsOneWidget);
    expect(find.text('正在恢復 @tester'), findsNothing);
    expect(session.active, isNull);
    if (!deferred.isCompleted) {
      deferred.complete(jsonResponse({'id': 7, 'username': 'tester'}));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
    expect(session.active, isNull);
    expect(find.byKey(const Key('instanceField')), findsOneWidget);
    await _settleReadCache(tester, session);
    } finally {
      semantics.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}
