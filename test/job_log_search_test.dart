import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/job_trace.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';

import 'support/fake_adapter.dart';
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

    testWidgets('nested collapsed sections auto-expand all ancestors when jumped to', (tester) async {
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

      expect(find.textContaining('Deeply nested secret target'), findsNothing);

      final searchFinder = find.byKey(const ValueKey('job-log-search-501'));
      await tester.enterText(searchFinder, 'secret target');
      await tester.pump();

      // Deeply nested text is revealed as both parent and child sections expand
      expect(find.textContaining('Deeply nested secret target'), findsOneWidget);
    });

    testWidgets('manually collapsing a section with matches and then jumping re-expands it', (tester) async {
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
      await tester.enterText(searchFinder, 'warning');
      await tester.pump();

      // Section was opened
      expect(find.textContaining('Hidden warning in step'), findsOneWidget);

      // Now user manually collapses the section header
      final headerFinder = find.textContaining('hidden step');
      expect(headerFinder, findsOneWidget);
      await tester.tap(headerFinder);
      await tester.pump();

      // Section is now collapsed
      expect(find.textContaining('Hidden warning in step'), findsNothing);

      // Navigating or jumping to the match re-expands it
      await tester.tap(find.byTooltip('下一個相符項目'));
      await tester.pump();

      expect(find.textContaining('Hidden warning in step'), findsOneWidget);
    });

    testWidgets('search results and section filtering on streamed chunks match whole-fixture baseline using prebuilt lowerText', (tester) async {
      final baseline = JobTrace.parse(_SearchFixture.trace);
      final streamedParser = JobTraceParser();
      final rawBytes = utf8.encode(_SearchFixture.trace);
      for (var i = 0; i < rawBytes.length; i += 19) {
        final end = (i + 19 < rawBytes.length) ? i + 19 : rawBytes.length;
        streamedParser.addBytes(rawBytes.sublist(i, end));
      }
      final streamed = streamedParser.finish();

      expect(streamed.lines.length, baseline.lines.length);
      for (var i = 0; i < baseline.lines.length; i++) {
        expect(streamed.lines[i].lowerText, baseline.lines[i].text.toLowerCase());
        expect(streamed.lines[i].lowerText, baseline.lines[i].lowerText);
      }

      final fixture = _ChunkedSearchFixture();
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

      // Append second half via poll
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await settleWorkspace(tester);

      final searchFinder = find.byKey(const ValueKey('job-log-search-501'));
      for (final query in ['ERROR', 'warning', 'secret target', '[test-bracket]', '測試日誌', '🚀']) {
        await tester.enterText(searchFinder, query);
        await tester.pump();

        // Reference match count from baseline lowercasing
        final needle = query.toLowerCase();
        var expectedCount = 0;
        final expectedLineTexts = <String>[];
        for (final line in baseline.lines) {
          var start = 0;
          final lower = line.text.toLowerCase();
          var lineMatched = false;
          while (start < lower.length) {
            final idx = lower.indexOf(needle, start);
            if (idx < 0) break;
            expectedCount++;
            lineMatched = true;
            start = idx + needle.length;
          }
          if (lineMatched) expectedLineTexts.add(line.text);
        }

        expect(find.text('1/$expectedCount'), findsOneWidget, reason: 'query $query match counter');
        for (final matchedLine in expectedLineTexts) {
          expect(
            find.descendant(of: find.byType(ListView), matching: find.textContaining(matchedLine)),
            findsOneWidget,
            reason: 'query $query visible line $matchedLine',
          );
        }
      }
    });

    for (final scale in [1.0, 2.0]) {
      testWidgets('window slide while not following keeps the rows on screen still (text scale $scale), then shows the latest window back at the tail', (tester) async {
        final chunk1Buf = StringBuffer();
        for (var i = 0; i < 20000; i++) {
          // Long rows wrap at 412 px, more so at text scale 2.0, so no fixed
          // row height can describe them.
          chunk1Buf.writeln(i % 10 != 1
              ? 'plain log row $i'
              : 'wrapped log row $i ${'with a long tail of words that wraps ' * 3}');
        }
        final chunk1Text = chunk1Buf.toString();
        final chunk1Bytes = utf8.encode(chunk1Text);
        final chunk2Buf = StringBuffer();
        for (var i = 20000; i < 20100; i++) {
          chunk2Buf.writeln('plain log row $i');
        }
        final chunk2Text = chunk2Buf.toString();
        final chunk2Bytes = utf8.encode(chunk2Text);

        final fixture = _CustomTraceFixture((request) {
          if (request.uri.path.endsWith('/jobs/501')) {
            return jsonResponse({'id': 501, 'status': 'running', 'name': 'slide-freeze'});
          }
          if (request.uri.path.endsWith('/jobs/501/trace')) {
            final range = request.headers['Range'] as String?;
            if (range != null && range.startsWith('bytes=${chunk1Bytes.length}-')) {
              return ResponseBody.fromString(chunk2Text, 206, headers: {
                'content-range': [
                  'bytes ${chunk1Bytes.length}-${chunk1Bytes.length + chunk2Bytes.length - 1}/*',
                ],
              });
            }
            if (range != null &&
                range.startsWith('bytes=${chunk1Bytes.length + chunk2Bytes.length}-')) {
              return ResponseBody.fromString('', 206, headers: {
                'content-range': ['bytes */${chunk1Bytes.length + chunk2Bytes.length}'],
              });
            }
            return ResponseBody.fromString(chunk1Text, 200);
          }
          return jsonResponse({}, status: 404);
        });
        addTearDown(fixture.api.close);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(412, 900);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(workspaceHost(JobLogPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          id: 501,
        ), scale: scale));
        await settleWorkspace(tester);
        expect(MediaQuery.textScalerOf(tester.element(find.byType(ListView))).scale(10), 10 * scale);
        // Polls come from the 10 s auto-refresh: the refresh button is the
        // reader asking for the latest window, tested below.
        await tester.tap(find.text('10 秒更新'));
        await tester.pump();

        // Scroll up from the tail (follow inactive) to rows that would move if
        // the 100 rows the slide drops (wrapped ones among them) were taken
        // off the top of the list.
        final scrollable = tester.state<ScrollableState>(
          find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
        );
        expect(scrollable.position.extentAfter, 0, reason: 'followed to the end');
        final reading = scrollable.position.maxScrollExtent - 3000;
        scrollable.position.jumpTo(reading);
        await tester.pumpAndSettle();
        final before = _firstVisibleRow(tester);
        expect(before, anyOf(startsWith('plain log row'), startsWith('wrapped log row')));
        expect(scrollable.position.extentAfter, greaterThan(80));

        // The poll appends 100 lines: the window slides by 100 in the
        // background, and nothing on screen moves.
        await tester.pump(const Duration(seconds: 10));
        await settleWorkspace(tester);
        expect(scrollable.position.pixels, reading);
        expect(_firstVisibleRow(tester), before);
        expect(find.text('plain log row 20099'), findsNothing);
        // A second poll with nothing new keeps it still too.
        await tester.pump(const Duration(seconds: 10));
        await settleWorkspace(tester);
        expect(_firstVisibleRow(tester), before);

        // Tapping refresh shows the held window where the reader is: the
        // rows move up by the 100 dropped ones and the list does not jump.
        await tester.tap(find.byTooltip('重新讀取 Log'));
        await settleWorkspace(tester);
        expect(scrollable.position.pixels, reading);
        expect(scrollable.position.extentAfter, greaterThan(80));
        final after = _firstVisibleRow(tester);
        int rowNumber(String row) => int.parse(RegExp(r'log row (\d+)').firstMatch(row)!.group(1)!);
        expect(rowNumber(after), greaterThan(rowNumber(before)));

        // Back at the tail, the latest window is shown and followed.
        scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
        await tester.pump();
        await tester.pump();
        await tester.pump();
        await settleWorkspace(tester);
        expect(find.text('plain log row 20099'), findsOneWidget);
        expect(scrollable.position.extentAfter, 0);

        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      });
    }

    testWidgets('active search match is re-anchored by line position when the window, slid past an earlier match, is shown on return to follow', (tester) async {
      final chunk1Buf = StringBuffer();
      for (var i = 0; i < 19999; i++) {
        if (i == 10) {
          chunk1Buf.writeln('needle early line $i');
        } else if (i == 5000) {
          chunk1Buf.writeln('needle middle line $i');
        } else if (i == 10000) {
          chunk1Buf.writeln('needle late line $i');
        } else {
          chunk1Buf.writeln('plain log row $i');
        }
      }
      final chunk1Text = chunk1Buf.toString();
      final chunk1Bytes = utf8.encode(chunk1Text);

      final chunk2Buf = StringBuffer();
      for (var i = 19999; i < 20100; i++) {
        chunk2Buf.writeln('plain log row $i');
      }
      final chunk2Text = chunk2Buf.toString();
      final chunk2Bytes = utf8.encode(chunk2Text);

      final fixture = _CustomTraceFixture((request) {
        if (request.uri.path.endsWith('/jobs/501')) {
          return jsonResponse({'id': 501, 'status': 'running', 'name': 'reanchor-search'});
        }
        if (request.uri.path.endsWith('/jobs/501/trace')) {
          final range = request.headers['Range'] as String?;
          if (range != null && range.startsWith('bytes=${chunk1Bytes.length}-')) {
            return ResponseBody.fromString(chunk2Text, 206, headers: {
              'content-range': [
                'bytes ${chunk1Bytes.length}-${chunk1Bytes.length + chunk2Bytes.length - 1}/*',
              ],
            });
          }
          return ResponseBody.fromString(chunk1Text, 200);
        }
        return jsonResponse({}, status: 404);
      });
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(workspaceHost(JobLogPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        id: 501,
      )));
      await settleWorkspace(tester);
      await tester.tap(find.text('10 秒更新'));
      await tester.pump();

      final searchFinder = find.byKey(const ValueKey('job-log-search-501'));
      await tester.enterText(searchFinder, 'needle');
      await tester.pump();
      expect(find.text('1/3'), findsOneWidget);

      // Select match 2 of 3 ('needle middle line 5000').
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();
      expect(find.text('2/3'), findsOneWidget);

      // The 10 s poll appends 101 lines -> the window slides past line 10
      // ('needle early line 10') in the background. Searching turned follow
      // off, so the rows and matches on screen stay as they were.
      await tester.pump(const Duration(seconds: 10));
      await settleWorkspace(tester);
      expect(find.text('2/3'), findsOneWidget);

      // Following again shows the latest window. Only 2 matches remain
      // ('needle middle line 5000' and 'needle late line 10000'). Because
      // _currentMatch is re-anchored by absolute line position, it stays on
      // 'needle middle line 5000', which is now match 1/2 (index 0).
      await tester.tap(find.text('跟隨尾端'));
      await tester.pump();
      await settleWorkspace(tester);
      expect(find.text('1/2'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}

/// Text of the topmost log row inside the list's viewport.
String _firstVisibleRow(WidgetTester tester) {
  final viewport = tester.getRect(find.byType(ListView));
  String? text;
  var top = double.infinity;
  for (final element in find
      .descendant(of: find.byType(ListView), matching: find.byType(RichText))
      .evaluate()) {
    final box = element.renderObject! as RenderBox;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    if (rect.bottom <= viewport.top + 0.5 || rect.top >= viewport.bottom) continue;
    if (rect.top < top) {
      top = rect.top;
      text = (element.widget as RichText).text.toPlainText();
    }
  }
  return text!;
}

class _CustomTraceFixture extends WorkspaceFixture {
  _CustomTraceFixture(this._handler);
  final FutureOr<ResponseBody> Function(RequestOptions request) _handler;

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) => _handler(request);
}

class _ChunkedSearchFixture extends WorkspaceFixture {
  static final _bytes = utf8.encode(_SearchFixture.trace);
  static final _split = _bytes.length ~/ 2;
  static final _part1 = utf8.decode(_bytes.sublist(0, _split), allowMalformed: true);
  static final _part1Bytes = utf8.encode(_part1);
  static final _part2 = _SearchFixture.trace.substring(_part1.length);
  static final _part2Bytes = utf8.encode(_part2);

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (request.uri.path.endsWith('/jobs/501')) {
      return jsonResponse({'id': 501, 'status': 'running', 'name': 'chunked-search'});
    }
    if (request.uri.path.endsWith('/jobs/501/trace')) {
      final range = request.headers['Range'] as String?;
      if (range != null && range.startsWith('bytes=${_part1Bytes.length}-')) {
        return ResponseBody.fromString(_part2, 206, headers: {
          'content-range': [
            'bytes ${_part1Bytes.length}-${_part1Bytes.length + _part2Bytes.length - 1}/${_part1Bytes.length + _part2Bytes.length}',
          ],
          'x-gitlab-trace-eof': ['true'],
        });
      }
      return ResponseBody.fromString(_part1, 200);
    }
    return super.respond(request);
  }
}

class _SearchFixture extends WorkspaceFixture {
  static const trace =
      'Normal log line 1\n'
      'First error detected in compilation\n'
      'section_start:10:hidden_step[collapsed=true]\r'
      'Hidden warning in step\n'
      'section_start:11:nested_inner[collapsed=true]\r'
      'Deeply nested secret target\n'
      'section_end:12:nested_inner\r\n'
      'section_end:13:hidden_step\r\n'
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
