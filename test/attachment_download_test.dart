import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';
import 'package:gitlab_mobile/shared/attachment_budget.dart';
import 'package:gitlab_mobile/shared/attachment_download.dart';
import 'package:gitlab_mobile/shared/attachment_image.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

Matcher _isFailure(FailureKind kind) =>
    isA<ApiFailure>().having((e) => e.kind, 'kind', kind);

class _MemorySink implements IOSink {
  final _buffer = BytesBuilder(copy: false);
  bool _closed = false;

  Uint8List get bytes => _buffer.toBytes();
  bool get isClosed => _closed;

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {
    if (_closed) throw StateError('closed');
    _buffer.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  @override
  Future<dynamic> get done async {}

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) => add(utf8.encode('$object'));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => write('$object\n');
}

class _TestSharer implements ArtifactSharer {
  final List<String> sharedPaths = [];
  final List<Rect?> origins = [];
  ShareOutcome outcome = ShareOutcome.success;

  @override
  Future<ShareOutcome> share(String path, {Rect? sharePositionOrigin}) async {
    sharedPaths.add(path);
    origins.add(sharePositionOrigin);
    return outcome;
  }
}

class _FailingAttachmentDownloader implements AttachmentDownloader {
  _FailingAttachmentDownloader(this.failure);

  final ApiFailure failure;
  int callCount = 0;

  @override
  Future<File> downloadUpload({
    required int projectId,
    required String secret,
    required String filename,
    required Account account,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
  }) async {
    callCount++;
    throw failure;
  }
}

class _SuccessfulAttachmentDownloader implements AttachmentDownloader {
  _SuccessfulAttachmentDownloader(this.file);

  final File file;
  int callCount = 0;

  @override
  Future<File> downloadUpload({
    required int projectId,
    required String secret,
    required String filename,
    required Account account,
    void Function(int received, int? total)? onProgress,
    Future<void>? cancel,
  }) async {
    callCount++;
    final bytes = file.lengthSync();
    onProgress?.call(bytes, bytes);
    return file;
  }
}

class _ClosingWatchSink implements IOSink {
  _ClosingWatchSink(this._delegate, {required this.onClose});

  final IOSink _delegate;
  final void Function() onClose;

  @override
  Encoding get encoding => _delegate.encoding;
  @override
  set encoding(Encoding encoding) => _delegate.encoding = encoding;

  @override
  void add(List<int> data) => _delegate.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => _delegate.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _delegate.addStream(stream);

  @override
  Future<void> flush() => _delegate.flush();

  @override
  Future<void> close() async {
    onClose();
    await _delegate.close();
  }

  @override
  Future<dynamic> get done => _delegate.done;

  @override
  void write(Object? object) => _delegate.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _delegate.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _delegate.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _delegate.writeln(object);
}

