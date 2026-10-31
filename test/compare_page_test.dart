import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/compare_page.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _project = Project(
  id: 42,
  name: 'Mobile',
  path: 'studio/mobile',
  visibility: 'private',
  defaultBranch: 'main',
);

Account _account(GitLabApi api, {int id = 7, String username = 'developer'}) =>
    Account(
      instance: api.instance,
      user: GitLabUser(id: id, username: username, name: username),
      token: 'synthetic-test-token',
    );

Widget _host(GitLabApi api, {Account? account, double textScale = 1}) =>
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: ComparePage(
        account: account ?? _account(api),
        api: api,
        project: _project,
      ),
    );

Future<void> _compare(
  WidgetTester tester, {
  String from = 'main',
  String to = 'feature/mobile',
  bool direct = false,
}) async {
  await tester.enterText(find.byKey(const Key('compare-from')), from);
  await tester.enterText(find.byKey(const Key('compare-to')), to);
  if (direct) {
    await tester.tap(find.byKey(const Key('compare-mode-direct')));
  }
  await tester.tap(find.byKey(const Key('compare-submit')));
  await settleNetworkWidgets(tester);
}

Map<String, Object?> _response({
  bool timeout = false,
  bool sameRef = false,
  List<Map<String, Object?>> commits = const [],
  List<Map<String, Object?>> diffs = const [],
}) => {
  'compare_timeout': timeout,
  'compare_same_ref': sameRef,
  'commits': commits,
  'diffs': diffs,
};

Map<String, Object?> _commit(int index) => {
  'id': index.toString().padLeft(40, 'a'),
  'short_id': 'sha$index',
  'title': 'Commit $index',
  'author_name': 'Developer',
  'created_at': '2026-10-02T00:00:00Z',
};

Map<String, Object?> _diff(int index, {String? diff}) => {
  'old_path': 'lib/file_$index.dart',
  'new_path': 'lib/file_$index.dart',
  'new_file': false,
  'renamed_file': false,
  'deleted_file': false,
  'diff': diff ?? '@@ -1 +1 @@\n-old $index\n+new $index',
};

