import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/shared/attachment_budget.dart';
import 'package:gitlab_mobile/shared/attachment_image.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'session_test.dart' show MemoryAccountStore, controllerFor;
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

const _secret = '0123456789abcdef0123456789abcdef';

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _PngUploads extends WorkspaceFixture {
  _PngUploads({this.bytes = const [], this.extraHeaders = const {}});
  final List<int> bytes;
  final Map<String, List<String>> extraHeaders;
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (request.method == 'GET' && request.uri.path.contains('/uploads/$_secret/')) {
      return ResponseBody.fromBytes(bytes, 200, headers: {
        'content-type': ['image/png'],
        ...extraHeaders,
      });
    }
    return super.respond(request);
  }
}

class _HeldUploads extends WorkspaceFixture {
  _HeldUploads(this.gate);
  final Completer<void> gate;
  var _passed = false;
  @override
  Future<ResponseBody> respond(RequestOptions request) async {
    if (request.method == 'GET' && request.uri.path.contains('/uploads/$_secret/')) {
      if (!_passed) {
        _passed = true;
        await gate.future;
      }
      return ResponseBody.fromBytes(_png, 200, headers: {'content-type': ['image/png']});
    }
    final next = super.respond(request);
    if (next is Future<ResponseBody>) return next;
    return next;
  }
}

int _uploads(WorkspaceFixture fixture) => fixture.adapter.requests
    .where((request) => request.uri.path.contains('/uploads/')).length;

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final byte in data) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      final mask = -(crc & 1);
      crc = (crc >> 1) ^ (0xEDB88320 & mask);
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Uint8List _chunk(List<int> typeAndData) {
  final length = typeAndData.length - 4;
  final crc = _crc32(typeAndData);
  return Uint8List.fromList([
    (length >> 24) & 0xff, (length >> 16) & 0xff, (length >> 8) & 0xff, length & 0xff,
    ...typeAndData,
    (crc >> 24) & 0xff, (crc >> 16) & 0xff, (crc >> 8) & 0xff, crc & 0xff,
  ]);
}

/// PNG whose IHDR claims [width]×[height] and whose body is only an empty zlib stream.
Uint8List _pngSized(int width, int height) {
  final ihdr = <int>[
    0x49, 0x48, 0x44, 0x52,
    (width >> 24) & 0xff, (width >> 16) & 0xff, (width >> 8) & 0xff, width & 0xff,
    (height >> 24) & 0xff, (height >> 16) & 0xff, (height >> 8) & 0xff, height & 0xff,
    8, 2, 0, 0, 0,
  ];
  final idat = <int>[
    0x49, 0x44, 0x41, 0x54,
    0x78, 0x01, 0x01, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01,
  ];
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ..._chunk(ihdr),
    ..._chunk(idat),
    ..._chunk([0x49, 0x45, 0x4E, 0x44]),
  ]);
}

Widget _scoped(SessionController session, Widget child) => ProviderScope(
  overrides: [sessionProvider.overrideWithValue(session)],
  child: _host(child),
);

Widget _host(Widget child) => MaterialApp(theme: appTheme(Brightness.light), home: Scaffold(
  body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child),
));

