import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/my_work_page.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

GitLabApi _boundApi(FakeAdapter adapter, {required DateTime Function() clock}) {
  final api = GitLabApi(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    token: 'synthetic-test-token',
    dio: Dio()..httpClientAdapter = adapter,
    readCacheClock: clock,
  );
  api.bindReadCache('${api.instance.key}#7', 1);
  return api;
}

Widget _feed(GitLabApi api, Key key) => MaterialApp(
  home: MyWorkPage(
    key: key,
    account: Account(
      instance: api.instance,
      user: const GitLabUser(id: 7, username: 'tester', name: 'Test User'),
      token: 'synthetic-test-token',
    ),
    api: api,
    kind: MyWorkKind.issues,
  ),
);

Json _issue(int id, String title) => {
  'id': id,
  'iid': id,
  'project_id': 10,
  'title': title,
  'state': 'opened',
  'updated_at': '2026-10-23T08:00:00Z',
  'references': {'full': 'team/project#$id'},
};

int _issueRequests(FakeAdapter adapter) => adapter.requests
    .where((request) => request.uri.path.endsWith('/api/v4/issues'))
    .length;

void main() {
  testWidgets(
    'issues fixture with one row and no notes, warm fresh cache, 800x600 viewport, clock +30s: reopen settles with zero endpoint requests',
    (tester) async {
      var now = DateTime.utc(2026, 10, 23, 8);
      final adapter = FakeAdapter(
        (_) => jsonResponse([_issue(1, 'Cached issue')]),
      );
      final api = _boundApi(adapter, clock: () => now);
      addTearDown(api.close);

      await tester.pumpWidget(_feed(api, const ValueKey('fresh-first-open')));
      await settleNetworkWidgets(tester);
      expect(find.text('Cached issue'), findsOneWidget);
      expect(_issueRequests(adapter), 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      now = now.add(const Duration(seconds: 30));

      await tester.pumpWidget(_feed(api, const ValueKey('fresh-reopen')));
      await settleNetworkWidgets(tester);

      expect(find.text('Cached issue'), findsOneWidget);
      expect(
        _issueRequests(adapter),
        1,
        reason: 'the reopen itself must add zero GET /issues requests',
      );
    },
  );

  testWidgets(
    'issues fixture with one row and no notes, stale memory cache, 800x600 viewport, clock +61s: row paints before exactly one blocked background request settles',
    (tester) async {
      var now = DateTime.utc(2026, 10, 23, 8);
      final background = Completer<ResponseBody>();
      var sends = 0;
      final adapter = FakeAdapter((_) {
        sends++;
        if (sends == 1) {
          return jsonResponse([_issue(1, 'Cached issue')]);
        }
        return background.future;
      });
      final api = _boundApi(adapter, clock: () => now);
      addTearDown(api.close);

      await tester.pumpWidget(_feed(api, const ValueKey('stale-first-open')));
      await settleNetworkWidgets(tester);
      expect(find.text('Cached issue'), findsOneWidget);
      expect(_issueRequests(adapter), 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      now = now.add(const Duration(seconds: 61));

      await tester.pumpWidget(_feed(api, const ValueKey('stale-reopen')));
      await tester.pump();
      await tester.pump();

      expect(
        find.text('Cached issue'),
        findsOneWidget,
        reason: 'the stale row must paint while the network response is held',
      );

      await pumpUntil(
        tester,
        () => _issueRequests(adapter) == 2,
        description: 'one background GET /issues starts',
      );
      expect(
        _issueRequests(adapter),
        2,
        reason: 'one stale reopen must start exactly one background request',
      );

      background.complete(jsonResponse([_issue(2, 'Fresh issue')]));
      await settleNetworkWidgets(tester);

      expect(find.text('Fresh issue'), findsOneWidget);
      expect(find.text('Cached issue'), findsNothing);
      expect(_issueRequests(adapter), 2);
    },
  );
}
