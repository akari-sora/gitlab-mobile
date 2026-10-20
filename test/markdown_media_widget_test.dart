import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';
import 'package:gitlab_mobile/shared/attachment_budget.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);
const _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="20" height="20" fill="red"/></svg>';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

final class _VideoPlatform extends VideoPlayerPlatform {
  final sources = <DataSource>[];
  final calls = <String>[];
  final streams = <StreamController<VideoEvent>>[];
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    sources.add(options.dataSource);
    final stream = StreamController<VideoEvent>();
    streams.add(stream);
    stream.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 30),
        size: const Size(320, 180),
      ),
    );
    return streams.length - 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId].stream;
  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose');
    await streams[playerId].close();
  }

  @override
  Future<void> play(int playerId) async {
    calls.add('play');
  }

  @override
  Future<void> pause(int playerId) async {
    calls.add('pause');
  }

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    calls.add('seek');
  }

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {
    calls.add('volume:$volume');
  }

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();
}

void main() {
  testWidgets(
    'README routes relative PNG, HTML img, SVG and external without credentials',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final apiAdapter = FakeAdapter(
        (request) => ResponseBody.fromBytes(
          request.uri.path.endsWith('logo.svg/raw') ? utf8.encode(_svg) : _png,
          200,
          headers: {
            'content-type': [
              request.uri.path.contains('svg') ? 'image/svg+xml' : 'image/png',
            ],
          },
        ),
      );
      final api = testApi(apiAdapter);
      addTearDown(api.close);
      final external = FakeAdapter(
        (_) => ResponseBody.fromBytes(
          _png,
          200,
          headers: {
            'content-type': ['image/png'],
          },
        ),
      );
      final dio = Dio()..httpClientAdapter = external;
      final web = fixture.account.instance.projectWeb(fixture.project.path);
      final widget = MarkdownView(
        '![relative](docs/a.png)\n\n<img src="html.png" alt="html" width="28" height="16">\n\n![svg](logo.svg)\n\n![external](https://images.example/a.png)',
        api: api,
        projectId: 42,
        projectWeb: web,
        base: Uri.parse('$web/-/blob/${'a' * 40}/README.md'),
        externalMediaClient: dio,
      );
      await tester.pumpWidget(_host(widget));
      await settleNetworkWidgets(tester);
      expect(find.byType(Image), findsNWidgets(3));
      expect(find.byType(SvgPicture), findsOneWidget);
      final mediaImages = tester
          .widgetList<MarkdownMediaImage>(find.byType(MarkdownMediaImage))
          .toList();
      expect(
        mediaImages.map((image) => image.source.path),
        containsAll(['docs/a.png', 'html.png', 'logo.svg']),
      );
      for (final image in mediaImages.where(
        (image) => image.source.path != null,
      )) {
        expect(image.source.project, '42');
        expect(image.source.ref, 'a' * 40);
      }
      expect(mediaImages.firstWhere((image) => image.alt == 'html').width, 28);
      final request = external.requests.single;
      expect(
        request.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('private-token')),
      );
      expect(
        request.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(
        request.headers.keys.map((key) => key.toLowerCase()),
        isNot(contains('cookie')),
      );
      expect(apiAdapter.requests, hasLength(3));
      for (final request in apiAdapter.requests) {
        expect(request.headers['PRIVATE-TOKEN'], 'synthetic-test-token');
        expect(request.followRedirects, isFalse);
        expect(
          request.uri.path,
          contains('/api/v4/projects/42/repository/files/'),
        );
        expect(request.uri.queryParameters['ref'], 'a' * 40);
      }
      await tester.pumpWidget(_host(widget));
      await settleNetworkWidgets(tester);
      expect(external.requests, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed content type retries on image tap; HTTP stays blocked', (
    tester,
  ) async {
    var attempts = 0;
    final adapter = FakeAdapter((_) {
      attempts++;
      return attempts == 1
          ? ResponseBody.fromString(
              'not an image',
              200,
              headers: {
                'content-type': ['text/html'],
              },
            )
          : ResponseBody.fromBytes(
              _png,
              200,
              headers: {
                'content-type': ['image/png'],
              },
            );
    });
    await tester.pumpWidget(
      _host(
        MarkdownView(
          '![remote](https://images.example/a.png)\n\n![blocked](http://images.example/a.png)',
          externalMediaClient: Dio()..httpClientAdapter = adapter,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.textContaining('這不是圖片'), findsOneWidget);
    expect(find.textContaining('已封鎖不安全'), findsOneWidget);
    await tester.tap(find.textContaining('這不是圖片'));
    await settleNetworkWidgets(tester);
    expect(adapter.requests, hasLength(2));
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets(
    'repository and external images share the image count and byte caps',
    (tester) async {
      final adapter = FakeAdapter(
        (_) => ResponseBody.fromBytes(
          _png,
          200,
          headers: {
            'content-type': ['image/png'],
          },
        ),
      );
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '![one](https://images.example/a.png)\n\n![two](https://images.example/b.png)',
            budget: AttachmentBudget(maxImages: 1),
            externalMediaClient: Dio()..httpClientAdapter = adapter,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(adapter.requests, hasLength(1));
      expect(find.textContaining('媒體超過大小限制'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      final bytesAdapter = FakeAdapter(
        (_) => ResponseBody.fromBytes(
          _png,
          200,
          headers: {
            'content-type': ['image/png'],
          },
        ),
      );
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '![one](https://images.example/a.png)',
            budget: AttachmentBudget(maxTotalBytes: 1),
            externalMediaClient: Dio()..httpClientAdapter = bytesAdapter,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.textContaining('媒體超過大小限制'), findsOneWidget);
    },
  );

  test('SVG references are local only', () {
    expect(markdownSvgIsSelfContained(_svg), isTrue);
    expect(
      markdownSvgIsSelfContained('<svg><use href="#local"/></svg>'),
      isTrue,
    );
    for (final svg in [
      '<svg><image href="https://other.example/a.png"/></svg>',
      '<svg><image href="data:image/png;base64,AAAA"/></svg>',
      '<!DOCTYPE svg><svg/>',
      '<svg><style>@import "https://example.com";</style></svg>',
      '<svg><path fill="url(https://example.com/a.svg)"/></svg>',
    ]) {
      expect(markdownSvgIsSelfContained(svg), isFalse);
    }
  });

  testWidgets(
    'media loads only on tap, uses a file, controls playback, and deletes on dispose',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final root = Directory.systemTemp.createTempSync('markdown-media-test-');
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => root;
      resetMarkdownMediaStartup();
      final platform = _VideoPlatform();
      final previousPlatform = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = platform;
      addTearDown(() {
        artifactStorageRoot = previousRoot;
        resetMarkdownMediaStartup();
        VideoPlayerPlatform.instance = previousPlatform;
        root.deleteSync(recursive: true);
      });
      final adapter = FakeAdapter(
        (_) => ResponseBody.fromBytes(
          [1, 2, 3],
          200,
          headers: {
            'content-type': ['video/mp4'],
            'content-length': ['3'],
          },
        ),
      );
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '[clip](https://media.example/clip.mp4)',
            account: fixture.account,
            externalMediaClient: Dio()..httpClientAdapter = adapter,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.byType(MarkdownMediaCard), findsOneWidget);
      expect(adapter.requests, isEmpty);
      expect(platform.sources, isEmpty);
      await tester.tap(find.byTooltip('播放'));
      await settleNetworkWidgets(tester);
      expect(platform.sources, hasLength(1));
      final source = platform.sources.single;
      expect(source.sourceType, DataSourceType.file);
      final file = File.fromUri(Uri.parse(source.uri!));
      expect(file.readAsBytesSync(), [1, 2, 3]);
      expect(
        file.path,
        contains('/media/${artifactAccountSegment(fixture.account)}/'),
      );
      expect(platform.calls, contains('play'));
      await tester.tap(find.byTooltip('暫停'));
      await settleNetworkWidgets(tester);
      expect(platform.calls, contains('pause'));
      await tester.tap(find.byType(VideoProgressIndicator));
      await settleNetworkWidgets(tester);
      expect(platform.calls, contains('seek'));
      await tester.tap(find.byTooltip('靜音'));
      await settleNetworkWidgets(tester);
      expect(platform.calls, contains('volume:0.0'));
      await tester.pumpWidget(const SizedBox());
      await settleNetworkWidgets(tester);
      expect(file.existsSync(), isFalse);
      expect(platform.calls, contains('dispose'));
    },
  );

  test('media cleared at next startup and on account removal', () async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final root = Directory.systemTemp.createTempSync('markdown-media-cleanup-');
    final previousRoot = artifactStorageRoot;
    artifactStorageRoot = () async => root;
    resetMarkdownMediaStartup();
    addTearDown(() {
      artifactStorageRoot = previousRoot;
      resetMarkdownMediaStartup();
      root.deleteSync(recursive: true);
    });
    final stale = Directory('${root.path}/media/old')
      ..createSync(recursive: true);
    File('${stale.path}/clip.mp4').writeAsBytesSync([1]);
    await clearStaleMarkdownMedia();
    expect(stale.existsSync(), isFalse);
    final attempt = await markdownMediaDirectory(fixture.account);
    File('${attempt.path}/clip.mp4').writeAsBytesSync([1]);
    await clearAccountArtifacts(fixture.account);
    expect(attempt.existsSync(), isFalse);
    final again = await markdownMediaDirectory(fixture.account);
    File('${again.path}/audio.mp3').writeAsBytesSync([2]);
    resetMarkdownMediaStartup();
    await clearStaleMarkdownMedia();
    expect(again.existsSync(), isFalse);
  });

  testWidgets(
    'cancelled media download never creates a player or leaves a file',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final root = Directory.systemTemp.createTempSync(
        'markdown-media-cancel-',
      );
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => root;
      resetMarkdownMediaStartup();
      addTearDown(() {
        artifactStorageRoot = previousRoot;
        resetMarkdownMediaStartup();
        root.deleteSync(recursive: true);
      });
      final gate = Completer<ResponseBody>();
      final adapter = FakeAdapter((_) => gate.future);
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '[clip](https://media.example/clip.mp4)',
            account: fixture.account,
            externalMediaClient: Dio()..httpClientAdapter = adapter,
          ),
        ),
      );
      await tester.tap(find.byTooltip('播放'));
      await settleNetworkWidgets(tester);
      expect(find.byTooltip('取消下載'), findsOneWidget);
      await tester.tap(find.byTooltip('取消下載'));
      await settleNetworkWidgets(tester);
      gate.complete(
        ResponseBody.fromBytes(
          [1],
          200,
          headers: {
            'content-type': ['video/mp4'],
          },
        ),
      );
      await settleNetworkWidgets(tester);
      expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'account removal fences directory creation already waiting on storage',
    () async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final root = Directory.systemTemp.createTempSync('markdown-media-race-');
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => root;
      resetMarkdownMediaStartup();
      addTearDown(() {
        artifactStorageRoot = previousRoot;
        resetMarkdownMediaStartup();
        root.deleteSync(recursive: true);
      });
      await clearStaleMarkdownMedia();
      final gate = Completer<Directory>();
      artifactStorageRoot = () => gate.future;
      final pending = markdownMediaDirectory(fixture.account);
      final assertion = expectLater(
        pending,
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      final cleanup = clearAccountArtifacts(fixture.account);
      gate.complete(root);
      await assertion;
      await cleanup;
      expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    },
  );

  test(
    'account removal blocks fresh attempts while cleanup is pending',
    () async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final root = Directory.systemTemp.createTempSync(
        'markdown-media-removing-',
      );
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => root;
      resetMarkdownMediaStartup();
      addTearDown(() {
        artifactStorageRoot = previousRoot;
        resetMarkdownMediaStartup();
        root.deleteSync(recursive: true);
      });
      await clearStaleMarkdownMedia();
      final gate = Completer<void>();
      registerMarkdownMediaCleanup(fixture.account, () => gate.future);
      final cleanup = clearAccountArtifacts(fixture.account);
      await expectLater(
        markdownMediaDirectory(fixture.account),
        throwsA(
          isA<ApiFailure>().having(
            (error) => error.kind,
            'kind',
            FailureKind.cancelled,
          ),
        ),
      );
      gate.complete();
      await cleanup;
      expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    },
  );

  testWidgets(
    'account removal cancels a pending download and deletes its attempt',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final root = Directory.systemTemp.createTempSync(
        'markdown-media-remove-',
      );
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => root;
      resetMarkdownMediaStartup();
      addTearDown(() {
        artifactStorageRoot = previousRoot;
        resetMarkdownMediaStartup();
        root.deleteSync(recursive: true);
      });
      final gate = Completer<ResponseBody>();
      final adapter = FakeAdapter((_) => gate.future);
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '[clip](https://media.example/clip.mp4)',
            account: fixture.account,
            externalMediaClient: Dio()..httpClientAdapter = adapter,
          ),
        ),
      );
      await tester.tap(find.byTooltip('播放'));
      await settleNetworkWidgets(tester);
      var cleaned = false;
      final cleanup = clearAccountArtifacts(
        fixture.account,
      ).then((_) => cleaned = true);
      await pumpUntil(
        tester,
        () => cleaned,
        description: 'account media cleanup',
      );
      await cleanup;
      gate.complete(
        ResponseBody.fromBytes(
          [1],
          200,
          headers: {
            'content-type': ['video/mp4'],
          },
        ),
      );
      await settleNetworkWidgets(tester);
      expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
      final requests = adapter.requests.length;
      await tester.tap(find.byTooltip('播放'));
      await settleNetworkWidgets(tester);
      expect(adapter.requests, hasLength(requests));
      expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('oversized media is visible and removes the partial file', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final root = Directory.systemTemp.createTempSync('markdown-media-large-');
    final previousRoot = artifactStorageRoot;
    artifactStorageRoot = () async => root;
    resetMarkdownMediaStartup();
    addTearDown(() {
      artifactStorageRoot = previousRoot;
      resetMarkdownMediaStartup();
      root.deleteSync(recursive: true);
    });
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromBytes(
        [1],
        200,
        headers: {
          'content-type': ['video/mp4'],
          'content-length': ['104857601'],
        },
      ),
    );
    await tester.pumpWidget(
      _host(
        MarkdownView(
          '[clip](https://media.example/clip.mp4)',
          account: fixture.account,
          externalMediaClient: Dio()..httpClientAdapter = adapter,
        ),
      ),
    );
    await tester.tap(find.byTooltip('播放'));
    await settleNetworkWidgets(tester);
    expect(find.textContaining('媒體超過大小限制'), findsOneWidget);
    expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
    expect(tester.takeException(), isNull);
  });

  test('media cleanup failure keeps account removal failed', () async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final root = Directory.systemTemp.createTempSync('markdown-media-failure-');
    final previousRoot = artifactStorageRoot;
    final previousRemove = removeArtifactDirectory;
    artifactStorageRoot = () async => root;
    resetMarkdownMediaStartup();
    addTearDown(() {
      artifactStorageRoot = previousRoot;
      removeArtifactDirectory = previousRemove;
      resetMarkdownMediaStartup();
      root.deleteSync(recursive: true);
    });
    await markdownMediaDirectory(fixture.account);
    removeArtifactDirectory = (_) =>
        throw const FileSystemException('synthetic');
    await expectLater(
      clearAccountArtifacts(fixture.account),
      throwsA(isA<ApiFailure>()),
    );
  });
}
