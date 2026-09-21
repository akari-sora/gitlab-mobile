import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/main.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets('full application boots to the login screen', (tester) async {
    final adapter = FakeAdapter((_) => jsonResponse([]));
    final session = controllerFor(MemoryAccountStore(), adapter);
    addTearDown(session.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWithValue(session)],
      child: const GitLabMobileApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('instanceField')), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(adapter.requests, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('authenticated shell reaches projects and opens locator', (tester) async {
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
    await tester.runAsync(() async {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('我的專案'), findsOneWidget);
    await tester.tap(find.byTooltip('以連結或路徑開啟'));
    await tester.pumpAndSettle();
    expect(find.text('開啟專案'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('resume scaffold shows the username and can switch accounts', (tester) async {
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
  }, timeout: const Timeout(Duration(minutes: 1)));
}
