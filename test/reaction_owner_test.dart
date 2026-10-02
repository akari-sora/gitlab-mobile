import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/reactions.dart';
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'session_test.dart' show MemoryAccountStore;
import 'support/widget_settle.dart';

Widget workspaceHost(Widget child) => MaterialApp(home: child);
Future<void> settleWorkspace(WidgetTester tester) =>
    settleNetworkWidgets(tester);

void main() {
  testWidgets('session ending dismisses the picker without a reaction write', (tester) async {
    final fixture = WorkspaceFixture();
    fixture.issues[1] = fixture.issue(1, 'Synthetic');
    final session = SessionController(MemoryAccountStore())
      ..active = fixture.account ..api = fixture.api ..initializing = false;
    addTearDown(session.dispose);
    await tester.pumpWidget(ProviderScope(overrides: [sessionProvider.overrideWithValue(session)],
      child: workspaceHost(Scaffold(body: ReactionsBar(account: fixture.account,
        api: fixture.api, project: fixture.project, resource: 'issues', iid: 1)))));
    await settleWorkspace(tester);
    await tester.tap(find.byKey(const ValueKey('reaction-add')));
    await settleWorkspace(tester);
    expect(find.bySemanticsLabel('rocket'), findsOneWidget);
    await session.endSession();
    await settleWorkspace(tester);
    expect(find.bySemanticsLabel('rocket'), findsNothing);
    expect(find.byKey(const ValueKey('reaction-add')), findsNothing);
    expect(find.widgetWithText(TextButton, '重新整理'), findsNothing);
    expect(fixture.adapter.requests.where((request) => request.method != 'GET'), isEmpty);
  });

  testWidgets('closed API disables visible reaction controls', (tester) async {
    final fixture = WorkspaceFixture();
    final api = testApi(FakeAdapter((_) => jsonResponse([
      {'id': 1, 'name': 'rocket', 'user': {'id': 7}},
    ])));
    addTearDown(fixture.api.close);
    addTearDown(api.close);
    Widget host() => workspaceHost(Scaffold(body: ReactionsBar(account: fixture.account,
      api: api, project: fixture.project, resource: 'issues', iid: 1)));
    await tester.pumpWidget(host());
    await settleWorkspace(tester);
    api.close();
    await tester.pumpWidget(host());
    await settleWorkspace(tester);
    expect(tester.widget<FilterChip>(find.byKey(const ValueKey('reaction-rocket'))).onSelected, isNull);
    expect(tester.widget<ActionChip>(find.byKey(const ValueKey('reaction-add'))).onPressed, isNull);
  });

  testWidgets('old removal failure cannot affect a replacement API', (tester) async {
    final pending = Completer<ResponseBody>();
    final oldApi = testApi(FakeAdapter((request) => request.method == 'DELETE'
      ? pending.future : jsonResponse([{'id': 1, 'name': 'rocket', 'user': {'id': 7}}])));
    final newApi = testApi(FakeAdapter((_) => jsonResponse([{'id': 2, 'name': 'heart', 'user': {'id': 8}}])));
    final fixture = WorkspaceFixture();
    addTearDown(oldApi.close); addTearDown(newApi.close); addTearDown(fixture.api.close);
    Widget host(bool old) => workspaceHost(Scaffold(body: ReactionsBar(account: fixture.account,
      api: old ? oldApi : newApi, project: fixture.project, resource: 'issues', iid: 1)));
    await tester.pumpWidget(host(true));
    await settleWorkspace(tester);
    await tester.tap(find.byKey(const ValueKey('reaction-rocket')));
    await tester.pump();
    await tester.pumpWidget(host(false));
    await settleWorkspace(tester);
    pending.complete(jsonResponse({'message': 'Synthetic failure'}, status: 503));
    await settleWorkspace(tester);
    expect(find.text('❤️ 1'), findsOneWidget);
    expect(find.text('🚀 1'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.widget<ActionChip>(find.byKey(const ValueKey('reaction-add'))).onPressed, isNotNull);
  });

  testWidgets('replacement discards the old pending awards read', (
    tester,
  ) async {
    final pending = Completer<ResponseBody>();
    final adapter = FakeAdapter((request) {
      if (request.uri.path.endsWith('/issues/1/award_emoji')) {
        return pending.future;
      }
      return jsonResponse([
        {
          'id': 22,
          'name': 'heart',
          'user': {'id': 8},
        },
      ]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    Widget host(int iid) => workspaceHost(
      Scaffold(
        body: ReactionsBar(
          account: fixture.account,
          api: api,
          project: fixture.project,
          resource: 'issues',
          iid: iid,
        ),
      ),
    );
    await tester.pumpWidget(host(1));
    await tester.pump();
    await tester.pumpWidget(host(2));
    await settleWorkspace(tester);
    pending.complete(
      jsonResponse([
        {
          'id': 11,
          'name': 'rocket',
          'user': {'id': 7},
        },
      ]),
    );
    await settleWorkspace(tester);
    expect(find.text('❤️ 1'), findsOneWidget);
    expect(find.text('🚀 1'), findsNothing);
  });

  testWidgets('an old picker cannot send a reaction to a replacement account', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    fixture.issues[1] = fixture.issue(1, 'Synthetic');
    addTearDown(fixture.api.close);
    final other = Account(
      instance: fixture.api.instance,
      user: const GitLabUser(id: 8, username: 'other', name: 'Other'),
      token: 'synthetic-other',
    );
    Widget host(Account account) => workspaceHost(
      Scaffold(
        body: ReactionsBar(
          account: account,
          api: fixture.api,
          project: fixture.project,
          resource: 'issues',
          iid: 1,
        ),
      ),
    );
    await tester.pumpWidget(host(fixture.account));
    await settleWorkspace(tester);
    await tester.tap(find.byKey(const ValueKey('reaction-add')));
    await settleWorkspace(tester);
    await tester.pumpWidget(host(other));
    await settleWorkspace(tester);
    final oldPicker = find.bySemanticsLabel('rocket');
    if (oldPicker.evaluate().isNotEmpty) {
      await tester.tap(oldPicker);
      await settleWorkspace(tester);
    }
    expect(fixture.adapter.requests.where((r) => r.method != 'GET'), isEmpty);
    expect(find.text('🚀 1'), findsNothing);
  });

  testWidgets('old mutation completion cannot reload a replacement note', (
    tester,
  ) async {
    final pending = Completer<ResponseBody>();
    final adapter = FakeAdapter((request) {
      if (request.method == 'POST') return pending.future;
      return jsonResponse([
        {
          'id': 11,
          'name': 'rocket',
          'user': {'id': 99},
        },
      ]);
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    Widget host(int? note) => workspaceHost(
      Scaffold(
        body: ReactionsBar(
          account: fixture.account,
          api: api,
          project: fixture.project,
          resource: 'issues',
          iid: 1,
          note: note,
        ),
      ),
    );
    await tester.pumpWidget(host(null));
    await settleWorkspace(tester);
    await tester.tap(find.byKey(const ValueKey('reaction-rocket')));
    await tester.pump();
    await tester.pumpWidget(host(12));
    await settleWorkspace(tester);
    final readsBeforeCompletion = adapter.requests
        .where((r) => r.method == 'GET')
        .length;
    pending.complete(jsonResponse({'id': 44}));
    await settleWorkspace(tester);
    expect(
      adapter.requests.where((r) => r.method == 'GET').length,
      readsBeforeCompletion,
    );
    expect(
      adapter.requests.where((r) => r.method == 'POST').single.uri.path,
      endsWith('/issues/1/award_emoji'),
    );
  });
}
