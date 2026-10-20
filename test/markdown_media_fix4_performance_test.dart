import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/shared/markdown_media_syntax.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'package:markdown/markdown.dart' as md;

import 'support/fake_adapter.dart';

void main() {
  const defaultBaselineShapes = {'Codex code source', 'Opus Q15 footnote'};
  const neutralised = {
    'Codex escaped source': r'<a>\<img src=x>',
    'Codex code source': '<a>`<img src=x>`',
    'Opus Q1 code': '<a>`<img src="https://cdn.example/a.png">`',
    'Opus Q2 escaped source': r'<a>\<img src="https://cdn.example/a.png">',
    'Opus Q3 text and code':
        '<a href=x>t `<img src="https://cdn.example/a.png">` ',
  };
  const hostile = {
    'Opus M1 quoted anchor close': (
      prefix: 'x <a href=u>t ',
      repeated: '<img src=y t="</a>"c=<a href=x>',
      suffix: ' t',
    ),
    'Opus M1 quoted picture close': (
      prefix: 'x <picture>t ',
      repeated: '<img t="</picture>"c=<picture>',
      suffix: ' t',
    ),
    'Opus N2 incomplete anchor': (prefix: 'v ', repeated: '<a b=', suffix: ''),
    'Opus N2b incomplete image': (
      prefix: 'v ',
      repeated: '<img src=',
      suffix: '',
    ),
    'Opus N3 block incomplete anchor': (
      prefix: '<div><img src="https://cdn.example/real.svg">\n',
      repeated: '<a b=',
      suffix: '',
    ),
  };
  String hostileSource(String key, int cap) {
    final shape = hostile[key]!;
    final count =
        (cap - shape.prefix.length - shape.suffix.length) ~/
        shape.repeated.length;
    return '${shape.prefix}${shape.repeated * count}${shape.suffix}';
  }

  String repeatedToLength(String value, int length) {
    final count = (length / value.length).ceil();
    return (value * count).substring(0, length);
  }

  String footnoteSource(int cap) =>
      'v ${repeatedToLength('<a>[^1]`<img src="https://cdn.example/a.png">`', cap - 30)}</a>\n\n[^1]: n';

  final shapes = <String, String>{
    for (final key in hostile.keys) key: hostileSource(key, 65536),
    'paragraph unknown tags': 'a\n${'<x>\n' * 16384}',
    'paragraph anchors': 'a\n${'<a href="x">\n' * 5462}',
    'inline unclosed video': 'v ${'<video>' * 9363}',
    'block unclosed video': '<div>\n${'<video>' * 9363}',
    'block unclosed audio': '<div>\n${'<audio>' * 9363}',
    'unclosed audio': '<audio>' * 9363,
    'invalid image anchors': 'v ${'<a><img>' * 8192}</a>',
    'invalid image pictures': 'v ${'<picture><img>' * 4682}</picture>',
    'invalid image anchors with text': 'v ${'<a href=x>t <img>' * 4096}</a>',
    'empty source anchors': 'v ${'<a href=x><img src="">' * 3121}</a>',
    for (final shape in neutralised.entries)
      shape.key: 'v ${shape.value * 65536}</a>',
    'Opus Q15 footnote': footnoteSource(65536),
  };
  const repeatedRegions = {
    'invalid image anchors': '<a><img>',
    'invalid image pictures': '<picture><img>',
    'invalid image anchors with text': '<a href=x>t <img>',
    'empty source anchors': '<a href=x><img src="">',
    ...neutralised,
  };
  for (final shape in shapes.entries) {
    testWidgets('FIX4 cap growth: ${shape.key}', (tester) async {
      final client = Dio()
        ..httpClientAdapter = FakeAdapter(
          (_) => ResponseBody.fromString('', 200),
        );
      addTearDown(client.close);

      Future<int> render(int length, {bool defaultSyntax = false}) async {
        // Tear down outside the timer so samples measure only this render.
        await tester.pumpWidget(const SizedBox.shrink());
        final closing = shape.key.contains('pictures') ? '</picture>' : '</a>';
        final repeated = repeatedRegions[shape.key];
        final source = shape.key == 'Opus Q15 footnote'
            ? footnoteSource(length)
            : hostile.containsKey(shape.key)
            ? hostileSource(shape.key, length)
            : repeated == null
            ? shape.value.substring(0, length)
            : 'v ${repeated * ((length - 2 - closing.length) ~/ repeated.length)}$closing';
        final watch = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: defaultSyntax
                    ? _DefaultMarkdownBody(source)
                    : MarkdownView(source, externalMediaClient: client),
              ),
            ),
          ),
        );
        await tester.pump();
        watch.stop();
        // The block hostile shape contains a real image. Drain its fake
        // transport timers after measuring parsing and initial layout.
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        return watch.elapsedMicroseconds;
      }

      await render(1024);
      final usesDefaultBaseline = defaultBaselineShapes.contains(shape.key);
      if (usesDefaultBaseline) await render(1024, defaultSyntax: true);
      // Use the best of three to reduce JIT/GC/scheduling noise without an
      // additive allowance that could conceal quadratic growth.
      var quarter = 1 << 62;
      var cap = 1 << 62;
      var defaultCap = 1 << 62;
      for (var sample = 0; sample < 3; sample++) {
        final measuredQuarter = await render(16384);
        final measuredCap = await render(65536);
        if (measuredQuarter < quarter) quarter = measuredQuarter;
        if (measuredCap < cap) cap = measuredCap;
        if (usesDefaultBaseline) {
          final measuredDefaultCap = await render(65536, defaultSyntax: true);
          if (measuredDefaultCap < defaultCap) defaultCap = measuredDefaultCap;
        }
      }
      debugPrint(
        'FIX4 ${shape.key}: N=${quarter}us 4N=${cap}us '
        'default4N=${usesDefaultBaseline ? defaultCap : 'not measured'}us',
      );
      // Linear scans grow 4x from N to 4N and quadratic ones 16x. Laying out
      // one long unbroken line is already slightly superlinear (about 7x
      // here, as on main), so the ratio allows 12x; the original scans took
      // 2.8 to 66 s at the cap, far above the independent ceiling.
      if (usesDefaultBaseline) {
        expect(cap, lessThan(5000000), reason: '${shape.key}: cap < 5 s');
        expect(
          cap,
          lessThan(defaultCap * 1.5),
          reason: '${shape.key}: cap < 1.5x default render',
        );
      } else {
        expect(cap, lessThan(2000000), reason: '${shape.key}: cap < 2 s');
        expect(cap, lessThan(quarter * 12), reason: '${shape.key}: 4N growth');
      }
    });
  }

  for (final shape in {
    ...neutralised,
    for (final entry in hostile.entries) entry.key: entry.value.repeated,
    'Opus Q15 footnote': '',
  }.entries) {
    test('FIX6 parser cap growth: ${shape.key}', () {
      String source(int cap) => shape.key == 'Opus Q15 footnote'
          ? footnoteSource(cap)
          : hostile.containsKey(shape.key)
          ? hostileSource(shape.key, cap)
          : 'v ${shape.value * ((cap - 6) ~/ shape.value.length)}</a>';
      List<md.Node> parse(String text, {bool media = true}) => md.Document(
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
      ).parseLines(const LineSplitter().convert(text));
      int measure(int cap, {bool media = true}) {
        final text = source(cap);
        final watch = Stopwatch()..start();
        parse(text, media: media);
        return (watch..stop()).elapsedMicroseconds;
      }

      measure(1024);
      var quarter = 1 << 62;
      var cap = 1 << 62;
      var mainQuarter = 1 << 62;
      var mainCap = 1 << 62;
      for (var sample = 0; sample < 3; sample++) {
        final n = measure(16384);
        final fourN = measure(65536);
        final mainN = measure(16384, media: false);
        final mainFourN = measure(65536, media: false);
        if (n < quarter) quarter = n;
        if (fourN < cap) cap = fourN;
        if (mainN < mainQuarter) mainQuarter = mainN;
        if (mainFourN < mainCap) mainCap = mainFourN;
      }
      if (!hostile.containsKey(shape.key)) {
        expect(
          md.HtmlRenderer().render(parse(source(65536))),
          md.HtmlRenderer().render(parse(source(65536), media: false)),
        );
      }
      debugPrint(
        'FIX6 parser ${shape.key}: N=${quarter}us 4N=${cap}us mainN=${mainQuarter}us main4N=${mainCap}us',
      );
      expect(cap, lessThan(2000000));
      expect(cap, lessThan(quarter * 12));
      expect(mainCap, lessThan(2000000));
      expect(mainCap, lessThan(mainQuarter * 12));
    });
  }
}

class _DefaultMarkdownBody extends StatelessWidget {
  const _DefaultMarkdownBody(this.data);

  final String data;

  @override
  Widget build(BuildContext context) {
    final tableTextScale = (MediaQuery.textScalerOf(context).scale(14) / 14)
        .clamp(1.0, 2.0);
    final body = MarkdownBody(
      data: data,
      selectable: false,
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        h1: Theme.of(context).textTheme.headlineSmall,
        h2: Theme.of(context).textTheme.titleLarge,
        h3: Theme.of(context).textTheme.titleMedium,
        tableColumnWidth: FixedColumnWidth(180.0 * tableTextScale),
        tableScrollbarThumbVisibility: true,
        code: TextStyle(
          fontFamily: codeFontFamily,
          fontFamilyFallback: const ['Menlo', 'monospace'],
          fontSize: 13,
          color: Theme.of(context).colorScheme.onSurface,
        ),
        codeblockDecoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        blockquoteDecoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
    return PageStorage(
      bucket: PageStorageBucket(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: SelectionArea(child: body),
      ),
    );
  }
}