void main() {
  late Directory testRoot;
  late Future<Directory> Function() defaultRoot;

  setUpAll(() async {
    testRoot = await Directory.systemTemp.createTemp('gitlab-attachment-test-');
    defaultRoot = artifactStorageRoot;
    artifactStorageRoot = () async => testRoot;
  });

  tearDownAll(() async {
    artifactStorageRoot = defaultRoot;
    if (testRoot.existsSync()) {
      testRoot.deleteSync(recursive: true);
    }
  });

  tearDown(() {
    resetArtifactShareCleanup();
    artifactStorageRoot = () async => testRoot;
  });

  const secret = '0123456789abcdef0123456789abcdef';
  final account = Account(
    instance: GitLabInstance.parse('https://example.com/gitlab'),
    user: const GitLabUser(id: 7, username: 'testuser', name: 'Test User'),
    token: 'synthetic-test-token',
  );

  group('GitLabApi.downloadProjectUpload', () {
    test('successful download writes bytes to sink and returns ArtifactDownload', () async {
      final expectedBytes = Uint8List.fromList([1, 2, 3, 4, 5, 42]);
      final adapter = FakeAdapter((request) {
        expect(request.path, 'https://example.com/gitlab/api/v4/projects/42/uploads/$secret/report.pdf');
        expect(request.method, 'GET');
        expect(request.headers['PRIVATE-TOKEN'], 'synthetic-test-token');
        return ResponseBody(
          Stream<Uint8List>.value(expectedBytes),
          200,
          headers: {
            'content-length': ['${expectedBytes.length}'],
            'content-type': ['application/pdf'],
          },
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final sink = _MemorySink();
      final progressReports = <(int, int?)>[];
      final result = await api.downloadProjectUpload(
        42,
        secret,
        'report.pdf',
        sink: sink,
        onProgress: (received, total) => progressReports.add((received, total)),
      );

      expect(result.fileName, 'report.pdf');
      expect(result.bytesWritten, expectedBytes.length);
      expect(result.contentType, 'application/pdf');
      expect(sink.bytes, expectedBytes);
      expect(progressReports.last, (expectedBytes.length, expectedBytes.length));
    });

    test('4 MiB budget: exactly 4 MiB (4194304 bytes) succeeds', () async {
      final fourMib = Uint8List(4 * 1024 * 1024);
      final adapter = FakeAdapter((request) {
        return ResponseBody(
          Stream<Uint8List>.value(fourMib),
          200,
          headers: {'content-length': ['${fourMib.length}']},
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final sink = _MemorySink();
      final result = await api.downloadProjectUpload(
        42,
        secret,
        'big.bin',
        sink: sink,
      );

      expect(result.bytesWritten, 4 * 1024 * 1024);
      expect(sink.bytes.length, 4 * 1024 * 1024);
    });

    test('4 MiB budget: Content-Length 4194305 bytes pre-check fails immediately with tooLarge', () async {
      var reads = 0;
      final controller = StreamController<Uint8List>();
      addTearDown(controller.close);

      final adapter = FakeAdapter((request) {
        return ResponseBody(
          controller.stream.map((chunk) {
            reads += chunk.length;
            return chunk;
          }),
          200,
          headers: {'content-length': ['4194305']},
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final sink = _MemorySink();
      await expectLater(
        api.downloadProjectUpload(42, secret, 'oversize.bin', sink: sink),
        throwsA(_isFailure(FailureKind.tooLarge)),
      );
      expect(sink.bytes, isEmpty);
      expect(reads, 0);
    });

    test('4 MiB budget: chunked stream exceeding 4 MiB cancels transport and throws tooLarge', () async {
      final chunk1 = Uint8List(2 * 1024 * 1024);
      final chunk2 = Uint8List(2 * 1024 * 1024);
      final chunk3 = Uint8List(100);

      final adapter = FakeAdapter((request) {
        return ResponseBody(
          Stream<Uint8List>.fromIterable([chunk1, chunk2, chunk3]),
          200,
          headers: {}, // No content-length (chunked)
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final sink = _MemorySink();
      await expectLater(
        api.downloadProjectUpload(42, secret, 'chunked.bin', sink: sink),
        throwsA(_isFailure(FailureKind.tooLarge)),
      );
    });

    test('4 MiB budget: fake small Content-Length header is caught by stream accumulation check', () async {
      final chunk1 = Uint8List(2 * 1024 * 1024);
      final chunk2 = Uint8List(3 * 1024 * 1024);

      final adapter = FakeAdapter((request) {
        return ResponseBody(
          Stream<Uint8List>.fromIterable([chunk1, chunk2]),
          200,
          headers: {'content-length': ['1024']}, // Fake small length
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final sink = _MemorySink();
      await expectLater(
        api.downloadProjectUpload(42, secret, 'fake_len.bin', sink: sink),
        throwsA(_isFailure(FailureKind.tooLarge)),
      );
    });

    test('Redirect rejection: 302 Found throws redirectBlocked and does NOT follow redirect', () async {
      final adapter = FakeAdapter((request) {
        return ResponseBody(
          Stream<Uint8List>.empty(),
          302,
          headers: {
            'location': ['https://evil-third-party.com/leak'],
          },
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final sink = _MemorySink();
      await expectLater(
        api.downloadProjectUpload(42, secret, 'redirect.pdf', sink: sink),
        throwsA(
          isA<ApiFailure>()
              .having((e) => e.kind, 'kind', FailureKind.redirectBlocked)
              .having((e) => e.status, 'status', 302),
        ),
      );
      expect(adapter.requests.length, 1);
    });

    test('Path traversal rejection: invalid secret throws unsupported without making requests', () async {
      final adapter = FakeAdapter((_) => throw StateError('should not be called'));
      final api = testApi(adapter);
      addTearDown(api.close);

      final sink = _MemorySink();
      await expectLater(
        api.downloadProjectUpload(42, 'bad-secret', 'file.pdf', sink: sink),
        throwsA(_isFailure(FailureKind.unsupported)),
      );
      expect(adapter.requests, isEmpty);
    });

    test('Path traversal rejection: filename with .., /, \\, or % throws unsupported without requests', () async {
      final adapter = FakeAdapter((_) => throw StateError('should not be called'));
      final api = testApi(adapter);
      addTearDown(api.close);

      final badFilenames = ['../etc/passwd', '..', 'sub/file.txt', r'sub\file.txt', 'file%2e.txt'];
      for (final bad in badFilenames) {
        final sink = _MemorySink();
        await expectLater(
          api.downloadProjectUpload(42, secret, bad, sink: sink),
          throwsA(_isFailure(FailureKind.unsupported)),
        );
      }
      expect(adapter.requests, isEmpty);
    });

    test('HTTP status error mapping: 404 maps to invisible, 403 maps to forbidden, 429 to rateLimited', () async {
      int currentStatus = 404;
      final adapter = FakeAdapter((_) => ResponseBody(
        Stream<Uint8List>.empty(),
        currentStatus,
        headers: currentStatus == 429 ? {'retry-after': ['60']} : {},
      ));
      final api = testApi(adapter);
      addTearDown(api.close);

      currentStatus = 404;
      await expectLater(
        api.downloadProjectUpload(42, secret, 'notfound.pdf', sink: _MemorySink()),
        throwsA(_isFailure(FailureKind.invisible)),
      );

      currentStatus = 403;
      await expectLater(
        api.downloadProjectUpload(42, secret, 'forbidden.pdf', sink: _MemorySink()),
        throwsA(_isFailure(FailureKind.forbidden)),
      );

      currentStatus = 429;
      await expectLater(
        api.downloadProjectUpload(42, secret, 'limited.pdf', sink: _MemorySink()),
        throwsA(_isFailure(FailureKind.rateLimited)),
      );
    });

    test('Cancellation: cancel future aborts download and throws cancelled', () async {
      final cancelCompleter = Completer<void>();
      final adapter = FakeAdapter((request) {
        final controller = StreamController<Uint8List>();
        return ResponseBody(controller.stream, 200);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final sink = _MemorySink();
      final future = api.downloadProjectUpload(
        42,
        secret,
        'hang.pdf',
        sink: sink,
        cancel: cancelCompleter.future,
      );

      scheduleMicrotask(() => cancelCompleter.complete());

      await expectLater(future, throwsA(_isFailure(FailureKind.cancelled)));
    });
  });

  group('DefaultAttachmentDownloader and storage', () {
    test('downloads to attempt-scoped .download.partial and atomically promotes to sanitized filename', () async {
      final tempRoot = await Directory.systemTemp.createTemp('gitlab-attachment-test-');
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => tempRoot;
      addTearDown(() {
        artifactStorageRoot = previousRoot;
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      final content = Uint8List.fromList([10, 20, 30, 40]);
      final adapter = FakeAdapter((_) => ResponseBody(
        Stream<Uint8List>.value(content),
        200,
        headers: {'content-length': ['${content.length}']},
      ));
      final api = testApi(adapter);
      addTearDown(api.close);

      final downloader = DefaultAttachmentDownloader(api: api);
      final file = await downloader.downloadUpload(
        projectId: 42,
        secret: secret,
        filename: 'manual.pdf',
        account: account,
      );

      expect(file.existsSync(), isTrue);
      expect(file.uri.pathSegments.last, 'manual.pdf');
      expect(file.readAsBytesSync(), content);

      // Verify .download.partial no longer exists
      final partial = File('${file.parent.path}/.download.partial');
      expect(partial.existsSync(), isFalse);
    });

    test('sanitizes dangerous or reserved names: .download.partial, .partial, null byte fallback to attachment.bin', () {
      expect(attachmentDownloadFileName('.download.partial'), 'attachment.bin');
      expect(attachmentDownloadFileName('.partial'), 'attachment.bin');
      expect(attachmentDownloadFileName('.'), 'attachment.bin');
      expect(attachmentDownloadFileName('..'), 'attachment.bin');
      expect(attachmentDownloadFileName('evil\u0000file.pdf'), 'attachment.bin');
      expect(attachmentDownloadFileName('good.pdf'), 'good.pdf');
      expect(attachmentDownloadFileName('path/to/nested.zip'), 'nested.zip');
    });

    test('failed download deletes .download.partial and cleans attempt directory', () async {
      final tempRoot = await Directory.systemTemp.createTemp('gitlab-attachment-fail-');
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => tempRoot;
      addTearDown(() {
        artifactStorageRoot = previousRoot;
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      final adapter = FakeAdapter((_) => ResponseBody(
        Stream<Uint8List>.error(const SocketException('connection reset')),
        200,
      ));
      final api = testApi(adapter);
      addTearDown(api.close);

      final downloader = DefaultAttachmentDownloader(api: api);
      await expectLater(
        downloader.downloadUpload(
          projectId: 42,
          secret: secret,
          filename: 'fail.pdf',
          account: account,
        ),
        throwsA(_isFailure(FailureKind.network)),
      );

      // Check that attachments directory has no leftover attempt dirs
      final attachmentsDir = Directory('${tempRoot.path}/attachments/${artifactAccountSegment(account)}/42');
      if (attachmentsDir.existsSync()) {
        expect(attachmentsDir.listSync(), isEmpty);
      }
    });

    test('server 500 error safely closes sink before deletion and preserves server failure without artifactStorage override', () async {
      final tempRoot = await Directory.systemTemp.createTemp('gitlab-attachment-500-');
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => tempRoot;
      addTearDown(() {
        artifactStorageRoot = previousRoot;
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      var sinkClosed = false;
      final adapter = FakeAdapter((_) => ResponseBody(
        Stream<Uint8List>.empty(),
        500,
      ));
      final api = testApi(adapter);
      addTearDown(api.close);

      final downloader = DefaultAttachmentDownloader(
        api: api,
        openSink: (file) {
          final realSink = openArtifactSink(file);
          return _ClosingWatchSink(realSink, onClose: () {
            sinkClosed = true;
          });
        },
      );

      await expectLater(
        downloader.downloadUpload(
          projectId: 42,
          secret: secret,
          filename: 'server_error.pdf',
          account: account,
        ),
        throwsA(
          isA<ApiFailure>()
              .having((e) => e.kind, 'kind', FailureKind.server)
              .having((e) => e.status, 'status', 500),
        ),
      );

      expect(sinkClosed, isTrue);

      final attachmentsDir = Directory('${tempRoot.path}/attachments/${artifactAccountSegment(account)}/42');
      if (attachmentsDir.existsSync()) {
        expect(attachmentsDir.listSync(), isEmpty);
      }
    });

    test('concurrent downloads for same project and upload use separate attempt directories', () async {
      final tempRoot = await Directory.systemTemp.createTemp('gitlab-attachment-concurrent-');
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => tempRoot;
      addTearDown(() {
        artifactStorageRoot = previousRoot;
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      final content = Uint8List.fromList([1, 2, 3]);
      final adapter = FakeAdapter((_) => ResponseBody(
        Stream<Uint8List>.value(content),
        200,
        headers: {'content-length': ['3']},
      ));
      final api = testApi(adapter);
      addTearDown(api.close);

      final downloader = DefaultAttachmentDownloader(api: api);
      final futures = await Future.wait([
        downloader.downloadUpload(projectId: 42, secret: secret, filename: 'doc.pdf', account: account),
        downloader.downloadUpload(projectId: 42, secret: secret, filename: 'doc.pdf', account: account),
      ]);

      expect(futures[0].path, isNot(futures[1].path));
      expect(futures[0].existsSync(), isTrue);
      expect(futures[1].existsSync(), isTrue);
    });

    test('clearAccountArtifacts deletes both artifacts and attachments for account', () async {
      final tempRoot = await Directory.systemTemp.createTemp('gitlab-clear-all-');
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => tempRoot;
      addTearDown(() {
        artifactStorageRoot = previousRoot;
        if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
      });

      final artDir = await jobArtifactDirectory(account, 10, 20);
      File('${artDir.path}/job.zip').writeAsBytesSync([1]);
      final attDir = await attachmentAttemptDirectory(account, 10);
      File('${attDir.path}/file.pdf').writeAsBytesSync([2]);

      expect(artDir.existsSync(), isTrue);
      expect(attDir.existsSync(), isTrue);

      await clearAccountArtifacts(account);

      final artAccount = Directory('${tempRoot.path}/artifacts/${artifactAccountSegment(account)}');
      final attAccount = Directory('${tempRoot.path}/attachments/${artifactAccountSegment(account)}');
      expect(artAccount.existsSync(), isFalse);
      expect(attAccount.existsSync(), isFalse);
    });
  });

  group('AttachmentDownloadSheet UI and interactions', () {

    testWidgets('shows progress indicator with Semantics percentage and allows cancellation', (tester) async {
      final controller = StreamController<Uint8List>();
      final adapter = FakeAdapter((_) => ResponseBody(
        controller.stream,
        200,
        headers: {'content-length': ['1000']},
      ));
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AttachmentDownloadSheet(
            account: account,
            api: api,
            projectId: 42,
            secret: secret,
            filename: 'test_doc.pdf',
            suggestedSize: 1000,
          ),
        ),
      ));
      await tester.pump();

      expect(find.text('test_doc.pdf'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      // Push 500 bytes (50%)
      controller.add(Uint8List(500));
      await tester.pump(const Duration(milliseconds: 150));

      final semantics = find.bySemanticsLabel(RegExp('附件下載進度'));
      expect(semantics, findsOneWidget);

      // Cancel button
      expect(find.text('取消'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pump();

      unawaited(controller.close());
    });

    testWidgets('failure shows FailureNotice with retry and 在 GitLab 開啟 link', (tester) async {
      final adapter = FakeAdapter((_) => ResponseBody(
        Stream<Uint8List>.empty(),
        500,
      ));
      final api = testApi(adapter);
      addTearDown(api.close);

      final failingDownloader = _FailingAttachmentDownloader(
        const ApiFailure(FailureKind.server, status: 500),
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AttachmentDownloadSheet(
            account: account,
            api: api,
            projectId: 42,
            secret: secret,
            filename: 'broken.pdf',
            suggestedSize: 1000,
            webUri: Uri.parse('https://example.com/gitlab/uploads/$secret/broken.pdf'),
            downloader: failingDownloader,
          ),
        ),
      ));
      await settleNetworkWidgets(tester);

      expect(failingDownloader.callCount, 1);
      expect(find.text('GitLab 暫時無法回應'), findsOneWidget);
      expect(find.text('重新整理'), findsOneWidget);
      expect(find.text('在 GitLab 開啟'), findsOneWidget);

      await tester.tap(find.text('重新整理'));
      await settleNetworkWidgets(tester);

      expect(failingDownloader.callCount, 2);
      expect(find.text('GitLab 暫時無法回應'), findsOneWidget);
    });

    testWidgets('completed download shows 開啟／分享 button and passes iPad sharePositionOrigin to sharer', (tester) async {
      final testFile = File('${testRoot.path}/ready.pdf')..writeAsBytesSync([1, 2, 3, 4, 5]);

      final adapter = FakeAdapter((_) => ResponseBody(
        Stream<Uint8List>.value(Uint8List.fromList([1, 2, 3, 4, 5])),
        200,
        headers: {'content-length': ['5']},
      ));
      final api = testApi(adapter);
      addTearDown(api.close);

      final sharer = _TestSharer();
      final downloader = _SuccessfulAttachmentDownloader(testFile);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AttachmentDownloadSheet(
            account: account,
            api: api,
            projectId: 42,
            secret: secret,
            filename: 'ready.pdf',
            suggestedSize: 5,
            sharer: sharer,
            downloader: downloader,
          ),
        ),
      ));
      await settleNetworkWidgets(tester);

      expect(downloader.callCount, 1);
      expect(find.textContaining('已下載 ready.pdf · 5 B'), findsOneWidget);
      expect(find.text('開啟／分享'), findsOneWidget);

      // Tap 開啟／分享
      await tester.tap(find.text('開啟／分享'));
      await settleNetworkWidgets(tester);

      expect(sharer.sharedPaths.length, 1);
      expect(sharer.sharedPaths.first, testFile.path);
      expect(sharer.origins.length, 1);
      final origin = sharer.origins.first;
      expect(origin, isNotNull);
      expect(origin!.width, greaterThan(0));
      expect(origin.height, greaterThan(0));
    });
  });

  group('AttachmentViewer and MarkdownView interactions', () {
    testWidgets('AttachmentViewer AppBar includes share button and calls sharer with memory bytes and iPad anchor', (tester) async {
      final bytes = Uint8List.fromList([10, 20, 30, 40, 50]);
      final sharer = _TestSharer();

      await tester.pumpWidget(MaterialApp(
        home: AttachmentViewer(
          bytes: bytes,
          title: 'viewed_image.png',
          semanticLabel: 'viewed_image.png',
          account: account,
          sharer: sharer,
        ),
      ));
      await settleNetworkWidgets(tester);

      final shareBtn = find.byTooltip('分享');
      expect(shareBtn, findsOneWidget);

      await tester.tap(shareBtn);
      await settleNetworkWidgets(tester);

      expect(sharer.sharedPaths.length, 1);
      final sharedFile = File(sharer.sharedPaths.first);
      expect(sharedFile.existsSync(), isTrue);
      expect(sharedFile.readAsBytesSync(), bytes);

      // Verify iPad popover anchor was calculated
      expect(sharer.origins.length, 1);
      final origin = sharer.origins.first;
      expect(origin, isNotNull);
      expect(origin!.width, greaterThan(0));
      expect(origin.height, greaterThan(0));
    });

    testWidgets('AttachmentImage _failureButton has minimum touch target >= 48x48 dp', (tester) async {
      final adapter = FakeAdapter((_) => ResponseBody(Stream<Uint8List>.empty(), 404));
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AttachmentImage(
            api: api,
            budget: AttachmentBudget(),
            projectId: 42,
            secret: secret,
            filename: 'missing.png',
          ),
        ),
      ));
      await settleNetworkWidgets(tester);

      final failureBtn = find.bySemanticsLabel('附件載入失敗，查看詳情');
      expect(failureBtn, findsOneWidget);
      final size = tester.getSize(failureBtn);
      expect(size.width, greaterThanOrEqualTo(48.0));
      expect(size.height, greaterThanOrEqualTo(48.0));
    });

    testWidgets('MarkdownView intercepts upload links and opens AttachmentDownloadSheet', (tester) async {
      final adapter = FakeAdapter((_) => ResponseBody(Stream<Uint8List>.empty(), 200));
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MarkdownView(
            '[Download Specification](/uploads/$secret/specification.docx)',
            api: api,
            projectId: 42,
            projectPath: 'group/project',
            base: Uri.parse('https://example.com/gitlab'),
            account: account,
          ),
        ),
      ));
      await settleNetworkWidgets(tester);

      final link = find.text('Download Specification');
      expect(link, findsOneWidget);

      await tester.tap(link);
      await settleNetworkWidgets(tester);

      expect(find.byType(AttachmentDownloadSheet), findsOneWidget);
      expect(find.text('specification.docx'), findsOneWidget);
    });
  });
}
