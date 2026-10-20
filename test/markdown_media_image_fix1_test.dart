import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/attachment_budget.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);
Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);
FakeAdapter _images() => FakeAdapter(
  (_) => ResponseBody.fromBytes(
    _png,
    200,
    headers: {
      'content-type': ['image/png'],
    },
  ),
);

void main() {
  testWidgets('fix3 remount three times preserves two-slot image budget', (
    tester,
  ) async {
    final adapter = _images();
    final client = Dio()..httpClientAdapter = adapter;
    final budget = AttachmentBudget(maxImages: 2);
    for (var mount = 0; mount < 3; mount++) {
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '![logo](https://images.example/logo.png)',
            budget: budget,
            externalMediaClient: client,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.byType(Image), findsOneWidget, reason: 'mount $mount');
      expect(adapter.requests, hasLength(1), reason: 'mount $mount');
      await tester.pumpWidget(const SizedBox());
    }
  });

  for (final width in [0.0, 0.5]) {
    testWidgets('fix3 image decode accepts layout width $width', (
      tester,
    ) async {
      final adapter = _images();
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: width,
            child: MarkdownView(
              '![tiny](https://images.example/tiny.png)',
              externalMediaClient: Dio()..httpClientAdapter = adapter,
            ),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Image), findsOneWidget);
    });
  }

  testWidgets('text revisions reuse loader cache and two image slots', (
    tester,
  ) async {
    final adapter = _images();
    final client = Dio()..httpClientAdapter = adapter;
    final budget = AttachmentBudget(maxImages: 2);
    for (var revision = 1; revision <= 3; revision++) {
      await tester.pumpWidget(
        _host(
          MarkdownView(
            'revision=$revision\n\n![same](https://images.example/logo.png)',
            budget: budget,
            externalMediaClient: client,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.byType(Image), findsOneWidget, reason: 'revision $revision');
      expect(
        adapter.requests,
        hasLength(1),
        reason: 'revision $revision must reuse bytes',
      );
    }
  });

  testWidgets('API, account and ref changes start isolated image loads', (
    tester,
  ) async {
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final firstAdapter = _images();
    final secondAdapter = _images();
    final firstApi = testApi(firstAdapter);
    final secondApi = testApi(secondAdapter);
    addTearDown(firstApi.close);
    addTearDown(secondApi.close);
    final budget = AttachmentBudget();
    final web = fixture.account.instance.projectWeb(fixture.project.path);
    Future<void> display({
      bool second = false,
      String ref = 'one',
      bool account = true,
    }) async {
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '![same](a.png)',
            api: second ? secondApi : firstApi,
            account: account ? fixture.account : null,
            projectId: 42,
            projectWeb: web,
            base: Uri.parse('$web/-/blob/$ref/README.md'),
            budget: budget,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.byType(Image), findsOneWidget);
    }

    await display();
    await display(ref: 'two');
    expect(firstAdapter.requests, hasLength(2));
    expect(firstAdapter.requests.last.uri.queryParameters['ref'], 'two');
    await display(second: true, ref: 'two');
    expect(secondAdapter.requests, hasLength(1));
    await display(second: true, ref: 'two', account: false);
    expect(secondAdapter.requests, hasLength(2));
  });

  testWidgets('exported SVGs render after comments declarations and styles', (
    tester,
  ) async {
    final adapter = FakeAdapter(
      (_) => ResponseBody.fromString(
        '<!-- Created with Inkscape -->\n<!DOCTYPE svg>\n<svg xmlns="http://www.w3.org/2000/svg" width="20" height="20"><style>.a{fill:red}</style><rect width="20" height="20"/></svg>',
        200,
        headers: {
          'content-type': ['image/svg+xml'],
        },
      ),
    );
    await tester.pumpWidget(
      _host(
        MarkdownView(
          '![export](https://images.example/export)',
          externalMediaClient: Dio()..httpClientAdapter = adapter,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('image spinner has a translated semantic label', (tester) async {
    final pending = Completer<ResponseBody>();
    final adapter = FakeAdapter((_) => pending.future);
    await tester.pumpWidget(
      _host(
        MarkdownView(
          '![pending](https://images.example/a.png)',
          externalMediaClient: Dio()..httpClientAdapter = adapter,
        ),
      ),
    );
    await tester.pump();
    final spinner = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(spinner.semanticsLabel, l10n.attachmentLoading);
    pending.complete(
      ResponseBody.fromBytes(
        _png,
        200,
        headers: {
          'content-type': ['image/png'],
        },
      ),
    );
    await settleNetworkWidgets(tester);
  });

  testWidgets('blocked sources do not consume slots or offer retry', (
    tester,
  ) async {
    final adapter = _images();
    await tester.pumpWidget(
      _host(
        MarkdownView(
          '![](http://images.example/no.png)\n\n![ok](https://images.example/yes.png)',
          budget: AttachmentBudget(maxImages: 1),
          externalMediaClient: Dio()..httpClientAdapter = adapter,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.byType(Image), findsOneWidget);
    expect(adapter.requests, hasLength(1));
    expect(find.byType(TextButton), findsNothing);
    expect(find.textContaining(' · '), findsNothing);
    expect(find.byTooltip(l10n.markdownMediaBlocked), findsOneWidget);
  });

  testWidgets('image count has its own translated non-retry message', (
    tester,
  ) async {
    final adapter = _images();
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
    expect(find.text(l10n.attachmentExceedsDisplayLimit), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
  });

  testWidgets(
    'repository 404 retains account and full coordinates in recovery sheet',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final adapter = FakeAdapter(
        (_) => jsonResponse({'message': '404'}, status: 404),
      );
      final api = testApi(adapter);
      addTearDown(api.close);
      final web = fixture.account.instance.projectWeb(fixture.project.path);
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '![secret](docs/missing.png)',
            api: api,
            account: fixture.account,
            projectId: 42,
            projectWeb: web,
            base: Uri.parse('$web/-/blob/fixed/README.md'),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      await tester.tap(find.byType(TextButton).first);
      await settleNetworkWidgets(tester);
      expect(find.byType(FailureNotice), findsOneWidget);
      final notice = tester.widget<FailureNotice>(find.byType(FailureNotice));
      expect(notice.error.kind, FailureKind.invisible);
      expect(notice.account?.key, fixture.account.key);
      expect(notice.resourceLabel, contains('42'));
      expect(notice.resourceLabel, contains('fixed'));
      expect(notice.resourceLabel, contains('docs/missing.png'));
      expect(find.text(l10n.switchAccount), findsOneWidget);
      expect(find.text(l10n.refreshAction), findsOneWidget);
      expect(
        find.text(l10n.instanceKey(fixture.account.instance.key)),
        findsOneWidget,
      );
    },
  );

  testWidgets('raster decode dimensions follow layout width and device ratio', (
    tester,
  ) async {
    final adapter = _images();
    await tester.pumpWidget(
      _host(
        MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 2),
          child: SizedBox(
            width: 120,
            child: MarkdownView(
              '![small](https://images.example/a.png)',
              externalMediaClient: Dio()..httpClientAdapter = adapter,
            ),
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    final image = tester.widget<Image>(find.byType(Image));
    final resized = image.image as ResizeImage;
    expect(resized.width, 240);
    expect(resized.height, lessThanOrEqualTo(960));
    expect(resized.policy, ResizeImagePolicy.fit);
  });

  test(
    'stream errors use network message; SVG parse failures use decode message',
    () {
      expect(
        markdownMediaFailure(const SocketException('synthetic')),
        l10n.markdownMediaNetwork,
      );
      expect(
        markdownMediaFailure(const FormatException('synthetic')),
        l10n.cannotDecodeImage,
      );
      expect(
        markdownMediaFailure(const ApiFailure(FailureKind.invalidResponse)),
        l10n.cannotDecodeImage,
      );
    },
  );

  testWidgets(
    'image failure names are isolated in Arabic without empty separators',
    (tester) async {
      useLanguage(languageForTag('ar')!);
      addTearDown(() => useLanguage(sourceLanguage));
      final adapter = FakeAdapter(
        (_) => ResponseBody.fromString(
          'bad',
          200,
          headers: {
            'content-type': ['text/plain'],
          },
        ),
      );
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '![اسم](https://images.example/a.png)',
            externalMediaClient: Dio()..httpClientAdapter = adapter,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.textContaining(isolated('اسم')), findsOneWidget);
      expect(l10n.markdownMediaNotImage, 'هذه ليست صورة');
    },
  );
}
