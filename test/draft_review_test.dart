import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/draft_review_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

const _head = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _newHead = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

Widget _host(Widget child) => MaterialApp(
  theme: appTheme(Brightness.light),
  locale: const Locale('zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: child,
);

class _DraftFixture {
  _DraftFixture() {
    adapter = FakeAdapter(respond);
    api = testApi(adapter);
  }

  late final FakeAdapter adapter;
  late final GitLabApi api;
  final drafts = <int, Map<String, dynamic>>{
    5: {
      'id': 5,
      'author_id': 7,
      'merge_request_id': 12,
      'note': '先處理空值，再補測試。',
      'commit_id': _head,
      'position': null,
    },
  };
  String currentHead = _head;
  bool uncertainCreate = false;
  bool failReadAfterPublish = false;
  Completer<void>? draftReadGate;
  int nextId = 5;

  Account get account => Account(
    instance: api.instance,
    user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
    token: 'synthetic-test-token',
  );
  Project get project => const Project(
    id: 42,
    name: 'Mobile Workspace',
    path: 'studio/mobile-workspace',
    visibility: 'private',
    defaultBranch: 'main',
    archived: false,
  );

  Future<ResponseBody> respond(RequestOptions request) async {
    final segments = request.uri.pathSegments;
    final start = segments.indexOf('v4');
    final path = segments.skip(start + 1).toList();
    final joined = path.join('/');
    final method = request.method;
    final body = request.data is Map
        ? Map<String, dynamic>.from(request.data as Map)
        : <String, dynamic>{};

    if (joined == 'projects/42/merge_requests/12' && method == 'GET') {
      return jsonResponse({'iid': 12, 'sha': currentHead});
    }
    if (joined == 'projects/42/merge_requests/12/draft_notes') {
      if (method == 'GET') {
        final gate = draftReadGate;
        draftReadGate = null;
        if (gate != null) await gate.future;
        if (published && failReadAfterPublish) {
          return jsonResponse({'message': 'readback failed'}, status: 500);
        }
        return jsonResponse(drafts.values.toList());
      }
      if (method == 'POST') {
        if (uncertainCreate) {
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.connectionError,
          );
        }
        final id = ++nextId;
        final value = <String, dynamic>{
          'id': id,
          'author_id': 7,
          'merge_request_id': 12,
          'note': body['note'],
          'commit_id': body['commit_id'],
          'position': null,
        };
        drafts[id] = value;
        return jsonResponse(value, status: 201);
      }
    }
    if (joined == 'projects/42/merge_requests/12/draft_notes/bulk_publish' &&
        method == 'POST') {
      drafts.clear();
      published = true;
      return ResponseBody.fromString('', 204);
    }
    if (path.length == 6 &&
        path.take(5).join('/') == 'projects/42/merge_requests/12/draft_notes') {
      final id = int.parse(path.last);
      final value = drafts[id];
      if (value == null) return jsonResponse({'message': '404'}, status: 404);
      if (method == 'GET') return jsonResponse(value);
      if (method == 'PUT') {
        value['note'] = body['note'];
        return jsonResponse(value);
      }
      if (method == 'DELETE') {
        drafts.remove(id);
        return ResponseBody.fromString('', 204);
      }
    }
    return jsonResponse({'message': '$method $joined'}, status: 404);
  }

  bool published = false;
}

