import 'dart:convert';

import 'package:dio/dio.dart';
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

String _normalizedRenderedText(WidgetTester tester) => _renderedText(
  tester,
).replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'>\s+'), '>').trim();

void main() {
  for (final value
      in const <
        ({String name, String source, Set<String> tags, List<String> text})
      >[
        (
          name: 'prose links code and bold',
          source:
              'Requires Python < 3.12. See [docs](https://docs.example), '
              '`pip install x` and **bold**.',
          tags: {'a', 'code', 'strong'},
          text: ['Requires Python < 3.12. See docs, pip install x and bold.'],
        ),
        (
          name: 'list item code and link',
          source: '- Use x < 5 with `--flag` and [docs](https://d.example)',
          tags: {'li', 'code', 'a'},
          text: ['Use x < 5 with --flag and docs'],
        ),
        (
          name: 'soft line break',
          source:
              'Works when n < 10\n'
              'see [the docs](https://docs.example) for `limits`.',
          tags: {'a', 'code'},
          text: ['Works when n < 10\nsee the docs for limits.'],
        ),
        (
          name: 'image and link',
          source:
              'If a < b see ![x](https://cdn.example/a.png) and '
              '[l](https://l.example)',
          tags: {'img', 'a'},
          text: ['If a < b see ', ' and l'],
        ),
        (
          name: 'entity and escape',
          source: r'a < b &amp; c \*not\*',
          tags: {},
          text: ['a < b & c *not*'],
        ),
        (
          name: 'Codex combined input',
          source:
              'Python < 3.12 **bold** [docs](https://docs.example/) '
              '![logo](https://images.example/logo.svg)',
          tags: {'strong', 'a', 'img'},
          text: ['Python < 3.12 bold docs'],
        ),
      ]) {
    test('literal less-than keeps ${value.name}', () {
      final nodes = _parse(value.source);
      final tags = _elements(nodes).map((element) => element.tag).toSet();
      expect(tags, containsAll(value.tags), reason: value.source);
      final text = nodes.map((node) => node.textContent).join('\n');
      for (final expected in value.text) {
        expect(text, contains(expected), reason: value.source);
      }
    });
  }

  for (final value in const [
    (name: 'block video attribute', source: '<video src=""></video>'),
    (name: 'block audio valueless attribute', source: '<audio src>'),
    (
      name: 'block audio source child',
      source: '<audio><source src=""></audio>',
    ),
    (
      name: 'inline video attribute',
      source: 'Before <video src=""></video> after',
    ),
    (
      name: 'inline audio valueless attribute',
      source: 'Before <audio src>after</audio> tail',
    ),
    (
      name: 'inline audio source child',
      source: 'Before <audio><source src=""></audio> tail',
    ),
  ]) {
    testWidgets('empty ${value.name} never throws or loads', (tester) async {
      final fixture = _client();
      addTearDown(fixture.client.close);
      await tester.pumpWidget(_host(value.source, fixture.client));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: value.source);
      expect(
        find.byType(MarkdownMediaCard),
        findsNothing,
        reason: value.source,
      );
      expect(fixture.adapter.requests, isEmpty, reason: value.source);
    });
  }

  for (final value
      in const <({String name, String source, String destination})>[
        (
          name: 'block Markdown image badge',
          source:
              '[<img src="https://cdn.example/badge.png" alt="Get it" '
              'width="40" height="40">]'
              '(https://ci.example/md-label-alt)',
          destination: 'https://ci.example/md-label-alt',
        ),
        (
          name: 'inline Markdown image badge',
          source:
              'x [<img src="https://cdn.example/inline.png" alt="Get it">]'
              '(https://ci.example/md-label-inline) y',
          destination: 'https://ci.example/md-label-inline',
        ),
        (
          name: 'HTML image anchor',
          source:
              '<a href="https://ci.example/html-anchor">'
              '<img src="https://cdn.example/html.png"></a>',
          destination: 'https://ci.example/html-anchor',
        ),
      ]) {
    testWidgets('${value.name} opens its destination', (tester) async {
      final fixture = _client();
      addTearDown(fixture.client.close);
      final taps = <Uri>[];
      await tester.pumpWidget(_host(value.source, fixture.client, taps: taps));
      await tester.pumpAndSettle();
      expect(
        find.byType(MarkdownMediaImage),
        findsOneWidget,
        reason: value.source,
      );
      expect(find.byType(TextButton), findsNothing, reason: value.source);
      await tester.tap(find.byType(MarkdownMediaImage));
      await tester.pump();
      expect(taps, [Uri.parse(value.destination)], reason: value.source);
    });
  }

  for (final value in const [
    (
      name: 'Discord badge then text',
      source:
          '<a href="https://discord.example/x"><img src="https://cdn.example/d.svg" height="20"> Join our Discord</a>',
      count: 1,
      linked: false,
    ),
    (
      name: 'inline Flutter badge and text',
      source:
          'Made with <a href="https://f.example"><img src="https://cdn.example/f.svg" height="14"/>Flutter</a>.',
      count: 1,
      linked: false,
    ),
    (
      name: 'sponsor badge and company',
      source:
          'Sponsors: <a href="https://a.example"><img src="https://cdn.example/a.svg" width="16"> Acme Corp</a>, …',
      count: 1,
      linked: false,
    ),
    (
      name: 'guide text before badge',
      source:
          'See <a href="https://x.example">the guide <img src="https://cdn.example/x.svg"></a> now',
      count: 1,
      linked: false,
    ),
    (
      name: 'Codex prose around badge',
      source:
          'Read <a href="https://docs.example/">Docs <img src="https://images.example/logo.svg"> now</a> tail',
      count: 1,
      linked: false,
    ),
    (
      name: 'Codex two-image anchor',
      source:
          'Read <a href="https://docs.example/">Docs <img src="https://images.example/one.svg"> and <img src="https://images.example/two.svg"> now</a> tail',
      count: 2,
      linked: false,
    ),
  ]) {
    testWidgets('HTML anchor keeps reached images: ${value.name}', (
      tester,
    ) async {
      final media = _elements(
        _parse(value.source),
      ).where((element) => element.tag == markdownMediaElement).toList();
      expect(media, hasLength(value.count));
      expect(
        media.map((element) => element.attributes.containsKey('href')),
        everyElement(value.linked),
      );
      final fixture = _client();
      addTearDown(fixture.client.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownBody(
              data: value.source.replaceAll(RegExp(r'<img\b[^>]*>'), ''),
            ),
          ),
        ),
      );
      final baseline = _normalizedRenderedText(tester);
      await tester.pumpWidget(_host(value.source, fixture.client));
      await tester.pumpAndSettle();
      expect(_normalizedRenderedText(tester), baseline);
      expect(find.byType(MarkdownMediaImage), findsNWidgets(value.count));
      expect(fixture.adapter.requests, hasLength(value.count));
    });
  }

  testWidgets('mixed text and two images follow main without tap targets', (
    tester,
  ) async {
    const source =
        'Read <a href="https://docs.example/">Docs <img '
        'src="https://images.example/one.svg"> and <img '
        'src="https://images.example/two.svg"> now</a> tail';
    final fixture = _client();
    addTearDown(fixture.client.close);
    final taps = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownBody(
            data: source.replaceAll(RegExp(r'<img\b[^>]*>'), ''),
          ),
        ),
      ),
    );
    final baseline = _normalizedRenderedText(tester);
    await tester.pumpWidget(_host(source, fixture.client, taps: taps));
    await tester.pumpAndSettle();
    expect(_normalizedRenderedText(tester), baseline);
    expect(find.byType(MarkdownMediaImage), findsNWidgets(2));
    expect(fixture.adapter.requests, hasLength(2));
    expect(taps, isEmpty);
    expect(_elements(_parse(source)).where((e) => e.tag == 'a'), isEmpty);
  });

  for (final value in const [
    (
      name: 'inline textarea',
      source:
          'Before <textarea>before <img '
          'src="https://images.example/ta.svg"> after</textarea> tail',
    ),
    (
      name: 'Codex exact one-line block textarea',
      source:
          '<textarea>before <img '
          'src="https://images.example/secret.svg"> after</textarea>',
    ),
    (
      name: 'block textarea',
      source:
          '<textarea>\n<img src="https://images.example/ta-block.svg">\n'
          '</textarea>',
    ),
    (
      name: 'Codex exact inline script',
      source:
          'Before <script>const x=\'<img '
          'src="https://images.example/secret.svg">\';</script> after',
    ),
    (
      name: 'block script',
      source:
          '<script>\n<img src="https://images.example/script-block.svg">\n'
          '</script>',
    ),
    (
      name: 'inline style',
      source:
          'Before <style>.x{content:\'<img '
          'src="https://images.example/style.svg">\'}</style> after',
    ),
    (
      name: 'block style',
      source:
          '<style>\n<img src="https://images.example/style-block.svg">\n'
          '</style>',
    ),
    (
      name: 'inline title',
      source:
          'Before <title><img src="https://images.example/title.svg">'
          '</title> after',
    ),
    (
      name: 'block title',
      source:
          '<title>\n<img src="https://images.example/title-block.svg">\n'
          '</title>',
    ),
    (
      name: 'inline noscript',
      source:
          'Before <noscript><img src="https://images.example/no.svg">'
          '</noscript> after',
    ),
    (
      name: 'block noscript',
      source:
          '<noscript>\n<img src="https://images.example/no-block.svg">\n'
          '</noscript>',
    ),
    (
      name: 'inline comment',
      source:
          'Before <!-- <img src="https://images.example/comment.svg"> --> '
          'after',
    ),
    (
      name: 'block nested comment',
      source:
          '<div><!-- <img '
          'src="https://images.example/nested-comment.svg"> -->visible</div>',
    ),
  ]) {
    testWidgets('${value.name} follows HTML context', (tester) async {
      final fixture = _client();
      addTearDown(fixture.client.close);
      await tester.pumpWidget(_host(value.source, fixture.client));
      await tester.pumpAndSettle();
      final inline =
          value.source.startsWith('Before <') &&
          !value.source.startsWith('Before <!--');
      expect(
        find.byType(MarkdownMediaImage),
        findsNWidgets(inline ? 1 : 0),
        reason: value.source,
      );
      expect(
        fixture.adapter.requests,
        hasLength(inline ? 1 : 0),
        reason: value.source,
      );
    });
  }

  testWidgets('mixed HTML block loads only its real sibling image', (
    tester,
  ) async {
    final fixture = _client();
    addTearDown(fixture.client.close);
    const source = '''
<div>
<textarea><img src="https://images.example/textarea.svg"></textarea>
<script>const x = '<img src="https://images.example/script.svg">';</script>
<style>.x { content: '<img src="https://images.example/style.svg">'; }</style>
<title><img src="https://images.example/title.svg"></title>
<noscript><img src="https://images.example/noscript.svg"></noscript>
<!-- <img src="https://images.example/comment.svg"> -->
<img src="https://images.example/real.svg">
</div>
''';
    await tester.pumpWidget(_host(source, fixture.client));
    await tester.pumpAndSettle();
    final image = tester.widget<MarkdownMediaImage>(
      find.byType(MarkdownMediaImage),
    );
    expect(image.source.uri, Uri.parse('https://images.example/real.svg'));
    expect(fixture.adapter.requests.map((request) => request.uri), [
      Uri.parse('https://images.example/real.svg'),
    ]);
  });

  for (final value in const [
    (
      name: 'inline entity',
      source: '[clip](https://cdn.example/video.mp4?token=a&amp;download=1)',
    ),
    (name: 'inline escapes', source: r'[clip](foo\(bar\).mp4)'),
    (
      name: 'reference entity',
      source:
          '[clip][x]\n\n'
          '[x]: https://cdn.example/video.mp4?token=a&amp;download=1',
    ),
    (name: 'reference escapes', source: '[clip][x]\n\n[x]: foo\\(bar\\).mp4'),
  ]) {
    test('media link normalizes ${value.name} like LinkSyntax', () {
      final expected = _elements(
        _parse(value.source, media: false),
      ).singleWhere((element) => element.tag == 'a').attributes['href'];
      final actual = _elements(_parse(value.source))
          .singleWhere((element) => element.tag == markdownMediaElement)
          .attributes['src'];
      expect(actual, expected, reason: value.source);
    });
  }

  testWidgets('converted HTML blocks decode common named entities', (
    tester,
  ) async {
    final fixture = _client();
    addTearDown(fixture.client.close);
    const source =
        '<p><img src="badge.svg">'
        '&nbsp;&middot;&bull;&copy;&mdash;&ndash;&hellip;&laquo;&raquo; '
        '&quot;&apos;&amp;&lt;&gt;</p>';
    await tester.pumpWidget(_host(source, fixture.client));
    await tester.pumpAndSettle();
    expect(_renderedText(tester), contains('\u00a0·•©—–…«» "\'&<>'));
  });

  testWidgets('text links in converted HTML blocks remain tappable', (
    tester,
  ) async {
    final fixture = _client();
    addTearDown(fixture.client.close);
    final taps = <Uri>[];
    const source =
        '<p><a href="https://docs.example/guide">Docs</a></p>\n'
        '<img src="https://cdn.example/logo.svg">';
    await tester.pumpWidget(_host(source, fixture.client, taps: taps));
    await tester.pumpAndSettle();
    expect(find.text('Docs'), findsOneWidget);
    await tester.tap(find.text('Docs'));
    await tester.pump();
    expect(taps, [Uri.parse('https://docs.example/guide')]);
  });
}
