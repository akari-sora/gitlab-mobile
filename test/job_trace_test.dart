import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
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

  test('jobTraceChunk sends Range header and offset query param when offset > 0', () async {
    RequestOptions? captured;
    final api = testApi(FakeAdapter((request) {
      captured = request;
      return ResponseBody.fromString('chunk2', 206, headers: {
        'content-range': ['bytes 100-105/200'],
      });
    }));
    addTearDown(api.close);
    final result = await api.jobTraceChunk(42, 1, offset: 100);
    expect(captured, isNotNull);
    expect(captured!.headers['Range'], 'bytes=100-');
    expect(captured!.uri.queryParameters['offset'], '100');
    expect(utf8.decode(result.bytes), 'chunk2');
    expect(result.nextOffset, 106);
    expect(result.isEof, isFalse);
  });

  test('jobTraceChunk handles HTTP 206 with partial content and EOF', () async {
    final api = testApi(FakeAdapter((request) => ResponseBody.fromString('done', 206, headers: {
      'content-range': ['bytes 100-103/104'],
      'x-gitlab-trace-eof': ['true'],
    })));
    addTearDown(api.close);
    final result = await api.jobTraceChunk(42, 1, offset: 100);
    expect(utf8.decode(result.bytes), 'done');
    expect(result.nextOffset, 104);
    expect(result.isEof, isTrue);
  });

  test('jobTraceChunk handles HTTP 416 Range Not Satisfiable as empty chunk with current offset', () async {
    final api = testApi(FakeAdapter((request) => ResponseBody.fromString('', 416, headers: {
      'content-range': ['bytes */100'],
      'x-gitlab-trace-eof': ['true'],
    })));
    addTearDown(api.close);
    final result = await api.jobTraceChunk(42, 1, offset: 100);
    expect(result.bytes, isEmpty);
    expect(result.nextOffset, 100);
    expect(result.isEof, isTrue);
  });

  testWidgets('JobLogPage preserves section collapsed state during offset streaming updates', (tester) async {
    const initialTrace = 'section_start:1700000000:step_1\r\nInside step 1\r\nsection_end:1700000010:step_1\r\n';
    const appendTrace = 'New log line after step 1\r\n';

    final api = testApi(FakeAdapter((request) {
      if (request.uri.path.endsWith('/jobs/1')) {
        return jsonResponse({'id': 1, 'status': 'running'});
      }
      if (request.uri.path.endsWith('/trace')) {
        final initialBytes = utf8.encode(initialTrace);
        if (request.headers['Range'] == 'bytes=${initialBytes.length}-') {
          return ResponseBody.fromString(appendTrace, 206, headers: {
            'content-range': ['bytes ${initialBytes.length}-${initialBytes.length + utf8.encode(appendTrace).length - 1}/*'],
          });
        }
        return ResponseBody.fromString(initialTrace, 200);
      }
      return jsonResponse({}, status: 404);
    }));
    addTearDown(api.close);

    final project = Project.fromJson(projectJson(42));
    final account = Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 1, username: 'testuser', name: 'Test User'),
      token: 'tok',
    );

    await tester.pumpWidget(workspaceHost(JobLogPage(account: account, api: api, project: project, id: 1)));
    await settleWorkspace(tester);

    expect(find.text('step 1 · 10 秒'), findsOneWidget);
    expect(find.text('Inside step 1'), findsOneWidget);

    // Tap section header to collapse it
    await tester.tap(find.text('step 1 · 10 秒'));
    await tester.pumpAndSettle();

    // Inside step 1 should now be collapsed (hidden)
    expect(find.text('Inside step 1'), findsNothing);

    // Tap refresh icon to trigger streaming update
    await tester.tap(find.byTooltip('重新讀取 Log'));
    await settleWorkspace(tester);

    // Verify new log arrived
    expect(find.text('New log line after step 1'), findsOneWidget);
    // Verify section is STILL collapsed!
    expect(find.text('Inside step 1'), findsNothing);

    // Expand section again
    await tester.tap(find.text('step 1 · 10 秒'));
    await tester.pumpAndSettle();

    // Verify inside content is visible again
    expect(find.text('Inside step 1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
