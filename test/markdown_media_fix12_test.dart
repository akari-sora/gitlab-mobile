import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/markdown_media.dart';
import 'package:gitlab_mobile/shared/markdown_media_syntax.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:markdown/markdown.dart' as md;

import 'support/fake_adapter.dart';

const _hidden = 'https://cdn.example/hidden.svg';

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

Iterable<md.Element> _elements(Iterable<md.Node> nodes) sync* {
  for (final node in nodes.whereType<md.Element>()) {
    yield node;
    if (node.children != null) yield* _elements(node.children!);
  }
}

List<String> _code(Iterable<md.Node> nodes) => _elements(
  nodes,
).where((node) => node.tag == 'code').map((node) => node.textContent).toList();

String _withoutOpeningSource(String source) => source
    .replaceFirst('<video src="a.mp4">', '<video>')
    .replaceFirst('<audio src="a.mp4">', '<audio>');

void _expectDefaultAfterOpeningCard(String source) {
  final withoutSource = _withoutOpeningSource(source);
  expect(
    _parse(withoutSource).map(_ast),
    _parse(withoutSource, media: false).map(_ast),
  );
  expect(_code(_parse(source)), _code(_parse(source, media: false)));
}

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
  const autolinkCrossings = {
    'Codex whitespace and code opener':
        'v <https://cdn.example/ `x.mp4>'
        '<img src="$_hidden">` t',
    'Opus AU1 whitespace and code opener':
        'v <https://a.example/a.mp4? `x.mp4>'
        '<img src="$_hidden">` t',
    'Opus AU4 complete comment':
        'v <https://a.example/a.mp4? `<!-- complete --> '
        '<img src="$_hidden">` t',
    'Opus AU5 complete link title':
        'v <https://a.example/a.mp4? `[label](path "title >") '
        '<img src="$_hidden">` t',
  };
  for (final input in autolinkCrossings.entries) {
    testWidgets('FIX12 autolink default AST and zero requests: ${input.key}', (
      tester,
    ) async {
      expect(
        _parse(input.value).map(_ast),
        _parse(input.value, media: false).map(_ast),
      );
      expect(
        _code(_parse(input.value)),
        _code(_parse(input.value, media: false)),
      );
      await _expectMedia(tester, input.value);
    });
  }

  testWidgets('FIX12 AU6 unspaced media autolink remains a card', (
    tester,
  ) async {
    const source = 'v <https://cdn.example/clip.mp4> t';
    final cards = _elements(
      _parse(source),
    ).where((node) => node.tag == markdownMediaElement).toList();
    expect(cards, hasLength(1));
    expect(cards.single.attributes['src'], 'https://cdn.example/clip.mp4');
    await _expectMedia(tester, source, cards: 1);
  });

  const tokenClosings = {
    'Codex complete comment': '<!-- </video> ` -->`<img src="$_hidden">`',
    'Opus V-C1 plain comment': '<!-- alpha </video> <img src="$_hidden"> -->',
    'Opus V-C2 comment with greater-than':
        '<!-- alpha > beta </video> <img src="$_hidden"> -->',
    'Opus V-C3 comment with less-than':
        '<!-- alpha < beta </video> <img src="$_hidden"> -->',
    'Opus V-P processing instruction':
        '<?review </video> <img src="$_hidden"> ?>',
    'Opus V-D CDATA': '<![CDATA[ </video> <img src="$_hidden"> ]]>',
    'Opus V-A quoted tag attribute':
        '<x title="</video> <img src=\'$_hidden\'>">fallback</x>',
    'Opus V-L link title': '[label](path "</video> <img src=\'$_hidden\'>")',
    'Opus V-I image title': '![label](path "</video> <img src=\'$_hidden\'>")',
    'Opus V-B link label': '[label </video>](path "<img src=\'$_hidden\'>")',
  };
  for (final input in tokenClosings.entries) {
    testWidgets('FIX12 bounded video token: ${input.key}', (tester) async {
      final source = 'v <video src="a.mp4">${input.value}</video> t';
      _expectDefaultAfterOpeningCard(source);
      await _expectMedia(
        tester,
        source,
        cards: 1,
        imageWidgets: input.key == 'Opus V-I image title' ? 1 : 0,
      );
    });
  }

  for (final character in {
    'backtick': '`',
    'link bracket': '[',
    'closing bracket': ']',
    'backslash': r'\',
  }.entries) {
    test('FIX12 rule 1 rejects ${character.key} in a text run', () {
      final source =
          'v <video src="a.mp4">before ${character.value} after</video> t';
      _expectDefaultAfterOpeningCard(source);
      expect(_parse(source).single.textContent, contains('</video>'));
    });
  }

  // Round 12: a label opened before the element ends inside its body, so
  // the closing tag sits in the link title or destination.
  const labelsBeforeOpening = {
    'Codex/Opus V-B link label':
        'v [<video src="a.mp4">x](u "</video><img src=\'$_hidden\'>") t',
    'image label':
        'v ![<video src="a.mp4">x](u "</video><img src=\'$_hidden\'>") t',
    'parenthesized title':
        'v [<video src="a.mp4">x](u (</video><img src=\'$_hidden\'>)) t',
    'audio single-quoted title':
        'v [<audio src="a.mp4">x](u \'</audio><img src="$_hidden">\') t',
    'empty label':
        'v [<video src="a.mp4">](u "</video><img src=\'$_hidden\'>") t',
    'tag in label':
        'v [<video src="a.mp4"><b>x</b>](u "</video><img src=\'$_hidden\'>") t',
    'angle destination':
        'v [<video src="a.mp4">x](<u> "</video><img src=\'$_hidden\'>") t',
  };
  for (final input in labelsBeforeOpening.entries) {
    testWidgets('FIX13 label before the opening tag: ${input.key}', (
      tester,
    ) async {
      _expectDefaultAfterOpeningCard(input.value);
      await _expectMedia(
        tester,
        input.value,
        // An image label becomes alt text, so the card is not built.
        cards: input.key == 'image label' ? 0 : 1,
        imageWidgets: input.key == 'image label' ? 1 : 0,
      );
    });
  }

  testWidgets('FIX13 a label closing after the element still wraps it', (
    tester,
  ) async {
    const source = 'v [<video src="a.mp4">x</video>](u) t';
    final links = _elements(
      _parse(source),
    ).where((node) => node.tag == 'a').toList();
    expect(links, hasLength(1));
    expect(_elements(links.single.children!).map((node) => node.tag), [
      markdownMediaElement,
    ]);
    await _expectMedia(tester, source, cards: 1);
  });

  const specialLessThan = {
    'comment': '<!-- </video> -->',
    'processing instruction': '<?review </video> ?>',
    'CDATA': '<![CDATA[ </video> ]]>',
    'declaration': '<!DOCTYPE </video>>',
    'bare less-than': '< </video>',
    'digit': '<7 </video>>',
    'autolink': '<https://cdn.example/path></video>',
  };
  for (final input in specialLessThan.entries) {
    test('FIX12 rule 2 rejects ${input.key}', () {
      final source = 'v <video src="a.mp4">${input.value}</video> t';
      _expectDefaultAfterOpeningCard(source);
      expect(_parse(source).single.textContent, contains('</video>'));
    });
  }

  test('FIX12 rule 3 uses the first matching-kind closing tag', () {
    const source =
        '<video src="a.mp4"><audio></audio><x></x></video>'
        '<video src="b.mp4"></video>';
    final nodes = _parse(source);
    final cards = _elements(
      nodes,
    ).where((node) => node.tag == markdownMediaElement).toList();
    expect(cards.map((node) => node.attributes['src']), ['a.mp4', 'b.mp4']);
    expect(nodes.map((node) => node.textContent).join(), isEmpty);
  });

  test('FIX12 full-window tag matching keeps quoted greater-than intact', () {
    const source =
        '<video src="a.mp4"><x title="one > </video> two" '
        "data-note='three > four'>fallback</x></video>";
    final nodes = _parse(source);
    final cards = _elements(
      nodes,
    ).where((node) => node.tag == markdownMediaElement).toList();
    expect(cards, hasLength(1));
    expect(cards.single.attributes['src'], 'a.mp4');
    expect(nodes.map((node) => node.textContent).join(), isEmpty);
  });

  test('FIX12 bounded named-tag ends equal full-source matcher ends', () {
    final pattern = md.InlineHtmlSyntax().pattern;
    for (final token in [
      '<x title="one > two">',
      '<x title="one \' > two">',
      '<x title=\'one " > two\'>',
      '<x\u00a0title="value"\u3000>',
    ]) {
      final start = 4096 - token.length;
      final source = '${'x' * start}$token continuation="not an attribute">';
      final window = source.substring(0, 4096);
      final bounded = pattern.matchAsPrefix(window, start);
      final full = pattern.matchAsPrefix(source, start);
      expect(bounded, isNotNull, reason: token);
      expect(full, isNotNull, reason: token);
      expect(bounded!.end, 4096, reason: token);
      expect(full!.end, bounded.end, reason: token);
    }

    const truncated = '<x title="one > two">';
    final start = 4097 - truncated.length;
    final source = '${'x' * start}$truncated';
    final window = source.substring(0, 4096);
    expect(pattern.matchAsPrefix(window, start), isNull);
    expect(pattern.matchAsPrefix(source, start)!.end, 4097);
  });

  String sizedElement(int size) {
    const opening = '<video src="a.mp4">';
    const closing = '</video>';
    return '$opening${'x' * (size - opening.length - closing.length)}$closing';
  }

  test('FIX12 rule 4 consumes 4096 characters', () {
    final source = sizedElement(4096);
    expect(source, hasLength(4096));
    final nodes = _parse(source);
    expect(
      _elements(nodes).where((node) => node.tag == markdownMediaElement),
      hasLength(1),
    );
    expect(nodes.map((node) => node.textContent).join(), isEmpty);
  });

  test('FIX12 rule 4 falls back at 4097 characters', () {
    final source = sizedElement(4097);
    expect(source, hasLength(4097));
    _expectDefaultAfterOpeningCard(source);
    expect(_parse(source).single.textContent, contains('</video>'));
  });

  String taggedElement(int bodyTags) =>
      '<video src="a.mp4">${'<x/>' * bodyTags}</video>';

  test('FIX12 rule 4 consumes 16 tags including the closer', () {
    final nodes = _parse(taggedElement(15));
    expect(
      _elements(nodes).where((node) => node.tag == markdownMediaElement),
      hasLength(1),
    );
    expect(nodes.map((node) => node.textContent).join(), isEmpty);
  });

  test('FIX12 rule 4 falls back at 17 tags including the closer', () {
    final source = taggedElement(16);
    _expectDefaultAfterOpeningCard(source);
    expect(_parse(source).single.textContent, contains('</video>'));
  });

  for (final body in {
    'V-F fallback image': '<img src="$_hidden">fallback',
    'V-T plain text': 'plain fallback text',
    'V-E empty': '',
  }.entries) {
    testWidgets('FIX12 consumed video keeps ${body.key} hidden', (
      tester,
    ) async {
      final source = '<video src="a.mp4">${body.value}</video>';
      final nodes = _parse(source);
      expect(nodes.map((node) => node.textContent).join(), isEmpty);
      await _expectMedia(tester, source, cards: 1);
    });
  }

  testWidgets('FIX12 retains source-only audio card', (tester) async {
    const source = '<audio><source src="sound.ogg" type="audio/ogg"></audio>';
    final card = _elements(
      _parse(source),
    ).singleWhere((node) => node.tag == markdownMediaElement);
    expect(card.attributes['src'], 'sound.ogg');
    expect(card.attributes['kind'], 'audio');
    await _expectMedia(tester, source, cards: 1);
  });
}
