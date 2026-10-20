import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  const formerlyRejected = {
    'badge then text': (
      source: 'v <a href="u"><img src="real.svg">caption</a> tail',
      images: ['real.svg'],
    ),
    'text then badge': (
      source: 'v <a href="u">caption<img src="real.svg"></a> tail',
      images: ['real.svg'],
    ),
    'text between badges': (
      source: 'v <a href="u"><img src="one.svg">and<img src="two.svg"></a>',
      images: ['one.svg', 'two.svg'],
    ),
    'backtick': (
      source: 'v <a href="u"><img src="real.svg">`</a>',
      images: ['real.svg'],
    ),
    'code': (
      source: 'v <a href="u"><img src="real.svg">`<img src="code.svg">`</a>',
      images: ['real.svg'],
    ),
    'closing tag in code': (
      source: 'v <a href="u">`<img src="code.svg"></a>` tail',
      images: <String>[],
    ),
    'escape': (
      source: r'v <a href="u"><img src="real.svg">\<img src="escape.svg"></a>',
      images: ['real.svg'],
    ),
    'entity': (
      source: 'v <a href="u"><img src="real.svg">&amp;</a>',
      images: ['real.svg'],
    ),
    'comment': (
      source: 'v <a href="u"><img src="real.svg"><!-- comment --></a>',
      images: ['real.svg'],
    ),
    'span': (
      source: 'v <a href="u"><img src="real.svg"><span>hello</span></a>',
      images: ['real.svg'],
    ),
    'kbd': (
      source: 'v <a href="u"><img src="real.svg"><kbd>K</kbd></a>',
      images: ['real.svg'],
    ),
    'sub bold': (
      source: 'v <a href="u"><img src="real.svg"><sub><b>Name</b></sub></a>',
      images: ['real.svg'],
    ),
    'br caption': (
      source: 'v <a href="u"><img src="real.svg"><br>Caption</a>',
      images: ['real.svg'],
    ),
    'nested anchor': (
      source:
          'v <a href="outer"><img src="one.svg"> one <a href="inner">two</a> three<img src="two.svg"></a>',
      images: ['one.svg', 'two.svg'],
    ),
    'nested badge anchor': (
      source:
          'v <a href="outer"><a href="inner"><img src="inner.svg"></a><img src="outer.svg"></a>',
      images: ['inner.svg', 'outer.svg'],
    ),
    'picture inside anchor': (
      source: 'v <a href="u"><picture><img src="real.svg"></picture></a>',
      images: ['real.svg'],
    ),
    'malformed closing attributes': (
      source:
          'v <a href="u"><img src="one.svg"></a title="bad"><img src="two.svg"></a>',
      images: ['one.svg', 'two.svg'],
    ),
    'malformed closing slash': (
      source: 'v <a href="u"><img src="one.svg"></a/><img src="two.svg"></a>',
      images: ['one.svg', 'two.svg'],
    ),
    'missing image source': (
      source: 'v <a href="u"><img><img src="real.svg"></a>',
      images: ['real.svg'],
    ),
    'empty image source': (
      source: 'v <a href="u"><img src=""><img src="real.svg"></a>',
      images: ['real.svg'],
    ),
    'no href': (source: 'v <a><img src="real.svg"></a>', images: ['real.svg']),
    'empty href': (
      source: 'v <a href=""><img src="real.svg"></a>',
      images: ['real.svg'],
    ),
    'picture code': (
      source:
          'Logo <picture><img src="real.png"> `<img src="code.png">`</picture> end',
      images: ['real.png'],
    ),
    'picture escape': (
      source:
          r'Logo <picture><img src="real.png"> \<img src="code.png"></picture> end',
      images: ['real.png'],
    ),
    'picture text': (
      source: 'v <picture><img src="real.svg">caption</picture>',
      images: ['real.svg'],
    ),
    'picture entity': (
      source: 'v <picture><img src="real.svg">&amp;</picture>',
      images: ['real.svg'],
    ),
    'picture br': (
      source: 'v <picture><img src="real.svg"><br></picture>',
      images: ['real.svg'],
    ),
    'picture comment': (
      source: 'v <picture><!-- c --><img src="real.svg"></picture>',
      images: ['real.svg'],
    ),
    'picture other tag': (
      source: 'v <picture><span><img src="real.svg"></span></picture>',
      images: ['real.svg'],
    ),
    'nested picture': (
      source:
          'v <picture><picture><img src="one.svg"></picture><img src="two.svg"></picture>',
      images: ['one.svg', 'two.svg'],
    ),
    'Markdown inside rejected anchor': (
      source:
          'v <a href="u"><img src="real.svg">**bold** `code` [docs](https://docs.example) [ref][r]</a> tail\n\n[r]: https://ref.example',
      images: ['real.svg'],
    ),
  };
  for (final value in formerlyRejected.entries) {
    testWidgets('FIX7 formerly rejected wrapper: ${value.key}', (tester) async {
      final media = _elements(
        _parse(value.value.source),
      ).where((element) => element.tag == markdownMediaElement).toList();
      expect(
        media.map((element) => element.attributes['src']),
        value.value.images,
        reason: value.value.source,
      );
      if (value.key != 'nested badge anchor') {
        expect(
          media.map((element) => element.attributes['href']),
          everyElement(isNull),
          reason: value.value.source,
        );
      }
      final fixture = _client();
      addTearDown(fixture.client.close);
      await tester.pumpWidget(_host(value.value.source, fixture.client));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(MarkdownMediaImage), findsNWidgets(media.length));
      expect(fixture.adapter.requests, isEmpty);
    });
  }

  test('FIX7 nested image badge keeps only its own anchor destination', () {
    const source =
        'v <a href="outer"><a href="inner"><img src="inner.svg"></a><img src="outer.svg"></a>';
    final media = _elements(
      _parse(source),
    ).where((element) => element.tag == markdownMediaElement).toList();
    expect(media.map((element) => element.attributes['src']), [
      'inner.svg',
      'outer.svg',
    ]);
    expect(media.map((element) => element.attributes['href']), ['inner', null]);
  });

  test('FIX7 rejected wrapper stays raw while Markdown children parse', () {
    const source =
        'v <a href="u"><img src="real.svg"> **bold** `code` [docs](https://docs.example)</a> tail';
    final nodes = _parse(source);
    final rendered = md.HtmlRenderer().render(nodes);
    final elements = _elements(nodes).toList();
    expect(rendered, contains('<a href="u">'));
    expect(rendered, contains('</a>'));
    expect(
      elements
          .where((element) => element.tag == markdownMediaElement)
          .single
          .attributes['href'],
      isNull,
    );
    expect(
      elements.where((element) => element.tag == 'strong').single.textContent,
      'bold',
    );
    expect(
      elements.where((element) => element.tag == 'code').single.textContent,
      'code',
    );
    expect(
      elements.where((element) => element.tag == 'a').single.attributes['href'],
      'https://docs.example',
    );
  });

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
      expect(_elements(nodes).where((e) => e.tag == 'sup').length, 1);
      expect(_elements(expected).where((e) => e.tag == 'sup').length, 1);
      expect(md.HtmlRenderer().render(nodes), isNot(contains('fnref-1-2')));
    });
  }

  test(
    'FIX7 formerly rejected surrogate entity keeps media and replacement',
    () {
      const source = 'x <a href="u"><img src="real.svg">&#xDC00;</a>';
      final nodes = _parse(source);
      expect(
        _elements(nodes)
            .where((element) => element.tag == markdownMediaElement)
            .single
            .attributes['src'],
        'real.svg',
      );
      expect(md.HtmlRenderer().render(nodes), isNot(contains('&#xDC00;')));
    },
  );

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

  testWidgets('FIX7 nested wrappers do not suppress parser-reached images', (
    tester,
  ) async {
    const source =
        'v <a href="outer"><a href="inner"><img src="hidden.svg"></a><img src="also-hidden.svg"></a> <picture><img src="https://cdn.example/real.svg"></picture>';
    final fixture = _client();
    addTearDown(fixture.client.close);
    await tester.pumpWidget(_host(source, fixture.client));
    await tester.pumpAndSettle();
    expect(
      _elements(_parse(source))
          .where((e) => e.tag == markdownMediaElement)
          .map((e) => e.attributes['src']),
      ['hidden.svg', 'also-hidden.svg', 'https://cdn.example/real.svg'],
    );
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