void _surface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 1200);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  test('projectUpload rejects a bad reference before requesting', () async {
    final adapter = FakeAdapter((_) => jsonResponse({}));
    final api = testApi(adapter);
    addTearDown(api.close);
    await expectLater(api.projectUpload(42, 'not-a-secret', 'shot.png'), throwsA(isA<ApiFailure>().having((error) => error.kind, 'kind', FailureKind.unsupported)));
    await expectLater(api.projectUpload(42, _secret, '..'), throwsA(isA<ApiFailure>().having((error) => error.kind, 'kind', FailureKind.unsupported)));
    expect(adapter.requests, isEmpty);
    await api.projectUpload(42, _secret, 'notes..png');
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.uri.path, endsWith('/notes..png'));
  });

  testWidgets('project upload renders an image with the token and opens the viewer', (tester) async {
    final fixture = _PngUploads(bytes: _png);
    addTearDown(fixture.api.close);
    _surface(tester);
    final web = fixture.account.instance.projectWeb(fixture.project.path);
    await tester.pumpWidget(_host(MarkdownView(
      '![shot](/uploads/$_secret/shot.png)',
      api: fixture.api, projectId: 42, projectWeb: web, base: web,
    )));
    await settleNetworkWidgets(tester);
    expect(find.byType(Image), findsOneWidget);
    final preview = tester.widget<Image>(find.byType(Image));
    expect(preview.image, isA<ResizeImage>());
    expect((preview.image as ResizeImage).width, inInclusiveRange(64, 2048));
    expect(find.byIcon(Icons.image_outlined), findsNothing);
    final request = fixture.adapter.requests.single;
    expect(request.method, 'GET');
    expect(request.headers['PRIVATE-TOKEN'], 'synthetic-test-token');
    expect(request.followRedirects, isFalse);
    expect(request.uri.path, '/gitlab/api/v4/projects/42/uploads/$_secret/shot.png');
    await tester.tap(find.byType(Image));
    await tester.pumpAndSettle();
    expect(find.text('在 GitLab 開啟'), findsOneWidget);
    expect(find.text('shot'), findsWidgets);
    final widths = [
      for (final image in tester.widgetList<Image>(find.byType(Image)))
        (image.image as ResizeImage).width,
    ];
    expect(widths, contains(2048));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a missing upload keeps the icon row and the failure title', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(MarkdownView(
      '![shot](/uploads/$_secret/shot.png)',
      api: fixture.api, projectId: fixture.project.id,
      projectWeb: fixture.account.instance.projectWeb(fixture.project.path),
    )));
    await settleNetworkWidgets(tester);
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.textContaining('無法開啟此資源'), findsOneWidget);
    expect(find.textContaining('shot'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an upload over the byte budget shows the size limit', (tester) async {
    final fixture = _PngUploads(bytes: const [1], extraHeaders: {
      Headers.contentLengthHeader: ['${8 * 1024 * 1024 + 1}'],
    });
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(MarkdownView(
      '![shot](/uploads/$_secret/shot.png)',
      api: fixture.api, projectId: 42,
      projectWeb: fixture.account.instance.projectWeb('studio/mobile-workspace'),
    )));
    await settleNetworkWidgets(tester);
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('超過大小上限'), findsOneWidget);
    expect(find.textContaining('無法載入附件（超過大小上限）'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an external image loads automatically without GitLab credentials', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    final external = FakeAdapter((_) => ResponseBody.fromBytes(_png, 200,
      headers: {'content-type': ['image/png']}));
    await tester.pumpWidget(_host(MarkdownView(
      '![remote](https://example.org/x.png)',
      externalMediaClient: Dio()..httpClientAdapter = external,
      api: fixture.api, projectId: 42,
      projectWeb: fixture.account.instance.projectWeb(fixture.project.path),
    )));
    await settleNetworkWidgets(tester);
    expect(find.byType(Image), findsOneWidget);
    expect(external.requests, hasLength(1));
    expect(external.requests.single.headers.containsKey('PRIVATE-TOKEN'), isFalse);
    expect(external.requests.single.headers.containsKey('Authorization'), isFalse);
    expect(fixture.adapter.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('malformed upload references show failure icons without requests or throws', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    final web = fixture.account.instance.projectWeb(fixture.project.path);
    final longName = 'a' * 5000;
    await tester.pumpWidget(_host(MarkdownView(
      '![ff](/uploads/$_secret/%FF.png)\n\n![pct](/uploads/$_secret/%)\n\n![long](/uploads/$_secret/$longName.png)',
      api: fixture.api, projectId: 42, projectWeb: web, base: web,
    )));
    await settleNetworkWidgets(tester);
    expect(find.byIcon(Icons.broken_image_outlined), findsNWidgets(3));
    expect(find.byType(Image), findsNothing);
    expect(fixture.adapter.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the same upload twice shares one request', (tester) async {
    final fixture = _PngUploads(bytes: _png);
    addTearDown(fixture.api.close);
    _surface(tester);
    final web = fixture.account.instance.projectWeb(fixture.project.path);
    await tester.pumpWidget(_host(MarkdownView(
      '![](/uploads/$_secret/shot.png)\n\n![again](/uploads/$_secret/shot.png)',
      api: fixture.api, projectId: 42, projectWeb: web, base: web,
    )));
    await settleNetworkWidgets(tester);
    expect(_uploads(fixture), 1);
    expect(find.byType(Image), findsNWidgets(2));
    final labels = tester.widgetList<Image>(find.byType(Image)).map((image) => image.semanticLabel).toList();
    expect(labels, containsAll(<String>['shot.png', 'again']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('images past maxImages stay icon rows and are not fetched', (tester) async {
    final fixture = _PngUploads(bytes: _png);
    addTearDown(fixture.api.close);
    _surface(tester);
    final web = fixture.account.instance.projectWeb(fixture.project.path);
    await tester.pumpWidget(_host(MarkdownView(
      '![a](/uploads/$_secret/a.png)\n\n![b](/uploads/$_secret/b.png)\n\n![c](/uploads/$_secret/c.png)',
      api: fixture.api, projectId: 42, projectWeb: web, base: web,
      budget: AttachmentBudget(maxImages: 2),
    )));
    await settleNetworkWidgets(tester);
    expect(find.text('附件超過本頁顯示上限'), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
    expect(fixture.adapter.requests.where((request) => request.uri.path.endsWith('/c.png')), isEmpty);
    expect(_uploads(fixture), 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a remounted preview keeps its slot and is not fetched again', (tester) async {
    // A collapsed thread removes its previews from the tree; reopening it must
    // not consume another slot nor another request for the same upload.
    final fixture = _PngUploads(bytes: _png);
    addTearDown(fixture.api.close);
    _surface(tester);
    final web = fixture.account.instance.projectWeb(fixture.project.path);
    final budget = AttachmentBudget(maxImages: 1);
    Widget view() => _host(MarkdownView(
      '![a](/uploads/$_secret/a.png)',
      api: fixture.api, projectId: 42, projectWeb: web, base: web, budget: budget,
    ));
    await tester.pumpWidget(view());
    await settleNetworkWidgets(tester);
    expect(find.byType(Image), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await tester.pumpWidget(_host(const SizedBox()));
      await tester.pump();
      await tester.pumpWidget(view());
      await settleNetworkWidgets(tester);
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('附件超過本頁顯示上限'), findsNothing);
    }
    expect(_uploads(fixture), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the image that crosses maxTotalBytes shows the size row', (tester) async {
    final fixture = _PngUploads(bytes: _png);
    addTearDown(fixture.api.close);
    _surface(tester);
    final web = fixture.account.instance.projectWeb(fixture.project.path);
    await tester.pumpWidget(_host(MarkdownView(
      '![a](/uploads/$_secret/a.png)\n\n![b](/uploads/$_secret/b.png)',
      api: fixture.api, projectId: 42, projectWeb: web, base: web,
      budget: AttachmentBudget(maxTotalBytes: _png.length),
    )));
    await settleNetworkWidgets(tester);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('超過大小上限'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a huge image is not decoded', (tester) async {
    final fixture = _PngUploads(bytes: _pngSized(6000, 6000));
    addTearDown(fixture.api.close);
    _surface(tester);
    final web = fixture.account.instance.projectWeb(fixture.project.path);
    await tester.pumpWidget(_host(MarkdownView(
      '![big](/uploads/$_secret/big.png)',
      api: fixture.api, projectId: 42, projectWeb: web, base: web,
    )));
    await settleNetworkWidgets(tester);
    expect(find.text('圖片尺寸超過預覽上限'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a second fetch waits for the in-flight slot', (tester) async {
    final gate = Completer<void>();
    final fixture = _HeldUploads(gate);
    addTearDown(fixture.api.close);
    addTearDown(() { if (!gate.isCompleted) gate.complete(); });
    _surface(tester);
    final web = fixture.account.instance.projectWeb(fixture.project.path);
    await tester.pumpWidget(_host(MarkdownView(
      '![a](/uploads/$_secret/a.png)\n\n![b](/uploads/$_secret/b.png)',
      api: fixture.api, projectId: 42, projectWeb: web, base: web,
      budget: AttachmentBudget(maxConcurrent: 1),
    )));
    await pumpUntil(
      tester,
      () => _uploads(fixture) >= 1 && find.bySemanticsLabel('附件載入中').evaluate().isNotEmpty,
      description: 'first upload in flight with spinner mounted',
    );
    expect(_uploads(fixture), 1);
    expect(find.bySemanticsLabel('附件載入中'), findsWidgets);
    gate.complete();
    await pumpUntil(
      tester,
      () => _uploads(fixture) >= 2 && find.byType(Image).evaluate().length == 2,
      description: 'second upload completed and both images rendered',
    );
    expect(_uploads(fixture), 2);
    expect(find.byType(Image), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed upload opens the notice and retry fetches again', (tester) async {
    final fixture = WorkspaceFixture();
    final session = controllerFor(MemoryAccountStore(), fixture.adapter);
    addTearDown(session.dispose);
    addTearDown(fixture.api.close);
    session.active = fixture.account;
    _surface(tester);
    final web = fixture.account.instance.projectWeb(fixture.project.path);
    await tester.pumpWidget(_scoped(session, MarkdownView(
      '![shot](/uploads/$_secret/shot.png)',
      api: fixture.api, projectId: fixture.project.id, projectWeb: web, base: web,
      projectPath: fixture.project.path,
    )));
    await settleNetworkWidgets(tester);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(_uploads(fixture), 1);
    await tester.tap(find.bySemanticsLabel('附件載入失敗，查看詳情'));
    await pumpUntil(
      tester,
      () => find.text('重新整理').hitTestable().evaluate().isNotEmpty,
      description: 'failure notice opened with hitTestable 重新整理 button',
    );
    expect(find.textContaining('@developer'), findsOneWidget);
    expect(find.textContaining('example.com'), findsOneWidget);
    expect(find.textContaining('studio/mobile-workspace/shot.png'), findsOneWidget);
    expect(find.text('切換帳號'), findsOneWidget);
    await tester.tap(find.text('重新整理'));
    await pumpUntil(
      tester,
      () => _uploads(fixture) >= 2,
      description: 'retry upload requested',
    );
    await settleNetworkWidgets(tester);
    expect(_uploads(fixture), 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('corrupt bytes show an undecodable row and do not open the viewer', (tester) async {
    final fixture = _PngUploads(bytes: Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8]));
    addTearDown(fixture.api.close);
    _surface(tester);
    final web = fixture.account.instance.projectWeb(fixture.project.path);
    await tester.pumpWidget(_host(MarkdownView(
      '![shot](/uploads/$_secret/shot.png)',
      api: fixture.api, projectId: 42, projectWeb: web, base: web,
      projectPath: fixture.project.path,
    )));
    await settleNetworkWidgets(tester);
    expect(find.text('無法解碼圖片'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.text('無法解碼圖片'));
    await pumpUntil(
      tester,
      () => find.text('切換帳號').evaluate().isNotEmpty,
      description: 'notice opened with 切換帳號',
    );
    expect(find.text('切換帳號'), findsOneWidget);
    expect(find.text('在 GitLab 開啟'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the viewer errorBuilder says the image cannot be decoded', (tester) async {
    _surface(tester);
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.light),
      home: AttachmentViewer(
        bytes: Uint8List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8]),
        title: 'broken.png',
        semanticLabel: 'broken.png',
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('無法解碼圖片'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a later small image that finishes first is charged first and an earlier large one shows the size limit', (tester) async {
    final slowGate = Completer<void>();
    addTearDown(() { if (!slowGate.isCompleted) slowGate.complete(); });
    final largePng = Uint8List.fromList([..._png, ...List.filled(200, 0)]);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final adapter = FakeAdapter((request) async {
      if (request.uri.path.endsWith('/early.png')) {
        await slowGate.future;
        return ResponseBody.fromBytes(largePng, 200, headers: {'content-type': ['image/png']});
      }
      return ResponseBody.fromBytes(_png, 200, headers: {'content-type': ['image/png']});
    });
    final api = testApi(adapter);
    addTearDown(api.close);
    _surface(tester);
    final web = fixture.account.instance.projectWeb(fixture.project.path);
    await tester.pumpWidget(_host(MarkdownView(
      '![early](/uploads/$_secret/early.png)\n\n![late](/uploads/$_secret/late.png)',
      api: api, projectId: 42, projectWeb: web, base: web,
      budget: AttachmentBudget(maxTotalBytes: largePng.length),
    )));
    await pumpUntil(
      tester,
      () => find.byType(Image).evaluate().length == 1,
      description: 'later small image rendered first',
    );
    expect(find.byType(Image), findsOneWidget);
    slowGate.complete();
    await settleNetworkWidgets(tester);
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('超過大小上限'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
