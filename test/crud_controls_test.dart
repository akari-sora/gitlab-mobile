import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost, settleWorkspace;

/// Stateful synthetic server for visible-control tests. Each mutation changes
/// subsequent reads. Unknown routes/methods fail, never blanket-return success.
/// These tests do not claim a live GitLab or physical-device run.
class CrudFixture extends WorkspaceFixture {
  late final collections = <String, Map<String, Json>>{
    'repository/branches': {
      'main': {'name': 'main', 'default': true, 'protected': true, 'commit': {'id': head}},
      'feature/navigation': {'name': 'feature/navigation', 'default': false, 'protected': false, 'commit': {'id': head}},
    },
    'repository/tags': {}, 'labels': {}, 'milestones': {}, 'releases': {},
  };
  final files = <String, String>{'README.md': '# Initial\n'};
  final fileCommits = <String, String>{};
  final mrs = <int, Json>{};
  final pipelines = <int, Json>{};
  late final jobRecords = <int, Json>{
    501: {...job(501, status: 'failed'), 'name': 'Unit tests'},
    502: {...job(502, status: 'manual'), 'name': 'manual deploy'},
  };
  int revision = 1, latestJob = 501;
  int traceStatus = 200;
  String? forcedTrace;
  Completer<ResponseBody>? delayedTrace;
  String get head => revision.toRadixString(16).padLeft(40, '0');
  List<String> pathOf(RequestOptions r) => r.uri.pathSegments.skip(r.uri.pathSegments.indexOf('v4') + 1).toList();
  Iterable<RequestOptions> writes(String suffix) => adapter.requests.where((r) =>
    !const ['GET', 'HEAD'].contains(r.method) && pathOf(r).join('/').endsWith(suffix));
  ResponseBody missing() => jsonResponse({'error': 'fixture-not-found'}, status: 404);
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final path = pathOf(request);
    final method = request.method;
    final body = request.data is Json ? Map<String, dynamic>.from(request.data as Json) : <String, dynamic>{};
    if (failWrites && !const ['GET', 'HEAD'].contains(method)) { return jsonResponse({}, status: 422); }
    if (path.length < 2 || path[0] != 'projects' || path[1] != '42') { return super.respond(request); }
    final sub = path.skip(2).toList();
    if (sub.isEmpty) { return super.respond(request); }
    if (sub.length == 2 && sub.join('/') == 'repository/tree' && method == 'GET') {
      return jsonResponse(files.keys.map((p) => {'id': p, 'name': p, 'path': p, 'type': 'blob', 'mode': '100644'}).toList());
    }
    if (sub.length >= 3 && sub[0] == 'repository' && sub[1] == 'files') {
      final file = sub[2];
      if (method == 'POST' && sub.length == 3) {
        if (files.containsKey(file)) { return jsonResponse({}, status: 400); }
        files[file] = body['content'] as String; revision++; fileCommits[file] = head;
        collections['repository/branches']!['main']!['commit'] = {'id': head};
        return jsonResponse({'file_path': file, 'branch': 'main'}, status: 201);
      }
      if (!files.containsKey(file)) { return missing(); }
      if (method == 'HEAD' && sub.length == 3) {
        return ResponseBody.fromString('', 200, headers: {
          'x-gitlab-size': ['${utf8.encode(files[file]!).length}'],
          'x-gitlab-last-commit-id': [fileCommits[file] ?? head],
        });
      }
      if (method == 'GET' && sub.length == 4 && sub[3] == 'raw') { return ResponseBody.fromString(files[file]!, 200); }
      if (const ['PUT', 'DELETE'].contains(method) && sub.length == 3) {
        if (body['last_commit_id'] != (fileCommits[file] ?? head)) { return jsonResponse({}, status: 400); }
        revision++;
        if (method == 'PUT') { files[file] = body['content'] as String; fileCommits[file] = head; }
        else { files.remove(file); fileCommits.remove(file); }
        collections['repository/branches']!['main']!['commit'] = {'id': head};
        return method == 'DELETE' ? ResponseBody.fromString('', 204) : jsonResponse({'file_path': file, 'branch': 'main'});
      }
    }
    for (final entry in collections.entries) {
      final prefix = entry.key.split('/');
      if (sub.length < prefix.length || sub.take(prefix.length).join('/') != entry.key) { continue; }
      final rows = entry.value;
      if (sub.length == prefix.length) {
        if (method == 'GET') { return jsonResponse(rows.values.toList()); }
        if (method == 'POST') {
          final id = ++counter;
          final key = entry.key == 'repository/branches' ? body['branch'] as String
            : entry.key == 'repository/tags' || entry.key == 'releases' ? body['tag_name'] as String : '$id';
          if (rows.containsKey(key)) { return jsonResponse({}, status: 409); }
          rows[key] = {'id': id, 'state': 'active', ...body,
            if (entry.key == 'repository/branches') ...{'name': key, 'protected': false, 'default': false, 'commit': {'id': head}},
            if (entry.key == 'repository/tags') ...{'name': key, 'commit': {'id': head}},
          };
          // GitLab tags return name, not the request-only tag_name field.
          if (entry.key == 'repository/tags') { rows[key]!.remove('tag_name'); }
          return jsonResponse(rows[key], status: 201);
        }
      }
      if (sub.length == prefix.length + 1) {
        final key = sub.last, row = rows[sub.last];
        if (row == null) { return missing(); }
        if (method == 'GET') { return jsonResponse(row); }
        if (method == 'DELETE') {
          if (row['protected'] == true) { return jsonResponse({}, status: 403); }
          rows.remove(key); return ResponseBody.fromString('', 204);
        }
        if (method == 'PUT') {
          if (entry.key == 'labels' && body.containsKey('name')) { return jsonResponse({}, status: 400); }
          row.addAll(body);
          if (body['new_name'] != null) { row['name'] = body['new_name']; }
          if (body['state_event'] != null) { row['state'] = body['state_event'] == 'close' ? 'closed' : 'active'; }
          return jsonResponse(row);
        }
      }
    }
    if (sub[0] == 'merge_requests') {
      if (sub.length == 1) {
        if (method == 'GET') { return jsonResponse(mrs.values.toList()); }
        if (method == 'POST') {
          final iid = ++counter;
          mrs[iid] = {...mergeRequest, ...body, 'iid': iid, 'labels': <String>[], 'updated_at': 'r$counter'};
          return jsonResponse(mrs[iid], status: 201);
        }
      } else {
        final row = mrs[int.tryParse(sub[1])];
        if (row == null) { return missing(); }
        if (sub.length == 2) {
          if (method == 'GET') { return jsonResponse(row); }
          if (method == 'PUT') {
            row.addAll(body); row['updated_at'] = 'r${++counter}';
            if (body['state_event'] != null) { row['state'] = body['state_event'] == 'close' ? 'closed' : 'opened'; }
            return jsonResponse(row);
          }
          if (method == 'DELETE') { mrs.remove(int.parse(sub[1])); return ResponseBody.fromString('', 204); }
        }
        if (method == 'GET' && sub.last == 'discussions') { return jsonResponse(<Json>[]); }
        if (method == 'GET' && sub.last == 'approvals') { return jsonResponse({'approved_by': <Json>[]}); }
        if (method == 'GET' && sub.last == 'versions') { return jsonResponse([{'id': 1, 'head_commit_sha': WorkspaceFixture.sha}]); }
        if (method == 'GET' && sub.length == 4 && sub[2] == 'versions') {
          return jsonResponse({'id': 1, 'head_commit_sha': WorkspaceFixture.sha,
            'start_commit_sha': WorkspaceFixture.sha, 'base_commit_sha': WorkspaceFixture.sha, 'diffs': <Json>[]});
        }
      }
    }
    if (sub.length == 1 && sub[0] == 'pipeline' && method == 'POST') {
      final id = ++counter;
      pipelines[id] = {...pipeline, 'id': id, 'ref': body['ref'], 'status': 'failed'};
      return jsonResponse(pipelines[id], status: 201);
    }
    if (sub[0] == 'pipelines') {
      if (sub.length == 1 && method == 'GET') { return jsonResponse(pipelines.values.toList()); }
      if (sub.length >= 2) {
        final id = int.tryParse(sub[1]), row = pipelines[int.tryParse(sub[1])];
        if (row == null) { return missing(); }
        if (sub.length == 2 && method == 'GET') { return jsonResponse(row); }
        if (sub.length == 2 && method == 'DELETE') { pipelines.remove(id); return ResponseBody.fromString('', 204); }
        if (sub.length == 3 && sub.last == 'jobs' && method == 'GET') { return jsonResponse([jobRecords[latestJob], jobRecords[502]]); }
        if (sub.length == 3 && method == 'POST' && const ['retry', 'cancel'].contains(sub.last)) {
          row['status'] = sub.last == 'retry' ? 'running' : 'canceled'; return jsonResponse(row);
        }
      }
    }
    if (sub[0] == 'jobs' && sub.length >= 2) {
      final id = int.tryParse(sub[1]), row = jobRecords[int.tryParse(sub[1])];
      if (row == null) { return missing(); }
      if (sub.length == 2 && method == 'GET') { return jsonResponse(row); }
      if (sub.length == 3 && sub.last == 'trace' && method == 'GET') {
        if (id == 501 && delayedTrace != null) { return delayedTrace!.future; }
        if (row['status'] == 'manual' || row['status'] == 'pending') { return missing(); }
        return ResponseBody.fromString(forcedTrace ?? 'Synthetic log\n', traceStatus);
      }
      if (sub.length == 3 && method == 'POST') {
        if (sub.last == 'retry') {
          latestJob = 701; jobRecords[701] = {...row, 'id': 701, 'status': 'pending'}; return jsonResponse(jobRecords[701], status: 201);
        }
        if (sub.last == 'play' && id == 502) { row['status'] = 'pending'; return jsonResponse(row); }
        if (sub.last == 'cancel') { row['status'] = 'canceled'; return jsonResponse(row); }
      }
    }
    return super.respond(request);
  }
}

