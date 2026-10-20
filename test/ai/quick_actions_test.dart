import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/quick_actions.dart';

// Representative executable inputs from GitLab's extractor spec at snapshot
// 8fcba17f7e7118a8e9682d5f71c303bf60746e08 (file last changed at
// aa66b93027f52d94b3efb3b15bd5af923c0e1f6d):
// https://gitlab.com/gitlab-org/gitlab/-/blob/8fcba17f7e7118a8e9682d5f71c303bf60746e08/spec/lib/gitlab/quick_actions/extractor_spec.rb
const _upstreamExecutableInputs = [
  '/reopen\nworld',
  'hello\n/reopen\nworld',
  'hello\n/reopen',
  '/assign @joe / @jane\nworld',
  'hello\n/label ~foo ~"bar baz" label\nworld',
  'hello\n/PoWer @user.name %9.10 ~"bar baz.2"\nworld',
  '<!-- this is a comment -->\n\n/label ~bug\n\n<p>\n</p>',
];

void main() {
  test(
    'normalizes GitLab CR handling and neutralizes every column-zero slash',
    () {
      final cases = <String, String>{
        '/merge': ' /merge',
        'ok\n/merge': 'ok\n /merge',
        'a\r\n/merge': 'a\n /merge',
        'a\n\r/merge': 'a\n /merge',
        'x\r/merge': 'x/merge',
        '/title Fix `foo`': ' /title Fix `foo`',
        '/one\n/two': ' /one\n /two',
      };

      for (final entry in cases.entries) {
        expect(neutralizeForGitLabDraft(entry.key), entry.value);
      }
    },
  );

  test('does not depend on Markdown structure', () {
    const input =
        '```\n/usr/bin/env\n```\n'
        '~~~\n/merge\n~~~\n'
        '> /quoted\n'
        '<div>\n/html\n</div>\n'
        '    /indented\n'
        '- /listed\n'
        ' /already-indented\n'
        '\u200b/zero-width';

    expect(
      neutralizeForGitLabDraft(input),
      '```\n /usr/bin/env\n```\n'
      '~~~\n /merge\n~~~\n'
      '> /quoted\n'
      '<div>\n /html\n</div>\n'
      '    /indented\n'
      '- /listed\n'
      ' /already-indented\n'
      '\u200b/zero-width',
    );
  });

  test(
    'preserves Unicode line separators because GitLab keys only on newline',
    () {
      const input = 'before\u2028/merge\u2029/close';

      expect(neutralizeForGitLabDraft(input), input);
    },
  );

  test('postcondition holds for a broad synthetic extractor corpus', () {
    final corpus = <String>[
      '',
      '\n',
      '\r',
      '\r\n',
      '/assign @user',
      'text\n/approve\n/merge',
      '`/merge`\n/close',
      '```unclosed\n/rebase',
      '    ```\n/squash\n    ```',
      '<!-- /merge -->\n/label ~bug',
    ];

    for (final value in corpus) {
      final result = neutralizeForGitLabDraft(value);
      expect(
        result.split('\n').any((line) => line.startsWith('/')),
        isFalse,
        reason: value,
      );
    }
  });

  test('neutralizes representative upstream executable inputs', () {
    for (final input in _upstreamExecutableInputs) {
      final result = neutralizeForGitLabDraft(input);

      expect(
        result.split('\n').any((line) => line.startsWith('/')),
        isFalse,
        reason: input,
      );
      expect(result, isNot(input), reason: input);
    }
  });
}
