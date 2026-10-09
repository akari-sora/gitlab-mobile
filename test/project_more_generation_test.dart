import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/registries_page.dart';
import 'support/fake_adapter.dart';
import 'workspace_widget_test.dart' show workspaceHost, settleWorkspace;

Account _account(GitLabApi api) => Account(
  instance: api.instance,
  user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
  token: 'synthetic-test-token',
);

Widget _host(GitLabApi api, int project) => workspaceHost(
  Scaffold(
    body: ProjectMoreTab(
      key: const ValueKey('same-more-state'),
      account: _account(api),
      api: api,
      project: Project.fromJson(projectJson(project)),
      onChanged: (_) {},
    ),
  ),
);

ResponseBody _overview(RequestOptions request, int id, {bool old = false}) {
  if (request.uri.path.endsWith('/starrers')) {
    return jsonResponse(
      old
          ? [
              {
                'user': {'username': 'tester'},
              },
            ]
          : [],
    );
  }
  if (request.uri.path.endsWith('/languages')) {
    return jsonResponse({old ? 'OldLanguage' : 'CurrentLanguage': 100});
  }
  return jsonResponse({
    ...projectJson(id),
    'star_count': old ? 111 : 222,
    'http_url_to_repo': 'https://example.com/${old ? 'old' : 'current'}.git',
  });
}

void main() {
  testWidgets(
    'late old project/account overview cannot replace current counts, URLs or star direction',
    (tester) async {
      final gate = Completer<void>();
      final oldAdapter = FakeAdapter((r) async {
        await gate.future;
        return _overview(r, 42, old: true);
      });
      final oldApi = testApi(oldAdapter),
          currentApi = testApi(FakeAdapter((r) => _overview(r, 43)));
      addTearDown(oldApi.close);
      addTearDown(currentApi.close);
      await tester.pumpWidget(_host(oldApi, 42));
      await tester.pump();
      await tester.pumpWidget(_host(currentApi, 43));
      await settleWorkspace(tester);
      expect(find.text('加入星標'), findsOneWidget);
      expect(find.text('222'), findsOneWidget);
      gate.complete();
      await settleWorkspace(tester);
      expect(find.text('111'), findsNothing);
      expect(find.textContaining('OldLanguage'), findsNothing);
      expect(find.text('https://example.com/old.git'), findsNothing);
      expect(find.text('加入星標'), findsOneWidget);
      expect(find.text('移除星標'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account replacement dismisses owned Fork confirmation without writing to either account',
    (tester) async {
      final oldAdapter = FakeAdapter((r) => _overview(r, 42));
      final currentAdapter = FakeAdapter((r) => _overview(r, 43));
      final oldApi = testApi(oldAdapter), currentApi = testApi(currentAdapter);
      addTearDown(oldApi.close);
      addTearDown(currentApi.close);
      await tester.pumpWidget(_host(oldApi, 42));
      await settleWorkspace(tester);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Fork'));
      await settleWorkspace(tester);
      expect(find.text('Fork 這個專案？'), findsOneWidget);
      await tester.pumpWidget(_host(currentApi, 43));
      await settleWorkspace(tester);
      expect(find.text('Fork 這個專案？'), findsNothing);
      expect(oldAdapter.requests.where((r) => r.method != 'GET'), isEmpty);
      expect(currentAdapter.requests.where((r) => r.method != 'GET'), isEmpty);
      expect(find.text('加入星標'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('replacement dismisses registry detail and its delete dialog', (
    tester,
  ) async {
    ResponseBody respond(RequestOptions r, int project) {
      if (r.uri.path.endsWith('/packages')) {
        return jsonResponse([
          {
            'id': 11,
            'name': 'old-package',
            'version': '1',
            'package_type': 'generic',
            '_links': {'delete_api_path': '/api/v4/projects/42/packages/11'},
          },
        ]);
      }
      if (r.uri.path.endsWith('/packages/11')) {
        return jsonResponse({
          'id': 11,
          'name': 'old-package',
          'version': '1',
          'package_type': 'generic',
          '_links': {'delete_api_path': '/api/v4/projects/42/packages/11'},
        });
      }
      if (r.uri.path.endsWith('/package_files')) {
        return jsonResponse(<Object>[]);
      }
      return _overview(r, project);
    }

    final oldAdapter = FakeAdapter((r) => respond(r, 42));
    final currentAdapter = FakeAdapter((r) => respond(r, 43));
    final oldApi = testApi(oldAdapter), currentApi = testApi(currentAdapter);
    addTearDown(oldApi.close);
    addTearDown(currentApi.close);
    await tester.pumpWidget(_host(oldApi, 42));
    await settleWorkspace(tester);
    await tester.scrollUntilVisible(find.text('套件與容器 Registry'), 500);
    await tester.tap(find.text('套件與容器 Registry'));
    await settleWorkspace(tester);
    await tester.tap(find.text('old-package'));
    await settleWorkspace(tester);
    expect(find.byType(PackageDetailPage), findsOneWidget);
    await tester.tap(find.byTooltip('刪除套件'));
    await settleWorkspace(tester);
    expect(find.text('刪除套件？'), findsOneWidget);
    await tester.pumpWidget(_host(currentApi, 43));
    await settleWorkspace(tester);
    expect(find.text('刪除套件？'), findsNothing);
    expect(find.byType(PackageDetailPage), findsNothing);
    expect(find.text('old-package'), findsNothing);
    expect(oldAdapter.requests.where((r) => r.method != 'GET'), isEmpty);
    expect(currentAdapter.requests.where((r) => r.method != 'GET'), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