Future<void> host(WidgetTester tester, CrudFixture f, Widget page) async {
  addTearDown(f.api.close);
  tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(workspaceHost(page)); await settleWorkspace(tester);
}
Future<void> input(WidgetTester tester, String key, String value) => tester.enterText(find.byKey(ValueKey('editor-$key')), value);
Future<void> save(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('editorSave'))); await settleWorkspace(tester);
}
Future<void> menu(WidgetTester tester, String tooltip, String choice, {String? row}) async {
  final target = row == null ? find.byTooltip(tooltip) : find.descendant(
    of: find.ancestor(of: find.text(row), matching: find.byType(Card)).first, matching: find.byTooltip(tooltip));
  await tester.ensureVisible(target); await tester.tap(target); await tester.pumpAndSettle();
  await tester.tap(find.text(choice)); await settleWorkspace(tester);
}
Future<void> confirm(WidgetTester tester, {String? text}) async {
  if (text != null) {
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '確認')).onPressed, isNull);
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), text);
    await tester.pump();
  }
  await tester.tap(find.widgetWithText(FilledButton, '確認')); await settleWorkspace(tester);
}
Future<void> pumpPending(WidgetTester tester) async {
  // A deliberately unresolved trace keeps a loading animation alive. Advance
  // route frames and Dio's real event loop without requiring global idleness.
  for (var cycle = 0; cycle < 12; cycle++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
  }
}
Future<void> finish(WidgetTester tester, CrudFixture f) async {
  expect(f.unhandled, isEmpty); expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox()); await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  for (final kind in [MetadataKind.branches, MetadataKind.tags, MetadataKind.labels, MetadataKind.milestones, MetadataKind.releases]) {
    testWidgets('${kind.name} visible create/read/update-if-supported/delete', (tester) async {
      final f = CrudFixture();
      await host(tester, f, MetadataPage(account: f.account, api: f.api, project: f.project, kind: kind));
      await tester.tap(find.byTooltip('新增${metadataTitle(kind)}')); await settleWorkspace(tester);
      var name = 'Smoke ${kind.name}';
      if (kind == MetadataKind.branches) { name = 'smoke/branch'; await input(tester, 'branch', name); }
      else if (kind == MetadataKind.tags) { name = 'smoke-v1'; await input(tester, 'tag_name', name); }
      else {
        if (kind == MetadataKind.releases) { await input(tester, 'tag_name', 'smoke-v1'); }
        await input(tester, kind == MetadataKind.milestones ? 'title' : 'name', name);
        await input(tester, 'description', 'Original description');
      }
      await save(tester); expect(find.text(name), findsOneWidget);
      final collection = f.collections[kind == MetadataKind.branches || kind == MetadataKind.tags ? 'repository/${kind.name}' : kind.name]!;
      expect(collection.values.any((v) => v['name'] == name || v['title'] == name), isTrue);
      if (![MetadataKind.branches, MetadataKind.tags].contains(kind)) {
        await menu(tester, '項目操作', '編輯', row: name);
        name = 'Updated ${kind.name}';
        await input(tester, kind == MetadataKind.milestones ? 'title' : 'name', name);
        await input(tester, 'description', 'Updated description');
        await save(tester); expect(find.text(name), findsOneWidget);
        expect(collection.values.single['description'], 'Updated description');
        if (kind == MetadataKind.labels) {
          final write = f.writes('labels/${collection.keys.single}').last;
          expect((write.data as Json)['new_name'], name); expect((write.data as Json).containsKey('name'), isFalse);
        }
        if (kind == MetadataKind.milestones) {
          await menu(tester, '項目操作', '關閉里程碑', row: name); expect(collection.values.single['state'], 'closed');
          await menu(tester, '項目操作', '重新啟用', row: name); expect(collection.values.single['state'], 'active');
        }
      }
      await menu(tester, '項目操作', '刪除', row: name);
      final before = collection.length;
      await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'wrong name');
      await tester.pump();
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '確認')).onPressed, isNull);
      expect(collection.length, before);
      await confirm(tester, text: name); expect(find.text(name), findsNothing);
      expect(collection.length, before - 1); await finish(tester, f);
    });
  }
  testWidgets('invalid calendar date stays in milestone form without a write', (tester) async {
    final f = CrudFixture();
    await host(tester, f, MetadataPage(account: f.account, api: f.api, project: f.project, kind: MetadataKind.milestones));
    await tester.tap(find.byTooltip('新增里程碑')); await settleWorkspace(tester);
    await input(tester, 'title', 'Date check'); await input(tester, 'start_date', '2026-02-30');
    await save(tester); expect(f.writes('milestones'), isEmpty);
    expect(tester.widget<TextFormField>(find.byKey(const ValueKey('editor-title'))).controller!.text, 'Date check');
    await input(tester, 'start_date', '2026-02-28'); await save(tester);
    expect(f.collections['milestones']!.values.single['start_date'], '2026-02-28'); await finish(tester, f);
  });
  testWidgets('file create/read/edit/delete from repository controls sends last_commit_id', (tester) async {
    final f = CrudFixture();
    await host(tester, f, Scaffold(body: RepositoryTab(account: f.account, api: f.api, project: f.project)));
    await tester.tap(find.byTooltip('新增檔案')); await settleWorkspace(tester);
    await input(tester, 'path', 'smoke.txt'); await input(tester, 'content', 'Original file'); await save(tester);
    expect(f.files['smoke.txt'], 'Original file');
    await tester.tap(find.text('smoke.txt')); await settleWorkspace(tester);
    expect(find.text('Original file'), findsOneWidget);
    await menu(tester, '檔案操作', '編輯檔案');
    await input(tester, 'content', 'Changed file'); await save(tester);
    expect(f.files['smoke.txt'], 'Changed file');
    final update = f.writes('repository/files/smoke.txt').last;
    expect(update.method, 'PUT'); expect((update.data as Json)['last_commit_id'], isNotEmpty);
    await tester.tap(find.text('smoke.txt')); await settleWorkspace(tester);
    expect(find.text('Changed file'), findsOneWidget);
    await menu(tester, '檔案操作', '刪除檔案'); await confirm(tester, text: 'smoke.txt');
    expect(f.files.containsKey('smoke.txt'), isFalse); expect(find.text('smoke.txt'), findsNothing);
    await finish(tester, f);
  });
  testWidgets('MR visible create/read/edit/close/reopen/delete', (tester) async {
    final f = CrudFixture();
    await host(tester, f, Scaffold(body: WorkItemsTab(account: f.account, api: f.api, project: f.project, resource: 'merge_requests')));
    await tester.tap(find.byTooltip('新增合併請求')); await settleWorkspace(tester);
    await input(tester, 'title', 'UI MR');
    await tester.tap(find.byKey(const ValueKey('editor-source_branch')));
    await settleWorkspace(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('picker-row-feature/navigation')));
    await tester.tap(find.byKey(const ValueKey('picker-row-feature/navigation')));
    await tester.pump();
    await tester.tap(find.text('完成'));
    await settleWorkspace(tester);
    await save(tester);
    final created = f.writes('merge_requests').single;
    expect((created.data as Json)['source_branch'], 'feature/navigation');
    expect((created.data as Json)['target_branch'], 'main');
    final iid = f.mrs.keys.single;
    expect(find.text('UI MR'), findsOneWidget);
    await menu(tester, '更多操作', '編輯'); await input(tester, 'title', 'Updated MR'); await save(tester);
    expect(f.mrs[iid]!['title'], 'Updated MR');
    await menu(tester, '更多操作', '關閉'); expect(f.mrs[iid]!['state'], 'closed');
    await menu(tester, '更多操作', '重新開啟'); expect(f.mrs[iid]!['state'], 'opened');
    await menu(tester, '更多操作', '刪除'); await confirm(tester, text: '!$iid');
    expect(f.mrs, isEmpty); await finish(tester, f);
  });
  testWidgets('pipeline visible run/read/retry/cancel/delete', (tester) async {
    final f = CrudFixture();
    await host(tester, f, Scaffold(body: PipelinesTab(account: f.account, api: f.api, project: f.project)));
    await tester.tap(find.byTooltip('執行 Pipeline')); await settleWorkspace(tester); await save(tester);
    final id = f.pipelines.keys.single;
    expect(find.text('Pipeline #$id'), findsOneWidget);
    await menu(tester, 'Pipeline 操作', '重試失敗工作'); await confirm(tester);
    expect(f.pipelines[id]!['status'], 'running');
    await menu(tester, 'Pipeline 操作', '取消流程'); await confirm(tester);
    expect(f.pipelines[id]!['status'], 'canceled');
    await menu(tester, 'Pipeline 操作', '刪除 Pipeline'); await confirm(tester, text: '$id');
    expect(f.pipelines, isEmpty); await finish(tester, f);
  });
  testWidgets('job retry follows new ID and refreshes pipeline only on real back', (tester) async {
    final f = CrudFixture(); f.pipelines[99] = f.pipeline;
    await host(tester, f, PipelinePage(account: f.account, api: f.api, project: f.project, id: 99));
    await tester.tap(find.text('Unit tests')); await settleWorkspace(tester);
    int readCount() => f.adapter.requests.where((r) => f.pathOf(r).join('/') == 'projects/42/pipelines/99/jobs').length;
    final beforeRetry = readCount();
    await menu(tester, '工作操作', '重試工作');
    expect(find.byType(LinearProgressIndicator), findsNothing, reason: 'Confirmation is not an executing operation');
    await confirm(tester);
    expect(find.text('#701'), findsOneWidget); expect(find.text('尚無 Log'), findsOneWidget);
    expect(readCount(), beforeRetry, reason: 'Retry must not prematurely complete the job route');
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton)); await settleWorkspace(tester);
    expect(readCount(), greaterThan(beforeRetry)); expect(find.text('等待中'), findsOneWidget);
    await finish(tester, f);
  });
  for (final status in [200, 404]) {
    testWidgets('late old-attempt trace $status cannot overwrite retried job', (tester) async {
      final f = CrudFixture()..delayedTrace = Completer<ResponseBody>();
      addTearDown(() {
        if (!f.delayedTrace!.isCompleted) { f.delayedTrace!.complete(ResponseBody.fromString('', 200)); }
      });
      addTearDown(f.api.close);
      tester.view.devicePixelRatio = 1; tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(workspaceHost(JobLogPage(account: f.account, api: f.api, project: f.project, id: 501)));
      await pumpPending(tester);
      expect(find.text('Unit tests'), findsOneWidget);
      await tester.tap(find.byTooltip('工作操作')); await pumpPending(tester);
      await tester.tap(find.text('重試工作').hitTestable()); await pumpPending(tester);
      expect(f.writes('jobs/501/retry'), isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, '確認').hitTestable());
      await settleWorkspace(tester);
      expect(find.text('#701'), findsOneWidget); expect(find.text('尚無 Log'), findsOneWidget);
      f.delayedTrace!.complete(ResponseBody.fromString('STALE OLD ATTEMPT', status));
      await settleWorkspace(tester);
      expect(find.text('#701'), findsOneWidget); expect(find.text('STALE OLD ATTEMPT'), findsNothing);
      expect(find.text('診斷資訊'), findsNothing); expect(find.text('尚無 Log'), findsOneWidget);
      await finish(tester, f);
    });
  }
  for (final status in [404, 413]) {
    testWidgets('trace $status retains real job metadata and artifact/retry controls', (tester) async {
      final f = CrudFixture()..traceStatus = status;
      await host(tester, f, JobLogPage(account: f.account, api: f.api, project: f.project, id: 501));
      expect(find.text('Unit tests'), findsOneWidget); expect(find.text('失敗'), findsOneWidget);
      await tester.tap(find.byTooltip('工作操作')); await tester.pumpAndSettle();
      expect(find.text('重試工作'), findsOneWidget); expect(find.text('下載產物'), findsOneWidget);
      await finish(tester, f);
    });
  }
  testWidgets('manual play works before any log exists', (tester) async {
    final f = CrudFixture();
    await host(tester, f, JobLogPage(account: f.account, api: f.api, project: f.project, id: 502));
    expect(find.text('尚無 Log'), findsOneWidget);
    await menu(tester, '工作操作', '啟動手動工作'); await confirm(tester);
    expect(f.jobRecords[502]!['status'], 'pending'); expect(f.writes('jobs/502/play'), hasLength(1));
    expect(find.text('等待中'), findsOneWidget); await finish(tester, f);
  });
  testWidgets('excessive log line count keeps job controls without building huge lists', (tester) async {
    final f = CrudFixture()..forcedTrace = List.filled(GitLabApi.maxTextLines + 1, 'x').join('\n');
    await host(tester, f, JobLogPage(account: f.account, api: f.api, project: f.project, id: 501));
    expect(find.text('Unit tests'), findsOneWidget); expect(find.text('x'), findsNothing);
    expect(find.text('診斷資訊'), findsOneWidget); await finish(tester, f);
  });
}
