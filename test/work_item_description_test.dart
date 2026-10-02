import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _project = Project(id: 42, name: 'Example', path: 'team/example');

Account _account(GitLabApi api) => Account(
  instance: api.instance,
  user: const GitLabUser(id: 7, username: 'reader', name: 'Reader'),
  token: 'synthetic-token',
);

ResponseBody _detailResponse(String description) => jsonResponse({
  'data': {
    'project': {
      'id': 'gid://gitlab/Project/42',
      'fullPath': 'team/example',
      'workItems': {
        'nodes': [
          {
            'id': 'gid://gitlab/WorkItem/7',
            'iid': '7',
            'title': 'Long description item',
            'state': 'OPEN',
            'createdAt': '2026-09-01T01:02:03Z',
            'updatedAt': '2026-09-02T03:04:05Z',
            'project': {
              'id': 'gid://gitlab/Project/42',
              'fullPath': 'team/example',
            },
            'namespace': {
              'id': 'gid://gitlab/Namespaces::ProjectNamespace/42',
              'fullPath': 'team/example',
            },
            'workItemType': {
              'id': 'gid://gitlab/WorkItems::Type/99',
              'name': 'Custom type',
            },
            'description': description,
            'widgets': [
              {
                'type': 'DESCRIPTION',
                'description': description,
                'edited': false,
                'lastEditedAt': null,
              },
              {'type': 'STATUS'},
            ],
          },
        ],
        'pageInfo': {'hasNextPage': false, 'endCursor': null},
      },
    },
  },
});

ResponseBody _stateResponse() => jsonResponse({
  'data': {
    'workItem': {
      'id': 'gid://gitlab/WorkItem/7',
      'iid': '7',
      'state': 'OPEN',
      'updatedAt': '2026-09-02T03:04:05Z',
      'project': {'id': 'gid://gitlab/Project/42', 'fullPath': 'team/example'},
      'namespace': {
        'id': 'gid://gitlab/Namespaces::ProjectNamespace/42',
        'fullPath': 'team/example',
      },
      'workItemType': {'id': 'gid://gitlab/WorkItems::Type/99'},
      'userPermissions': {'updateWorkItem': false},
    },
  },
});

ResponseBody _response(RequestOptions request, String description) {
  final query = (request.data as Map)['query'] as String;
  return query.contains('MobileWorkItemState')
      ? _stateResponse()
      : _detailResponse(description);
}

Widget _host(Account account, GitLabApi api) => MaterialApp(
  home: GraphWorkItemDetailPage.project(
    account: account,
    api: api,
    project: _project,
    iid: 7,
  ),
);

void main() {
  testWidgets(
    'long description stays collapsed until requested and resets on refresh',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final description = 'Preview ${List.filled(900, 'x').join()} END_MARKER';
      final adapter = FakeAdapter((request) => _response(request, description));
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(_host(_account(api), api));
      await settleNetworkWidgets(tester);

      expect(find.byType(MarkdownView), findsNothing);
      expect(
        find.textContaining('${description.runes.length} 字元'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('work-item-attributes')),
        findsOneWidget,
      );
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('work-item-attributes')))
            .dy,
        lessThan(844),
      );
      expect(adapter.requests.length, 2, reason: 'collapsed panels stay lazy');

      await tester.tap(find.text('說明'));
      await settleNetworkWidgets(tester);
      expect(find.byType(MarkdownView), findsOneWidget);

      await tester.tap(find.byTooltip('重新整理'));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownView), findsNothing);
      expect(adapter.requests.length, 4);
    },
  );

  testWidgets('short description remains open at 320dp with large text', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 840);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final adapter = FakeAdapter(
      (request) => _response(request, 'Short **Markdown** body'),
    );
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: GraphWorkItemDetailPage.project(
          account: _account(api),
          api: api,
          project: _project,
          iid: 7,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.byType(MarkdownView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('expanded long description survives ListView eviction', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 300);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final description = List.generate(
      180,
      (index) =>
          'Paragraph $index with enough words to wrap on a phone viewport.',
    ).join('\n\n');
    final api = testApi(
      FakeAdapter((request) => _response(request, description)),
    );
    addTearDown(api.close);

    await tester.pumpWidget(_host(_account(api), api));
    await settleNetworkWidgets(tester);
    expect(find.byType(MarkdownView), findsNothing);
    await tester.tap(find.text('說明'));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownView), findsOneWidget);

    final scrollable = find.descendant(
      of: find.byType(ListView),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
    position.jumpTo(0);
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
