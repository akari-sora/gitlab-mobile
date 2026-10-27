import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/features/shell/language.dart' show rebuildForLanguage;
import 'package:gitlab_mobile/features/workspace/records_feed.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

/// A snack bar action with this label, including SnackBarAction subclasses.
Finder _snackAction(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((widget) => widget is SnackBarAction),
);

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

  group('C2e read-cache cleanup notices (§4.6)', () {
    // Exact zh-TW text and permitted actions per disposition.
    const expected = <ReadCacheCleanupDisposition, (String, String, bool, bool)>{
      ReadCacheCleanupDisposition.requestBlockedBeforeSend: (
        '變更尚未送出',
        '離線快取無法清除，所以這項變更沒有送到 GitLab。請先重試清除，再重新送出。',
        true, // the unsent request may be retried explicitly
        true,
      ),
      ReadCacheCleanupDisposition.originalOutcomePreserved: (
        '離線快取待清除',
        '操作的結果不受影響。離線快取已暫停使用，清除完成後才會恢復。',
        false,
        true,
      ),
      ReadCacheCleanupDisposition.legalNetworkValueReturned: (
        '離線快取已暫停',
        '畫面上是剛從 GitLab 取得的內容。舊的離線快取還沒清除，已暫停使用。',
        false,
        true,
      ),
      ReadCacheCleanupDisposition.accountRetained: (
        '無法清除離線快取',
        '離線快取尚未清除。帳號已保留，請重試移除。',
        false,
        false, // removal is retried from the account row, not the notice
      ),
      ReadCacheCleanupDisposition.signedOutCleanupPending: (
        '離線快取尚未清除',
        '已登出，但這台裝置上的離線快取還沒清除完成。可以重試清除。',
        false,
        true,
      ),
      ReadCacheCleanupDisposition.diskClosed: (
        '無法清除離線快取',
        '離線快取已暫停使用，重試清除完成後才會恢復。',
        false,
        true,
      ),
    };
    const operations = <ReadCacheCleanupDisposition, ReadCacheCleanupOperation>{
      ReadCacheCleanupDisposition.requestBlockedBeforeSend: ReadCacheCleanupOperation.mutation,
      ReadCacheCleanupDisposition.originalOutcomePreserved: ReadCacheCleanupOperation.mutation,
      ReadCacheCleanupDisposition.legalNetworkValueReturned: ReadCacheCleanupOperation.privacyRead,
      ReadCacheCleanupDisposition.accountRetained: ReadCacheCleanupOperation.accountRemoval,
      ReadCacheCleanupDisposition.signedOutCleanupPending: ReadCacheCleanupOperation.signOut,
      ReadCacheCleanupDisposition.diskClosed: ReadCacheCleanupOperation.startup,
    };
    ApiFailure failure(ReadCacheCleanupDisposition disposition, ReadCacheCleanupCode code) =>
        ApiFailure.readCacheCleanup(ReadCacheCleanupState(
          operation: operations[disposition]!,
          disposition: disposition,
          code: code,
          clearResult: const DiskClearResult(
            keyGoneConfirmed: false,
            directoryGoneConfirmed: false,
            markerDurable: false,
            complete: false,
          ),
        ));

    test('every disposition has a mapping', () {
      expect(expected.keys.toSet(), ReadCacheCleanupDisposition.values.toSet());
    });

    for (final entry in expected.entries) {
      for (final code in ReadCacheCleanupCode.values) {
        testWidgets('FailureNotice ${entry.key.name}/${code.name}: text and actions', (tester) async {
          final (title, detail, originalRetry, cleanupRetry) = entry.value;
          var retried = 0, cleaned = 0;
          final error = failure(entry.key, code);
          await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
            child: FailureNotice(error, account: _account(),
              onRetry: () => retried++, onRetryCleanup: () => cleaned++),
          ))));
          expect(find.text(title), findsOneWidget);
          expect(find.text(detail), findsOneWidget);
          // The core fallback text is never what the user sees.
          expect(find.text(error.title), findsNothing);
          expect(find.text('切換帳號'), findsNothing);
          expect(find.text('重新整理'), originalRetry ? findsOneWidget : findsNothing);
          expect(find.text('重試清除'), cleanupRetry ? findsOneWidget : findsNothing);
          if (cleanupRetry) {
            await tester.tap(find.text('重試清除'));
            await tester.pump();
          }
          expect((retried, cleaned), (0, cleanupRetry ? 1 : 0),
            reason: 'a cleanup notice never re-runs the original operation');
          await tester.tap(find.text('診斷資訊'));
          await tester.pumpAndSettle();
          expect(find.text('readCacheCleanup · ${entry.key.name} · ${code.name}'), findsOneWidget);
        });
      }
      testWidgets('showFailure ${entry.key.name}: snack bar text and cleanup-only action', (tester) async {
        final (title, detail, _, cleanupRetry) = entry.value;
        var cleaned = 0;
        late BuildContext captured;
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) {
          captured = context;
          return const SizedBox();
        }))));
        showFailure(captured, failure(entry.key, ReadCacheCleanupCode.cleanupFailed),
          onRetryCleanup: () => cleaned++);
        await tester.pump();
        expect(find.text(l10n.titleThenDetail(title, detail)), findsOneWidget);
        final action = _snackAction('重試清除');
        expect(action, cleanupRetry ? findsOneWidget : findsNothing);
        if (cleanupRetry) {
          // The long zh-TW text can push the action past an 800x600 test view.
          tester.widget<SnackBarAction>(action).onPressed();
          await tester.pump();
        }
        expect(cleaned, cleanupRetry ? 1 : 0);
      });
    }

    testWidgets('other failures keep their own text and the screen retry', (tester) async {
      var retried = 0;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
        child: FailureNotice(const ApiFailure(FailureKind.network), account: _account(),
          onRetry: () => retried++, onRetryCleanup: () {}),
      ))));
      expect(find.text('無法連線'), findsOneWidget);
      expect(find.text('重試清除'), findsNothing);
      await tester.tap(find.text('重新整理'));
      expect(retried, 1);
    });

    // FIX1 (review P2-6): snack bars are built from the current language, so
    // one on screen and one still queued both follow a switch.
    testWidgets('shown and queued cleanup snack bars follow a language switch', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) {
        captured = context;
        return const SizedBox();
      }))));
      showFailure(captured, failure(ReadCacheCleanupDisposition.originalOutcomePreserved,
        ReadCacheCleanupCode.cleanupFailed), onRetryCleanup: () {});
      showFailure(captured, failure(ReadCacheCleanupDisposition.signedOutCleanupPending,
        ReadCacheCleanupCode.cleanupFailed), onRetryCleanup: () {});
      await tester.pumpAndSettle();
      expect(find.text('離線快取待清除。操作的結果不受影響。離線快取已暫停使用，清除完成後才會恢復。'), findsOneWidget);
      expect(_snackAction('重試清除'), findsOneWidget);

      useLanguage(languageForTag('en')!);
      // What the app does on a language change (above the ScaffoldMessenger).
      rebuildForLanguage(tester.element(find.byType(MaterialApp)));
      await tester.pump();
      expect(find.text('Offline cache needs clearing. The result of your action is not affected. '
        'The offline cache is paused until clearing finishes.'), findsOneWidget);
      expect(_snackAction('Retry clearing'), findsOneWidget);
      expect(find.textContaining('離線快取'), findsNothing);

      ScaffoldMessenger.of(captured).hideCurrentSnackBar();
      await tester.pumpAndSettle();
      expect(find.text('Offline cache not cleared yet. You are signed out, but the offline cache on this '
        'device hasn’t been fully cleared. You can retry clearing.'), findsOneWidget,
        reason: 'the queued snack bar shows in the new language');
      expect(_snackAction('Retry clearing'), findsOneWidget);
    });

    testWidgets('text follows a language switch; nothing translated is stored', (tester) async {
      final error = failure(ReadCacheCleanupDisposition.originalOutcomePreserved,
        ReadCacheCleanupCode.barrierTimedOut);
      final rebuild = ValueNotifier(0);
      addTearDown(rebuild.dispose);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
        child: ValueListenableBuilder<int>(valueListenable: rebuild,
          builder: (_, value, _) => FailureNotice(error, key: ValueKey(value), onRetryCleanup: () {})),
      ))));
      expect(find.text('離線快取待清除'), findsOneWidget);
      useLanguage(languageForTag('en')!);
      rebuild.value++;
      await tester.pump();
      expect(find.text('Offline cache needs clearing'), findsOneWidget);
      expect(find.text('Retry clearing'), findsOneWidget);
      expect(find.text('離線快取待清除'), findsNothing);
      useLanguage(languageForTag('ja')!);
      rebuild.value++;
      await tester.pump();
      expect(find.text('オフラインキャッシュの消去が保留中です'), findsOneWidget);
    });
  });
}
