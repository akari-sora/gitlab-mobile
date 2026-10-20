import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';

import 'support/fake_adapter.dart';

Widget _host(String source, Dio external) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: MarkdownView(source, externalMediaClient: external),
    ),
  ),
);

void main() {
  testWidgets('parser ordering leaves every code context untouched', (
    tester,
  ) async {
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
    addTearDown(external.close);
    const source = '''
`<img src="https://images.example/span.svg">`

    <img src="https://images.example/indent.svg">

```html
<img src="https://images.example/fence.svg">
```

> ~~~html
> <img src="https://images.example/quote.svg">
> ~~~

- outer
  - inner
    ~~~html
    <img src="https://images.example/nested.svg">
    ~~~

Press <img src="https://images.example/key.svg" height="16"> to start.
''';

    await tester.pumpWidget(_host(source, external));
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownMediaImage), findsOneWidget);
    expect(
      tester
          .widget<MarkdownMediaImage>(find.byType(MarkdownMediaImage))
          .source
          .uri,
      Uri.parse('https://images.example/key.svg'),
    );
    expect((external.httpClientAdapter as FakeAdapter).requests, hasLength(1));
  });

  testWidgets('main baseline: list continuation HTML renders as media', (
    tester,
  ) async {
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
    addTearDown(external.close);
    const source = '''
1. Install:

    <img src="https://cdn.example/install.png">

2. Run

- Demo:

    <video src="https://cdn.example/demo.mp4"></video>
''';
    await tester.pumpWidget(_host(source, external));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownMediaImage), findsOneWidget);
    expect(find.byType(MarkdownMediaCard), findsOneWidget);
    final text = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((widget) => widget.text.toPlainText())
        .join('\n');
    expect(text, isNot(contains('<img')));
    expect(text, isNot(contains('<video')));
  });

  testWidgets('main baseline: heading badge row stays one inline paragraph', (
    tester,
  ) async {
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
    addTearDown(external.close);
    const source = '''
<h1 align="center">Project</h1>

<p align="center">
<a href="https://ci.example/1"><img src="https://img.shields.io/badge/a-1-green.svg"></a>
<a href="https://ci.example/2"><img src="https://img.shields.io/badge/b-2-blue.svg"></a>
<a href="https://ci.example/3"><img src="https://img.shields.io/badge/c-3-red.svg"></a>
</p>
''';
    await tester.pumpWidget(_host(source, external));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownMediaImage), findsNWidgets(3));
    final paragraphAncestors = find.ancestor(
      of: find.byType(MarkdownMediaImage),
      matching: find.byType(Wrap),
    );
    expect(tester.widgetList<Wrap>(paragraphAncestors).toSet(), hasLength(1));
  });

  testWidgets('main baseline: inline badge stays with surrounding prose', (
    tester,
  ) async {
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
    addTearDown(external.close);
    const source = '''
<h1 align="center">T</h1>

Press <img src="k.png" height="16"> to start.

Run `x`    <img src="a.png"> tail.
''';
    await tester.pumpWidget(_host(source, external));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownMediaImage), findsNWidgets(2));
    final paragraphAncestors = find.ancestor(
      of: find.byType(MarkdownMediaImage),
      matching: find.byType(Wrap),
    );
    expect(tester.widgetList<Wrap>(paragraphAncestors).toSet(), hasLength(2));
    final text = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((widget) => widget.text.toPlainText())
        .join('\n');
    expect(text, contains('Press '));
    expect(text, contains(' to start.'));
    expect(text, contains('Run x'));
    expect(text, contains(' tail.'));
  });

  testWidgets('malformed block wrappers do not leak parser context', (
    tester,
  ) async {
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
    addTearDown(external.close);
    const sources = [
      '<td><img src="one.svg">\n\nPress <img src="two.svg"> to start.',
      '<div><img src="one.svg">\n\n    <img src="code.svg">',
      '> <div align="center">\n>     <img src="quote.svg">\n> </div>',
      '<img alt="a<b" src="alt.svg">',
    ];
    for (var index = 0; index < sources.length; index++) {
      await tester.pumpWidget(_host(sources[index], external));
      await tester.pumpAndSettle();
      expect(
        find.byType(MarkdownMediaImage),
        findsNWidgets(switch (index) {
          0 => 2,
          1 => 1,
          _ => 1,
        }),
        reason: sources[index],
      );
    }
  });

  testWidgets('a wrapper close inside a fence remains code', (tester) async {
    final external = Dio()
      ..httpClientAdapter = FakeAdapter(
        (_) => ResponseBody.fromString('', 200),
      );
    addTearDown(external.close);
    const source = '''
<div>
visible

```html
<img src="should-stay-code.png">
</div>
```
''';
    await tester.pumpWidget(_host(source, external));
    await tester.pump();
    expect(find.byType(MarkdownMediaImage), findsNothing);
    final text = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((widget) => widget.text.toPlainText())
        .join('\n');
    expect(text, contains('<img src="should-stay-code.png">'));
  });

  testWidgets('reference definitions in code and comments stay inert', (
    tester,
  ) async {
    final external = Dio()
      ..httpClientAdapter = FakeAdapter(
        (_) => ResponseBody.fromString('', 200),
      );
    addTearDown(external.close);
    const source = '''
[Demo][clip]

`multi
[clip]: hidden.mp4
line`

<!--
[clip]: comment.mp4
-->
''';
    await tester.pumpWidget(_host(source, external));
    await tester.pump();
    expect(find.byType(MarkdownMediaCard), findsNothing);
  });

  testWidgets('angle-bracket reference destination resolves document-wide', (
    tester,
  ) async {
    final external = Dio()
      ..httpClientAdapter = FakeAdapter(
        (_) => ResponseBody.fromString('', 200),
      );
    addTearDown(external.close);
    const source = '''
[Demo][clip]

```text
middle
```

[clip]: <https://cdn.example/demo.mp4>
''';
    await tester.pumpWidget(_host(source, external));
    await tester.pump();
    expect(find.byType(MarkdownMediaCard), findsOneWidget);
  });
}
