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

Future<void> _expectRequests(
  WidgetTester tester,
  String source,
  List<String> expected,
) async {
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
  expect(adapter.requests.map((request) => request.uri.toString()), expected);
  expect(find.byType(MarkdownMediaImage), findsNWidgets(expected.length));
}

void main() {
  final codePrecedence = {
    for (final tag in ['script', 'style', 'textarea', 'title', 'noscript'])
      tag: 'v <$tag>`</$tag><img src="https://cdn.example/p1.svg">` t',
    'invalid comment':
        'v <!-- -- ` --> <img src="https://cdn.example/p3.svg"> ` t',
    for (final tag in ['video', 'audio'])
      tag:
          'v <$tag src="a.mp4">`</$tag><img src="https://cdn.example/p4.svg">` t',
  };
  for (final input in codePrecedence.entries) {
    test('FIX8 code precedence AST matches main: ${input.key}', () {
      expect(
        _parse(input.value).map(_ast),
        _parse(input.value, media: false).map(_ast),
      );
    });
    testWidgets('FIX8 code precedence zero requests: ${input.key}', (
      tester,
    ) async {
      await _expectRequests(tester, input.value, []);
    });
  }

  const literalBlocks = {
    'Codex CDATA': '<![CDATA[\n<img src="https://cdn.example/hidden.svg">\n]]>',
    'Codex processing instruction':
        '<?review\n<img src="https://cdn.example/hidden.svg">\n?>',
    'Opus processing instruction':
        '<?php\n<img src="https://cdn.example/k2.svg">\n?>',
    'Opus declaration': '<!doctype x <img src="https://cdn.example/k3.svg">',
    'Opus nested CDATA':
        '<div><![CDATA[<img src="https://cdn.example/k4.svg">]]></div>',
  };
  for (final input in literalBlocks.entries) {
    testWidgets('FIX8 HTML literal zero requests: ${input.key}', (
      tester,
    ) async {
      await _expectRequests(tester, input.value, []);
      expect(
        _parse(input.value).map(_ast),
        _parse(input.value, media: false).map(_ast),
      );
    });
  }

  for (final separator in ['\u00a0', '\u3000', '\u000b']) {
    testWidgets(
      'FIX8 block rejects non-HTML whitespace ${separator.codeUnitAt(0)}',
      (tester) async {
        await _expectRequests(
          tester,
          '<div><img${separator}src="https://cdn.example/hidden.svg"></div>',
          [],
        );
      },
    );
    testWidgets(
      'FIX8 inline keeps package whitespace ${separator.codeUnitAt(0)}',
      (tester) async {
        await _expectRequests(
          tester,
          'v <img${separator}src="https://cdn.example/visible.svg"> t',
          ['https://cdn.example/visible.svg'],
        );
      },
    );
  }

  for (final separator in ['\t', '\n', '\f', '\r', ' ']) {
    testWidgets(
      'FIX8 block accepts HTML whitespace ${separator.codeUnitAt(0)}',
      (tester) async {
        await _expectRequests(
          tester,
          '<div><img${separator}src="https://cdn.example/visible.svg"></div>',
          ['https://cdn.example/visible.svg'],
        );
      },
    );
  }

  for (final literal in [
    '<![CDATA[<img src="https://cdn.example/hidden.svg">]]>',
    '<?review <img src="https://cdn.example/hidden.svg">?>',
    '<!DOCTYPE x <img src="https://cdn.example/hidden.svg">',
  ]) {
    testWidgets('FIX8 block resumes after literal: $literal', (tester) async {
      await _expectRequests(
        tester,
        '<div>$literal<img src="https://cdn.example/visible.svg"></div>',
        ['https://cdn.example/visible.svg'],
      );
    });
  }
}
