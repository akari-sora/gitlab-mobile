import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';

import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  group('Job Log Search and Jump Navigation (D5)', () {
    testWidgets('search bar renders with clear button, counter badge, and jump buttons', (tester) async {
      final fixture = _SearchFixture();
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(workspaceHost(JobLogPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        id: 501,
      )));
      await settleWorkspace(tester);

      final searchFinder = find.byKey(const ValueKey('job-log-search-501'));
      expect(searchFinder, findsOneWidget);

      // Initially no search query, clear button and match counter not visible
      expect(find.byIcon(Icons.clear), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);

      // Type search query that matches multiple lines
      await tester.enterText(searchFinder, 'error');
      await tester.pump();

      // Counter should show "1/3" (3 occurrences across lines)
      expect(find.text('1/3'), findsOneWidget);
      expect(find.bySemanticsLabel('第 1 個相符項目，共 3 個'), findsOneWidget);

      // Navigation buttons and clear button appear
      final upButton = find.byTooltip('上一個相符項目');
      final downButton = find.byTooltip('下一個相符項目');
      final clearButton = find.byTooltip('清除搜尋');
      expect(upButton, findsOneWidget);
      expect(downButton, findsOneWidget);
      expect(clearButton, findsOneWidget);

      // Touch targets are at least 48x48dp
      final upSize = tester.getSize(upButton);
      final downSize = tester.getSize(downButton);
      final clearSize = tester.getSize(clearButton);
      expect(upSize.width, greaterThanOrEqualTo(48.0));
      expect(upSize.height, greaterThanOrEqualTo(48.0));
      expect(downSize.width, greaterThanOrEqualTo(48.0));
      expect(downSize.height, greaterThanOrEqualTo(48.0));
      expect(clearSize.width, greaterThanOrEqualTo(48.0));
      expect(clearSize.height, greaterThanOrEqualTo(48.0));

      // Jump next wraps: 1/3 -> 2/3 -> 3/3 -> 1/3
      await tester.tap(downButton);
      await tester.pump();
      expect(find.text('2/3'), findsOneWidget);

      await tester.tap(downButton);
      await tester.pump();
      expect(find.text('3/3'), findsOneWidget);

      await tester.tap(downButton);
      await tester.pump();
      expect(find.text('1/3'), findsOneWidget);

      // Jump prev wraps: 1/3 -> 3/3 -> 2/3
      await tester.tap(upButton);
      await tester.pump();
      expect(find.text('3/3'), findsOneWidget);

      await tester.tap(upButton);
      await tester.pump();
      expect(find.text('2/3'), findsOneWidget);

      // Clear search button clears query, counter, navigation buttons, and restores all lines
      await tester.tap(clearButton);
      await tester.pump();
      expect(find.byIcon(Icons.clear), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
      expect(find.text('Normal log line 1'), findsOneWidget);
      expect(find.text('Normal log line 2'), findsOneWidget);
    });

    testWidgets('empty or unmatched search shows 0/0 and disables jump buttons', (tester) async {
      final fixture = _SearchFixture();
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(workspaceHost(JobLogPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        id: 501,
      )));
      await settleWorkspace(tester);

      final searchFinder = find.byKey(const ValueKey('job-log-search-501'));
      await tester.enterText(searchFinder, 'nonexistent_pattern_xyz');
      await tester.pump();

      expect(find.text('0/0'), findsOneWidget);
      expect(find.bySemanticsLabel('無相符項目'), findsOneWidget);

      final upButton = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.keyboard_arrow_up));
      final downButton = tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down));
      expect(upButton.onPressed, isNull);
      expect(downButton.onPressed, isNull);
    });

    testWidgets('search highlights matched text with distinct active vs inactive styling', (tester) async {
      final fixture = _SearchFixture();
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(workspaceHost(JobLogPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        id: 501,
      )));
      await settleWorkspace(tester);

      final searchFinder = find.byKey(const ValueKey('job-log-search-501'));
      await tester.enterText(searchFinder, 'error');
      await tester.pump();

      // Find RichText widgets displaying matched spans
      final richTexts = tester.widgetList<RichText>(find.byType(RichText)).toList();
      expect(richTexts, isNotEmpty);

      // Check that TextSpans contain highlight styling
      bool foundActiveHighlight = false;
      bool foundInactiveHighlight = false;

      for (final rt in richTexts) {
        rt.text.visitChildren((child) {
          if (child is TextSpan && child.text?.toLowerCase() == 'error') {
            final bg = child.style?.backgroundColor;
            if (bg == const Color(0xFFFF9800)) {
              foundActiveHighlight = true;
            } else if (bg == const Color(0xFFFFE082)) {
              foundInactiveHighlight = true;
            }
          }
          return true;
        });
      }

      expect(foundActiveHighlight, isTrue, reason: 'Active match must have active highlight color #FFFF9800');
      expect(foundInactiveHighlight, isTrue, reason: 'Inactive matches must have inactive highlight color #FFFFE082');

      // Tapping down moves active match
      await tester.tap(find.byTooltip('下一個相符項目'));
      await tester.pump();

      // Active highlight remains present on the second match
      bool foundActiveAfterJump = false;
      for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
        rt.text.visitChildren((child) {
          if (child is TextSpan && child.text?.toLowerCase() == 'error') {
            if (child.style?.backgroundColor == const Color(0xFFFF9800)) {
              foundActiveAfterJump = true;
            }
          }
          return true;
        });
      }
      expect(foundActiveAfterJump, isTrue);
    });

    testWidgets('search expands collapsed sections containing matches', (tester) async {
      final fixture = _SearchFixture();
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(workspaceHost(JobLogPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        id: 501,
      )));
      await settleWorkspace(tester);

      // Hidden line in collapsed section is not visible initially
      expect(find.textContaining('Hidden warning in step'), findsNothing);

      // Search for keyword in collapsed section
      final searchFinder = find.byKey(const ValueKey('job-log-search-501'));
      await tester.enterText(searchFinder, 'warning');
      await tester.pump();

      // Section automatically opens and hidden matching line is displayed
      expect(find.textContaining('Hidden warning in step'), findsOneWidget);
    });

    testWidgets('special punctuation characters []().*+\\ are searched literally without regex crash', (tester) async {
      final fixture = _SearchFixture();
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(workspaceHost(JobLogPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        id: 501,
      )));
      await settleWorkspace(tester);

      final searchFinder = find.byKey(const ValueKey('job-log-search-501'));

      // Searching literal "[test-bracket]" should match and not throw PatternSyntaxException
      await tester.enterText(searchFinder, '[test-bracket]');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('1/1'), findsOneWidget);
      expect(find.descendant(of: find.byType(ListView), matching: find.textContaining('[test-bracket]')), findsOneWidget);

      // Searching literal "a+b*c" should match literally
      await tester.enterText(searchFinder, 'a+b*c');
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('1/1'), findsOneWidget);
      expect(find.descendant(of: find.byType(ListView), matching: find.textContaining('a+b*c')), findsOneWidget);
    });

    testWidgets('multibyte Unicode and CJK queries match accurately', (tester) async {
      final fixture = _SearchFixture();
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(workspaceHost(JobLogPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        id: 501,
      )));
      await settleWorkspace(tester);

      final searchFinder = find.byKey(const ValueKey('job-log-search-501'));

      // Searching CJK string
      await tester.enterText(searchFinder, '測試日誌');
      await tester.pump();
      expect(find.text('1/1'), findsOneWidget);
      expect(find.descendant(of: find.byType(ListView), matching: find.textContaining('測試日誌')), findsOneWidget);

      // Searching Emoji 🚀
      await tester.enterText(searchFinder, '🚀');
      await tester.pump();
      expect(find.text('1/1'), findsOneWidget);
      expect(find.descendant(of: find.byType(ListView), matching: find.textContaining('🚀 Rocket launched')), findsOneWidget);
    });
  });
}

class _SearchFixture extends WorkspaceFixture {
  static const trace =
      'Normal log line 1\n'
      'First error detected in compilation\n'
      'section_start:10:hidden_step[collapsed=true]\r'
      'Hidden warning in step\n'
      'section_end:12:hidden_step\r\n'
      'Normal log line 2\n'
      'Second error: runtime failure\n'
      'Final line with error code 123\n'
      'Special syntax with [test-bracket] inside\n'
      'Mathematical formula: a+b*c = result\n'
      '繁體中文測試日誌行號資訊\n'
      '🚀 Rocket launched successfully\n';

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (request.uri.path.endsWith('/jobs/501/trace')) {
      return ResponseBody.fromString(trace, 200);
    }
    return super.respond(request);
  }
}
