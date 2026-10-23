import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/boards_page.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show workspaceHost;

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

Account _account(GitLabApi api) => Account(
  instance: api.instance,
  user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
  token: 'synthetic-test-token',
);

const _project = Project(
  id: 42,
  name: 'Mobile',
  path: 'studio/mobile',
  visibility: 'private',
  defaultBranch: 'main',
);

int _endpointCount(FakeAdapter adapter, String suffix) => adapter.requests
    .where((request) => request.uri.path.endsWith(suffix))
    .length;

void main() {
  testWidgets(
    'board toolbar refresh within 20s fetches each warm column once and shows new issues; plain reopen within 60s adds zero issue GETs',
    (tester) async {
      var now = DateTime.utc(2026, 10, 23, 8);
      final board = {
        'id': 1,
        'name': 'Delivery',
        'hide_backlog_list': false,
        'hide_closed_list': false,
      };
      final issues = {
        for (final state in ['opened', 'closed'])
          state: {
            'id': state == 'opened' ? 1001 : 1002,
            'iid': state == 'opened' ? 1 : 2,
            'project_id': 42,
            'title': 'Original $state issue',
            'description': 'Synthetic board issue.',
            'state': state,
            'labels': <Object?>[],
            'author': {'id': 7, 'username': 'developer'},
            'assignees': <Object?>[],
            'created_at': '2026-10-01T00:00:00Z',
            'updated_at': '2026-10-02T00:00:00Z',
          },
      };
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/42/boards')) return jsonResponse([board]);
        if (path.endsWith('/projects/42/boards/1/lists')) {
          return jsonResponse([]);
        }
        if (path.endsWith('/projects/42/boards/1')) return jsonResponse(board);
        if (path.endsWith('/projects/42/issues')) {
          return jsonResponse([issues[request.uri.queryParameters['state']]!]);
        }
        return jsonResponse([]);
      });
      final api = _boundApi(adapter, clock: () => now);
      addTearDown(api.close);

      Widget host(Key key) => MaterialApp(
        home: BoardsPage(
          key: key,
          account: _account(api),
          api: api,
          project: _project,
        ),
      );

      Future<void> visitColumns(String revision) async {
        for (final column in [
          (key: 'open', state: 'opened'),
          (key: 'closed', state: 'closed'),
        ]) {
          await tester.tap(find.byKey(ValueKey('board-column-${column.key}')));
          await settleNetworkWidgets(tester);
          expect(find.text('$revision ${column.state} issue'), findsOneWidget);
        }
      }

      void expectIssueGets(int perColumn) {
        final requests = adapter.requests
            .where((request) => request.uri.path.endsWith('/projects/42/issues'))
            .toList();
        expect(requests, hasLength(2 * perColumn));
        for (final state in ['opened', 'closed']) {
          final columnRequests = requests.where(
            (request) => request.uri.queryParameters['state'] == state,
          );
          expect(columnRequests, hasLength(perColumn));
          for (final request in columnRequests) {
            expect(request.method, 'GET');
            expect(request.uri.path, '/gitlab/api/v4/projects/42/issues');
            expect(request.uri.queryParameters, {
              'per_page': '30',
              'scope': 'all',
              'state': state,
              'order_by': 'relative_position',
              'sort': 'asc',
              'with_labels_details': 'true',
            });
          }
        }
      }

      await tester.pumpWidget(host(const ValueKey('board-first-open')));
      await settleNetworkWidgets(tester);
      await visitColumns('Original');
      expectIssueGets(1);

      now = now.add(const Duration(seconds: 20));
      for (final entry in issues.entries) {
        entry.value['title'] = 'Updated ${entry.key} issue';
      }
      await tester.tap(find.byIcon(Icons.refresh));
      await settleNetworkWidgets(tester);
      await visitColumns('Updated');
      expectIssueGets(2);

      await visitColumns('Updated');
      expectIssueGets(2);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      now = now.add(const Duration(seconds: 10));

      await tester.pumpWidget(host(const ValueKey('board-reopen')));
      await settleNetworkWidgets(tester);
      await visitColumns('Updated');
      expectIssueGets(2);
    },
  );

  for (final entry in [
    (
      kind: MetadataKind.branches,
      rows: [
        {
          'name': 'main',
          'default': true,
          'protected': false,
          'commit': {
            'id': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'author_name': 'developer',
          },
        },
      ],
      title: 'main',
      suffix: '/projects/42/repository/branches',
      extra: <String, String>{},
    ),
    (
      kind: MetadataKind.tags,
      rows: [
        {
          'name': 'v1.0',
          'message': '',
          'commit': {
            'id': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'author_name': 'developer',
          },
        },
      ],
      title: 'v1.0',
      suffix: '/projects/42/repository/tags',
      extra: <String, String>{},
    ),
    (
      kind: MetadataKind.commits,
      rows: [
        {
          'id': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'title': 'Fix crash',
          'author_name': 'developer',
          'committed_date': '2026-10-01T00:00:00Z',
        },
      ],
      title: 'Fix crash',
      suffix: '/projects/42/repository/commits',
      extra: <String, String>{},
    ),
    (
      kind: MetadataKind.releases,
      rows: [
        {
          'tag_name': 'v1',
          'name': 'Release one',
          'description': 'Notes',
          'released_at': '2026-10-01T00:00:00Z',
          'author': {'id': 7, 'username': 'developer', 'name': 'Developer'},
          'assets': <String, Object?>{'links': <Object?>[]},
        },
      ],
      title: 'Release one',
      suffix: '/projects/42/releases',
      extra: <String, String>{},
    ),
    (
      kind: MetadataKind.labels,
      rows: [
        {'id': 1, 'name': 'bug', 'color': '#d9534f', 'description': ''},
      ],
      title: 'bug',
      suffix: '/projects/42/labels',
      extra: {'include_ancestor_groups': 'false'},
    ),
    (
      kind: MetadataKind.milestones,
      rows: [
        {
          'id': 101,
          'iid': 7,
          'title': 'Sprint',
          'description': '',
          'state': 'active',
          'due_date': '2026-10-01',
        },
      ],
      title: 'Sprint',
      suffix: '/projects/42/milestones',
      extra: <String, String>{},
    ),
  ]) {
    testWidgets(
      'metadata ${entry.kind.name} fixture with one row, warm fresh cache, 800x600 viewport, clock +30s: cold URI matches the first-page path and query and reopen adds zero endpoint requests',
      (tester) async {
        var now = DateTime.utc(2026, 10, 23, 8);
        final adapter = FakeAdapter((request) {
          if (request.uri.path.endsWith(entry.suffix)) {
            return jsonResponse(entry.rows);
          }
          return jsonResponse([]);
        });
        final api = _boundApi(adapter, clock: () => now);
        addTearDown(api.close);

        Widget host(Key key) => workspaceHost(
          MetadataPage(
            key: key,
            account: _account(api),
            api: api,
            project: _project,
            kind: entry.kind,
          ),
        );

        await tester.pumpWidget(host(const ValueKey('metadata-first-open')));
        await settleNetworkWidgets(tester);
        expect(find.text(entry.title), findsOneWidget);

        final first = adapter.requests
            .where((request) => request.uri.path.endsWith(entry.suffix))
            .toList();
        expect(first, hasLength(1));
        expect(first.single.method, 'GET');
        expect(first.single.uri.path, '/gitlab/api/v4${entry.suffix}');
        expect(first.single.uri.queryParameters, {
          'per_page': '30',
          ...entry.extra,
        });

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        now = now.add(const Duration(seconds: 30));

        await tester.pumpWidget(host(const ValueKey('metadata-reopen')));
        await settleNetworkWidgets(tester);
        expect(find.text(entry.title), findsOneWidget);
        expect(
          _endpointCount(adapter, entry.suffix),
          1,
          reason: 'the reopen itself must add zero ${entry.suffix} requests',
        );
      },
    );
  }

  testWidgets(
    'milestone issues fixture with one row, warm fresh cache, 800x600 viewport, clock +30s: cold work-items URI carries the milestone path and query and reopen adds zero endpoint requests',
    (tester) async {
      var now = DateTime.utc(2026, 10, 23, 8);
      final milestone = {
        'id': 101,
        'iid': 7,
        'title': 'Sprint seven',
        'description': 'Plan',
        'state': 'active',
        'due_date': '2026-10-01',
      };
      final issue = {
        'id': 1001,
        'iid': 1,
        'project_id': 42,
        'title': 'Milestone issue',
        'description': 'Synthetic milestone issue.',
        'state': 'opened',
        'author': {'id': 7, 'username': 'developer'},
        'assignees': <Object?>[],
        'labels': <Object?>[],
        'updated_at': '2026-10-23T08:00:00Z',
        'created_at': '2026-10-01T00:00:00Z',
      };
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/42/milestones/101/issues')) {
          return jsonResponse([issue]);
        }
        if (path.endsWith('/projects/42/milestones')) {
          return jsonResponse([milestone]);
        }
        return jsonResponse([]);
      });
      final api = _boundApi(adapter, clock: () => now);
      addTearDown(api.close);

      Widget host(Key key) => workspaceHost(
        MetadataPage(
          key: key,
          account: _account(api),
          api: api,
          project: _project,
          kind: MetadataKind.milestones,
        ),
      );

      Future<void> openWorkItems() async {
        await tester.tap(find.text('Sprint seven'));
        await settleNetworkWidgets(tester);
        await tester.tap(find.byKey(const ValueKey('metadata-detail-issues')));
        await settleNetworkWidgets(tester);
        expect(find.text('Milestone issue'), findsOneWidget);
      }

      await tester.pumpWidget(host(const ValueKey('milestone-first-open')));
      await settleNetworkWidgets(tester);
      await openWorkItems();

      final first = adapter.requests
          .where(
            (request) => request.uri.path.endsWith(
              '/projects/42/milestones/101/issues',
            ),
          )
          .toList();
      expect(first, hasLength(1));
      expect(first.single.method, 'GET');
      expect(
        first.single.uri.path,
        '/gitlab/api/v4/projects/42/milestones/101/issues',
      );
      expect(first.single.uri.queryParameters, {
        'per_page': '30',
        'with_labels_details': 'true',
      });

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      now = now.add(const Duration(seconds: 30));

      await tester.pumpWidget(host(const ValueKey('milestone-reopen')));
      await settleNetworkWidgets(tester);
      await openWorkItems();
      expect(
        _endpointCount(adapter, '/projects/42/milestones/101/issues'),
        1,
        reason:
            'the reopen itself must add zero GET projects/42/milestones/101/issues requests',
      );
    },
  );

  testWidgets(
    'label issues fixture with one row, warm fresh cache, 800x600 viewport, clock +30s: cold work-items URI carries the label query and reopen adds zero GET projects/42/issues requests',
    (tester) async {
      var now = DateTime.utc(2026, 10, 23, 8);
      final label = {'id': 1, 'name': 'bug', 'color': '#d9534f', 'description': ''};
      final issue = {
        'id': 1001,
        'iid': 1,
        'project_id': 42,
        'title': 'Labeled issue',
        'description': 'Synthetic labeled issue.',
        'state': 'opened',
        'author': {'id': 7, 'username': 'developer'},
        'assignees': <Object?>[],
        'labels': ['bug'],
        'updated_at': '2026-10-23T08:00:00Z',
        'created_at': '2026-10-01T00:00:00Z',
      };
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/projects/42/issues')) {
          return jsonResponse([issue]);
        }
        if (path.endsWith('/projects/42/labels')) {
          return jsonResponse([label]);
        }
        return jsonResponse([]);
      });
      final api = _boundApi(adapter, clock: () => now);
      addTearDown(api.close);

      Widget host(Key key) => workspaceHost(
        MetadataPage(
          key: key,
          account: _account(api),
          api: api,
          project: _project,
          kind: MetadataKind.labels,
        ),
      );

      Future<void> openWorkItems() async {
        await tester.tap(find.text('bug'));
        await settleNetworkWidgets(tester);
        await tester.tap(find.byKey(const ValueKey('metadata-detail-issues')));
        await settleNetworkWidgets(tester);
        expect(find.text('Labeled issue'), findsOneWidget);
      }

      await tester.pumpWidget(host(const ValueKey('label-first-open')));
      await settleNetworkWidgets(tester);
      await openWorkItems();

      final first = adapter.requests
          .where((request) => request.uri.path.endsWith('/projects/42/issues'))
          .toList();
      expect(first, hasLength(1));
      expect(first.single.method, 'GET');
      expect(first.single.uri.path, '/gitlab/api/v4/projects/42/issues');
      expect(first.single.uri.queryParameters, {
        'per_page': '30',
        'labels': 'bug',
        'state': 'opened',
        'with_labels_details': 'true',
      });
      final firstCount = first.length;

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      now = now.add(const Duration(seconds: 30));

      await tester.pumpWidget(host(const ValueKey('label-reopen')));
      await settleNetworkWidgets(tester);
      await openWorkItems();
      expect(
        _endpointCount(adapter, '/projects/42/issues'),
        firstCount,
        reason: 'the reopen itself must add zero GET projects/42/issues requests',
      );
    },
  );
}
