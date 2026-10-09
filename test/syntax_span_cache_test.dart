import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/syntax_highlighter.dart';

void main() {
  const baseStyle = TextStyle(fontFamily: 'monospace', fontSize: 13);

  test('reuses spans and evicts the least recently used row', () {
    final cache = SyntaxSpanCache(maxRows: 2, maxSourceCharacters: 128);

    final first = cache.highlight(
      0,
      'final first = 1;',
      extension: 'main.dart',
      isDark: false,
      baseStyle: baseStyle,
    );
    final second = cache.highlight(
      1,
      'final second = 2;',
      extension: 'main.dart',
      isDark: false,
      baseStyle: baseStyle,
    );
    final reused = cache.highlight(
      0,
      'final first = 1;',
      extension: 'main.dart',
      isDark: false,
      baseStyle: baseStyle,
    );
    expect(reused, same(first));

    cache.highlight(
      2,
      'final third = 3;',
      extension: 'main.dart',
      isDark: false,
      baseStyle: baseStyle,
    );
    final evicted = cache.highlight(
      1,
      'final second = 2;',
      extension: 'main.dart',
      isDark: false,
      baseStyle: baseStyle,
    );

    expect(evicted, isNot(same(second)));
    expect(cache.cachedRows, 2);
  });

  test('bounds cached source characters and skips oversized rows', () {
    final cache = SyntaxSpanCache(maxRows: 10, maxSourceCharacters: 7);
    cache.highlight(
      0,
      'aaaa',
      extension: 'main.dart',
      isDark: false,
      baseStyle: baseStyle,
    );
    cache.highlight(
      1,
      'bbbb',
      extension: 'main.dart',
      isDark: false,
      baseStyle: baseStyle,
    );

    expect(cache.cachedRows, 1);
    expect(cache.cachedSourceCharacters, 4);

    final oversized = cache.highlight(
      2,
      'x' * 2500,
      extension: 'main.dart',
      isDark: false,
      baseStyle: baseStyle,
    );
    expect(oversized.children, isNull);
    expect(cache.cachedRows, 1);
  });

  test('theme and base-style changes invalidate cached spans', () {
    final cache = SyntaxSpanCache();
    final light = cache.highlight(
      0,
      'class App {}',
      extension: 'main.dart',
      isDark: false,
      baseStyle: baseStyle,
    );
    final dark = cache.highlight(
      0,
      'class App {}',
      extension: 'main.dart',
      isDark: true,
      baseStyle: baseStyle,
    );
    final resized = cache.highlight(
      0,
      'class App {}',
      extension: 'main.dart',
      isDark: true,
      baseStyle: baseStyle.copyWith(fontSize: 14),
    );

    expect(dark, isNot(same(light)));
    expect(resized, isNot(same(dark)));
    expect(cache.cachedRows, 1);
  });

  test('clear drops all page-owned spans', () {
    final cache = SyntaxSpanCache();
    final before = cache.highlight(
      0,
      'final value = 1;',
      extension: 'main.dart',
      isDark: false,
      baseStyle: baseStyle,
    );

    cache.clear();

    final after = cache.highlight(
      0,
      'final value = 1;',
      extension: 'main.dart',
      isDark: false,
      baseStyle: baseStyle,
    );
    expect(after, isNot(same(before)));
    expect(cache.cachedRows, 1);
  });
}
