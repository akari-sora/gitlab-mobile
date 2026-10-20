import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';

import 'support/fake_adapter.dart';

Widget _host(String markdown, Dio external) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: MarkdownView(markdown, externalMediaClient: external),
    ),
  ),
);

Dio _client() => Dio()
  ..httpClientAdapter = FakeAdapter(
    (_) => ResponseBody.fromString(
      '<svg xmlns="http://www.w3.org/2000/svg"/>',
      200,
      headers: {
        'content-type': ['image/svg+xml'],
      },
    ),
  );

String _renderedText(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((widget) => widget.text.toPlainText())
    .join('\n');

void main() {
  testWidgets('HTML image attributes render with dimensions', (tester) async {
    final client = _client();
    addTearDown(client.close);
    await tester.pumpWidget(
      _host(
        '<img alt="A &amp; B" src="docs/a b.png" width="320" height="180">\n'
        '<IMG SRC=a.png HEIGHT=40 />',
        client,
      ),
    );
    await tester.pump();
    final images = tester
        .widgetList<MarkdownMediaImage>(find.byType(MarkdownMediaImage))
        .toList();
    expect(images, hasLength(2));
    expect(images.first.alt, 'A & B');
    expect(images.first.width, 320);
    expect(images.first.height, 180);
    expect(images.last.height, 40);
  });

  testWidgets('layout wrappers and linked picture keep one clickable image', (
    tester,
  ) async {
    final client = _client();
    addTearDown(client.close);
    await tester.pumpWidget(
      _host(
        '<div><center><a href="guide.html"><picture>'
        '<source srcset="large.webp"><img src="small.png" alt="Small">'
        '</picture></a></center></div>',
        client,
      ),
    );
    await tester.pump();
    expect(find.byType(MarkdownMediaImage), findsOneWidget);
    expect(find.byType(GestureDetector), findsWidgets);
    final image = tester.widget<MarkdownMediaImage>(
      find.byType(MarkdownMediaImage),
    );
    expect(image.source.uri, Uri.parse('small.png'));
    expect(image.alt, 'Small');
  });

  testWidgets('unrelated inline HTML stays on the default parser path', (
    tester,
  ) async {
    final client = _client();
    addTearDown(client.close);
    const source = '<span>text</span> <a href="page.html">page</a>';
    await tester.pumpWidget(_host(source, client));
    await tester.pump();
    expect(find.byType(MarkdownMediaImage), findsNothing);
    expect(_renderedText(tester), contains(source));

    await tester.pumpWidget(
      _host('<img src="a.png" alt="&#999999999999;">', client),
    );
    await tester.pump();
    expect(find.byType(MarkdownMediaImage), findsOneWidget);
  });

  testWidgets('comments and scripts do not make HTML blocks media blocks', (
    tester,
  ) async {
    final client = _client();
    addTearDown(client.close);
    const sources = [
      '<div><!-- <img src="hidden.png"> -->visible</div>',
      '<script>const x = \'<img src="hidden.png">\';</script>',
    ];
    for (final source in sources) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MarkdownBody(data: source)),
        ),
      );
      await tester.pump();
      final baseline = _renderedText(tester);
      await tester.pumpWidget(_host(source, client));
      await tester.pump();
      expect(find.byType(MarkdownMediaImage), findsNothing);
      expect(_renderedText(tester), baseline);
    }
  });

  testWidgets('picture keeps reached image while inert children stay hidden', (
    tester,
  ) async {
    final client = _client();
    addTearDown(client.close);
    const source =
        '<picture><!-- <img src="hidden.png"> -->'
        '<script>"<img src=\'also-hidden.png\'>"</script>'
        '<img src="https://cdn.example/actual.png"></picture>';
    await tester.pumpWidget(_host(source, client));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownMediaImage), findsOneWidget);
    expect(
      (client.httpClientAdapter as FakeAdapter).requests.map(
        (request) => request.uri.toString(),
      ),
      ['https://cdn.example/actual.png'],
    );
  });

  testWidgets('HTML video and audio keep explicit media kinds', (tester) async {
    final client = _client();
    addTearDown(client.close);
    await tester.pumpWidget(
      _host(
        '<video title="Demo" src="demo.mp4"></video>\n'
        '<audio><source src="sound.ogg" type="audio/ogg"></audio>\n'
        '<audio src="api/tracks/7"></audio>',
        client,
      ),
    );
    await tester.pump();
    final cards = tester
        .widgetList<MarkdownMediaCard>(find.byType(MarkdownMediaCard))
        .toList();
    expect(cards, hasLength(3));
    expect(cards.map((card) => card.audio), [isFalse, isTrue, isTrue]);
    expect(cards.last.source.uri, Uri.parse('api/tracks/7'));
  });

  testWidgets('Markdown media links use parser-resolved destinations', (
    tester,
  ) async {
    final client = _client();
    addTearDown(client.close);
    const source = '''
[Movie](clip.MP4?download=1#preview) [song](<audio file.m4a> "old") [page](page.html) ![poster](poster.png)

[Clip][demo]

<https://cdn.example/audio.m4a?raw=1>

`[not media](inside.mp4)`

```text
[demo]: hidden.mp4
```

[demo]: https://cdn.example/demo.webm "Demo"
''';
    await tester.pumpWidget(_host(source, client));
    await tester.pump();
    final cards = tester
        .widgetList<MarkdownMediaCard>(find.byType(MarkdownMediaCard))
        .toList();
    expect(cards, hasLength(4));
    expect(
      cards.map((card) => card.source.uri.toString()),
      containsAll([
        'clip.MP4?download=1#preview',
        'audio%20file.m4a',
        'https://cdn.example/demo.webm',
        'https://cdn.example/audio.m4a?raw=1',
      ]),
    );
    expect(find.byType(MarkdownMediaImage), findsOneWidget);
    expect(_renderedText(tester), contains('[not media](inside.mp4)'));
  });

  testWidgets('outer media link around a Markdown image stays a link', (
    tester,
  ) async {
    final client = _client();
    addTearDown(client.close);
    await tester.pumpWidget(
      _host('[![poster](poster.png)](movie.mp4)', client),
    );
    await tester.pump();
    expect(find.byType(MarkdownMediaImage), findsOneWidget);
    expect(find.byType(MarkdownMediaCard), findsNothing);
  });

  testWidgets('fenced, indented and inline code remain byte-visible code', (
    tester,
  ) async {
    final client = _client();
    addTearDown(client.close);
    const source = '''
Before <img src="before.png">

```html
<img src="fenced.png">
[movie](fenced.mp4)
```

    <img src="indented.png">

`<img src="inline.png">` and ``[audio](inline.mp3)``

After <audio src="after.wav"></audio>
''';
    await tester.pumpWidget(_host(source, client));
    await tester.pump();
    expect(find.byType(MarkdownMediaImage), findsOneWidget);
    expect(find.byType(MarkdownMediaCard), findsOneWidget);
    final text = _renderedText(tester);
    expect(text, contains('<img src="fenced.png">'));
    expect(text, contains('[movie](fenced.mp4)'));
    expect(text, contains('<img src="indented.png">'));
    expect(text, contains('<img src="inline.png">'));
    expect(text, contains('[audio](inline.mp3)'));
  });

  testWidgets('claimed HTML blocks keep visible text and drop inert content', (
    tester,
  ) async {
    final client = _client();
    addTearDown(client.close);
    await tester.pumpWidget(
      _host(
        '<div><h2>Visible heading</h2><script>hidden()</script>'
        '<img src="logo.png"><p>Visible tail</p></div>',
        client,
      ),
    );
    await tester.pump();
    expect(find.byType(MarkdownMediaImage), findsOneWidget);
    final text = _renderedText(tester);
    expect(text, contains('Visible heading'));
    expect(text, contains('Visible tail'));
    expect(text, isNot(contains('hidden()')));
  });

  testWidgets('render cost grows near-linearly at the 65536 character cap', (
    tester,
  ) async {
    const mebibyte = 1024 * 1024;
    final hostile = <String>[
      '${List.filled(mebibyte ~/ 10, '<img ').join()}'
          '${List.filled(mebibyte ~/ 2, '[').join()}',
      List.filled(mebibyte ~/ 2, '[\n').join(),
      '${List.filled(20000, '<a href="x">').join()}'
          '<img src="image.png">'
          '${List.filled(20000, '</a>').join()}',
      List.filled(50000, '<img alt="unterminated>').join(),
      '${List.filled(mebibyte ~/ 10, '< not-a-tag ').join()}'
          '<img src="tail.png">',
      List.filled(mebibyte ~/ 4, '<!--').join(),
      List.filled(mebibyte ~/ 13, '<img src=a>').join(),
      List.filled(mebibyte ~/ 32, '<a href="x"><img src=a></a>').join(),
    ];

    String capped(String source, int length) =>
        source.length <= length ? source : source.substring(0, length);

    Future<Duration> render(String source) async {
      final client = _client();
      final stopwatch = Stopwatch()..start();
      await tester.pumpWidget(_host(source, client));
      await tester.pump();
      stopwatch.stop();
      client.close();
      return stopwatch.elapsed;
    }

    for (var index = 0; index < hostile.length; index++) {
      await render(capped(hostile[index], 1024));
      final half = await render(capped(hostile[index], 32768));
      final atLimit = await render(capped(hostile[index], 65536));
      expect(
        atLimit,
        lessThan(const Duration(seconds: 5)),
        reason: 'case $index',
      );
      expect(
        atLimit.inMicroseconds,
        lessThan(half.inMicroseconds * 3 + 750000),
        reason: 'case $index',
      );
    }
  });
}
