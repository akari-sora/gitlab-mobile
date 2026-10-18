import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/inbox_page.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;

Map<String, Object?> _body(RequestOptions request) => (request.data as Map).cast<String, Object?>();
Map<String, Object?> _variables(RequestOptions request) =>
    (_body(request)['variables']! as Map).cast<String, Object?>();
bool _graph(RequestOptions request) => request.uri.path == '/gitlab/api/graphql';

Json _restTodo(int id, String title) => {
  'id': id, 'action_name': 'assigned', 'target_type': 'Issue', 'state': 'pending',
  'target': {'iid': id, 'title': title}, 'project': {'id': 10, 'path_with_namespace': 'team/core'},
  'author': {'username': 'lead'}, 'updated_at': '2026-09-20T10:00:00Z',
};

Map<String, Object?> _snoozedNode(int id, String title, String until) => {
  'id': 'gid://gitlab/Todo/$id', 'action': 'review_requested', 'body': title, 'createdAt': '2026-09-20T10:00:00Z',
  'snoozedUntil': until, 'targetType': 'MERGEREQUEST', 'targetUrl': 'https://example.com/gitlab/team/core/-/merge_requests/$id',
  'author': {'username': 'lead'}, 'project': {'id': 'gid://gitlab/Project/10', 'fullPath': 'team/core'},
  'targetEntity': {'iid': '$id', 'title': title},
};

