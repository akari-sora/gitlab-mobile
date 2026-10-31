import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/job_trace.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  for (final status in ['manual', 'pending', 'created', 'scheduled', 'preparing', 'waiting_for_resource']) {
    test('visible $status job without trace returns an empty log', () async {
      final api = testApi(FakeAdapter((request) => request.uri.path.endsWith('/trace')
        ? jsonResponse({}, status: 404) : jsonResponse({'id': 1, 'status': status})));
      addTearDown(api.close);
      expect(await api.jobTrace(42, 1), '');
    });
  }
  test('expired completed-job trace remains 404 rather than pretending it is empty', () async {
    final api = testApi(FakeAdapter((request) => request.uri.path.endsWith('/trace')
      ? jsonResponse({}, status: 404) : jsonResponse({'id': 1, 'status': 'success'})));
    addTearDown(api.close);
    await expectLater(api.jobTrace(42, 1), throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 404)));
  });
  test('nonexistent job cannot masquerade as a pending empty log', () async {
    final api = testApi(FakeAdapter((_) => jsonResponse({}, status: 404))); addTearDown(api.close);
    await expectLater(api.jobTrace(42, 1), throwsA(isA<ApiFailure>().having((e) => e.status, 'status', 404)));
  });
  test('invalid project rows fail in the transport rather than during widget build', () async {
    final api = testApi(FakeAdapter((_) => jsonResponse([{'id': 42}]))); addTearDown(api.close);
    await expectLater(api.records(['projects']), throwsA(isA<ApiFailure>()
      .having((e) => e.kind, 'kind', FailureKind.invalidResponse)));
  });
  testWidgets('manual job retains its play control before any trace exists', (tester) async {
    final fixture = WorkspaceFixture(); addTearDown(fixture.api.close);
    await tester.pumpWidget(workspaceHost(JobLogPage(account: fixture.account, api: fixture.api, project: fixture.project, id: 502)));
    await settleWorkspace(tester);
    expect(find.text('等待手動啟動'), findsOneWidget);
    await tester.tap(find.byTooltip('工作操作')); await tester.pumpAndSettle();
    expect(find.text('啟動手動工作'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox()); await tester.pump();
  });

  test('jobTraceChunk sends Range header and offset query param when offset > 0', () async {
    RequestOptions? captured;
    final api = testApi(FakeAdapter((request) {
      captured = request;
      return ResponseBody.fromString('chunk2', 206, headers: {
        'content-range': ['bytes 100-105/200'],
      });
    }));
    addTearDown(api.close);
    final result = await api.jobTraceChunk(42, 1, offset: 100);
    expect(captured, isNotNull);
    expect(captured!.headers['Range'], 'bytes=100-');
    expect(captured!.uri.queryParameters['offset'], '100');
    expect(utf8.decode(result.bytes), 'chunk2');
    expect(result.nextOffset, 106);
    expect(result.isEof, isFalse);
  });

  test('jobTraceChunk handles HTTP 206 with partial content and EOF', () async {
    final api = testApi(FakeAdapter((request) => ResponseBody.fromString('done', 206, headers: {
      'content-range': ['bytes 100-103/104'],
      'x-gitlab-trace-eof': ['true'],
    })));
    addTearDown(api.close);
    final result = await api.jobTraceChunk(42, 1, offset: 100);
    expect(utf8.decode(result.bytes), 'done');
    expect(result.nextOffset, 104);
    expect(result.isEof, isTrue);
  });

  test('jobTraceChunk handles HTTP 416 Range Not Satisfiable as empty chunk with current offset', () async {
    final api = testApi(FakeAdapter((request) => ResponseBody.fromString('', 416, headers: {
      'content-range': ['bytes */100'],
      'x-gitlab-trace-eof': ['true'],
    })));
    addTearDown(api.close);
    final result = await api.jobTraceChunk(42, 1, offset: 100);
    expect(result.bytes, isEmpty);
    expect(result.nextOffset, 100);
    expect(result.isEof, isTrue);
  });

  testWidgets('JobLogPage preserves section collapsed state during offset streaming updates', (tester) async {
    const initialTrace = 'section_start:1700000000:step_1\r\nInside step 1\r\nsection_end:1700000010:step_1\r\n';
    const appendTrace = 'New log line after step 1\r\n';

    final api = testApi(FakeAdapter((request) {
      if (request.uri.path.endsWith('/jobs/1')) {
        return jsonResponse({'id': 1, 'status': 'running'});
      }
      if (request.uri.path.endsWith('/trace')) {
        final initialBytes = utf8.encode(initialTrace);
        if (request.headers['Range'] == 'bytes=${initialBytes.length}-') {
          return ResponseBody.fromString(appendTrace, 206, headers: {
            'content-range': ['bytes ${initialBytes.length}-${initialBytes.length + utf8.encode(appendTrace).length - 1}/*'],
          });
        }
        return ResponseBody.fromString(initialTrace, 200);
      }
      return jsonResponse({}, status: 404);
    }));
    addTearDown(api.close);

    final project = Project.fromJson(projectJson(42));
    final account = Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 1, username: 'testuser', name: 'Test User'),
      token: 'tok',
    );

    await tester.pumpWidget(workspaceHost(JobLogPage(account: account, api: api, project: project, id: 1)));
    await settleWorkspace(tester);

    expect(find.text('step 1 · 10 秒'), findsOneWidget);
    expect(find.text('Inside step 1'), findsOneWidget);

    // Tap section header to collapse it
    await tester.tap(find.text('step 1 · 10 秒'));
    await tester.pumpAndSettle();

    // Inside step 1 should now be collapsed (hidden)
    expect(find.text('Inside step 1'), findsNothing);

    // Tap refresh icon to trigger streaming update
    await tester.tap(find.byTooltip('重新讀取 Log'));
    await settleWorkspace(tester);

    // Verify new log arrived
    expect(find.text('New log line after step 1'), findsOneWidget);
    // Verify section is STILL collapsed!
    expect(find.text('Inside step 1'), findsNothing);

    // Expand section again
    await tester.tap(find.text('step 1 · 10 秒'));
    await tester.pumpAndSettle();

    // Verify inside content is visible again
    expect(find.text('Inside step 1'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  group('JobTraceParser incremental equivalence', () {
    const timestampedTrace =
        '2026-10-20T06:56:03.100000Z 00O \x1b[0KRunning with gitlab-runner 19.4.1 🚀\x1b[0;m\r\n'
        '2026-10-20T06:56:03.200000Z 00O section_start:1792479365:prepare_script[collapsed=true]\r\x1b[0K\n'
        '2026-10-20T06:56:03.300000Z 00O+\x1b[38;5;208;1mPreparing 繁體中文 environment\x1b[0m\n'
        '2026-10-20T06:56:03.400000Z 00O \x1b[38;2;12;34;56;48;2;200;210;220mTruecolor chunk part 1\n'
        '2026-10-20T06:56:03.500000Z 00O+ and continued part 2 🧪\x1b[0m\n'
        '2026-10-20T06:56:03.600000Z 00O section_start:1792479366:nested_step\rInline before\n'
        '2026-10-20T06:56:04.000000Z 00O Inside nested step éß\r\n'
        '2026-10-20T06:56:05.000000Z 00O section_end:1792479368:nested_step\rAfter nested\n'
        '2026-10-20T06:56:06.000000Z 00O section_end:1792479370:prepare_script\r\x1b[0K\n'
        '2026-10-20T06:56:07.000000Z 00O section_start:1792479371:unclosed_tail[collapsed=true]\rTrailing \x1b[32mgreen text';

    const plainTrace =
        '\x1b[31;1mHeader 繁體中文 🚀\x1b[0m\r\n'
        'section_start:100:outer[collapsed=true]\r\x1b[38;5;42mOuter line\n'
        'section_start:102:inner\r\x1b[38;2;255;128;0mInner line 🧪\x1b[0m\r\n'
        'section_end:105:inner\rAfter inner\n'
        'section_end:110:outer\r\n'
        'Final line with \x1b[4;36munderline cyan\x1b[0m\n';

    test('matches JobTrace.parse across every single byte split offset (mid-UTF8, mid-ANSI, mid-marker, mid-timestamp)', () {
      for (final sample in [timestampedTrace, plainTrace]) {
        final expected = JobTrace.parse(sample);
        final bytes = Uint8List.fromList(utf8.encode(sample));

        for (var split = 0; split <= bytes.length; split++) {
          final parser = JobTraceParser();
          parser.addBytes(Uint8List.sublistView(bytes, 0, split));
          // Exercise intermediate snapshot before the second half arrives.
          parser.snapshot();
          final actual = parser.addBytes(
            Uint8List.sublistView(bytes, split),
            isLast: true,
          );
          _expectTraceEquivalent(actual, expected, reason: 'split at byte $split');
        }
      }
    });

    test('matches JobTrace.parse when fed in fine-grained multi-chunk byte streams', () {
      for (final sample in [timestampedTrace, plainTrace]) {
        final expected = JobTrace.parse(sample);
        final bytes = Uint8List.fromList(utf8.encode(sample));

        for (final step in [1, 2, 3, 5, 7, 13, 29, 32, 64]) {
          final parser = JobTraceParser();
          for (var offset = 0; offset < bytes.length; offset += step) {
            final end = (offset + step < bytes.length) ? offset + step : bytes.length;
            parser.addBytes(Uint8List.sublistView(bytes, offset, end));
          }
          final actual = parser.finish();
          _expectTraceEquivalent(actual, expected, reason: 'chunk step $step');
        }
      }
    });

    test('addBytesAsync parses chunks > 64 KiB in an isolate and respects shouldCommit', () async {
      final buf = StringBuffer(
        'section_start:10:async_sec[collapsed=true]\r\x1b[38;2;10;20;30mStart 🚀\n',
      );
      while (buf.length < 75 * 1024) {
        buf.writeln('Line ${buf.length} with \x1b[38;5;120mANSI color\x1b[0m and 繁體中文');
      }
      buf.write('section_end:25:async_sec\r\nDone\n');
      final fullText = buf.toString();
      final expected = JobTrace.parse(fullText);
      final allBytes = Uint8List.fromList(utf8.encode(fullText));

      // Split right inside the initial multi-byte emoji 🚀 so the > 64 KiB
      // isolate chunk starts with continuation bytes and an open ANSI/section state.
      final rocketStart = _indexOfSublist(allBytes, utf8.encode('🚀'));
      expect(rocketStart, greaterThan(0));
      final split = rocketStart + 2;

      final firstChunk = Uint8List.sublistView(allBytes, 0, split);
      final secondChunk = Uint8List.sublistView(allBytes, split);
      expect(secondChunk.length, greaterThan(JobTraceParser.isolateThresholdBytes));

      final parser = JobTraceParser();
      await parser.addBytesAsync(firstChunk);
      final charsAfterFirst = parser.charactersProcessed;

      // Stale epoch: shouldCommit returns false, so parser state must not advance.
      await parser.addBytesAsync(
        secondChunk,
        isLast: true,
        shouldCommit: () => false,
      );
      expect(parser.charactersProcessed, charsAfterFirst);

      // Active epoch: shouldCommit returns true, committing the isolate result.
      final committed = await parser.addBytesAsync(
        secondChunk,
        isLast: true,
        shouldCommit: () => true,
      );
      _expectTraceEquivalent(committed, expected);
    });
  });

  group('JobTraceParser sliding window and sections', () {
    test('drops sections ending before the window and clamps sections starting before the window', () {
      final parser = JobTraceParser(maxLines: 6);
      // Lines 0..1: closed section `old_sec` (ends at line 2, before windowStart)
      parser.addText('section_start:100:old_sec\rOld 0\nOld 1\nsection_end:105:old_sec\r');
      // Line 2: open `outer_open` (stays open through end of trace)
      parser.addText('section_start:200:outer_open[collapsed=true]\rOuter 2\n');
      // Lines 3..6: `spanning_closed` starts at line 3 (before windowStart=4) and closes at line 7 (inside window)
      parser.addText('section_start:300:spanning_closed\rSpan 3\nSpan 4\nSpan 5\nSpan 6\nsection_end:312:spanning_closed\r');
      // Lines 7..9: `inner_recent` starts and ends inside the window
      final trace = parser.addText(
        'section_start:400:inner_recent\rRecent 7\nRecent 8\nsection_end:403:inner_recent\rTail 9',
        isLast: true,
      );

      // Total lines emitted: 10 (indices 0..9). With maxLines=6, window is 4..9.
      expect(trace.truncated, isTrue);
      expect(trace.lines.map((l) => l.text).toList(), [
        'Span 4',
        'Span 5',
        'Span 6',
        'Recent 7',
        'Recent 8',
        'Tail 9',
      ]);

      // `old_sec` (0..2) was dropped; `spanning_closed`, `inner_recent`, and `outer_open` remain.
      final byName = {for (final s in trace.sections) s.name: s};
      expect(byName.containsKey('old_sec'), isFalse);

      final outer = byName['outer_open']!;
      expect(outer.startLine, 0);
      expect(outer.endLine, 6);
      expect(outer.collapsed, isTrue);
      expect(outer.depth, 0);
      expect(outer.durationSeconds, isNull);

      final spanning = byName['spanning_closed']!;
      expect(spanning.startLine, 0);
      expect(spanning.endLine, 3);
      expect(spanning.depth, 1);
      expect(spanning.durationSeconds, 12);

      final recent = byName['inner_recent']!;
      expect(recent.startLine, 3);
      expect(recent.endLine, 5);
      expect(recent.depth, 1);
      expect(recent.durationSeconds, 3);
    });
  });

  group('Performance baseline (50,000 lines)', () {
    test('50,000-line trace with ANSI 16/256/truecolor, sections, and timestamps does work proportional to appended bytes and bounds memory', () {
      const totalLines = 50000;
      final rawBuffer = StringBuffer();
      for (var i = 0; i < totalLines; i++) {
        final sec = (i % 60).toString().padLeft(2, '0');
        final min = ((i ~/ 60) % 60).toString().padLeft(2, '0');
        final ts = '2026-10-20T06:$min:$sec.123456Z 00O ';
        if (i % 500 == 0) {
          final stepIdx = i ~/ 500;
          rawBuffer.write(
            '${ts}section_start:${1700000000 + i}:step_$stepIdx[collapsed=true]\r',
          );
        } else {
          rawBuffer.write(ts);
        }
        rawBuffer.write(
          '\x1b[31;1m[STEP]\x1b[0m '
          '\x1b[38;5;${i % 256}mcolor256\x1b[0m '
          '\x1b[38;2;${i % 255};100;200mtruecolor\x1b[0m '
          'Log payload line $i',
        );
        if (i % 500 == 499) {
          final stepIdx = i ~/ 500;
          rawBuffer.write('\n${ts}section_end:${1700000000 + i}:step_$stepIdx\r');
        }
        rawBuffer.write('\n');
      }

      final fullString = rawBuffer.toString();
      final allBytes = Uint8List.fromList(utf8.encode(fullString));
      const chunkSizes = <int>[1024, 4096, 8192, 16384, 32768, 65536];

      JobTrace.resetDebugCounters();
      final parser = JobTraceParser();
      final stopwatch = Stopwatch()..start();

      var offset = 0;
      var chunkIndex = 0;
      var prevProcessed = 0;
      var memoryAtMidpoint = 0;

      while (offset < allBytes.length) {
        final size = chunkSizes[chunkIndex % chunkSizes.length];
        final end = (offset + size < allBytes.length) ? offset + size : allBytes.length;
        final slice = Uint8List.sublistView(allBytes, offset, end);
        parser.addBytes(slice, isLast: end == allBytes.length);

        final currentProcessed = parser.charactersProcessed;
        final deltaChars = currentProcessed - prevProcessed;
        // Each chunk is ASCII/UTF-8 so decoded characters never exceed slice.length.
        expect(deltaChars, lessThanOrEqualTo(slice.length));
        expect(deltaChars, greaterThan(0));
        prevProcessed = currentProcessed;

        if (memoryAtMidpoint == 0 && offset > allBytes.length ~/ 2) {
          memoryAtMidpoint = parser.snapshot().estimatedBytes;
        }

        offset = end;
        chunkIndex++;
      }

      final finalTrace = parser.snapshot();
      stopwatch.stop();

      // 1. Characters processed equals exact decoded length (1x, never quadratic).
      expect(parser.charactersProcessed, fullString.length);
      expect(JobTrace.debugCharactersProcessed, fullString.length);

      // 2. Sliding window is capped at GitLabApi.maxTextLines (20,000).
      expect(finalTrace.lines.length, GitLabApi.maxTextLines);
      expect(finalTrace.truncated, isTrue);
      expect(finalTrace.lines.first.text, contains('Log payload line 30001'));
      expect(finalTrace.lines[finalTrace.lines.length - 2].text, contains('Log payload line 49999'));

      // 3. Parsed model memory stays bounded (~6-8 MiB for 20k styled lines).
      expect(memoryAtMidpoint, greaterThan(0));
      expect(finalTrace.estimatedBytes, lessThan(12 * 1024 * 1024));
      // Memory after 50k lines is within 5% of memory after 25k lines (window already full).
      expect(
        (finalTrace.estimatedBytes - memoryAtMidpoint).abs(),
        lessThan(memoryAtMidpoint * 0.05),
      );

      // 4. Generous wall-clock sanity bound (marked clearly; typically < 500ms).
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 30)),
        reason: 'Generous wall-clock sanity bound for 50k-line incremental parse',
      );
    });
  });

  group('JobLogPage incremental & sliding-window widget tests', () {
    testWidgets('running job growing past 20k lines shows tail and truncated notice instead of error, without re-parsing old text', (tester) async {
      final chunk1Buf = StringBuffer(
        'section_start:100:long_build\r',
      );
      for (var i = 0; i < 12000; i++) {
        chunk1Buf.writeln('running line $i');
      }
      final chunk1Text = chunk1Buf.toString();
      final chunk1Bytes = utf8.encode(chunk1Text);

      final chunk2Buf = StringBuffer();
      for (var i = 12000; i < 22000; i++) {
        chunk2Buf.writeln('running line $i');
      }
      chunk2Buf.write('section_end:200:long_build\r\n');
      final chunk2Text = chunk2Buf.toString();
      final chunk2Bytes = utf8.encode(chunk2Text);

      final requestedRanges = <String?>[];
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'running', 'name': 'long-job'});
        }
        if (request.uri.path.endsWith('/trace')) {
          final range = request.headers['Range'] as String?;
          requestedRanges.add(range);
          if (range == 'bytes=${chunk1Bytes.length}-') {
            return ResponseBody.fromString(chunk2Text, 206, headers: {
              'content-range': [
                'bytes ${chunk1Bytes.length}-${chunk1Bytes.length + chunk2Bytes.length - 1}/*',
              ],
            });
          }
          if (range == 'bytes=${chunk1Bytes.length + chunk2Bytes.length}-') {
            return ResponseBody.fromString('', 206, headers: {
              'content-range': [
                'bytes */${chunk1Bytes.length + chunk2Bytes.length}',
              ],
            });
          }
          return ResponseBody.fromString(chunk1Text, 200);
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(api.close);

      final project = Project.fromJson(projectJson(42));
      final account = Account(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
        user: const GitLabUser(id: 1, username: 'testuser', name: 'Test User'),
        token: 'tok',
      );

      JobTrace.resetDebugCounters();

      await tester.pumpWidget(
        workspaceHost(JobLogPage(account: account, api: api, project: project, id: 1)),
      );
      await settleWorkspace(tester);

      // After first poll (12,000 lines): no truncation notice yet, and characters
      // processed equals chunk1Text.length.
      expect(find.byKey(const ValueKey('job-log-truncated')), findsNothing);
      expect(JobTrace.debugCharactersProcessed, chunk1Text.length);

      // Trigger second poll (+10,000 lines -> 22,000 lines total > 20,000 limit).
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await settleWorkspace(tester);

      // Incremental parse processed ONLY chunk2Text, never re-parsing chunk1Text.
      expect(
        JobTrace.debugCharactersProcessed,
        chunk1Text.length + chunk2Text.length,
      );

      // Shows truncation notice and tail line at bottom, NOT an error page.
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);
      expect(find.text('running line 21999'), findsOneWidget);

      // Scroll to the top of the window: the spanning section header (`long build`)
      // is clamped to line 0 and the first retained line is `running line 2001`.
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
      );
      scrollable.position.jumpTo(0);
      await tester.pump();
      expect(find.text('long build · 100 秒'), findsOneWidget);
      expect(find.text('running line 2001'), findsOneWidget);
      expect(find.text('running line 0'), findsNothing);

      // Trigger third poll to verify byte offset stayed absolute across window trimming.
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await settleWorkspace(tester);
      expect(
        requestedRanges,
        contains('bytes=${chunk1Bytes.length + chunk2Bytes.length}-'),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}

