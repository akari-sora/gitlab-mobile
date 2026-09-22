import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/shared/theme.dart';
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
    if (request.method == 'GET' && request.uri.path.endsWith('/uploads/$_secret/shot.png')) {
      return ResponseBody.fromBytes(bytes, 200, headers: {
        'content-type': ['image/png'],
        ...extraHeaders,
      });
    }
    return super.respond(request);
  }
}

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

  testWidgets('an external image stays an icon and makes no request', (tester) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    _surface(tester);
    await tester.pumpWidget(_host(MarkdownView(
      '![remote](https://example.org/x.png)',
      api: fixture.api, projectId: 42,
      projectWeb: fixture.account.instance.projectWeb(fixture.project.path),
    )));
    await settleNetworkWidgets(tester);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.text('remote'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(fixture.adapter.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