void main() {
  testWidgets('only Compare sends the exact repository compare query', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) => jsonResponse(_response()));
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api));

    await tester.enterText(find.byKey(const Key('compare-to')), 'feature/ui');
    await tester.pump(const Duration(milliseconds: 500));
    expect(adapter.requests, isEmpty, reason: 'typing must not send requests');

    await _compare(tester, to: 'feature/ui', direct: true);

    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.uri.path, endsWith('/projects/42/repository/compare'));
    expect(request.uri.queryParameters, {
      'from': 'main',
      'to': 'feature/ui',
      'straight': 'true',
      'unidiff': 'true',
    });
  });

  testWidgets(
    'editing refs or mode clears the bound result without requesting',
    (tester) async {
      var response = 0;
      final adapter = FakeAdapter((request) {
        response++;
        return jsonResponse(_response(commits: [_commit(response)]));
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(_host(api));

      await _compare(tester);
      expect(find.text('Commit 1'), findsOneWidget);
      expect(
        find.byKey(
          const PageStorageKey(
            'compare-commits/main/feature%2Fmobile/merge-base',
          ),
        ),
        findsOneWidget,
      );

      await tester.enterText(
        find.byKey(const Key('compare-to')),
        'feature/edited',
      );
      await tester.pump();
      expect(find.text('Commit 1'), findsNothing);
      expect(find.text('選擇兩個版本後執行比較'), findsOneWidget);
      expect(adapter.requests, hasLength(1));

      await tester.tap(find.byKey(const Key('compare-submit')));
      await settleNetworkWidgets(tester);
      expect(find.text('Commit 2'), findsOneWidget);
      await tester.tap(find.byKey(const Key('compare-mode-direct')));
      await tester.pump();
      expect(find.text('Commit 2'), findsNothing);
      expect(adapter.requests, hasLength(2));
    },
  );

  testWidgets('editing while a compare is pending invalidates its response', (
    tester,
  ) async {
    final pending = Completer<ResponseBody>();
    final adapter = FakeAdapter((request) => pending.future);
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api));

    await tester.enterText(
      find.byKey(const Key('compare-to')),
      'original-target',
    );
    await tester.tap(find.byKey(const Key('compare-submit')));
    await pumpUntil(
      tester,
      () => adapter.requests.isNotEmpty,
      description: 'compare request starts',
    );
    expect(find.byType(CompareSkeleton), findsOneWidget);
    expect(
      adapter.requests.single.uri.queryParameters['to'],
      'original-target',
    );

    await tester.enterText(find.byKey(const Key('compare-to')), 'new-target');
    await tester.pump();
    expect(find.byType(CompareSkeleton), findsNothing);
    expect(find.text('選擇兩個版本後執行比較'), findsOneWidget);

    pending.complete(jsonResponse(_response(commits: [_commit(99)])));
    await settleNetworkWidgets(tester);
    expect(find.text('Commit 99'), findsNothing);
    expect(adapter.requests, hasLength(1));
  });

  testWidgets('timeout with empty diffs never claims there are no changes', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (request) =>
          jsonResponse(_response(timeout: true, commits: [_commit(1)])),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api));
    await _compare(tester);

    expect(find.textContaining('提交清單完整'), findsOneWidget);
    await tester.tap(find.text('檔案'));
    await tester.pumpAndSettle();
    expect(find.textContaining('這不代表沒有變更'), findsOneWidget);
    expect(find.text('沒有變更'), findsNothing);
  });

  testWidgets('compare_same_ref has a distinct empty result', (tester) async {
    final adapter = FakeAdapter(
      (request) => jsonResponse(_response(sameRef: true)),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api));
    await _compare(tester, from: 'same', to: 'same');

    expect(find.text('兩個版本相同，沒有差異'), findsOneWidget);
  });

  testWidgets('404 identifies the account and target and can retry', (
    tester,
  ) async {
    var attempts = 0;
    final adapter = FakeAdapter((request) {
      attempts++;
      if (attempts == 1) {
        return jsonResponse({'message': 'not found'}, status: 404);
      }
      return jsonResponse(_response(sameRef: true));
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api));
    await _compare(tester);

    expect(find.text('無法開啟此資源'), findsOneWidget);
    expect(find.text('App 帳號：@developer'), findsOneWidget);
    expect(find.text('目標：studio/mobile · main…feature/mobile'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);
    await tester.tap(find.text('重新整理'));
    await settleNetworkWidgets(tester);
    expect(find.text('兩個版本相同，沒有差異'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('an old account response cannot replace the new page state', (
    tester,
  ) async {
    final oldResponse = Completer<ResponseBody>();
    final oldAdapter = FakeAdapter((request) => oldResponse.future);
    final oldApi = testApi(oldAdapter);
    final newAdapter = FakeAdapter(
      (request) => jsonResponse(_response(commits: [_commit(2)])),
    );
    final newApi = testApi(newAdapter);
    addTearDown(oldApi.close);
    addTearDown(newApi.close);

    await tester.pumpWidget(_host(oldApi));
    await tester.enterText(find.byKey(const Key('compare-to')), 'old-target');
    await tester.tap(find.byKey(const Key('compare-submit')));
    await tester.pump();
    expect(find.byType(CompareSkeleton), findsOneWidget);

    await tester.pumpWidget(
      _host(newApi, account: _account(newApi, id: 8, username: 'new-user')),
    );
    await tester.pump();
    oldResponse.complete(jsonResponse(_response(commits: [_commit(999)])));
    await settleNetworkWidgets(tester);

    expect(find.text('Commit 999'), findsNothing);
    expect(newAdapter.requests, isEmpty);
    await _compare(tester, to: 'new-target');
    expect(find.text('Commit 2'), findsOneWidget);
  });

  testWidgets('account generation change dismisses its owned branch picker', (
    tester,
  ) async {
    final branches = Completer<ResponseBody>();
    final oldAdapter = FakeAdapter((request) => branches.future);
    final oldApi = testApi(oldAdapter);
    final newAdapter = FakeAdapter((request) => jsonResponse([]));
    final newApi = testApi(newAdapter);
    addTearDown(oldApi.close);
    addTearDown(newApi.close);
    await tester.pumpWidget(_host(oldApi));

    await tester.tap(find.byTooltip('選擇基準分支'));
    await tester.pump();
    expect(find.text('選擇基準分支'), findsOneWidget);

    await tester.pumpWidget(
      _host(newApi, account: _account(newApi, id: 8, username: 'new-user')),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('選擇基準分支'), findsNothing);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('compare-from')))
          .controller!
          .text,
      'main',
    );

    branches.complete(
      jsonResponse([
        {'name': 'old-branch'},
      ]),
    );
    await settleNetworkWidgets(tester);
    expect(find.text('old-branch'), findsNothing);
    expect(newAdapter.requests, isEmpty);
  });

  testWidgets('large commit and file collections stay lazily built', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (request) => jsonResponse(
        _response(
          commits: [for (var i = 0; i < 800; i++) _commit(i)],
          diffs: [for (var i = 0; i < 800; i++) _diff(i)],
        ),
      ),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api));
    await _compare(tester);

    expect(find.byKey(const ValueKey('compare-commit-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('compare-commit-799')), findsNothing);

    await tester.tap(find.text('檔案'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('compare-file-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('compare-file-799')), findsNothing);
  });

  testWidgets('file rows preserve rename and capability metadata', (
    tester,
  ) async {
    final renamed = {
      ..._diff(1),
      'old_path': 'lib/old.dart',
      'new_path': 'lib/new.dart',
      'renamed_file': true,
      'collapsed': true,
    };
    final adapter = FakeAdapter(
      (request) => jsonResponse(_response(diffs: [renamed])),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api));
    await _compare(tester);
    await tester.tap(find.text('檔案'));
    await tester.pumpAndSettle();

    expect(find.text('lib/old.dart → lib/new.dart'), findsOneWidget);
    expect(find.text('重新命名 · GitLab 已折疊'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('compare-file-0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('回應未包含可顯示內容'), findsOneWidget);
  });

  testWidgets('tapped file parses validated hunks and shows line numbers', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (request) => jsonResponse(
        _response(
          diffs: [
            _diff(
              1,
              diff:
                  '--- a/lib/core/workspace_api.dart\n'
                  '+++ b/lib/core/workspace_api.dart\n'
                  '@@ -8,2 +8,2 @@\n'
                  ' context\n'
                  '-old\n'
                  '+new',
            ),
          ],
        ),
      ),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api));
    await _compare(tester);
    await tester.tap(find.text('檔案'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('compare-file-0')));
    await settleNetworkWidgets(tester);

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('compare-old-4'))).data,
      '9',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('compare-new-5'))).data,
      '9',
    );
    expect(find.text('old'), findsOneWidget);
    expect(find.text('new'), findsOneWidget);
    expect(find.text('--- a/lib/core/workspace_api.dart'), findsOneWidget);
    expect(find.text('+++ b/lib/core/workspace_api.dart'), findsOneWidget);
  });

  testWidgets(
    'large single diff line parses off-thread and is capped for layout',
    (tester) async {
      final longLine = List.filled(5000, 'x').join();
      final adapter = FakeAdapter(
        (request) => jsonResponse(
          _response(diffs: [_diff(1, diff: '@@ -1 +1 @@\n-$longLine\n+new')]),
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(_host(api));
      await _compare(tester);
      await tester.tap(find.text('檔案'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('compare-file-0')));
      await tester.pump();

      await settleNetworkWidgets(tester);
      expect(
        find.byKey(const ValueKey('compare-line-truncated-notice')),
        findsOneWidget,
      );
      final displayed = tester
          .widget<Text>(find.byKey(const ValueKey('compare-text-1')))
          .data!;
      expect(displayed.length, 2001);
      expect(displayed.endsWith('…'), isTrue);
    },
  );

  testWidgets('malformed hunk is an invalid response', (tester) async {
    final adapter = FakeAdapter(
      (request) => jsonResponse(
        _response(diffs: [_diff(1, diff: '@@ -1 +1 @@\n+only-add')]),
      ),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(_host(api));
    await _compare(tester);
    await tester.tap(find.text('檔案'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('compare-file-0')));
    await settleNetworkWidgets(tester);

    expect(find.text('無法讀取回應'), findsOneWidget);
  });

  for (final width in [320.0, 412.0]) {
    testWidgets('controls fit ${width.toInt()}dp with large text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = Size(width * 2, 900 * 2);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final adapter = FakeAdapter((request) => jsonResponse(_response()));
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(_host(api, textScale: 1.8));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('compare-from')), findsOneWidget);
      expect(find.byKey(const Key('compare-to')), findsOneWidget);
      expect(find.byKey(const Key('compare-submit')), findsOneWidget);
      await _compare(tester);
      await tester.tap(find.text('檔案'));
      await tester.pumpAndSettle();
      expect(find.textContaining('可能是二進位'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
