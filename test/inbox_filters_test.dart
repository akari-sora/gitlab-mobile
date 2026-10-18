import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/inbox_page.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;

Json _todo(int id, String title, {required String action, required String type}) => {
  'id': id, 'action_name': action, 'target_type': type, 'state': 'pending',
  'target': {'iid': id, 'title': title}, 'project': {'id': 10, 'path_with_namespace': 'team/core'},
  'author': {'username': 'lead'}, 'updated_at': '2026-09-20T10:00:00Z',
};

void main() {
  testWidgets('filters ask GitLab for one kind of todo and can always be left', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 860);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final todos = [
      _todo(1, 'Review the parser', action: 'review_requested', type: 'MergeRequest'),
      _todo(2, 'Crash on start', action: 'assigned', type: 'Issue'),
    ];
    final queries = <Map<String, String>>[];
    final api = testApi(FakeAdapter((request) {
      if (request.uri.path.endsWith('/todos') && request.method == 'GET') {
        final query = request.uri.queryParameters;
        queries.add(Map.of(query)..remove('per_page'));
        return jsonResponse([
          for (final todo in todos)
            if ((query['action'] == null || query['action'] == todo['action_name']) &&
                (query['type'] == null || query['type'] == todo['target_type'])) todo,
        ]);
      }
      return jsonResponse(<Object>[]);
    }));
    addTearDown(api.close);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(InboxPage(account: fixture.account, api: api)));
    await settleNetworkWidgets(tester);
    expect(find.text('Review the parser'), findsOneWidget);
    expect(find.text('Crash on start'), findsOneWidget);
    expect(find.byKey(const ValueKey('todos-mark-all-done')), findsOneWidget);

    // The chip row scrolls sideways; bring each chip into view first.
    Future<void> pick(String filter) async {
      final chip = find.byKey(ValueKey('todo-filter-$filter'));
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
    }

    await pick('review');
    await settleNetworkWidgets(tester);
    expect(queries.last, {'state': 'pending', 'action': 'review_requested'});
    expect(find.text('Review the parser'), findsOneWidget);
    expect(find.text('Crash on start'), findsNothing);
    expect(find.byKey(const ValueKey('todos-mark-all-done')), findsNothing,
      reason: '全部完成 marks every todo, so it is not offered on a filtered list');

    await pick('mergeRequests');
    await settleNetworkWidgets(tester);
    expect(queries.last, {'state': 'pending', 'type': 'MergeRequest'});

    await pick('failed');
    await settleNetworkWidgets(tester);
    expect(queries.last, {'state': 'pending', 'action': 'build_failed'});
    expect(find.text('沒有「Pipeline 失敗」的待辦'), findsOneWidget);
    expect(find.text('全部處理完畢！'), findsNothing, reason: 'an empty filter is not an empty inbox');

    await pick('all');
    await settleNetworkWidgets(tester);
    expect(queries.last, {'state': 'pending'});
    expect(find.text('Crash on start'), findsOneWidget);
    expect(find.byKey(const ValueKey('todos-mark-all-done')), findsOneWidget);
  });
}
