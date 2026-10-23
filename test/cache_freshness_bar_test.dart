import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/record_controller.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/cache_freshness.dart';

Widget _bar(CacheFreshnessBar bar, {double scale = 1, TextDirection? direction}) => MaterialApp(
  home: Scaffold(body: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Directionality(textDirection: direction ?? TextDirection.ltr,
      child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [bar])),
  )),
);

CachedRead<ApiPage<Json>> _page(String title, {bool stale = false, DateTime? at}) => CachedRead(
  value: ApiPage<Json>([{'id': 1, 'title': title}]),
  fetchedAt: at ?? DateTime.now().subtract(const Duration(minutes: 5)),
  lineage: CacheLineage.memory,
  stale: stale,
);

Widget _feed(CachedRecordLoader cached) => MaterialApp(home: Scaffold(body: RecordsFeed(
  identity: 'freshness',
  load: (_) => throw StateError('the first page comes from the cache'),
  cached: cached,
  itemBuilder: (context, item) => SizedBox(height: 56, child: Text(item['title']! as String)),
)));

void main() {
  final fiveMinutes = DateTime.now().subtract(const Duration(minutes: 5));

  testWidgets('refreshing shows the load time and a spinner, without a button', (tester) async {
    await tester.pumpWidget(_bar(CacheFreshnessBar(fetchedAt: fiveMinutes, refreshing: true)));
    expect(find.text('正在更新'), findsOneWidget);
    expect(find.text('最後更新：5 分鐘前'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('a stale list that is not refreshing only says when it was loaded', (tester) async {
    await tester.pumpWidget(_bar(CacheFreshnessBar(fetchedAt: fiveMinutes)));
    expect(find.text('最後更新：5 分鐘前'), findsOneWidget);
    expect(find.byIcon(Icons.history), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets('each background failure has its own wording and a refresh button', (tester) async {
    var retried = 0;
    for (final (kind, title, icon) in [
      (FailureKind.network, '無法連線', Icons.cloud_off_outlined),
      (FailureKind.rateLimited, 'GitLab 正在限制請求', Icons.hourglass_empty),
      (FailureKind.server, '無法更新', Icons.sync_problem),
    ]) {
      await tester.pumpWidget(_bar(CacheFreshnessBar(fetchedAt: fiveMinutes, failure: kind,
        onRetry: () => retried++)));
      expect(find.text(title), findsOneWidget, reason: '$kind');
      expect(find.byIcon(icon), findsOneWidget, reason: '$kind');
      expect(find.text('最後更新：5 分鐘前'), findsOneWidget, reason: '$kind');
      await tester.tap(find.text('重新整理'));
    }
    expect(retried, 3);
  });

  testWidgets('a rate limit states the resume time only when GitLab gave one', (tester) async {
    await tester.pumpWidget(_bar(CacheFreshnessBar(fetchedAt: fiveMinutes,
      failure: FailureKind.rateLimited, retryAt: DateTime.now().add(const Duration(seconds: 90)))));
    expect(find.text('最後更新：5 分鐘前 · 約 2 分鐘後恢復'), findsOneWidget);

    await tester.pumpWidget(_bar(CacheFreshnessBar(fetchedAt: fiveMinutes,
      failure: FailureKind.rateLimited)));
    expect(find.textContaining('恢復'), findsNothing);

    await tester.pumpWidget(_bar(CacheFreshnessBar(fetchedAt: fiveMinutes, failure: FailureKind.network,
      retryAt: DateTime.now().add(const Duration(minutes: 3)))));
    expect(find.textContaining('恢復'), findsNothing);
  });

  testWidgets('the status and the load time are read as one label', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_bar(CacheFreshnessBar(fetchedAt: fiveMinutes, failure: FailureKind.network,
      onRetry: () {})));
    expect(find.bySemanticsLabel(RegExp('無法連線\n最後更新：5 分鐘前')), findsOneWidget);
    expect(find.bySemanticsLabel('重新整理'), findsOneWidget);
    semantics.dispose();
  });

  for (final tag in ['zh-TW', 'de', 'ar']) {
    testWidgets('320 dp at twice the text size in $tag wraps and keeps the button usable', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final language = languageForTag(tag)!;
      useLanguage(language);
      addTearDown(() => useLanguage(sourceLanguage));
      var retried = 0;
      await tester.pumpWidget(_bar(CacheFreshnessBar(fetchedAt: fiveMinutes,
        failure: FailureKind.rateLimited, retryAt: DateTime.now().add(const Duration(minutes: 3)),
        onRetry: () => retried++),
        scale: 2, direction: language.rtl ? TextDirection.rtl : TextDirection.ltr));
      expect(tester.takeException(), isNull);
      final button = tester.getRect(find.byType(TextButton));
      expect(button.left, greaterThanOrEqualTo(16));
      expect(button.right, lessThanOrEqualTo(304));
      expect(button.height, greaterThanOrEqualTo(40));
      await tester.tap(find.byType(TextButton));
      expect(retried, 1);
    });
  }

  testWidgets('the feed shows the strip while a stale page refreshes and drops it once fresh', (tester) async {
    final later = Completer<CachedRead<ApiPage<Json>>>();
    await tester.pumpWidget(_feed(({required fresh, required background}) =>
        background ? later.future : Future.value(_page('Old', stale: true, at: fiveMinutes))));
    await tester.pump();
    expect(find.text('Old'), findsOneWidget);
    expect(find.text('正在更新'), findsOneWidget);

    later.complete(_page('New', at: DateTime.now()));
    await tester.pumpAndSettle();
    expect(find.text('New'), findsOneWidget);
    expect(find.byType(CacheFreshnessBar), findsNothing);
  });

  testWidgets('a failed background refresh keeps the rows and offers a fresh read', (tester) async {
    final calls = <({bool fresh, bool background})>[];
    await tester.pumpWidget(_feed(({required fresh, required background}) async {
      calls.add((fresh: fresh, background: background));
      if (background) throw const ApiFailure(FailureKind.network);
      return _page(fresh ? 'Fresh' : 'Old', stale: !fresh);
    }));
    await tester.pumpAndSettle();
    expect(find.text('Old'), findsOneWidget);
    expect(find.text('無法連線'), findsOneWidget);

    await tester.tap(find.text('重新整理'));
    await tester.pumpAndSettle();
    expect(find.text('Fresh'), findsOneWidget);
    expect(find.byType(CacheFreshnessBar), findsNothing);
    expect(calls.last, (fresh: true, background: false));
  });

  testWidgets('a fresh first page shows no strip', (tester) async {
    await tester.pumpWidget(_feed(({required fresh, required background}) async =>
        _page('Row', at: DateTime.now())));
    await tester.pumpAndSettle();
    expect(find.text('Row'), findsOneWidget);
    expect(find.byType(CacheFreshnessBar), findsNothing);
  });
}
