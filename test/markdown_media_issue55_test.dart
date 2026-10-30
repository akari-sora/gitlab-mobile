import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';
import 'package:gitlab_mobile/shared/attachment_budget.dart';
import 'package:gitlab_mobile/shared/attachment_image.dart';
import 'package:gitlab_mobile/shared/attachment_ref.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_media_source.dart';
import 'package:gitlab_mobile/shared/markdown_media_svg.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/shared/network_boundary.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

const _secret = '0123456789abcdef0123456789abcdef';
final _sha = 'a' * 40;

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Builds a valid GIF89a payload of [totalBytes] (e.g. 3 MiB) with 1x1 logical
/// screen dimensions and a comment extension padded to [totalBytes].
Uint8List _largeGifBytes(int totalBytes) {
  final header = <int>[
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
    0x01, 0x00, 0x01, 0x00, // 1x1
    0x80, 0x00, 0x00, // GCT 2 colors
    0x00, 0x00, 0x00, 0xff, 0xff, 0xff,
  ];
  final frame = <int>[
    0x21, 0xf9, 0x04, 0x00, 0x0a, 0x00, 0x00, 0x00, // GCE 100ms
    0x2c, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, // 1x1 image
    0x02, 0x02, 0x44, 0x01, 0x00, // LZW data
  ];
  final out = BytesBuilder(copy: false)
    ..add(header)
    ..add(frame)
    ..add(const [0x21, 0xfe]); // Comment extension
  var remaining = totalBytes - out.length - 2;
  final block = Uint8List(255)..fillRange(0, 255, 0x41);
  while (remaining > 256) {
    out.addByte(255);
    out.add(block);
    remaining -= 256;
  }
  if (remaining > 1) {
    out.addByte(remaining - 1);
    out.add(Uint8List(remaining - 1)..fillRange(0, remaining - 1, 0x41));
  }
  out.add(const [0x00, 0x3b]); // Sub-block terminator + GIF trailer ';'
  return out.takeBytes();
}

Uint8List _craftedGif({
  required int screenW,
  required int screenH,
  required int frameW,
  required int frameH,
  int left = 0,
  int top = 0,
}) {
  int lo(int v) => v & 0xff;
  int hi(int v) => (v >> 8) & 0xff;
  return Uint8List.fromList([
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, // GIF89a
    lo(screenW), hi(screenW), lo(screenH), hi(screenH), 0x80, 0x00, 0x00,
    0x00, 0x00, 0x00, 0xff, 0xff, 0xff, // 2-entry GCT
    0x2c, lo(left), hi(left), lo(top), hi(top),
    lo(frameW), hi(frameW), lo(frameH), hi(frameH), 0x00,
    0x02, 0x01, 0x2c, 0x00, // LZW min 2, one sub-block (clear, EOI), terminator
    0x3b,
  ]);
}

Uint8List _craftedJpegWithRst() {
  final b = BytesBuilder();
  b.add(const [0xff, 0xd8, 0xff, 0xd0]); // SOI, RST0 (parameterless)
  b.add(const [
    0xff, 0xc0, 0x00, 0x0b, 0x08, 0x40, 0x00, 0x40, 0x00, 0x01, 0x01, 0x11, 0x00,
  ]); // SOF0 16384x16384
  final com = Uint8List(65533);
  const fake = [
    0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x00,
  ];
  const at = 65476 - 21;
  for (var i = 0; i < fake.length; i++) {
    com[at + i] = fake[i];
  }
  b.add(const [0xff, 0xfe, 0xff, 0xff]);
  b.add(com);
  b.add([0xff, 0xdb, 0x00, 0x43, 0x00, ...List.filled(64, 1)]);
  b.add(const [
    0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00, 0, 0, 0, 0, 0xff, 0xd9,
  ]);
  return b.takeBytes();
}

final class _RequestRecord {
  _RequestRecord({
    required this.timestampMs,
    required this.client,
    required this.method,
    required this.uri,
    required this.contentType,
  });

  final int timestampMs;
  final String client;
  final String method;
  final Uri uri;
  final String contentType;
  int bytesRead = 0;

  @override
  String toString() =>
      '[+${timestampMs}ms] $client $method ${uri.path}${uri.hasQuery ? '?${uri.query}' : ''} '
      'type=$contentType bytesRead=$bytesRead';
}

