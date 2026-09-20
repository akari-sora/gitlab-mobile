import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  for (final status in ['manual', 'pending', 'created', 'scheduled', 'preparing', 'waiting_for_resource']) {
    test('visible $status job without trace returns an empty log', () async {
      final api = testApi(FakeAdapter((request) => request.uri.path.endsWith('/trace')
        ? jsonResponse({}, status: 404) : jsonResponse({'id': 1, 'status': status})));
      addTearDown(api.close);
      expect(await api.jobTrace(42, 1), '');
    });
  }
  test('expired completed-job trace remains 404 rather than pretending it is empty', () async {
    final api = testApi(FakeAdapter((request) => request.uri.path.endsWith('/trace')
      ? jsonResponse({}, status: 404) : jsonResponse({'id': 1, 'status': 'success'})));
    addTearDown(api.close);
    await expectLater(api.jobTrace(42, 1), throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 404)));
  });
  test('nonexistent job cannot masquerade as a pending empty log', () async {
    final api = testApi(FakeAdapter((_) => jsonResponse({}, status: 404))); addTearDown(api.close);
    await expectLater(api.jobTrace(42, 1), throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 404)));
  });
  test('invalid project rows fail in the transport rather than during widget build', () async {
    final api = testApi(FakeAdapter((_) => jsonResponse([{'id': 42}]))); addTearDown(api.close);
    await expectLater(api.records(['projects']), throwsA(isA<ApiFailure>()
      .having((e) => e.kind, 'kind', FailureKind.invalidResponse)));
  });
  testWidgets('manual job retains its play control before any trace exists', (tester) async {
    final fixture = WorkspaceFixture(); addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(JobLogPage(account: fixture.account, api: fixture.api, project: fixture.project, id: 502)));
    await settleWorkspace(tester);
    expect(find.text('等待手動啟動'), findsOneWidget);
    await tester.tap(find.byTooltip('工作操作')); await tester.pumpAndSettle();
    expect(find.text('啟動手動工作'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pump();
  });
}