Account _alternateAccount(_DraftFixture fixture) => Account(
  instance: fixture.api.instance,
  user: const GitLabUser(id: 8, username: 'other', name: 'Other'),
  token: 'other-synthetic-test-token',
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('MR overview exposes the draft review workflow', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      _host(
        WorkItemPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          resource: 'merge_requests',
          iid: 12,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.byKey(const ValueKey('mr-draft-review-btn')), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '審查草稿'), findsOneWidget);
    expect(fixture.unhandled, isEmpty);
  });

  testWidgets('server drafts can be created, edited and discarded', (
    tester,
  ) async {
    final fixture = _DraftFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('先處理空值，再補測試。'), findsOneWidget);
    expect(find.textContaining('只有你看得到這些尚未發布的留言'), findsOneWidget);

    await tester.tap(find.byTooltip('新增審查草稿'));
    await settleNetworkWidgets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-note')),
      '新增的審查意見',
    );
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    expect(fixture.drafts.values.any((v) => v['note'] == '新增的審查意見'), isTrue);
    final create = fixture.adapter.requests.lastWhere(
      (r) => r.method == 'POST' && r.uri.path.endsWith('/draft_notes'),
    );
    expect((create.data as Map)['commit_id'], _head);

    await tester.tap(find.byTooltip('草稿操作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('編輯'));
    await settleNetworkWidgets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-note')),
      '修正後的審查意見',
    );
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);
    expect(find.text('修正後的審查意見'), findsOneWidget);

    await tester.tap(find.byTooltip('草稿操作').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('捨棄'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '#6');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await settleNetworkWidgets(tester);
    expect(fixture.drafts.containsKey(6), isFalse);
    expect(find.text('修正後的審查意見'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale MR head blocks writes and keeps editor content', (
    tester,
  ) async {
    final fixture = _DraftFixture()..currentHead = _newHead;
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    await tester.tap(find.byTooltip('新增審查草稿'));
    await settleNetworkWidgets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-note')),
      '不能送到舊版本',
    );
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);

    expect(find.text('合併請求已有新版本'), findsOneWidget);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('editor-note')))
          .controller!
          .text,
      '不能送到舊版本',
    );
    expect(
      fixture.adapter.requests.where(
        (r) => r.method == 'POST' && r.uri.path.endsWith('/draft_notes'),
      ),
      isEmpty,
    );
  });

  testWidgets('uncertain create is sent once and requires explicit readback', (
    tester,
  ) async {
    final fixture = _DraftFixture()..uncertainCreate = true;
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    await tester.tap(find.byTooltip('新增審查草稿'));
    await settleNetworkWidgets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-note')),
      '結果不確定也不能重送',
    );
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);

    expect(find.text('尚未確認操作結果'), findsOneWidget);
    expect(
      fixture.adapter.requests.where(
        (r) => r.method == 'POST' && r.uri.path.endsWith('/draft_notes'),
      ),
      hasLength(1),
    );
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('editor-note')))
          .controller!
          .text,
      '結果不確定也不能重送',
    );
  });

  testWidgets('bulk publish confirms count, accepts 204 and reads back', (
    tester,
  ) async {
    final fixture = _DraftFixture();
    fixture.drafts[6] = {
      'id': 6,
      'author_id': 7,
      'merge_request_id': 12,
      'note': '第二則',
      'commit_id': _head,
      'position': null,
    };
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    await tester.tap(find.widgetWithText(FilledButton, '發布 2 則'));
    await tester.pumpAndSettle();
    expect(find.text('發布伺服器上的 2 則審查草稿？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await settleNetworkWidgets(tester);

    expect(fixture.drafts, isEmpty);
    expect(find.text('沒有審查草稿'), findsOneWidget);
    expect(
      fixture.adapter.requests.where(
        (r) => r.method == 'POST' && r.uri.path.endsWith('/bulk_publish'),
      ),
      hasLength(1),
    );
    expect(
      fixture.adapter.requests
          .where(
            (r) => r.method == 'GET' && r.uri.path.endsWith('/draft_notes'),
          )
          .length,
      greaterThanOrEqualTo(2),
      reason: 'A successful no-body publish must be confirmed by a fresh read.',
    );
  });

  testWidgets('publish aborts when server drafts change after confirmation', (
    tester,
  ) async {
    final fixture = _DraftFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    await tester.tap(find.widgetWithText(FilledButton, '發布 1 則'));
    await settleNetworkWidgets(tester);
    expect(find.text('發布伺服器上的 1 則審查草稿？'), findsOneWidget);

    fixture.drafts[5]!['note'] = '另一台裝置已修改內容';
    fixture.drafts[6] = {
      'id': 6,
      'author_id': 7,
      'merge_request_id': 12,
      'note': '另一台裝置新增的草稿',
      'commit_id': _head,
      'position': null,
    };
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await settleNetworkWidgets(tester);

    expect(find.text('伺服器上的審查草稿已變更'), findsOneWidget);
    expect(find.text('2 則待發布'), findsOneWidget);
    expect(
      fixture.adapter.requests.where(
        (request) =>
            request.method == 'POST' &&
            request.uri.path.endsWith('/bulk_publish'),
      ),
      isEmpty,
    );
  });

  testWidgets('resolve target change after confirmation blocks publish', (
    tester,
  ) async {
    final fixture = _DraftFixture();
    fixture.drafts[5]!['resolve_discussion'] = false;
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    await tester.tap(find.widgetWithText(FilledButton, '發布 1 則'));
    await settleNetworkWidgets(tester);
    fixture.drafts[5]!['resolve_discussion'] = true;
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await settleNetworkWidgets(tester);

    expect(find.text('伺服器上的審查草稿已變更'), findsOneWidget);
    expect(
      fixture.adapter.requests.where(
        (request) =>
            request.method == 'POST' &&
            request.uri.path.endsWith('/bulk_publish'),
      ),
      isEmpty,
    );
  });

  testWidgets('account switch dismisses owned discard dialog without delete', (
    tester,
  ) async {
    final oldFixture = _DraftFixture();
    final newFixture = _DraftFixture();
    newFixture.drafts[5]!['note'] = '新帳號的草稿';
    addTearDown(oldFixture.api.close);
    addTearDown(newFixture.api.close);
    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: oldFixture.account,
          api: oldFixture.api,
          project: oldFixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    await tester.tap(find.byTooltip('草稿操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('捨棄'));
    await tester.pumpAndSettle();
    expect(find.text('捨棄審查草稿 #5？'), findsOneWidget);

    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: _alternateAccount(newFixture),
          api: newFixture.api,
          project: newFixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('捨棄審查草稿 #5？'), findsNothing);
    expect(find.text('新帳號的草稿'), findsOneWidget);
    expect(
      oldFixture.adapter.requests.where(
        (request) =>
            request.method == 'DELETE' &&
            request.uri.path.endsWith('/draft_notes/5'),
      ),
      isEmpty,
    );
  });

  testWidgets('account switch dismisses owned editor without creating draft', (
    tester,
  ) async {
    final oldFixture = _DraftFixture();
    final newFixture = _DraftFixture();
    newFixture.drafts[5]!['note'] = '新帳號仍安全';
    addTearDown(oldFixture.api.close);
    addTearDown(newFixture.api.close);
    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: oldFixture.account,
          api: oldFixture.api,
          project: oldFixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('新增審查草稿'));
    await settleNetworkWidgets(tester);
    await tester.enterText(
      find.byKey(const ValueKey('editor-note')),
      '舊帳號未送出的內容',
    );

    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: _alternateAccount(newFixture),
          api: newFixture.api,
          project: newFixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('新增審查草稿'), findsNothing);
    expect(find.text('新帳號仍安全'), findsOneWidget);
    expect(
      oldFixture.adapter.requests.where(
        (request) =>
            request.method == 'POST' &&
            request.uri.path.endsWith('/draft_notes'),
      ),
      isEmpty,
    );
  });

  testWidgets('pending old-account read cannot replace new-account state', (
    tester,
  ) async {
    final oldFixture = _DraftFixture();
    final newFixture = _DraftFixture();
    newFixture.drafts[5]!['note'] = '只屬於新帳號';
    addTearDown(oldFixture.api.close);
    addTearDown(newFixture.api.close);
    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: oldFixture.account,
          api: oldFixture.api,
          project: oldFixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    final gate = Completer<void>();
    oldFixture.draftReadGate = gate;
    await tester.tap(find.widgetWithText(FilledButton, '發布 1 則'));
    await tester.pump();

    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: _alternateAccount(newFixture),
          api: newFixture.api,
          project: newFixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    gate.complete();
    await settleNetworkWidgets(tester);

    expect(find.text('只屬於新帳號'), findsOneWidget);
    expect(find.text('先處理空值，再補測試。'), findsNothing);
    expect(
      oldFixture.adapter.requests.where(
        (request) =>
            request.method == 'POST' &&
            request.uri.path.endsWith('/bulk_publish'),
      ),
      isEmpty,
    );
  });

  testWidgets('accepted publish with failed readback never reports success', (
    tester,
  ) async {
    final fixture = _DraftFixture()..failReadAfterPublish = true;
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    await tester.tap(find.widgetWithText(FilledButton, '發布 1 則'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await settleNetworkWidgets(tester);

    expect(fixture.published, isTrue);
    expect(find.text('發布已送出，尚未確認結果'), findsOneWidget);
    expect(find.text('已發布 1 則審查草稿'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('publish-draft-review')),
          )
          .onPressed,
      isNull,
    );

    fixture.failReadAfterPublish = false;
    await tester.tap(find.byTooltip('重新整理審查草稿'));
    await settleNetworkWidgets(tester);
    expect(find.text('沒有審查草稿'), findsOneWidget);
    expect(
      fixture.adapter.requests.where(
        (request) =>
            request.method == 'POST' &&
            request.uri.path.endsWith('/bulk_publish'),
      ),
      hasLength(1),
    );
  });

  testWidgets(
    'repeated continuation cursor fails without duplicate page loop',
    (tester) async {
      var reads = 0;
      late final GitLabApi api;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/draft_notes')) {
          reads++;
          return jsonResponse(
            [
              {
                'id': reads,
                'note': 'page $reads',
                'commit_id': _head,
                'position': null,
              },
            ],
            headers: {
              'x-next-page': ['2'],
            },
          );
        }
        return jsonResponse({'message': 'unexpected'}, status: 404);
      });
      api = testApi(adapter);
      addTearDown(api.close);
      final account = Account(
        instance: api.instance,
        user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
        token: 'synthetic-test-token',
      );
      const project = Project(
        id: 42,
        name: 'Mobile Workspace',
        path: 'studio/mobile-workspace',
        visibility: 'private',
        defaultBranch: 'main',
        archived: false,
      );

      await tester.pumpWidget(
        _host(
          DraftReviewPage(
            account: account,
            api: api,
            project: project,
            iid: 12,
            headSha: _head,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      expect(reads, 2);
      expect(find.text('無法讀取回應'), findsOneWidget);
    },
  );

  testWidgets('large draft list lazily builds only the visible viewport', (
    tester,
  ) async {
    final fixture = _DraftFixture();
    fixture.drafts
      ..clear()
      ..addEntries(
        List.generate(600, (index) {
          final id = index + 1;
          return MapEntry(id, {
            'id': id,
            'author_id': 7,
            'merge_request_id': 12,
            'note': '審查草稿 $id',
            'commit_id': _head,
            'position': null,
          });
        }),
      );
    addTearDown(fixture.api.close);

    await tester.pumpWidget(
      _host(
        DraftReviewPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          iid: 12,
          headSha: _head,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('600 則待發布'), findsOneWidget);
    expect(
      tester.widget<ListView>(find.byType(ListView)).childrenDelegate,
      isA<SliverChildBuilderDelegate>(),
    );
    expect(find.byType(Card).evaluate().length, lessThan(20));
    expect(find.text('審查草稿 600'), findsNothing);
  });
}
