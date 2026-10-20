import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/attachment_budget.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_media_html.dart';
import 'package:gitlab_mobile/shared/markdown_media_source.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

final _pixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

final _tallPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAoAAAfQCAYAAAD7MM56AAABC0lEQVR42u3KsQ0AAAjAoP7/tL7gasLARlNzkSiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKoiiKovgpLrfhrNbBoKllAAAAAElFTkSuQmCC',
);

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Dio _imageClient([List<int>? bytes]) => Dio()
  ..httpClientAdapter = FakeAdapter(
    (_) => ResponseBody.fromBytes(
      bytes ?? _pixel,
      200,
      headers: {
        'content-type': ['image/png'],
      },
    ),
  );

String _renderedText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((widget) => widget.text.toPlainText())
    .join('\n');

final class _CodeCounter extends SyntaxHighlighter {
  var count = 0;

  @override
  TextSpan format(String source) {
    count++;
    return TextSpan(text: source);
  }
}

void main() {
  testWidgets('Argon 1 exact absolute media inputs render once', (
    tester,
  ) async {
    final client = _imageClient();
    addTearDown(client.close);
    const markdown = '''
<video src="https://cdn.example/clip.mp4"></video>
<audio src="https://cdn.example/clip.mp3"></audio>
![demo](<https://cdn.example/clip.mp4>)
<video controls><source src="https://example.com/gitlab/team/project/-/raw/main/demo.mp4" type="video/mp4"></video>
''';

    await tester.pumpWidget(
      _host(MarkdownView(markdown, externalMediaClient: client)),
    );
    await tester.pump();

    final cards = tester
        .widgetList<MarkdownMediaCard>(find.byType(MarkdownMediaCard))
        .toList();
    expect(cards, hasLength(4));
    expect(cards.map((card) => card.audio), [
      isFalse,
      isTrue,
      isFalse,
      isFalse,
    ]);
    expect(cards.map((card) => card.source.uri.toString()), [
      'https://cdn.example/clip.mp4',
      'https://cdn.example/clip.mp3',
      'https://cdn.example/clip.mp4',
      'https://example.com/gitlab/team/project/-/raw/main/demo.mp4',
    ]);
  });

  testWidgets('Argon 4 tall 10x2000 PNG decodes without upscaling', (
    tester,
  ) async {
    final client = _imageClient(_tallPng);
    addTearDown(client.close);
    await tester.pumpWidget(
      _host(
        MediaQuery(
          data: const MediaQueryData(devicePixelRatio: 2),
          child: SizedBox(
            width: 120,
            child: MarkdownView(
              '![tall](https://images.example/tall.png)',
              externalMediaClient: client,
            ),
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    final widget = tester.widget<Image>(find.byType(Image));
    expect(widget.image, isA<ResizeImage>());
    final resized = widget.image as ResizeImage;
    expect(resized.policy, ResizeImagePolicy.fit);
    final widthScale = (resized.width ?? 10) / 10;
    final heightScale = (resized.height ?? 2000) / 2000;
    expect(
      widthScale < heightScale ? widthScale : heightScale,
      lessThanOrEqualTo(1),
      reason: 'the fit decode box must not enlarge the 10x2000 source',
    );
  });

  for (final wrapper in ['p', 'div', 'center', 'picture']) {
    for (final media in ['img', 'video']) {
      testWidgets('Argon 6 four-space <$media> escapes <$wrapper> blocks', (
        tester,
      ) async {
        final client = _imageClient();
        addTearDown(client.close);
        final element = media == 'img'
            ? '<img src="logo.png" alt="Logo" width="120">'
            : '<video src="clip.mp4"></video>';
        final markdown =
            '''
<$wrapper>
    $element
</$wrapper>
''';
        await tester.pumpWidget(
          _host(MarkdownView(markdown, externalMediaClient: client)),
        );
        await tester.pump();
        expect(
          find.byType(media == 'img' ? MarkdownMediaImage : MarkdownMediaCard),
          findsOneWidget,
        );

        final highlighter = _CodeCounter();
        await tester.pumpWidget(
          _host(
            MarkdownBody(
              data: preprocessMarkdownMedia(markdown),
              syntaxHighlighter: highlighter,
            ),
          ),
        );
        expect(highlighter.count, 0);
      });
    }
  }

  testWidgets('Argon 5 raw relative traversal probes stay blocked', (
    tester,
  ) async {
    final base = Uri.parse(
      'https://example.com/gitlab/team/project/-/blob/main/docs/README.md',
    );
    final projectWeb = Uri.parse('https://example.com/gitlab/team/project');
    final repositoryAdapter = FakeAdapter(
      (_) => ResponseBody.fromBytes(_pixel, 200),
    );
    final api = testApi(repositoryAdapter);
    final externalAdapter = FakeAdapter(
      (_) => ResponseBody.fromBytes(_pixel, 200),
    );
    final external = Dio()..httpClientAdapter = externalAdapter;
    addTearDown(api.close);
    addTearDown(external.close);
    for (final value in [
      '/../secret.png',
      '/%2e%2e/secret.png',
      '///evil.example/a.png',
    ]) {
      await tester.pumpWidget(
        _host(
          MarkdownView(
            '![x]($value)',
            api: api,
            projectId: 42,
            projectWeb: projectWeb,
            base: base,
            externalMediaClient: external,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      final image = tester.widget<MarkdownMediaImage>(
        find.byType(MarkdownMediaImage),
      );
      expect(image.source.kind, MarkdownMediaSourceKind.blocked, reason: value);
    }
    expect(repositoryAdapter.requests, isEmpty);
    expect(externalAdapter.requests, isEmpty);
  });

  testWidgets('Argon 9 exact reference resolves across fenced code', (
    tester,
  ) async {
    final client = _imageClient();
    addTearDown(client.close);
    const markdown = '''
[Demo video][clip]

```sh
echo hello
```

[clip]: https://cdn.example/demo.webm
''';
    await tester.pumpWidget(
      _host(MarkdownView(markdown, externalMediaClient: client)),
    );
    await tester.pump();
    expect(find.byType(MarkdownMediaCard), findsOneWidget);
    expect(_renderedText(tester), contains('echo hello'));
  });

  testWidgets('Argon Minor 1 empty alt falls back to filename', (tester) async {
    final client = Dio()
      ..httpClientAdapter = FakeAdapter(
        (_) => ResponseBody.fromString('failed', 500),
      );
    addTearDown(client.close);
    await tester.pumpWidget(
      _host(
        MarkdownView(
          '![](https://images.example/test.png)',
          externalMediaClient: client,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    final label = tester.widget<Text>(
      find.descendant(of: find.byType(TextButton), matching: find.byType(Text)),
    );
    expect(label.data, contains('test.png'));
    expect(label.data, isNot(startsWith(' · ')));
  });

  testWidgets('Argon Minor 1 null alt and filename render no null separator', (
    tester,
  ) async {
    final client = Dio()
      ..httpClientAdapter = FakeAdapter(
        (_) => ResponseBody.fromString('failed', 500),
      );
    final loader = MarkdownMediaLoader(external: client);
    addTearDown(loader.close);
    await tester.pumpWidget(
      _host(
        MarkdownMediaImage(
          source: MarkdownMediaSource(
            kind: MarkdownMediaSourceKind.external,
            uri: Uri.parse('https://images.example'),
          ),
          loader: loader,
          budget: AttachmentBudget(),
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    final label = tester.widget<Text>(
      find.descendant(of: find.byType(TextButton), matching: find.byType(Text)),
    );
    expect(label.data, isNot(contains('null')));
    expect(label.data, isNot(startsWith(' · ')));
    expect(label.data, contains(l10n.markdownMediaRetry));
  });
}
