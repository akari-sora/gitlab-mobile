import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _baseSha = '1111111111111111111111111111111111111111';
const _startSha = '2222222222222222222222222222222222222222';
const _headSha = '3333333333333333333333333333333333333333';
const _newHeadSha = '4444444444444444444444444444444444444444';

Widget _host(Widget child) => MaterialApp(
  theme: appTheme(Brightness.light),
  locale: const Locale('zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: Scaffold(body: child),
);

class _DiffDraftFixture {
  _DiffDraftFixture({this.currentHead = _headSha}) {
    adapter = FakeAdapter(respond);
    api = testApi(adapter);
  }

  late final FakeAdapter adapter;
  late final GitLabApi api;
  String currentHead;
  Map<String, dynamic>? postedDraft;
  var postedDiscussionCount = 0;
  var published = false;
  final drafts = <Map<String, dynamic>>[];

  Account get account => Account(
    instance: api.instance,
    user: const GitLabUser(id: 7, username: 'reviewer', name: 'Reviewer'),
    token: 'synthetic-test-token',
  );

  Project get project => const Project(
    id: 42,
    name: 'Project',
    path: 'group/project',
    visibility: 'private',
    defaultBranch: 'main',
    archived: false,
  );

  Map<String, dynamic> get version => {
    'id': 1,
    'head_commit_sha': _headSha,
    'base_commit_sha': _baseSha,
    'start_commit_sha': _startSha,
    'diffs': [
      {
        'old_path': 'lib/sample.dart',
        'new_path': 'lib/sample.dart',
        'new_file': false,
        'renamed_file': false,
        'deleted_file': false,
        'diff': '''
@@ -1,2 +1,2 @@
 line1
-old_line2
+new_line2
''',
      },
    ],
  };

  FutureOr<ResponseBody> respond(RequestOptions request) {
    final path = request.uri.path;
    final method = request.method;
    if (path.endsWith('/merge_requests/10/versions')) {
      return jsonResponse([
        {'id': 1, 'head_commit_sha': _headSha},
      ]);
    }
    if (path.endsWith('/merge_requests/10/versions/1')) {
      return jsonResponse(version);
    }
    if (path.endsWith('/merge_requests/10') && method == 'GET') {
      return jsonResponse({'iid': 10, 'sha': currentHead});
    }
    if (path.endsWith('/merge_requests/10/discussions')) {
      if (method == 'GET') return jsonResponse([]);
      if (method == 'POST') {
        postedDiscussionCount++;
        return jsonResponse({
          'id': 'discussion-1',
          'notes': <dynamic>[],
        }, status: 201);
      }
    }
    if (path.endsWith('/merge_requests/10/draft_notes/bulk_publish') &&
        method == 'POST') {
      drafts.clear();
      published = true;
      return ResponseBody.fromString('', 204);
    }
    if (path.endsWith('/merge_requests/10/draft_notes')) {
      if (method == 'GET') return jsonResponse(drafts);
      if (method == 'POST') {
        postedDraft = Map<String, dynamic>.from(request.data as Map);
        final draft = {
          'id': drafts.length + 1,
          'author_id': 7,
          'merge_request_id': 10,
          'note': postedDraft!['note'],
          'commit_id': _headSha,
          'position': postedDraft!['position'],
        };
        drafts.add(draft);
        return jsonResponse(draft, status: 201);
      }
    }
    return jsonResponse({'message': '$method $path'}, status: 404);
  }
}

Future<void> _openLineComposer(
  WidgetTester tester,
  _DiffDraftFixture fixture,
) async {
  await tester.pumpWidget(
    _host(
      ReviewDiffPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        iid: 10,
        expectedSha: _headSha,
      ),
    ),
  );
  await settleNetworkWidgets(tester);
  await tester.tap(find.text('lib/sample.dart'));
  await settleNetworkWidgets(tester);
  await tester.tap(find.text('new_line2'));
  await settleNetworkWidgets(tester);
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('inline composer posts an exact positioned draft payload', (
    tester,
  ) async {
    final fixture = _DiffDraftFixture();
    addTearDown(fixture.api.close);
    await _openLineComposer(tester, fixture);

    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey('editor-toggle-draft')),
          )
          .value,
      isFalse,
      reason: 'Immediate publishing remains the compatible default.',
    );
    await tester.tap(find.byKey(const ValueKey('editor-toggle-draft')));
    await tester.enterText(
      find.byKey(const ValueKey('editor-body')),
      '先補上空值測試',
    );
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);

    expect(fixture.postedDiscussionCount, 0);
    expect(fixture.postedDraft, isNotNull);
    expect(fixture.postedDraft!.keys, unorderedEquals(['note', 'position']));
    expect(fixture.postedDraft!['note'], '先補上空值測試');
    final position = fixture.postedDraft!['position'] as Map<String, dynamic>;
    expect(position, {
      'position_type': 'text',
      'base_sha': _baseSha,
      'start_sha': _startSha,
      'head_sha': _headSha,
      'old_path': 'lib/sample.dart',
      'new_path': 'lib/sample.dart',
      'new_line': 2,
    });
    expect(find.text('已暫存，發布前只有你可見'), findsOneWidget);
  });

  testWidgets('stale head blocks positioned draft and retains editor content', (
    tester,
  ) async {
    final fixture = _DiffDraftFixture(currentHead: _newHeadSha);
    addTearDown(fixture.api.close);
    await _openLineComposer(tester, fixture);

    await tester.tap(find.byKey(const ValueKey('editor-toggle-draft')));
    await tester.enterText(
      find.byKey(const ValueKey('editor-body')),
      '這段不能送到舊版本',
    );
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleNetworkWidgets(tester);

    expect(find.text('合併請求已有新版本'), findsOneWidget);
    expect(fixture.postedDraft, isNull);
    expect(
      tester
          .widget<TextFormField>(find.byKey(const ValueKey('editor-body')))
          .controller!
          .text,
      '這段不能送到舊版本',
    );
  });

  testWidgets('diff draft entry publishes via 204 then reads back', (
    tester,
  ) async {
    final fixture = _DiffDraftFixture();
    fixture.drafts.add({
      'id': 8,
      'author_id': 7,
      'merge_request_id': 10,
      'note': '待發布的行內意見',
      'commit_id': _headSha,
      'position': {
        'position_type': 'text',
        'base_sha': _baseSha,
        'start_sha': _startSha,
        'head_sha': _headSha,
        'old_path': 'lib/sample.dart',
        'new_path': 'lib/sample.dart',
        'new_line': 2,
      },
    });
    addTearDown(fixture.api.close);

    await tester.pumpWidget(
      _host(
        ReviewDiffPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          iid: 10,
          expectedSha: _headSha,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('lib/sample.dart'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('審查草稿'));
    await settleNetworkWidgets(tester);

    expect(find.text('1 則待發布'), findsOneWidget);
    expect(find.text('lib/sample.dart · 第 2 行'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '發布 1 則'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await settleNetworkWidgets(tester);

    expect(fixture.published, isTrue);
    expect(find.text('沒有審查草稿'), findsOneWidget);
    expect(
      fixture.adapter.requests
          .where(
            (request) =>
                request.method == 'GET' &&
                request.uri.path.endsWith('/merge_requests/10/draft_notes'),
          )
          .length,
      greaterThanOrEqualTo(2),
    );
  });
}
