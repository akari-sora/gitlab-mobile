import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
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

ResponseBody _statusBody(int status, Map<String, List<String>> headers) => ResponseBody(
  Stream<Uint8List>.value(Uint8List(0)), status, headers: headers,
);

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

  test('content-length above the artifact cap fails before the body is read', () async {
    var reads = 0;
    final body = StreamController<Uint8List>();
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
    await expectLater(api.downloadJobArtifacts(8, 3, sink: sink), throwsA(failure(FailureKind.tooLarge)));
    expect(reads, 0);
    expect(sink.bytes, isEmpty);
    expect(sink.closed, isFalse);
    expect(adapter.requests, hasLength(1));
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
      artifactDirectory: (projectId, jobId) async {
        final created = await Directory.systemTemp.createTemp('gitlab-mobile-artifacts-$projectId-$jobId-');
        directory = created;
        return created;
      },
    )));
    addTearDown(() async {
      final created = directory;
      if (created != null && created.existsSync()) await created.delete(recursive: true);
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
      artifactDirectory: (projectId, jobId) async {
        final created = await Directory.systemTemp.createTemp('gitlab-mobile-artifacts-cancel-');
        directory = created;
        return created;
      },
    )));
    addTearDown(() async {
      final created = directory;
      if (created != null && created.existsSync()) await created.delete(recursive: true);
    });
    await settleWorkspace(tester);
    await tester.tap(find.byTooltip('工作操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下載產物'));
    await settleWorkspace(tester);
    expect(directory!.listSync().map((entity) => entity.path), contains(endsWith('.partial')));
    await tester.tap(find.text('取消'));
    await settleWorkspace(tester);
    expect(find.text('取消'), findsNothing);
    expect(directory!.listSync(), isEmpty);
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
      artifactDirectory: (projectId, jobId) async {
        final created = await Directory.systemTemp.createTemp('gitlab-mobile-artifacts-fail-');
        directory = created;
        return created;
      },
    )));
    addTearDown(() async {
      final created = directory;
      if (created != null && created.existsSync()) await created.delete(recursive: true);
    });
    await settleWorkspace(tester);
    await tester.tap(find.byTooltip('工作操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下載產物'));
    await settleWorkspace(tester);
    expect(find.text('無法開啟此資源'), findsOneWidget);
    expect(find.text('診斷資訊'), findsOneWidget);
    expect(directory!.listSync(), isEmpty);
  });
}

class _StubSharer implements ArtifactSharer {
  final paths = <String>[];
  @override
  Future<void> share(String path) async { paths.add(path); }
}

class _DownloadFixture extends WorkspaceFixture {
  Completer<void>? pause;
  int artifactStatus = 200;
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
      final body = Stream<Uint8List>.fromFuture((pause?.future ?? Future<void>.value()).then((_) => Uint8List.fromList([1, 2, 3, 4])));
      return ResponseBody(body, 200, headers: {
        Headers.contentTypeHeader: ['application/zip'],
        Headers.contentLengthHeader: ['4'],
        'content-disposition': ['attachment; filename="artifacts.zip"'],
      });
    }
    return super.respond(request);
  }
}
