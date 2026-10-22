import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';

import 'support/workspace_fixture.dart';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'invalid owner suppresses pending timer and dispose persistence',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      var current = true;
      await tester.pumpWidget(
        MaterialApp(
          home: ResourceEditor(
            account: fixture.account,
            title: '新增留言',
            resource: 'invalid-owner-comment',
            isCurrent: () => current,
            fields: const [EditField('body', '留言內容', required: true)],
            save: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField),
        'Synthetic pending draft',
      );
      current = false;
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
    },
  );

  testWidgets(
    'disposing invalidated editor cannot recreate cleared account draft',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: ResourceEditor(
            account: fixture.account,
            title: '新增留言',
            resource: 'removed-account-comment',
            fields: const [EditField('body', '留言內容', required: true)],
            save: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField),
        'Synthetic private draft',
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(await const FlutterSecureStorage().readAll(), isNotEmpty);
      await clearSecureDrafts(fixture.account);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(await const FlutterSecureStorage().readAll(), isEmpty);
    },
  );

  testWidgets('a fresh editor can save drafts after an earlier account clear', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await clearSecureDrafts(fixture.account);
    await tester.pumpWidget(
      MaterialApp(
        home: ResourceEditor(
          account: fixture.account,
          title: '新增留言',
          resource: 'fresh-after-clear',
          fields: const [EditField('body', '留言內容', required: true)],
          save: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Synthetic fresh draft');
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      (await const FlutterSecureStorage().readAll()).values.single,
      '{"body":"Synthetic fresh draft"}',
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('plain Markdown keeps formatting and hides project tools', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: ResourceEditor(
          account: fixture.account,
          title: '群組留言',
          resource: 'group-markdown-tools',
          persistent: false,
          projectToolsEnabled: false,
          fields: const [EditField('body', '留言內容', markdown: true)],
          save: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('粗體'), findsOneWidget);
    expect(find.byTooltip('提及'), findsNothing);
    expect(find.byTooltip('附加圖片'), findsNothing);
    expect(find.byTooltip('附加檔案'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'uncertain creation blocks repeat save and preserves editable draft',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      var calls = 0;
      const resource = 'work-item-comment-uncertain';
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => openEditor(
                  context,
                  account: fixture.account,
                  title: '新增留言',
                  resource: resource,
                  blockRetryOnWriteUncertain: true,
                  fields: const [EditField('body', '留言內容', required: true)],
                  save: (_) async {
                    calls++;
                    throw const ApiFailure(FailureKind.writeUncertain);
                  },
                ),
                child: const Text('開啟編輯器'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('開啟編輯器'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'First comment');
      await tester.tap(find.byKey(const Key('editorSave')));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('editorSave')))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byType(TextFormField), 'Kept comment draft');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(
        find.byKey(const Key('editorSave')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(calls, 1);
      await tester.tap(find.byTooltip('保留草稿並返回'));
      await tester.pumpAndSettle();
      expect(find.text('開啟編輯器'), findsOneWidget);
      final key =
          'draft.v2.${base64Url.encode(utf8.encode(fixture.account.key))}.${base64Url.encode(utf8.encode(resource))}';
      final stored = await const FlutterSecureStorage().read(key: key);
      expect(jsonDecode(stored!), {'body': 'Kept comment draft', '__writeUncertain': 'true'});
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('definitive validation failure still permits correction', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ResourceEditor(
          account: fixture.account,
          title: '新增留言',
          resource: 'work-item-comment-validation',
          persistent: false,
          blockRetryOnWriteUncertain: true,
          fields: const [
            EditField('body', '留言內容', required: true, value: 'Comment'),
          ],
          save: (_) async {
            calls++;
            throw const ApiFailure(FailureKind.validation);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editorSave')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('editorSave')))
          .onPressed,
      isNotNull,
    );
    await tester.enterText(find.byType(TextFormField), 'Corrected comment');
    await tester.tap(find.byKey(const Key('editorSave')));
    await tester.pumpAndSettle();
    expect(calls, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('uncertain retry guard is opt in for existing editors', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ResourceEditor(
          account: fixture.account,
          title: 'Existing editor',
          resource: 'existing-editor',
          persistent: false,
          fields: const [EditField('body', 'Content', value: 'Comment')],
          save: (_) async {
            calls++;
            throw const ApiFailure(FailureKind.writeUncertain);
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editorSave')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('editorSave')))
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
