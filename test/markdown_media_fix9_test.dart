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
  const inlineHtml = {
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
    'different run lengths':
        'v <script>``x`<img src="https://cdn.example/hidden.svg"></script> ` t',
    'invalid comment paired then outside':
        'v <!-- a -- `x` <img src="https://cdn.example/hidden.svg"> --> ` t',
  };
  for (final input in inlineHtml.entries) {
    testWidgets('FIX9 inline HTML image: ${input.key}', (tester) async {
      final images = RegExp(
        r'https://cdn\.example/[^" ]+\.svg',
      ).allMatches(input.value).map((match) => match[0]!).toList();
      await _expectMedia(
        tester,
        input.value,
        images: input.key == 'different run lengths' ? [] : images,
      );
    });
  }

  const media = {
    'V1 video fallback':
        'v <video src="https://cdn.example/v1.mp4">Use `mp4`</video> t',
    'V2 audio fallback':
        'v <audio src="https://cdn.example/v2.mp3">a `b` c</audio> t',
    'V3 video plain fallback':
        'v <video src="https://cdn.example/v3.mp4">fallback</video> t',
    'V4 video attribute':
        'v <video src="https://cdn.example/v4.mp4" title="`x`"></video> t',
    'V5 unclosed video with later code':
        'v <video src="https://cdn.example/v5.mp4"> then `code` t',
    'V6 line-start video fallback':
        '<video src="https://cdn.example/v6.mp4" controls>Your browser does not support `video`.</video>',
    'V7 line-start video attribute':
        '<video src="https://cdn.example/v7.mp4" title="`npm start` demo"></video>',
    'V8 multiline video block':
        '<video src="https://cdn.example/v8.mp4" controls>\nfallback `x`\n</video>\n',
    'V9 centered video block':
        '<p align="center"><video src="https://cdn.example/v9.mp4">`x`</video></p>\n',
  };
  for (final input in media.entries) {
    testWidgets('FIX9 renders one media card: ${input.key}', (tester) async {
      await _expectMedia(tester, input.value, cards: 1);
      if (input.key == 'V1 video fallback' ||
          input.key == 'V6 line-start video fallback') {
        final codes = _parse(input.value).single as md.Element;
        expect(
          codes.children!
              .whereType<md.Element>()
              .where((node) => node.tag == 'code')
              .single
              .textContent,
          input.key.startsWith('V1') ? 'mp4' : 'video',
        );
        expect(codes.textContent, contains('</video>'));
      }
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
        final withoutSrc = ['video', 'audio'].contains(tag)
            ? source.replaceFirst(' src="a.mp4"', '')
            : source;
        expect(
          _parse(withoutSrc).map(_ast),
          _parse(withoutSrc, media: false).map(_ast),
        );
        await _expectMedia(
          tester,
          source,
          cards: ['video', 'audio'].contains(tag) ? 1 : 0,
        );
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
