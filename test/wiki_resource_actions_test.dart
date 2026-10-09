import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/project_extras.dart';
import 'package:gitlab_mobile/shared/resource_share.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _project = Project(
  id: 42,
  name: 'Mobile Workspace',
  path: 'studio/mobile-workspace',
  defaultBranch: 'main',
);

Account _account(GitLabApi api) => Account(
  instance: api.instance,
  user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
  token: 'synthetic-test-token',
);

Widget _host({
  required GitLabApi api,
  required String slug,
  String title = 'Wiki',
  double scale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: WikiPageView(
    account: _account(api),
    api: api,
    project: _project,
    slug: slug,
    title: title,
  ),
);

void main() {
  testWidgets(
    'nested wiki share preserves instance subpath and stays usable at 320dp 2x',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final adapter = FakeAdapter(
        (_) => jsonResponse({
          'slug': 'handbook/setup',
          'title': 'Setup',
          'format': 'markdown',
          'content': 'Current wiki content',
        }),
      );
      final api = testApi(
        adapter,
        host: 'https://example.com:8443/gitlab/root',
      );
      addTearDown(() {
        if (!api.isClosed) api.close();
      });

      await tester.pumpWidget(
        _host(
          api: api,
          slug: 'handbook/setup',
          title: 'A deliberately long Wiki page title that must stay compact',
          scale: 2,
        ),
      );
      await settleNetworkWidgets(tester);

      final title = tester.widget<Text>(
        find.text('A deliberately long Wiki page title that must stay compact'),
      );
      final share = tester.widget<ResourceShareButton>(
        find.byType(ResourceShareButton),
      );
      expect(
        share.uri.toString(),
        'https://example.com:8443/gitlab/root/studio/mobile-workspace/-/wikis/handbook/setup',
      );
      expect(find.byTooltip('分享連結'), findsOneWidget);
      expect(find.byTooltip('在 GitLab 開啟'), findsOneWidget);
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      final appBarRect = tester.getRect(find.byType(AppBar));
      final titleRect = tester.getRect(
        find.text('A deliberately long Wiki page title that must stay compact'),
      );
      final shareRect = tester.getRect(find.byTooltip('分享連結'));
      expect(titleRect.top, greaterThanOrEqualTo(appBarRect.top));
      expect(titleRect.bottom, lessThanOrEqualTo(appBarRect.bottom));
      expect(titleRect.right, lessThanOrEqualTo(shareRect.left));
      expect(shareRect.left, greaterThanOrEqualTo(0));
      expect(
        tester.getRect(find.byTooltip('在 GitLab 開啟')).right,
        lessThanOrEqualTo(320),
      );
      expect(tester.takeException(), isNull);

      api.close();
      expect(share.isCurrent?.call(), isFalse);
    },
  );

  testWidgets('pending old wiki read cannot replace a new slug', (
    tester,
  ) async {
    final oldRead = Completer<ResponseBody>();
    final adapter = FakeAdapter((request) {
      final slug = request.uri.pathSegments.last;
      if (slug == 'old/page') return oldRead.future;
      if (slug == 'new/page') {
        return jsonResponse({
          'slug': slug,
          'title': 'New page',
          'format': 'markdown',
          'content': 'Replacement wiki content',
        });
      }
      throw StateError('Unexpected wiki slug: $slug');
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(_host(api: api, slug: 'old/page'));
    await tester.pump();
    await tester.pumpWidget(_host(api: api, slug: 'new/page'));
    await settleNetworkWidgets(tester);
    expect(find.text('Replacement wiki content'), findsOneWidget);

    oldRead.complete(
      jsonResponse({
        'slug': 'old/page',
        'title': 'Old page',
        'format': 'markdown',
        'content': 'Stale wiki content',
      }),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('Replacement wiki content'), findsOneWidget);
    expect(find.text('Stale wiki content'), findsNothing);
    expect(
      tester
          .widget<ResourceShareButton>(find.byType(ResourceShareButton))
          .uri
          .path,
      endsWith('/-/wikis/new/page'),
    );
  });
}
