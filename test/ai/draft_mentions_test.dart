import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/draft_mentions.dart';
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

  test('does not normalize carriage returns or trim whitespace', () {
    _expectDraft(
      ' \r\nhi @victim.\r\n ',
      text: ' \r\nhi `@victim`.\r\n ',
      neutralized: 1,
    );
    for (final input in ['', '  ', '\r', '\r\n', '\n\n', ' a\r b ']) {
      _expectDraft(input);
    }
  });

  test('generated Markdown never leaves a mention unreported', () {
    final random = Random(0x6a3);
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
      '[',
      ']',
      '(',
      ')',
      '<',
      '>',
      '<div>',
      '</div>',
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
      final result = analyzeDraftMentions(input);
      final reparsed = analyzeDraftMentions(
        result.text,
        keepNotifications: true,
      );
      final repeated = analyzeDraftMentions(result.text);
      final reason = 'generated case $index: ${input.replaceAll('\n', r'\n')}';

      expect(reparsed.text, result.text, reason: reason);
      expect(reparsed.mentions, result.mentions, reason: reason);
      expect(reparsed.neutralized, 0, reason: reason);
      expect(reparsed.references, result.references, reason: reason);
      expect(repeated.mentions, result.mentions, reason: reason);
      expect(result.mentions, _outsideMentions(result.text), reason: reason);
      final beforeCode = _codeTexts(input);
      final afterCode = _codeTexts(result.text);
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
  });
}

void _expectDraft(
  String input, {
  String? text,
  List<String> mentions = const [],
  int neutralized = 0,
  int references = 0,
  bool keepNotifications = false,
}) {
  final result = analyzeDraftMentions(
    input,
    keepNotifications: keepNotifications,
  );
  expect(result.text, text ?? input);
  expect(result.mentions, mentions);
  expect(result.neutralized, neutralized);
  expect(
    result.references,
    references,
    reason: md.markdownToHtml(
      result.text,
      extensionSet: md.ExtensionSet.gitHubFlavored,
    ),
  );
}

List<String> _outsideMentions(String text) {
  final names = <String>{};
  final pattern = RegExp(r'(?<![A-Za-z0-9_])@([A-Za-z0-9_.][A-Za-z0-9_.\-/]*)');
  void visit(md.Node node) {
    if (node is md.Element) {
      if (node.tag == 'code' || node.tag == 'pre') return;
      for (final child in node.children ?? const <md.Node>[]) {
        visit(child);
      }
    } else if (node is md.Text) {
      names.addAll(pattern.allMatches(node.text).map((match) => match[1]!));
    }
  }

  for (final node in md.Document(
    extensionSet: md.ExtensionSet.gitHubFlavored,
  ).parse(text)) {
    visit(node);
  }
  return names.toList();
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
