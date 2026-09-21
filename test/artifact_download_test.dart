import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

Matcher failure(FailureKind kind) => isA<ApiFailure>().having((error) => error.kind, 'kind', kind);

void expectNoCredential(RequestOptions request) {
  for (final key in request.headers.keys) {
    final name = key.toLowerCase();
    expect(name, isNot('private-token'), reason: 'follow-up forwarded $key');
    expect(name, isNot('authorization'), reason: 'follow-up forwarded $key');
    expect(name, isNot('cookie'), reason: 'follow-up forwarded $key');
  }
}

class _CollectingSink implements IOSink {
  final _buffer = BytesBuilder(copy: false);
  var closed = false;
  Uint8List get bytes => _buffer.toBytes();
  void _check() {
    if (closed) throw StateError('closed');
  }
  @override
  Encoding encoding = utf8;
  @override
  void add(List<int> data) { _check(); _buffer.add(data); }
  @override
  void addError(Object error, [StackTrace? stackTrace]) => _check();
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) { add(chunk); }
  }
  @override
  Future<void> flush() async {}
  @override
  Future<void> close() async { closed = true; }
  @override
  Future<dynamic> get done async {}
  @override
  void write(Object? object) => add(utf8.encode('$object'));
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => write(objects.join(separator));
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
  @override
  void writeln([Object? object = '']) => write('$object\n');
}

class _FullSink extends _CollectingSink {
  @override
  void add(List<int> data) {
    throw const FileSystemException('no space');
  }
}

class _HoldFlushSink extends _CollectingSink {
  _HoldFlushSink(this.gate);
  final Completer<void> gate;
  final _done = Completer<void>();
  @override
  Future<dynamic> get done => _done.future;
  @override
  Future<void> flush() => gate.future;
  @override
  Future<void> close() async {
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }
}

class _AsyncFailSink extends _CollectingSink {
  final _done = Completer<void>();
  @override
  Future<dynamic> get done => _done.future;
  @override
  void add(List<int> data) {
    super.add(data);
    scheduleMicrotask(() {
      if (!_done.isCompleted) _done.completeError(const FileSystemException('no space'));
    });
  }
  @override
  Future<void> close() async {
    closed = true;
    if (!_done.isCompleted) _done.complete();
  }
}

ResponseBody _statusBody(int status, Map<String, List<String>> headers) => ResponseBody(
  Stream<Uint8List>.value(Uint8List(0)), status, headers: headers,
);

/// The production cleanup may still be removing a cache directory when a
/// test's tearDown runs; only a directory that is verifiably gone is ignored.
/// Any other filesystem failure (permissions, a file still open) is a real
/// leak and fails the test instead of being swallowed.
Future<void> removeQuietly(Directory directory) async {
  try {
    if (directory.existsSync()) await directory.delete(recursive: true);
  } on FileSystemException {
    if (directory.existsSync()) rethrow;
  }
}

