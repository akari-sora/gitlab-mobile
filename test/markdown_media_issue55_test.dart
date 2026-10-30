import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/shared/artifact_storage.dart';
import 'package:gitlab_mobile/shared/attachment_budget.dart';
import 'package:gitlab_mobile/shared/attachment_image.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
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

    Future<({int pumps, int cards, int renderedImages, List<_RequestRecord> records})>
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
      // ignore: avoid_print
      print(
        '=== CASE $name ===\n'
        'textAppeared: pumps=${textAppearance.pumps} elapsedMs=${textAppearance.elapsedMs} '
        'cards=$cards mediaImages=$mediaImages '
        'attachmentImages=$attachmentImages renderedImages=$renderedImages\n'
        'requests (${logs.length}):\n'
        '${logs.isEmpty ? '  (none)' : logs.map((r) => '  $r').join('\n')}',
      );
      final snapshot = List<_RequestRecord>.of(logs);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      return (
        pumps: textAppearance.pumps,
        cards: cards,
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
    expect(caseA.records, isEmpty);

    // (b) HTML <video src="demo.mp4" controls></video> and <img src="demo.mp4">
    final caseB = await runCase(
      '1b_html_video_and_img_mp4',
      '<video src="demo.mp4" controls></video>\n\n<img src="demo.mp4">',
    );
    expect(caseB.pumps, 0);
    expect(caseB.cards, 2);
    expect(caseB.records, isEmpty);

    // (c) Extension-less video links served as video/mp4 and uppercase .MP4
    final caseC = await runCase(
      '1c_extensionless_upload_repo_ext_and_uppercase',
      '![u](/uploads/$_secret/clip)\n\n![r](clip)\n\n![e](https://cdn.example/clip)\n\n![up](demo.MP4)\n\n<img src="demo.MP4">',
    );
    expect(caseC.pumps, 0);
    expect(caseC.cards, 5);
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
    expect(caseD.renderedImages, 3);
    expect(caseD.records, hasLength(3));

    // (e) External https video and GIF
    final caseE = await runCase(
      '1e_external_https_video_and_gif',
      '![ev](https://cdn.example/ext.mp4)\n\n<video src="https://cdn.example/ext.mp4" controls></video>\n\n![eg](https://cdn.example/ext.gif)',
    );
    expect(caseE.pumps, 0);
    expect(caseE.cards, 2);
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
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '![gif](https://cdn.example/ext.gif)\n\n![ok](https://cdn.example/fast1.png)',
            externalMediaClient: Dio()
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
              }),
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
}
