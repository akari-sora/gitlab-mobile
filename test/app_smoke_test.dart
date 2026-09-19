import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/main.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';

void main() {
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
  });

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
    await session.connect('https://example.com', 'synthetic-test-token');
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('我的專案'), findsOneWidget);
    await tester.tap(find.byTooltip('以連結或路徑開啟'));
    await tester.pumpAndSettle();
    expect(find.text('開啟專案'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
