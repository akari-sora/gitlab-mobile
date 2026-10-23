import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/exact_edit.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_preview.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/unified_diff.dart';

const _token = 'glpat-ABCDEFGHIJKLMNOPQRST';
final _instance = GitLabInstance.parse('https://gitlab.example/install');

void main() {
  group('original-coordinate exact replacements', () {
    test('all anchors use original coordinates, in either input order', () {
      for (final edits in [
        const [AiExactEdit('alpha', 'beta'), AiExactEdit('beta', 'gamma')],
        const [AiExactEdit('beta', 'gamma'), AiExactEdit('alpha', 'beta')],
      ]) {
        expect(_apply('alpha beta', edits).finalText, 'beta gamma');
      }
    });

    test('rejects missing anchors with their input index', () {
      _reject('alpha beta', const [AiExactEdit('missing', 'new')],
          'fragmentNotFound', index: 0);
    });

    test('rejects repeated anchors, including overlapping occurrences', () {
      _reject('old old', const [AiExactEdit('old', 'new')],
          'fragmentNotUnique', index: 0);
      _reject('aaa', const [AiExactEdit('aa', 'new')],
          'fragmentNotUnique', index: 0);
    });

    test('empty anchors are not insertion coordinates', () {
      for (final original in ['', 'abc']) {
        _reject(original, const [AiExactEdit('', 'new')],
            'fragmentNotUnique', index: 0);
      }
    });

    test('rejects overlaps and identical anchors but allows adjacency', () {
      _reject('abcdef', const [AiExactEdit('abcd', 'x'), AiExactEdit('def', 'y')],
          'fragmentsOverlap', index: 1);
      _reject('abc', const [AiExactEdit('abc', 'x'), AiExactEdit('abc', 'y')],
          'fragmentsOverlap', index: 1);
      expect(_apply('abcdef', const [
        AiExactEdit('abc', 'x'), AiExactEdit('def', 'y'),
      ]).finalText, 'xy');
    });

    test('rejects no edits, too many edits, and net no change', () {
      _reject('abc', const [], 'noEdits');
      _reject('abc', List.filled(21, const AiExactEdit('a', 'b')), 'tooManyEdits');
      _reject('abc', const [AiExactEdit('abc', 'abc')], 'noChange');
      _reject('abc', const [AiExactEdit('abc', 'x')], 'tooManyEdits', maxEdits: 0);
      expect(_apply('abc', const [AiExactEdit('abc', 'x')], maxEdits: 1).finalText,
          'x');
    });

    test('deletions and mixed no-op replacements preserve the rest', () {
      final result = _apply('first\nsecond\nthird\n', const [
        AiExactEdit('second\n', ''), AiExactEdit('third', 'third'),
      ]);
      expect(result.finalText, 'first\nthird\n');
      expect(result.scan.newTexts, ['', 'third']);
    });

    test('multiline strings, decorators, slashes and Unicode keep exact bytes', () {
      const original = 'header\r\nold\r\nfooter\r\n';
      const replacement = '@param value\r\n@Override\r\n@dataclass\r\n'
          '/usr/bin/env\r\n"""\r\n  text\t\r\n"""\r\n🙂e\u0301\u0000';
      final result = _apply(original, const [AiExactEdit('old', replacement)]);
      expect(utf8.encode(result.finalText),
          utf8.encode('header\r\n$replacement\r\nfooter\r\n'));
      expect(_check(result.scan).blockCode, isNull);
      expect(_check(result.scan).confirmReasons, isEmpty);
    });

    test('context windows include exactly three surrounding lines', () {
      final source = List.generate(11, (i) => 'line$i\n').join();
      final result = _apply(source, const [AiExactEdit('line5\n', 'new\n')]);
      expect(result.scan.windows.single.before,
          List.generate(7, (i) => 'line${i + 2}\n').join());
      expect(result.scan.windows.single.after,
          'line2\nline3\nline4\nnew\nline6\nline7\nline8\n');
    });

    test('windows merge and retain offsets after multiline replacements', () {
      final source = List.generate(24, (i) => 'line$i\n').join();
      final result = _apply(source, const [
        AiExactEdit('line3', 'three\nextra'),
        AiExactEdit('line7', ''),
        AiExactEdit('line20', 'twenty'),
      ]);
      expect(result.scan.windows, hasLength(2));
      expect(result.scan.windows[0].after,
          result.scan.windows[0].before.replaceFirst('line3', 'three\nextra')
              .replaceFirst('line7', ''));
      expect(result.scan.windows[1].after,
          result.scan.windows[1].before.replaceFirst('line20', 'twenty'));
    });

    test('windows preserve CRLF through file-edge and multiline deletions', () {
      const source = 'first\r\none\r\ntwo\r\nthree\r\nlast';
      final result = _apply(source, const [
        AiExactEdit('first\r\n', ''),
        AiExactEdit('two\r\nthree\r\n', 'middle\r\n'),
        AiExactEdit('last', 'end'),
      ]);
      expect(result.scan.windows.single.before, source);
      expect(result.scan.windows.single.after, 'one\r\nmiddle\r\nend');
      expect(_check(result.scan).blockCode, isNull);
    });
  });

  group('§15 row 9 fragment safety', () {
    test('new redaction, data-boundary and private-key markers are blocked', () {
      for (final marker in [
        '[REDACTED]', '[REDACTED:private_key_fragment]',
        '<gitlab_data nonce="fake">', '</gitlab_data>',
      ]) {
        final scan = _apply('old', [AiExactEdit('old', marker)]).scan;
        expect(_check(scan).blockCode, 'redactionMarker', reason: marker);
      }
    });

    test('new strings are scanned even when window hit counts do not rise', () {
      for (final value in ['[REDACTED]', _token, 'opaqueCredential']) {
        final nearby = _apply('$value\nold', const [AiExactEdit('old', 'new')]).scan;
        final scan = AiTextScan(
          original: nearby.original,
          newTexts: [value],
          windows: nearby.windows,
        );
        expect(_check(scan, secrets: {'opaqueCredential'}).blockCode,
            value == '[REDACTED]' ? 'redactionMarker' : 'secret');
      }
    });

    test('existing markers do not block nearby edits', () {
      for (final marker in ['[REDACTED]', '<gitlab_data>', '</gitlab_data>']) {
        final scan = _apply('$marker\nold\n', const [AiExactEdit('old', 'new')]).scan;
        expect(_check(scan).blockCode, isNull, reason: marker);
      }
    });

    test('markers assembled at either boundary or by deletion are blocked', () {
      for (final sample in <(String, AiExactEdit)>[
        ('[REDAold', const AiExactEdit('old', 'CTED]')),
        ('oldCTED]', const AiExactEdit('old', '[REDA')),
        ('[REDAxCTED]', const AiExactEdit('x', '')),
        ('<gitlab_xdata>', const AiExactEdit('x', '')),
        ('</gitlab_xdata>', const AiExactEdit('x', '')),
      ]) {
        expect(_check(_apply(sample.$1, [sample.$2]).scan).blockCode,
            'redactionMarker', reason: sample.$1);
      }
    });

    test('unchanged built-in and known secrets are counted without blocking', () {
      final scan = _apply('$_token\nold\n', const [AiExactEdit('old', 'new')]).scan;
      expect(_check(scan).blockCode, isNull);
      expect(_check(scan).preexistingSecretHits, 1);
      final known = _apply('opaqueCredential\nold', const [AiExactEdit('old', 'new')]);
      expect(_check(known.scan, secrets: {'opaqueCredential'}).blockCode, isNull);
      expect(_check(known.scan, secrets: {'opaqueCredential'}).preexistingSecretHits, 1);
    });

    test('unchanged hits outside all context windows are still counted', () {
      final source = '$_token\n${'padding\n' * 10}old\n';
      final scan = _apply(source, const [AiExactEdit('old', 'new')]).scan;
      expect(scan.windows.single.after, isNot(contains(_token)));
      expect(_check(scan).blockCode, isNull);
      expect(_check(scan).preexistingSecretHits, 1);
    });

    test('removed hits are excluded and merged windows do not double count', () {
      final result = _apply('$_token\nold\nend\n', const [
        AiExactEdit(_token, ''), AiExactEdit('old', 'new'),
      ]);
      expect(_check(result.scan).blockCode, isNull);
      expect(_check(result.scan).preexistingSecretHits, 0);
    });

    test('new built-in tokens and newly copied known secrets are blocked', () {
      for (final secret in [_token, 'opaqueCredential']) {
        final scan = _apply('old', [AiExactEdit('old', secret)]).scan;
        expect(_check(scan, secrets: {'opaqueCredential'}).blockCode, 'secret');
      }
    });

    test('known secrets and built-in tokens assembled across boundaries block', () {
      for (final sample in <(String, AiExactEdit)>[
        ('glpat-ABCDEFGHIJold', const AiExactEdit('old', 'KLMNOPQRST')),
        ('oldKLMNOPQRST', const AiExactEdit('old', 'glpat-ABCDEFGHIJ')),
        ('glpat-ABCDEFGHIJ KLMNOPQRST', const AiExactEdit(' ', '')),
        ('opaque-old', const AiExactEdit('old', 'Credential')),
      ]) {
        final scan = _apply(sample.$1, [sample.$2]).scan;
        expect(_check(scan, secrets: {'opaque-Credential'}).blockCode, 'secret',
            reason: sample.$1);
      }
    });

    test('adjacent replacements cannot assemble a secret together', () {
      final scan = _apply('leftRIGHT', const [
        AiExactEdit('left', 'opaque'), AiExactEdit('RIGHT', 'Credential'),
      ]).scan;
      expect(_check(scan, secrets: {'opaqueCredential'}).blockCode, 'secret');
    });

    test('equal aggregate counts cannot conceal a different new boundary hit', () {
      final scan = _apply('oldSecret\nnew-piece', const [
        AiExactEdit('oldSecret\n', ''), AiExactEdit('piece', 'Secret'),
      ]).scan;
      expect(_check(scan, secrets: {'oldSecret', 'new-Secret'}).blockCode, 'secret');
    });

    test('removed identical markers cannot conceal newly assembled markers', () {
      final scan = _apply('[REDACTED]\n[REDAX', const [
        AiExactEdit('[REDACTED]\n', ''), AiExactEdit('X', 'CTED]'),
      ]).scan;
      expect(_check(scan).blockCode, 'redactionMarker');
    });

    test('removed identical secrets cannot conceal replacement boundary hits', () {
      final scan = _apply('opaqueCredential\nopaqueX', const [
        AiExactEdit('opaqueCredential\n', ''), AiExactEdit('X', 'Credential'),
      ]).scan;
      expect(_check(scan, secrets: {'opaqueCredential'}).blockCode, 'secret');
    });

    test('provenance follows earlier deltas across disjoint windows', () {
      final scan = _apply('head\n${'padding\n' * 10}'
          'opaqueCredential\nopaqueX', const [
        AiExactEdit('X', 'Credential'),
        AiExactEdit('head',
            'a substantially longer replacement header\nwith another line'),
        AiExactEdit('opaqueCredential\n', ''),
      ]).scan;
      expect(scan.windows, hasLength(2));
      expect(_check(scan, secrets: {'opaqueCredential'}).blockCode, 'secret');
    });

    test('removed identical secrets cannot conceal deletion-only joins', () {
      final scan = _apply('opaqueCredential\nopaqueXCredential', const [
        AiExactEdit('opaqueCredential\n', ''), AiExactEdit('X', ''),
      ]).scan;
      expect(_check(scan, secrets: {'opaqueCredential'}).blockCode, 'secret');
    });

    test('unchanged hits touching deletion seams remain allowed', () {
      for (final source in ['XopaqueCredential old', 'opaqueCredentialX old']) {
        final scan = _apply(source, const [
          AiExactEdit('X', ''), AiExactEdit('old', 'new'),
        ]).scan;
        final checked = _check(scan, secrets: {'opaqueCredential'});
        expect(checked.blockCode, isNull, reason: source);
        expect(checked.preexistingSecretHits, 1);
      }
    });

    test('windows without engine provenance fail closed on ambiguous hits', () {
      for (final value in ['[REDACTED]', 'opaqueCredential']) {
        final scan = AiTextScan(original: value,
            windows: [AiTextWindow(before: value, after: value)]);
        expect(_check(scan, secrets: {'opaqueCredential'}).blockCode,
            value == '[REDACTED]' ? 'redactionMarker' : 'secret');
      }
      expect(_check(AiTextScan(windows: const [
        AiTextWindow(before: 'old', after: 'new'),
      ])).blockCode, isNull);
    });

    test('scan failures fail closed', () {
      final scan = _apply('old', const [AiExactEdit('old', 'new')]).scan;
      expect(_check(scan, secrets: {'REDACTED'}).blockCode, 'secret');
    });

    test('private key material introduced across a boundary is blocked', () {
      final scan = _apply('-----BEGIN RSA old\nbody\n', const [
        AiExactEdit('old', 'PRIVATE KEY-----'),
      ]).scan;
      expect(_check(scan).blockCode, 'secret');
    });
  });

  group('§15 row 14 Markdown confirmation', () {
    test('visibility holds apply independently of Markdown rendering', () {
      final scan = _apply('old', const [AiExactEdit('old', 'new')]).scan;
      for (final visibility in const [
        text.AiVisibilityContext(polluted: true),
        text.AiVisibilityContext(visibilityUnreadable: true),
      ]) {
        for (final value in [scan, _markdown(scan)]) {
          expect(checkFragments(value, knownSecrets: const {},
              instance: _instance, visibility: visibility).confirmReasons,
              [AiFixedConfirmReason.confidentialOrVisibilityMix]);
        }
      }
    });

    test('unseen external Markdown link domains require confirmation', () {
      for (final domain in ['unseen.example', 'external.example']) {
        final scan = _apply('old', [
          AiExactEdit('old', '[link](https://$domain/path)'),
        ]).scan;
        expect(_check(_markdown(scan)).confirmReasons,
            domain == 'unseen.example'
                ? [AiFixedConfirmReason.confidentialOrVisibilityMix]
                : isEmpty);
      }
    });

    test('only Markdown extensions are rendered, case insensitively', () {
      for (final path in ['README.md', 'docs/readme.MARKDOWN', '.md']) {
        expect(isRenderedMarkdownPath(path), isTrue);
      }
      for (final path in ['code.py', 'Main.java', 'readme.mdx', 'readme.md.txt']) {
        expect(isRenderedMarkdownPath(path), isFalse);
      }
    });

    test('Java and Python @param and decorators are byte-preserved without holds', () {
      const code = '@param one\n@Override\n@dataclass\n@decorator\n@five\n@six\n/keep';
      final result = _apply('old', const [AiExactEdit('old', code)]);
      expect(result.finalText, code);
      expect(_check(result.scan).confirmReasons, isEmpty);
    });

    test('mass mentions in a Markdown changed window require confirmation', () {
      const mentions = '@a @b @c @d @e @f';
      final result = _apply('old\n', const [AiExactEdit('old', mentions)]);
      expect(_check(_markdown(result.scan)).confirmReasons,
          contains(AiFixedConfirmReason.massMention));
      expect(result.finalText, '$mentions\n');
    });

    test('unchanged uploads cannot hide Markdown confirmations', () {
      for (final old in [
        '/uploads/0123456789abcdef0123456789abcdef/a.png',
        '[[upload:u-1]]', '[[attachment:att-1]]',
      ]) {
        final result = _apply('$old old', const [AiExactEdit('old', '@all')]);
        expect(_check(_markdown(result.scan)).blockCode, isNull);
        expect(_check(_markdown(result.scan)).confirmReasons,
            contains(AiFixedConfirmReason.massMention), reason: old);
      }
    });

    test('upload context keeps media hosts and boundary-assembled mentions', () {
      const source = '![old](https://external.example/uploads/'
          '0123456789abcdef0123456789abcdef/a.png) @alX';
      final result = _apply(source, const [AiExactEdit('X', 'l')]);
      final check = _check(_markdown(result.scan));
      expect(check.blockCode, isNull);
      expect(check.confirmReasons, containsAll([
        AiFixedConfirmReason.massMention,
        AiFixedConfirmReason.externalMediaInRenderedMarkdown,
      ]));
      expect(result.finalText, source.replaceFirst('X', 'l'));
    });

    test('broadcasts and group mentions require confirmation', () {
      for (final mention in ['@all', '@here', '@group/team', '@uploads/team']) {
        final scan = _apply('old', [AiExactEdit('old', mention)]).scan;
        expect(_check(_markdown(scan)).confirmReasons,
            contains(AiFixedConfirmReason.massMention));
      }
    });

    test('upload scanning preserves media URL hosts', () {
      const source = '![image](https://uploads/'
          '0123456789abcdef0123456789abcdef/a.png) old';
      final scan = _markdown(_apply(source,
          const [AiExactEdit('old', 'new')]).scan);
      final check = checkFragments(scan, knownSecrets: const {},
          instance: GitLabInstance.parse('https://uploads'),
          visibility: const text.AiVisibilityContext());
      expect(check.blockCode, isNull);
      expect(check.confirmReasons, isEmpty);
    });

    test('Markdown outside changed windows does not require confirmation', () {
      final source = '@all ![image](https://external.example/a.png)\n'
          '${'padding\n' * 10}old\n';
      final result = _apply(source, const [AiExactEdit('old', 'new')]);
      expect(_check(_markdown(result.scan)).confirmReasons, isEmpty);
    });

    test('external Markdown media holds; same-instance media does not', () {
      for (final media in [
        '![image](https://external.example/a.png)',
        '<video src="https://external.example/a.mp4"></video>',
      ]) {
        final scan = _apply('old', [AiExactEdit('old', media)]).scan;
        expect(_check(_markdown(scan)).confirmReasons,
            contains(AiFixedConfirmReason.externalMediaInRenderedMarkdown));
        expect(_check(scan).confirmReasons, isEmpty);
      }
      final same = _apply('old', const [
        AiExactEdit('old', '![image](https://gitlab.example/install/image.png)'),
      ]);
      expect(_check(_markdown(same.scan)).confirmReasons, isEmpty);
    });

    test('confirmation reasons are deduplicated across disjoint windows', () {
      final result = _apply('one\n${'padding\n' * 12}two', const [
        AiExactEdit('one', '@all'), AiExactEdit('two', '@all'),
      ]);
      expect(_check(_markdown(result.scan)).confirmReasons,
          [AiFixedConfirmReason.massMention]);
    });
  });

  group('unified preview diff', () {
    test('unchanged content produces no hunks', () {
      expect(unifiedDiff('', ''), isEmpty);
      expect(unifiedDiff('same\n', 'same\n'), isEmpty);
    });

    test('replacement has three context lines and independent anchors', () {
      final before = List.generate(11, (i) => 'line$i\n').join();
      final lines = unifiedDiff(before, before.replaceFirst('line5', 'new'));
      expect(lines.first.text, '@@ -3,7 +3,7 @@');
      expect(lines.where((l) => l.kind == AiDiffLineKind.context), hasLength(6));
      final removed = lines.singleWhere((l) => l.kind == AiDiffLineKind.deletion);
      final added = lines.singleWhere((l) => l.kind == AiDiffLineKind.addition);
      expect((removed.text, removed.oldLine, removed.newLine), ('line5', 6, null));
      expect((added.text, added.oldLine, added.newLine), ('new', null, 6));
      expect(() => parseUnifiedDiff(_wire(lines)), returnsNormally);
    });

    test('empty-file insertions and deletions have valid zero-count anchors', () {
      expect(unifiedDiff('', 'new\n').first.text, '@@ -0,0 +1,1 @@');
      expect(unifiedDiff('old\n', '').first.text, '@@ -1,1 +0,0 @@');
      expect(() => parseUnifiedDiff(_wire(unifiedDiff('', 'new\n'))), returnsNormally);
      expect(() => parseUnifiedDiff(_wire(unifiedDiff('old\n', ''))), returnsNormally);
    });

    test('context controls hunk merging and rejects negative values', () {
      const before = 'a\nb\nc\nd\ne\nf\ng\nh\ni\n';
      const after = 'A\nb\nc\nd\ne\nf\ng\nh\nI\n';
      expect(unifiedDiff(before, after).where((l) => l.kind == AiDiffLineKind.hunk),
          hasLength(2));
      expect(unifiedDiff(before, after, context: 4)
          .where((l) => l.kind == AiDiffLineKind.hunk), hasLength(1));
      expect(unifiedDiff('a\nb\nc\n', 'a\nB\nc\n', context: 0).first.text,
          '@@ -2,1 +2,1 @@');
      expect(() => unifiedDiff('a', 'b', context: -1), throwsArgumentError);
    });

    test('newline-only changes and CRLF are visible without altering payload', () {
      final lines = unifiedDiff('same', 'same\n');
      expect(lines.where((l) => l.kind == AiDiffLineKind.deletion), hasLength(1));
      expect(lines.where((l) => l.kind == AiDiffLineKind.addition), hasLength(1));
      expect(lines.any((l) => l.text == r'\ No newline at end of file'), isTrue);
      expect(() => parseUnifiedDiff(_wire(lines)), returnsNormally);
      final crlf = unifiedDiff('old\r\n', 'new\r\n');
      expect(crlf.singleWhere((l) => l.kind == AiDiffLineKind.addition).text, 'new\r');
    });

    test('random repeated-line diffs reconstruct both full sources', () {
      final random = Random(4321);
      for (var run = 0; run < 200; run++) {
        String source() => List.generate(random.nextInt(18),
            (_) => '${random.nextInt(5)}\n').join();
        final before = source();
        final after = source();
        final lines = unifiedDiff(before, after, context: 100);
        if (before == after) continue;
        expect(_side(lines, old: true), before, reason: 'old $run');
        expect(_side(lines, old: false), after, reason: 'new $run');
        expect(() => parseUnifiedDiff(_wire(lines)), returnsNormally);
      }
    });

    test('large unrelated files use a bounded exact replacement fallback', () {
      final before = List.generate(20000, (i) => 'old$i\n').join();
      final after = List.generate(20000, (i) => 'new$i\n').join();
      final lines = unifiedDiff(before, after);
      expect(lines, hasLength(40001));
      expect(_side(lines, old: true), before);
      expect(_side(lines, old: false), after);
    });
  });
}

