import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' show MarkdownBody;
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/workspace_fixture.dart';

const _fsi = '\u2068', _pdi = '\u2069';

/// Whether [token] inside [text] is laid out left to right, character by
/// character, in a right-to-left paragraph: `!44` must not read `44!`.
bool _readsLeftToRight(String text, String token) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: const TextStyle(fontSize: 14)),
    textDirection: TextDirection.rtl,
  )..layout();
  addTearDown(painter.dispose);
  double left(int index) => painter
      .getBoxesForSelection(TextSelection(baseOffset: index, extentOffset: index + 1))
      .first
      .left;
  final start = text.indexOf(token);
  expect(start, isNonNegative, reason: 'token "$token" in "$text"');
  for (var i = start; i < start + token.length - 1; i++) {
    if (left(i) >= left(i + 1)) return false;
  }
  return true;
}

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
        expect(l10n.openMergeRequest(44), isNot(contains(_fsi)), reason: tag);
        expect(isolated('!44'), '!44', reason: tag);
      }
    });

    test('isolated wraps each line of GitLab text in Arabic and leaves empty text alone', () {
      useLanguage(languageForTag('ar')!);
      expect(isolated('!44'), '$_fsi!44$_pdi');
      expect(isolated('@user · gitlab.com\nsecond'), '$_fsi@user · gitlab.com$_pdi\n${_fsi}second$_pdi');
      expect(isolated(''), '');
    });

    testWidgets('references and usernames read left to right in Arabic text', (tester) async {
      useLanguage(languageForTag('ar')!);
      // A sigil written in the message joins the value's isolate.
      expect(_readsLeftToRight(l10n.openMergeRequest(44), '!44'), isTrue);
      expect(_readsLeftToRight(l10n.workItemIid(12), '#12'), isTrue);
      expect(_readsLeftToRight(l10n.accountAtUsername('user'), '@user'), isTrue);
      expect(_readsLeftToRight(l10n.mergeRequestCommits(44), '!44'), isTrue);
      // A reference passed whole.
      expect(_readsLeftToRight(l10n.editItemReference('!44'), '!44'), isTrue);
      expect(_readsLeftToRight(isolated('!44'), '!44'), isTrue);
      // An Arabic name next to a Latin username: each is isolated on its own.
      expect(_readsLeftToRight('${isolated('محمد')} · ${isolated('@user')}', '@user'), isTrue);
      // Without isolation the same text is reordered, so the check can fail.
      expect(_readsLeftToRight('فتح !44', '!44'), isFalse);
    });

    testWidgets('an editor subtitle such as a dotfile path keeps its order in Arabic', (tester) async {
      useLanguage(languageForTag('ar')!);
      FlutterSecureStorage.setMockInitialValues({});
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      await tester.pumpWidget(MaterialApp(home: Directionality(
        textDirection: TextDirection.rtl,
        child: ResourceEditor(
          account: fixture.account,
          title: 'edit',
          subtitle: '.gitlab-ci.yml · main',
          resource: 'bidi-editor-subtitle',
          fields: const [EditField('body', 'body')],
          save: (_) async {},
        ),
      )));
      await tester.pumpAndSettle();
      final shown = find.textContaining('gitlab-ci.yml');
      expect(shown, findsOneWidget);
      final text = tester.widget<Text>(shown).data!;
      expect(text, '$_fsi.gitlab-ci.yml · main$_pdi');
      expect(_readsLeftToRight(text, '.gitlab-ci.yml'), isTrue);
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
    test('follows the first letter or direction mark and skips neutral characters', () {
      expect(firstStrongDirection('Hello, world.'), TextDirection.ltr);
      expect(firstStrongDirection('مرحبا'), TextDirection.rtl);
      expect(firstStrongDirection('42 — שלום'), TextDirection.rtl);
      expect(firstStrongDirection('中文說明'), TextDirection.ltr);
      expect(firstStrongDirection('\u200FEnglish.'), TextDirection.rtl);
      expect(firstStrongDirection('\u200Eمرحبا'), TextDirection.ltr);
      expect(firstStrongDirection('!44 · #12'), isNull);
      expect(firstStrongDirection(''), isNull);
    });

    Future<TextDirection> bodyDirection(WidgetTester tester, String markdown, TextDirection ambient) async {
      await tester.pumpWidget(MaterialApp(home: Directionality(
        textDirection: ambient,
        child: Material(child: MarkdownView(markdown, selectable: false)),
      )));
      return Directionality.of(tester.element(find.byType(MarkdownBody)));
    }

    testWidgets('in a right-to-left interface a left-to-right body reads left to right', (tester) async {
      expect(await bodyDirection(tester, '<!-- مرحبا -->\n## Release notes\nFixed.', TextDirection.rtl), TextDirection.ltr);
      expect(await bodyDirection(tester, '[![badge](https://example.com/b.svg)](https://example.com) مرحبا بكم', TextDirection.rtl), TextDirection.rtl);
      expect(await bodyDirection(tester, '```\n42\n```', TextDirection.rtl), TextDirection.rtl);
    });

    testWidgets('a left-to-right interface is never flipped', (tester) async {
      // Code blocks follow the body's direction, so an Arabic body stays LTR here.
      expect(await bodyDirection(tester, 'مرحبا بكم', TextDirection.ltr), TextDirection.ltr);
      expect(await bodyDirection(tester, '中文說明', TextDirection.ltr), TextDirection.ltr);
    });
  });

  group('Markdown summary', () {
    String summary(String source, [int limit = 400]) =>
        markdownSummary(source, limit).text.replaceAll(RegExp(r'\s+'), ' ').trim();

    test('drops comments, tags, markers and link targets but keeps the words', () {
      final result = markdownSummary(
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
      expect(result.more, isFalse);
      expect(result.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
        'What I found Job artifact saves in lib/ci_page.dart kept a private copy. Log '
        'final x = 1; See the docs and . - [ ] still a task');
    });

    test('code keeps its text, comments and tags included', () {
      expect(summary('Use `<!-- keep this -->` in the template.'), 'Use <!-- keep this --> in the template.');
      expect(summary('```html\n<!-- keep --><b>x</b>\n```\nafter'), '<!-- keep --><b>x</b> after');
      expect(summary('Use ``a ` b`` here.'), 'Use a ` b here.');
      expect(summary('Returns `List<String>`.'), 'Returns List<String>.');
      expect(summary('```foo``` is used for bar'), 'foo is used for bar');
      expect(summary('Unclosed ` tick'), 'Unclosed ` tick');
    });

    test('long and nested link syntax never leaks', () {
      final long = '[Read the docs](https://example.com/${'a' * 1300}) after';
      expect(summary(long, 560), 'Read the docs after');
      final badges = '${'[![badge](https://example.com/b.svg)](https://example.com) ' * 40}\nVisible introduction';
      expect(summary(badges, 200), 'Visible introduction');
      expect(summary('[wiki](https://example.com/Foo_(bar)) end'), 'wiki end');
    });

    test('block markers, comments and emphasis follow CommonMark', () {
      expect(summary('<!--> visible'), 'visible');
      expect(summary('> ## Quoted heading\n>> nested'), 'Quoted heading nested');
      expect(summary('Title\n====='), 'Title');
      expect(summary('__init__ and __Important__ but snake__case__name'), 'init and Important but snake__case__name');
      expect(summary('A\n<!-- x\ny -->B'), 'A B');
    });

    test('an unclosed comment hides the rest, as GitLab renders it', () {
      final result = markdownSummary('Intro\n<!-- draft\nnotes', 100);
      expect(result.text.trim(), 'Intro');
      expect(result.more, isFalse);
    });

    test('a link whose label holds code or a comment still loses its target', () {
      expect(summary('[Use `foo`](https://example.com/docs) after'), 'Use foo after');
      expect(summary('[Read <!-- hidden -->docs](https://example.com/docs) after'), 'Read docs after');
      expect(summary('Code `[a](b)` stays'), 'Code [a](b) stays');
    });

    test('every code span on a line keeps its text, and noncharacters cannot collide', () {
      final many = '${'`x` ' * 40}`List<String>` and `[a](b)` and `__keep__` after';
      expect(summary(many, 2000), '${'x ' * 40}List<String> and [a](b) and __keep__ after');
      expect(summary('odd \uFDD0 char then `code`'), 'odd char then code');
      expect(summary('__snake_case__ word and __init__'), 'snake_case word and init');
    });

    test('a line cut at the scan limit drops the syntax left open', () {
      final badge = '[![b](https://img.shields.io/${'x' * 800})](https://example.com/${'y' * 20}) ';
      final result = markdownSummary('${badge * 40} Real text', 560);
      expect(result.more, isTrue);
      expect(result.text, isNot(contains('https')));
      expect(result.text, isNot(contains('[')));
    });

    test('escapes, inline comments and the exact limit', () {
      expect(summary('\\`x \\` stays and \\*not bold\\*'), '`x ` stays and *not bold*');
      // A comment opened mid-line and never closed is plain text, as in CommonMark.
      expect(summary('a <!-- b \nc'), 'a <!-- b c');
      expect(summary('a <!-- b \nc --> d'), 'a d');
      expect(markdownSummary('a' * 400, 400).more, isFalse);
      expect(markdownSummary('a' * 401, 400).more, isTrue);
    });

    test('hostile long lines are summarised in bounded time', () {
      // Every one of these took seconds to minutes when the patterns could
      // rescan the rest of the line from each start.
      final widths = List.generate(250, (i) => '`' * (i + 1)).join('a');
      for (final input in [
        '[' * 65536,
        '![' * 32768,
        '__x ' * 16384,
        '<!--' * 16384,
        '<a ' * 20000,
        widths,
        '[a](${'(' * 30000}',
        '`${'a' * 16383}`${'\uFDD0' * 16383}',
        '__${'x_' * 16000}',
      ]) {
        final watch = Stopwatch()..start();
        final result = markdownSummary(input, 560);
        watch.stop();
        expect(watch.elapsedMilliseconds, lessThan(1500), reason: input.substring(0, 12));
        expect(result.text.characters.length, lessThanOrEqualTo(560));
      }
    });

    test('reports more text past the limit without splitting a grapheme', () {
      final result = markdownSummary('${'👨‍👩‍👧‍👦' * 30}<!-- hidden -->', 10);
      expect(result.more, isTrue);
      expect(result.text, '👨‍👩‍👧‍👦' * 10);
    });
  });
}