int _indexOfSublist(List<int> haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

void _expectTraceEquivalent(
  JobTrace actual,
  JobTrace expected, {
  String? reason,
}) {
  expect(actual.lines.length, expected.lines.length, reason: reason);
  for (var i = 0; i < expected.lines.length; i++) {
    final a = actual.lines[i];
    final e = expected.lines[i];
    expect(a.text, e.text, reason: '$reason line $i text');
    expect(a.lowerText, e.lowerText, reason: '$reason line $i lowerText');
    expect(a.lowerText, a.text.toLowerCase(), reason: '$reason line $i lowerText invariant');
    expect(a.section, e.section, reason: '$reason line $i section');
    expect(a.spans.length, e.spans.length, reason: '$reason line $i spans length');
    for (var s = 0; s < e.spans.length; s++) {
      expect(a.spans[s].text, e.spans[s].text, reason: '$reason line $i span $s text');
      expect(a.spans[s].style, e.spans[s].style, reason: '$reason line $i span $s style');
    }
  }
  expect(actual.sections.length, expected.sections.length, reason: reason);
  for (var i = 0; i < expected.sections.length; i++) {
    final a = actual.sections[i];
    final e = expected.sections[i];
    expect(a.name, e.name, reason: '$reason section $i name');
    expect(a.start, e.start, reason: '$reason section $i start');
    expect(a.end, e.end, reason: '$reason section $i end');
    expect(a.collapsed, e.collapsed, reason: '$reason section $i collapsed');
    expect(a.startLine, e.startLine, reason: '$reason section $i startLine');
    expect(a.endLine, e.endLine, reason: '$reason section $i endLine');
    expect(a.depth, e.depth, reason: '$reason section $i depth');
    expect(a.durationSeconds, e.durationSeconds, reason: '$reason section $i duration');
  }
}
