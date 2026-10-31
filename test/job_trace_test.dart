import 'dart:convert';
import 'dart:math';
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
import 'package:gitlab_mobile/shared/skeleton.dart';
import 'support/fake_adapter.dart';
import 'support/old_job_trace.dart';
import 'support/widget_settle.dart';
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
        final range = request.headers['Range'] as String?;
        if (range != null && range.startsWith('bytes=${initialBytes.length}-')) {
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

      // Stale epoch: shouldCommit returns false -> returns null and leaves parser state unchanged.
      final uncommitted = await parser.addBytesAsync(
        secondChunk,
        isLast: true,
        shouldCommit: () => false,
      );
      expect(uncommitted, isNull);
      expect(parser.charactersProcessed, charsAfterFirst);

      // Also verify sync path (< 64 KiB) returns null when shouldCommit returns false.
      final uncommittedSync = await parser.addBytesAsync(
        utf8.encode('ignored\n'),
        shouldCommit: () => false,
      );
      expect(uncommittedSync, isNull);
      expect(parser.charactersProcessed, charsAfterFirst);

      // Active epoch: shouldCommit returns true, committing the isolate result.
      final committed = await parser.addBytesAsync(
        secondChunk,
        isLast: true,
        shouldCommit: () => true,
      );
      expect(committed, isNotNull);
      _expectTraceEquivalent(committed!, expected);
    });

    test('rejects stale isolate result with StateError if sync addBytes mutates parser while addBytesAsync is in flight', () async {
      final largePayload = Uint8List.fromList(
        utf8.encode(List.generate(3000, (i) => 'isolate row $i with padding text').join('\n')),
      );
      expect(largePayload.length, greaterThan(JobTraceParser.isolateThresholdBytes));

      final parser = JobTraceParser();
      parser.addText('initial row\n');

      // Start background isolate parse without awaiting immediately.
      final inFlight = parser.addBytesAsync(largePayload, isLast: true);

      // Mutate parser synchronously while the isolate is in flight.
      parser.addBytes(utf8.encode('sync row preserved\n'));

      await expectLater(inFlight, throwsA(isA<StateError>()));

      final snap = parser.snapshot();
      expect(snap.lines.map((l) => l.text).toList(), [
        'initial row',
        'sync row preserved',
        '',
      ]);
    });

    test('caps unterminated pending \\r progress line so memory and parseSpans work stay bounded', () {
      JobTrace.resetDebugCounters();
      final parser = JobTraceParser();
      final chunk = utf8.encode('${'x' * 20000}\r');
      // Feed 50 chunks of 20,000 chars + '\r' = 1,000,050 chars without a newline,
      // taking a snapshot after every chunk.
      for (var i = 0; i < 50; i++) {
        parser.addBytes(chunk);
        parser.snapshot();
      }
      final snap = parser.snapshot();
      expect(parser.charactersProcessed, 50 * chunk.length);
      // Display still shows the 20,000 'x' characters (chunked at 4096 chars per line).
      expect(snap.lines.map((l) => l.text).join().length, 20000);
      // Estimated bytes includes raw buffers and stays bounded well below 512 KiB.
      expect(parser.estimatedBytes, lessThan(512 * 1024));
      // Total characters fed to parseSpans across all 50 snapshots stays bounded
      // (capping prevents quadratic 25.5M char re-parsing).
      expect(JobTrace.debugCharactersProcessed, lessThan(3000000));
    });

    test('maxSections lifetime counter caps total sections at 1024 even after earlier sections evict from window', () {
      final parser = JobTraceParser(maxLines: 10);
      final buf = StringBuffer();
      for (var i = 0; i < 1100; i++) {
        buf.write('section_start:$i:sec_$i\rline $i\nsection_end:${i + 1}:sec_$i\r\n');
      }
      final text = buf.toString();
      parser.addText(text, isLast: true);
      final snap = parser.snapshot();
      // Sections 0..1023 consumed the 1024 lifetime budget; sections 1024..1099
      // were ignored just like OldJobTrace.parse, so none of sec_1024..sec_1099 appear.
      for (final s in snap.sections) {
        final idx = int.parse(s.name.substring(4));
        expect(idx, lessThan(JobTrace.maxSections));
      }
    });
  });

  group('Equivalence against pre-incremental OldJobTrace.parse (HEAD~1)', () {
    final fixtures = <String, String>{
      'empty': '',
      'whitespace_only': '   \t  ',
      'ansi_only': '\x1b[31m\x1b[0m',
      'single_newline': '\n',
      'two_newlines': '\n\n',
      'plain_no_trailing_nl': 'alpha\nbeta\ngamma',
      'plain_trailing_nl': 'alpha\nbeta\ngamma\n',
      'crlf': 'alpha\r\nbeta\r\ngamma\r\n',
      'cr_overwrite_midline':
          'progress 10%\rprogress 50%\rprogress 100%\r\ndone\n',
      'cr_at_eof': 'line1\nprogress 10%\rprogress 99%\r',
      'ansi_sgr_and_erase':
          '\x1b[1;31mRedBold\x1b[38;5;208mOrange256\x1b[48;2;10;20;30mTrueBg\x1b[0m\n'
          'before\r\x1b[Kafter_erase0\n'
          '12345\rabc\x1b[1Kdef\n'
          'wipe_me\x1b[2Kkept\n'
          'screen_wipe\x1b[2Jafter_j\n'
          'osc_bel\x1b]0;window title\x07visible\n'
          'osc_st\x1b]0;title2\x1b\\visible2\n'
          'esc2\x1b(Bplain\n',
      'multibyte_utf8':
          'ASCII then 2-byte é ß then 3-byte 繁體中文 then 4-byte 🚀🧪🎉 end\n'
          '\x1b[32m彩色中文🔥\x1b[0mと日本語\r\n',
      'long_line_chunking':
          '\x1b[31m${'A' * 3000}\x1b[32m${'B' * 3000}\x1b[0m${'C' * 3000}\nshort\n',
      'sections_complex':
          'section_start:100:sec_a[collapsed=true]\rHeader A\n'
          'inside A\n'
          'section_start:110:sec_b[collapsed=false]\rInline B1\n'
          'inside B\n'
          'section_start:115:sec_c\rInline C\n'
          'section_end:120:sec_b\rAfter B closes C implicitly\n'
          'section_end:130:sec_a\r\n'
          'section_end:140:nonexistent\rignored\n'
          'section_start:150:unclosed_1[collapsed=true]\r'
          'section_start:160:unclosed_2\rstill open at EOF',
      'inline_multiple_markers':
          'pre section_start:10:s1\rmid section_end:20:s1\rpost section_start:30:s2[collapsed=true]\rtail\n',
      'timestamps_basic':
          '2026-10-20T06:56:03.100000Z 00O First line\n'
          '2026-10-20T06:56:03.200000Z 00O+ continued part\n'
          '2026-10-20T06:56:03.300000Z 01E Second line on stderr\r\n'
          '2026-10-20T06:56:03.400000Z 00O section_start:10:ts_sec[collapsed=true]\rIn section\n'
          '2026-10-20T06:56:03.500000Z 00O+ still in section 🚀\n'
          '2026-10-20T06:56:05.000000Z 00O section_end:15:ts_sec\r\n'
          '2026-10-20T06:56:06.000000Z 00O Trailing without newline',
      'timestamps_with_trailing_nl':
          '2026-10-20T06:56:03.100000Z 00O Line A\n'
          '2026-10-20T06:56:03.200000Z 00O+ Line A2\n',
      'timestamps_short_nonheader_line':
          '2026-10-20T06:56:03.100000Z 00O First valid timestamped line\n'
          'short non-header\n'
          '2026-10-20T06:56:03.200000Z 00O Third line\n',
      'timestamps_malformed_32char_line':
          '2026-10-20T06:56:03.100000Z 00O First valid timestamped line\n'
          'NOT_A_TIMESTAMP_HEADER_AT_ALL_!!\n'
          '2026-10-20T06:56:03.200000Z 00O+ continuation after malformed\n',
      'almost_timestamp_first_line': '2026-10-20T06:56:03.100000Z 00X Not E or O\nsecond\n',
      'short_first_line': 'hi\n2026-10-20T06:56:03.100000Z 00O Not stripped\n',
    };

    test('1. JobTrace.parse matches OldJobTrace.parse on all fixtures', () {
      for (final e in fixtures.entries) {
        final oldT = OldJobTrace.parse(e.value);
        final newT = JobTrace.parse(e.value);
        _expectMatchesOld(newT, oldT, reason: 'JobTrace.parse(${e.key})');
      }
    });

    test('2. Every byte prefix fed in one chunk: snapshot() and finish() match OldJobTrace.parse', () {
      for (final e in fixtures.entries) {
        if (e.key == 'long_line_chunking') continue;
        final bytes = Uint8List.fromList(utf8.encode(e.value));
        for (var len = 0; len <= bytes.length; len++) {
          final sub = Uint8List.sublistView(bytes, 0, len);
          final p = JobTraceParser();
          p.addBytes(sub);
          final snap = p.snapshot();
          final fin = p.finish();
          final decodedForFinish = utf8.decode(sub, allowMalformed: true);
          final oldFin = OldJobTrace.parse(decodedForFinish);
          _expectMatchesOld(fin, oldFin, reason: '${e.key} prefix=$len finish');
          if (!_hasIncompleteTrailingUtf8(sub)) {
            _expectMatchesOld(snap, oldFin, reason: '${e.key} prefix=$len snapshot');
          }
        }
      }
    });

    test('3. Random multi-chunk byte splits (including empty chunks) match OldJobTrace at every step and at finish()', () {
      final rng = Random(20261031);
      for (final e in fixtures.entries) {
        final bytes = Uint8List.fromList(utf8.encode(e.value));
        final expectedFull = OldJobTrace.parse(e.value);
        for (var trial = 0; trial < 30; trial++) {
          final p = JobTraceParser();
          var offset = 0;
          while (offset < bytes.length) {
            if (rng.nextInt(5) == 0) {
              p.addBytes(Uint8List(0));
            }
            final maxStep = (trial % 3 == 0) ? 5 : (trial % 3 == 1 ? 37 : 256);
            final step = rng.nextInt(maxStep) + 1;
            final end = (offset + step < bytes.length) ? offset + step : bytes.length;
            p.addBytes(Uint8List.sublistView(bytes, offset, end));
            offset = end;

            if (e.key != 'long_line_chunking') {
              final prefix = Uint8List.sublistView(bytes, 0, offset);
              if (!_hasIncompleteTrailingUtf8(prefix)) {
                final snap = p.snapshot();
                final oldPrefix = OldJobTrace.parse(utf8.decode(prefix));
                _expectMatchesOld(snap, oldPrefix, reason: '${e.key} trial=$trial offset=$offset');
              }
            }
          }
          _expectMatchesOld(p.snapshot(), expectedFull, reason: '${e.key} trial=$trial end snapshot');
          _expectMatchesOld(p.finish(), expectedFull, reason: '${e.key} trial=$trial finish');
        }
      }
    });

    test('4. Sliding window (maxLines 1..40) matches windowed OldJobTrace across random chunks', () {
      final extra = List.generate(
        30,
        (i) => 'section_start:${200 + i}:s_$i\r\x1b[3${i % 7}mline $i\nsection_end:${201 + i}:s_$i\r',
      ).join('\n');
      final trace =
          '${fixtures['sections_complex']!}\n${fixtures['timestamps_basic']!}\n$extra';
      final fullOld = OldJobTrace.parse(trace, maxLines: 100000);
      final bytes = Uint8List.fromList(utf8.encode(trace));
      final rng = Random(77);

      for (var maxLines = 1; maxLines <= 40; maxLines++) {
        final p = JobTraceParser(maxLines: maxLines);
        var offset = 0;
        while (offset < bytes.length) {
          final step = rng.nextInt(23) + 1;
          final end = (offset + step < bytes.length) ? offset + step : bytes.length;
          p.addBytes(Uint8List.sublistView(bytes, offset, end));
          offset = end;
        }
        final snap = p.finish();
        _expectWindowMatchesOld(snap, fullOld, maxLines, reason: 'maxLines=$maxLines');
      }
    });

    test('5. Isolate path (> 64 KiB) with adversarial split points (UTF-8, CSI, OSC, markers, timestamp header, CRLF)', () async {
      final pad = List.generate(
        1800,
        (i) => '2026-10-20T06:56:03.100000Z 00O pad line $i with \x1b[32mcolor\x1b[0m and 텍스트\n',
      ).join();
      final tail =
          '2026-10-20T06:56:04.100000Z 00O section_start:500:iso_sec[collapsed=true]\r\x1b[38;2;1;2;3mStart 🚀中é\r\n'
          '2026-10-20T06:56:04.200000Z 00O+\x1b]0;osc title\x07continued after osc\n'
          '2026-10-20T06:56:05.000000Z 00O section_end:505:iso_sec\r\n';
      final full = pad + tail + pad;
      final fullBytes = Uint8List.fromList(utf8.encode(full));
      final expected = OldJobTrace.parse(full);

      final tailStart = utf8.encode(pad).length;
      final rocketIdx = _indexOfSublist(fullBytes, utf8.encode('🚀'), tailStart);
      final cjkIdx = _indexOfSublist(fullBytes, utf8.encode('中'), tailStart);
      final eAcuteIdx = _indexOfSublist(fullBytes, utf8.encode('é'), tailStart);
      final csiIdx = _indexOfSublist(fullBytes, utf8.encode('\x1b[38;2;1;2;3m'), tailStart);
      final oscIdx = _indexOfSublist(fullBytes, utf8.encode('\x1b]0;osc title\x07'), tailStart);
      final markerIdx = _indexOfSublist(fullBytes, utf8.encode('section_start:500'), tailStart);
      final crlfIdx = _indexOfSublist(fullBytes, utf8.encode('\r\n'), tailStart);

      final splits = <int>[
        tailStart + 1,
        tailStart + 16,
        tailStart + 31,
        rocketIdx + 1,
        rocketIdx + 2,
        rocketIdx + 3,
        cjkIdx + 1,
        cjkIdx + 2,
        eAcuteIdx + 1,
        csiIdx + 1,
        csiIdx + 6,
        oscIdx + 1,
        oscIdx + 5,
        markerIdx + 8,
        crlfIdx + 1,
      ];

      for (final split in splits) {
        final chunk1 = Uint8List.sublistView(fullBytes, 0, split);
        final chunk2 = Uint8List.sublistView(fullBytes, split);
        expect(chunk1.length, greaterThan(JobTraceParser.isolateThresholdBytes));
        expect(chunk2.length, greaterThan(JobTraceParser.isolateThresholdBytes));

        final p = JobTraceParser();
        await p.addBytesAsync(chunk1);
        p.snapshot();
        final res = await p.addBytesAsync(chunk2);
        expect(res, isNotNull);
        _expectMatchesOld(res!, expected, reason: 'isolate split=$split snapshot');
        _expectMatchesOld(p.finish(), expected, reason: 'isolate split=$split finish');
      }
    });

    test('6. Snapshot views stay immutable after subsequent appends and sliding-window eviction', () {
      final p = JobTraceParser(maxLines: 600);
      p.addText(List.generate(700, (i) => 'a$i').join('\n'));
      final s1 = p.snapshot();
      final before = [for (final l in s1.lines) l.text];
      p.addText('\n${List.generate(1500, (i) => 'b$i').join('\n')}\n');
      expect([for (final l in s1.lines) l.text], before);
      expect(p.snapshot().lines.length, 600);
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

      // 1. Characters processed equals exact decoded length, and parseSpans
      // character counter is bounded by fullString.length (1x, never quadratic).
      expect(parser.charactersProcessed, fullString.length);
      expect(JobTrace.debugCharactersProcessed, greaterThan(fullString.length ~/ 2));
      expect(JobTrace.debugCharactersProcessed, lessThanOrEqualTo(fullString.length));

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
      await _settleJobLog(tester);

      // After first poll (12,000 lines): no truncation notice yet, and parseSpans
      // characters processed is bounded by chunk1Text.length.
      expect(find.byKey(const ValueKey('job-log-truncated')), findsNothing);
      final afterFirstPoll = JobTrace.debugCharactersProcessed;
      expect(afterFirstPoll, greaterThan(0));
      expect(afterFirstPoll, lessThanOrEqualTo(chunk1Text.length));

      // Trigger second poll (+10,000 lines -> 22,000 lines total > 20,000 limit).
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);

      // Incremental parse processed ONLY chunk2Text, never re-parsing chunk1Text.
      final deltaSecondPoll = JobTrace.debugCharactersProcessed - afterFirstPoll;
      expect(deltaSecondPoll, greaterThan(0));
      expect(deltaSecondPoll, lessThanOrEqualTo(chunk2Text.length));

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

      // Trigger third poll to verify byte offset stayed absolute across window trimming
      // and requested a bounded range.
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      final totalLen = chunk1Bytes.length + chunk2Bytes.length;
      expect(
        requestedRanges,
        contains('bytes=$totalLen-${totalLen + GitLabApi.maxTextBytes - 1}'),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('BLOCKER 1: running job whose first read at offset 0 exceeds 2 MiB falls back to Range: bytes=-2MiB, shows tail + notice, and continues polling', (tester) async {
      // 22,000 timestamped lines (~104 bytes each = 2,288,000 bytes > 2 MiB).
      final fullBuf = StringBuffer();
      for (var i = 0; i < 22000; i++) {
        final s = (i % 60).toString().padLeft(2, '0');
        final m = ((i ~/ 60) % 60).toString().padLeft(2, '0');
        fullBuf.write(
          '2026-10-20T06:$m:$s.123456Z 00O \x1b[32mbuild\x1b[0m output payload line number ${i.toString().padLeft(6, '0')} padding-text-0123456789\n',
        );
      }
      final fullBytes = Uint8List.fromList(utf8.encode(fullBuf.toString()));
      expect(fullBytes.length, greaterThan(GitLabApi.maxTextBytes));

      final tailStart = fullBytes.length - GitLabApi.maxTextBytes;
      final tailSlice = Uint8List.sublistView(fullBytes, tailStart);
      final appendedBytes = Uint8List.fromList(
        utf8.encode('2026-10-20T07:00:00.000000Z 00O fresh polled line 22000\n'),
      );

      final requestedRanges = <String?>[];
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'running', 'name': 'over-2mib-running'});
        }
        if (request.uri.path.endsWith('/trace')) {
          final range = request.headers['Range'] as String?;
          requestedRanges.add(range);
          if (range == null) {
            // Unbounded offset=0 request serves > 2 MiB, triggering tooLarge in Dio.
            return ResponseBody.fromBytes(fullBytes, 200, headers: {
              'content-length': ['${fullBytes.length}'],
            });
          }
          if (range == 'bytes=-${GitLabApi.maxTextBytes}') {
            return ResponseBody.fromBytes(tailSlice, 206, headers: {
              'content-range': [
                'bytes $tailStart-${fullBytes.length - 1}/${fullBytes.length}',
              ],
            });
          }
          final expectedPollRange =
              'bytes=${fullBytes.length}-${fullBytes.length + GitLabApi.maxTextBytes - 1}';
          if (range == expectedPollRange) {
            return ResponseBody.fromBytes(appendedBytes, 206, headers: {
              'content-range': [
                'bytes ${fullBytes.length}-${fullBytes.length + appendedBytes.length - 1}/${fullBytes.length + appendedBytes.length}',
              ],
            });
          }
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

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        workspaceHost(JobLogPage(account: account, api: api, project: project, id: 1)),
      );
      await _settleJobLog(tester);

      // Must NOT fail with tooLarge ('內容超出預覽上限'); shows tail + notice instead.
      expect(find.text('內容超出預覽上限'), findsNothing);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);
      expect(find.textContaining('line number 021999'), findsOneWidget);

      // Enable 10 s auto-refresh and advance timer to verify polling continues from Content-Range end.
      await tester.tap(find.text('10 秒更新'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      await _settleJobLog(tester);

      expect(find.textContaining('fresh polled line 22000'), findsOneWidget);
      expect(requestedRanges, [
        null,
        'bytes=-${GitLabApi.maxTextBytes}',
        'bytes=${fullBytes.length}-${fullBytes.length + GitLabApi.maxTextBytes - 1}',
      ]);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('BLOCKER 2: poll exceeding 2 MiB splits into bounded ranges and recovers via tail read if server ignores bound', (tester) async {
      final initialBytes = Uint8List.fromList(utf8.encode('initial line 0\n'));
      final limit = GitLabApi.maxTextBytes;
      // Simulate a multi-poll catch-up across bounded ranges, then simulate a
      // server ignoring the upper range bound and returning > 2 MiB on poll 3.
      final burstPart1 = Uint8List.fromList(
        utf8.encode('burst part 1 start\nburst part 1 end\n'),
      );
      final burstPart2 = Uint8List.fromList(
        utf8.encode('burst part 2 tail line\n'),
      );
      final oversizedPollBytes = Uint8List(limit + 1024)..fillRange(0, limit + 1024, 0x61);
      final recoveredTailBytes = Uint8List.fromList(
        utf8.encode('recovered after oversized poll\n'),
      );

      final requestedRanges = <String?>[];
      var pollCount = 0;
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'running', 'name': 'burst-poll'});
        }
        if (request.uri.path.endsWith('/trace')) {
          final range = request.headers['Range'] as String?;
          requestedRanges.add(range);
          if (range == null) {
            return ResponseBody.fromBytes(initialBytes, 200);
          }
          if (range == 'bytes=${initialBytes.length}-${initialBytes.length + limit - 1}') {
            pollCount++;
            final start = initialBytes.length;
            final end = start + burstPart1.length - 1;
            final total = start + burstPart1.length + burstPart2.length;
            return ResponseBody.fromBytes(burstPart1, 206, headers: {
              'content-range': ['bytes $start-$end/$total'],
            });
          }
          final offset2 = initialBytes.length + burstPart1.length;
          if (range == 'bytes=$offset2-${offset2 + limit - 1}') {
            pollCount++;
            final end = offset2 + burstPart2.length - 1;
            return ResponseBody.fromBytes(burstPart2, 206, headers: {
              'content-range': ['bytes $offset2-$end/${end + 1}'],
            });
          }
          final offset3 = offset2 + burstPart2.length;
          if (range == 'bytes=$offset3-${offset3 + limit - 1}') {
            pollCount++;
            // Simulate server ignoring the upper range bound and returning > 2 MiB -> triggers tooLarge.
            return ResponseBody.fromBytes(oversizedPollBytes, 206, headers: {
              'content-length': ['${oversizedPollBytes.length}'],
              'content-range': [
                'bytes $offset3-${offset3 + oversizedPollBytes.length - 1}/${offset3 + oversizedPollBytes.length}',
              ],
            });
          }
          if (range == 'bytes=-$limit') {
            final newTotal = 5000000;
            final start = newTotal - recoveredTailBytes.length;
            return ResponseBody.fromBytes(recoveredTailBytes, 206, headers: {
              'content-range': ['bytes $start-${newTotal - 1}/$newTotal'],
            });
          }
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

      await tester.pumpWidget(
        workspaceHost(JobLogPage(account: account, api: api, project: project, id: 1)),
      );
      await _settleJobLog(tester);
      expect(find.text('initial line 0'), findsOneWidget);

      // Poll 1: bounded range from initialBytes.length.
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(find.text('burst part 1 end'), findsOneWidget);

      // Poll 2: bounded range from offset2.
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(find.text('burst part 2 tail line'), findsOneWidget);

      // Poll 3: server returns > 2 MiB -> page recovers with Range: bytes=-2MiB and shows notice.
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(find.text('內容超出預覽上限'), findsNothing);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);
      expect(find.text('recovered after oversized poll'), findsOneWidget);
      final offset2 = initialBytes.length + burstPart1.length;
      final offset3 = offset2 + burstPart2.length;
      expect(pollCount, 3);
      expect(requestedRanges, [
        null,
        'bytes=${initialBytes.length}-${initialBytes.length + limit - 1}',
        'bytes=$offset2-${offset2 + limit - 1}',
        'bytes=$offset3-${offset3 + limit - 1}',
        'bytes=-$limit',
      ]);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('SHOULD-FIX 1: terminal fallback tooLarge does not corrupt live _parser on retry', (tester) async {
      final oversizedLines = List.generate(20005, (i) => 'line $i').join('\n');
      var attempt = 0;
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'success', 'name': 'term-fallback'});
        }
        if (request.uri.path.endsWith('/trace')) {
          final range = request.headers['Range'] as String?;
          if (range != null && range.startsWith('bytes=-')) {
            // Return 200 without Content-Length so _terminalTail treats tail as unsupported.
            return ResponseBody.fromString('unsupported', 200);
          }
          attempt++;
          if (attempt == 1) {
            return ResponseBody.fromString(oversizedLines, 200);
          }
          return ResponseBody.fromString('clean retry line\n', 200);
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

      await tester.pumpWidget(
        workspaceHost(JobLogPage(account: account, api: api, project: project, id: 1)),
      );
      await _settleJobLog(tester);

      // First attempt fails with tooLarge.
      expect(find.text('內容超出預覽上限'), findsOneWidget);

      // Retry: because targetParser was isolated from _parser, the retry shows
      // 'clean retry line' cleanly instead of throwing tooLarge again.
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(find.text('內容超出預覽上限'), findsNothing);
      expect(find.text('clean retry line'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('NIT: terminal job at EOF flushes trailing incomplete UTF-8 sequence to U+FFFD', (tester) async {
      // 'Hello ' followed by 2 bytes of a 3-byte UTF-8 character (0xE4, 0xB8).
      final incompleteBytes = Uint8List.fromList([
        ...utf8.encode('Hello '),
        0xE4,
        0xB8,
      ]);
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'success', 'name': 'eof-utf8'});
        }
        if (request.uri.path.endsWith('/trace')) {
          return ResponseBody.fromBytes(incompleteBytes, 200, headers: {
            'content-length': ['${incompleteBytes.length}'],
          });
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

      await tester.pumpWidget(
        workspaceHost(JobLogPage(account: account, api: api, project: project, id: 1)),
      );
      await _settleJobLog(tester);

      expect(find.text('Hello \uFFFD'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}

Future<void> _settleJobLog(WidgetTester tester) async {
  await tester.pump();
  await pumpUntil(
    tester,
    () =>
        find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(LogSkeleton).evaluate().isEmpty,
    step: const Duration(milliseconds: 5),
    description: 'JobLogPage load finished',
  );
  await tester.pump();
  await tester.pump();
}

int _indexOfSublist(List<int> haystack, List<int> needle, [int start = 0]) {
  for (var i = start; i <= haystack.length - needle.length; i++) {
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

bool _hasIncompleteTrailingUtf8(Uint8List bytes) {
  if (bytes.isEmpty) return false;
  final tailLen = bytes.length < 3 ? bytes.length : 3;
  var leadPos = -1;
  for (var i = bytes.length - 1; i >= bytes.length - tailLen; i--) {
    final b = bytes[i];
    if ((b & 0xC0) != 0x80) {
      leadPos = i;
      break;
    }
  }
  if (leadPos < 0) return false;
  final lead = bytes[leadPos];
  if (lead < 0xC2 || lead > 0xF4) return false;
  final expectedLen = lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4);
  final remaining = bytes.length - leadPos;
  if (remaining >= expectedLen) return false;
  for (var i = leadPos + 1; i < bytes.length; i++) {
    final b = bytes[i];
    if ((b & 0xC0) != 0x80) return false;
    if (i == leadPos + 1) {
      if (lead == 0xE0 && b < 0xA0) return false;
      if (lead == 0xED && b > 0x9F) return false;
      if (lead == 0xF0 && b < 0x90) return false;
      if (lead == 0xF4 && b > 0x8F) return false;
    }
  }
  return true;
}

void _expectMatchesOld(JobTrace actual, OldJobTrace expected, {required String reason}) {
  expect(actual.lines.length, expected.lines.length, reason: '$reason lines.length');
  for (var i = 0; i < expected.lines.length; i++) {
    final a = actual.lines[i];
    final e = expected.lines[i];
    expect(a.text, e.text, reason: '$reason line[$i].text');
    expect(a.lowerText, e.text.toLowerCase(), reason: '$reason line[$i].lowerText');
    expect(a.section, e.section, reason: '$reason line[$i].section');
    expect(a.spans.length, e.spans.length, reason: '$reason line[$i].spans.length');
    for (var s = 0; s < e.spans.length; s++) {
      expect(a.spans[s].text, e.spans[s].text, reason: '$reason line[$i].span[$s].text');
      expect(a.spans[s].style, e.spans[s].style, reason: '$reason line[$i].span[$s].style');
    }
  }
  expect(actual.sections.length, expected.sections.length, reason: '$reason sections.length');
  for (var i = 0; i < expected.sections.length; i++) {
    final a = actual.sections[i];
    final e = expected.sections[i];
    expect(a.name, e.name, reason: '$reason section[$i].name');
    expect(a.start, e.start, reason: '$reason section[$i].start');
    expect(a.end, e.end, reason: '$reason section[$i].end');
    expect(a.collapsed, e.collapsed, reason: '$reason section[$i].collapsed');
    expect(a.startLine, e.startLine, reason: '$reason section[$i].startLine');
    expect(a.endLine, e.endLine, reason: '$reason section[$i].endLine');
    expect(a.depth, e.depth, reason: '$reason section[$i].depth');
    expect(a.durationSeconds, e.durationSeconds, reason: '$reason section[$i].durationSeconds');
    expect(a.label, e.label, reason: '$reason section[$i].label');
  }
}

void _expectWindowMatchesOld(
  JobTrace actual,
  OldJobTrace fullOld,
  int maxLines, {
  required String reason,
}) {
  final total = fullOld.lines.length;
  final truncated = total > maxLines;
  final windowStart = truncated ? total - maxLines : 0;
  expect(actual.truncated, truncated, reason: '$reason truncated');
  final expectedLines = fullOld.lines.sublist(windowStart);
  expect(actual.lines.length, expectedLines.length, reason: '$reason lines.length');
  for (var i = 0; i < expectedLines.length; i++) {
    expect(actual.lines[i].text, expectedLines[i].text, reason: '$reason line[$i].text');
    expect(actual.lines[i].section, expectedLines[i].section, reason: '$reason line[$i].section');
    expect(actual.lines[i].spans, expectedLines[i].spans, reason: '$reason line[$i].spans');
  }
  final expectedSections = <OldJobTraceSection>[];
  for (final s in fullOld.sections) {
    if (windowStart > 0 && s.startLine < windowStart && s.endLine <= windowStart) {
      continue;
    }
    expectedSections.add(
      OldJobTraceSection(
        name: s.name,
        start: s.start,
        end: s.end,
        collapsed: s.collapsed,
        startLine: s.startLine <= windowStart ? 0 : s.startLine - windowStart,
        endLine: s.endLine <= windowStart ? 0 : s.endLine - windowStart,
        depth: s.depth,
      ),
    );
  }
  expect(actual.sections.length, expectedSections.length, reason: '$reason sections.length');
  for (var i = 0; i < expectedSections.length; i++) {
    final a = actual.sections[i];
    final e = expectedSections[i];
    expect(a.name, e.name, reason: '$reason sec[$i].name');
    expect(a.startLine, e.startLine, reason: '$reason sec[$i].startLine');
    expect(a.endLine, e.endLine, reason: '$reason sec[$i].endLine');
    expect(a.depth, e.depth, reason: '$reason sec[$i].depth');
    expect(a.end, e.end, reason: '$reason sec[$i].end');
  }
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
