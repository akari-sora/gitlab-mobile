import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_media_source.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

final class _ControllableVideoPlatform extends VideoPlayerPlatform {
  final sources = <DataSource>[];
  final calls = <String>[];
  final streams = <StreamController<VideoEvent>>[];
  bool failNextInitialization = false;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    sources.add(options.dataSource);
    final stream = StreamController<VideoEvent>();
    streams.add(stream);
    if (failNextInitialization) {
      failNextInitialization = false;
      scheduleMicrotask(
        () => stream.addError(
          PlatformException(
            code: 'synthetic_initialization_error',
            message: 'synthetic initialization error',
          ),
        ),
      );
    } else {
      scheduleMicrotask(
        () => stream.add(
          VideoEvent(
            eventType: VideoEventType.initialized,
            duration: const Duration(seconds: 3),
            size: const Size(16, 9),
          ),
        ),
      );
    }
    return streams.length - 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId].stream;

  @override
  Future<void> dispose(int playerId) async {
    calls.add('dispose:$playerId');
    await streams[playerId].close();
  }

  @override
  Future<void> play(int playerId) async => calls.add('play:$playerId');

  @override
  Future<void> pause(int playerId) async => calls.add('pause:$playerId');

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();
}

void main() {
  late Directory root;
  late Future<Directory> Function() previousRoot;
  late VideoPlayerPlatform previousPlatform;
  late _ControllableVideoPlatform platform;

  setUp(() {
    root = Directory.systemTemp.createTempSync('markdown-card-fix1-');
    previousRoot = artifactStorageRoot;
    artifactStorageRoot = () async => root;
    resetMarkdownMediaStartup();
    previousPlatform = VideoPlayerPlatform.instance;
    platform = _ControllableVideoPlatform();
    VideoPlayerPlatform.instance = platform;
  });

  tearDown(() async {
    useLanguage(languageForTag('zh-TW')!);
    artifactStorageRoot = previousRoot;
    resetMarkdownMediaStartup();
    VideoPlayerPlatform.instance = previousPlatform;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets('failed account cleanup lets the retained card retry', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromBytes(
        [1, 2, 3],
        200,
        headers: {
          'content-type': ['video/mp4'],
        },
      ),
    );
    final oldRemove = removeArtifactDirectory;
    addTearDown(() => removeArtifactDirectory = oldRemove);
    await tester.pumpWidget(
      _host(
        MarkdownMediaCard(
          source: MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.external,
            uri: Uri.parse('https://media.example/video.mp4'),
            filename: 'video.mp4',
          ),
          loader: MarkdownMediaLoader(
            external: Dio()..httpClientAdapter = adapter,
          ),
          account: fixture.account,
        ),
      ),
    );
    final accountDirectory = Directory(
      '${root.path}/media/${artifactAccountSegment(fixture.account)}/stale',
    )..createSync(recursive: true);
    File('${accountDirectory.path}/stale.mp4').writeAsBytesSync([1]);
    removeArtifactDirectory = (_) =>
        throw const FileSystemException('synthetic cleanup failure');

    await expectLater(
      clearAccountArtifacts(fixture.account),
      throwsA(isA<ApiFailure>()),
    );
    removeArtifactDirectory = oldRemove;
    await tester.tap(find.byTooltip('播放'));
    await settleNetworkWidgets(tester);

    expect(adapter.requests, hasLength(1));
    expect(platform.calls, contains('play:0'));
  });

  testWidgets('a newly mounted card can use a re-added account identity', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromBytes(
        [1],
        200,
        headers: {
          'content-type': ['video/mp4'],
        },
      ),
    );
    await clearAccountArtifacts(fixture.account);
    await tester.pumpWidget(
      _host(
        MarkdownMediaCard(
          source: MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.external,
            uri: Uri.parse('https://media.example/video.mp4'),
            filename: 'video.mp4',
          ),
          loader: MarkdownMediaLoader(
            external: Dio()..httpClientAdapter = adapter,
          ),
          account: fixture.account,
        ),
      ),
    );
    await tester.tap(find.byTooltip('播放'));
    await settleNetworkWidgets(tester);

    expect(adapter.requests, hasLength(1));
    expect(platform.calls, contains('play:0'));
  });

  testWidgets('a post-initialization player error is visible and retryable', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromBytes(
        [1],
        200,
        headers: {
          'content-type': ['video/mp4'],
        },
      ),
    );
    await tester.pumpWidget(
      _host(
        MarkdownMediaCard(
          source: MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.external,
            uri: Uri.parse('https://media.example/video.mp4'),
            filename: 'video.mp4',
          ),
          loader: MarkdownMediaLoader(
            external: Dio()..httpClientAdapter = adapter,
          ),
          account: fixture.account,
        ),
      ),
    );
    await tester.tap(find.byTooltip('播放'));
    await settleNetworkWidgets(tester);
    platform.streams.single.addError(
      PlatformException(
        code: 'synthetic_decoder_error',
        message: 'synthetic decoder error',
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('無法播放媒體'), findsOneWidget);
    expect(find.textContaining('重試'), findsOneWidget);
    await tester.tap(find.textContaining('重試'));
    await settleNetworkWidgets(tester);

    expect(adapter.requests, hasLength(2));
    expect(platform.sources, hasLength(2));
    expect(platform.calls, contains('dispose:0'));
    expect(platform.calls, contains('play:1'));
  });

  testWidgets('player initialization failure is accurate and cleans its file', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromBytes(
        [1],
        200,
        headers: {
          'content-type': ['video/mp4'],
        },
      ),
    );
    platform.failNextInitialization = true;
    await tester.pumpWidget(
      _host(
        MarkdownMediaCard(
          source: MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.external,
            uri: Uri.parse('https://media.example/video.mp4'),
            filename: 'video.mp4',
          ),
          loader: MarkdownMediaLoader(
            external: Dio()..httpClientAdapter = adapter,
          ),
          account: fixture.account,
        ),
      ),
    );
    await tester.tap(find.byTooltip('播放'));
    await settleNetworkWidgets(tester);

    expect(find.textContaining('無法播放媒體'), findsOneWidget);
    expect(platform.calls, contains('dispose:0'));
    expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  testWidgets('repository 404 opens account and source recovery details', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final adapter = FakeAdapter((_) => ResponseBody.fromString('', 404));
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      _host(
        MarkdownMediaCard(
          source: const MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.repository,
            project: '42',
            ref: 'main',
            path: 'private/video.mp4',
            filename: 'video.mp4',
          ),
          loader: MarkdownMediaLoader(api: api),
          account: fixture.account,
        ),
      ),
    );
    await tester.tap(find.byTooltip('播放'));
    await settleNetworkWidgets(tester);
    await tester.tap(find.textContaining('重試'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(FailureNotice), findsOneWidget);
    expect(find.textContaining('42/main/private/video.mp4'), findsOneWidget);
    expect(find.textContaining(fixture.account.instance.key), findsOneWidget);
    expect(find.textContaining('developer'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);
  });

  testWidgets('card isolates filenames and labels indeterminate progress', (
    tester,
  ) async {
    useLanguage(languageForTag('ar')!);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final response = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => response.future);
    await tester.pumpWidget(
      _host(
        MarkdownMediaCard(
          source: MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.external,
            uri: Uri.parse('https://media.example/video'),
            filename: 'clip-44.mp4',
          ),
          loader: MarkdownMediaLoader(
            external: Dio()..httpClientAdapter = adapter,
          ),
          account: fixture.account,
        ),
      ),
    );

    expect(find.text('\u2068clip-44.mp4\u2069'), findsOneWidget);
    await tester.tap(find.byTooltip('تشغيل'));
    await tester.pump();
    final progress = find.byType(LinearProgressIndicator);
    expect(progress, findsOneWidget);
    expect(
      tester.getSemantics(progress).label,
      contains(l10n.markdownMediaLoading),
    );
    response.complete(
      ResponseBody.fromBytes(
        [1],
        200,
        headers: {
          'content-type': ['video/mp4'],
        },
      ),
    );
    await settleNetworkWidgets(tester);
  });

  testWidgets('download completion does not autoplay while app is paused', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final response = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => response.future);
    await tester.pumpWidget(
      _host(
        MarkdownMediaCard(
          source: MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.external,
            uri: Uri.parse('https://media.example/video.mp4'),
            filename: 'video.mp4',
          ),
          loader: MarkdownMediaLoader(
            external: Dio()..httpClientAdapter = adapter,
          ),
          account: fixture.account,
        ),
      ),
    );
    await tester.tap(find.byTooltip('播放'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    response.complete(
      ResponseBody.fromBytes(
        [1],
        200,
        headers: {
          'content-type': ['video/mp4'],
        },
      ),
    );
    await settleNetworkWidgets(tester);

    expect(platform.calls.where((call) => call.startsWith('play:')), isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('content type gives extension to an extensionless media file', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromBytes(
        [1],
        200,
        headers: {
          'content-type': ['audio/mpeg'],
        },
      ),
    );
    await tester.pumpWidget(
      _host(
        MarkdownMediaCard(
          source: MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.external,
            uri: Uri.parse('https://media.example/tracks/7'),
            filename: '7',
          ),
          loader: MarkdownMediaLoader(
            external: Dio()..httpClientAdapter = adapter,
          ),
          account: fixture.account,
          audio: true,
        ),
      ),
    );
    await tester.tap(find.byTooltip('播放'));
    await settleNetworkWidgets(tester);

    expect(Uri.parse(platform.sources.single.uri!).path, endsWith('/7.mp3'));
  });
}
