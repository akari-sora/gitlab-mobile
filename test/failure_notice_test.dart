import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

Account _account() => Account(
  instance: GitLabInstance.parse('https://example.com/gitlab'),
  user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
  token: 'synthetic-test-token',
);

void main() {
  testWidgets('404 notice shows instance, account, resource and switch without rotating', (tester) async {
    var switched = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: FailureNotice(
      const ApiFailure(FailureKind.invisible, status: 404),
      account: _account(), resourceLabel: 'studio/private',
      onRetry: () {}, onSwitchAccount: () { switched++; },
    ))));
    expect(find.text('無法開啟此資源'), findsOneWidget);
    expect(find.text('實例：https://example.com/gitlab'), findsOneWidget);
    expect(find.text('App 帳號：@tester'), findsOneWidget);
    expect(find.text('目標：studio/private'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);
    expect(find.text('重新整理'), findsOneWidget);
    await tester.tap(find.text('切換帳號'));
    await tester.pump();
    expect(switched, 1);
  });

  testWidgets('list 404 card carries account and does not auto-switch', (tester) async {
    final adapter = FakeAdapter((_) => jsonResponse({'message': 'not found'}, status: 404));
    final api = testApi(adapter); addTearDown(api.close);
    var switched = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RecordsFeed(
      identity: 'todos', account: _account(), resourceLabel: '待辦',
      onSwitchAccount: () { switched++; },
      load: (next) => api.records(['todos'], next: next),
      itemBuilder: (context, item) => const SizedBox(),
    ))));
    await settleNetworkWidgets(tester);
    expect(find.text('App 帳號：@tester'), findsOneWidget);
    expect(find.text('目標：待辦'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);
    await tester.tap(find.text('切換帳號'));
    await tester.pump();
    expect(switched, 1);
  });

  testWidgets('writeUncertain omits retry', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: FailureNotice(
      const ApiFailure(FailureKind.writeUncertain),
      account: _account(), onRetry: () {},
    ))));
    expect(find.text('重新整理'), findsNothing);
  });

  testWidgets('FailureNotice with resumeTarget sets pendingResumeTarget and switches', (tester) async {
    final adapter = FakeAdapter((_) => jsonResponse({'id': 7, 'username': 'tester'}));
    final store = MemoryAccountStore();
    final session = controllerFor(store, adapter);
    addTearDown(session.dispose);

    const target = ResumeTarget(
      projectId: 10,
      projectPath: 'org/repo',
      resource: 'issues',
      iid: 42,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: MaterialApp(
          home: Scaffold(
            body: FailureNotice(
              const ApiFailure(FailureKind.invisible, status: 404),
              account: _account(),
              resourceLabel: 'org/repo · Issue #42',
              resumeTarget: target,
            ),
          ),
        ),
      ),
    );

    expect(find.text('切換帳號'), findsOneWidget);
    await tester.tap(find.text('切換帳號'));
    await tester.pump();

    expect(session.pendingResumeTarget, target);
  });

  testWidgets(
    'FailureNotice ExpansionTile does not collide with PageStorage double scroll offset',
    (tester) async {
      final bucket = PageStorageBucket();
      const feedKey = PageStorageKey<String>('group-feed-storage-id');

      // 1. Initial build: Scrollable with ancestor PageStorageKey has a large height to allow scrolling
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageStorage(
              bucket: bucket,
              child: CustomScrollView(
                key: feedKey,
                slivers: const [
                  SliverToBoxAdapter(
                    child: SizedBox(height: 1200),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // 2. Drag the scroll view to establish a non-zero double scroll offset in PageStorage
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -250));
      await tester.pumpAndSettle();

      // 3. Rebuild with FailureNotice rendered in the scroll view under the same PageStorageKey.
      // Prior to storage key separation on ExpansionTile, ExpansionTile inherited the
      // same PageStorage identifier as the ScrollPosition and attempted to cast the stored
      // double scroll offset (250.0) to bool?, throwing a TypeError.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageStorage(
              bucket: bucket,
              child: CustomScrollView(
                key: feedKey,
                slivers: [
                  const SliverToBoxAdapter(
                    child: SizedBox(height: 1200),
                  ),
                  SliverToBoxAdapter(
                    child: FailureNotice(
                      const ApiFailure(FailureKind.invalidResponse),
                      account: _account(),
                      resourceLabel: 'group/project · 工作項目',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // Verify initial rebuild with restored non-zero scroll offset succeeds without error
      expect(tester.takeException(), isNull);

      // Scroll the CustomScrollView to bring the offscreen FailureNotice into view
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('診斷資訊'), findsOneWidget);

      await tester.ensureVisible(find.text('診斷資訊'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('診斷資訊'));
      await tester.pumpAndSettle();

      expect(find.text('invalidResponse'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Verify collapse behavior
      await tester.tap(find.text('診斷資訊'));
      await tester.pumpAndSettle();

      expect(find.text('invalidResponse'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
