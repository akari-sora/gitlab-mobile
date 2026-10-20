import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/markdown_media_syntax.dart';
import 'package:markdown/markdown.dart' as md;

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

String _repeatWithinLength({
  required String prefix,
  required String repeated,
  required String suffix,
  required int length,
}) {
  final count = (length - prefix.length - suffix.length) ~/ repeated.length;
  return '$prefix${repeated * count}$suffix';
}

int _measure(String source, {bool media = true}) {
  final watch = Stopwatch()..start();
  _parse(source, media: media);
  return (watch..stop()).elapsedMicroseconds;
}

void main() {
  const shapes = <String, ({String prefix, String repeated, String suffix})>{
    'spaced autolinks': (prefix: '', repeated: '<https://a ', suffix: ''),
    'unspaced autolinks': (prefix: '', repeated: '<https://a', suffix: ''),
    'video openers without closer': (
      prefix: 'v ',
      repeated: '<video src=a.mp4>',
      suffix: '',
    ),
    'video openers with failing tag before closer': (
      prefix: 'v ',
      repeated: '<video src=a.mp4>',
      suffix: '<x</video>',
    ),
  };

  for (final shape in shapes.entries) {
    test('FIX12 parser growth: ${shape.key}', () {
      String source(int length) => _repeatWithinLength(
        prefix: shape.value.prefix,
        repeated: shape.value.repeated,
        suffix: shape.value.suffix,
        length: length,
      );

      _measure(source(1024));
      final usesDefaultBaseline = shape.key == 'unspaced autolinks';
      if (usesDefaultBaseline) _measure(source(1024), media: false);
      // Keep the inherently quadratic package parser baseline below the
      // existing five-second cap while still comparing N with 4N.
      final quarterLength = usesDefaultBaseline ? 8192 : 16384;
      final capLength = usesDefaultBaseline ? 32768 : 65536;

      var quarter = 1 << 62;
      var cap = 1 << 62;
      var defaultQuarter = 1 << 62;
      var defaultCap = 1 << 62;
      for (var sample = 0; sample < 3; sample++) {
        final measuredQuarter = _measure(source(quarterLength));
        final measuredCap = _measure(source(capLength));
        if (measuredQuarter < quarter) quarter = measuredQuarter;
        if (measuredCap < cap) cap = measuredCap;
        if (usesDefaultBaseline) {
          final measuredDefaultQuarter = _measure(
            source(quarterLength),
            media: false,
          );
          final measuredDefaultCap = _measure(source(capLength), media: false);
          if (measuredDefaultQuarter < defaultQuarter) {
            defaultQuarter = measuredDefaultQuarter;
          }
          if (measuredDefaultCap < defaultCap) {
            defaultCap = measuredDefaultCap;
          }
        }
      }

      debugPrint(
        'FIX12 ${shape.key}: N=${quarter}us 4N=${cap}us '
        'defaultN=${usesDefaultBaseline ? defaultQuarter : 'not measured'}us '
        'default4N=${usesDefaultBaseline ? defaultCap : 'not measured'}us',
      );

      if (usesDefaultBaseline) {
        // The package:markdown AutolinkSyntax is itself superlinear on this
        // no-whitespace shape. The media syntax may add only bounded overhead.
        expect(cap, lessThan(5000000), reason: '${shape.key}: cap < 5 s');
        expect(
          cap,
          lessThan(defaultCap * 2.5),
          reason: '${shape.key}: cap < 2.5x default parser',
        );
      } else {
        expect(cap, lessThan(2000000), reason: '${shape.key}: cap < 2 s');
        expect(cap, lessThan(quarter * 12), reason: '${shape.key}: 4N growth');
      }
    });
  }
}
