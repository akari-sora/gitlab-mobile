// C3b §6.1 / §8.3: the online repository screens show the same rows and send
// the same requests before and after CodeTextView and the offline entry points
// were added. Written against the pre-refactor code first.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/offline/offline_repository_coordinator.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/features/offline/offline_repositories.dart';
import 'package:gitlab_mobile/features/offline/offline_status.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'offline/coordinator_regression_test.dart' as fixture;
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  final instance = GitLabInstance.parse('https://example.com/gitlab');
  final account = Account(
    instance: instance,
    user: const GitLabUser(id: 7, username: 'coder', name: 'Coder'),
    token: 'synthetic-token',
  );
  final project = Project.fromJson({
    'id': 42,
    'name': 'Project',
    'path': 'project',
    'path_with_namespace': 'group/project',
    'description': '',
    'visibility': 'private',
    'default_branch': 'main',
    'archived': false,
    'last_activity_at': '2026-09-20T10:00:00Z',
  });

  String describe(RequestOptions r) =>
      '${r.method} ${r.uri.path.replaceFirst('/gitlab/api/v4/', '')}'
      '${r.uri.queryParameters.isEmpty ? '' : '?${(r.uri.queryParameters.entries.toList()..sort((a, b) => a.key.compareTo(b.key))).map((e) => '${e.key}=${e.value}').join('&')}'}';

  testWidgets('online file page: requests, lines, search and wrap', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (request) => request.method == 'HEAD'
          ? ResponseBody.fromString(
              '',
              200,
              headers: {
                'x-gitlab-size': ['40'],
                'x-gitlab-last-commit-id': [_sha],
              },
            )
          : ResponseBody.fromString('alpha line\nbeta line\ngamma\n', 200),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: RepositoryFilePage(
          account: account,
          api: api,
          project: project,
          branch: 'main',
          sha: _sha,
          filePath: 'src/main.txt',
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    // Metadata for the writable branch, then the text (which checks its size
    // with its own HEAD first).
    expect(adapter.requests.map(describe).toList(), [
      'HEAD projects/42/repository/files/src%2Fmain.txt?ref=$_sha',
      'HEAD projects/42/repository/files/src%2Fmain.txt?ref=$_sha',
      'GET projects/42/repository/files/src%2Fmain.txt/raw?lfs=false&ref=$_sha',
    ]);
    for (var line = 1; line <= 4; line++) {
      expect(find.byKey(ValueKey('repository-file-line-$line')), findsOneWidget);
    }
    expect(find.text('alpha line'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'beta');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('repository-file-line-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('repository-file-line-1')), findsNothing);
    await tester.tap(find.byTooltip('檔案操作'));
    await tester.pumpAndSettle();
    expect(find.text('關閉自動換行'), findsOneWidget);
    await tester.tap(find.text('關閉自動換行'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('repository-file-line-2')), findsOneWidget);
    // Nothing else was requested by the search, the menu or the wrap toggle.
    expect(adapter.requests, hasLength(3));
  });

  Finder offlineButton() => find.byWidgetPredicate(
    (widget) =>
        widget.key is ValueKey<String> &&
        (widget.key! as ValueKey<String>).value.startsWith(
          'repository-offline-button',
        ),
  );

  FakeAdapter tabAdapter() => FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/repository/branches/main')) {
        return jsonResponse({
          'name': 'main',
          'protected': false,
          'default': true,
          'developers_can_push': false,
          'can_push': false,
          'commit': {'id': _sha, 'title': 'init'},
        });
      }
      if (path.endsWith('/repository/tree')) {
        return jsonResponse([
          {'id': '1' * 40, 'name': 'docs', 'type': 'tree', 'path': 'docs', 'mode': '040000'},
          {'id': '2' * 40, 'name': 'main.txt', 'type': 'blob', 'path': 'main.txt', 'mode': '100644'},
        ]);
      }
      return jsonResponse({}, status: 404);
    });

  const expected = [
    'GET projects/42/repository/branches/main',
    'GET projects/42/repository/tree?path=&per_page=50&ref=$_sha',
  ];

  testWidgets('online repository tab: requests and rows', (tester) async {
    final adapter = tabAdapter();
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepositoryTab(account: account, api: api, project: project),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(adapter.requests.map(describe).toList(), expected);
    expect(find.text('docs'), findsOneWidget);
    expect(find.text('main.txt'), findsOneWidget);
    // No offline entry exists without an offline scope.
    expect(offlineButton(), findsNothing);
  });

  testWidgets('the offline entry adds no request to the online tab', (
    tester,
  ) async {
    final adapter = tabAdapter();
    final api = testApi(adapter);
    addTearDown(api.close);
    final owner = OfflineRepositoryCoordinator()
      ..configure(
        keys: fixture.MemoryKeys()..value = null,
        supportRoot: () async => Directory.systemTemp,
        deleteDirectory: (_) async {},
      );
    late OfflineRepositories repositories;
    await tester.runAsync(() async {
      repositories = OfflineRepositories(
        binding: DiskBinding(accountKey: account.key, generation: 1),
        coordinator: owner,
        api: api,
      );
      await repositories.refresh();
    });
    addTearDown(repositories.dispose);
    await tester.pumpWidget(
      OfflineScope(
        repositories: repositories,
        account: account,
        child: MaterialApp(
          home: Scaffold(
            body: RepositoryTab(account: account, api: api, project: project),
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(adapter.requests.map(describe).toList(), expected);
    expect(
      find.byKey(const ValueKey('repository-offline-button-none')),
      findsOneWidget,
    );
  });
}
