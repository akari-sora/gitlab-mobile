import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/inbox_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

void main() {
  final instance = GitLabInstance.parse('https://example.com/gitlab');
  final account = Account(
    instance: instance,
    user: const GitLabUser(id: 7, username: 'tester', name: 'Tester'),
    token: 'synthetic-test-token',
  );

  testWidgets('inbox renders tabs and displays empty state for empty todos', (
    tester,
  ) async {
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/todos')) {
        return jsonResponse([]);
      }
      return jsonResponse([]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: InboxPage(account: account, api: api),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('收件匣'), findsOneWidget);
    expect(find.text('待辦'), findsOneWidget);
    expect(find.text('指派給我'), findsOneWidget);
    expect(find.text('待我審查'), findsOneWidget);
    expect(find.text('全部處理完畢！'), findsOneWidget);
  });

  testWidgets('inbox displays todos and allows marking todo as done', (
    tester,
  ) async {
    var markedDone = false;
    final todos = [
      {
        'id': 101,
        'target_type': 'Issue',
        'target': {'id': 501, 'iid': 42, 'title': 'Fix login timeout bug'},
        'project': {'id': 10, 'path_with_namespace': 'team/core'},
        'state': 'pending',
      },
    ];

    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/todos') && request.method == 'GET') {
        return jsonResponse(markedDone ? [] : todos);
      }
      if (path.endsWith('/todos/101/mark_as_done') &&
          request.method == 'POST') {
        markedDone = true;
        return jsonResponse({'id': 101, 'state': 'done'});
      }
      return jsonResponse([]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: InboxPage(account: account, api: api),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('Fix login timeout bug'), findsOneWidget);
    expect(find.text('team/core'), findsOneWidget);

    final doneButton = find.byTooltip('完成此待辦');
    expect(doneButton, findsOneWidget);
    await tester.tap(doneButton);
    await settleNetworkWidgets(tester);

    expect(markedDone, isTrue);
    expect(find.text('Fix login timeout bug'), findsNothing);
    expect(find.text('全部處理完畢！'), findsOneWidget);
  });

  testWidgets('inbox switches to assigned-to-me tab and renders issues', (
    tester,
  ) async {
    final issues = [
      {
        'id': 201,
        'iid': 15,
        'project_id': 10,
        'title': 'Assigned feature issue',
        'updated_at': '2026-09-20T10:00:00Z',
      },
    ];

    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/todos')) {
        return jsonResponse([]);
      }
      if (request.uri.path.endsWith('/issues')) {
        expect(request.uri.queryParameters['scope'], 'assigned_to_me');
        return jsonResponse(issues);
      }
      return jsonResponse([]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: InboxPage(account: account, api: api),
      ),
    );
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('指派給我'));
    await settleNetworkWidgets(tester);

    expect(find.text('Assigned feature issue'), findsOneWidget);
    expect(find.textContaining('#15'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(EntityCard),
        matching: find.byWidgetPredicate((widget) => widget is Text && widget.data == ''),
      ),
      findsNothing,
    );
    final height = tester.getSize(find.byType(EntityCard)).height;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ListView(children: [
        Builder(builder: (context) => workItemCard(
          context, Map<String, dynamic>.from(issues.single), mr: false, onTap: () {})),
      ])),
    ));
    await tester.pump();
    expect(tester.getSize(find.byType(EntityCard)).height, height);
  });

  testWidgets(
    'inbox switches to review-requests tab and renders merge requests',
    (tester) async {
      final mrs = [
        {
          'id': 301,
          'iid': 88,
          'project_id': 10,
          'title': 'Review requested MR',
          'updated_at': '2026-09-20T11:00:00Z',
        },
      ];

      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/todos')) {
          return jsonResponse([]);
        }
        if (request.uri.path.endsWith('/merge_requests')) {
          expect(request.uri.queryParameters['reviewer_id'], '7');
          return jsonResponse(mrs);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: InboxPage(account: account, api: api),
        ),
      );
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('待我審查'));
      await settleNetworkWidgets(tester);

      expect(find.text('Review requested MR'), findsOneWidget);
      expect(find.textContaining('!88'), findsOneWidget);
    },
  );

  testWidgets('tapping todo navigates to WorkItemPage', (tester) async {
    final todos = [
      {
        'id': 102,
        'target_type': 'MergeRequest',
        'target': {'id': 601, 'iid': 22, 'title': 'Implement new flow'},
        'project': {'id': 10, 'path_with_namespace': 'team/core'},
        'state': 'pending',
      },
    ];
    final project = {
      'id': 10,
      'name': 'Core',
      'path': 'core',
      'path_with_namespace': 'team/core',
      'description': 'Main repo',
      'visibility': 'private',
      'default_branch': 'main',
      'archived': false,
      'last_activity_at': '2026-09-20T12:00:00Z',
    };
    final mrDetail = {
      'id': 601,
      'iid': 22,
      'title': 'Implement new flow',
      'description': 'MR description',
      'state': 'opened',
      'source_branch': 'feat/flow',
      'target_branch': 'main',
      'sha': '1111222233334444555566667777888899990000',
      'author': {'id': 7, 'username': 'tester'},
    };

    final adapter = FakeAdapter((request) {
      final path = request.uri.path;
      if (path.endsWith('/todos')) return jsonResponse(todos);
      if (path.endsWith('/projects/10')) return jsonResponse(project);
      if (path.endsWith('/projects/10/merge_requests/22')) {
        return jsonResponse(mrDetail);
      }
      if (path.endsWith('/projects/10/merge_requests/22/discussions')) {
        return jsonResponse([]);
      }
      if (path.endsWith('/projects/10/merge_requests/22/approvals')) {
        return jsonResponse({'approved_by': <dynamic>[]});
      }
      return jsonResponse([]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: InboxPage(account: account, api: api),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('Implement new flow'), findsOneWidget);
    await tester.tap(find.text('Implement new flow'));
    await settleNetworkWidgets(tester);

    expect(find.text('feat/flow → main'), findsOneWidget);
  });
}