void main() {
  group('api', () {
    test('snoozing sends the todo and time and returns what GitLab acknowledged', () async {
      late RequestOptions sent;
      final api = testApi(FakeAdapter((request) {
        sent = request;
        return jsonResponse({'data': {'todoSnooze': {
          'todo': {'id': 'gid://gitlab/Todo/7', 'snoozedUntil': '2030-01-02T09:00:00Z'}, 'errors': <Object>[]}}});
      }));
      addTearDown(api.close);
      final until = DateTime.utc(2030, 1, 2, 9);
      expect(await api.snoozeTodo(7, until), DateTime.utc(2030, 1, 2, 9));
      expect(_graph(sent), isTrue);
      expect(sent.method, 'POST');
      expect(_body(sent)['query'], contains('todoSnooze'));
      expect(_variables(sent), {'id': 'gid://gitlab/Todo/7', 'until': '2030-01-02T09:00:00.000Z'});
    });

    test('a refusal, another todo or an old GitLab fail clearly', () async {
      var reply = <String, Object?>{};
      final api = testApi(FakeAdapter((_) => jsonResponse(reply)));
      addTearDown(api.close);
      final later = DateTime.now().add(const Duration(hours: 1));

      reply = {'data': {'todoSnooze': {'todo': null, 'errors': ['Not allowed']}}};
      await expectLater(api.snoozeTodo(7, later),
        throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.validation)));

      reply = {'data': {'todoSnooze': {'todo': {'id': 'gid://gitlab/Todo/8', 'snoozedUntil': '2030-01-01T00:00:00Z'}, 'errors': <Object>[]}}};
      await expectLater(api.snoozeTodo(7, later),
        throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.invalidResponse)));

      reply = {'errors': [{'message': "Field 'todoSnooze' doesn't exist on type 'Mutation'", 'extensions': {'code': 'undefinedField'}}]};
      await expectLater(api.snoozeTodo(7, later),
        throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.unsupported)));

      await expectLater(api.snoozeTodo(7, DateTime.now().subtract(const Duration(minutes: 1))),
        throwsA(isA<ApiFailure>().having((f) => f.kind, 'kind', FailureKind.validation)), reason: 'a past time');
    });

    test('unsnoozing checks the todo came back', () async {
      Object? until;
      final api = testApi(FakeAdapter((_) => jsonResponse({'data': {'todoUnSnooze': {
        'todo': {'id': 'gid://gitlab/Todo/7', 'snoozedUntil': until}, 'errors': <Object>[]}}})));
      addTearDown(api.close);
      await api.unsnoozeTodo(7);
      until = '2030-01-01T00:00:00Z';
      await expectLater(api.unsnoozeTodo(7), throwsA(isA<ApiFailure>()));
    });

    test('snoozed todos come back in the REST shape the inbox renders', () async {
      final api = testApi(FakeAdapter((request) => jsonResponse({'data': {'currentUser': {'todos': {
        'pageInfo': {'hasNextPage': false},
        'nodes': [_snoozedNode(31, 'Review the parser', '2030-01-02T09:00:00Z')],
      }}}})));
      addTearDown(api.close);
      final page = await api.snoozedTodos();
      expect(page.truncated, isFalse);
      expect(page.items.single, {
        'id': 31, 'action_name': 'review_requested', 'target_type': 'MergeRequest',
        'target_url': 'https://example.com/gitlab/team/core/-/merge_requests/31', 'body': 'Review the parser',
        'created_at': '2026-09-20T10:00:00Z', 'updated_at': '2026-09-20T10:00:00Z',
        'snoozed_until': '2030-01-02T09:00:00Z', 'author': {'username': 'lead'},
        'project': {'id': 10, 'path_with_namespace': 'team/core'},
        'target': {'iid': 31, 'title': 'Review the parser'},
      });
    });
  });

  test('presets land in the future at the times they name', () {
    final wednesday = DateTime(2026, 10, 21, 22, 30);
    final presets = {for (final (label, at) in todoSnoozePresets(wednesday)) label: at};
    expect(presets['1 小時後'], DateTime(2026, 10, 21, 23, 30));
    expect(presets['明天上午 9:00'], DateTime(2026, 10, 22, 9));
    expect(presets['下週一上午 9:00'], DateTime(2026, 10, 26, 9));
    final monday = DateTime(2026, 10, 26, 8);
    expect({for (final (label, at) in todoSnoozePresets(monday)) label: at}['下週一上午 9:00'], DateTime(2026, 11, 2, 9),
      reason: 'on a Monday it is the following one');
    expect(todoUntilLabel(DateTime(2026, 10, 21, 23, 5), wednesday), '今天 23:05');
    expect(todoUntilLabel(DateTime(2026, 10, 22, 9), wednesday), '明天 09:00');
    expect(todoUntilLabel(DateTime(2026, 10, 26, 9), wednesday), '10/26 09:00');
  });

  testWidgets('a todo snoozes from its row, can be undone, and the 已延後 list brings one back', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(412, 860);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final pending = [_restTodo(1, 'Crash on start')];
    final snoozed = <Map<String, Object?>>[_snoozedNode(31, 'Review the parser', '2030-01-02T09:00:00Z')];
    final mutations = <(String, Map<String, Object?>)>[];
    final api = testApi(FakeAdapter((request) {
      if (_graph(request)) {
        final query = _body(request)['query']! as String;
        if (query.contains('todoSnooze')) {
          mutations.add(('snooze', _variables(request)));
          pending.clear();
          return jsonResponse({'data': {'todoSnooze': {
            'todo': {'id': _variables(request)['id'], 'snoozedUntil': _variables(request)['until']}, 'errors': <Object>[]}}});
        }
        if (query.contains('todoUnSnooze')) {
          mutations.add(('unsnooze', _variables(request)));
          if (_variables(request)['id'] == 'gid://gitlab/Todo/1') pending.add(_restTodo(1, 'Crash on start'));
          snoozed.removeWhere((node) => node['id'] == _variables(request)['id']);
          return jsonResponse({'data': {'todoUnSnooze': {
            'todo': {'id': _variables(request)['id'], 'snoozedUntil': null}, 'errors': <Object>[]}}});
        }
        return jsonResponse({'data': {'currentUser': {'todos': {'pageInfo': {'hasNextPage': false}, 'nodes': snoozed}}}});
      }
      if (request.uri.path.endsWith('/todos')) return jsonResponse(pending);
      return jsonResponse(<Object>[]);
    }));
    addTearDown(api.close);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(InboxPage(account: fixture.account, api: api)));
    await settleNetworkWidgets(tester);
    expect(find.text('Crash on start'), findsOneWidget);

    final before = DateTime.now();
    await tester.tap(find.byTooltip('延後此待辦'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('todo-snooze-1 小時後')));
    await settleNetworkWidgets(tester);
    expect(mutations.single.$1, 'snooze');
    expect(mutations.single.$2['id'], 'gid://gitlab/Todo/1');
    final until = DateTime.parse(mutations.single.$2['until']! as String);
    expect(until.difference(before).inMinutes, inInclusiveRange(59, 61));
    expect(find.text('Crash on start'), findsNothing);
    expect(find.textContaining('已延後至'), findsOneWidget);

    await tester.tap(find.text('復原'));
    await settleNetworkWidgets(tester);
    expect(mutations.last.$1, 'unsnooze');
    expect(mutations.last.$2['id'], 'gid://gitlab/Todo/1');
    expect(find.text('Crash on start'), findsOneWidget, reason: '復原 brings it back');

    final chip = find.byKey(const ValueKey('todo-filter-snoozed'));
    await tester.ensureVisible(chip);
    await tester.pumpAndSettle();
    await tester.tap(chip);
    await settleNetworkWidgets(tester);
    expect(find.text('Review the parser'), findsOneWidget);
    expect(find.textContaining('延後至'), findsOneWidget);
    expect(find.byTooltip('延後此待辦'), findsNothing);
    await tester.tap(find.byTooltip('取消延後'));
    await settleNetworkWidgets(tester);
    expect(mutations.last.$1, 'unsnooze');
    expect(mutations.last.$2['id'], 'gid://gitlab/Todo/31');
    expect(find.text('Review the parser'), findsNothing);
    expect(find.text('已移回收件匣'), findsOneWidget);
  });
}
