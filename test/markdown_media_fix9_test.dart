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
  expect(find.byType(MarkdownMediaImage), findsNWidgets(images.length));
  expect(find.byType(MarkdownMediaCard), findsNWidgets(cards));
}

void main() {
  const inert = {
    'N1 script paired':
        'v <script>`x`<img src="https://cdn.example/n1.svg"></script> t',
    'N2 script unmatched':
        'v <script>a ` b <img src="https://cdn.example/n2.svg"></script> t',
    'N3 textarea paired':
        'v <textarea>`x` <img src="https://cdn.example/n3.svg"></textarea> t',
    'N4 style paired':
        'v <style>`x` <img src="https://cdn.example/n4.svg"></style> t',
    'N5 title paired':
        'v <title>`x` <img src="https://cdn.example/n5.svg"></title> t',
    'N6 noscript paired':
        'v <noscript>`x` <img src="https://cdn.example/n6.svg"></noscript> t',
    'N8 invalid comment paired':
        'v <!-- a -- `x` <img src="https://cdn.example/n8.svg"> --> t',
    'N9 script in anchor':
        'v <a href="u"><script>`x`<img src="https://cdn.example/n9.svg"></script></a>',
    'N10 script backticks after image':
        'v <script><img src="https://cdn.example/n10.svg"> `x`</script> t',
    'V10 script attribute':
        'v <script data-x="`"><img src="https://cdn.example/v10.svg"></script> t',
    'attribute matching outside':
        'v <script data-x="`"><img src="https://cdn.example/hidden.svg"></script> ` t',
    'paired inside then outside':
        'v <script>`x`<img src="https://cdn.example/hidden.svg"></script> ` t',
    'different run lengths':
        'v <script>``x`<img src="https://cdn.example/hidden.svg"></script> ` t',
    'unmatched different run lengths':
        'v <script>``x<img src="https://cdn.example/hidden.svg"></script> ` t',
    'paired enclosing a shorter run':
        'v <script>``x ` y``<img src="https://cdn.example/hidden.svg"></script> ` t',
    'invalid comment paired then outside':
        'v <!-- a -- `x` <img src="https://cdn.example/hidden.svg"> --> ` t',
  };
  for (final input in inert.entries) {
    testWidgets('FIX9 inert zero requests: ${input.key}', (tester) async {
      await _expectMedia(tester, input.value);
    });
  }

  const media = {
    'V1 video fallback':
        'v <video src="https://cdn.example/v1.mp4">Use `mp4`</video> t',
    'V2 audio fallback':
        'v <audio src="https://cdn.example/v2.mp3">a `b` c</audio> t',
    'V4 video attribute':
        'v <video src="https://cdn.example/v4.mp4" title="`x`"></video> t',
    'V6 line-start video fallback':
        '<video src="https://cdn.example/v6.mp4" controls>Your browser does not support `video`.</video>',
    'V7 line-start video attribute':
        '<video src="https://cdn.example/v7.mp4" title="`npm start` demo"></video>',
    'unmatched fallback':
        'v <video src="https://cdn.example/v.mp4">Use `mp4</video> t',
    'attribute matching outside':
        'v <audio src="https://cdn.example/v.mp3" title="`"></audio> ` t',
    'paired inside then outside':
        'v <video src="https://cdn.example/v.mp4">`mp4`</video> ` t',
    'unmatched different run lengths':
        'v <video src="https://cdn.example/v.mp4">``mp4</video> ` t',
    'paired enclosing a shorter run':
        'v <audio src="https://cdn.example/v.mp3">``x ` y``</audio> ` t',
  };
  for (final input in media.entries) {
    testWidgets('FIX9 renders one media card: ${input.key}', (tester) async {
      await _expectMedia(tester, input.value, cards: 1);
    });
  }

  for (final tag in [
    'script',
    'style',
    'textarea',
    'title',
    'noscript',
    'video',
    'audio',
  ]) {
    for (final run in ['`', '``', '```']) {
      testWidgets('FIX9 crossing $tag run ${run.length} matches main', (
        tester,
      ) async {
        final source =
            'v <$tag src="a.mp4">${run}x</$tag><img src="https://cdn.example/hidden.svg">$run t';
        expect(
          _parse(source).map(_ast),
          _parse(source, media: false).map(_ast),
        );
        await _expectMedia(tester, source);
      });
    }
  }

  for (final run in ['`', '``', '```']) {
    testWidgets('FIX9 crossing comment run ${run.length} matches main', (
      tester,
    ) async {
      final source =
          'v <!-- a -- ${run}x --> <img src="https://cdn.example/hidden.svg">$run t';
      expect(_parse(source).map(_ast), _parse(source, media: false).map(_ast));
      await _expectMedia(tester, source);
    });
  }

  const bogus = {
    'B1 digit': '<!1 <img src="https://cdn.example/b1.svg">',
    'B2 dash': '<!-x <img src="https://cdn.example/b2.svg">',
    'B3 invalid end tag': '</ <img src="https://cdn.example/b3.svg">',
    'processing instruction': '<?x <img src="https://cdn.example/pi.svg">',
    'non-letter end tag': '</1 <img src="https://cdn.example/end.svg">',
  };
  for (final input in bogus.entries) {
    testWidgets('FIX9 bogus comment zero requests: ${input.key}', (
      tester,
    ) async {
      await _expectMedia(tester, '<div>\n${input.value}\n</div>');
    });
    testWidgets('FIX9 resumes after bogus comment: ${input.key}', (
      tester,
    ) async {
      await _expectMedia(
        tester,
        '<div>\n${input.value}<img src="https://cdn.example/visible.svg">\n</div>',
        images: ['https://cdn.example/visible.svg'],
      );
    });
  }

  for (final literal in ['<!>', '<?x>']) {
    testWidgets('FIX9 bogus comment ends at first >: $literal', (tester) async {
      await _expectMedia(
        tester,
        '<div>$literal<img src="https://cdn.example/visible.svg"> ?></div>',
        images: ['https://cdn.example/visible.svg'],
      );
    });
  }
}
