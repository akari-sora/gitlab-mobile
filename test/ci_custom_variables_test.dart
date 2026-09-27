import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost, settleWorkspace;

void main() {
  group('createPipeline API variables integration', () {
    test('createPipeline without variables sends only ref', () async {
      late RequestOptions captured;
      final adapter = FakeAdapter((options) {
        captured = options;
        return jsonResponse({'id': 101, 'ref': 'main', 'status': 'created'});
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final res = await api.createPipeline(42, 'main');
      expect(res['id'], 101);
      expect(captured.method, 'POST');
      expect(captured.uri.path, endsWith('/api/v4/projects/42/pipeline'));
      final data = captured.data as Map<String, dynamic>;
      expect(data['ref'], 'main');
      expect(data.containsKey('variables'), isFalse);
    });

    test('createPipeline with variables sends formatted key-value array', () async {
      late RequestOptions captured;
      final adapter = FakeAdapter((options) {
        captured = options;
        return jsonResponse({'id': 102, 'ref': 'release/v1.0', 'status': 'created'});
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final variables = [
        {'key': 'ENV_TARGET', 'value': 'staging', 'variable_type': 'env_var'},
        {'key': 'CONFIG_JSON', 'value': '{"debug":true}', 'variable_type': 'file'},
      ];
      final res = await api.createPipeline(42, 'release/v1.0', variables: variables);
      expect(res['id'], 102);
      expect(captured.method, 'POST');
      final data = captured.data as Map<String, dynamic>;
      expect(data['ref'], 'release/v1.0');
      expect(data['variables'], variables);
    });
  });

  group('RunPipelineDialog widget tests', () {
    late WorkspaceFixture fixture;

    setUp(() {
      fixture = WorkspaceFixture();
    });

    tearDown(() {
      fixture.api.close();
    });

    testWidgets('renders initial dialog with project path and empty variables', (tester) async {
      int? resultId;
      await tester.pumpWidget(workspaceHost(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              resultId = await showDialog<int>(
                context: context,
                builder: (_) => RunPipelineDialog(
                  account: fixture.account,
                  api: fixture.api,
                  project: fixture.project,
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ));
      await settleWorkspace(tester);
      await tester.tap(find.text('Open'));
      await settleWorkspace(tester);

      expect(find.text('執行 Pipeline'), findsOneWidget);
      expect(find.text(fixture.project.path), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-ref')), findsOneWidget);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('CI 變數 (0)'), findsOneWidget);
      expect(find.text('未設定自訂 CI 變數'), findsOneWidget);
      expect(find.byKey(const Key('editorSave')), findsOneWidget);

      // Verify touch targets >= 48dp
      final addBtn = tester.getRect(find.byKey(const Key('add-ci-variable')));
      expect(addBtn.height, greaterThanOrEqualTo(48.0));
      final saveBtn = tester.getRect(find.byKey(const Key('editorSave')));
      expect(saveBtn.height, greaterThanOrEqualTo(48.0));

      await tester.tap(find.text('取消'));
      await settleWorkspace(tester);
      expect(resultId, isNull);
    });

    testWidgets('add and remove CI variables dynamically with >=48dp touch targets', (tester) async {
      await tester.pumpWidget(workspaceHost(
        RunPipelineDialog(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
        ),
      ));
      await settleWorkspace(tester);

      // Tap add variable
      await tester.tap(find.byKey(const Key('add-ci-variable')));
      await settleWorkspace(tester);

      expect(find.text('CI 變數 (1)'), findsOneWidget);
      expect(find.text('變數 #1'), findsOneWidget);
      expect(find.byKey(const ValueKey('ci-var-key-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('ci-var-val-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('ci-var-type-0')), findsOneWidget);

      // Check delete button touch target >= 48x48dp
      final removeBtn = tester.getRect(find.byKey(const ValueKey('ci-var-remove-0')));
      expect(removeBtn.width, greaterThanOrEqualTo(48.0));
      expect(removeBtn.height, greaterThanOrEqualTo(48.0));

      // Tap add second variable
      await tester.tap(find.byKey(const Key('add-ci-variable')));
      await settleWorkspace(tester);
      expect(find.text('CI 變數 (2)'), findsOneWidget);
      expect(find.text('變數 #2'), findsOneWidget);

      // Remove the first variable
      await tester.tap(find.byKey(const ValueKey('ci-var-remove-0')));
      await settleWorkspace(tester);
      expect(find.text('CI 變數 (1)'), findsOneWidget);
      expect(find.text('變數 #1'), findsOneWidget);
    });

    testWidgets('filters empty variables on submit', (tester) async {
      RequestOptions? captured;
      final adapter = FakeAdapter((options) {
        if (options.uri.path.endsWith('/pipeline') && options.method == 'POST') {
          captured = options;
          return jsonResponse({'id': 888, 'ref': 'main', 'status': 'created'});
        }
        return jsonResponse({});
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      int? resultId;
      await tester.pumpWidget(workspaceHost(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              resultId = await showDialog<int>(
                context: context,
                builder: (_) => RunPipelineDialog(
                  account: fixture.account,
                  api: api,
                  project: fixture.project,
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ));
      await settleWorkspace(tester);
      await tester.tap(find.text('Open'));
      await settleWorkspace(tester);

      // Add a variable but leave it completely empty
      await tester.tap(find.byKey(const Key('add-ci-variable')));
      await settleWorkspace(tester);

      // Submit
      await tester.tap(find.byKey(const Key('editorSave')));
      await settleWorkspace(tester);

      expect(resultId, 888);
      expect(captured, isNotNull);
      final data = captured!.data as Map<String, dynamic>;
      expect(data['ref'], 'main');
      expect(data.containsKey('variables'), isFalse);
    });

    testWidgets('validates empty key when value is present', (tester) async {
      await tester.pumpWidget(workspaceHost(
        RunPipelineDialog(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
        ),
      ));
      await settleWorkspace(tester);

      // Add variable and enter value only
      await tester.tap(find.byKey(const Key('add-ci-variable')));
      await settleWorkspace(tester);
      await tester.enterText(find.byKey(const ValueKey('ci-var-val-0')), 'some_value');
      await settleWorkspace(tester);

      // Tap run
      await tester.tap(find.byKey(const Key('editorSave')));
      await settleWorkspace(tester);

      expect(find.text('變數名稱不可為空'), findsOneWidget);
    });

    testWidgets('validates invalid variable key format', (tester) async {
      await tester.pumpWidget(workspaceHost(
        RunPipelineDialog(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
        ),
      ));
      await settleWorkspace(tester);

      // Add variable and enter invalid key (starting with number)
      await tester.tap(find.byKey(const Key('add-ci-variable')));
      await settleWorkspace(tester);
      await tester.enterText(find.byKey(const ValueKey('ci-var-key-0')), '1INVALID_KEY');
      await tester.enterText(find.byKey(const ValueKey('ci-var-val-0')), 'val');
      await settleWorkspace(tester);

      await tester.tap(find.byKey(const Key('editorSave')));
      await settleWorkspace(tester);

      expect(find.text('變數名稱格式不合（僅限英數字與底線，不可為數字開頭）'), findsOneWidget);

      // Change key to one with spaces
      await tester.enterText(find.byKey(const ValueKey('ci-var-key-0')), 'INVALID KEY');
      await tester.tap(find.byKey(const Key('editorSave')));
      await settleWorkspace(tester);
      expect(find.text('變數名稱格式不合（僅限英數字與底線，不可為數字開頭）'), findsOneWidget);
    });

    testWidgets('validates duplicate variable keys', (tester) async {
      await tester.pumpWidget(workspaceHost(
        RunPipelineDialog(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
        ),
      ));
      await settleWorkspace(tester);

      // Add two variables with same key
      await tester.tap(find.byKey(const Key('add-ci-variable')));
      await settleWorkspace(tester);
      await tester.enterText(find.byKey(const ValueKey('ci-var-key-0')), 'DUPLICATE_KEY');
      await tester.enterText(find.byKey(const ValueKey('ci-var-val-0')), 'val1');

      await tester.tap(find.byKey(const Key('add-ci-variable')));
      await settleWorkspace(tester);
      await tester.enterText(find.byKey(const ValueKey('ci-var-key-1')), 'DUPLICATE_KEY');
      await tester.enterText(find.byKey(const ValueKey('ci-var-val-1')), 'val2');
      await settleWorkspace(tester);

      await tester.tap(find.byKey(const Key('editorSave')));
      await settleWorkspace(tester);

      expect(find.text('變數名稱重複'), findsOneWidget);
    });

    testWidgets('submits custom variables with env_var and file types successfully', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 1200);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      RequestOptions? captured;
      final adapter = FakeAdapter((options) {
        if (options.uri.path.endsWith('/pipeline') && options.method == 'POST') {
          captured = options;
          return jsonResponse({'id': 999, 'ref': 'release-branch', 'status': 'created'});
        }
        return jsonResponse({});
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      int? resultId;
      await tester.pumpWidget(workspaceHost(
        Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              resultId = await showDialog<int>(
                context: context,
                builder: (_) => RunPipelineDialog(
                  account: fixture.account,
                  api: api,
                  project: fixture.project,
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ));
      await settleWorkspace(tester);
      await tester.tap(find.text('Open'));
      await settleWorkspace(tester);

      // Set ref
      await tester.enterText(find.byKey(const ValueKey('editor-ref')), 'release-branch');

      // Add first variable (env_var)
      await tester.tap(find.byKey(const Key('add-ci-variable')));
      await settleWorkspace(tester);
      await tester.enterText(find.byKey(const ValueKey('ci-var-key-0')), 'DEPLOY_STAGE');
      await tester.enterText(find.byKey(const ValueKey('ci-var-val-0')), 'production');

      // Add second variable (file)
      await tester.tap(find.byKey(const Key('add-ci-variable')));
      await settleWorkspace(tester);
      await tester.enterText(find.byKey(const ValueKey('ci-var-key-1')), 'SERVICE_KEY_FILE');
      await tester.enterText(find.byKey(const ValueKey('ci-var-val-1')), 'secret_content_xyz');

      // Select file type for second variable
      await tester.ensureVisible(find.byKey(const ValueKey('ci-var-type-1')));
      await tester.tap(find.byKey(const ValueKey('ci-var-type-1')));
      await settleWorkspace(tester);
      await tester.tap(find.text('file (檔案)').last);
      await settleWorkspace(tester);

      // Save
      await tester.ensureVisible(find.byKey(const Key('editorSave')));
      await tester.tap(find.byKey(const Key('editorSave')));
      await settleWorkspace(tester);

      expect(resultId, 999);
      expect(captured, isNotNull);
      final data = captured!.data as Map<String, dynamic>;
      expect(data['ref'], 'release-branch');
      expect(data['variables'], [
        {'key': 'DEPLOY_STAGE', 'value': 'production', 'variable_type': 'env_var'},
        {'key': 'SERVICE_KEY_FILE', 'value': 'secret_content_xyz', 'variable_type': 'file'},
      ]);
    });

    testWidgets('shows error when pipeline creation fails', (tester) async {
      final adapter = FakeAdapter((options) {
        if (options.uri.path.endsWith('/pipeline') && options.method == 'POST') {
          return jsonResponse({'message': 'Reference not found'}, status: 400);
        }
        return jsonResponse({});
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(workspaceHost(
        RunPipelineDialog(
          account: fixture.account,
          api: api,
          project: fixture.project,
        ),
      ));
      await settleWorkspace(tester);

      await tester.tap(find.byKey(const Key('editorSave')));
      await settleWorkspace(tester);

      expect(find.byKey(const Key('editorSave')), findsOneWidget);
    });
  });
}
