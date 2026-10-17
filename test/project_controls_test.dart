import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost, settleWorkspace;
import 'support/shell_nav.dart';

/// Synthetic stateful project API. The visible production screens perform all
/// writes; unknown endpoints fall through to the fixture's explicit 404.
class ProjectCrudFixture extends WorkspaceFixture {
  bool exists = false, starred = false;
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final segments = request.uri.pathSegments;
    final path = segments.skip(segments.indexOf('v4') + 1).join('/');
    final method = request.method;
    final body = request.data is Json ? request.data as Json : <String, dynamic>{};
    if (!const ['GET', 'HEAD'].contains(method) && failWrites) { return jsonResponse({}, status: 422); }
    if (path == 'projects') {
      if (method == 'GET') {
        final search = request.uri.queryParameters['search'] ?? '';
        final matches = exists && (request.uri.queryParameters['starred'] != 'true' || starred) &&
          (projectRecord['name'] as String).toLowerCase().contains(search.toLowerCase());
        return jsonResponse(matches ? [projectRecord] : <Json>[]);
      }
      if (method == 'POST') {
        if (exists) { return jsonResponse({}, status: 409); }
        exists = true;
        projectRecord.addAll({'name': body['name'], 'description': body['description'],
          'path_with_namespace': 'studio/${body['path']}', 'visibility': body['visibility']});
        return jsonResponse(projectRecord, status: 201);
      }
    }
    if (path == 'projects/42' || path == 'projects/${projectRecord['path_with_namespace']}') {
      if (!exists) { return jsonResponse({}, status: 404); }
      if (method == 'PUT') { projectRecord.addAll(body); }
      if (method == 'DELETE') { exists = false; return ResponseBody.fromString('', 202); }
      return jsonResponse(projectRecord);
    }
    if (path == 'projects/42/starrers' && method == 'GET') {
      return jsonResponse(starred ? [{'user': {'id': 7, 'username': 'developer'}}] : <Json>[]);
    }
    if (const ['projects/42/star', 'projects/42/unstar'].contains(path) && method == 'POST') {
      if (!exists) { return jsonResponse({}, status: 404); }
      starred = path.endsWith('/star');
      return jsonResponse(projectRecord);
    }
    return super.respond(request);
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test('app-bar titles have an explicit font family for renderable visual evidence', () {
    for (final brightness in Brightness.values) {
      expect(appTheme(brightness).appBarTheme.titleTextStyle!.fontFamily, 'Roboto');
    }
  });
  testWidgets('filter chips keep a 48dp hit target', (tester) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(MaterialApp(theme: appTheme(brightness), home: Scaffold(body: Center(child: FilterChip(
        label: const Text('只看未解決'), onSelected: (_) {})))));
      await tester.pump();
      expect(tester.getSize(find.byType(FilterChip)).height, greaterThanOrEqualTo(48));
    }
  });
  testWidgets('projects visible create/edit/star/unstar/delete retains failed draft and returns to refreshed list', (tester) async {
    final fixture = ProjectCrudFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    addTearDown(session.dispose); addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(412, 1000);
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await session.initialize(); await session.connect('https://example.com/gitlab', 'synthetic-test-token');
    });
    await tester.pumpWidget(workspaceHost(ProjectsPage(session: session))); await settleWorkspace(tester);
    expect(find.text('目前沒有專案'), findsOneWidget);
    await tester.tap(find.byTooltip('新增專案')); await settleWorkspace(tester);
    await tester.enterText(find.byKey(const ValueKey('editor-name')), 'Synthetic project');
    await tester.enterText(find.byKey(const ValueKey('editor-path')), 'project-crud');
    await tester.enterText(find.byKey(const ValueKey('editor-description')), 'Only synthetic data');
    fixture.failWrites = true;
    await tester.tap(find.byKey(const Key('editorSave'))); await settleWorkspace(tester);
    expect(fixture.exists, isFalse);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('editor-name'))).controller!.text, 'Synthetic project');
    fixture.failWrites = false;
    await tester.tap(find.byKey(const Key('editorSave'))); await settleWorkspace(tester);
    expect(fixture.exists, isTrue); expect(fixture.projectRecord['visibility'], 'private');
    final creates = fixture.adapter.requests.where((r) => r.method == 'POST' && r.uri.pathSegments.last == 'projects');
    expect(creates, hasLength(2));
    expect((creates.last.data as Json)['initialize_with_readme'], isTrue);
    expect(find.text('Synthetic project'), findsOneWidget);
    await openProjectTab(tester, '更多'); await settleWorkspace(tester);
    Future<void> action(String text) async {
      final scroller = find.descendant(of: find.byType(ProjectMoreTab), matching: find.byType(Scrollable)).first;
      // Controls sit both in the overview card at the top and in the list below.
      await tester.drag(scroller, const Offset(0, 4000)); await tester.pump();
      await tester.scrollUntilVisible(find.text(text), 150, scrollable: scroller);
      // A confirmation snack bar from the previous action may float over the target.
      ScaffoldMessenger.of(tester.element(scroller)).removeCurrentSnackBar(); await tester.pump();
      await tester.tap(find.text(text)); await settleWorkspace(tester);
    }
    await action('名稱與說明');
    await tester.enterText(find.byKey(const ValueKey('editor-name')), 'Updated project');
    await tester.enterText(find.byKey(const ValueKey('editor-description')), 'Updated synthetic data');
    await tester.tap(find.byKey(const Key('editorSave'))); await settleWorkspace(tester);
    expect(fixture.projectRecord['name'], 'Updated project');
    expect(find.text('Updated project'), findsOneWidget);
    int projectListReads() => fixture.adapter.requests.where((request) =>
      request.method == 'GET' && request.uri.pathSegments.last == 'projects').length;
    final readsBeforeStar = projectListReads();
    await action('加入星標'); expect(fixture.starred, isTrue);
    expect(projectListReads(), greaterThan(readsBeforeStar), reason: 'a star mutation reconciles the loaded project feed');
    await tester.tap(find.byType(BackButton)); await settleWorkspace(tester);
    await tester.tap(find.widgetWithText(ChoiceChip, '星標')); await settleWorkspace(tester);
    expect(find.text('Updated project'), findsOneWidget);
    await tester.tap(find.text('Updated project')); await settleWorkspace(tester);
    await openProjectTab(tester, '更多'); await settleWorkspace(tester);
    final readsBeforeUnstar = projectListReads();
    await action('移除星標'); expect(fixture.starred, isFalse);
    expect(projectListReads(), greaterThan(readsBeforeUnstar), reason: 'an unstar mutation reconciles starred/count state');
    await tester.tap(find.byType(BackButton)); await settleWorkspace(tester);
    expect(find.text('目前沒有專案'), findsOneWidget,
      reason: 'the reconciled starred feed removes an unstarred project row');
    await tester.tap(find.widgetWithText(ChoiceChip, '我的專案')); await settleWorkspace(tester);
    await tester.tap(find.text('Updated project').last); await settleWorkspace(tester);
    await openProjectTab(tester, '更多'); await settleWorkspace(tester);
    await action('刪除專案…');
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '確認')).onPressed, isNull);
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'studio/project-crud');
    await tester.pump(); await tester.tap(find.widgetWithText(FilledButton, '確認')); await settleWorkspace(tester);
    expect(fixture.exists, isFalse); expect(find.text('目前沒有專案'), findsOneWidget);
    expect(fixture.adapter.requests.where((r) => r.method == 'DELETE'), hasLength(1));
    expect(tester.takeException(), isNull); expect(fixture.unhandled, isEmpty);
    await tester.pumpWidget(const SizedBox()); await tester.pump(const Duration(seconds: 1));
  });
}
