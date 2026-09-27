import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/suggestion.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
import 'package:gitlab_mobile/features/workspace/suggestion_card.dart';
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
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('SuggestedChange Model & Parser', () {
    test('parses structured suggestions from API payload', () {
      final note = {
        'id': 101,
        'body': 'Consider this improvement\n```suggestion\nfinal total = a + b;\n```',
        'suggestions': [
          {
            'id': 5001,
            'from_content': 'var total = a + b;\n',
            'to_content': 'final total = a + b;\n',
            'appliable': true,
            'applied': false,
          }
        ],
      };

      final results = parseNoteSuggestions(note);
      expect(results.length, 1);
      expect(results.first.id, 5001);
      expect(results.first.fromContent, 'var total = a + b;\n');
      expect(results.first.toContent, 'final total = a + b;\n');
      expect(results.first.appliable, isTrue);
      expect(results.first.applied, isFalse);
    });

    test('parses markdown suggestion blocks when API suggestions are omitted', () {
      final note = {
        'id': 102,
        'body': 'Here is a suggestion:\n```suggestion\nconst timeout = Duration(seconds: 5);\n```\nLooks good?',
      };

      final results = parseNoteSuggestions(note);
      expect(results.length, 1);
      expect(results.first.id, isNull);
      expect(results.first.toContent.trim(), 'const timeout = Duration(seconds: 5);');
      expect(results.first.appliable, isFalse);
      expect(results.first.applied, isFalse);
    });

    test('parses suggestions with range offsets', () {
      final note = {
        'id': 103,
        'body': 'Multiple lines:\n```suggestion:-1+2\nline1\nline2\n```',
      };

      final results = parseNoteSuggestions(note);
      expect(results.length, 1);
      expect(results.first.toContent.trim(), 'line1\nline2');
    });

    test('parses multiple suggestions in a single note body', () {
      final note = {
        'id': 104,
        'body': '''
First:
```suggestion
fix1();
```
Second:
```suggestion
fix2();
```
''',
      };

      final results = parseNoteSuggestions(note);
      expect(results.length, 2);
      expect(results[0].toContent.trim(), 'fix1();');
      expect(results[1].toContent.trim(), 'fix2();');
    });

    test('returns empty list for notes without suggestion blocks', () {
      final note = {
        'id': 105,
        'body': 'Just a regular code review comment without suggestion syntax.',
      };

      final results = parseNoteSuggestions(note);
      expect(results, isEmpty);
    });

    test('copyWith properly preserves and overrides fields', () {
      const original = SuggestedChange(
        id: 1,
        fromContent: 'old',
        toContent: 'new',
        appliable: true,
        applied: false,
      );

      final updated = original.copyWith(applied: true);
      expect(updated.id, 1);
      expect(updated.fromContent, 'old');
      expect(updated.toContent, 'new');
      expect(updated.appliable, isTrue);
      expect(updated.applied, isTrue);
    });
  });

  group('SuggestedChangeCard Widget', () {
    testWidgets('renders diff comparison and meets touch target requirements', (tester) async {
      _surface(tester);

      const suggestion = SuggestedChange(
        id: 777,
        fromContent: 'int count = 0;\n',
        toContent: 'final count = 0;\n',
        appliable: true,
        applied: false,
      );

      await tester.pumpWidget(_host(
        const SuggestedChangeCard(suggestion: suggestion),
      ));
      await tester.pump();

      expect(find.text('建議修改 (Suggested Change)'), findsOneWidget);
      expect(find.text('- int count = 0;'), findsOneWidget);
      expect(find.text('+ final count = 0;'), findsOneWidget);
    });

    testWidgets('displays applied badge when applied is true', (tester) async {
      _surface(tester);

      const suggestion = SuggestedChange(
        id: 778,
        fromContent: 'foo();',
        toContent: 'bar();',
        appliable: true,
        applied: true,
      );

      await tester.pumpWidget(_host(
        const SuggestedChangeCard(suggestion: suggestion),
      ));
      await tester.pump();

      expect(find.text('已套用'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.text('套用建議'), findsNothing);
    });

    testWidgets('displays non-appliable text when appliable is false', (tester) async {
      _surface(tester);

      const suggestion = SuggestedChange(
        id: 779,
        toContent: 'qux();',
        appliable: false,
        applied: false,
      );

      await tester.pumpWidget(_host(
        const SuggestedChangeCard(suggestion: suggestion),
      ));
      await tester.pump();

      expect(find.text('無法自動套用'), findsOneWidget);
      expect(find.text('套用建議'), findsNothing);
    });

    testWidgets('clicking apply suggestion shows dialog and executes API on confirm', (tester) async {
      _surface(tester);
      final fixture = WorkspaceFixture();

      const suggestion = SuggestedChange(
        id: 888,
        fromContent: 'oldCode();',
        toContent: 'newCode();',
        appliable: true,
        applied: false,
      );

      var appliedCallbackCalled = false;

      await tester.pumpWidget(_host(
        SuggestedChangeCard(
          suggestion: suggestion,
          api: fixture.api,
          onApplied: () => appliedCallbackCalled = true,
        ),
      ));
      await tester.pump();

      // Find apply button
      final applyButton = find.byKey(const ValueKey('apply-suggestion-888'));
      expect(applyButton, findsOneWidget);

      // Verify touch target size ≥ 48dp
      final size = tester.getSize(applyButton);
      expect(size.height, greaterThanOrEqualTo(48.0));

      // Tap apply button -> open dialog
      await tester.tap(applyButton);
      await tester.pumpAndSettle();

      expect(find.text('套用建議修改'), findsOneWidget);
      expect(find.text('確認套用'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);

      // Enter custom commit message
      await tester.enterText(find.byType(TextField), 'Custom commit message');
      await tester.pump();

      // Tap confirm
      await tester.tap(find.text('確認套用'));
      await tester.pumpAndSettle();

      // Verify success
      expect(appliedCallbackCalled, isTrue);
      expect(find.text('建議修改已成功套用'), findsOneWidget);
      expect(find.text('已套用'), findsOneWidget);
    });

    testWidgets('cancelling dialog does not apply suggestion', (tester) async {
      _surface(tester);
      final fixture = WorkspaceFixture();

      const suggestion = SuggestedChange(
        id: 889,
        fromContent: 'line1',
        toContent: 'line2',
        appliable: true,
        applied: false,
      );

      var appliedCalled = false;

      await tester.pumpWidget(_host(
        SuggestedChangeCard(
          suggestion: suggestion,
          api: fixture.api,
          onApplied: () => appliedCalled = true,
        ),
      ));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('apply-suggestion-889')));
      await tester.pumpAndSettle();

      // Tap cancel
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(appliedCalled, isFalse);
      expect(find.text('套用建議修改'), findsNothing);
      expect(find.byKey(const ValueKey('apply-suggestion-889')), findsOneWidget);
    });
  });

  group('SuggestedChange in ReviewDiffPage integration', () {
    testWidgets('renders suggestion inside diff discussion note', (tester) async {
      _surface(tester);
      final fixture = WorkspaceFixture();

      fixture.extraDiscussions.add({
        'id': 'thread-suggestion-1',
        'individual_note': false,
        'notes': [
          {
            'id': 901,
            'body': 'Please check this suggestion\n```suggestion\nfinal optimized = true;\n```',
            'author': {'id': 8, 'username': 'reviewer', 'name': 'Reviewer'},
            'created_at': '2026-09-27T10:00:00Z',
            'system': false,
            'resolvable': true,
            'resolved': false,
            'suggestions': [
              {
                'id': 9901,
                'from_content': 'var optimized = false;\n',
                'to_content': 'final optimized = true;\n',
                'appliable': true,
                'applied': false,
              }
            ],
            'position': {
              'position_type': 'text',
              'base_sha': WorkspaceFixture.sha,
              'start_sha': WorkspaceFixture.sha,
              'head_sha': WorkspaceFixture.sha,
              'old_path': 'lib/session.dart',
              'new_path': 'lib/session.dart',
              'new_line': 1,
            },
          }
        ],
      });

      await tester.pumpWidget(_host(
        ReviewDiffPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          iid: 12,
          expectedSha: WorkspaceFixture.sha,
        ),
      ));
      await settleWorkspace(tester);

      // Open file
      await tester.tap(find.text('lib/session.dart'));
      await settleWorkspace(tester);

      // Verify SuggestedChangeCard rendered inside diff note
      expect(find.text('建議修改 (Suggested Change)'), findsOneWidget);
      expect(find.text('- var optimized = false;'), findsOneWidget);
      expect(find.text('+ final optimized = true;'), findsOneWidget);
      expect(find.byKey(const ValueKey('apply-suggestion-9901')), findsOneWidget);
    });
  });
}