ResponseBody _trackedStreamResponse(
  _RequestRecord record,
  Uint8List payload, {
  int chunkSize = 64 * 1024,
  int status = 200,
  Map<String, List<String>> headers = const {},
}) {
  late final StreamController<Uint8List> controller;
  var cancelled = false;
  controller = StreamController<Uint8List>(
    onListen: () {
      unawaited(() async {
        for (var offset = 0; offset < payload.length; offset += chunkSize) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
          if (cancelled || controller.isClosed) return;
          final end = offset + chunkSize < payload.length
              ? offset + chunkSize
              : payload.length;
          final chunk = Uint8List.sublistView(payload, offset, end);
          record.bytesRead += chunk.length;
          controller.add(chunk);
        }
        if (!cancelled && !controller.isClosed) {
          await controller.close();
        }
      }());
    },
    onCancel: () {
      cancelled = true;
    },
  );

  return ResponseBody(
    controller.stream,
    status,
    headers: {
      'content-type': [record.contentType],
      'content-length': ['${payload.length}'],
      ...headers,
    },
  );
}

final class _FakeVideoPlatform extends VideoPlayerPlatform {
  final List<DataSource> sources = [];
  final List<StreamController<VideoEvent>> _streams = [];

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    sources.add(options.dataSource);
    final stream = StreamController<VideoEvent>();
    _streams.add(stream);
    stream.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 4),
        size: const Size(320, 180),
      ),
    );
    return _streams.length - 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _streams[playerId].stream;

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> dispose(int playerId) async {
    await _streams[playerId].close();
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      SizedBox(key: ValueKey('video-${options.playerId}'));
}

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Future<({int pumps, int elapsedMs})> _pumpUntilTextVisible(
  WidgetTester tester,
  String expectedText, {
  Duration step = const Duration(milliseconds: 16),
  int maxPumps = 50,
}) async {
  final watch = Stopwatch()..start();
  var pumps = 0;
  while (pumps < maxPumps) {
    if (find.textContaining(expectedText).evaluate().isNotEmpty) {
      watch.stop();
      return (pumps: pumps, elapsedMs: watch.elapsedMilliseconds);
    }
    await tester.pump(step);
    pumps++;
  }
  watch.stop();
  return (pumps: pumps, elapsedMs: watch.elapsedMilliseconds);
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('issue 55 cases a-e: videos never download before tap and text renders immediately', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final videoBytes = Uint8List(3 * 1024 * 1024); // 3 MiB synthetic mp4
    final gifBytes = _largeGifBytes(3 * 1024 * 1024); // 3 MiB valid GIF89a
    final clock = Stopwatch()..start();
    final logs = <_RequestRecord>[];

    final apiAdapter = FakeAdapter((request) {
      final path = request.uri.path;
      final isVideo =
          path.contains('demo.mp4') ||
          path.contains('demo.MP4') ||
          path.contains('/clip');
      final isGif = path.contains('anim.gif');
      final contentType = isVideo
          ? 'video/mp4'
          : isGif
          ? 'image/gif'
          : 'image/png';
      final record = _RequestRecord(
        timestampMs: clock.elapsedMilliseconds,
        client: 'api',
        method: request.method,
        uri: request.uri,
        contentType: contentType,
      );
      logs.add(record);
      return _trackedStreamResponse(
        record,
        isVideo
            ? videoBytes
            : isGif
            ? gifBytes
            : _png,
      );
    });
    final api = testApi(apiAdapter);
    addTearDown(api.close);

    final externalAdapter = FakeAdapter((request) {
      final path = request.uri.path;
      final isVideo =
          path.contains('ext.mp4') ||
          path.contains('ext.MP4') ||
          path.contains('/clip');
      final isGif = path.contains('ext.gif');
      final contentType = isVideo
          ? 'video/mp4'
          : isGif
          ? 'image/gif'
          : 'image/png';
      final record = _RequestRecord(
        timestampMs: clock.elapsedMilliseconds,
        client: 'ext',
        method: request.method,
        uri: request.uri,
        contentType: contentType,
      );
      logs.add(record);
      return _trackedStreamResponse(
        record,
        isVideo
            ? videoBytes
            : isGif
            ? gifBytes
            : _png,
      );
    });
    final externalDio = Dio()..httpClientAdapter = externalAdapter;
    addTearDown(externalDio.close);

    final web = fixture.account.instance.projectWeb(fixture.project.path);
    final base = Uri.parse('$web/-/blob/$_sha/README.md');

    Future<
      ({
        int pumps,
        int cards,
        int mediaImages,
        int attachmentImages,
        int renderedImages,
        List<_RequestRecord> records,
      })
    >
    runCase(String name, String markdown) async {
      logs.clear();
      clock
        ..reset()
        ..start();
      await tester.pumpWidget(
        _host(
          MarkdownView(
            'README_HEADER_$name\n\n$markdown\n\nREADME_FOOTER_$name',
            api: api,
            account: fixture.account,
            projectId: fixture.project.id,
            projectWeb: web,
            projectPath: fixture.project.path,
            base: base,
            externalMediaClient: externalDio,
          ),
        ),
      );
      final textAppearance = await _pumpUntilTextVisible(
        tester,
        'README_HEADER_$name',
      );
      await settleNetworkWidgets(tester);
      final cards = find.byType(MarkdownMediaCard).evaluate().length;
      final mediaImages = find.byType(MarkdownMediaImage).evaluate().length;
      final attachmentImages = find.byType(AttachmentImage).evaluate().length;
      final renderedImages = find.byType(Image).evaluate().length;
      final snapshot = List<_RequestRecord>.of(logs);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      return (
        pumps: textAppearance.pumps,
        cards: cards,
        mediaImages: mediaImages,
        attachmentImages: attachmentImages,
        renderedImages: renderedImages,
        records: snapshot,
      );
    }

    // (a) ![demo](demo.mp4) (repo-relative) and /uploads/<secret>/demo.mp4
    final caseA = await runCase(
      '1a_repo_and_upload_mp4',
      '![demo](demo.mp4)\n\n![upload](/uploads/$_secret/demo.mp4)',
    );
    expect(caseA.pumps, 0);
    expect(caseA.cards, 2);
    expect(caseA.mediaImages, 0);
    expect(caseA.attachmentImages, 0);
    expect(caseA.renderedImages, 0);
    expect(caseA.records, isEmpty);

    // (b) HTML <video src="demo.mp4" controls></video> and <img src="demo.mp4">
    final caseB = await runCase(
      '1b_html_video_and_img_mp4',
      '<video src="demo.mp4" controls></video>\n\n<img src="demo.mp4">',
    );
    expect(caseB.pumps, 0);
    expect(caseB.cards, 2);
    expect(caseB.mediaImages, 0);
    expect(caseB.attachmentImages, 0);
    expect(caseB.renderedImages, 0);
    expect(caseB.records, isEmpty);

    // (c) Extension-less video links served as video/mp4 and uppercase .MP4
    final caseC = await runCase(
      '1c_extensionless_upload_repo_ext_and_uppercase',
      '![u](/uploads/$_secret/clip)\n\n![r](clip)\n\n![e](https://cdn.example/clip)\n\n![up](demo.MP4)\n\n<img src="demo.MP4">',
    );
    expect(caseC.pumps, 0);
    expect(caseC.cards, 5);
    expect(caseC.mediaImages, 2);
    expect(caseC.attachmentImages, 1);
    expect(caseC.renderedImages, 0);
    // Uppercase .MP4 never fired a request; the 3 extension-less image links
    // aborted immediately upon inspecting Content-Type: video/mp4 with 0 body bytes read.
    expect(caseC.records, hasLength(3));
    for (final record in caseC.records) {
      expect(record.uri.path, contains('/clip'));
      expect(record.bytesRead, 0);
    }

    // (d) Large animated GIF (3 MiB) next to normal images
    final caseD = await runCase(
      '1d_large_gif_next_to_normal_images',
      '![gif](anim.gif)\n\n![p1](normal1.png)\n\n![p2](/uploads/$_secret/normal2.png)',
    );
    expect(caseD.pumps, 0);
    expect(caseD.cards, 0);
    expect(caseD.mediaImages, 2);
    expect(caseD.attachmentImages, 1);
    expect(caseD.renderedImages, 3);
    expect(caseD.records, hasLength(3));

    // (e) External https video and GIF
    final caseE = await runCase(
      '1e_external_https_video_and_gif',
      '![ev](https://cdn.example/ext.mp4)\n\n<video src="https://cdn.example/ext.mp4" controls></video>\n\n![eg](https://cdn.example/ext.gif)',
    );
    expect(caseE.pumps, 0);
    expect(caseE.cards, 2);
    expect(caseE.mediaImages, 1);
    expect(caseE.attachmentImages, 0);
    expect(caseE.renderedImages, 1);
    expect(caseE.records, hasLength(1));
    expect(caseE.records.single.uri.path, '/ext.gif');
  });

  testWidgets(
    'slow GIF shows placeholder while loading and never blocks README text or fast images in AttachmentBudget',
    (tester) async {
      final gifBytes = _largeGifBytes(3 * 1024 * 1024);
      final clock = Stopwatch()..start();
      final logs = <_RequestRecord>[];
      final slowGifGate = Completer<void>();

      final slowBudgetAdapter = FakeAdapter((request) async {
        final path = request.uri.path;
        final isSlowGif = path.contains('slow.gif');
        final record = _RequestRecord(
          timestampMs: clock.elapsedMilliseconds,
          client: 'ext',
          method: request.method,
          uri: request.uri,
          contentType: isSlowGif ? 'image/gif' : 'image/png',
        );
        logs.add(record);
        if (isSlowGif) await slowGifGate.future;
        return _trackedStreamResponse(record, isSlowGif ? gifBytes : _png);
      });
      final slowDio = Dio()..httpClientAdapter = slowBudgetAdapter;
      addTearDown(slowDio.close);

      await tester.pumpWidget(
        _host(
          MarkdownView(
            'README_SLOW_BUDGET\n\n'
            '![slow](https://cdn.example/slow.gif)\n\n'
            '![fast1](https://cdn.example/fast1.png)\n\n'
            '![fast2](https://cdn.example/fast2.png)',
            externalMediaClient: slowDio,
            budget: AttachmentBudget(maxConcurrent: 2),
          ),
        ),
      );

      // Text is visible on the very first frame (0 additional pumps).
      expect(find.textContaining('README_SLOW_BUDGET'), findsOneWidget);
      // Loading placeholders are shown while images are in flight.
      expect(find.bySemanticsLabel('附件載入中'), findsWidgets);

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      // Both fast1.png and fast2.png completed and rendered Image widgets while
      // slow.gif is still in flight and showing its loading placeholder.
      expect(logs, hasLength(3));
      expect(find.byType(Image), findsNWidgets(2));
      expect(find.bySemanticsLabel('附件載入中'), findsOneWidget);

      slowGifGate.complete();
      await settleNetworkWidgets(tester);
      expect(find.byType(Image), findsNWidgets(3));

      // Verify byte-budget cap on a large GIF: when maxTotalBytes is smaller than
      // the 3 MiB GIF, the GIF shows the size-limit fallback and does not prevent
      // a subsequent normal PNG from loading.
      final cappedDio = Dio()
        ..httpClientAdapter = FakeAdapter((request) {
          final isGif = request.uri.path.contains('ext.gif');
          final record = _RequestRecord(
            timestampMs: clock.elapsedMilliseconds,
            client: 'ext',
            method: request.method,
            uri: request.uri,
            contentType: isGif ? 'image/gif' : 'image/png',
          );
          return _trackedStreamResponse(
            record,
            isGif ? gifBytes : _png,
          );
        });
      addTearDown(cappedDio.close);
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '![gif](https://cdn.example/ext.gif)\n\n![ok](https://cdn.example/fast1.png)',
            externalMediaClient: cappedDio,
            budget: AttachmentBudget(maxTotalBytes: 512 * 1024),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.textContaining('媒體超過大小限制'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    },
  );

  testWidgets(
    'extension-less video handed off to MarkdownMediaCard downloads and plays only after tap',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final root = Directory.systemTemp.createTempSync('markdown-media-issue55-');
      final previousRoot = artifactStorageRoot;
      artifactStorageRoot = () async => root;
      resetMarkdownMediaStartup();
      final platform = _FakeVideoPlatform();
      final previousPlatform = VideoPlayerPlatform.instance;
      VideoPlayerPlatform.instance = platform;
      addTearDown(() {
        artifactStorageRoot = previousRoot;
        resetMarkdownMediaStartup();
        VideoPlayerPlatform.instance = previousPlatform;
        root.deleteSync(recursive: true);
      });

      final videoBytes = Uint8List.fromList([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70]);
      final records = <_RequestRecord>[];
      final apiAdapter = FakeAdapter((request) {
        final record = _RequestRecord(
          timestampMs: 0,
          client: 'api',
          method: request.method,
          uri: request.uri,
          contentType: 'video/mp4',
        );
        records.add(record);
        return _trackedStreamResponse(record, videoBytes);
      });
      final api = testApi(apiAdapter);
      addTearDown(api.close);
      final web = fixture.account.instance.projectWeb(fixture.project.path);

      await tester.pumpWidget(
        _host(
          MarkdownView(
            '![uploadClip](/uploads/$_secret/clip)',
            api: api,
            account: fixture.account,
            projectId: fixture.project.id,
            projectWeb: web,
            projectPath: fixture.project.path,
            base: Uri.parse('$web/-/blob/$_sha/README.md'),
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      // Before tap: 1 request fired, aborted on Content-Type with 0 body bytes read,
      // and rendered MarkdownMediaCard with no video player initialized.
      expect(find.byType(MarkdownMediaCard), findsOneWidget);
      expect(records, hasLength(1));
      expect(records.single.bytesRead, 0);
      expect(platform.sources, isEmpty);

      // Tap Play: now the video downloads to a staged file with .mp4 appended.
      await tester.tap(find.byTooltip('播放'));
      await settleNetworkWidgets(tester);
      expect(records, hasLength(2));
      expect(records.last.bytesRead, videoBytes.length);
      expect(platform.sources, hasLength(1));
      expect(platform.sources.single.uri, endsWith('/clip.mp4'));
    },
  );

  testWidgets(
    'RepositoryFilePage renders Markdown text immediately without waiting for video or slow image',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final slowImageGate = Completer<void>();
      addTearDown(() {
        if (!slowImageGate.isCompleted) slowImageGate.complete();
      });
      final videoRequests = <Uri>[];

      final adapter = FakeAdapter((request) async {
        final path = request.uri.path;
        if (request.method == 'HEAD') {
          return ResponseBody.fromString(
            '',
            200,
            headers: {
              'x-gitlab-size': ['128'],
              'x-gitlab-last-commit-id': [_sha],
            },
          );
        }
        if (path.endsWith('/README.md/raw')) {
          return ResponseBody.fromString(
            '# Project Title\n\n![demo](demo.mp4)\n\n![slow](slow.png)\n\nBody paragraph.',
            200,
          );
        }
        if (path.contains('demo.mp4')) {
          videoRequests.add(request.uri);
        }
        if (path.contains('slow.png')) {
          await slowImageGate.future;
          return ResponseBody.fromBytes(
            _png,
            200,
            headers: {
              'content-type': ['image/png'],
            },
          );
        }
        return ResponseBody.fromString('', 404);
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        MaterialApp(
          home: RepositoryFilePage(
            account: fixture.account,
            api: api,
            project: fixture.project,
            branch: 'main',
            sha: _sha,
            filePath: 'README.md',
          ),
        ),
      );
      await pumpUntil(
        tester,
        () => find.text('Project Title').evaluate().isNotEmpty,
        maxCycles: 5,
        description: 'RepositoryFilePage Markdown text visible while slow image is loading',
      );

      // Markdown text and tap-to-load video card are visible while slow.png is still loading!
      expect(find.text('Project Title'), findsOneWidget);
      expect(find.text('Body paragraph.'), findsOneWidget);
      expect(find.byType(MarkdownMediaCard), findsOneWidget);
      expect(find.bySemanticsLabel('附件載入中'), findsOneWidget);
      expect(videoRequests, isEmpty);

      slowImageGate.complete();
      await settleNetworkWidgets(tester);
      expect(videoRequests, isEmpty);
      expect(find.byType(Image), findsOneWidget);
    },
  );

  testWidgets(
    'crafted GIF and JPEG decompression bombs are rejected as tooLarge by both MarkdownMediaImage and AttachmentImage',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final web = fixture.account.instance.projectWeb(fixture.project.path);

      final zeroCanvasGif = _craftedGif(
        screenW: 0,
        screenH: 0,
        frameW: 5000,
        frameH: 5000,
      );
      final rstJpeg = _craftedJpegWithRst();
      expect(markdownRasterDimensions(zeroCanvasGif), isNull);
      expect(markdownRasterDimensions(rstJpeg), (16384, 16384));

      final cases = <({String name, String contentType, Uint8List bytes})>[
        (
          name: 'gif_1x1_canvas_6000x6000_frame.gif',
          contentType: 'image/gif',
          bytes: _craftedGif(
            screenW: 1,
            screenH: 1,
            frameW: 6000,
            frameH: 6000,
          ),
        ),
        (
          name: 'gif_frame_offset_9000_9000.gif',
          contentType: 'image/gif',
          bytes: _craftedGif(
            screenW: 1,
            screenH: 1,
            frameW: 1,
            frameH: 1,
            left: 9000,
            top: 9000,
          ),
        ),
        (
          name: 'gif_0x0_canvas_5000x5000_frame.gif',
          contentType: 'image/gif',
          bytes: zeroCanvasGif,
        ),
        (
          name: 'jpeg_rst_16384_sof_with_fake_1x1_com.jpg',
          contentType: 'image/jpeg',
          bytes: rstJpeg,
        ),
      ];

      final byName = {for (final entry in cases) entry.name: entry};
      final adapter = FakeAdapter((request) {
        final name = request.uri.pathSegments.last;
        final match = byName[name];
        if (match != null) {
          return ResponseBody.fromBytes(
            match.bytes,
            200,
            headers: {
              'content-type': [match.contentType],
            },
          );
        }
        return ResponseBody.fromString('', 404);
      });
      final api = testApi(adapter);
      addTearDown(api.close);
      final externalDio = Dio()..httpClientAdapter = adapter;
      addTearDown(externalDio.close);

      for (final entry in cases) {
        // 1. MarkdownMediaImage (external / repository path)
        await tester.pumpWidget(
          _host(
            MarkdownView(
              '![ext](https://cdn.example/${entry.name})',
              externalMediaClient: externalDio,
            ),
          ),
        );
        await settleNetworkWidgets(tester);
        expect(
          find.byType(Image),
          findsNothing,
          reason: 'MarkdownMediaImage must reject ${entry.name}',
        );
        expect(
          find.textContaining(l10n.markdownMediaTooLarge),
          findsOneWidget,
          reason: 'MarkdownMediaImage must report tooLarge for ${entry.name}',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();

        // 2. AttachmentImage (project upload path)
        await tester.pumpWidget(
          _host(
            MarkdownView(
              '![up](/uploads/$_secret/${entry.name})',
              api: api,
              account: fixture.account,
              projectId: fixture.project.id,
              projectWeb: web,
              base: web,
            ),
          ),
        );
        await settleNetworkWidgets(tester);
        expect(
          find.byType(Image),
          findsNothing,
          reason: 'AttachmentImage must reject ${entry.name}',
        );
        expect(
          find.text(l10n.imageExceedsPreviewLimit2),
          findsOneWidget,
          reason: 'AttachmentImage must report oversize for ${entry.name}',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    },
  );

  testWidgets(
    'AttachmentBudget charges first-come: a later fast small image wins the budget and an earlier slow large one shows size-limit state',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final web = fixture.account.instance.projectWeb(fixture.project.path);
      final slowGate = Completer<void>();
      addTearDown(() {
        if (!slowGate.isCompleted) slowGate.complete();
      });
      final largePng = _largeGifBytes(2048);

      final adapter = FakeAdapter((request) async {
        final isSlow = request.uri.path.endsWith('/early_large.gif');
        if (isSlow) {
          await slowGate.future;
          return ResponseBody.fromBytes(
            largePng,
            200,
            headers: {
              'content-type': ['image/gif'],
            },
          );
        }
        return ResponseBody.fromBytes(
          _png,
          200,
          headers: {
            'content-type': ['image/png'],
          },
        );
      });
      final api = testApi(adapter);
      addTearDown(api.close);

      final budget = AttachmentBudget(maxTotalBytes: largePng.length);
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '![early](/uploads/$_secret/early_large.gif)\n\n![late](/uploads/$_secret/late_small.png)',
            api: api,
            account: fixture.account,
            projectId: fixture.project.id,
            projectWeb: web,
            base: web,
            budget: budget,
          ),
        ),
      );
      await pumpUntil(
        tester,
        () => find.byType(Image).evaluate().length == 1,
        description: 'later small image finishes first and renders',
      );
      expect(budget.cachedBytes(const ProjectUploadRef(secret: _secret, filename: 'late_small.png')), isNotNull);

      slowGate.complete();
      await settleNetworkWidgets(tester);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text(l10n.exceedsSizeLimit), findsOneWidget);
    },
  );

  test(
    'GitLabApi rechecks _closed after onContentType throws in _send and _rawFileBytes',
    () async {
      for (final mode in ['projectUpload', 'rawFileBytes']) {
        late final GitLabApi api;
        final adapter = FakeAdapter(
          (_) => ResponseBody.fromBytes(
            _png,
            200,
            headers: {
              'content-type': ['video/mp4'],
            },
          ),
        );
        api = testApi(adapter);
        addTearDown(api.close);

        Future<Uint8List> call() => mode == 'projectUpload'
            ? api.projectUpload(
                42,
                _secret,
                'clip',
                onContentType: (_) {
                  api.close();
                  throw const MarkdownMediaNotImage('video/mp4');
                },
              )
            : api.rawFileBytes(
                '42',
                'clip',
                _sha,
                onContentType: (_) {
                  api.close();
                  throw const MarkdownMediaNotImage('video/mp4');
                },
              );

        await expectLater(
          call(),
          throwsA(
            isA<ApiFailure>().having(
              (failure) => failure.kind,
              'kind',
              FailureKind.cancelled,
            ),
          ),
        );
      }
    },
  );

  testWidgets(
    'content-type-detected video in demo and offlineSnapshot modes shows offline placeholder instead of media card',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final web = fixture.account.instance.projectWeb(fixture.project.path);
      final adapter = FakeAdapter(
        (_) => ResponseBody.fromBytes(
          Uint8List(0),
          200,
          headers: {
            'content-type': ['video/mp4'],
          },
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);

      for (final mode in [
        NetworkBoundaryMode.demo,
        NetworkBoundaryMode.offlineSnapshot,
      ]) {
        await tester.pumpWidget(
          NetworkBoundary(
            mode: mode,
            child: _host(
              MarkdownView(
                '![repoClip](clip)\n\n'
                '${mode == NetworkBoundaryMode.offlineSnapshot ? '![upClip](/uploads/$_secret/clip)' : ''}',
                api: api,
                account: fixture.account,
                projectId: fixture.project.id,
                projectWeb: web,
                base: Uri.parse('$web/-/blob/$_sha/README.md'),
              ),
            ),
          ),
        );
        await settleNetworkWidgets(tester);
        expect(find.byType(MarkdownMediaCard), findsNothing);
        expect(
          find.byKey(const ValueKey('snapshot-media-placeholder')),
          findsWidgets,
        );
        expect(
          find.text(
            mode == NetworkBoundaryMode.demo
                ? l10n.demoOffline
                : l10n.snapshotMediaOffline,
          ),
          findsWidgets,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    },
  );

  testWidgets(
    'upload handed off to MarkdownMediaCard from <img height="24"> sizes itself without overflow',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final web = fixture.account.instance.projectWeb(fixture.project.path);
      final adapter = FakeAdapter(
        (_) => ResponseBody.fromBytes(
          Uint8List(0),
          200,
          headers: {
            'content-type': ['video/mp4'],
          },
        ),
      );
      final api = testApi(adapter);
      addTearDown(api.close);

      await tester.pumpWidget(
        _host(
          MarkdownView(
            '<img src="/uploads/$_secret/clip" width="120" height="24">',
            api: api,
            account: fixture.account,
            projectId: fixture.project.id,
            projectWeb: web,
            base: web,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(MarkdownMediaCard), findsOneWidget);
      expect(tester.getSize(find.byType(MarkdownMediaCard)).height, greaterThan(24));
    },
  );
}
