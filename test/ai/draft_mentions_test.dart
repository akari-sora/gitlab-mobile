import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/draft_mentions.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:markdown/markdown.dart' as md;

void main() {
  test('result supports a const constructor', () {
    const result = DraftMentions(
      text: 'draft',
      mentions: ['victim'],
      neutralized: 2,
      references: 3,
    );

    expect(result.text, 'draft');
    expect(result.mentions, ['victim']);
    expect(result.neutralized, 2);
    expect(result.references, 3);
  });

  test('wraps a plain mention while preserving sentence punctuation', () {
    _expectDraft('hi @victim.', text: 'hi `@victim`.', neutralized: 1);
  });

  test('wraps all and here like other usernames', () {
    _expectDraft('@all @here', text: '`@all` `@here`', neutralized: 2);
  });

  test('wraps a whole group path and leaves trailing slash outside', () {
    _expectDraft(
      '@group/subgroup @group/sub/',
      text: '`@group/subgroup` `@group/sub`/',
      neutralized: 2,
    );
  });

  test('leaves all trailing dots, hyphens and slashes outside the span', () {
    _expectDraft(
      '@victim... @group/sub-./ @.',
      text: '`@victim`... `@group/sub`-./ `@`.',
      neutralized: 3,
    );
  });

  test('accepts the complete superset of username and group characters', () {
    _expectDraft(
      '@_user @.user @9 @group-name/sub_group.name',
      text: '`@_user` `@.user` `@9` `@group-name/sub_group.name`',
      neutralized: 4,
    );
  });

  for (final input in [
    '`@victim hello`',
    '`hello @victim`',
    '``hello ` @victim``',
    '`hello\n@victim`',
    '```\n@victim\n```',
    '~~~\n@victim\n~~~',
    '    @victim\n',
    '\t@victim\n',
  ]) {
    test('preserves existing code: ${input.replaceAll('\n', r'\n')}', () {
      _expectDraft(input);
    });
  }

  test('compares code as a multiset, including duplicate code text', () {
    _expectDraft(
      '`@victim` `@victim` @victim @victim',
      text: '`@victim` `@victim` `@victim` `@victim`',
      neutralized: 2,
    );
  });

  for (final input in ['`code`@victim', '@victim`code`']) {
    test('reports an unverified mention next to code: $input', () {
      _expectDraft(input, mentions: ['victim']);
    });
  }

  for (final input in ['Thanks `@victim', '@victim`']) {
    test('reports an unverified mention next to an unpaired backtick', () {
      _expectDraft(input, mentions: ['victim']);
    });
  }

  test('keeps an unverified mention while wrapping another safely', () {
    _expectDraft(
      '`code`@victim @other',
      text: '`code`@victim `@other`',
      mentions: ['victim'],
      neutralized: 1,
    );
  });

  for (final prefix in ['-', '.', '+', 'é']) {
    test('accepts the non-ASCII-word prefix $prefix', () {
      _expectDraft('$prefix@victim', text: '$prefix`@victim`', neutralized: 1);
    });
  }

  test('does not recognize emails or mentions after ASCII word characters', () {
    _expectDraft('mail user@example.com a@victim 1@victim _@victim');
  });

  test('wraps mentions in link text', () {
    _expectDraft(
      '[@victim](https://example.com)',
      text: '[`@victim`](https://example.com)',
      neutralized: 1,
    );
  });

  test('reports HTML block mentions when a code span cannot be verified', () {
    _expectDraft('<div>\n@victim\n</div>', mentions: ['victim']);
  });

  for (final entry in <String, List<String>>{
    '<div>\n&#64victim\n</div>': ['victim'],
    '<div>\n&#x40victim\n</div>': ['victim'],
    '<div>\n&#X40victim\n</div>': ['victim'],
    '<div>\n&commat;&fjlig;\n</div>': ['fj'],
    '<div>\nhi @foo&UnderBar;bar\n</div>': ['foo_bar'],
    '<div>\n&#64;victim\n</div>': ['victim'],
    '<div>\n@&#118;ictim\n</div>': ['victim'],
    '<div>\n&commat;all\n</div>': ['all'],
    '<div>\n&#64;group/subgroup\n</div>': ['group/subgroup'],
  }.entries) {
    test('decodes mentions in raw HTML: ${entry.key}', () {
      expect(_html5Mentions(entry.key), entry.value);
      _expectDraft(entry.key, mentions: entry.value);
    });
  }

  for (final entry in {
    '&amp;#64;victim': 1,
    '<div>&amp;#64;victim</div>': 1,
    '<div title="@alice">hello</div>': 0,
    '<div>@<span>victim</span></div>': 0,
  }.entries) {
    test(
      'the shared HTML5 rendering check finds no mention in ${entry.key}',
      () {
        expect(_html5Mentions(entry.key), isEmpty);
        _expectDraft(entry.key, references: entry.value);
      },
    );
  }

  test('matches each DOM text node separately and counts anchor text', () {
    const input =
        '<div>@foo<span>bar</span> x<b>@other</b> '
        '<a href="https://example.com/@attribute">@linked</a></div>';
    expect(_html5Mentions(input), ['foo', 'other', 'linked']);
    _expectDraft(input, mentions: ['foo', 'other', 'linked']);
  });

  test('uses rendered text boundaries across nested Markdown fragments', () {
    const input = '~~a_@victim~~';
    expect(_html5Mentions(input), isEmpty);
    _expectDraft(input, mentions: ['victim']);
    const rawCode = '<code>*@victim*</code>';
    expect(_html5Mentions(rawCode), isEmpty);
    // The fragment view conservatively reports raw HTML code even though the
    // shared HTML5 parser suppresses it. A verified Markdown span is safe.
    _expectDraft(rawCode, text: '<code>*`@victim`*</code>', neutralized: 1);
  });

  test('conservatively wraps or reports raw HTML code mentions', () {
    for (final input in [
      '<pre>@x</pre>',
      '<code>@x</code>',
      '<div><pre>@x</pre><code>@x</code></div>',
    ]) {
      expect(_html5Mentions(input), isEmpty);
      _expectDraft(input, keepNotifications: true, mentions: ['x']);
    }
    _expectDraft('<pre>@x</pre>', mentions: ['x']);
    _expectDraft('<code>@x</code>', text: '<code>`@x`</code>', neutralized: 1);
    _expectDraft('<div><pre>@x</pre><code>@x</code></div>', mentions: ['x']);
  });

  test('preserves first appearance across raw code and prose mentions', () {
    _expectDraft(
      '<code>@first</code> @second',
      keepNotifications: true,
      mentions: ['first', 'second'],
    );
  });

  test(
    'single-candidate fallback handles HTML5 text joined around raw tags',
    () {
      _expectDraft(
        '</pre># <dd></h1>@victim<td>x <span><sup>`<dl>'
        '<blockquote></kbd><blockquote><tt></i></i>',
        text:
            '</pre># <dd></h1>`@victim`<td>x <span><sup>`<dl>'
            '<blockquote></kbd><blockquote><tt></i></i>',
        neutralized: 1,
      );
    },
  );

  test('fallback requires each code span to remove exactly one mention', () {
    _expectDraft(
      'see <textarea> @victim and <div>@raw</div>',
      mentions: ['victim', 'raw'],
    );
  });

  test(
    'uses per-name maximum counts for wrapping and existing subtraction',
    () {
      _expectDraft(
        '<code>@victim</code> @victim @other',
        text: '<code>`@victim`</code> `@victim` `@other`',
        neutralized: 3,
      );
      _expectDraft(
        '@victim @victim',
        existing: '<code>@victim</code>',
        text: '`@victim` `@victim`',
        neutralized: 2,
      );
    },
  );

  // These fixed expectations cover libxml2's closing of code/pre containers;
  // the HTML5 rendering check below shares the implementation's parser and
  // regexp, so it cannot establish compatibility with the older tree builder.
  for (final input in [
    'Wrap the value in a <code> element.\n\nThanks @victim for the report.',
    'x <code>\n\n@victim',
    '<b><code>x</b>\n\n@victim',
    '<span><code>\n\n@victim',
    'x <code>\n\n- @victim',
    'x <code>\n\n> @victim',
    'x <code>\n\n# @victim',
    'x <code>\n\n<div>@victim</div>',
    for (final tag in ['dd', 'dt', 'li', 'table']) '<pre><$tag>@victim</$tag>',
  ]) {
    test('wraps or reports the libxml2 mention in $input', () {
      final result = analyzeDraftMentions(input);
      expect(
        result.neutralized > 0 || result.mentions.contains('victim'),
        isTrue,
      );
      expect(analyzeDraftMentions(input, keepNotifications: true).mentions, [
        'victim',
      ]);
    });
  }

  test('wraps or reports after an existing raw code opening', () {
    const existing = 'Use <code> here';
    const answer = 'cc @victim';
    final result = analyzeDraftMentions(answer, existing: existing);
    expect(
      result.neutralized > 0 || result.mentions.contains('victim'),
      isTrue,
    );
    _expectDraft(
      answer,
      existing: existing,
      keepNotifications: true,
      mentions: ['victim'],
    );
  });

  test('counts references in DOM text, excluding attributes and raw code', () {
    _expectDraft(
      '<div title="#1 !2">&num;3 <code>#4</code><pre>!5</pre>'
      '#<span>6</span> <a href="https://example.com/!7">!8</a></div>',
      references: 2,
    );
  });

  test('reports all encoded mentions after the wrapping candidate cap', () {
    final names = List.generate(51, (index) => 'user$index');
    final input = names.map((name) => '<div>&#64;$name</div>').join('\n');
    expect(_html5Mentions(input), names);
    _expectDraft(input, mentions: names);
  });

  test('does not count an encoded at sign as a numeric reference', () {
    _expectDraft('<div>&#64;</div>');
  });

  test('detects an encoded mention in a paragraph', () {
    final result = analyzeDraftMentions('&#64;victim');
    expect(result.neutralized + result.mentions.length, 1);
    expect(result.references, 0);
  });

  test('deduplicates remaining mentions in first appearance order', () {
    _expectDraft(
      '<div>\n@second @first @second @First\n</div>',
      mentions: ['second', 'first', 'First'],
    );
  });

  test('skips wrapping when there are more than 50 candidates', () {
    final names = List.generate(51, (index) => 'user$index');
    final input = names.map((name) => '@$name').join(' ');
    _expectDraft(input, mentions: names);
  });

  test('deduplicates mentions even when the candidate cap is exceeded', () {
    final input = List.filled(51, '@victim').join(' ');
    _expectDraft(input, mentions: ['victim']);
  });

  test('counts candidates inside code toward the cap', () {
    final input = '`${List.filled(50, '@hidden').join(' ')}` @victim #12';
    _expectDraft(input, mentions: ['victim'], references: 1);
  });

  test('still wraps exactly 50 candidates', () {
    final names = List.generate(50, (index) => 'user$index');
    _expectDraft(
      names.map((name) => '@$name').join(' '),
      text: names.map((name) => '`@$name`').join(' '),
      neutralized: 50,
    );
  });

  test('analyzes a 3990-character answer with 50 candidates promptly', () {
    final mentions = List.generate(50, (index) => '@user$index').join(' ');
    final input = '${'a' * (3990 - mentions.length - 1)} $mentions';
    expect(input.length, 3990);

    final stopwatch = Stopwatch()..start();
    final result = analyzeDraftMentions(input);
    stopwatch.stop();
    // ignore: avoid_print
    print(
      'benign prefix / 3990 characters / 50 candidates: '
      '${stopwatch.elapsedMicroseconds / 1000} ms (JIT)',
    );

    expect(result.neutralized, 50);
    expect(result.mentions, isEmpty);
    expect(_html5Mentions(result.text), isEmpty);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  final fiftyMentions = List.generate(50, (index) => '@user$index').join(' ');
  for (final entry in <String, (String, int)>{
    // 50 numbered names occupy 389 characters. Pad the separator to retain
    // both the requested 3,500-character run and the 3,990-character total.
    '50 mentions then 3500 x': (
      '$fiftyMentions${' ' * (3990 - fiftyMentions.length - 3500)}${'x' * 3500}',
      50,
    ),
    '10 mentions then 3900 x': (
      '${List.generate(10, (index) => '@user$index').join(' ')} ${'x' * 3900}',
      10,
    ),
    '6000 x then Z': ('${'x' * 6000}Z', 0),
  }.entries) {
    test('bounds analysis time for ${entry.key}', () {
      final (input, count) = entry.value;
      final stopwatch = Stopwatch()..start();
      final result = analyzeDraftMentions(input);
      stopwatch.stop();
      // ignore: avoid_print
      print(
        '${entry.key} / ${input.length} characters: '
        '${stopwatch.elapsedMicroseconds / 1000} ms (JIT)',
      );
      expect(result.neutralized, count);
      expect(result.mentions, isEmpty);
      expect(_html5Mentions(result.text), isEmpty);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)));
    });
  }

  test(
    'keepNotifications preserves text and reports every outside mention',
    () {
      _expectDraft(
        '@second @first @second `@hidden` @group/sub @all #12',
        mentions: ['second', 'first', 'group/sub', 'all'],
        references: 1,
        keepNotifications: true,
      );
    },
  );

  test('remaining mentions retain the specified superset match', () {
    // Punctuation stripping applies only to the inserted code span. Reporting
    // deliberately uses the same unmodified superset pattern as analysis.
    _expectDraft(
      '@victim. @group/sub/ @victim.',
      mentions: ['victim.', 'group/sub/'],
      keepNotifications: true,
    );
  });

  test('analyzes an answer against an unclosed existing fence', () {
    _expectDraft(
      'Fix:\n\n```\n@Override\npublic void run() {}\n```\nThanks',
      existing: 'Stack trace:\n```\nat Foo.bar()',
      text: 'Fix:\n\n```\n`@Override`\npublic void run() {}\n```\nThanks',
      neutralized: 1,
    );
    _expectDraft(
      'Fix:\n\n```\n@Override\npublic void run() {}\n```\nThanks',
      existing: 'Stack trace:\n```\nat Foo.bar()',
      keepNotifications: true,
      mentions: ['Override'],
    );
  });

  test('analyzes indented answer text after an existing list', () {
    _expectDraft(
      '    @Test\n    void works() {}',
      existing: '- first point',
      text: '    `@Test`\n    void works() {}',
      neutralized: 1,
    );
    _expectDraft(
      '    @Test\n    void works() {}',
      existing: '- first point',
      keepNotifications: true,
      mentions: ['Test'],
    );
  });

  test('subtracts mentions from the existing draft as a multiset', () {
    _expectDraft(
      'plain answer',
      existing: 'cc @alice',
      keepNotifications: true,
    );
  });

  test('subtracts existing references from the joined document', () {
    _expectDraft('see #2', existing: 'see #1', references: 1);
  });

  for (final keepNotifications in [false, true]) {
    for (final entry in {
      'Use the <code> tag.\n\nThis fixes #123 and closes !45.': 2,
      'x <code>\n\n[a](/g/p/-/issues/5)': 1,
      'x <code>\n\nSee https://gitlab.com/g/p/-/issues/5': 1,
    }.entries) {
      test(
        'counts libxml2 references after raw code '
        '(keepNotifications=$keepNotifications): ${entry.key}',
        () => _expectDraft(
          entry.key,
          keepNotifications: keepNotifications,
          references: entry.value,
        ),
      );
    }

    test(
      'counts references after an existing raw code opening '
      '(keepNotifications=$keepNotifications)',
      () => _expectDraft(
        'cc #123',
        existing: 'Use <code> here',
        keepNotifications: keepNotifications,
        references: 1,
      ),
    );

    test('subtracts the fragment reference baseline '
        '(keepNotifications=$keepNotifications)', () {
      const existing = 'Use <code> here.\n\nSee #1 and !2.';
      _expectDraft(
        'cc #123',
        existing: existing,
        keepNotifications: keepNotifications,
        references: 1,
      );
      _expectDraft(
        'plain answer',
        existing: existing,
        keepNotifications: keepNotifications,
      );
    });

    test(
      'subtracts each reference view before choosing the maximum '
      '(keepNotifications=$keepNotifications)',
      () => _expectDraft(
        '#123',
        existing: '<a href="/g/p/-/issues/5"><li><br>',
        keepNotifications: keepNotifications,
        references: 1,
      ),
    );

    test(
      'clamps references when a new link definition hides existing references '
      '(keepNotifications=$keepNotifications)',
      () => _expectDraft(
        '[a]: /g/p/-/issues/3',
        existing: '[#1 !2][a]',
        keepNotifications: keepNotifications,
      ),
    );
  }

  test('wraps an answer mention after a non-empty existing draft', () {
    _expectDraft(
      'hello @bob',
      existing: 'opening text',
      text: 'hello `@bob`',
      neutralized: 1,
    );
  });

  test('subtracts only matching existing mention occurrences', () {
    _expectDraft(
      '@alice @alice @bob',
      existing: '@alice',
      mentions: ['alice', 'bob'],
      keepNotifications: true,
    );
  });

  test('analyzes the joined draft after deleting bare carriage returns', () {
    const existing = 'log\r```';
    expect(_addedHtml5Mentions('@victim', existing: existing), ['victim']);
    _expectDraft(
      '@victim',
      existing: existing,
      text: '`@victim`',
      neutralized: 1,
    );
    _expectDraft(
      '@victim',
      existing: existing,
      keepNotifications: true,
      mentions: ['victim'],
    );
  });

  test('treats CRLF and LF existing fences identically', () {
    for (final existing in ['log\r\n```', 'log\n```']) {
      expect(_addedHtml5Mentions('@victim', existing: existing), isEmpty);
      _expectDraft('@victim', existing: existing);
      _expectDraft('@victim', existing: existing, keepNotifications: true);
    }
  });

  test('normalizes the existing baseline before subtracting its mentions', () {
    _expectDraft('plain answer', existing: '@al\rice #\r1');
    _expectDraft(
      '@alice @bob #2',
      existing: '@al\rice #\r1',
      mentions: ['alice', 'bob'],
      references: 1,
      keepNotifications: true,
    );
  });

  test('counts short and cross-project references without rewriting them', () {
    _expectDraft('#12 !34 group/project#12 project!34', references: 4);
  });

  test('counts a project-qualified reference immediately after a word', () {
    // issue#12 has the same shape as project#12, so it counts as one reference.
    _expectDraft('issue#12', references: 1);
  });

  test('counts each repeated reference occurrence', () {
    _expectDraft('#12 #12 project!34 project!34', references: 4);
  });

  test('counts issue, merge request and work item URL paths', () {
    _expectDraft(
      'https://gitlab.com/g/p/-/issues/5 '
      'https://gitlab.com/g/p/-/merge_requests/6 '
      'https://gitlab.example:8443/gitlab/g/p/-/work_items/7 '
      '/g/p/-/issues/8',
      references: 4,
    );
  });

  test(
    'does not mistake URL queries, fragments or other paths for references',
    () {
      _expectDraft(
        'https://example.com/?next=/-/issues/5#12 '
        'https://example.com/#/-/merge_requests/6 '
        'https://example.com/-/jobs/7 '
        'https://example.com/-/issues/8abc',
      );
    },
  );

  test('counts explicit link URLs without double-counting autolinks', () {
    _expectDraft(
      '[issue](https://gitlab.com/g/p/-/issues/5) '
      '<https://gitlab.com/g/p/-/merge_requests/6> '
      '[https://gitlab.com/g/p/-/work_items/7]'
      '(https://gitlab.com/g/p/-/work_items/7)',
      references: 3,
    );
  });

  for (final kind in ['issues', 'merge_requests', 'work_items']) {
    final href = '/g/p/-/$kind/123';
    test('counts each raw $kind anchor once and preserves Markdown counts', () {
      _expectDraft('<div><a href="$href">details</a></div>', references: 1);
      _expectDraft('<div><a href="$href">$href</a></div>', references: 1);
      _expectDraft('<div><a href="$href">#456 !789</a></div>', references: 1);
      _expectDraft(
        '<div><a href="$href">/g/p/-/issues/456</a></div>',
        references: 1,
      );
      _expectDraft('<a href="$href">**#456**</a>', references: 1);
      for (final prefix in ['', 'x <code>\n\n']) {
        _expectDraft(
          '$prefix<a href="$href">**#456 !789** $href</a> #321',
          references: 2,
        );
        _expectDraft('$prefix[**#456 !789** $href]($href) #321', references: 2);
        _expectDraft(
          '$prefix<a href="$href">**#456**</a> '
          '<a href="$href">*!789*</a>',
          references: 2,
        );
      }
      _expectDraft(
        '<div><a href="$href">details</a><a href="$href">again</a></div>',
        references: 2,
      );
      _expectDraft('[details]($href)', references: 1);
      _expectDraft('[$href]($href)', references: 1);
      _expectDraft(
        '[details]($href)\n\n<div><a href="$href">details</a></div>',
        references: 2,
      );
      _expectDraft(
        '<div><a href="$href">answer</a></div>',
        existing: '<div><a href="$href">existing</a></div>',
        references: 1,
      );
      _expectDraft('<code><a href="$href">details</a></code>');
      _expectDraft('<pre><a href="$href">details</a></pre>');
      _expectDraft('`<a href="$href">details</a>`');
    });
  }

  test('a Markdown link ends a raw anchor the whole-DOM view cannot see', () {
    // The unclosed raw code swallows both anchors in the whole-DOM view, so
    // only the fragment view counts the Markdown link and the reference
    // after it. Without ending the raw-anchor context at the Markdown link,
    // the trailing reference is discounted as inside the raw anchor.
    _expectDraft(
      '<code><a href="/g/p/-/issues/5">[x](/g/p/-/issues/6)!8',
      references: 2,
    );
  });

  test('raw anchor reference paths exclude queries and unrelated attributes', () {
    _expectDraft(
      '<div title="/g/p/-/issues/123">'
      '<a href="/?next=/-/issues/123">query</a>'
      '<a href="/g/p/-/issues/123abc">suffix</a>'
      '<a href="/g/p/-/jobs/123">job</a></div>',
    );
    _expectDraft(
      '<div><a href="https://gitlab.example:8443/gitlab/g/p/-/issues/123?a=1&amp;b=2">'
      'details</a></div>',
      references: 1,
    );
  });

  for (final input in [
    'www.gitlab.com/g/p/-/issues/5',
    'https://gitlab.com/g/p/-/issues/5?a=1&b=2',
    '<https://gitlab.com/g/p/-/issues/5?a=1&b=2>',
    '[https://gitlab.com/g/p/-/issues/5?a=1&b=2]'
        '(https://gitlab.com/g/p/-/issues/5?a=1&b=2)',
  ]) {
    test('counts a URL once despite label and href representation changes', () {
      _expectDraft(input, references: 1);
    });
  }

  const references =
      '#12 !34 group/project#12 project!34 '
      'https://gitlab.com/g/p/-/issues/5 '
      'https://gitlab.com/g/p/-/merge_requests/6 '
      'https://gitlab.com/g/p/-/work_items/7';
  for (final input in [
    '`$references`',
    '```\n$references\n```',
    '~~~\n$references\n~~~',
    '    $references\n',
  ]) {
    test('ignores every reference inside code', () {
      _expectDraft(input);
    });
  }

  test('counts references in returned text alongside neutralized mentions', () {
    _expectDraft(
      '@victim #12 `!34` @group/project#56',
      text: '`@victim` #12 `!34` `@group/project`#56',
      neutralized: 2,
      references: 2,
    );
  });

  test('normalizes CRLF then deletes bare CR while preserving whitespace', () {
    _expectDraft(
      ' \r\nhi @victim.\r\n ',
      text: ' \nhi `@victim`.\n ',
      neutralized: 1,
    );
    for (final input in ['', '  ', '\n\n']) {
      _expectDraft(input);
    }
    for (final entry in {'\r': '', '\r\n': '\n', ' a\r b ': ' a b '}.entries) {
      _expectDraft(entry.key, text: entry.value);
      _expectDraft(entry.key, text: entry.value, keepNotifications: true);
    }
    _expectDraft('@vic\rtim', text: '`@victim`', neutralized: 1);
    _expectDraft(
      '@vic\rtim',
      text: '@victim',
      mentions: ['victim'],
      keepNotifications: true,
    );
  });

  test('generated Markdown covers shared HTML5 mentions and preserves code', () {
    final random = Random(0x6a3);
    final existingRandom = Random(0x6a3c);
    const parts = [
      '@',
      '@victim',
      '@group/sub',
      '@all',
      '`',
      '``',
      '```',
      '~',
      '~~~',
      '\n',
      '\r',
      '\r\n',
      'log\r```',
      '[',
      ']',
      '(',
      ')',
      '<',
      '>',
      '<div>',
      '</div>',
      '&#64;',
      '&#64victim',
      '&#x40victim',
      '&#X40victim',
      '&#x40;',
      '&#118;',
      '&commat;',
      '&fjlig;',
      '&UnderBar;',
      '&amp;#64;victim',
      '&amp;',
      '&lt;',
      '&gt;',
      '&quot;',
      '&apos;',
      '&sol;',
      '&period;',
      '&lowbar;',
      '&hyphen;',
      '&dash;',
      '&num;',
      '&excl;',
      '&colon;',
      '&unknown;',
      'a',
      'z',
      '_',
      '.',
      '-',
      '/',
      ' ',
      '#12',
      '!34',
    ];

    for (var index = 0; index < 600; index++) {
      final input = List.generate(
        4 + random.nextInt(40),
        (_) => parts[random.nextInt(parts.length)],
      ).join();
      final existing = List.generate(
        existingRandom.nextInt(12),
        (_) => parts[existingRandom.nextInt(parts.length)],
      ).join();
      for (final prefix in ['', existing]) {
        final result = analyzeDraftMentions(input, existing: prefix);
        final reparsed = analyzeDraftMentions(
          result.text,
          existing: prefix,
          keepNotifications: true,
        );
        final repeated = analyzeDraftMentions(result.text, existing: prefix);
        final reason =
            'generated case $index: '
            'existing=${prefix.replaceAll('\r', r'\r').replaceAll('\n', r'\n')}, '
            'answer=${input.replaceAll('\r', r'\r').replaceAll('\n', r'\n')}';

        expect(reparsed.text, result.text, reason: reason);
        expect(reparsed.mentions, result.mentions, reason: reason);
        expect(reparsed.neutralized, 0, reason: reason);
        expect(reparsed.references, result.references, reason: reason);
        expect(repeated.mentions, result.mentions, reason: reason);
        expect(
          result.mentions,
          containsAll(_addedHtml5Mentions(result.text, existing: prefix)),
          reason: reason,
        );
        final normalizedPrefix = prefix
            .replaceAll('\r\n', '\n')
            .replaceAll('\r', '');
        final normalized = input.replaceAll('\r\n', '\n').replaceAll('\r', '');
        String joined(String answer) =>
            normalizedPrefix.isEmpty ? answer : '$normalizedPrefix\n\n$answer';
        final beforeCode = _codeTexts(joined(normalized));
        final afterCode = _codeTexts(joined(result.text));
        for (final value in beforeCode.toSet()) {
          expect(
            afterCode.where((text) => text == value).length,
            greaterThanOrEqualTo(
              beforeCode.where((text) => text == value).length,
            ),
            reason: reason,
          );
        }
        expect(
          afterCode.length,
          beforeCode.length + result.neutralized,
          reason: reason,
        );
      }
    }
  });
}

