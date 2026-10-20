import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:markdown/markdown.dart' as md;

import 'support/fake_adapter.dart';

Widget _host(String markdown) {
  final external = Dio()
    ..httpClientAdapter = FakeAdapter(
      (_) => ResponseBody.fromString(
        '<svg xmlns="http://www.w3.org/2000/svg"/>',
        200,
        headers: {
          'content-type': ['image/svg+xml'],
        },
      ),
    );
  return MaterialApp(
    home: Scaffold(body: MarkdownView(markdown, externalMediaClient: external)),
  );
}

Future<void> _pumpMarkdown(WidgetTester tester, String markdown) async {
  await tester.pumpWidget(_host(markdown));
  await tester.pumpAndSettle();
}

String _renderedText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((widget) => widget.text.toPlainText())
    .join('\n');

Future<void> _expectNoCodeBlock(WidgetTester tester, String markdown) async {
  final body = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
  final nodes = md.Document(
    blockSyntaxes: body.blockSyntaxes,
    inlineSyntaxes: body.inlineSyntaxes,
    extensionSet: body.extensionSet ?? md.ExtensionSet.gitHubFlavored,
    encodeHtml: false,
  ).parseLines(const LineSplitter().convert(body.data));
  bool hasCodeBlock(List<md.Node> values) => values.any(
    (node) =>
        node is md.Element &&
        (node.tag == 'pre' ||
            (node.children != null && hasCodeBlock(node.children!))),
  );
  expect(hasCodeBlock(nodes), isFalse, reason: markdown);
  expect(_renderedText(tester), isNot(contains('![](')), reason: markdown);
  expect(_renderedText(tester), isNot(contains('<img')), reason: markdown);
}

void main() {
  group('HTML candidate scanning', () {
    testWidgets('comments and prose comparisons do not hide later images', (
      tester,
    ) async {
      const cases = <String>[
        '<!-- Don\'t edit this file by hand -->\n'
            '<p align="center"><img src="logo.png" width="200"></p>',
        'Supports Python < 3.12. It\'s fast.\n\n'
            '<p align="center"><img src="logo.png"></p>',
        'Use a < b here.\n\n<img src="a.png" width="10">\n\n'
            '<img src="b.png">',
        '<img alt=\'unterminated\n\n<img src="tail.png">',
      ];
      for (var index = 0; index < cases.length; index++) {
        await _pumpMarkdown(tester, cases[index]);
        expect(
          find.byType(MarkdownMediaImage),
          findsNWidgets(index == 2 ? 2 : 1),
          reason: 'case $index',
        );
      }
    });
  });

  group('HTML block boundaries', () {
    testWidgets('indented centered badge becomes an image, not code', (
      tester,
    ) async {
      const source = '''
<p align="center">
    <a href="https://ci.example/x"><img src="https://img.shields.io/badge/a-b-green.svg"></a>
</p>
''';
      await _pumpMarkdown(tester, source);
      expect(find.byType(MarkdownMediaImage), findsOneWidget);
      await _expectNoCodeBlock(tester, source);
    });

    testWidgets('blank wrapper boundary leaves indented code unchanged', (
      tester,
    ) async {
      const source = '''
<p align="center">

    <img src="logo.png">
</p>
''';
      await _pumpMarkdown(tester, source);
      expect(find.byType(MarkdownMediaImage), findsNothing);
      expect(_renderedText(tester), contains('<img src="logo.png">'));
    });

    testWidgets('images escape surrounding block-level HTML', (tester) async {
      const cases = <String>[
        '<div align="center">\n<h1>Title</h1>\n'
            '<img src="logo.png">\n</div>',
        '<table><tr><td><img src="avatar.png"></td></tr></table>',
      ];
      for (final source in cases) {
        await _pumpMarkdown(tester, source);
        expect(find.byType(MarkdownMediaImage), findsOneWidget, reason: source);
        await _expectNoCodeBlock(tester, source);
      }
    });

    testWidgets('plain paragraph wrappers preserve paragraph boundaries', (
      tester,
    ) async {
      const source = '<p>first paragraph</p><p>second paragraph</p>';
      await _pumpMarkdown(tester, source);
      expect(find.byType(MarkdownMediaImage), findsNothing);
      expect(_renderedText(tester), isNot(contains('paragraph')));
    });
  });

  group('container code preservation', () {
    testWidgets('indented code keeps its HTML example unchanged', (
      tester,
    ) async {
      const source = 'Example:\n\n    <img src="x.png">\n';
      await _pumpMarkdown(tester, source);
      expect(find.byType(MarkdownMediaImage), findsNothing);
      expect(_renderedText(tester), contains('<img src="x.png">'));
    });

    testWidgets('blockquote and list fences keep media syntax unchanged', (
      tester,
    ) async {
      const source = '''
> ~~~html
> <img src="quote.png">
> [clip](quote.mp4)
> ~~~

- item

  ```html
  <img src="list.png">
  [clip](list.mp4)
  ```

- ```html
  <img src="marker-list.png">
  [clip](marker-list.mp4)
  ```
''';
      await _pumpMarkdown(tester, source);
      expect(find.byType(MarkdownMediaImage), findsNothing);
      expect(find.byType(MarkdownMediaCard), findsNothing);
      final rendered = _renderedText(tester);
      expect(rendered, contains('<img src="quote.png">'));
      expect(rendered, contains('[clip](quote.mp4)'));
      expect(rendered, contains('<img src="list.png">'));
      expect(rendered, contains('[clip](list.mp4)'));
      expect(rendered, contains('<img src="marker-list.png">'));
      expect(rendered, contains('[clip](marker-list.mp4)'));
    });

    testWidgets('blockquote and list indented code keeps HTML unchanged', (
      tester,
    ) async {
      const source = '''
> Example:
>
>     <img src="quote-code.png">

- Example:

      <img src="list-code.png">
''';
      await _pumpMarkdown(tester, source);
      expect(find.byType(MarkdownMediaImage), findsNothing);
      final rendered = _renderedText(tester);
      expect(rendered, contains('<img src="quote-code.png">'));
      expect(rendered, contains('<img src="list-code.png">'));
    });

    testWidgets('wrapper-looking code spans and comments do not expose code', (
      tester,
    ) async {
      const cases = <String>[
        'Use `<p>` here.\n\n    <img src="span-code.png">',
        '<!--\n<p align="center">\n-->\n\n'
            '    <img src="comment-code.png">',
      ];
      for (final source in cases) {
        await _pumpMarkdown(tester, source);
        expect(find.byType(MarkdownMediaImage), findsNothing);
        expect(_renderedText(tester), contains('<img src='));
      }
    });
  });

  group('media destinations', () {
    testWidgets('absolute HTML and Markdown media are wrapped once', (
      tester,
    ) async {
      const source = '''
<video src="https://cdn.example/demo.mp4" controls></video>
<audio src="https://cdn.example/a.mp3"></audio>
<video controls><source src="https://cdn.example/b.webm"></video>
![demo](<https://cdn.example/c.mp4>)
''';
      await _pumpMarkdown(tester, source);
      expect(find.byType(MarkdownMediaCard), findsNWidgets(4));
      expect(find.byType(MarkdownMediaImage), findsNothing);
    });

    testWidgets('reference media links resolve across fenced code', (
      tester,
    ) async {
      const source = '''
[Demo][clip]

```text
[clip]: not-this.mp4
```

[clip]: clip.mp4
''';
      await _pumpMarkdown(tester, source);
      expect(find.byType(MarkdownMediaCard), findsOneWidget);
      expect(_renderedText(tester), contains('[clip]: not-this.mp4'));
    });
  });
}
