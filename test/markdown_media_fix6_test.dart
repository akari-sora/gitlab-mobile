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
  const rejected = {
    'badge then text': 'v <a href="u"><img src="real.svg">caption</a> tail',
    'text then badge': 'v <a href="u">caption<img src="real.svg"></a> tail',
    'text between badges':
        'v <a href="u"><img src="one.svg">and<img src="two.svg"></a>',
    'backtick': 'v <a href="u"><img src="real.svg">`</a>',
    'code': 'v <a href="u"><img src="real.svg">`<img src="code.svg">`</a>',
    'closing tag in code': 'v <a href="u">`<img src="code.svg"></a>` tail',
    'escape': r'v <a href="u"><img src="real.svg">\<img src="escape.svg"></a>',
    'entity': 'v <a href="u"><img src="real.svg">&amp;</a>',
    'comment': 'v <a href="u"><img src="real.svg"><!-- comment --></a>',
    'span': 'v <a href="u"><img src="real.svg"><span>hello</span></a>',
    'kbd': 'v <a href="u"><img src="real.svg"><kbd>K</kbd></a>',
    'sub bold': 'v <a href="u"><img src="real.svg"><sub><b>Name</b></sub></a>',
    'br caption': 'v <a href="u"><img src="real.svg"><br>Caption</a>',
    'nested anchor':
        'v <a href="outer"><img src="one.svg"> one <a href="inner">two</a> three<img src="two.svg"></a>',
    'nested badge anchor':
        'v <a href="outer"><a href="inner"><img src="inner.svg"></a><img src="outer.svg"></a>',
    'picture inside anchor':
        'v <a href="u"><picture><img src="real.svg"></picture></a>',
    'malformed closing attributes':
        'v <a href="u"><img src="one.svg"></a title="bad"><img src="two.svg"></a>',
    'malformed closing slash':
        'v <a href="u"><img src="one.svg"></a/><img src="two.svg"></a>',
    'missing image source': 'v <a href="u"><img><img src="real.svg"></a>',
    'empty image source': 'v <a href="u"><img src=""><img src="real.svg"></a>',
    'no href': 'v <a><img src="real.svg"></a>',
    'empty href': 'v <a href=""><img src="real.svg"></a>',
    'picture code':
        'Logo <picture><img src="real.png"> `<img src="code.png">`</picture> end',
    'picture escape':
        r'Logo <picture><img src="real.png"> \<img src="code.png"></picture> end',
    'picture text': 'v <picture><img src="real.svg">caption</picture>',
    'picture entity': 'v <picture><img src="real.svg">&amp;</picture>',
    'picture br': 'v <picture><img src="real.svg"><br></picture>',
    'picture comment': 'v <picture><!-- c --><img src="real.svg"></picture>',
    'picture other tag':
        'v <picture><span><img src="real.svg"></span></picture>',
    'nested picture':
        'v <picture><picture><img src="one.svg"></picture><img src="two.svg"></picture>',
    'Markdown inside rejected anchor':
        'v <a href="u"><img src="real.svg">**bold** `code` [docs](https://docs.example) [ref][r]</a> tail\n\n[r]: https://ref.example',
  };
  for (final value in rejected.entries) {
    testWidgets('FIX6 main parity: ${value.key}', (tester) async {
      final nodes = _parse(value.value);
      expect(
        md.HtmlRenderer().render(nodes),
        md.HtmlRenderer().render(_parse(value.value, media: false)),
        reason: value.value,
      );
      final fixture = _client();
      addTearDown(fixture.client.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MarkdownBody(data: value.value)),
        ),
      );
      final baseline = _renderedText(tester);
      final taps = <Uri>[];
      await tester.pumpWidget(_host(value.value, fixture.client, taps: taps));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(_renderedText(tester), baseline);
      expect(find.byType(MarkdownMediaImage), findsNothing);
      expect(fixture.adapter.requests, isEmpty);
      for (final link in _elements(nodes).where((e) => e.tag == 'a')) {
        final recognizer = tester
            .widgetList<RichText>(find.byType(RichText))
            .map((w) => _tapRecognizer(w.text, link.textContent))
            .whereType<TapGestureRecognizer>()
            .single;
        recognizer.onTap!();
        await tester.pump();
        expect(taps.last, Uri.parse(link.attributes['href']!));
      }
    });
  }

  for (final content in [
    '[^1] `<img src="code.svg">`',
    '<img src="real.svg">[^1]',
  ]) {
    test('FIX6 footnote count follows main: $content', () {
      final source =
          'Text <a href="https://x.example">$content</a> end\n\n[^1]: note';
      md.Document document(bool media) => md.Document(
        inlineSyntaxes: media ? [MarkdownMediaInlineSyntax()] : null,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        encodeHtml: false,
      );
      final actual = document(true);
      final baseline = document(false);
      final nodes = actual.parseLines(const LineSplitter().convert(source));
      final expected = baseline.parseLines(
        const LineSplitter().convert(source),
      );
      expect(actual.footnoteReferences, baseline.footnoteReferences);
      expect(actual.footnoteLabels, baseline.footnoteLabels);
      expect(actual.footnoteReferences, {'1': 1});
      expect(
        md.HtmlRenderer().render(nodes),
        md.HtmlRenderer().render(expected),
      );
      expect(md.HtmlRenderer().render(nodes), isNot(contains('fnref-1-2')));
    });
  }

  test('FIX6 rejected surrogate entity content keeps main AST', () {
    const source = 'x <a href="u"><img src="real.svg">&#xDC00;</a>';
    expect(
      md.HtmlRenderer().render(_parse(source)),
      md.HtmlRenderer().render(_parse(source, media: false)),
    );
  });

  for (final content in [
    '<img src="https://cdn.example/one.svg">',
    '  <img src="https://cdn.example/one.svg"> <br /> <img src="https://cdn.example/two.svg">  ',
    '<IMG SRC="https://cdn.example/one.svg"/><BR><img src="https://cdn.example/two.svg"/>',
  ]) {
    testWidgets('FIX6 image-only badge remains tappable: $content', (
      tester,
    ) async {
      final source =
          'v <a href="https://docs.example/?a=1&amp;b=2">$content</a> tail';
      final media = _elements(
        _parse(source),
      ).where((e) => e.tag == markdownMediaElement).toList();
      expect(media.length, content.contains('two.svg') ? 2 : 1);
      expect(
        media.map((e) => e.attributes['href']),
        everyElement('https://docs.example/?a=1&b=2'),
      );
      final fixture = _client();
      addTearDown(fixture.client.close);
      final taps = <Uri>[];
      await tester.pumpWidget(_host(source, fixture.client, taps: taps));
      await tester.pumpAndSettle();
      final images = find.byType(MarkdownMediaImage);
      expect(images, findsNWidgets(media.length));
      expect(fixture.adapter.requests, hasLength(media.length));
      for (var i = 0; i < media.length; i++) {
        await tester.tap(images.at(i));
        await tester.pump();
      }
      expect(
        taps,
        List.filled(media.length, Uri.parse('https://docs.example/?a=1&b=2')),
      );
    });
  }

  testWidgets('FIX6 picture uses fallback img and ignores source srcset', (
    tester,
  ) async {
    const source =
        'Logo <picture> <source src="https://cdn.example/unused.svg" srcset="other.svg 2x"> <img src="https://cdn.example/real.svg"> </picture> end';
    final fixture = _client();
    addTearDown(fixture.client.close);
    await tester.pumpWidget(_host(source, fixture.client));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownMediaImage), findsOneWidget);
    expect(fixture.adapter.requests.map((r) => r.uri.toString()), [
      'https://cdn.example/real.svg',
    ]);
  });

  for (final label in [
    '<img src="https://cdn.example/real.svg">',
    '![x](https://cdn.example/real.svg)',
  ]) {
    testWidgets('FIX6 Markdown image link stays tappable: $label', (
      tester,
    ) async {
      final source = 'v [$label](https://docs.example) tail';
      final fixture = _client();
      addTearDown(fixture.client.close);
      final taps = <Uri>[];
      await tester.pumpWidget(_host(source, fixture.client, taps: taps));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownMediaImage), findsOneWidget);
      await tester.tap(find.byType(MarkdownMediaImage));
      await tester.pump();
      expect(taps, [Uri.parse('https://docs.example')]);
    });
  }

  testWidgets('FIX6 rejection ends at its own close before a valid sibling', (
    tester,
  ) async {
    const source =
        'v <a href="outer"><a href="inner"><img src="hidden.svg"></a><img src="also-hidden.svg"></a> <picture><img src="https://cdn.example/real.svg"></picture>';
    final fixture = _client();
    addTearDown(fixture.client.close);
    await tester.pumpWidget(_host(source, fixture.client));
    await tester.pumpAndSettle();
    expect(fixture.adapter.requests.map((r) => r.uri.toString()), [
      'https://cdn.example/real.svg',
    ]);
  });

  test('FIX6 C1 K=40 does not multiply main Markdown parse cost', () {
    const prefix = 'v ';
    final anchors = r'<a>\<img src=x>' * 40;
    const closing = '</a>';
    final source =
        '$prefix$anchors${'**b** ' * ((65536 - prefix.length - anchors.length - closing.length) ~/ 6)}$closing';
    _parse('v **b**');
    final baselineWatch = Stopwatch()..start();
    final baseline = _parse(source, media: false);
    baselineWatch.stop();
    final watch = Stopwatch()..start();
    final actual = _parse(source);
    watch.stop();
    expect(
      md.HtmlRenderer().render(actual),
      md.HtmlRenderer().render(baseline),
    );
    debugPrint(
      'FIX6 C1 K=40 ${source.length} chars: main=${baselineWatch.elapsedMicroseconds}us fixed=${watch.elapsedMicroseconds}us',
    );
    expect(
      watch.elapsedMicroseconds,
      lessThan(baselineWatch.elapsedMicroseconds * 3 + 100000),
    );
  });
}