void _expectDraft(
  String input, {
  String? text,
  List<String> mentions = const [],
  int neutralized = 0,
  int references = 0,
  bool keepNotifications = false,
  String existing = '',
}) {
  final result = analyzeDraftMentions(
    input,
    keepNotifications: keepNotifications,
    existing: existing,
  );
  expect(result.text, text ?? input);
  expect(result.mentions, mentions);
  expect(result.neutralized, neutralized);
  expect(
    result.mentions,
    containsAll(_addedHtml5Mentions(result.text, existing: existing)),
  );
  expect(
    result.references,
    references,
    reason: md.markdownToHtml(
      result.text,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    ),
  );
}

// A rendering consistency check using the same HTML5 parser and regexp as the
// analyzer. The fixed libxml2 cases above supply separate expected outcomes.
List<String> _html5Mentions(String text) {
  final names = <String>[];
  final pattern = RegExp(r'(?<![A-Za-z0-9_])@([A-Za-z0-9_.][A-Za-z0-9_.\-/]*)');
  void visit(dom.Node node) {
    if (node is dom.Element &&
        (node.localName == 'code' || node.localName == 'pre')) {
      return;
    }
    if (node is dom.Text) {
      names.addAll(pattern.allMatches(node.data).map((match) => match[1]!));
    }
    for (final child in node.nodes) {
      visit(child);
    }
  }

  final rendered = md.markdownToHtml(
    text.replaceAll('\r\n', '\n').replaceAll('\r', ''),
    extensionSet: md.ExtensionSet.gitHubFlavored,
  );
  visit(html.parseFragment(rendered));
  return names;
}

List<String> _addedHtml5Mentions(String text, {String existing = ''}) {
  final prefix = existing.replaceAll('\r\n', '\n').replaceAll('\r', '');
  final baseline = _html5Mentions(prefix);
  final joined = prefix.isEmpty ? text : '$prefix\n\n$text';
  final added = <String>{};
  for (final name in _html5Mentions(joined)) {
    if (!baseline.remove(name)) added.add(name);
  }
  return added.toList();
}

List<String> _codeTexts(String text) {
  final result = <String>[];
  void visit(md.Node node) {
    if (node is! md.Element) return;
    if (node.tag == 'code') result.add(node.textContent);
    for (final child in node.children ?? const <md.Node>[]) {
      visit(child);
    }
  }

  for (final node in md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
  ).parse(text)) {
    visit(node);
  }
  return result;
}
