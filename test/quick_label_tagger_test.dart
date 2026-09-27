import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/picker_sheet.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace;

Widget _host(Widget child) => MaterialApp(
  theme: appTheme(Brightness.light),
  locale: const Locale('zh', 'TW'),
  supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  home: Scaffold(body: child),
);

void _surface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 1200);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('Quick Label Tagger in WorkItemPage', () {
    testWidgets('renders existing labels as chips with delete action and meets 48dp touch target', (tester) async {
      _surface(tester);
      final fixture = WorkspaceFixture();

      // Seed an issue with labels
      fixture.issues[1] = {
        'id': 101,
        'iid': 1,
        'title': 'Test Issue with Labels',
        'state': 'opened',
        'labels': ['bug', 'critical', 'frontend'],
        'author': {'id': 7, 'username': 'developer', 'name': 'Developer'},
        'updated_at': 'revision-1',
        'assignees': <dynamic>[],
      };

      await tester.pumpWidget(_host(
        WorkItemPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          resource: 'issues',
          iid: 1,
        ),
      ));
      await settleWorkspace(tester);

      // Verify label header
      expect(find.text('標籤'), findsOneWidget);

      // Verify "管理標籤" button and touch target >= 48dp
      final editLabelsBtn = find.byKey(const ValueKey('quick-edit-labels'));
      expect(editLabelsBtn, findsOneWidget);
      final editSize = tester.getSize(editLabelsBtn);
      expect(editSize.height, greaterThanOrEqualTo(48.0));
      expect(editSize.width, greaterThanOrEqualTo(48.0));

      // Verify chips exist
      expect(find.byKey(const ValueKey('label-chip-bug')), findsOneWidget);
      expect(find.byKey(const ValueKey('label-chip-critical')), findsOneWidget);
      expect(find.byKey(const ValueKey('label-chip-frontend')), findsOneWidget);

      // Verify "新增標籤" ActionChip exists
      expect(find.byKey(const ValueKey('quick-add-label')), findsOneWidget);
    });

    testWidgets('displays empty hint when issue has no labels', (tester) async {
      _surface(tester);
      final fixture = WorkspaceFixture();

      fixture.issues[2] = {
        'id': 102,
        'iid': 2,
        'title': 'Issue without labels',
        'state': 'opened',
        'labels': <dynamic>[],
        'author': {'id': 7, 'username': 'developer', 'name': 'Developer'},
        'updated_at': 'revision-1',
        'assignees': <dynamic>[],
      };

      await tester.pumpWidget(_host(
        WorkItemPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          resource: 'issues',
          iid: 2,
        ),
      ));
      await settleWorkspace(tester);

      expect(find.text('尚未設定標籤'), findsOneWidget);
      expect(find.byKey(const ValueKey('quick-add-label')), findsOneWidget);
    });

    testWidgets('tapping delete on label chip removes label and invokes onMutated callback', (tester) async {
      _surface(tester);
      final fixture = WorkspaceFixture();

      fixture.issues[3] = {
        'id': 103,
        'iid': 3,
        'title': 'Issue to remove label from',
        'state': 'opened',
        'labels': ['backend', 'urgent'],
        'author': {'id': 7, 'username': 'developer', 'name': 'Developer'},
        'updated_at': 'revision-1',
        'assignees': <dynamic>[],
      };

      var mutatedCalled = false;
      Map<String, dynamic>? mutatedData;

      await tester.pumpWidget(_host(
        WorkItemPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          resource: 'issues',
          iid: 3,
          onMutated: (data) {
            mutatedCalled = true;
            mutatedData = data;
          },
        ),
      ));
      await settleWorkspace(tester);

      expect(find.byKey(const ValueKey('label-chip-urgent')), findsOneWidget);

      // Find the delete button inside InputChip for 'urgent'
      final deleteIcon = find.descendant(
        of: find.byKey(const ValueKey('label-chip-urgent')),
        matching: find.byIcon(Icons.close),
      );
      expect(deleteIcon, findsOneWidget);

      await tester.tap(deleteIcon);
      await settleWorkspace(tester);

      // Verify SnackBar
      expect(find.text('已移除標籤「urgent」'), findsOneWidget);

      // Verify onMutated called
      expect(mutatedCalled, isTrue);
      expect(mutatedData, isNotNull);

      // Verify urgent label is gone from the UI
      expect(find.byKey(const ValueKey('label-chip-urgent')), findsNothing);
      expect(find.byKey(const ValueKey('label-chip-backend')), findsOneWidget);
    });

    testWidgets('works similarly on Merge Requests', (tester) async {
      _surface(tester);
      final fixture = WorkspaceFixture();

      fixture.mergeFields['labels'] = ['review-needed', 'ui'];

      var mrMutated = false;

      await tester.pumpWidget(_host(
        WorkItemPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          resource: 'merge_requests',
          iid: 12,
          onMutated: (data) => mrMutated = true,
        ),
      ));
      await settleWorkspace(tester);

      expect(find.byKey(const ValueKey('label-chip-review-needed')), findsOneWidget);
      expect(find.byKey(const ValueKey('label-chip-ui')), findsOneWidget);

      // Delete 'ui'
      final deleteIcon = find.descendant(
        of: find.byKey(const ValueKey('label-chip-ui')),
        matching: find.byIcon(Icons.close),
      );
      await tester.tap(deleteIcon);
      await settleWorkspace(tester);

      expect(find.text('已移除標籤「ui」'), findsOneWidget);
      expect(mrMutated, isTrue);
      expect(find.byKey(const ValueKey('label-chip-ui')), findsNothing);
      expect(find.byKey(const ValueKey('label-chip-review-needed')), findsOneWidget);
    });

    testWidgets('shows conflict error if record was modified concurrently', (tester) async {
      _surface(tester);
      final fixture = WorkspaceFixture();

      fixture.issues[4] = {
        'id': 104,
        'iid': 4,
        'title': 'Conflict Test Issue',
        'state': 'opened',
        'labels': ['stale-label'],
        'author': {'id': 7, 'username': 'developer', 'name': 'Developer'},
        'updated_at': 'revision-old',
        'assignees': <dynamic>[],
      };

      await tester.pumpWidget(_host(
        WorkItemPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          resource: 'issues',
          iid: 4,
        ),
      ));
      await settleWorkspace(tester);

      // Concurrently change the revision on the server
      fixture.issues[4]!['updated_at'] = 'revision-new';

      final deleteIcon = find.descendant(
        of: find.byKey(const ValueKey('label-chip-stale-label')),
        matching: find.byIcon(Icons.close),
      );
      await tester.tap(deleteIcon);
      await settleWorkspace(tester);

      // Conflict failure notice / snackbar should be displayed
      expect(find.textContaining('內容已經變更'), findsOneWidget);
    });

    testWidgets('tapping quick-edit-labels opens choice picker and updates labels', (tester) async {
      _surface(tester);
      final fixture = WorkspaceFixture();

      fixture.issues[5] = {
        'id': 105,
        'iid': 5,
        'title': 'Issue to edit via picker',
        'state': 'opened',
        'labels': <dynamic>[],
        'author': {'id': 7, 'username': 'developer', 'name': 'Developer'},
        'updated_at': 'revision-1',
        'assignees': <dynamic>[],
      };

      var mutatedCalled = false;
      Map<String, dynamic>? mutatedData;

      await tester.pumpWidget(_host(
        WorkItemPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          resource: 'issues',
          iid: 5,
          onMutated: (data) {
            mutatedCalled = true;
            mutatedData = data;
          },
        ),
      ));
      await settleWorkspace(tester);

      // Tap "新增標籤" / "quick-add-label"
      await tester.tap(find.byKey(const ValueKey('quick-add-label')));
      await settleWorkspace(tester);

      // BottomSheet ChoicePickerSheet should appear
      expect(find.byType(ChoicePickerSheet), findsOneWidget);

      // Toggle label 'a'
      final optionA = find.byKey(const ValueKey('picker-row-a'));
      expect(optionA, findsOneWidget);
      await tester.tap(optionA);
      await tester.pump();

      // Tap "完成" button
      final doneBtn = find.byKey(const Key('picker-done'));
      expect(doneBtn, findsOneWidget);
      await tester.tap(doneBtn);
      await settleWorkspace(tester);

      // Sheet should close and SnackBar shown
      expect(find.byType(ChoicePickerSheet), findsNothing);
      expect(find.text('標籤已更新'), findsOneWidget);

      // Label 'a' chip should now appear on the page
      expect(find.byKey(const ValueKey('label-chip-a')), findsOneWidget);
      expect(mutatedCalled, isTrue);
      expect(mutatedData?['labels'], contains('a'));
    });
  });
}