AiExactEditApplied _apply(String original, List<AiExactEdit> edits,
    {int maxEdits = 20}) {
  final result = applyExactEdits(original, edits, maxEdits: maxEdits);
  expect(result, isA<AiExactEditApplied>());
  return result as AiExactEditApplied;
}

void _reject(String original, List<AiExactEdit> edits, String reason,
    {int? index, int maxEdits = 20}) {
  final result = applyExactEdits(original, edits, maxEdits: maxEdits);
  expect(result, isA<AiExactEditRejected>());
  final rejected = result as AiExactEditRejected;
  expect(rejected.reasonCode, reason);
  expect(rejected.editIndex, index);
}

AiTextScan _markdown(AiTextScan scan) => AiTextScan(
  original: scan.original, newTexts: scan.newTexts, windows: scan.windows,
  markdown: true,
);

AiFragmentCheck _check(AiTextScan scan, {Set<String> secrets = const {}}) =>
    checkFragments(scan, knownSecrets: secrets, instance: _instance,
      visibility: const text.AiVisibilityContext(targetProjectPath: 'group/project',
        userMessageDomains: {'external.example'}));

String _wire(List<AiDiffLine> lines) => lines.map((line) => switch (line.kind) {
  AiDiffLineKind.hunk => line.text,
  AiDiffLineKind.context => ' ${line.text}',
  AiDiffLineKind.addition => '+${line.text}',
  AiDiffLineKind.deletion => '-${line.text}',
}).join('\n');

String _side(List<AiDiffLine> lines, {required bool old}) => lines.where((l) =>
  l.kind == AiDiffLineKind.context ||
  l.kind == (old ? AiDiffLineKind.deletion : AiDiffLineKind.addition))
  .map((l) => '${l.text}\n').join();
