import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace;

Widget _host(Widget child) => MaterialApp(
      theme: appTheme(Brightness.light),
      locale: const Locale('zh', 'TW'),
      supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: child,
    );

void _surface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('quick action chips render on issue comment editor and insert command on tap', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    Map<String, String>? submittedValues;

    await tester.pumpWidget(_host(Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => openEditor(
              context,
              account: fixture.account,
              title: '新增留言',
              resource: 'projects/1/issues/10/root/new',
              subtitle: 'my-org/my-repo · #10',
              fields: [
                const EditField(
                  'body',
                  '留言內容',
                  required: true,
                  lines: 9,
                  markdown: true,
                  quickActions: true,
                ),
              ],
              save: (values) async {
                submittedValues = values;
              },
            ),
            child: const Text('打開編輯器'),
          ),
        ),
      ),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('打開編輯器'));
    await settleWorkspace(tester);

    // Issue quick action chips are present
    expect(find.byKey(const ValueKey('quick-action-/close')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-action-/reopen')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-action-/assign_@me')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-action-/spend_1h')), findsOneWidget);

    // Tap on /close chip
    final closeChip = find.byKey(const ValueKey('quick-action-/close'));
    await tester.ensureVisible(closeChip);
    await tester.tap(closeChip);
    await tester.pump();

    // Verify indicator appears
    expect(find.text('包含快捷指令：'), findsOneWidget);
    expect(find.text('/close'), findsWidgets);

    // TextField contains /close\n
    final textField = tester.widget<TextFormField>(find.byKey(const ValueKey('editor-body')));
    expect(textField.controller?.text, '/close\n');

    // Tap on /spend 1h chip
    final spendChip = find.byKey(const ValueKey('quick-action-/spend_1h'));
    await tester.ensureVisible(spendChip);
    await tester.tap(spendChip);
    await tester.pump();

    expect(textField.controller?.text, '/close\n/spend 1h\n');
    expect(find.text('/spend'), findsOneWidget);

    // Submit
    await tester.tap(find.byKey(const Key('editorSave')));
    await settleWorkspace(tester);

    expect(submittedValues, isNotNull);
    expect(submittedValues!['body'], '/close\n/spend 1h\n');

    await _finish(tester);
  });

  testWidgets('MR comment editor shows MR quick action chips including /approve and /ready', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    await tester.pumpWidget(_host(Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => openEditor(
              context,
              account: fixture.account,
              title: '新增留言',
              resource: 'projects/1/merge_requests/42/root/new',
              subtitle: 'my-org/my-repo · !42',
              fields: [
                const EditField(
                  'body',
                  '留言內容',
                  required: true,
                  lines: 9,
                  markdown: true,
                  quickActions: true,
                ),
              ],
              save: (values) async {},
            ),
            child: const Text('打開 MR 編輯器'),
          ),
        ),
      ),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('打開 MR 編輯器'));
    await settleWorkspace(tester);

    // MR quick action chips are present
    expect(find.byKey(const ValueKey('quick-action-/approve')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-action-/ready')), findsOneWidget);
    expect(find.byKey(const ValueKey('quick-action-/draft')), findsOneWidget);

    // Tap on /approve
    await tester.tap(find.byKey(const ValueKey('quick-action-/approve')));
    await tester.pump();

    final textField = tester.widget<TextFormField>(find.byKey(const ValueKey('editor-body')));
    expect(textField.controller?.text, '/approve\n');
    expect(find.text('包含快捷指令：'), findsOneWidget);

    await _finish(tester);
  });

  testWidgets('quick actions toolbar button opens sheet and allows selecting any categorized command', (tester) async {
    _surface(tester);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);

    await tester.pumpWidget(_host(Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => openEditor(
              context,
              account: fixture.account,
              title: '新增留言',
              resource: 'projects/1/issues/10/root/new',
              subtitle: 'my-org/my-repo · #10',
              fields: [
                const EditField(
                  'body',
                  '留言內容',
                  required: true,
                  lines: 9,
                  markdown: true,
                  quickActions: true,
                ),
              ],
              save: (values) async {},
            ),
            child: const Text('打開選單編輯器'),
          ),
        ),
      ),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('打開選單編輯器'));
    await settleWorkspace(tester);

    // Find and tap the quick actions toolbar button
    final quickActionBtn = find.byKey(const ValueKey('editor-quick-actions-btn'));
    expect(quickActionBtn, findsOneWidget);
    await tester.ensureVisible(quickActionBtn);
    await tester.tap(quickActionBtn);
    await tester.pumpAndSettle();

    // Bottom sheet is shown
    expect(find.text('快捷指令 (Quick Actions)'), findsOneWidget);
    expect(find.text('狀態'), findsOneWidget);
    expect(find.text('指派與審查'), findsOneWidget);

    final timeItem = find.text('工時追蹤');
    await tester.scrollUntilVisible(timeItem, 100, scrollable: find.byType(Scrollable).last);
    expect(timeItem, findsOneWidget);

    // Tap on /lock item
    final lockItem = find.byKey(const ValueKey('sheet-action-/lock'));
    await tester.scrollUntilVisible(lockItem, 100, scrollable: find.byType(Scrollable).last);
    expect(lockItem, findsOneWidget);
    await tester.tap(lockItem);
    await tester.pumpAndSettle();

    // Sheet dismissed, text inserted
    final textField = tester.widget<TextFormField>(find.byKey(const ValueKey('editor-body')));
    expect(textField.controller?.text, '/lock\n');
    expect(find.text('包含快捷指令：'), findsOneWidget);

    await _finish(tester);
  });
}
