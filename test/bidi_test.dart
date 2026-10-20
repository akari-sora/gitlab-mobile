import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' show MarkdownBody;
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

const _fsi = '⁨', _pdi = '⁩';

void main() {
  group('right-to-left isolation', () {
    test('Arabic messages isolate the values put into them', () {
      useLanguage(languageForTag('ar')!);
      expect(l10n.language.rtl, isTrue);
      expect(l10n.daysAgo(6), 'منذ ${_fsi}6$_pdi ي');
      expect(l10n.unlockNamedApp('Mergeline'), contains('${_fsi}Mergeline$_pdi'));
    });

    test('left-to-right languages keep their messages and text as they are', () {
      for (final tag in ['zh-TW', 'en', 'de']) {
        useLanguage(languageForTag(tag)!);
        expect(l10n.language.rtl, isFalse, reason: tag);
        expect(l10n.daysAgo(6), isNot(contains(_fsi)), reason: tag);
        expect(isolated('!44'), '!44', reason: tag);
      }
    });

    test('isolated wraps each line of GitLab text in Arabic and leaves empty text alone', () {
      useLanguage(languageForTag('ar')!);
      expect(isolated('!44'), '$_fsi!44$_pdi');
      expect(isolated('@user · gitlab.com\nsecond'), '$_fsi@user · gitlab.com$_pdi\n${_fsi}second$_pdi');
      expect(isolated(''), '');
    });

    testWidgets('a meta chip keeps a reference in its own direction in Arabic', (tester) async {
      useLanguage(languageForTag('ar')!);
      await tester.pumpWidget(const MaterialApp(home: Directionality(
        textDirection: TextDirection.rtl,
        child: Material(child: MetaChip('!44', mono: true)),
      )));
      expect(find.text('$_fsi!44$_pdi'), findsOneWidget);
    });
  });

  group('first strong direction', () {
    test('follows the first letter and skips neutral characters', () {
      expect(firstStrongDirection('Hello, world.'), TextDirection.ltr);
      expect(firstStrongDirection('مرحبا'), TextDirection.rtl);
      expect(firstStrongDirection('42 — שלום'), TextDirection.rtl);
      expect(firstStrongDirection('中文說明'), TextDirection.ltr);
      expect(firstStrongDirection('!44 · #12'), isNull);
      expect(firstStrongDirection(''), isNull);
    });

    Future<TextDirection> bodyDirection(WidgetTester tester, String markdown, TextDirection ambient) async {
      await tester.pumpWidget(MaterialApp(home: Directionality(
        textDirection: ambient,
        child: Material(child: MarkdownView(markdown, selectable: false)),
      )));
      final body = find.byType(MarkdownBody);
      return Directionality.of(tester.element(body));
    }

    testWidgets('a Markdown body reads in its own direction, like dir="auto"', (tester) async {
      expect(await bodyDirection(tester, '<!-- مرحبا -->\n## Release notes\nFixed.', TextDirection.rtl), TextDirection.ltr);
      expect(await bodyDirection(tester, '[![badge](https://example.com/b.svg)](https://example.com) مرحبا بكم', TextDirection.ltr), TextDirection.rtl);
      expect(await bodyDirection(tester, '中文說明', TextDirection.ltr), TextDirection.ltr);
      expect(await bodyDirection(tester, '```\n42\n```', TextDirection.rtl), TextDirection.rtl);
    });
  });

  group('Markdown summary', () {
    test('drops comments, tags, markers and link targets but keeps the words', () {
      final summary = markdownSummary(
        '<!-- CURSOR_AGENT_PR_BODY_BEGIN -->\n'
        '## What I found\n'
        '> Job artifact saves in `lib/ci_page.dart` kept a **private** ~~copy~~.\n'
        '<details><summary>Log</summary>\n\n'
        '```dart\nfinal x = 1;\n```\n'
        '---\n'
        'See [the docs](https://example.com/docs) and ![chart](https://example.com/c.png).\n'
        '- [ ] still a task',
        400,
      );
      expect(summary.more, isFalse);
      expect(summary.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
        'What I found Job artifact saves in lib/ci_page.dart kept a private copy. Log '
        'final x = 1; See the docs and . - [ ] still a task');
    });

    test('an unclosed comment hides the rest, as GitLab renders it', () {
      expect(markdownSummary('Intro\n<!-- draft notes', 100).text.trim(), 'Intro');
    });

    test('reports more text past the limit without splitting a grapheme', () {
      final summary = markdownSummary('${'👨‍👩‍👧‍👦' * 30}<!-- hidden -->', 10);
      expect(summary.more, isTrue);
      expect(summary.text, '👨‍👩‍👧‍👦' * 10);
    });
  });
}
