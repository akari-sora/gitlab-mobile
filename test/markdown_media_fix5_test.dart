import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:gitlab_mobile/shared/in_app_links.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_media_syntax.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:markdown/markdown.dart' as md;

import 'support/fake_adapter.dart';

({Dio client, FakeAdapter adapter}) _client() {
  final adapter = FakeAdapter(
    (_) => ResponseBody.fromString(
      '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">'
      '<rect width="40" height="40"/></svg>',
      200,
      headers: {
        'content-type': ['image/svg+xml'],
      },
    ),
  );
  return (client: Dio()..httpClientAdapter = adapter, adapter: adapter);
}

Widget _host(String markdown, Dio external, {List<Uri>? taps}) => InAppLinks(
  handler: (_, uri) async {
    taps?.add(uri);
    return true;
  },
  child: MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: MarkdownView(markdown, externalMediaClient: external),
      ),
    ),
  ),
);

List<md.Node> _parse(String source, {bool media = true}) => md.Document(
  blockSyntaxes: media ? [MarkdownMediaBlockSyntax()] : null,
  inlineSyntaxes: media
      ? [
          MarkdownMediaImageSyntax(),
          MarkdownMediaInlineSyntax(),
          MarkdownMediaAutolinkSyntax(),
          MarkdownLiteralLessThanSyntax(),
          MarkdownMediaLinkSyntax(),
        ]
      : null,
  extensionSet: md.ExtensionSet.gitHubFlavored,
  encodeHtml: false,
).parseLines(const LineSplitter().convert(source));

Iterable<md.Element> _elements(Iterable<md.Node> nodes) sync* {
  for (final node in nodes) {
    if (node case final md.Element element) {
      yield element;
      yield* _elements(element.children ?? const []);
    }
  }
}

String _renderedText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((widget) => widget.text.toPlainText())
    .join('\n');

TapGestureRecognizer? _tapRecognizer(InlineSpan span, String text) {
  if (span case final TextSpan value) {
    final recognizer = value.recognizer;
    if ((value.text ?? '').contains(text) &&
        recognizer is TapGestureRecognizer) {
      return recognizer;
    }
    for (final child in value.children ?? const <InlineSpan>[]) {
      final found = _tapRecognizer(child, text);
      if (found != null) return found;
    }
  }
  return null;
}

