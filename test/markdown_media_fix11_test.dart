import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_media_syntax.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:markdown/markdown.dart' as md;

import 'support/fake_adapter.dart';

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

Object _ast(md.Node node) => switch (node) {
  md.Element() => [
    node.tag,
    node.attributes,
    node.children?.map(_ast).toList(),
  ],
  _ => node.textContent,
};

Future<void> _expectMedia(
  WidgetTester tester,
  String source, {
  List<String> images = const [],
  int cards = 0,
  int? imageWidgets,
}) async {
  final adapter = FakeAdapter(
    (_) => ResponseBody.fromString(
      '<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"/>',
      200,
      headers: {
        'content-type': ['image/svg+xml'],
      },
    ),
  );
  final client = Dio()..httpClientAdapter = adapter;
  addTearDown(client.close);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: MarkdownView(source, externalMediaClient: client),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  expect(adapter.requests.map((request) => request.uri.toString()), images);
  expect(
    find.byType(MarkdownMediaImage),
    findsNWidgets(imageWidgets ?? images.length),
  );
  expect(find.byType(MarkdownMediaCard), findsNWidgets(cards));
}

void main() {
  const swallowedTicks = {
    'Codex link title': '[label](path "`") ',
    'Codex link destination': '[label](path`x) ',
    'Codex autolink': '<http://a.example/`x>',
    'Opus email autolink': '<a`b@c.example>',
    'Opus GFM autolink': 'https://a.example/`x ',
    'Opus image title': '![label](path "`") ',
  };
  for (final input in swallowedTicks.entries) {
    for (final tag in [
      'script',
      'style',
      'textarea',
      'title',
      'noscript',
      'video',
      'audio',
      'invalid comment',
    ]) {
      final comment = tag == 'invalid comment';
      // Keep raw-tag report inputs verbatim. Src-less audio/video also proves
      // exact default-parser AST equality when the body contains a tick.
      final open = comment
          ? '<!-- a -- '
          : ['video', 'audio'].contains(tag)
          ? '<$tag>'
          : '<$tag src="a.mp4">';
      final close = comment ? ' -->' : '</$tag>';
      final source =
          'v $open${input.value}`$close'
          '<img src="https://cdn.example/hidden.svg">` t';
      testWidgets('FIX11 default AST and zero requests: ${input.key} / $tag', (
        tester,
      ) async {
        expect(
          _parse(source).map(_ast),
          _parse(source, media: false).map(_ast),
        );
        await _expectMedia(
          tester,
          source,
          imageWidgets: input.key == 'Opus image title' ? 1 : 0,
        );
      });
    }
  }

  for (final tag in ['video', 'audio']) {
    for (final input in swallowedTicks.entries) {
      testWidgets('FIX11 opening card and zero requests: $tag / ${input.key}', (
        tester,
      ) async {
        final source =
            'v <$tag src="a.mp4">${input.value}`</$tag>'
            '<img src="https://cdn.example/hidden.svg">` t';
        await _expectMedia(
          tester,
          source,
          cards: 1,
          imageWidgets: input.key == 'Opus image title' ? 1 : 0,
        );
      });
    }

    for (final body in [
      'Use `mp4` and **bold**',
      r'Use \`mp4 and **bold**',
      '<!-- ` --> **bold**',
      '<source title="`" src="fallback.mp4"> **bold**',
    ]) {
      testWidgets('FIX11 $tag with src leaves tick body to Markdown: $body', (
        tester,
      ) async {
        final nodes = _parse('v <$tag src="a.mp4">$body</$tag> t');
        final elements = _elements(nodes).toList();
        expect(
          elements.where((node) => node.tag == markdownMediaElement),
          hasLength(1),
        );
        expect(
          elements.where((node) => node.tag == 'strong').single.textContent,
          'bold',
        );
        expect(nodes.single.textContent, contains('</$tag>'));
        if (body.startsWith('Use `')) {
          expect(
            elements.where((node) => node.tag == 'code').single.textContent,
            'mp4',
          );
        }
        await _expectMedia(
          tester,
          'v <$tag src="a.mp4">$body</$tag> t',
          cards: 1,
        );
      });
      for (final src in ['', ' src=" "']) {
        testWidgets(
          'FIX11 $tag without usable src keeps default AST: $src / $body',
          (tester) async {
            final source =
                'v <$tag$src><source src="fallback.mp4">$body</$tag> t';
            expect(
              _parse(source).map(_ast),
              _parse(source, media: false).map(_ast),
            );
            await _expectMedia(tester, source);
          },
        );
      }
    }

    for (final src in ['', ' src="opening.mp4"']) {
      testWidgets('FIX11 $tag tick-free body consumes complete element: $src', (
        tester,
      ) async {
        final source =
            'v <$tag$src title="`attribute`">'
            '<source src="fallback.mp4">**fallback**</$tag> t';
        final nodes = _parse(source);
        final card = _elements(
          nodes,
        ).singleWhere((node) => node.tag == markdownMediaElement);
        expect(
          card.attributes['src'],
          src.isEmpty ? 'fallback.mp4' : 'opening.mp4',
        );
        expect(nodes.single.textContent, 'v  t');
        await _expectMedia(tester, source, cards: 1);
      });
    }
  }

  for (final tag in ['script', 'style', 'textarea', 'title', 'noscript']) {
    testWidgets('FIX11 inline $tag parses Markdown and reached images', (
      tester,
    ) async {
      final source =
          'v <$tag>**bold** `code` '
          '<img src="https://cdn.example/visible.svg"></$tag> t';
      final elements = _elements(_parse(source)).toList();
      expect(
        elements.where((node) => node.tag == 'strong').single.textContent,
        'bold',
      );
      expect(
        elements.where((node) => node.tag == 'code').single.textContent,
        'code',
      );
      await _expectMedia(
        tester,
        source,
        images: ['https://cdn.example/visible.svg'],
      );
    });
  }

  for (final comment in [
    '<!-- complete ` -->',
    '<!-- complete <img src="https://cdn.example/hidden.svg"> -->',
  ]) {
    testWidgets(
      'FIX11 complete comment keeps default AST and zero requests: $comment',
      (tester) async {
        final source = 'v $comment t';
        expect(
          _parse(source).map(_ast),
          _parse(source, media: false).map(_ast),
        );
        await _expectMedia(tester, source);
      },
    );
  }

  testWidgets(
    'FIX11 unclosed comment stays text and leaves Markdown reachable',
    (tester) async {
      const source = 'v <!-- unclosed **bold** `code` t';
      expect(_parse(source).map(_ast), _parse(source, media: false).map(_ast));
      await _expectMedia(tester, source);
    },
  );
}

Iterable<md.Element> _elements(Iterable<md.Node> nodes) sync* {
  for (final node in nodes.whereType<md.Element>()) {
    yield node;
    if (node.children != null) yield* _elements(node.children!);
  }
}
