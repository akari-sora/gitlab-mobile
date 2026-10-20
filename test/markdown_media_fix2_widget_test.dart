import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';
import 'package:gitlab_mobile/shared/attachment_image.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_media_source.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'session_test.dart' show MemoryAccountStore, controllerFor;
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
  Size size = const Size(16, 9);

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
            size: size,
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

  const secret = '0123456789abcdef0123456789abcdef';
  const svg =
      '<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><rect width="10" height="10"/></svg>';
  testWidgets('Argon7 uploaded SVG uses authenticated safe SVG renderer', (
    tester,
  ) async {
    final adapter = FakeAdapter((_) => ResponseBody.fromString(svg, 200));
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      _host(
        MarkdownView(
          '![diagram](/uploads/$secret/diagram.svg)',
          api: api,
          projectId: 42,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byType(AttachmentImage), findsNothing);
    expect(adapter.requests.single.headers['PRIVATE-TOKEN'], isNotEmpty);
  });
  testWidgets(
    'Argon7 uploaded unsafe SVG is blocked after authenticated read',
    (tester) async {
      final adapter = FakeAdapter(
        (_) => ResponseBody.fromString(
          '<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>',
          200,
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '![diagram](/uploads/$secret/diagram.svg)',
            api: api,
            projectId: 42,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.byType(AttachmentImage), findsNothing);
      expect(find.byType(SvgPicture), findsNothing);
      expect(find.textContaining(l10n.cannotDecodeImage), findsNothing);
      expect(find.textContaining(l10n.markdownMediaBlocked), findsOneWidget);
    },
  );
  for (final dimension in [1, 16, 24]) {
    testWidgets('Argon7 upload fallback fits ${dimension}px box', (
      tester,
    ) async {
      final adapter = FakeAdapter((_) => ResponseBody.fromString('bad', 200));
      final api = testApi(adapter);
      addTearDown(api.close);
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '<img src="/uploads/$secret/badge.png" width="$dimension" height="$dimension">',
            api: api,
            projectId: 42,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.byType(AttachmentImage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('Argon7 fallback itself adapts to tiny constraints', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        Align(
          child: SizedBox(
            width: 16,
            height: 16,
            child: attachmentImageFallback('tiny'),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byType(Icon)).width, lessThanOrEqualTo(16));
    expect(tester.getSize(find.byType(Icon)).height, lessThanOrEqualTo(16));
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Argon8 known account with no API never reads same instance anonymously',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final adapter = FakeAdapter((_) => ResponseBody.fromString('HTML', 200));
      final web = fixture.account.instance.projectWeb('team/project');
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '![arch]($web/-/raw/main/docs/arch.png)',
            account: fixture.account,
            externalMediaClient: Dio()..httpClientAdapter = adapter,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(adapter.requests, isEmpty);
      final image = tester.widget<MarkdownMediaImage>(
        find.byType(MarkdownMediaImage),
      );
      expect(image.source.kind, MarkdownMediaSourceKind.repository);
    },
  );
  for (final html in [
    '<video src="clips/demo.ogg"></video>',
    '<video><source src="clips/demo.ogg" type="video/ogg"></video>',
  ]) {
    testWidgets('Argon11 video element overrides ogg extension $html', (
      tester,
    ) async {
      await tester.pumpWidget(_host(MarkdownView(html)));
      expect(
        tester.widget<MarkdownMediaCard>(find.byType(MarkdownMediaCard)).audio,
        isFalse,
      );
    });
  }
  testWidgets('ArgonM2 blocked media allocates and registers nothing', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    var roots = 0;
    artifactStorageRoot = () async {
      roots++;
      return root;
    };
    final loader = MarkdownMediaLoader();
    addTearDown(loader.close);
    await tester.pumpWidget(
      _host(
        MarkdownMediaCard(
          source: const MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.blocked,
          ),
          loader: loader,
          account: fixture.account,
        ),
      ),
    );
    await tester.tap(find.byTooltip(l10n.markdownMediaPlay));
    await settleNetworkWidgets(tester);
    expect(roots, 0);
    expect(root.listSync(recursive: true), isEmpty);
    expect(markdownMediaCleanupCount(fixture.account), 0);
  });
  testWidgets('ArgonM2 failed download unregisters account cleanup', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final loader = MarkdownMediaLoader(
      external: Dio()
        ..httpClientAdapter = FakeAdapter(
          (_) => ResponseBody.fromString('bad', 500),
        ),
    );
    addTearDown(loader.close);
    await tester.pumpWidget(
      _host(
        MarkdownMediaCard(
          source: MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.external,
            uri: Uri.parse('https://cdn.example/clip.mp4'),
            filename: 'clip.mp4',
          ),
          loader: loader,
          account: fixture.account,
        ),
      ),
    );
    await tester.tap(find.byTooltip(l10n.markdownMediaPlay));
    await settleNetworkWidgets(tester);
    expect(markdownMediaCleanupCount(fixture.account), 0);
    expect(root.listSync(recursive: true).whereType<File>(), isEmpty);
  });
  testWidgets('ArgonM3 media uses session active account when omitted', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final session = controllerFor(MemoryAccountStore(), fixture.adapter)
      ..active = fixture.account;
    addTearDown(session.dispose);
    final loader = MarkdownMediaLoader(
      external: Dio()
        ..httpClientAdapter = FakeAdapter(
          (_) => ResponseBody.fromBytes(
            [1],
            200,
            headers: {
              'content-type': ['video/mp4'],
            },
          ),
        ),
    );
    addTearDown(loader.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _host(
          MarkdownMediaCard(
            source: MarkdownMediaSource(
              kind: MarkdownMediaSourceKind.external,
              uri: Uri.parse('https://cdn.example/clip.mp4'),
              filename: 'clip.mp4',
            ),
            loader: loader,
            account: null,
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip(l10n.markdownMediaPlay));
    await settleNetworkWidgets(tester);
    expect(platform.sources, hasLength(1));
    expect(platform.calls, contains('play:0'));
  });
  for (final size in [
    const Size(9, 16),
    Size.zero,
    const Size(double.infinity, 1),
  ]) {
    testWidgets('ArgonM3 video bounds and guards ratio $size', (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      platform.size = size;
      final loader = MarkdownMediaLoader(
        external: Dio()
          ..httpClientAdapter = FakeAdapter(
            (_) => ResponseBody.fromBytes(
              [1],
              200,
              headers: {
                'content-type': ['video/mp4'],
              },
            ),
          ),
      );
      addTearDown(loader.close);
      await tester.pumpWidget(
        _host(
          MarkdownMediaCard(
            source: MarkdownMediaSource(
              kind: MarkdownMediaSourceKind.external,
              uri: Uri.parse('https://cdn.example/clip.mp4'),
              filename: 'clip.mp4',
            ),
            loader: loader,
            account: fixture.account,
          ),
        ),
      );
      await tester.tap(find.byTooltip(l10n.markdownMediaPlay));
      await settleNetworkWidgets(tester);
      final ratios = tester.widgetList<AspectRatio>(find.byType(AspectRatio));
      expect(ratios, isNotEmpty);
      expect(
        ratios.every((w) => w.aspectRatio > 0 && w.aspectRatio.isFinite),
        isTrue,
      );
      expect(
        tester.getSize(find.byType(AspectRatio).first).height,
        lessThanOrEqualTo(480),
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
    'raw traversal stays blocked through reference image destinations',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final web = fixture.account.instance.projectWeb('team/project');
      for (final destination in [
        '/../secret.png',
        '/%2e%2e/secret.png',
        '///evil.example/a.png',
      ]) {
        await tester.pumpWidget(
          _host(
            MarkdownView(
              '![x][unsafe]\n\n[unsafe]: $destination',
              api: fixture.api,
              projectId: 42,
              projectWeb: web,
              base: Uri.parse('$web/-/blob/main/docs/README.md'),
            ),
          ),
        );
        await tester.pump();
        expect(
          tester
              .widget<MarkdownMediaImage>(find.byType(MarkdownMediaImage))
              .source
              .kind,
          MarkdownMediaSourceKind.blocked,
          reason: destination,
        );
      }
      expect(fixture.adapter.requests, isEmpty);
    },
  );
}
