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
}