void main() {
  const anchors = {
    'Codex code span':
        'Read <a href="https://docs.example/"><img src="https://images.example/real.svg"> `<img src="https://images.example/code.svg">`</a> tail',
    'Codex escaped tag':
        r'Read <a href="https://docs.example/"><img src="https://images.example/real.svg"> \<img src="https://images.example/escaped.svg"></a> tail',
    'Opus M4':
        'x <a href="https://x.example"><img src="https://cdn.example/a.png"> **Join** `now`</a> tail',
    'Markdown links and reference':
        'x <a href="https://x.example"><img src="https://cdn.example/a.png"> *Join* [docs](https://docs.example) [ref][r]</a> tail\n\n[r]: https://ref.example',
  };
  for (final value in anchors.entries) {
    testWidgets('FIX5 inline anchor ${value.key}', (tester) async {
      final nodes = _parse(value.value);
      final elements = _elements(nodes).toList();
      final baseline = _elements(_parse(value.value, media: false)).toList();
      for (final tag in ['strong', 'em', 'code']) {
        expect(
          elements.where((e) => e.tag == tag).map((e) => e.textContent),
          baseline.where((e) => e.tag == tag).map((e) => e.textContent),
        );
      }
      expect(
        md.HtmlRenderer().render(nodes),
        md.HtmlRenderer().render(_parse(value.value, media: false)),
      );
      if (value.key == 'Markdown links and reference') {
        expect(
          elements.where((e) => e.tag == 'a').map((e) => e.attributes['href']),
          containsAll(['https://docs.example', 'https://ref.example']),
        );
      }
      final fixture = _client();
      addTearDown(fixture.client.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MarkdownBody(data: value.value)),
        ),
      );
      final baselineText = _renderedText(tester);
      await tester.pumpWidget(_host(value.value, fixture.client));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_renderedText(tester), baselineText);
      expect(find.byType(MarkdownMediaImage), findsNothing);
      expect(fixture.adapter.requests, isEmpty);
    });
  }

  final unclosed = <String, String>{
    for (final comment in [
      '<!-- broken',
      '<!-->',
      '<!--->',
      '<!-- complete -->',
    ])
      'Codex $comment':
          'Before $comment **bold** [docs](https://docs.example) after',
    'Opus short comment': 'a <!--> b **bold** [l](https://l.example)',
    'Opus comment':
        'Use <!-- to start a comment; see [docs](https://docs.example) and **bold**.',
    'Opus script':
        'Avoid inline <script> tags; see [CSP](https://csp.example) and `code`.',
    'Opus title':
        'Set the <title> element, then **save** [x](https://x.example).',
    'Opus textarea':
        'A <textarea> holds text; see ![i](https://cdn.example/i.png).',
    'Opus noscript': 'Add <noscript> fallback and [docs](https://d.example)',
    'style':
        'Avoid inline <style> tags; see [CSP](https://csp.example) and `code`.',
    for (final prefix in [
      '<!-- broken',
      '<!-->',
      '<!--->',
      '<script>',
      '<style>',
      '<title>',
      '<textarea>',
      '<noscript>',
    ])
      'combined $prefix':
          'Before $prefix **bold** `code` [docs](https://docs.example) ![i](https://cdn.example/i.png) after',
  };
  for (final value in unclosed.entries) {
    testWidgets('FIX5 Markdown after ${value.key}', (tester) async {
      final expected = _elements(_parse(value.value, media: false))
          .where((e) => ['strong', 'code', 'a', 'img'].contains(e.tag))
          .map((e) => [e.tag, e.textContent, e.attributes])
          .toList();
      final actual = _elements(_parse(value.value))
          .where((e) => ['strong', 'code', 'a', 'img'].contains(e.tag))
          .map((e) => [e.tag, e.textContent, e.attributes])
          .toList();
      expect(actual, expected, reason: value.value);
      final fixture = _client();
      addTearDown(fixture.client.close);
      final taps = <Uri>[];
      await tester.pumpWidget(_host(value.value, fixture.client, taps: taps));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final links = _elements(
        _parse(value.value, media: false),
      ).where((e) => e.tag == 'a');
      for (final link in links) {
        final recognizers = tester
            .widgetList<RichText>(find.byType(RichText))
            .map((w) => _tapRecognizer(w.text, link.textContent))
            .whereType<TapGestureRecognizer>();
        expect(recognizers, hasLength(1));
        recognizers.single.onTap!();
        await tester.pump();
        expect(taps.last, Uri.parse(link.attributes['href']!));
      }
      expect(
        fixture.adapter.requests,
        hasLength(expected.where((e) => e[0] == 'img').length),
      );
    });
  }

  test('FIX5 short comments terminate before following HTML media', () {
    for (final comment in ['<!-->', '<!--->']) {
      final source = 'Before $comment <img src="real.svg"> **bold**';
      final elements = _elements(_parse(source)).toList();
      expect(
        elements.where((e) => e.tag == markdownMediaElement),
        hasLength(1),
      );
      expect(
        elements.where((e) => e.tag == 'strong').single.textContent,
        'bold',
      );
    }
  });

  test('FIX5 less-than preserves hard line break', () {
    const source = 'a <  \nb **c**';
    expect(
      md.HtmlRenderer().render(_parse(source)),
      md.HtmlRenderer().render(_parse(source, media: false)),
    );
    expect(_elements(_parse(source)).map((e) => e.tag), contains('br'));
  });

  for (final source in [
    '<p>&#xD800; <img src="https://cdn.example/a.png"></p>',
    'x <a href="https://x.example"><img src="https://cdn.example/a.png" alt="&#xDC00;"></a>',
    '<p>&#55296; &#57343; <img src="https://cdn.example/a.png" alt="&#xDFFF;"></p>',
  ]) {
    testWidgets('FIX5 surrogate entity $source', (tester) async {
      final nodes = _parse(source);
      final media = _elements(
        nodes,
      ).where((e) => e.tag == markdownMediaElement);
      if (source.contains('alt="&#xDC00;"')) {
        expect(media.single.attributes['alt'], '\uFFFD');
      } else {
        expect(nodes.map((n) => n.textContent).join(), contains('\uFFFD'));
      }
      final fixture = _client();
      addTearDown(fixture.client.close);
      await tester.pumpWidget(_host(source, fixture.client));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      if (!source.contains('alt="&#xDC00;"')) {
        expect(_renderedText(tester), contains('\uFFFD'));
      }
    });
  }

  testWidgets('FIX5 converted block hides noscript markup', (tester) async {
    const source =
        '<div>\n<noscript><img src="https://cdn.example/hidden.svg"></noscript><img src="https://cdn.example/real.svg"></div>';
    final fixture = _client();
    addTearDown(fixture.client.close);
    await tester.pumpWidget(_host(source, fixture.client));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_renderedText(tester), isNot(contains('<img')));
    expect(fixture.adapter.requests.map((r) => r.uri.toString()), [
      'https://cdn.example/real.svg',
    ]);
  });

  for (final href in ['href="https://x.example"', 'href']) {
    testWidgets('FIX5 whitespace under $href creates no stray tap target', (
      tester,
    ) async {
      final source =
          '<p align="center">\n  <a $href>\n    <img src="https://cdn.example/a.svg">\n  </a>\n</p>';
      final links = _elements(_parse(source)).where((e) => e.tag == 'a');
      expect(links.where((e) => e.textContent.trim().isEmpty), isEmpty);
      final fixture = _client();
      addTearDown(fixture.client.close);
      await tester.pumpWidget(_host(source, fixture.client));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(MarkdownMediaImage), findsOneWidget);
    });
  }
}
