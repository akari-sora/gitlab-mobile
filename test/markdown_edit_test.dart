import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/workspace/markdown_edit.dart';

void main() {
  test('inline code block gains surrounding line boundaries', () {
    final edit = insertCodeBlock('beforeafter', 6, 6);
    expect(edit.text, 'before\n```\n\n```\nafter');
    expect(edit.base, 'before\n```\n'.length);
    expect(edit.extent, edit.base);
  });

  test('multiline code block keeps the selection inside the fences', () {
    const source = 'intro\nalpha\nbeta\nout';
    final start = source.indexOf('alpha');
    final edit = insertCodeBlock(source, start, start + 'alpha\nbeta'.length);
    expect(edit.text, 'intro\n```\nalpha\nbeta\n```\nout');
    expect(edit.text.substring(edit.base, edit.extent), 'alpha\nbeta');
  });

  test('cjk code block insertion stays on its own lines', () {
    final selected = insertCodeBlock('前文字後', 1, 3);
    expect(selected.text, '前\n```\n文字\n```\n後');
    expect(selected.text.substring(selected.base, selected.extent), '文字');
    final caret = insertCodeBlock('前後', 1, 1);
    expect(caret.text, '前\n```\n\n```\n後');
    expect(caret.base, '前\n```\n'.length);
    expect(caret.extent, caret.base);
  });

  test('code block already on its own line does not add extra breaks', () {
    final edit = insertCodeBlock('keep', 0, 4);
    expect(edit.text, '```\nkeep\n```');
    expect(edit.text.substring(edit.base, edit.extent), 'keep');
  });

  test('mention before existing text keeps a trailing delimiter', () {
    final edit = insertMention('world', 0, 0, 'reviewer');
    expect(edit.text, '@reviewer world');
    expect(edit.base, '@reviewer '.length);
    expect(edit.extent, edit.base);
    final typed = edit.text.replaceRange(edit.base, edit.extent, 'hi');
    expect(typed, '@reviewer hiworld');
    expect(typed.contains('@reviewerworld'), isFalse);
  });

  test('mention at the end leaves the caret after the trailing space', () {
    final edit = insertMention('hi', 2, 2, 'reviewer');
    expect(edit.text, 'hi @reviewer ');
    expect(edit.base, edit.text.length);
    final typed = edit.text.replaceRange(edit.base, edit.extent, 'next');
    expect(typed, 'hi @reviewer next');
  });

  test('insertQuickAction on empty string inserts command with trailing newline', () {
    final edit = insertQuickAction('', 0, 0, '/close');
    expect(edit.text, '/close\n');
    expect(edit.base, '/close\n'.length);
    expect(edit.extent, edit.base);
  });

  test('insertQuickAction mid-text prepends and appends newline', () {
    final edit = insertQuickAction('hello world', 5, 5, '/spend 1h');
    expect(edit.text, 'hello\n/spend 1h\n world');
    expect(edit.base, 'hello\n/spend 1h\n'.length);
    expect(edit.extent, edit.base);
  });

  test('insertQuickAction at line start only adds trailing newline', () {
    final edit = insertQuickAction('first\nsecond', 6, 6, '/ready');
    expect(edit.text, 'first\n/ready\nsecond');
    expect(edit.base, 'first\n/ready\n'.length);
    expect(edit.extent, edit.base);
  });

  test('extractQuickActions parses commands at line start and ignores inline slashes', () {
    const text = '''
/close
Some comment here
/spend 2h 30m
And visit http://gitlab.com/test or type a /slash in the middle
/label ~frontend
''';
    final actions = extractQuickActions(text);
    expect(actions, ['/close', '/spend', '/label']);
  });

  test('extractQuickActions follows GitLab: first column only, CR removed', () {
    // GitLab's extractor matches `^\/` after deleting `\r`
    // (lib/gitlab/quick_actions/extractor.rb), so an indented slash is text
    // and a lone CR joins two lines.
    expect(extractQuickActions('  /label ~frontend\n /close'), isEmpty);
    expect(extractQuickActions('a\r\n/merge'), ['/merge']);
    expect(extractQuickActions('a\n\r/merge'), ['/merge']);
    expect(extractQuickActions('x\r/merge'), isEmpty);
  });

  test('insertQuickAction replaces already typed slash or partial command on current line', () {
    final slashOnly = insertQuickAction('/', 1, 1, '/close');
    expect(slashOnly.text, '/close\n');
    expect(slashOnly.base, '/close\n'.length);

    final partial = insertQuickAction('/cl', 3, 3, '/close');
    expect(partial.text, '/close\n');
    expect(partial.base, '/close\n'.length);

    final multilinePartial = insertQuickAction('intro\n/sp', 9, 9, '/spend 1h');
    expect(multilinePartial.text, 'intro\n/spend 1h\n');
    expect(multilinePartial.base, 'intro\n/spend 1h\n'.length);
  });

  test('extractQuickActions ignores commands inside fenced code blocks and quotes', () {
    const text = '''
Here is some code:
```bash
/close
/spend 1h
```
And a quote:
> /reopen
Real action:
/label ~bug
~~~
/approve
~~~
''';
    final actions = extractQuickActions(text);
    expect(actions, ['/label']);
  });

  test('defaultQuickActions contains essential issue and merge request commands', () {
    expect(defaultQuickActions.any((a) => a.command == '/close'), isTrue);
    expect(defaultQuickActions.any((a) => a.command == '/reopen'), isTrue);
    expect(defaultQuickActions.any((a) => a.command == '/assign @me'), isTrue);
    expect(defaultQuickActions.any((a) => a.command == '/approve' && a.isMergeRequestOnly), isTrue);
    expect(defaultQuickActions.any((a) => a.command == '/ready' && a.isMergeRequestOnly), isTrue);
  });
}

