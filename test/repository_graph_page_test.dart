import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/commit_page.dart';
import 'package:gitlab_mobile/features/workspace/repository_graph_page.dart';

import 'support/fake_adapter.dart';

const mergeSha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const firstParent = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const secondParent = 'cccccccccccccccccccccccccccccccccccccccc';

Map<String, dynamic> graphCommit(
  String id,
  String title,
  List<String> parents,
) => {
  'id': id,
  'short_id': id.substring(0, 8),
  'title': title,
  'message': title,
  'author_name': 'Developer',
  'committed_date': '2026-10-02T08:00:00Z',
  'parent_ids': parents,
};

final account = Account(
  instance: GitLabInstance.parse('https://example.com/gitlab'),
  user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
  token: 'synthetic-test-token',
);
const project = Project(
  id: 42,
  name: 'Mobile Workspace',
  path: 'studio/mobile-workspace',
  defaultBranch: 'main',
);

Widget host(Widget child, {double width = 412, double textScale = 1}) =>
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          size: Size(width, 900),
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: child,
    );

void main() {
  testWidgets(
    'loads a bounded topological page, exposes boundary parents, paginates, and opens a commit',
    (tester) async {
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/repository/commits')) {
          if (request.uri.queryParameters['page'] == '2') {
            return jsonResponse([
              graphCommit(firstParent, 'First parent', const []),
              graphCommit(secondParent, 'Second parent', const []),
            ]);
          }
          return jsonResponse(
            [
              graphCommit(mergeSha, 'Merge commit', [
                firstParent,
                secondParent,
              ]),
            ],
            headers: {
              'x-next-page': ['2'],
            },
          );
        }
        if (request.uri.path.endsWith('/repository/commits/$mergeSha')) {
          return jsonResponse(
            graphCommit(mergeSha, 'Merge commit', [firstParent, secondParent]),
          );
        }
        if (request.uri.path.endsWith('/repository/commits/$mergeSha/diff')) {
          return jsonResponse([]);
        }
        return jsonResponse({});
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        host(RepositoryGraphPage(account: account, api: api, project: project)),
      );
      await tester.pumpAndSettle();

      final firstRequest = adapter.requests.firstWhere(
        (request) => request.uri.path.endsWith('/repository/commits'),
      );
      expect(
        firstRequest.uri.queryParameters,
        containsPair('ref_name', 'main'),
      );
      expect(firstRequest.uri.queryParameters, containsPair('order', 'topo'));
      expect(firstRequest.uri.queryParameters, containsPair('per_page', '30'));
      expect(find.textContaining('可從 main 到達的提交歷史'), findsOneWidget);
      expect(find.text('Merge commit'), findsOneWidget);
      expect(find.textContaining(firstParent.substring(0, 8)), findsOneWidget);
      expect(find.textContaining(secondParent.substring(0, 8)), findsOneWidget);
      expect(
        adapter.requests.where(
          (request) => request.uri.path.endsWith('/repository/commits'),
        ),
        hasLength(1),
      );

      await tester.tap(find.byKey(const Key('graph-load-more')));
      await tester.pumpAndSettle();
      expect(
        adapter.requests.where(
          (request) => request.uri.path.endsWith('/repository/commits'),
        ),
        hasLength(2),
      );
      expect(find.text('First parent'), findsOneWidget);
      expect(find.text('Second parent'), findsOneWidget);
      expect(find.byKey(const Key('graph-boundary')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('graph-commit-$mergeSha')));
      await tester.pumpAndSettle();
      expect(find.byType(CommitDetailPage), findsOneWidget);
    },
  );

  testWidgets(
    'tag selection and manual SHA apply issue explicit ref requests',
    (tester) async {
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/repository/tags')) {
          return jsonResponse([
            {'name': 'v1.0.0', 'target': mergeSha},
          ]);
        }
        if (request.uri.path.endsWith('/repository/commits')) {
          return jsonResponse([]);
        }
        return jsonResponse({});
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(
        host(RepositoryGraphPage(account: account, api: api, project: project)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('graph-pick-tag')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('v1.0.0'));
      await tester.pumpAndSettle();
      expect(
        adapter.requests
            .lastWhere(
              (request) => request.uri.path.endsWith('/repository/commits'),
            )
            .uri
            .queryParameters['ref_name'],
        'v1.0.0',
      );

      await tester.enterText(find.byKey(const Key('graph-ref')), mergeSha);
      await tester.tap(find.byKey(const Key('graph-load-ref')));
      await tester.pumpAndSettle();
      expect(
        adapter.requests
            .lastWhere(
              (request) => request.uri.path.endsWith('/repository/commits'),
            )
            .uri
            .queryParameters['ref_name'],
        mergeSha,
      );
    },
  );

  testWidgets('late response from replaced account API cannot become visible', (
    tester,
  ) async {
    final pending = Completer<ResponseBody>();
    final oldAdapter = FakeAdapter((request) => pending.future);
    final newAdapter = FakeAdapter(
      (request) => jsonResponse([
        graphCommit(firstParent, 'Current account commit', const []),
      ]),
    );
    final oldApi = testApi(oldAdapter);
    final newApi = testApi(newAdapter);
    addTearDown(oldApi.close);
    addTearDown(newApi.close);

    await tester.pumpWidget(
      host(
        RepositoryGraphPage(account: account, api: oldApi, project: project),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(
      host(
        RepositoryGraphPage(account: account, api: newApi, project: project),
      ),
    );
    await tester.pumpAndSettle();
    pending.complete(
      jsonResponse([graphCommit(mergeSha, 'Stale commit', const [])]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current account commit'), findsOneWidget);
    expect(find.text('Stale commit'), findsNothing);
  });

  for (final width in [320.0, 412.0, 840.0]) {
    testWidgets('graph is readable at ${width.toInt()}dp and 2x text', (
      tester,
    ) async {
      final adapter = FakeAdapter(
        (request) => jsonResponse([
          graphCommit(
            mergeSha,
            'A long commit title that wraps on narrow mobile screens',
            const [],
          ),
        ]),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(
        host(
          RepositoryGraphPage(account: account, api: api, project: project),
          width: width,
          textScale: 2,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel(
          RegExp('提交.*Merge|提交.*long', caseSensitive: false),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
