import 'dart:async';
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
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
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

  test('jobTraceChunk bounded from byte 0 sends bytes=0-(budget-1) and reports the total', () async {
    RequestOptions? captured;
    final api = testApi(FakeAdapter((request) {
      captured = request;
      return ResponseBody.fromString('head', 206, headers: {
        'content-range': ['bytes 0-3/5000000'],
      });
    }));
    addTearDown(api.close);
    final result = await api.jobTraceChunk(42, 1, bounded: true);
    expect(captured!.headers['Range'], 'bytes=0-${GitLabApi.maxTextBytes - 1}');
    expect(captured!.uri.queryParameters['offset'], isNull);
    expect(result.startOffset, 0);
    expect(result.nextOffset, 4);
    expect(result.totalBytes, 5000000);
    // The default (unbounded) shape is unchanged for other callers.
    await api.jobTraceChunk(42, 1);
    expect(captured!.headers['Range'], isNull);
  });

  test('jobTraceChunk on a server ignoring Range (200, whole log): bytes past the offset; a shorter body is returned whole from byte 0', () async {
    var body = 'first line\nsecond line\n';
    final api = testApi(FakeAdapter((request) => ResponseBody.fromString(body, 200)));
    addTearDown(api.close);
    final grown = await api.jobTraceChunk(42, 1, offset: 11, bounded: true);
    expect(utf8.decode(grown.bytes), 'second line\n');
    expect(grown.startOffset, 11);
    expect(grown.nextOffset, 23);
    expect(grown.totalBytes, isNull);
    final same = await api.jobTraceChunk(42, 1, offset: 23, bounded: true);
    expect(same.bytes, isEmpty);
    expect(same.startOffset, 23);
    expect(same.nextOffset, 23);
    expect(same.totalBytes, isNull);
    body = 'replaced\n';
    final replaced = await api.jobTraceChunk(42, 1, offset: 23, bounded: true);
    expect(utf8.decode(replaced.bytes), 'replaced\n');
    expect(replaced.startOffset, 0);
    expect(replaced.nextOffset, 9);
    body = '';
    final erased = await api.jobTraceChunk(42, 1, offset: 23, bounded: true);
    expect(erased.bytes, isEmpty);
    expect(erased.nextOffset, 23, reason: 'an empty body keeps what is shown');
  });

  group('jobTraceChunk streaming when server ignores Range with 200 (#62)', () {
    // Dio subscribes to the adapter's stream as soon as the headers arrive and
    // its response interceptors take a timer turn before GitLabApi sees the
    // response, so a fake that sends on the first turn always sends once
    // before any cancel. What the cancel proves is that the download stops:
    // the source is cancelled long before it would have finished.
    ({ResponseBody body, int Function() sent, bool Function() cancelled})
        slowBody(List<int> bytes, {int step = 16, Map<String, List<String>> headers = const {}}) {
      var sent = 0;
      var cancelled = false;
      final body = ResponseBody(
        Stream<Uint8List>.multi((sink) {
          sink.onCancel = () => cancelled = true;
          Future<void> pump() async {
            for (var i = 0; i < bytes.length && !cancelled; i += step) {
              await Future<void>.delayed(Duration.zero);
              if (cancelled) return;
              sent++;
              sink.add(Uint8List.fromList(bytes.sublist(i, min(i + step, bytes.length))));
            }
            if (!cancelled) await sink.close();
          }

          unawaited(pump());
        }),
        200,
        headers: headers,
      );
      return (body: body, sent: () => sent, cancelled: () => cancelled);
    }

    test('200 ignoring Range: offset read discards prefix across chunks and tail read uses ring buffer with skipCutLine', () async {
      const cut = 'partial line at start of tail window\n';
      const rest = '2026-10-20T06:56:03.100000Z 00O first complete tail line\n'
          '2026-10-20T06:56:04.100000Z 00O final tail line\n';
      final tailWindow = [...utf8.encode(cut), ...utf8.encode(rest)];
      final prefix = List<int>.filled(300, 0x78); // 300 'x' bytes before the window
      final fullBytes = Uint8List.fromList([...prefix, ...tailWindow]);

      Stream<Uint8List> chunked(Uint8List data, int step) async* {
        for (var i = 0; i < data.length; i += step) {
          yield Uint8List.sublistView(data, i, min(i + step, data.length));
        }
      }

      final api = testApi(FakeAdapter((request) => ResponseBody(
        chunked(fullBytes, 17),
        200,
        headers: {
          'content-length': ['${fullBytes.length}'],
        },
      )));
      addTearDown(api.close);

      // 1. Offset read: discards the first 300 + cut.length bytes and keeps `rest`.
      final offsetTarget = prefix.length + utf8.encode(cut).length;
      final offsetRes = await api.jobTraceChunk(
        42,
        1,
        offset: offsetTarget,
        maxBytes: 256,
        bounded: true,
      );
      expect(utf8.decode(offsetRes.bytes), rest);
      expect(offsetRes.startOffset, offsetTarget);
      expect(offsetRes.nextOffset, fullBytes.length);
      expect(offsetRes.totalBytes, fullBytes.length);

      // 2. Tail read: keeps only the last `tailWindow.length` bytes in the ring
      // buffer and aligns to the next line via skipCutLine.
      final tailRes = await api.jobTraceChunk(
        42,
        1,
        tail: true,
        maxBytes: tailWindow.length,
      );
      expect(utf8.decode(tailRes.bytes), rest);
      expect(tailRes.startOffset, prefix.length + utf8.encode(cut).length);
      expect(tailRes.startOffset! + tailRes.bytes.length, fullBytes.length);
      expect(tailRes.nextOffset, fullBytes.length);
      expect(tailRes.totalBytes, fullBytes.length);
      final parsed = JobTraceParser().addBytes(tailRes.bytes, isLast: true);
      expect(parsed.lines.map((l) => l.text).toList(), [
        'first complete tail line',
        'final tail line',
        '',
      ]);

      // 3. Tail read when total <= limit: keeps the whole body from byte 0
      // without dropping the first line.
      final wholeTail = await api.jobTraceChunk(
        42,
        1,
        tail: true,
        maxBytes: fullBytes.length + 100,
      );
      expect(wholeTail.bytes, fullBytes);
      expect(wholeTail.startOffset, 0);
      expect(wholeTail.nextOffset, fullBytes.length);
      expect(wholeTail.totalBytes, fullBytes.length);
    });

    test('kept-bytes budget: discarded offset bytes do not count; a bounded read keeps the budget and the next read goes on, an unbounded one fails with tooLarge', () async {
      const limit = GitLabApi.maxTextBytes;
      // 3 MiB discarded, then the bytes after the offset.
      const discarded = 3 * 1024 * 1024;
      final chunk64K = Uint8List.fromList(List<int>.generate(64 * 1024, (i) => 0x61 + (i % 26)));
      var keptChunks = limit ~/ chunk64K.length;
      var streamCancelled = false;
      var emittedChunks = 0;
      final api = testApi(FakeAdapter((request) {
        final totalChunks = discarded ~/ chunk64K.length + keptChunks;
        return ResponseBody(
          Stream<Uint8List>.multi((sink) {
            sink.onCancel = () {
              streamCancelled = true;
            };
            Future<void> pump() async {
              for (var i = 0; i < totalChunks && !streamCancelled; i++) {
                emittedChunks++;
                sink.add(chunk64K);
                await Future<void>.delayed(Duration.zero);
              }
              if (!streamCancelled) {
                await sink.close();
              }
            }

            unawaited(pump());
          }),
          200,
        );
      }));
      addTearDown(api.close);

      // Exactly 2 MiB kept after discarding 3 MiB.
      final ok = await api.jobTraceChunk(42, 1, offset: discarded, bounded: true);
      expect(ok.bytes.length, limit);
      expect(ok.startOffset, discarded);
      expect(ok.nextOffset, discarded + limit);
      expect(ok.totalBytes, isNull);

      // 10 more chunks after the offset: a bounded read keeps exactly the
      // budget, as a 206 for bytes=offset-(offset+limit-1) would, and stops
      // the download. The next read starts where it stopped.
      keptChunks += 10;
      streamCancelled = false;
      emittedChunks = 0;
      final first = await api.jobTraceChunk(42, 1, offset: discarded, bounded: true);
      expect(first.bytes.length, limit);
      expect(first.startOffset, discarded);
      expect(first.nextOffset, discarded + limit);
      expect(first.totalBytes, isNull);
      expect(streamCancelled, isTrue);
      expect(emittedChunks, lessThan(80 + 10), reason: 'stopped before the end of the body');
      streamCancelled = false;
      final next = await api.jobTraceChunk(42, 1, offset: first.nextOffset!, bounded: true);
      expect(next.bytes.length, 10 * chunk64K.length);
      expect(next.startOffset, discarded + limit);
      expect(next.nextOffset, discarded + limit + 10 * chunk64K.length);

      // Unbounded (other callers, like `bytes=offset-` on the Range path):
      // more than the budget after the offset fails with tooLarge.
      streamCancelled = false;
      emittedChunks = 0;
      await expectLater(
        api.jobTraceChunk(42, 1, offset: discarded),
        throwsA(isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.tooLarge)),
      );
      expect(streamCancelled, isTrue);
      expect(emittedChunks, lessThan(80 + 10));

      // A Content-Length with more than the budget after the offset: an
      // unbounded read fails before reading the body; a bounded one keeps the
      // budget and reports the total.
      final bytes = List<int>.filled(discarded + limit + 10, 0x61);
      final declared = <({int Function() sent, bool Function() cancelled})>[];
      final declaredApi = testApi(FakeAdapter((request) {
        final body = slowBody(bytes, step: 64 * 1024, headers: {
          'content-length': ['${bytes.length}'],
        });
        declared.add((sent: body.sent, cancelled: body.cancelled));
        return body.body;
      }));
      addTearDown(declaredApi.close);
      await expectLater(
        declaredApi.jobTraceChunk(42, 1, offset: discarded),
        throwsA(isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.tooLarge)),
      );
      expect(declared.last.cancelled(), isTrue);
      expect(declared.last.sent(), lessThan(10));
      final bounded = await declaredApi.jobTraceChunk(42, 1, offset: discarded, bounded: true);
      expect(bounded.bytes.length, limit);
      expect(bounded.nextOffset, discarded + limit);
      expect(bounded.totalBytes, bytes.length);
      expect(declared.last.cancelled(), isTrue);
    });

    test('total-bytes cap (64 MiB): fails with tooLarge when streamed bytes or Content-Length exceed 64 MiB', () async {
      const cap = GitLabApi.maxTraceStreamBytes;
      final oneMiB = Uint8List(1024 * 1024);

      for (final tail in [false, true]) {
        var chunksEmitted = 0;
        var cancelled = false;
        final streamApi = testApi(FakeAdapter((request) => ResponseBody(
          Stream<Uint8List>.multi((sink) {
            sink.onCancel = () {
              cancelled = true;
            };
            Future<void> emit() async {
              while (!cancelled && chunksEmitted < 100) {
                chunksEmitted++;
                sink.add(oneMiB);
                await Future<void>.delayed(Duration.zero);
              }
              if (!cancelled) await sink.close();
            }

            unawaited(emit());
          }),
          200,
        )));
        addTearDown(streamApi.close);

        await expectLater(
          streamApi.jobTraceChunk(
            42,
            1,
            offset: tail ? 0 : cap - 1024 * 1024,
            tail: tail,
            bounded: !tail,
          ),
          throwsA(isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.tooLarge)),
        );
        expect(cancelled, isTrue);
        expect(chunksEmitted, 65, reason: 'stops on the chunk that crosses 64 MiB');

        // Also when Content-Length > 64 MiB: cancels on the headers, so the
        // download stops after the first bytes Dio buffered.
        final declared = slowBody(List<int>.filled(64 * 100, 0x61), step: 64, headers: {
          'content-length': ['${cap + 1}'],
        });
        final headerApi = testApi(FakeAdapter((request) => declared.body));
        addTearDown(headerApi.close);
        await expectLater(
          headerApi.jobTraceChunk(42, 1, offset: 0, tail: tail, bounded: !tail),
          throwsA(isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.tooLarge)),
        );
        expect(declared.cancelled(), isTrue);
        expect(declared.sent(), lessThan(10), reason: 'of 100 chunks');
      }
    });

    test('Content-Length early cancel: equal to the offset (nothing new) or 0 (erased) cancels before the body and reports no new data; shorter is a replaced log read from byte 0', () async {
      for (final declaredLength in [500, 0]) {
        var dioCancelled = false;
        final slow = slowBody(
          utf8.encode('must not be read\n' * 100),
          headers: {
            'content-length': ['$declaredLength'],
          },
        );
        final adapter = FakeAdapter((request) => slow.body);
        final api = testApi(adapter);
        addTearDown(api.close);

        final res = await api.jobTraceChunk(42, 1, offset: 500, bounded: true);
        await adapter.cancelFutures.single!.then((_) => dioCancelled = true);
        expect(dioCancelled, isTrue, reason: 'CancelToken cancelled for Content-Length=$declaredLength');
        expect(slow.cancelled(), isTrue, reason: 'body stream cancelled for Content-Length=$declaredLength');
        expect(slow.sent(), lessThan(10), reason: 'of 107 chunks for Content-Length=$declaredLength');
        expect(res.bytes, isEmpty);
        expect(res.startOffset, 500);
        expect(res.nextOffset, 500);
        expect(res.totalBytes, isNull);
      }

      // Shorter than the offset: the log was replaced. It is read whole from
      // byte 0, as before #62, so the page restarts from it.
      final replaced = utf8.encode('replaced\n' * 25);
      final shorterApi = testApi(FakeAdapter((request) => ResponseBody.fromBytes(
        replaced,
        200,
        headers: {
          'content-length': ['${replaced.length}'],
        },
      )));
      addTearDown(shorterApi.close);
      final shorter = await shorterApi.jobTraceChunk(42, 1, offset: 500, bounded: true);
      expect(shorter.bytes, replaced);
      expect(shorter.startOffset, 0);
      expect(shorter.nextOffset, replaced.length);
      expect(shorter.totalBytes, replaced.length);
      expect(shorter.rangeIgnored, isTrue);

      // A replaced log over the budget fails before its body, as a whole
      // read of it did.
      final big = slowBody(List<int>.filled(64 * 100, 0x61), step: 64, headers: {
        'content-length': ['${GitLabApi.maxTextBytes + 1}'],
      });
      final bigApi = testApi(FakeAdapter((request) => big.body));
      addTearDown(bigApi.close);
      await expectLater(
        bigApi.jobTraceChunk(42, 1, offset: GitLabApi.maxTextBytes + 100, bounded: true),
        throwsA(isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.tooLarge)),
      );
      expect(big.cancelled(), isTrue);
      expect(big.sent(), lessThan(10), reason: 'of 100 chunks');

      // When Content-Length is present and larger than offset, it is used for totalBytes.
      final body = utf8.encode('0123456789new data\n');
      final largerApi = testApi(FakeAdapter((request) => ResponseBody.fromBytes(
        body,
        200,
        headers: {
          'content-length': ['${body.length}'],
        },
      )));
      addTearDown(largerApi.close);
      final larger = await largerApi.jobTraceChunk(42, 1, offset: 10, bounded: true);
      expect(utf8.decode(larger.bytes), 'new data\n');
      expect(larger.startOffset, 10);
      expect(larger.nextOffset, body.length);
      expect(larger.totalBytes, body.length);
    });

    test('no Content-Length: streams offset and tail reads with null totalBytes', () async {
      const head = 'line 0\nline 1\n';
      const cut = 'cut middle line\n';
      const tailLines = 'kept line A\nkept line B\n';
      final allBytes = Uint8List.fromList(utf8.encode('$head$cut$tailLines'));
      final tailBudget = utf8.encode('$cut$tailLines').length;

      Stream<Uint8List> makeStream() async* {
        for (var i = 0; i < allBytes.length; i += 5) {
          yield Uint8List.sublistView(allBytes, i, min(i + 5, allBytes.length));
        }
      }

      final api = testApi(FakeAdapter((_) => ResponseBody(makeStream(), 200)));
      addTearDown(api.close);

      final offsetChunk = await api.jobTraceChunk(
        42,
        1,
        offset: utf8.encode('$head$cut').length,
        bounded: true,
      );
      expect(utf8.decode(offsetChunk.bytes), tailLines);
      expect(offsetChunk.startOffset, utf8.encode('$head$cut').length);
      expect(offsetChunk.nextOffset, allBytes.length);
      expect(offsetChunk.totalBytes, isNull);

      final tailChunk = await api.jobTraceChunk(
        42,
        1,
        tail: true,
        maxBytes: tailBudget,
      );
      expect(utf8.decode(tailChunk.bytes), tailLines);
      expect(tailChunk.startOffset, utf8.encode('$head$cut').length);
      expect(tailChunk.nextOffset, allBytes.length);
      expect(tailChunk.totalBytes, isNull);
    });

    test('a multi-byte UTF-8 character across the skip or budget boundary is never split (offset and tail reads)', () async {
      // '🚀' is 4 bytes [0xF0, 0x9F, 0x9A, 0x80]; '中' is 3 bytes [0xE4, 0xB8, 0xAD].
      final prefix = utf8.encode('prefix ');
      final rocket = utf8.encode('🚀'); // 4 bytes
      final cutRest = utf8.encode(' mid-line\n');
      final afterNewline = utf8.encode('clean line 中🎉\n');
      final full = Uint8List.fromList([...prefix, ...rocket, ...cutRest, ...afterNewline]);

      Stream<Uint8List> oneByteAtATime(Uint8List bytes) async* {
        for (var i = 0; i < bytes.length; i++) {
          yield Uint8List.sublistView(bytes, i, i + 1);
        }
      }

      final api = testApi(FakeAdapter((_) => ResponseBody(oneByteAtATime(full), 200)));
      addTearDown(api.close);

      // 1. An offset read continues the previous read byte for byte, as a 206
      // does: a budget that ends inside '🚀' leaves its first bytes in the
      // decoder, and the next read starts with the rest of it.
      final rangeApi = testApi(FakeAdapter((request) => _serveRange(full, request.headers['Range'] as String?)));
      addTearDown(rangeApi.close);
      for (var split = 1; split < rocket.length; split++) {
        final budget = prefix.length + split;
        final head = await api.jobTraceChunk(42, 1, bounded: true, maxBytes: budget);
        expect(head.bytes, full.sublist(0, budget));
        expect(head.nextOffset, budget);
        final viaRange = await rangeApi.jobTraceChunk(42, 1, bounded: true, maxBytes: budget);
        expect(head.bytes, viaRange.bytes, reason: 'same bytes as the Range path');
        final rest = await api.jobTraceChunk(42, 1, offset: budget, bounded: true);
        expect(rest.startOffset, budget);
        expect(rest.bytes, full.sublist(budget));
        expect(rest.nextOffset, full.length);
        final parser = JobTraceParser()..addBytes(head.bytes);
        expect(
          parser.addBytes(rest.bytes, isLast: true).lines.map((l) => l.text).toList(),
          ['prefix 🚀 mid-line', 'clean line 中🎉', ''],
        );
      }

      // 2. Tail read whose ring-buffer start lands at each continuation byte inside '🚀',
      // followed by a newline (skipCutLine aligns to afterNewline):
      for (var split = 1; split < rocket.length; split++) {
        final windowSize = (rocket.length - split) + cutRest.length + afterNewline.length;
        final res = await api.jobTraceChunk(42, 1, tail: true, maxBytes: windowSize);
        expect(utf8.decode(res.bytes), 'clean line 中🎉\n');
        expect(res.startOffset, prefix.length + rocket.length + cutRest.length);
        expect(res.startOffset! + res.bytes.length, full.length);
        expect(res.nextOffset, full.length);
      }

      // 3. Single-line tail read (no newline to align on) whose ring-buffer start
      // lands inside '🚀': drops only the dangling continuation bytes so UTF-8 stays valid.
      final singleLine = Uint8List.fromList([...prefix, ...rocket, ...utf8.encode('one long line 中')]);
      final singleLineApi = testApi(FakeAdapter((_) => ResponseBody(oneByteAtATime(singleLine), 200)));
      addTearDown(singleLineApi.close);
      for (var split = 1; split < rocket.length; split++) {
        final windowSize = (rocket.length - split) + utf8.encode('one long line 中').length;
        final res = await singleLineApi.jobTraceChunk(42, 1, tail: true, maxBytes: windowSize);
        expect(utf8.decode(res.bytes), 'one long line 中');
        expect(res.startOffset, prefix.length + rocket.length);
        expect(res.startOffset! + res.bytes.length, singleLine.length);
        expect(res.nextOffset, singleLine.length);
      }
    });

    test('closing the client while a 200 streams fails with cancelled and stops the download (offset and tail)', () async {
      for (final tail in [false, true]) {
        final slow = slowBody(List<int>.filled(16 * 1000, 0x61));
        final api = testApi(FakeAdapter((request) => slow.body));
        final read = api.jobTraceChunk(42, 1, offset: tail ? 0 : 64, tail: tail, bounded: !tail);
        while (slow.sent() < 5) {
          await Future<void>.delayed(Duration.zero);
        }
        api.close();
        await expectLater(
          read,
          throwsA(isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.cancelled)),
          reason: tail ? 'tail' : 'offset',
        );
        expect(slow.cancelled(), isTrue);
        expect(slow.sent(), lessThan(1000));
      }
    });
  });

  test('jobTraceChunk tail starting mid-line drops the cut line and keeps offsets absolute', () async {
    const cut = 'ut off part of a line\n';
    const rest = '2026-10-20T06:56:03.100000Z 00O next whole line\n'
        '2026-10-20T06:56:04.100000Z 00O last line\n';
    final body = [0x80, 0x80, ...utf8.encode(cut), ...utf8.encode(rest)];
    const start = 5000;
    final total = start + body.length;
    final api = testApi(FakeAdapter((request) {
      expect(request.headers['Range'], 'bytes=-${GitLabApi.maxTextBytes}');
      return ResponseBody.fromBytes(body, 206, headers: {
        'content-range': ['bytes $start-${total - 1}/$total'],
      });
    }));
    addTearDown(api.close);
    final result = await api.jobTraceChunk(42, 1, tail: true);
    expect(utf8.decode(result.bytes), rest);
    expect(result.startOffset, start + 2 + utf8.encode(cut).length);
    expect(result.startOffset! + result.bytes.length, total);
    expect(result.nextOffset, total);
    expect(result.totalBytes, total);
    // Parsed from a whole line, the runner timestamps are stripped.
    final trace = JobTraceParser().addBytes(result.bytes, isLast: true);
    expect(trace.lines.map((l) => l.text).toList(), ['next whole line', 'last line', '']);
  });

  test('jobTraceChunk tail that is one long line keeps it (no newline to align on)', () async {
    final api = testApi(FakeAdapter((request) => ResponseBody.fromString('one long line', 206, headers: {
      'content-range': ['bytes 10-22/23'],
    })));
    addTearDown(api.close);
    final result = await api.jobTraceChunk(42, 1, tail: true);
    expect(utf8.decode(result.bytes), 'one long line');
    expect(result.startOffset, 10);
    expect(result.nextOffset, 23);
  });

  test('jobTraceChunk tail 206 without Content-Range claims no absolute offset', () async {
    final api = testApi(FakeAdapter((request) => ResponseBody.fromString('tail bytes\n', 206)));
    addTearDown(api.close);
    final result = await api.jobTraceChunk(42, 1, tail: true);
    expect(utf8.decode(result.bytes), 'tail bytes\n');
    expect(result.startOffset, isNull);
    expect(result.nextOffset, isNull);
    expect(result.totalBytes, isNull);
  });

  test('cachedTerminalJobTrace suffix starting mid-line starts on a whole line with absolute offsets', () async {
    final head = StringBuffer();
    for (var i = 0; i < 30000; i++) {
      head.write('2026-10-20T06:56:03.100000Z 00O terminal output line number $i of the job\n');
    }
    final all = utf8.encode(head.toString());
    expect(all.length, greaterThan(readCacheTerminalLogLimit));
    final from = all.length - readCacheTerminalLogLimit;
    expect(all[from - 1], isNot(0x0A), reason: 'the fixture cuts inside a line');
    final api = testApi(FakeAdapter((request) {
      if (request.uri.path.endsWith('/jobs/1')) {
        return jsonResponse({
          'id': 1, 'status': 'failed', 'name': 'terminal',
          'pipeline': {'id': 9, 'project_id': 42},
          'erased_at': null, 'finished_at': '2026-10-20T07:00:00Z',
        });
      }
      expect(request.headers['Range'], 'bytes=-$readCacheTerminalLogLimit');
      return ResponseBody.fromBytes(all.sublist(from), 206, headers: {
        'content-range': ['bytes $from-${all.length - 1}/${all.length}'],
        'content-length': ['$readCacheTerminalLogLimit'],
      });
    }));
    addTearDown(api.close);
    final log = (await api.cachedTerminalJobTrace(42, 1)).value;
    final skipped = all.indexOf(0x0A, from) + 1 - from;
    expect(log.startOffset, from + skipped);
    expect(all[log.startOffset - 1], 0x0A);
    expect(log.bytes, all.sublist(log.startOffset));
    expect(log.nextOffset, all.length);
    expect(log.truncated, isTrue);
    final trace = JobTraceParser().addBytes(log.bytes, isLast: true);
    expect(trace.lines.first.text, startsWith('terminal output line number'));
    expect(trace.lines.where((l) => l.text.contains('Z 00O')), isEmpty);
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

    test('keeps an unterminated \\r progress line whole: old-parser output, counted work and memory', () {
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
      // The pending line is never capped: the rows are exactly the old
      // whole-text parser's rows for the same input.
      _expectMatchesOld(
        snap,
        OldJobTrace.parse(utf8.decode([for (var i = 0; i < 50; i++) ...chunk])),
        reason: 'pending \\r line',
      );
      expect(snap.lines.map((l) => l.text).join().length, 20000);
      // estimatedBytes counts the retained raw pending line (2 bytes per code
      // unit); the input is within the 2 MiB read budget, so is the estimate.
      expect(parser.estimatedBytes, greaterThanOrEqualTo(2 * 50 * (chunk.length - 1)));
      expect(parser.estimatedBytes, lessThan(2 * GitLabApi.maxTextBytes));
      // Every snapshot re-parses the pending line once (counted), and never
      // more than that: at most one preview parse per snapshot.
      expect(JobTrace.debugCharactersProcessed, greaterThanOrEqualTo(50 * (chunk.length - 1)));
      expect(JobTrace.debugCharactersProcessed, lessThanOrEqualTo(chunk.length * 50 * 51 ~/ 2));
    });

    test('lines longer than 64K characters spanning many chunks match the old parser (plain, marker, SGR, isolate)', () async {
      final cases = <String, String>{
        'plain 100K line': '${'a' * 100000}\nafter\n',
        'section_end inside the long prefix':
            'section_start:1:outer[collapsed=true]\rhead\nsection_end:2:outer\r${'b' * 100000}\nafter outside\n',
        'SGR inside the long prefix': '\x1b[31m${'r' * 100000}\nnext line should be red\n',
        'SGR change late in a long line':
            '${'p' * 70000}\x1b[1;32m${'g' * 40000}\nstill bold green\n',
        'progress residual':
            '${List.generate(2000, (i) => 'Progress ${'#' * 30} ${i.toString().padLeft(5)}').join('\r')}\rDone\n',
      };
      for (final entry in cases.entries) {
        final bytes = utf8.encode(entry.value);
        final expected = OldJobTrace.parse(entry.value);
        // 5,000-byte chunks: the pending line passes 64K characters long before
        // its newline; every snapshot equals the old parse of that prefix.
        final p = JobTraceParser();
        for (var i = 0; i < bytes.length; i += 5000) {
          final end = i + 5000 < bytes.length ? i + 5000 : bytes.length;
          p.addBytes(bytes.sublist(i, end));
          _expectMatchesOld(
            p.snapshot(),
            OldJobTrace.parse(utf8.decode(bytes.sublist(0, end))),
            reason: '${entry.key} prefix=$end',
          );
        }
        _expectMatchesOld(p.finish(), expected, reason: '${entry.key} finish');
        // The same text through the background isolate (> 64 KiB chunks).
        final iso = JobTraceParser();
        final first = await iso.addBytesAsync(bytes.sublist(0, 70000));
        expect(first, isNotNull);
        final last = await iso.addBytesAsync(bytes.sublist(70000), isLast: true);
        _expectMatchesOld(last!, expected, reason: '${entry.key} isolate');
      }
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

    testWidgets('BLOCKER 1: running job whose bounded first read reports more than 2 MiB reads Range: bytes=-2MiB, shows tail + notice, and continues polling', (tester) async {
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
          if (range == 'bytes=0-${GitLabApi.maxTextBytes - 1}') {
            // The bounded first read reports the total: more than one budget.
            return ResponseBody.fromBytes(
              Uint8List.sublistView(fullBytes, 0, GitLabApi.maxTextBytes), 206, headers: {
              'content-range': [
                'bytes 0-${GitLabApi.maxTextBytes - 1}/${fullBytes.length}',
              ],
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
        'bytes=0-${GitLabApi.maxTextBytes - 1}',
        'bytes=-${GitLabApi.maxTextBytes}',
        'bytes=${fullBytes.length}-${fullBytes.length + GitLabApi.maxTextBytes - 1}',
      ]);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('BLOCKER 2: a poll behind reads bounded ranges to the end in one load, and recovers via a tail read if the server ignores the bound', (tester) async {
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
          if (range == 'bytes=0-${limit - 1}') {
            // A server that ignores the bound: the whole (small) log.
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

      // One load reads bounded ranges on until the end: part 1 does not reach
      // the reported total, so the same load reads part 2 from offset2.
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(find.text('burst part 1 end'), findsOneWidget);
      expect(find.text('burst part 2 tail line'), findsOneWidget);
      expect(pollCount, 2);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsNothing);

      // Next poll: server returns > 2 MiB -> page recovers with Range: bytes=-2MiB and shows notice.
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(find.text('內容超出預覽上限'), findsNothing);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);
      expect(find.text('recovered after oversized poll'), findsOneWidget);
      final offset2 = initialBytes.length + burstPart1.length;
      final offset3 = offset2 + burstPart2.length;
      expect(pollCount, 3);
      expect(requestedRanges, [
        'bytes=0-${limit - 1}',
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

  group('Round 3 (#58): tail when far behind, read to the end, superseded loads, timestamps', () {
    const limit = GitLabApi.maxTextBytes;

    testWidgets('B1: a job that finishes more than 2 MiB past the last read shows its true final line plus the notice', (tester) async {
      final head = utf8.encode('first line while running\n');
      final b = StringBuffer();
      for (var i = 0; i < 40000; i++) {
        b.writeln('middle output line number $i padded with some text......');
      }
      b.writeln('FINAL ERROR: the build failed here');
      final all = [...head, ...utf8.encode(b.toString())];
      expect(all.length - head.length, greaterThan(limit));
      var status = 'running';
      List<int> served = head;
      final ranges = <String?>[];
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': status, 'name': 'long-job'});
        }
        if (request.uri.path.endsWith('/trace')) {
          final range = request.headers['Range'] as String?;
          ranges.add(range);
          return _serveRange(served, range);
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(api.close);
      await _pumpJobLog(tester, api);
      expect(find.text('first line while running'), findsOneWidget);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsNothing);

      // The job finishes with ~2.3 MiB more; the user taps refresh.
      status = 'failed';
      served = all;
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);

      expect(find.text('FINAL ERROR: the build failed here'), findsOneWidget);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);
      expect(find.text('內容超出預覽上限'), findsNothing);
      expect(ranges, [
        'bytes=0-${limit - 1}',
        'bytes=${head.length}-${head.length + limit - 1}',
        'bytes=-$limit',
      ]);
      // The end is on screen, so polling stops; the window ends at the last line.
      final rows = find.descendant(of: find.byType(ListView), matching: find.byType(RichText));
      expect(
        rows.evaluate().map((e) => (e.widget as RichText).text.toPlainText()).toList(),
        containsAllInOrder(['FINAL ERROR: the build failed here', ' ']),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('B1: a finished job within one budget is read to its end in one load across short responses, whole and without the notice', (tester) async {
      final head = utf8.encode('first line while running\n');
      final b = StringBuffer();
      for (var i = 0; i < 18000; i++) {
        b.writeln('output line $i padded with text to reach about eighty bytes per row.....');
      }
      b.writeln('FINAL LINE of a finished job');
      final all = [...head, ...utf8.encode(b.toString())];
      expect(all.length - head.length, inInclusiveRange(1024 * 1024, limit));
      var status = 'running';
      List<int> served = head;
      final ranges = <String?>[];
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': status, 'name': 'short-reads'});
        }
        if (request.uri.path.endsWith('/trace')) {
          final range = request.headers['Range'] as String?;
          ranges.add(range);
          // GitLab-like: at most 128 KiB per response.
          return _serveRange(served, range, maxPerResponse: 128 * 1024);
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(api.close);
      await _pumpJobLog(tester, api);

      status = 'success';
      served = all;
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);

      // Rows here wrap unevenly (the test font is wide), so the list's extent
      // estimate is off; following still lands on the true end.
      final followed = tester.state<ScrollableState>(
        find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
      ).position;
      expect(followed.extentAfter, 0);
      expect(find.text('FINAL LINE of a finished job'), findsOneWidget);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsNothing);
      expect(ranges.where((r) => r!.startsWith('bytes=-')), isEmpty);
      // One load kept reading from where the previous read ended.
      expect(ranges.length, greaterThan(9));
      var expected = head.length;
      for (final range in ranges.skip(1)) {
        expect(range, 'bytes=$expected-${expected + limit - 1}');
        expected = expected + 128 * 1024 > all.length ? all.length : expected + 128 * 1024;
      }
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
      );
      scrollable.position.jumpTo(0);
      await tester.pump();
      expect(find.text('first line while running'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('B1: a running job that grows by more than 2 MiB between polls jumps to the tail with the notice, then polls on from it', (tester) async {
      final head = utf8.encode('running head line\n');
      final b = StringBuffer();
      for (var i = 0; i < 40000; i++) {
        b.writeln('burst output line number $i padded with some text......');
      }
      b.writeln('LAST LINE of the burst');
      List<int> served = head;
      final ranges = <String?>[];
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'running', 'name': 'fast-job'});
        }
        if (request.uri.path.endsWith('/trace')) {
          final range = request.headers['Range'] as String?;
          ranges.add(range);
          return _serveRange(served, range);
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(api.close);
      await _pumpJobLog(tester, api);
      expect(find.text('running head line'), findsOneWidget);

      final burst = [...head, ...utf8.encode(b.toString())];
      served = burst;
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(find.text('LAST LINE of the burst'), findsOneWidget);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);
      expect(ranges.sublist(1), [
        'bytes=${head.length}-${head.length + limit - 1}',
        'bytes=-$limit',
      ]);

      // The next poll continues from the tail's absolute end.
      served = [...burst, ...utf8.encode('appended after the tail\n')];
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(ranges.last, 'bytes=${burst.length}-${burst.length + limit - 1}');
      expect(find.text('appended after the tail'), findsOneWidget);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    for (final oversized in [false, true]) {
      testWidgets('SHOULD-FIX 1: a load superseded while its bounded read is in flight makes no tail request (${oversized ? 'read fails tooLarge' : 'read reports a total far ahead'})', (tester) async {
        final hold = Completer<void>();
        final ranges = <String?>[];
        final api = testApi(FakeAdapter((request) async {
          if (request.uri.path.endsWith('/jobs/1')) {
            return jsonResponse({'id': 1, 'status': 'running', 'name': 'superseded'});
          }
          if (request.uri.path.endsWith('/trace')) {
            ranges.add(request.headers['Range'] as String?);
            await hold.future;
            if (oversized) {
              // A server ignoring the bound: more than the budget.
              return ResponseBody.fromBytes(Uint8List(limit + 1024), 200);
            }
            return ResponseBody.fromString('head', 206, headers: {
              'content-range': ['bytes 0-3/5000000'],
            });
          }
          return jsonResponse({}, status: 404);
        }));
        addTearDown(api.close);
        await tester.pumpWidget(workspaceHost(JobLogPage(
          account: _account(), api: api, project: Project.fromJson(projectJson(42)), id: 1)));
        await pumpUntil(tester, () => ranges.isNotEmpty, step: const Duration(milliseconds: 5),
            description: 'bounded read started');
        // Closing the page supersedes the load while its read is in flight.
        await tester.pumpWidget(const SizedBox());
        hold.complete();
        await settleNetworkWidgets(tester);
        expect(ranges, ['bytes=0-${limit - 1}']);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('SHOULD-FIX 2: a running log read as a tail starting mid-line shows its rows with runner timestamps stripped', (tester) async {
      final b = StringBuffer();
      for (var i = 0; i < 22000; i++) {
        b.write('2026-10-20T06:56:03.100000Z 00O ');
        b.writeln('\x1b[32m[step]\x1b[0m compiling module number $i of the very long build');
      }
      final all = utf8.encode(b.toString());
      expect(all.length, greaterThan(limit));
      expect(all[all.length - limit - 1], isNot(0x0A), reason: 'the tail starts mid-line');
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'running', 'name': 'long-job'});
        }
        if (request.uri.path.endsWith('/trace')) {
          return _serveRange(all, request.headers['Range'] as String?);
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(api.close);
      await _pumpJobLog(tester, api);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);
      expect(find.text('[step] compiling module number 21999 of the very long build'), findsOneWidget);
      expect(find.textContaining('Z 00O'), findsNothing);
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
      );
      scrollable.position.jumpTo(0);
      await tester.pump();
      expect(find.textContaining('Z 00O'), findsNothing);
      expect(find.textContaining(RegExp(r'^\[step\] compiling module number \d+ of the very long build$')), findsWidgets);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('SHOULD-FIX 2: a finished log opened as its pinned tail starting mid-line shows rows with runner timestamps stripped', (tester) async {
      final b = StringBuffer();
      for (var i = 0; i < 30000; i++) {
        b.writeln('2026-10-20T06:56:03.100000Z 00O terminal output line number $i of the job');
      }
      final all = utf8.encode(b.toString());
      expect(all[all.length - readCacheTerminalLogLimit - 1], isNot(0x0A));
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({
            'id': 1, 'status': 'failed', 'name': 'terminal',
            'pipeline': {'id': 9, 'project_id': 42},
            'erased_at': null, 'finished_at': '2026-10-20T07:00:00Z',
          });
        }
        if (request.uri.path.endsWith('/trace')) {
          return _serveRange(all, request.headers['Range'] as String?);
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(api.close);
      await _pumpJobLog(tester, api);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);
      expect(find.text('terminal output line number 29999 of the job'), findsOneWidget);
      expect(find.textContaining('Z 00O'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('NIT: after a restarted parse on a tail read, search matches start over instead of re-anchoring across numberings', (tester) async {
      final initial = utf8.encode(
        '${[for (var i = 0; i < 10; i++) i % 3 == 2 ? 'needle line $i' : 'plain line $i'].join('\n')}\n',
      );
      const total = 5000000;
      final tailBody = utf8.encode(
        'cut part of a line\n${[for (var i = 0; i < 20; i++) 'needle tail $i'].join('\n')}\n',
      );
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'running', 'name': 'restart-search'});
        }
        if (request.uri.path.endsWith('/trace')) {
          final range = request.headers['Range'] as String?;
          if (range == 'bytes=0-${limit - 1}') return ResponseBody.fromBytes(initial, 200);
          if (range == 'bytes=-$limit') {
            return ResponseBody.fromBytes(tailBody, 206, headers: {
              'content-range': ['bytes ${total - tailBody.length}-${total - 1}/$total'],
            });
          }
          // Far behind: the bounded read reports a total more than a budget ahead.
          return ResponseBody.fromString('abcd', 206, headers: {
            'content-range': ['bytes ${initial.length}-${initial.length + 3}/$total'],
          });
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(api.close);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _pumpJobLog(tester, api);
      await tester.tap(find.text('10 秒更新'));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('job-log-search-1')), 'needle');
      await tester.pump();
      expect(find.text('1/3'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();
      expect(find.text('3/3'), findsOneWidget); // 'needle line 8'

      await tester.pump(const Duration(seconds: 10)); // the auto-refresh poll
      await _settleJobLog(tester);
      // Searching turned follow off: the restarted parse waits off screen.
      expect(find.text('3/3'), findsOneWidget);
      await tester.tap(find.text('跟隨尾端'));
      await tester.pump();
      await _settleJobLog(tester);
      // Line 8 of the old numbering means nothing in the tail: start over at
      // its first match rather than at the tail's line 8.
      expect(find.text('1/20'), findsOneWidget);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('NIT: a tail 206 without Content-Range has no offset, so the next poll reads the tail again', (tester) async {
      final ranges = <String?>[];
      var tails = 0;
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'running', 'name': 'no-content-range'});
        }
        if (request.uri.path.endsWith('/trace')) {
          final range = request.headers['Range'] as String?;
          ranges.add(range);
          if (range == 'bytes=-$limit') {
            tails++;
            return ResponseBody.fromString('tail read $tails\n', 206);
          }
          return ResponseBody.fromString('head', 206, headers: {
            'content-range': ['bytes 0-3/5000000'],
          });
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(api.close);
      await _pumpJobLog(tester, api);
      expect(find.text('tail read 1'), findsOneWidget);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);

      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(ranges, ['bytes=0-${limit - 1}', 'bytes=-$limit', 'bytes=-$limit']);
      expect(find.text('tail read 2'), findsOneWidget);
      expect(find.text('tail read 1'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
  group('Server ignoring Range: 200 with the whole log on every read (#58, gitlab.com)', () {
    const limit = GitLabApi.maxTextBytes;
    String part(int from, int to) => [
          for (var i = from; i < to; i++)
            i % 7 == 0 ? '\x1b[3${i % 8}mcolored row $i\x1b[0m' : 'row $i of the growing log',
        ].join('\n');
    FakeAdapter wholeLog(String Function() text, List<String?> ranges, {String status = 'running'}) =>
        FakeAdapter((request) {
          if (request.uri.path.endsWith('/jobs/1')) {
            return jsonResponse({'id': 1, 'status': status, 'name': 'ignores-range'});
          }
          if (request.uri.path.endsWith('/trace')) {
            ranges.add(request.headers['Range'] as String?);
            final bytes = utf8.encode(text());
            return ResponseBody.fromBytes(bytes, 200, headers: {
              'content-length': ['${bytes.length}'],
              'accept-ranges': ['bytes'],
            });
          }
          return jsonResponse({}, status: 404);
        });
    List<String> rows(WidgetTester tester) => find
        .descendant(of: find.byType(ListView), matching: find.byType(RichText))
        .evaluate()
        .map((e) => (e.widget as RichText).text.toPlainText())
        .toList();

    testWidgets('polls parse only the new bytes, show the rows of a fresh load, and never read the tail', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 2600);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var text = 'section_start:1:build\r\n${part(0, 40)}\n';
      final initialBytes = utf8.encode(text).length;
      final ranges = <String?>[];
      final api = testApi(wholeLog(() => text, ranges));
      addTearDown(api.close);
      await _pumpJobLog(tester, api);
      expect(find.text('row 39 of the growing log'), findsOneWidget);

      final added = '${part(40, 60)}\nsection_end:2:build\r\nafter the section\n';
      text = '$text$added';
      JobTrace.resetDebugCounters();
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      // Only the appended text went through the parser, not the whole body.
      expect(JobTrace.debugCharactersProcessed, greaterThan(0));
      expect(JobTrace.debugCharactersProcessed, lessThanOrEqualTo(added.length));
      expect(JobTrace.debugCharactersProcessed, lessThan(text.length - added.length));
      expect(ranges, [
        'bytes=0-${limit - 1}',
        'bytes=$initialBytes-${initialBytes + limit - 1}',
      ]);
      // A poll with nothing new parses nothing and reads once.
      JobTrace.resetDebugCounters();
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(JobTrace.debugCharactersProcessed, 0);
      expect(ranges, hasLength(3));
      expect(ranges.where((r) => r!.startsWith('bytes=-')), isEmpty);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsNothing);
      final polled = rows(tester);
      expect(polled, contains('after the section'));

      // The same log loaded fresh shows the same rows.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      final fresh = testApi(wholeLog(() => text, <String?>[]));
      addTearDown(fresh.close);
      await _pumpJobLog(tester, fresh);
      expect(rows(tester), polled);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('Content-Length equal to the offset or 0 cancels before reading the body and keeps the shown rows (#62)', (tester) async {
      var text = '${part(0, 30)}\n';
      final initialLen = utf8.encode(text).length;
      final ranges = <String?>[];
      // Chunks sent by the latest response. Dio subscribes as soon as the
      // headers arrive, so one or two go out before any cancel; a cancelled
      // download stops long before its last chunk.
      var bodyReads = 0;
      var streamCancelled = false;
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'running', 'name': 'early-cancel'});
        }
        if (request.uri.path.endsWith('/trace')) {
          ranges.add(request.headers['Range'] as String?);
          final bytes = Uint8List.fromList(utf8.encode(text));
          var cancelled = false;
          return ResponseBody(
            Stream<Uint8List>.multi((sink) {
              sink.onCancel = () {
                cancelled = true;
                streamCancelled = true;
              };
              Future<void> pump() async {
                for (var i = 0; i < bytes.length; i += 16) {
                  await Future<void>.delayed(Duration.zero);
                  if (cancelled) return;
                  bodyReads++;
                  sink.add(Uint8List.sublistView(bytes, i, min(i + 16, bytes.length)));
                }
                await sink.close();
              }

              unawaited(pump());
            }),
            200,
            headers: {
              'content-length': ['${bytes.length}'],
              'accept-ranges': ['bytes'],
            },
          );
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(api.close);
      await _pumpJobLog(tester, api);
      expect(find.text('row 29 of the growing log'), findsOneWidget);
      final chunks = (initialLen + 15) ~/ 16;
      expect(bodyReads, chunks);

      // Same length (no new data): early cancel; nothing is parsed.
      bodyReads = 0;
      streamCancelled = false;
      JobTrace.resetDebugCounters();
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(streamCancelled, isTrue);
      expect(bodyReads, lessThan(5), reason: 'of $chunks chunks');
      expect(JobTrace.debugCharactersProcessed, 0);
      expect(find.text('row 29 of the growing log'), findsOneWidget);

      // Content-Length 0 (an erased log): also early cancel, keeping the
      // shown rows.
      final fullText = text;
      text = '';
      bodyReads = 0;
      streamCancelled = false;
      JobTrace.resetDebugCounters();
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(streamCancelled, isTrue);
      expect(bodyReads, 0, reason: 'an empty body has no chunks');
      expect(JobTrace.debugCharactersProcessed, 0);
      expect(find.text('row 29 of the growing log'), findsOneWidget);

      // When the log grows past the previous offset, polling resumes from initialLen.
      text = '${fullText}appended line after early cancel\n';
      bodyReads = 0;
      streamCancelled = false;
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(bodyReads, (utf8.encode(text).length + 15) ~/ 16);
      expect(ranges.last, 'bytes=$initialLen-${initialLen + limit - 1}');
      expect(find.text('appended line after early cancel'), findsOneWidget);
      expect(find.text('row 29 of the growing log'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a body shorter than the offset (log replaced) restarts from it', (tester) async {
      // wholeLog sends Content-Length, as gitlab.com does for a finished job.
      var text = '${part(0, 30)}\n';
      final ranges = <String?>[];
      final api = testApi(wholeLog(() => text, ranges));
      addTearDown(api.close);
      await _pumpJobLog(tester, api);
      expect(find.text('row 29 of the growing log'), findsOneWidget);

      text = 'replaced log line one\nreplaced log line two\n';
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(find.text('replaced log line two'), findsOneWidget);
      expect(find.text('row 29 of the growing log'), findsNothing);
      expect(find.textContaining('of the growing log'), findsNothing);
      expect(ranges.where((r) => r!.startsWith('bytes=-')), isEmpty);

      // It continues from the replaced log's end.
      text = '${text}third line\n';
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(ranges.last, 'bytes=44-${44 + limit - 1}');
      expect(find.text('third line'), findsOneWidget);
      expect(find.text('replaced log line one'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a running log over 2 MiB shows the last window (same as the Range path), never shows over-the-preview-limit, and keeps polling (#62)', (tester) async {
      final b = StringBuffer();
      for (var i = 0; i < 22000; i++) {
        b.write('2026-10-20T06:56:03.100000Z 00O ');
        b.writeln('running big log line number $i padded with extra text to exceed 2 MiB');
      }
      var big = b.toString();
      final initialBytes = utf8.encode(big);
      expect(initialBytes.length, greaterThan(limit));
      expect(initialBytes[initialBytes.length - limit - 1], isNot(0x0A), reason: 'tail starts mid-line');

      final ranges = <String?>[];
      final api = testApi(wholeLog(() => big, ranges));
      addTearDown(api.close);
      await _pumpJobLog(tester, api);
      expect(find.text('內容超出預覽上限'), findsNothing);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);
      expect(find.text('running big log line number 21999 padded with extra text to exceed 2 MiB'), findsOneWidget);
      expect(find.textContaining('Z 00O'), findsNothing);
      expect(ranges, ['bytes=0-${limit - 1}', 'bytes=-$limit']);
      final shownOn200 = rows(tester);

      // Verify the shown window matches the 206 Range path.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      final rangeApi = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'running', 'name': 'honours-range'});
        }
        if (request.uri.path.endsWith('/trace')) {
          return _serveRange(initialBytes, request.headers['Range'] as String?);
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(rangeApi.close);
      await _pumpJobLog(tester, rangeApi);
      expect(rows(tester), shownOn200);

      // Mount the 200 log again and verify subsequent polls keep polling from the tail end.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      ranges.clear();
      final pollApi = testApi(wholeLog(() => big, ranges));
      addTearDown(pollApi.close);
      await _pumpJobLog(tester, pollApi);
      expect(ranges, ['bytes=0-${limit - 1}', 'bytes=-$limit']);

      // Poll with new lines appended past 2 MiB: discards the first initialBytes.length
      // bytes and parses only the newly appended lines.
      const appended = '2026-10-20T06:56:04.100000Z 00O appended line 22000 after tail\n'
          '2026-10-20T06:56:05.100000Z 00O appended line 22001 after tail\n';
      big = '$big$appended';
      JobTrace.resetDebugCounters();
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(ranges.last, 'bytes=${initialBytes.length}-${initialBytes.length + limit - 1}');
      // A timestamped line is committed when the next header arrives, so the
      // poll also parses the line that was last before it, as on the Range
      // path: its content and the two new ones, never the window.
      const lastShown = 'running big log line number 21999 padded with extra text to exceed 2 MiB';
      const appendedContent = 'appended line 22000 after tailappended line 22001 after tail';
      expect(JobTrace.debugCharactersProcessed, greaterThan(0));
      expect(
        JobTrace.debugCharactersProcessed,
        lessThanOrEqualTo(lastShown.length + appendedContent.length),
      );
      expect(find.text('appended line 22001 after tail'), findsOneWidget);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);
      expect(find.text('內容超出預覽上限'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('a running log without Content-Length that grows by more than 2 MiB between polls jumps to the tail as on the Range path, then polls on (#62)', (tester) async {
      var text = '${part(0, 30)}\n';
      final ranges = <String?>[];
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'running', 'name': 'no-length'});
        }
        if (request.uri.path.endsWith('/trace')) {
          ranges.add(request.headers['Range'] as String?);
          return ResponseBody.fromBytes(utf8.encode(text), 200);
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(api.close);
      await _pumpJobLog(tester, api);
      expect(find.text('row 29 of the growing log'), findsOneWidget);
      final initialLen = utf8.encode(text).length;

      // More than one budget arrives before the next poll: the bounded read
      // keeps the budget and stops, and the page reads the tail instead.
      text = '$text${part(30, 120000)}\n';
      expect(utf8.encode(text).length - initialLen, greaterThan(limit));
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(ranges, [
        'bytes=0-${limit - 1}',
        'bytes=$initialLen-${initialLen + limit - 1}',
        'bytes=-$limit',
      ]);
      expect(find.text('內容超出預覽上限'), findsNothing);
      expect(find.byKey(const ValueKey('job-log-truncated')), findsOneWidget);
      expect(find.text('row 119999 of the growing log'), findsOneWidget);

      // The next poll goes on from the end of that tail.
      final end = utf8.encode(text).length;
      text = '${text}after the jump\n';
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(ranges.last, 'bytes=$end-${end + limit - 1}');
      expect(find.text('after the jump'), findsOneWidget);
      expect(find.text('內容超出預覽上限'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    test('the polling interval grows with the log only when the server ignored Range (#62)', () {
      const mib = 1024 * 1024;
      const ten = Duration(seconds: 10);
      Duration at(int bytes, {bool ignored = true, Duration base = ten}) =>
          jobLogPollingInterval(base, rangeIgnored: ignored, logBytes: bytes);
      // Range honoured (206): the rate-level interval, whatever the size.
      expect(at(30 * mib, ignored: false), ten);
      expect(at(30 * mib, ignored: false, base: const Duration(seconds: 60)), const Duration(seconds: 60));
      // Range ignored (200): +10 s per started 2 MiB above the first 2 MiB.
      expect(at(0), ten);
      expect(at(2 * mib), ten);
      expect(at(2 * mib + 1), const Duration(seconds: 20));
      expect(at(4 * mib), const Duration(seconds: 20));
      expect(at(4 * mib + 1), const Duration(seconds: 30));
      expect(at(10 * mib), const Duration(seconds: 50));
      expect(at(22 * mib), const Duration(seconds: 110));
      expect(at(22 * mib + 1), const Duration(seconds: 120));
      expect(at(30 * mib), const Duration(seconds: 120), reason: 'capped');
      // On top of a slower rate level, with the same cap.
      expect(at(4 * mib + 1, base: const Duration(seconds: 30)), const Duration(seconds: 50));
      expect(at(30 * mib, base: const Duration(seconds: 60)), const Duration(seconds: 120));
    });

    testWidgets('auto-refresh slows down as a log served whole (200) grows, and keeps 10 s for a log served with Range (206) (#62)', (tester) async {
      final line = '${'x' * 120}\n';
      var text = line * 39000; // 4.5 MiB: 10 s + 2 × 10 s
      final ranges = <String?>[];
      final api = testApi(wholeLog(() => text, ranges));
      addTearDown(api.close);
      // Auto-refresh runs only while the app is in the foreground.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _pumpJobLog(tester, api);
      final state = tester.state<JobLogPageState>(find.byType(JobLogPage));
      expect(state.pollingInterval, const Duration(seconds: 30));
      // The chip names the interval actually used.
      expect(find.text('30 秒更新'), findsOneWidget);
      expect(find.text('10 秒更新'), findsNothing);
      await tester.tap(find.byType(FilterChip).first);
      await tester.pump();
      final reads = ranges.length;
      await tester.pump(const Duration(seconds: 29));
      expect(ranges, hasLength(reads), reason: 'no poll after 10 s or 29 s');
      text = '$text${line * 18000}'; // 6.6 MiB: 10 s + 3 × 10 s
      await tester.pump(const Duration(seconds: 1));
      await _settleJobLog(tester);
      expect(ranges.length, greaterThan(reads));
      expect(state.pollingInterval, const Duration(seconds: 40));
      expect(find.text('40 秒更新'), findsOneWidget);
      final afterGrowth = ranges.length;
      await tester.pump(const Duration(seconds: 39));
      expect(ranges, hasLength(afterGrowth), reason: 'the timer was re-armed at 40 s');
      await tester.pump(const Duration(seconds: 1));
      await _settleJobLog(tester);
      expect(ranges.length, greaterThan(afterGrowth));

      // The same size served with Range keeps the 10 s cadence.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      final all = utf8.encode(text);
      final rangeApi = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'running', 'name': 'honours-range'});
        }
        if (request.uri.path.endsWith('/trace')) {
          return _serveRange(all, request.headers['Range'] as String?);
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(rangeApi.close);
      await _pumpJobLog(tester, rangeApi);
      expect(
        tester.state<JobLogPageState>(find.byType(JobLogPage)).pollingInterval,
        const Duration(seconds: 10),
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('over the 64 MiB total-bytes cap on a poll fails with tooLarge and keeps what we have on screen (#62)', (tester) async {
      var overCap = false;
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'running', 'name': 'cap-job'});
        }
        if (request.uri.path.endsWith('/trace')) {
          if (overCap) {
            return ResponseBody.fromBytes(
              Uint8List(0),
              200,
              headers: {
                'content-length': ['${GitLabApi.maxTraceStreamBytes + 1}'],
              },
            );
          }
          final bytes = utf8.encode('kept line before cap\n');
          return ResponseBody.fromBytes(
            bytes,
            200,
            headers: {
              'content-length': ['${bytes.length}'],
            },
          );
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(api.close);
      await _pumpJobLog(tester, api);
      expect(find.text('kept line before cap'), findsOneWidget);
      expect(find.text('內容超出預覽上限'), findsNothing);

      overCap = true;
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);
      expect(find.text('內容超出預覽上限'), findsOneWidget);
      expect(find.text('kept line before cap'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });

  group('Pending unterminated line cap at 2 MiB (#61)', () {
    const cap = GitLabApi.maxTextBytes;
    // A cut keeps at most three quarters of the cap.
    const keep = cap - cap ~/ 4;

    test('a 3 MiB \\r progress line fed in chunks keeps memory bounded, cuts to three quarters of the cap and sets the flag', () {
      final parser = JobTraceParser();
      // 64-char progress frame ending in \r; 64 divides 2 MiB (2,097,152)
      // and its three quarters evenly.
      final frame = '${'#' * 56} 100.0%\r';
      expect(frame.length, 64);
      final chunk = frame * 4096; // 256 KiB per chunk
      expect(chunk.length, 256 * 1024);

      late JobTrace snap;
      final cuts = <int>[];
      // Feed 12 chunks = 3 MiB total.
      for (var i = 0; i < 12; i++) {
        snap = parser.addText(chunk);
        expect(parser.pendingLineLength, lessThanOrEqualTo(cap));
        expect(snap.estimatedBytes, lessThan(6 * 1024 * 1024));
        cuts.add(snap.lineCuts);
      }

      // 2 MiB fits; the 9th chunk goes over and cuts to 1.5 MiB, and the
      // line only goes over again with the 12th.
      expect(cuts, [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 2]);
      expect(parser.charactersProcessed, 3 * 1024 * 1024);
      expect(parser.pendingLineLength, keep);
      expect(parser.pendingLineTruncated, isTrue);
      expect(snap.truncated, isTrue);
      expect(snap.lines, hasLength(1));
      expect(snap.lines.single.truncated, isTrue);
      expect(snap.lines.single.text, '${'#' * 56} 100.0%');

      // Non-power-of-two \r frames cut right after the first \r at or after
      // minCut - 1, so a cut keeps less than one frame under three quarters.
      final unalignedParser = JobTraceParser();
      final frame50 = '${'=' * 42} 99.9%\r';
      expect(frame50.length, 49);
      final chunk50 = frame50 * 6000; // 294,000 chars
      var unalignedCuts = 0;
      for (var i = 0; i < 11; i++) {
        snap = unalignedParser.addText(chunk50);
        expect(unalignedParser.pendingLineLength, lessThanOrEqualTo(cap));
        if (snap.lineCuts > unalignedCuts) {
          unalignedCuts = snap.lineCuts;
          expect(
            unalignedParser.pendingLineLength,
            inInclusiveRange(keep - frame50.length + 1, keep),
          );
        }
      }
      // Over the cap after the 8th and the 10th chunk.
      expect(unalignedCuts, 2);
      expect(unalignedParser.pendingLineTruncated, isTrue);
      expect(snap.truncated, isTrue);
      expect(snap.lines.single.truncated, isTrue);
      expect(snap.lines.single.text, '${'=' * 42} 99.9%');
    });

    test('a section opened before the cut still closes correctly', () {
      final parser = JobTraceParser();
      final header = 'section_start:1000:tqdm_step[collapsed=true]\r';
      final frame = '${'.' * 60} 50%\r'; // 65 chars
      final bodyChunk = frame * 5000; // 325,000 chars

      parser.addText(header);
      late JobTrace snap;
      for (var i = 0; i < 8; i++) {
        snap = parser.addText(bodyChunk);
      }
      // Total fed > 2.6 MiB; the section_start marker was dropped from the front.
      expect(parser.pendingLineTruncated, isTrue);
      expect(snap.truncated, isTrue);
      expect(snap.lines, hasLength(1));
      expect(snap.lines.single.section, 'tqdm_step');
      expect(snap.lines.single.truncated, isTrue);
      expect(snap.sections, hasLength(1));
      expect(snap.sections.single.name, 'tqdm_step');
      expect(snap.sections.single.start, 1000);
      expect(snap.sections.single.end, isNull);
      expect(snap.sections.single.collapsed, isTrue);

      snap = parser.addText('done\nsection_end:1045:tqdm_step\r\nafter section\n');
      expect(snap.sections, hasLength(1));
      final closed = snap.sections.single;
      expect(closed.name, 'tqdm_step');
      expect(closed.start, 1000);
      expect(closed.end, 1045);
      expect(closed.durationSeconds, 45);
      expect(closed.startLine, 0);
      expect(closed.endLine, 1);
      // 'done' ends the capped line and 'after section' is the next one; as
      // without a cap, the final newline leaves an empty last line.
      expect(snap.lines, hasLength(3));
      expect(snap.lines.first.truncated, isTrue);
      expect(snap.lines.first.section, 'tqdm_step');
      expect(snap.lines[1].text, 'after section');
      expect(snap.lines[1].section, isNull);
      expect(snap.lines[1].truncated, isFalse);
      expect(snap.lines.last.text, '');
      expect(snap.lines.last.section, isNull);
      expect(snap.lines.last.truncated, isFalse);
      _expectTraceEquivalent(
        snap,
        JobTrace.parse(
          '$header${bodyChunk * 8}'
          'done\nsection_end:1045:tqdm_step\r\nafter section\n',
        ),
        reason: 'capped section vs full parse',
      );
    });

    test('the colour state set before the cut still applies', () {
      final parser = JobTraceParser();
      final frame = '${'x' * 59} 10%\r'; // 64 chars
      final chunk = frame * 4096; // 256 KiB

      // Set bold red (\x1b[1;31m) at the very start of the line, then exceed 2 MiB.
      parser.addText('\x1b[1;31m');
      late JobTrace snap;
      for (var i = 0; i < 10; i++) {
        snap = parser.addText(chunk);
      }
      expect(parser.pendingLineTruncated, isTrue);
      expect(snap.lines, hasLength(1));
      expect(snap.lines.single.truncated, isTrue);
      expect(snap.lines.single.spans, isNotEmpty);
      for (final span in snap.lines.single.spans) {
        expect(span.style.bold, isTrue);
        expect(span.style.foreground?.index, 1);
      }

      // Resetting colour later on the same line transitions style cleanly.
      snap = parser.addText('\r\x1b[0mplain tail\n');
      // The newline completes the line; the parser then reports the empty
      // line that follows it, as it does without a cap.
      expect(snap.lines, hasLength(2));
      expect(snap.lines.first.truncated, isTrue);
      expect(snap.lines.first.spans.first.text, 'plain tail');
      expect(snap.lines.first.spans.first.style.isPlain, isTrue);
      expect(snap.lines.last.truncated, isFalse);
    });

    test('an escape left open before a marker in the dropped front ends there', () {
      // A full parse ends the dangling `\x1b[1;31` at the section marker, so
      // the `m` after it is text and the tail stays plain.
      final line = '\x1b[1;31section_start:1:a\rm${'y' * 200}\r${'z' * 50}';
      final parser = JobTraceParser(maxPendingChars: 100);
      final snap = parser.addText(line);
      final full = JobTrace.parse(line);
      expect(parser.pendingLineTruncated, isTrue);
      expect(snap.lines.single.truncated, isTrue);
      expect(snap.lines.single.section, 'a');
      expect(snap.lines.single.text, 'z' * 50);
      expect(snap.lines.single.spans.single.style.isPlain, isTrue);
      expect(
        snap.lines.single.spans.single.style,
        full.lines.single.spans.single.style,
      );
    });

    test('no cut lands inside a surrogate pair or an escape sequence', () {
      // 1. Surrogate pair straddling the cut target (no \r in tail).
      final surrogateParser = JobTraceParser();
      // Prefix of p chars + '🚀' (code units p and p + 1) + (keep - 1) 'a's:
      // length = p + 2 + keep - 1, so minCut = length - keep = p + 1, right
      // between the high and the low surrogate.
      const p = cap ~/ 4 + 101;
      final surrogateInput = '${'p' * p}🚀${'a' * (keep - 1)}';
      expect(surrogateInput.length, greaterThan(cap));
      expect(surrogateInput.length - keep, p + 1);
      final surrogateSnap = surrogateParser.addText(surrogateInput);
      expect(surrogateParser.pendingLineTruncated, isTrue);
      expect(surrogateParser.pendingLineLength, keep - 1);
      expect(surrogateSnap.lines.first.truncated, isTrue);
      expect(surrogateSnap.lines.first.text.codeUnitAt(0), equals('a'.codeUnitAt(0)));

      // 2. CSI escape sequence straddling the cut target.
      final ansiParser = JobTraceParser();
      const esc = '\x1b[38;5;208m'; // length 11
      // q chars + esc + (keep - 6) 'b's: length = q + 5 + keep, so
      // minCut = q + 5, offset 5 inside esc.
      const q = cap ~/ 4 + 100;
      final ansiInput = '${'q' * q}$esc${'b' * (keep - 6)}';
      expect(ansiInput.length, greaterThan(cap));
      expect(ansiInput.length - keep, q + 5);
      final ansiSnap = ansiParser.addText(ansiInput);
      expect(ansiParser.pendingLineTruncated, isTrue);
      expect(ansiParser.pendingLineLength, keep - 6);
      expect(ansiSnap.lines.first.truncated, isTrue);
      expect(ansiSnap.lines.first.text.startsWith('bbbbb'), isTrue);
      expect(ansiSnap.lines.first.spans.first.style.foreground?.index, 208);

      // 3. OSC sequence containing \r straddling the cut boundary does not cut at the \r inside OSC.
      // Length 33, keep 18: the search for a \r starts at 14, before the
      // \r at 16 inside the OSC.
      final oscParser = JobTraceParser(maxPendingChars: 24);
      final oscSnap = oscParser.addText('0123456789\x1b]0;my\rtitle\x07abcdefghij');
      expect(oscParser.pendingLineTruncated, isTrue);
      expect(oscSnap.lines.single.text, 'abcdefghij');
    });

    test('below the cap, the output equals the full re-parse', () {
      final frame = '\x1b[32mstep 1\r\x1b[34mstep 2 🚀\x1b[0m ';
      // Build a multi-line trace whose longest unterminated line is right below the cap.
      final belowLine = 'section_start:10:s1\r${frame * 2000}tail';
      expect(belowLine.length, lessThan(cap));
      final fullText = 'first line\n$belowLine';

      final parser = JobTraceParser();
      const chunkSize = 13107;
      for (var i = 0; i < fullText.length; i += chunkSize) {
        final end = (i + chunkSize < fullText.length) ? i + chunkSize : fullText.length;
        parser.addText(fullText.substring(i, end));
      }
      final snap = parser.snapshot();
      expect(parser.pendingLineTruncated, isFalse);
      expect(snap.truncated, isFalse);
      expect(snap.lines.every((l) => !l.truncated), isTrue);

      final expected = JobTrace.parse(fullText);
      _expectTraceEquivalent(snap, expected, reason: 'below cap snapshot vs full parse');
      _expectTraceEquivalent(parser.finish(), expected, reason: 'below cap finish vs full parse');

      // Also test exact cap length (== GitLabApi.maxTextBytes) does not truncate.
      final exactParser = JobTraceParser();
      final exactLine = 'x' * cap;
      final exactSnap = exactParser.addText(exactLine);
      expect(exactParser.pendingLineTruncated, isFalse);
      expect(exactParser.pendingLineLength, cap);
      expect(exactSnap.truncated, isFalse);
      expect(exactSnap.lines.every((l) => !l.truncated), isTrue);
    });

    test('a timestamped progress line over the cap is cut at most once per quarter of the cap', () {
      // Each physical line continues the logical one ('+'), as a runner
      // writes a long \r progress line. Every physical line used to pay a
      // 2 MiB scan once the line was over the cap.
      const header = '2024-01-01T00:00:00.000000Z 01O';
      final frame = '${'#' * 60} 50%\r'; // 65 chars
      final physical = '$header+$frame\n';
      final all = StringBuffer('$header $frame\n${physical * 33000}');
      final parser = JobTraceParser();
      var snap = parser.addText(all.toString());
      expect(parser.pendingLineTruncated, isTrue);
      // The 32,264th frame goes over and the cut keeps 24,197 frames; the
      // last 737 frames follow it.
      expect(snap.lineCuts, 1);
      expect(parser.pendingLineLength, (24197 + 737) * 65);

      // 16 polls of 64 KiB (668 physical lines each) add 694,720 characters
      // to the line: one more cut, in the 11th poll, never one per line.
      final poll = physical * (64 * 1024 ~/ physical.length);
      final cuts = <int>[];
      for (var i = 0; i < 16; i++) {
        snap = parser.addText(poll);
        all.write(poll);
        expect(parser.pendingLineLength, lessThanOrEqualTo(cap));
        cuts.add(snap.lineCuts);
      }
      expect(cuts, [for (var i = 0; i < 16; i++) i < 10 ? 1 : 2]);
      expect(snap.lines.first.truncated, isTrue);
      expect(snap.lines.first.text, '${'#' * 60} 50%');
      _expectTraceEquivalent(
        snap,
        JobTrace.parse(all.toString()),
        reason: 'timestamped capped line vs full parse',
      );
    });

    test('an escape sequence that never ends is cut inside it and ended there', () {
      // `printf '\e]'` with no terminator leaves no clean cut point: the cut
      // lands at its target and the escape ends there, so the line stays
      // bounded. A full parse would hide the rest of the line; only such
      // malformed input differs from it.
      final parser = JobTraceParser(maxPendingChars: 1000);
      parser.addText('\x1b]0;');
      late JobTrace snap;
      for (var i = 0; i < 20; i++) {
        snap = parser.addText('z' * 1000);
        expect(parser.pendingLineLength, 750);
      }
      expect(snap.lineCuts, 20);
      expect(snap.lines.single.truncated, isTrue);
      expect(snap.lines.single.text, 'z' * 750);
      expect(snap.lines.single.spans.single.style.isPlain, isTrue);

      // Behind a front dense with section markers too.
      final dense = JobTraceParser(maxPendingChars: 100000);
      dense.addText('${'section_start:1:a' * 3000}\x1b]${'x' * 40000}');
      snap = dense.addText('y' * 120000);
      expect(dense.pendingLineLength, 75000);
      expect(snap.lineCuts, 1);
      expect(snap.lines.first.truncated, isTrue);
      expect(snap.lines.map((l) => l.text).join(), 'y' * 75000);
    });

    test('the isolate and the synchronous parse agree when a cut lands inside an isolate chunk', () async {
      final text = StringBuffer('head line\n\x1b[1;33msection_start:5:outer\r');
      final frame = '\x1b[32m${'=' * 50}\x1b[0m 42%\r';
      var i = 0;
      while (text.length < cap + 300 * 1024) {
        text.write(frame);
        if (i % 5000 == 0) text.write('section_start:${i + 10}:inner$i\r');
        if (i % 5000 == 2500) {
          text.write('section_end:${i + 20}:inner${i - 2500}\r');
        }
        i++;
      }
      text.write('\x1b[35mdone\nsection_end:99:outer\r\nafter\n');
      final bytes = utf8.encode(text.toString());
      // Over the 64 KiB isolate threshold.
      const chunk = 100 * 1024;
      final viaIsolate = JobTraceParser();
      final sync = JobTraceParser();
      late JobTrace a;
      late JobTrace b;
      for (var offset = 0; offset < bytes.length; offset += chunk) {
        final end = min(offset + chunk, bytes.length);
        a = (await viaIsolate.addBytesAsync(bytes.sublist(offset, end)))!;
        b = sync.addBytes(bytes.sublist(offset, end));
        final reason = 'chunk at $offset';
        _expectTraceEquivalent(a, b, reason: reason);
        expect(a.truncated, b.truncated, reason: reason);
        expect(a.windowStart, b.windowStart, reason: reason);
        expect(a.lineCuts, b.lineCuts, reason: reason);
        expect(
          [for (final line in a.lines) line.truncated],
          [for (final line in b.lines) line.truncated],
          reason: reason,
        );
      }
      expect(b.lineCuts, greaterThan(0));
      expect(b.lines.last.text, '');
      expect(b.lines[b.lines.length - 2].text, 'after');
      expect(b.sections.last.name, 'outer');
      expect(b.sections.last.end, 99);
    });

    test('a \\r or an escape split across calls at the cut gives the one-shot result', () {
      final input = '${'abc\x1b[31m${'x' * 40}\r\x1b[0m' * 3000}END';
      final oneShot = JobTraceParser(maxPendingChars: 1000)..addText(input);
      for (final split in [1, 2, 3, 5, 7, 11, 64, 65, 66, 67]) {
        final parser = JobTraceParser(maxPendingChars: 1000);
        var longest = 0;
        for (var offset = 0; offset < input.length; offset += split) {
          parser.addText(input.substring(offset, min(offset + split, input.length)));
          longest = max(longest, parser.pendingLineLength);
        }
        expect(longest, lessThanOrEqualTo(1000), reason: 'split $split');
        final snap = parser.snapshot();
        _expectTraceEquivalent(snap, oneShot.snapshot(), reason: 'split $split');
        expect(snap.lines.single.truncated, isTrue, reason: 'split $split');
        expect(snap.lines.single.text, 'END${'x' * 40}', reason: 'split $split');
      }
    });

    testWidgets('JobLogPage shows the truncation notice on a capped pending line', (tester) async {
      final frame = '${'#' * 56} 100.0%\r'; // 64 chars
      final chunk1 = 'first normal line\n${frame * 20000}'; // ~1.28 MiB
      final chunk2 = frame * 20000; // +1.28 MiB -> > 2.56 MiB on line 1
      var polled = false;
      final api = testApi(FakeAdapter((request) {
        if (request.uri.path.endsWith('/jobs/1')) {
          return jsonResponse({'id': 1, 'status': 'running', 'name': 'tqdm-job'});
        }
        if (request.uri.path.endsWith('/trace')) {
          final all = utf8.encode(polled ? '$chunk1$chunk2' : chunk1);
          return _serveRange(all, request.headers['Range'] as String?);
        }
        return jsonResponse({}, status: 404);
      }));
      addTearDown(api.close);

      await _pumpJobLog(tester, api);
      expect(find.text('first normal line'), findsOneWidget);
      expect(find.text('Log 太長，前段已截掉，只顯示最後一部分。'), findsNothing);

      polled = true;
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await _settleJobLog(tester);

      expect(find.byKey(const ValueKey('job-log-line-truncated-1')), findsOneWidget);
      expect(find.text('Log 太長，前段已截掉，只顯示最後一部分。'), findsOneWidget);
      expect(find.text('${'#' * 56} 100.0%'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });
  });
}

Account _account() => Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 1, username: 'testuser', name: 'Test User'),
      token: 'tok',
    );

Future<void> _pumpJobLog(WidgetTester tester, GitLabApi api) async {
  await tester.pumpWidget(workspaceHost(JobLogPage(
    account: _account(), api: api, project: Project.fromJson(projectJson(42)), id: 1)));
  await _settleJobLog(tester);
}

/// Serves [all] honouring Range: none, `bytes=a-`, `bytes=a-b` and
/// `bytes=-n`, with at most [maxPerResponse] bytes for a start-based range.
ResponseBody _serveRange(List<int> all, String? range, {int? maxPerResponse}) {
  if (range == null) return ResponseBody.fromBytes(all, 200);
  final total = all.length;
  final int start;
  var end = total - 1;
  final suffix = RegExp(r'^bytes=-(\d+)$').firstMatch(range);
  if (suffix != null) {
    final n = int.parse(suffix.group(1)!);
    start = n < total ? total - n : 0;
  } else {
    final span = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range)!;
    start = int.parse(span.group(1)!);
    if (span.group(2)!.isNotEmpty) end = min(end, int.parse(span.group(2)!));
    if (maxPerResponse != null) end = min(end, start + maxPerResponse - 1);
  }
  if (start >= total) {
    return ResponseBody.fromBytes(const <int>[], 416, headers: {
      'content-range': ['bytes */$total'],
    });
  }
  return ResponseBody.fromBytes(all.sublist(start, end + 1), 206, headers: {
    'content-range': ['bytes $start-$end/$total'],
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