void main() {
  test('artifact archive is 256 MiB', () {
    expect(GitLabApi.maxArtifactBytes, 256 * 1024 * 1024);
  });

  test('302 follow-up is a single unauthenticated request and reports progress', () async {
    const location = 'https://cdn.artifacts.gitlab-static.net/signed/file.zip';
    const payload = [9, 8, 7];
    final adapter = FakeAdapter((request) {
      if (request.uri.host == 'cdn.artifacts.gitlab-static.net') {
        return ResponseBody(Stream<Uint8List>.value(Uint8List.fromList(payload)), 200, headers: {
          Headers.contentTypeHeader: ['application/zip'],
          Headers.contentLengthHeader: ['${payload.length}'],
          'content-disposition': ["attachment; filename=\"ignored.zip\"; filename*=UTF-8''build%20artifacts.zip"],
        });
      }
      return _statusBody(302, {'location': [location]});
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    final sink = _CollectingSink();
    final progress = <(int, int?)>[];
    final result = await api.downloadJobArtifacts(8, 3, sink: sink, onProgress: (received, total) {
      progress.add((received, total));
    });
    expect(adapter.requests, hasLength(2));
    expect(adapter.requests.first.uri.path, endsWith('/projects/8/jobs/3/artifacts'));
    expect(adapter.requests.first.headers['PRIVATE-TOKEN'], 'synthetic-test-token');
    expect(adapter.requests.first.followRedirects, isFalse);
    expect(adapter.requests.last.uri.toString(), location);
    expect(adapter.requests.last.followRedirects, isFalse);
    expect(adapter.requests.last.data, isNull);
    expect(adapter.requests.first.data, isNull);
    expectNoCredential(adapter.requests.last);
    expect(sink.bytes, payload);
    expect(result.bytesWritten, payload.length);
    expect(result.fileName, 'build artifacts.zip');
    expect(result.contentType, 'application/zip');
    expect(progress, [(payload.length, payload.length)]);
    expect(sink.closed, isFalse);
    await sink.close();
  });

  for (final location in [
    'http://cdn.artifacts.gitlab-static.net/a.zip',
    'https://user:secret@cdn.artifacts.gitlab-static.net/a.zip',
    'artifacts.zip',
    '/projects/8/jobs/3/artifacts',
  ]) {
    test('artifact Location $location is blocked with no follow-up', () async {
      final adapter = FakeAdapter((_) => _statusBody(302, {'location': [location]}));
      final api = testApi(adapter);
      addTearDown(api.close);
      await expectLater(
        api.downloadJobArtifacts(8, 3, sink: _CollectingSink()),
        throwsA(failure(FailureKind.redirectBlocked)),
      );
      expect(adapter.requests, hasLength(1));
    });
  }

  test('a second artifact redirect is not followed', () async {
    final adapter = FakeAdapter((request) {
      final location = request.uri.host == 'cdn.artifacts.gitlab-static.net'
          ? 'https://cdn.artifacts.gitlab-static.net/again.zip'
          : 'https://cdn.artifacts.gitlab-static.net/signed/file.zip';
      return _statusBody(302, {'location': [location]});
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(
      api.downloadJobArtifacts(8, 3, sink: _CollectingSink()),
      throwsA(failure(FailureKind.redirectBlocked)),
    );
    expect(adapter.requests, hasLength(2));
    expectNoCredential(adapter.requests.last);
  });

  test('credential defaults and interceptors stay off the CDN hop', () async {
    const location = 'https://cdn.artifacts.gitlab-static.net/signed/file.zip';
    final adapter = FakeAdapter((request) {
      if (request.uri.host == 'cdn.artifacts.gitlab-static.net') {
        return ResponseBody(Stream<Uint8List>.value(Uint8List.fromList([1])), 200);
      }
      return _statusBody(302, {'location': [location]});
    });
    final dio = Dio()..httpClientAdapter = adapter;
    dio.options.headers['Authorization'] = 'Bearer leaked';
    dio.options.headers['PRIVATE-TOKEN'] = 'leaked-token';
    dio.options.headers['Cookie'] = 'sid=leaked';
    dio.options.queryParameters['private_token'] = 'leaked';
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      options.headers['Authorization'] = 'Bearer from-interceptor';
      options.headers['Cookie'] = 'intercepted=1';
      options.headers['X-Leak'] = '1';
      handler.next(options);
    }));
    final api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: dio,
      cdnAdapter: adapter,
    );
    addTearDown(api.close);
    await api.downloadJobArtifacts(8, 3, sink: _CollectingSink());
    expect(adapter.requests, hasLength(2));
    final hop = adapter.requests.last;
    expect(hop.uri.toString(), location);
    expect(hop.data, isNull);
    expect(hop.followRedirects, isFalse);
    expect(hop.maxRedirects, 0);
    expectNoCredential(hop);
    expect(hop.headers.keys.map((key) => key.toLowerCase()), isNot(contains('x-leak')));
    expect(hop.uri.queryParameters.containsKey('private_token'), isFalse);
    expect(hop.queryParameters.containsKey('private_token'), isFalse);
  });

  test('CDN hop does not see a cookie-bearing account adapter', () async {
    const location = 'https://cdn.artifacts.gitlab-static.net/signed/file.zip';
    final cookies = _CookieAdapter((request) => _statusBody(302, {
      'location': [location],
      'set-cookie': ['sid=secret; Path=/; HttpOnly'],
    }));
    final cdn = FakeAdapter((request) => ResponseBody(
      Stream<Uint8List>.value(Uint8List.fromList([1])),
      200,
    ));
    final api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = cookies,
      cdnAdapter: cdn,
    );
    addTearDown(api.close);
    await api.downloadJobArtifacts(8, 3, sink: _CollectingSink());
    expect(cookies.cookie, 'sid=secret');
    expect(cookies.requests, hasLength(1));
    expect(cookies.requests.single.uri.host, 'example.com');
    expect(cdn.requests, hasLength(1));
    expect(cdn.requests.single.uri.toString(), location);
    expectNoCredential(cdn.requests.single);
    expect(cdn.requests.single.headers.values.join(' '), isNot(contains('sid=secret')));
  });

  test('CDN hop without an injected adapter ignores the account adapter', () async {
    final cookies = _CookieAdapter((request) => _statusBody(302, {
      'location': ['https://127.0.0.1:1/file.zip'],
      'set-cookie': ['sid=secret; Path=/'],
    }));
    final api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: Dio()..httpClientAdapter = cookies,
    );
    addTearDown(api.close);
    // The widget binding answers an unstubbed client with HTTP 400.
    await expectLater(
      api.downloadJobArtifacts(8, 3, sink: _CollectingSink()),
      throwsA(isA<ApiFailure>()
          .having((error) => error.kind, 'kind', FailureKind.validation)
          .having((error) => error.status, 'status', 400)),
    );
    expect(cookies.cookie, 'sid=secret');
    expect(cookies.requests, hasLength(1));
    expect(cookies.requests.single.uri.host, 'example.com');
  });

  for (final status in [401, 403, 404, 429, 500]) {
    test('CDN status $status keeps its own failure and is not replayed', () async {
      final adapter = FakeAdapter((request) {
        if (request.uri.host == 'cdn.artifacts.gitlab-static.net') {
          return _statusBody(status, {if (status == 429) 'retry-after': ['60']});
        }
        return _statusBody(302, {'location': ['https://cdn.artifacts.gitlab-static.net/signed/file.zip']});
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final expected = ApiFailure.fromStatus(status, retryAt: status == 429 ? DateTime.now() : null);
      await expectLater(
        api.downloadJobArtifacts(8, 3, sink: _CollectingSink()),
        throwsA(isA<ApiFailure>()
            .having((error) => error.kind, 'kind', expected.kind)
            .having((error) => error.status, 'status', status)
            .having((error) => error.title, 'title', isNot('資源網址已變更'))),
      );
      expect(adapter.requests, hasLength(2));
      expectNoCredential(adapter.requests.last);
      expect(adapter.requests.last.data, isNull);
      if (status == 429) {
        await expectLater(
          api.downloadJobArtifacts(8, 3, sink: _CollectingSink()),
          throwsA(failure(FailureKind.rateLimited)),
        );
        expect(adapter.requests, hasLength(2));
      }
    });
  }

  test('a filesystem error while writing an artifact is not an invalid response', () async {
    final api = testApi(FakeAdapter((_) => ResponseBody(
      Stream<Uint8List>.value(Uint8List.fromList([1, 2, 3])),
      200,
    )));
    addTearDown(api.close);
    await expectLater(
      api.downloadJobArtifacts(8, 3, sink: _FullSink()),
      throwsA(isA<ApiFailure>()
          .having((error) => error.kind, 'kind', FailureKind.network)
          .having((error) => error.title, 'title', '無法儲存產物')
          .having((error) => error.detail, 'detail', contains('寫入'))),
    );
  });

  test('1000 small chunks notify progress far less often than once each', () {
    var ticks = 0;
    final progress = ArtifactProgress(clock: () => DateTime.fromMillisecondsSinceEpoch(ticks));
    var callbacks = 0;
    progress.value.addListener(() => callbacks++);
    for (var i = 1; i <= 1000; i++) {
      ticks += 1;
      progress.report(i, 1000);
    }
    progress.report(1000, 1000, completed: true);
    expect(callbacks, lessThan(50));
    expect(callbacks, greaterThan(5));
    expect(progress.value.value, (1000, 1000));
    progress.dispose();
  });

  test('a raw stream error after close is cancelled', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    final adapter = FakeAdapter((_) => ResponseBody(
      () async* {
        yield Uint8List.fromList([1]);
        if (!started.isCompleted) started.complete();
        await release.future;
        throw StateError('socket reset');
      }(),
      200,
    ));
    final api = testApi(adapter);
    addTearDown(api.close);
    final pending = api.downloadJobArtifacts(8, 3, sink: _CollectingSink());
    await started.future;
    api.close();
    await expectLater(pending, throwsA(failure(FailureKind.cancelled)));
  });

  test('content-length above the artifact cap cancels without reading the body', () async {
    var reads = 0;
    var listened = false;
    var released = false;
    final body = StreamController<Uint8List>(
      onListen: () => listened = true,
      onCancel: () {
        released = true;
      },
    );
    addTearDown(body.close);
    final adapter = FakeAdapter((_) => ResponseBody(
      body.stream.map((chunk) {
        reads += 1;
        return chunk;
      }),
      200,
      headers: {Headers.contentLengthHeader: ['${GitLabApi.maxArtifactBytes + 1}']},
    ));
    final api = testApi(adapter);
    addTearDown(api.close);
    final sink = _CollectingSink();
    await expectLater(
      api.downloadJobArtifacts(8, 3, sink: sink),
      throwsA(isA<ApiFailure>()
          .having((error) => error.kind, 'kind', FailureKind.tooLarge)
          .having((error) => error.detail, 'detail', contains('256 MiB'))
          .having((error) => error.title, 'title', '產物超過下載上限')),
    );
    expect(listened, isTrue);
    expect(released, isTrue);
    expect(reads, 0);
    expect(sink.bytes, isEmpty);
    expect(sink.closed, isFalse);
    expect(adapter.requests, hasLength(1));
    await adapter.cancelFutures.single;
  });

  test('streamed artifact bytes above the cap close the sink', () async {
    final adapter = FakeAdapter((_) => ResponseBody(
      Stream<Uint8List>.fromIterable([
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([4, 5, 6]),
      ]),
      200,
      headers: {Headers.contentTypeHeader: ['application/octet-stream']},
    ));
    final api = testApi(adapter);
    addTearDown(api.close);
    final sink = _CollectingSink();
    final progress = <int>[];
    await expectLater(
      api.downloadJobArtifacts(8, 3, sink: sink, maxBytes: 4, onProgress: (received, _) => progress.add(received)),
      throwsA(failure(FailureKind.tooLarge)),
    );
    expect(sink.closed, isTrue);
    expect(sink.bytes, [1, 2, 3]);
    expect(progress, [3]);
    await adapter.cancelFutures.single;
  });

  test('close() during artifact streaming is cancelled', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    final adapter = FakeAdapter((_) => ResponseBody(
      () async* {
        yield Uint8List.fromList([1, 2, 3, 4]);
        if (!started.isCompleted) started.complete();
        await release.future;
        yield Uint8List.fromList([5]);
      }(),
      200,
    ));
    final api = testApi(adapter);
    addTearDown(api.close);
    final pending = api.downloadJobArtifacts(8, 3, sink: _CollectingSink());
    await started.future;
    api.close();
    await expectLater(pending, throwsA(failure(FailureKind.cancelled)));
  });

  test('artifact transport errors are network and a missing disposition uses the job name', () async {
    final broken = testApi(FakeAdapter((_) => throw StateError('offline')));
    addTearDown(broken.close);
    await expectLater(broken.downloadJobArtifacts(8, 3, sink: _CollectingSink()), throwsA(failure(FailureKind.network)));
    final direct = testApi(FakeAdapter((_) => ResponseBody(
      Stream<Uint8List>.value(Uint8List.fromList([1])),
      200,
      headers: {'content-disposition': ['attachment; filename="../../kept.zip"']},
    )));
    addTearDown(direct.close);
    final sink = _CollectingSink();
    final named = await direct.downloadJobArtifacts(8, 4, sink: sink);
    expect(named.fileName, 'kept.zip');
    final plain = testApi(FakeAdapter((_) => ResponseBody(
      Stream<Uint8List>.value(Uint8List.fromList([2])), 200,
    )));
    addTearDown(plain.close);
    expect((await plain.downloadJobArtifacts(8, 9, sink: _CollectingSink())).fileName, 'artifacts-9.zip');
  });

  test('first artifact response uses ApiFailure status mapping', () async {
    final api = testApi(FakeAdapter((_) => jsonResponse({'message': 'hidden'}, status: 404)));
    addTearDown(api.close);
    await expectLater(
      api.downloadJobArtifacts(8, 3, sink: _CollectingSink()),
      throwsA(isA<ApiFailure>().having((error) => error.kind, 'kind', FailureKind.invisible).having((error) => error.status, 'status', 404)),
    );
  });

  testWidgets('job page downloads an artifact and shares the saved file', (tester) async {
    final fixture = _DownloadFixture()..pause = Completer<void>();
    addTearDown(fixture.api.close);
    final sharer = _StubSharer();
    Directory? directory;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(JobLogPage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 501, sharer: sharer,
      artifactDirectory: (account, projectId, jobId) async {
        final created = await Directory.systemTemp.createTemp('gitlab-mobile-artifacts-$projectId-$jobId-');
        directory = created;
        return created;
      },
    )));
    addTearDown(() async {
      final created = directory;
      if (created != null) await removeQuietly(created);
    });
    await settleWorkspace(tester);
    await tester.tap(find.byTooltip('工作操作'));
    await tester.pumpAndSettle();
    expect(find.text('下載產物'), findsOneWidget);
    await tester.tap(find.text('下載產物'));
    await settleWorkspace(tester);
    expect(find.text('artifacts.zip'), findsWidgets);
    expect(find.text('4 B'), findsWidgets);
    expect(find.text('0 B / 4 B'), findsOneWidget);
    final progress = tester.widget<LinearProgressIndicator>(find.byKey(const Key('artifact-progress')));
    expect(progress.value, 0);
    expect(find.text('取消'), findsOneWidget);
    fixture.pause!.complete();
    await settleWorkspace(tester);
    expect(find.text('已下載 artifacts.zip · 4 B'), findsOneWidget);
    expect(find.text('在 GitLab 開啟'), findsOneWidget);
    await tester.tap(find.text('開啟／分享'));
    await tester.pump();
    expect(sharer.paths.single, endsWith('/artifacts.zip'));
    expect(File(sharer.paths.single).readAsBytesSync(), [1, 2, 3, 4]);
  });

  testWidgets('cancelling an artifact download removes the partial file', (tester) async {
    final fixture = _DownloadFixture()..pause = Completer<void>();
    addTearDown(fixture.api.close);
    addTearDown(() { if (!fixture.pause!.isCompleted) fixture.pause!.complete(); });
    Directory? directory;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(JobLogPage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 501,
      artifactDirectory: (account, projectId, jobId) async {
        final created = await Directory.systemTemp.createTemp('gitlab-mobile-artifacts-cancel-');
        directory = created;
        return created;
      },
    )));
    addTearDown(() async {
      final created = directory;
      if (created != null) await removeQuietly(created);
    });
    await settleWorkspace(tester);
    await tester.tap(find.byTooltip('工作操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下載產物'));
    await settleWorkspace(tester);
    expect(directory!.listSync().map((entity) => entity.path), contains(endsWith('.download.partial')));
    await tester.tap(find.text('取消'));
    await settleWorkspace(tester);
    expect(find.text('取消'), findsNothing);
    expect(find.text('已下載 artifacts.zip · 4 B'), findsNothing);
    expect(directory!.existsSync(), isFalse);
  });

  testWidgets('artifact download failure shows the failure notice and keeps no partial', (tester) async {
    final fixture = _DownloadFixture()..artifactStatus = 404;
    addTearDown(fixture.api.close);
    Directory? directory;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(JobLogPage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 501,
      artifactDirectory: (account, projectId, jobId) async {
        final created = await Directory.systemTemp.createTemp('gitlab-mobile-artifacts-fail-');
        directory = created;
        return created;
      },
    )));
    addTearDown(() async {
      final created = directory;
      if (created != null) await removeQuietly(created);
    });
    await settleWorkspace(tester);
    await tester.tap(find.byTooltip('工作操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下載產物'));
    await settleWorkspace(tester);
    expect(find.text('無法開啟此資源'), findsOneWidget);
    expect(find.text('診斷資訊'), findsOneWidget);
    expect(find.text('重新整理'), findsOneWidget);
    expect(directory!.existsSync(), isFalse);
  });

  testWidgets('oversized artifact sheet states the 256 MiB cap', (tester) async {
    final fixture = _DownloadFixture()..artifactLength = GitLabApi.maxArtifactBytes + 1;
    addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(JobLogPage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 501,
      artifactDirectory: (account, projectId, jobId) async =>
          Directory.systemTemp.createTemp('gitlab-mobile-artifacts-cap-'),
    )));
    await settleWorkspace(tester);
    await tester.tap(find.byTooltip('工作操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下載產物'));
    await settleWorkspace(tester);
    expect(find.text('產物超過下載上限'), findsOneWidget);
    expect(find.textContaining('256 MiB'), findsOneWidget);
    expect(find.textContaining('2 MiB'), findsNothing);
  });

  testWidgets('artifact failure retry starts a fresh download', (tester) async {
    final fixture = _DownloadFixture()..artifactStatus = 404;
    addTearDown(fixture.api.close);
    final created = <Directory>[];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(JobLogPage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 501,
      artifactDirectory: (account, projectId, jobId) async {
        final directory = await Directory.systemTemp.createTemp('gitlab-mobile-artifacts-retry-');
        created.add(directory);
        return directory;
      },
    )));
    addTearDown(() async {
      for (final directory in created) {
        await removeQuietly(directory);
      }
    });
    await settleWorkspace(tester);
    await tester.tap(find.byTooltip('工作操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下載產物'));
    await settleWorkspace(tester);
    expect(find.text('無法開啟此資源'), findsOneWidget);
    fixture.artifactStatus = 200;
    await tester.tap(find.text('重新整理'));
    await settleWorkspace(tester);
    expect(find.text('已下載 artifacts.zip · 4 B'), findsOneWidget);
    expect(created, hasLength(2));
    expect(created.first.path, isNot(created.last.path));
    // The failed attempt is removed by the download itself, not by tearDown.
    expect(created.first.existsSync(), isFalse);
    expect(created.last.existsSync(), isTrue);
  });

  testWidgets('cancel during flush does not promote the artifact', (tester) async {
    final fixture = _DownloadFixture();
    addTearDown(fixture.api.close);
    final gate = Completer<void>();
    addTearDown(() { if (!gate.isCompleted) gate.complete(); });
    Directory? directory;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(JobLogPage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 501,
      openSink: (_) => _HoldFlushSink(gate),
      artifactDirectory: (account, projectId, jobId) async {
        final created = await Directory.systemTemp.createTemp('gitlab-mobile-artifacts-flush-');
        directory = created;
        return created;
      },
    )));
    addTearDown(() async {
      final created = directory;
      if (created != null) await removeQuietly(created);
    });
    await settleWorkspace(tester);
    await tester.tap(find.byTooltip('工作操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下載產物'));
    await settleWorkspace(tester);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('4 B / 4 B'), findsOneWidget);
    expect(find.textContaining('已下載'), findsNothing);
    await tester.tap(find.text('取消'));
    gate.complete();
    await settleWorkspace(tester);
    expect(find.textContaining('已下載'), findsNothing);
    expect(find.text('取消'), findsNothing);
    expect(directory!.existsSync(), isFalse);
  });

  testWidgets('closing the client during flush does not promote the artifact', (tester) async {
    final fixture = _DownloadFixture();
    addTearDown(fixture.api.close);
    final gate = Completer<void>();
    addTearDown(() { if (!gate.isCompleted) gate.complete(); });
    Directory? directory;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(JobLogPage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 501,
      openSink: (_) => _HoldFlushSink(gate),
      artifactDirectory: (account, projectId, jobId) async {
        final created = await Directory.systemTemp.createTemp('gitlab-mobile-artifacts-close-');
        directory = created;
        return created;
      },
    )));
    addTearDown(() async {
      final created = directory;
      if (created != null) await removeQuietly(created);
    });
    await settleWorkspace(tester);
    await tester.tap(find.byTooltip('工作操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下載產物'));
    await settleWorkspace(tester);
    expect(find.text('4 B / 4 B'), findsOneWidget);
    expect(find.textContaining('已下載'), findsNothing);
    fixture.api.close();
    gate.complete();
    await settleWorkspace(tester);
    expect(find.textContaining('已下載'), findsNothing);
    expect(directory!.existsSync(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an account switch during rename does not promote the artifact', (tester) async {
    final fixture = _DownloadFixture();
    addTearDown(fixture.api.close);
    final entered = Completer<void>();
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    Directory? directory;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = GlobalKey<_SessionHostState>();
    await tester.pumpWidget(_SessionHost(
      key: host,
      initial: fixture.account,
      builder: (account, generation) => workspaceHost(JobLogPage(
        account: account, generation: generation, api: fixture.api, project: fixture.project, id: 501,
        promoteArtifact: (partial, target) async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
          return promoteArtifactFile(partial, target);
        },
        artifactDirectory: (account, projectId, jobId) async {
          final created = await Directory.systemTemp.createTemp('gitlab-mobile-artifacts-switch-');
          directory = created;
          return created;
        },
      )),
    ));
    addTearDown(() async {
      final created = directory;
      if (created != null) await removeQuietly(created);
    });
    await settleWorkspace(tester);
    await tester.tap(find.byTooltip('工作操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下載產物'));
    await settleWorkspace(tester);
    expect(entered.isCompleted, isTrue);
    expect(find.textContaining('已下載'), findsNothing);
    host.currentState!.switchAccount(Account(
      instance: GitLabInstance.parse('https://other.example'),
      user: const GitLabUser(id: 9, username: 'other', name: 'Other'),
      token: 'synthetic-test-token',
    ));
    await tester.pump();
    release.complete();
    await settleWorkspace(tester);
    expect(find.textContaining('已下載'), findsNothing);
    expect(directory!.existsSync(), isFalse);
    expect(fixture.api.isClosed, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an asynchronous sink failure cancels the transfer', (tester) async {
    final release = Completer<void>();
    addTearDown(() { if (!release.isCompleted) release.complete(); });
    final fixture = _DownloadFixture()..release = release;
    addTearDown(fixture.api.close);
    Directory? directory;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(JobLogPage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 501,
      openSink: (_) => _AsyncFailSink(),
      artifactDirectory: (account, projectId, jobId) async {
        final created = await Directory.systemTemp.createTemp('gitlab-mobile-artifacts-sink-');
        directory = created;
        return created;
      },
    )));
    addTearDown(() async {
      final created = directory;
      if (created != null) await removeQuietly(created);
    });
    await settleWorkspace(tester);
    await tester.tap(find.byTooltip('工作操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下載產物'));
    await settleWorkspace(tester);
    expect(find.text('無法儲存產物'), findsOneWidget);
    expect(find.textContaining('已下載'), findsNothing);
    expect(tester.takeException(), isNull);
    expect(directory!.existsSync(), isFalse);
    final index = fixture.adapter.requests.lastIndexWhere((request) => request.uri.path.endsWith('/artifacts'));
    expect(index, isNonNegative);
    var cancelled = false;
    unawaited(fixture.adapter.cancelFutures[index]!.then((_) { cancelled = true; }));
    await tester.pump();
    expect(cancelled, isTrue);
  });

  testWidgets('a disposition named .partial is not saved as the temp file', (tester) async {
    final fixture = _DownloadFixture()..disposition = 'attachment; filename=".partial"';
    addTearDown(fixture.api.close);
    Directory? directory;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(JobLogPage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 501,
      artifactDirectory: (account, projectId, jobId) async {
        final created = await Directory.systemTemp.createTemp('gitlab-mobile-artifacts-name-');
        directory = created;
        return created;
      },
    )));
    addTearDown(() async {
      final created = directory;
      if (created != null) await removeQuietly(created);
    });
    await settleWorkspace(tester);
    await tester.tap(find.byTooltip('工作操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下載產物'));
    await settleWorkspace(tester);
    expect(find.textContaining('已下載 artifacts-501.zip'), findsOneWidget);
    expect(find.text('無法讀取回應'), findsNothing);
    expect(File('${directory!.path}/artifacts-501.zip').readAsBytesSync(), [1, 2, 3, 4]);
    expect(File('${directory!.path}/.download.partial').existsSync(), isFalse);
    expect(File('${directory!.path}/.partial').existsSync(), isFalse);
  });

  test('artifact directories are unique per attempt and removed with the account', () async {
    final root = await Directory.systemTemp.createTemp('gitlab-mobile-artifact-root-');
    final previous = artifactStorageRoot;
    artifactStorageRoot = () async => root;
    addTearDown(() async {
      artifactStorageRoot = previous;
      if (root.existsSync()) await root.delete(recursive: true);
    });
    Account accountFor(String host, int id) => Account(
      instance: GitLabInstance.parse(host),
      user: GitLabUser(id: id, username: 'user$id', name: 'User $id'),
      token: 'synthetic-test-token',
    );
    final firstAccount = accountFor('https://one.example', 7);
    final secondAccount = accountFor('https://two.example', 7);
    final first = await jobArtifactDirectory(firstAccount, 4, 9);
    final second = await jobArtifactDirectory(firstAccount, 4, 9);
    final other = await jobArtifactDirectory(secondAccount, 4, 9);
    expect(first.path, isNot(second.path));
    expect(first.path, contains(artifactAccountSegment(firstAccount)));
    expect(other.path, contains(artifactAccountSegment(secondAccount)));
    expect(first.path.contains(artifactAccountSegment(secondAccount)), isFalse);
    await File('${first.path}/secret.bin').writeAsBytes([1, 2, 3]);
    await clearAccountArtifacts(firstAccount);
    expect(first.existsSync(), isFalse);
    expect(second.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
    expect(File('${other.path}/secret.bin').existsSync(), isFalse);
  });

  test('a 220-byte account key uses a fixed-length cache segment', () async {
    final root = await Directory.systemTemp.createTemp('gitlab-mobile-artifact-digest-');
    final previous = artifactStorageRoot;
    artifactStorageRoot = () async => root;
    addTearDown(() async {
      artifactStorageRoot = previous;
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final account = Account(
      instance: GitLabInstance.parse('https://example.com/${'a' * 198}'),
      user: const GitLabUser(id: 7, username: 'long', name: 'Long'),
      token: 'synthetic-test-token',
    );
    expect(utf8.encode(account.key), hasLength(220));
    final segment = artifactAccountSegment(account);
    expect(segment, sha256.convert(utf8.encode(account.key)).toString().substring(0, 32));
    expect(segment, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(segment.length, lessThan(255));
    final directory = await jobArtifactDirectory(account, 1, 2);
    expect(directory.existsSync(), isTrue);
    expect(directory.parent.parent.path.split(Platform.pathSeparator).last, segment);
    final other = Account(
      instance: GitLabInstance.parse('https://example.com/${'b' * 198}'),
      user: const GitLabUser(id: 7, username: 'long', name: 'Long'),
      token: 'synthetic-test-token',
    );
    expect(artifactAccountSegment(other), isNot(segment));
  });

  test('artifact cleanup failure is not reported as success', () async {
    final account = Account(
      instance: GitLabInstance.parse('https://example.com'),
      user: const GitLabUser(id: 7, username: 'user', name: 'User'),
      token: 'synthetic-test-token',
    );
    final previous = artifactStorageRoot;
    artifactStorageRoot = () async => throw const FileSystemException('missing root');
    addTearDown(() { artifactStorageRoot = previous; });
    await expectLater(
      clearAccountArtifacts(account),
      throwsA(isA<ApiFailure>().having((error) => error.title, 'title', '無法清除產物')),
    );
  });

  test('a failed artifact directory deletion keeps the archive', () async {
    final root = await Directory.systemTemp.createTemp('gitlab-mobile-artifact-locked-');
    final previous = artifactStorageRoot;
    artifactStorageRoot = () async => root;
    Directory? directory;
    addTearDown(() async {
      artifactStorageRoot = previous;
      final created = directory;
      if (created != null && created.existsSync()) Process.runSync('chmod', ['u+w', created.path]);
      if (root.existsSync()) await root.delete(recursive: true);
    });
    final account = Account(
      instance: GitLabInstance.parse('https://example.com'),
      user: const GitLabUser(id: 7, username: 'user', name: 'User'),
      token: 'synthetic-test-token',
    );
    final created = await jobArtifactDirectory(account, 4, 9);
    directory = created;
    final archive = File('${created.path}/secret.bin');
    await archive.writeAsBytes([1, 2, 3]);
    final chmod = Process.runSync('chmod', ['a-w', created.path]);
    expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
    await expectLater(
      clearAccountArtifacts(account),
      throwsA(isA<ApiFailure>()
          .having((error) => error.title, 'title', '無法清除產物')
          .having((error) => error.detail, 'detail', contains('帳號仍保留'))),
    );
    expect(archive.existsSync(), isTrue);
    expect(archive.readAsBytesSync(), [1, 2, 3]);
  });
}

final class _CookieAdapter implements HttpClientAdapter {
  _CookieAdapter(this._respond);
  final ResponseBody Function(RequestOptions request) _respond;
  final requests = <RequestOptions>[];
  String? cookie;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (cookie != null) options.headers['Cookie'] = cookie;
    requests.add(options);
    final body = _respond(options);
    final setCookie = body.headers['set-cookie'];
    if (setCookie != null && setCookie.isNotEmpty) cookie = setCookie.first.split(';').first.trim();
    return body;
  }
  @override
  void close({bool force = false}) {}
}

class _SessionHost extends StatefulWidget {
  const _SessionHost({super.key, required this.initial, required this.builder});
  final Account initial;
  final Widget Function(Account account, int generation) builder;
  @override
  State<_SessionHost> createState() => _SessionHostState();
}

class _SessionHostState extends State<_SessionHost> {
  late Account account = widget.initial;
  int generation = 0;
  void switchAccount(Account next) => setState(() {
    account = next;
    generation += 1;
  });
  @override
  Widget build(BuildContext context) => widget.builder(account, generation);
}

class _StubSharer implements ArtifactSharer {
  final paths = <String>[];
  @override
  Future<void> share(String path) async { paths.add(path); }
}

class _DownloadFixture extends WorkspaceFixture {
  Completer<void>? pause;
  Completer<void>? release;
  int artifactStatus = 200;
  int? artifactLength;
  String disposition = 'attachment; filename="artifacts.zip"';
  @override
  Json job(int id, {String status = 'success'}) {
    final value = super.job(id, status: status);
    final file = value['artifacts_file'];
    if (file is Map<Object?, Object?>) {
      value['artifacts_file'] = Map<String, dynamic>.from(file)..['size'] = 4;
    }
    return value;
  }
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final segments = request.uri.pathSegments;
    final path = segments.skip(segments.indexOf('v4') + 1).join('/');
    if (path == 'projects/42/jobs/501/artifacts') {
      if (artifactStatus != 200) return jsonResponse({'error': 'missing'}, status: artifactStatus);
      final length = artifactLength;
      final body = length != null
          ? Stream<Uint8List>.value(Uint8List(0))
          : () async* {
              await (pause?.future ?? Future<void>.value());
              yield Uint8List.fromList([1, 2, 3, 4]);
              final hold = release;
              if (hold != null) await hold.future;
            }();
      return ResponseBody(body, 200, headers: {
        Headers.contentTypeHeader: ['application/zip'],
        Headers.contentLengthHeader: ['${length ?? 4}'],
        'content-disposition': [disposition],
      });
    }
    return super.respond(request);
  }
}
