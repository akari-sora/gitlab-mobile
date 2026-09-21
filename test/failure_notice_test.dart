import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

Account _account() => Account(
  instance: GitLabInstance.parse('https://example.com/gitlab'),
  user: const GitLabUser(id: 7, username: 'tester', name: 'Test'),
  token: 'synthetic-test-token',
);

void main() {
  testWidgets('404 notice shows instance, account, resource and switch without rotating', (tester) async {
    var switched = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: FailureNotice(
      const ApiFailure(FailureKind.invisible, status: 404),
      account: _account(), resourceLabel: 'studio/private',
      onRetry: () {}, onSwitchAccount: () { switched++; },
    ))));
    expect(find.text('無法開啟此資源'), findsOneWidget);
    expect(find.text('實例：https://example.com/gitlab'), findsOneWidget);
    expect(find.text('App 帳號：@tester'), findsOneWidget);
    expect(find.text('目標：studio/private'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);
    expect(find.text('重新整理'), findsOneWidget);
    await tester.tap(find.text('切換帳號'));
    await tester.pump();
    expect(switched, 1);
  });

  testWidgets('list 404 card carries account and does not auto-switch', (tester) async {
    final adapter = FakeAdapter((_) => jsonResponse({'message': 'not found'}, status: 404));
    final api = testApi(adapter); addTearDown(api.close);
    var switched = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RecordsFeed(
      identity: 'todos', account: _account(), resourceLabel: '待辦',
      onSwitchAccount: () { switched++; },
      load: (next) => api.records(['todos'], next: next),
      itemBuilder: (context, item) => const SizedBox(),
    ))));
    await settleNetworkWidgets(tester);
    expect(find.text('App 帳號：@tester'), findsOneWidget);
    expect(find.text('目標：待辦'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);
    await tester.tap(find.text('切換帳號'));
    await tester.pump();
    expect(switched, 1);
  });

  testWidgets('writeUncertain omits retry', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: FailureNotice(
      const ApiFailure(FailureKind.writeUncertain),
      account: _account(), onRetry: () {},
    ))));
    expect(find.text('重新整理'), findsNothing);
  });
}
