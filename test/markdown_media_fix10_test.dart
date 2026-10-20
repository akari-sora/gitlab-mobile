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

Future<void> _expectNoMedia(WidgetTester tester, String source) async {
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
  expect(adapter.requests.map((request) => request.uri.toString()), isEmpty);
  expect(find.byType(MarkdownMediaImage), findsNothing);
  expect(find.byType(MarkdownMediaCard), findsNothing);
}

void main() {
  final regions = {
    for (final tag in [
      'script',
      'style',
      'textarea',
      'title',
      'noscript',
      'video',
      'audio',
    ])
      tag: (open: '<$tag src="a.mp4">', close: '</$tag>'),
    'invalid comment': (open: '<!-- a -- ', close: ' -->'),
  };
  for (final region in regions.entries) {
    final source =
        'v ${region.value.open}\\`x `${region.value.close}'
        '<img src="https://cdn.example/hidden.svg">` t';
    test('FIX10 escaped opener AST: ${region.key}', () {
      expect(_parse(source).map(_ast), _parse(source, media: false).map(_ast));
    });
    testWidgets('FIX10 escaped opener zero requests: ${region.key}', (
      tester,
    ) async {
      await _expectNoMedia(tester, source);
    });
  }

  for (final variant in {
    'double quoted anchor': '<a title="`"></a>',
    'single quoted source': "<source title='`'>",
    'image attribute': '<img alt="`">',
    'odd backslashes': r'\\\`x ',
  }.entries) {
    for (final region in regions.entries) {
      testWidgets('FIX10 ${variant.key} crossing ${region.key}', (
        tester,
      ) async {
        final source =
            'v ${region.value.open}${variant.value}`${region.value.close}'
            '<img src="https://cdn.example/hidden.svg">` t';
        expect(
          _parse(source).map(_ast),
          _parse(source, media: false).map(_ast),
        );
        await _expectNoMedia(tester, source);
        for (final token in [
          '<a disabled data-id=demo title="`" />',
          "<source x:y = 'a`b' data.a-b_c=unquoted/>",
          '<a\u00a0title="`"\u3000>',
          '<!-- a ` b -->',
          '<?review ` ?>',
          '<!DOCTYPE `>',
          '<![CDATA[`]]>',
        ]) {
          final control =
              'v ${region.value.open}$token`${region.value.close}'
              '<img src="https://cdn.example/hidden.svg">` t';
          expect(
            _parse(control).map(_ast),
            _parse(control, media: false).map(_ast),
          );
          await _expectNoMedia(tester, control);
        }
        // The parser has consumed this link title before it reaches the
        // region. Its backtick must not pair with the region's real opener.
        final afterLink =
            'v [label](path "`") ${region.value.open}`${region.value.close}'
            '<img src="https://cdn.example/hidden.svg">` t';
        expect(
          _parse(afterLink).map(_ast),
          _parse(afterLink, media: false).map(_ast),
        );
        await _expectNoMedia(tester, afterLink);
        // Once code is open, even escaped or attribute-contained ticks close
        // it. Before code opens, an even backslash count leaves a real opener.
        for (final close in [r'\` t', '<a title="`"> t']) {
          final control =
              'v ${region.value.open}\\\\`x${region.value.close}'
              '<img src="https://cdn.example/hidden.svg">$close';
          expect(
            _parse(control).map(_ast),
            _parse(control, media: false).map(_ast),
          );
          await _expectNoMedia(tester, control);
        }
      });
    }
  }

  for (final variant in {
    'escaped': r'\`',
    'nested anchor': '<a title="`"></a>',
    'nested image': '<img alt="`">',
  }.entries) {
    for (final tag in ['script', 'style', 'textarea', 'title', 'noscript']) {
      testWidgets('FIX10 ${variant.key} stays inside $tag', (tester) async {
        await _expectNoMedia(
          tester,
          'v <$tag>${variant.value}<img src="https://cdn.example/hidden.svg">'
          '</$tag> then `code` t',
        );
        // Escaping the first tick of a longer run cannot open code at its
        // remaining tick (CodeSyntax rejects a preceding backtick).
        await _expectNoMedia(
          tester,
          'v <$tag>${r'\``'}<img src="https://cdn.example/hidden.svg">'
          '</$tag> then `code` t',
        );
      });
    }
  }

  test('FIX10 many escaped backticks grow linearly', () {
    String source(int count) =>
        'v <script>${r'\`x ' * count}`</script>'
        '<img src="https://cdn.example/hidden.svg">` t';
    List<md.Node> parse(int count) => _parse(source(count));
    // The old raw-run index consumes the real opener after an odd count.
    expect(parse(31).map(_ast), _parse(source(31), media: false).map(_ast));
    parse(255);
    var small = 1 << 62;
    var large = 1 << 62;
    for (var sample = 0; sample < 5; sample++) {
      for (final count in [4095, 16383]) {
        final watch = Stopwatch()..start();
        final nodes = parse(count);
        watch.stop();
        expect(nodes.map(_ast), _parse(source(count), media: false).map(_ast));
        if (count == 4095 && watch.elapsedMicroseconds < small) {
          small = watch.elapsedMicroseconds;
        }
        if (count == 16383 && watch.elapsedMicroseconds < large) {
          large = watch.elapsedMicroseconds;
        }
      }
    }
    // Same ratio bound as the existing parser growth regressions.
    debugPrint('FIX10 escaped backticks: N=${small}us 4N=${large}us');
    expect(large, lessThan(small * 12));
    expect(large, lessThan(2000000));
  });
}
