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

List<md.Element> _media(String source) => _elements(
  _parse(source),
).where((element) => element.tag == markdownMediaElement).toList();

void main() {
  const reportInputs = {
    'Codex form-feed nested anchor': (
      source:
          'v <a href="outer">caption<a\fhref="inner">inner</a><img src="https://cdn.example/leak.svg"></a> tail',
      images: ['https://cdn.example/leak.svg'],
    ),
    'Codex form-feed closing anchor': (
      source:
          'v <a href="outer">caption</a\f> <img src="https://cdn.example/sibling.svg">',
      images: ['https://cdn.example/sibling.svg'],
    ),
    'Codex script closing text': (
      source:
          'v <a href="u">caption<script>"</a><img src="https://cdn.example/hidden.svg">"</script><img src="https://cdn.example/also-hidden.svg"></a>',
      images: [
        'https://cdn.example/hidden.svg',
        'https://cdn.example/also-hidden.svg',
      ],
    ),
    'Codex textarea closing text': (
      source:
          'v <a href="u">caption<textarea></a><img src="https://cdn.example/hidden.svg"></textarea><img src="https://cdn.example/also-hidden.svg"></a>',
      images: [
        'https://cdn.example/hidden.svg',
        'https://cdn.example/also-hidden.svg',
      ],
    ),
    'Codex script opening text': (
      source:
          'v <a href="u">caption<script>"<a>"</script></a> <img src="https://cdn.example/sibling.svg">',
      images: ['https://cdn.example/sibling.svg'],
    ),
    'Codex textarea opening text': (
      source:
          'v <a href="u">caption<textarea><a></textarea></a> <img src="https://cdn.example/sibling.svg">',
      images: ['https://cdn.example/sibling.svg'],
    ),
    'Opus D1': (
      source:
          'v <a href="u">text <b title="</a><img src="https://cdn.example/leak1.png">',
      images: ['https://cdn.example/leak1.png'],
    ),
    'Opus D2': (
      source:
          'v <a href="u">text <img src=y t="</a>"c=1> <img src="https://cdn.example/leak2.png"> tail</a>',
      images: ['https://cdn.example/leak2.png'],
    ),
    'Opus D3': (
      source:
          'v <a href="u">t <b x=< y="</a>"> <img src="https://cdn.example/leak3.png"></a>',
      images: ['https://cdn.example/leak3.png'],
    ),
    'Opus D4': (
      source:
          'v <a href="u">t <textarea></a></textarea> <img src="https://cdn.example/leak4.png"></a>',
      images: ['https://cdn.example/leak4.png'],
    ),
    'Opus D5 code span': (
      source:
          'v <a href="u">t `</a><img src="https://cdn.example/hidden.png">` <img src="https://cdn.example/leak5.png"></a>',
      images: ['https://cdn.example/leak5.png'],
    ),
  };

  for (final value in reportInputs.entries) {
    testWidgets('FIX7 report input: ${value.key}', (tester) async {
      final media = _media(value.value.source);
      expect(
        media.map((element) => element.attributes['src']),
        value.value.images,
      );
      expect(
        media.map((element) => element.attributes['href']),
        everyElement(isNull),
      );
      final fixture = _client();
      addTearDown(fixture.client.close);
      await tester.pumpWidget(_host(value.value.source, fixture.client));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        fixture.adapter.requests.map((request) => request.uri.toString()),
        value.value.images,
      );
    });
  }

  for (final value in const [
    (
      name: 'self-closing anchor',
      source:
          'v <a href="u">caption<a/></a> <img src="https://cdn.example/a.svg">',
    ),
    (
      name: 'self-closing picture',
      source: 'v <picture/> <img src="https://cdn.example/a.svg">',
    ),
    (
      name: 'self-closing anchor before apparent close',
      source:
          'v <a href="https://docs.example"/><img src="https://cdn.example/a.svg"></a>',
    ),
  ]) {
    test('FIX7 ${value.name} does not open a wrapper', () {
      final media = _media(value.source).single;
      expect(media.attributes['src'], 'https://cdn.example/a.svg');
      expect(media.attributes['href'], isNull);
    });
  }

  for (final value in const [
    (
      name: 'missing href',
      source: 'v <a><img src="https://cdn.example/a.svg"></a>',
    ),
    (
      name: 'empty href',
      source: 'v <a href=""><img src="https://cdn.example/a.svg"></a>',
    ),
  ]) {
    test('FIX7 ${value.name} drops the wrapper and keeps its image', () {
      final media = _media(value.source).single;
      expect(media.attributes['src'], 'https://cdn.example/a.svg');
      expect(media.attributes['href'], isNull);
      expect(
        _elements(_parse(value.source)).where((e) => e.tag == 'a'),
        isEmpty,
      );
    });
  }

  const badges = [
    (
      name: 'single',
      source:
          'v <a href="https://docs.example"><img src="https://cdn.example/one.svg"></a>',
      count: 1,
    ),
    (
      name: 'multiple with whitespace',
      source:
          'v <a href="https://docs.example">  <img src="https://cdn.example/one.svg"> \n <img src="https://cdn.example/two.svg">  </a>',
      count: 2,
    ),
    (
      name: 'br',
      source:
          'v <a href="https://docs.example"><img src="https://cdn.example/one.svg"><br /><img src="https://cdn.example/two.svg"></a>',
      count: 2,
    ),
    (
      name: 'case variants',
      source:
          'v <A HREF="https://docs.example"><IMG SRC="https://cdn.example/one.svg"><BR><img src="https://cdn.example/two.svg"></A>',
      count: 2,
    ),
    (
      name: 'closing whitespace',
      source:
          'v <a href="https://docs.example"><img src="https://cdn.example/one.svg"></a >',
      count: 1,
    ),
    (
      name: 'list item',
      source:
          '- <a href="https://docs.example"><img src="https://cdn.example/one.svg"></a>',
      count: 1,
    ),
    (
      name: 'table cell',
      source:
          '| badge |\n| --- |\n| <a href="https://docs.example"><img src="https://cdn.example/one.svg"></a> |',
      count: 1,
    ),
    (
      name: 'Markdown link label',
      source: '[<img src="https://cdn.example/one.svg">](https://docs.example)',
      count: 1,
    ),
  ];

  for (final value in badges) {
    testWidgets('FIX7 image-only badge: ${value.name}', (tester) async {
      final media = _media(value.source);
      expect(media, hasLength(value.count));
      expect(
        media.map((element) => element.attributes['href']),
        everyElement('https://docs.example'),
      );
      final fixture = _client();
      addTearDown(fixture.client.close);
      final taps = <Uri>[];
      await tester.pumpWidget(_host(value.source, fixture.client, taps: taps));
      await tester.pumpAndSettle();
      final images = find.byType(MarkdownMediaImage);
      expect(images, findsNWidgets(value.count));
      for (var index = 0; index < value.count; index++) {
        await tester.tap(images.at(index));
        await tester.pump();
      }
      expect(taps, List.filled(value.count, Uri.parse('https://docs.example')));
    });
  }

  const inert = {
    'code span': 'Before `<img src="https://cdn.example/code.svg">` after',
    'escaped tag': r'Before \<img src="https://cdn.example/escaped.svg"> after',
    'inline textarea':
        'Before <textarea>before <img src="https://cdn.example/ta.svg"> after</textarea> tail',
    'one-line textarea':
        '<textarea>before <img src="https://cdn.example/secret.svg"> after</textarea>',
    'block textarea':
        '<textarea>\n<img src="https://cdn.example/ta-block.svg">\n</textarea>',
    'inline script':
        'Before <script>const x=\'<img src="https://cdn.example/secret.svg">\';</script> after',
    'block script':
        '<script>\n<img src="https://cdn.example/script-block.svg">\n</script>',
    'inline style':
        'Before <style>.x{content:\'<img src="https://cdn.example/style.svg">\'}</style> after',
    'block style':
        '<style>\n<img src="https://cdn.example/style-block.svg">\n</style>',
    'inline title':
        'Before <title><img src="https://cdn.example/title.svg"></title> after',
    'block title':
        '<title>\n<img src="https://cdn.example/title-block.svg">\n</title>',
    'inline noscript':
        'Before <noscript><img src="https://cdn.example/no.svg"></noscript> after',
    'block noscript':
        '<noscript>\n<img src="https://cdn.example/no-block.svg">\n</noscript>',
    'inline comment':
        'Before <!-- <img src="https://cdn.example/comment.svg"> --> after',
    'block nested comment':
        '<div><!-- <img src="https://cdn.example/nested-comment.svg"> -->visible</div>',
    'picture code':
        '<picture>`<img src="https://cdn.example/code.svg">`</picture>',
    'picture escape':
        r'<picture>\<img src="https://cdn.example/escaped.svg"></picture>',
  };

  for (final value in inert.entries) {
    testWidgets('FIX7 HTML context: ${value.key}', (tester) async {
      final inline =
          value.key.startsWith('inline ') && value.key != 'inline comment';
      expect(
        _media(value.value),
        hasLength(inline ? 1 : 0),
        reason: value.value,
      );
      final fixture = _client();
      addTearDown(fixture.client.close);
      await tester.pumpWidget(_host(value.value, fixture.client));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownMediaImage), findsNWidgets(inline ? 1 : 0));
      expect(fixture.adapter.requests, hasLength(inline ? 1 : 0));
    });
  }

  const grammar = [
    (tag: '<img src=x>', valid: true, media: true),
    (tag: '<img\tsrc=x>', valid: true, media: true),
    (tag: '<img\nsrc=x>', valid: true, media: true),
    (tag: '<img\rsrc=x>', valid: true, media: true),
    (tag: '<img\fsrc=x>', valid: true, media: true),
    (tag: '<img\vsrc=x>', valid: true, media: true),
    (tag: '<img\u00A0src=x>', valid: true, media: true),
    (tag: '<img\u2028src=x>', valid: true, media: true),
    (tag: '<img src="a b">', valid: true, media: true),
    (tag: "<img src='a b'>", valid: true, media: true),
    (tag: '<img src=a"b>', valid: false, media: false),
    (tag: "<img src=a'b>", valid: false, media: false),
    (tag: '<img src=a=b>', valid: false, media: false),
    (tag: '<img src=a<b>', valid: false, media: false),
    (tag: '<img src=a`b>', valid: false, media: false),
    (tag: '<img src="unterminated>', valid: false, media: false),
    (tag: "<img src='unterminated>", valid: false, media: false),
    (tag: '<imgsrc=x>', valid: false, media: false),
    (tag: '<img 1src=x>', valid: false, media: false),
    (tag: '<img/src=x>', valid: false, media: false),
    (tag: '</a>', valid: true, media: false),
    (tag: '</a >', valid: true, media: false),
    (tag: '</a x>', valid: false, media: false),
    (tag: '</a/>', valid: false, media: false),
  ];

  for (final value in grammar) {
    test('FIX7 tag grammar parity: ${value.tag}', () {
      final packageMatch = md.InlineHtmlSyntax().pattern.matchAsPrefix(
        value.tag,
      );
      expect(packageMatch?.end == value.tag.length, value.valid);
      expect(_media('${value.tag} tail').isNotEmpty, value.media);
      if (value.valid && value.media) {
        expect(
          _media('${value.tag} tail').single.attributes['src'],
          isNotEmpty,
        );
      }
    });
  }

  test('FIX8 Unicode whitespace is accepted only by the inline grammar', () {
    const source = '<div><img\u00A0src="https://cdn.example/one.svg"></div>';
    expect(_media(source), isEmpty);
    expect(_media('v $source').map((element) => element.attributes['src']), [
      'https://cdn.example/one.svg',
    ]);
  });

  test('FIX7 block scanner stops invalid tag and reaches valid sibling', () {
    const source =
        '<div><img src=bad<value><img src="https://cdn.example/good.svg"></div>';
    expect(_media(source).map((element) => element.attributes['src']), [
      'https://cdn.example/good.svg',
    ]);
  });
}
