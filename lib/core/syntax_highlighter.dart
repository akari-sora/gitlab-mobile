import 'package:flutter/material.dart';

/// 輕量純 Dart 語法著色器
///
/// 無需巨型外部套件或 WebView，支援常用檔案類型的離線語法分詞與樣式渲染。
/// 支援 Dart, YAML, JSON, Python, Shell, Markdown 等常見格式。
class SyntaxHighlighter {
  const SyntaxHighlighter._();

  static const _dartKeywords = {
    'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch',
    'class', 'const', 'continue', 'covariant', 'default', 'deferred', 'do',
    'dynamic', 'else', 'enum', 'export', 'extends', 'extension', 'external',
    'factory', 'false', 'final', 'finally', 'for', 'function', 'get', 'hide',
    'if', 'implements', 'import', 'in', 'interface', 'is', 'late', 'library',
    'mixin', 'new', 'null', 'on', 'operator', 'part', 'required', 'rethrow',
    'return', 'set', 'show', 'static', 'super', 'switch', 'sync', 'this',
    'throw', 'true', 'try', 'typedef', 'var', 'void', 'while', 'with', 'yield',
    'int', 'double', 'String', 'bool', 'List', 'Map', 'Set', 'Future', 'Stream',
    'Widget', 'BuildContext', 'State', 'StatefulWidget', 'StatelessWidget',
  };

  static const _pyKeywords = {
    'and', 'as', 'assert', 'async', 'await', 'break', 'class', 'continue',
    'def', 'del', 'elif', 'else', 'except', 'False', 'finally', 'for',
    'from', 'global', 'if', 'import', 'in', 'is', 'lambda', 'None',
    'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'True', 'try',
    'while', 'with', 'yield', 'self',
  };

  static const _shKeywords = {
    'if', 'then', 'else', 'elif', 'fi', 'case', 'esac', 'for', 'while',
    'until', 'do', 'done', 'in', 'function', 'select', 'time', 'echo',
    'exit', 'export', 'source', 'set', 'unset', 'read', 'cd', 'pwd',
  };

  static const _yamlKeywords = {
    'true', 'false', 'yes', 'no', 'null', '~', 'TRUE', 'FALSE',
  };

  static const _jsonKeywords = {
    'true', 'false', 'null',
  };

  /// 根據副檔名取得標準語言識別碼
  static String detectLanguage(String filePath) {
    final lower = filePath.toLowerCase();
    final dot = lower.lastIndexOf('.');
    if (dot == -1) return '';
    final ext = lower.substring(dot + 1);
    switch (ext) {
      case 'dart':
        return 'dart';
      case 'yaml':
      case 'yml':
        return 'yaml';
      case 'json':
        return 'json';
      case 'py':
      case 'python':
        return 'python';
      case 'sh':
      case 'bash':
      case 'zsh':
        return 'shell';
      case 'md':
      case 'markdown':
        return 'markdown';
      case 'js':
      case 'jsx':
      case 'ts':
      case 'tsx':
        return 'javascript';
      default:
        return ext;
    }
  }

  /// 為單行程式碼生成高亮 TextSpan
  static TextSpan highlightLine(
    String line, {
    required String extension,
    required bool isDark,
    TextStyle? baseStyle,
  }) {
    if (line.isEmpty) {
      return TextSpan(text: '', style: baseStyle);
    }

    // 防護超長行（大於 2000 字元），避免複雜正則運算卡頓
    if (line.length > 2000) {
      return TextSpan(text: line, style: baseStyle);
    }

    try {
      final lang = detectLanguage(extension.contains('.') ? extension : '.$extension');
      final spans = <TextSpan>[];

      // 調色盤（深淺色自適應）
      final commentColor = isDark ? const Color(0xFF8B949E) : const Color(0xFF6A737D);
      final stringColor = isDark ? const Color(0xFFA5D6FF) : const Color(0xFF032F62);
      final keywordColor = isDark ? const Color(0xFFFF7B72) : const Color(0xFFD73A49);
      final numberColor = isDark ? const Color(0xFF79C0FF) : const Color(0xFF005CC5);
      final keyColor = isDark ? const Color(0xFF7EE787) : const Color(0xFF22863A);

      switch (lang) {
        case 'dart':
        case 'javascript':
          _tokenizeCStyle(line, spans, baseStyle, commentColor, stringColor, keywordColor, numberColor, _dartKeywords);
          break;
        case 'python':
          _tokenizePython(line, spans, baseStyle, commentColor, stringColor, keywordColor, numberColor);
          break;
        case 'yaml':
          _tokenizeYaml(line, spans, baseStyle, commentColor, stringColor, keyColor, numberColor);
          break;
        case 'json':
          _tokenizeJson(line, spans, baseStyle, stringColor, keyColor, numberColor, keywordColor);
          break;
        case 'shell':
          _tokenizeShell(line, spans, baseStyle, commentColor, stringColor, keywordColor);
          break;
        case 'markdown':
          _tokenizeMarkdown(line, spans, baseStyle, keywordColor, stringColor, commentColor);
          break;
        default:
          spans.add(TextSpan(text: line, style: baseStyle));
      }

      return TextSpan(children: spans, style: baseStyle);
    } catch (_) {
      // 任何例外保證 fail-soft
      return TextSpan(text: line, style: baseStyle);
    }
  }

  static void _tokenizeCStyle(
    String line,
    List<TextSpan> spans,
    TextStyle? base,
    Color commentCol,
    Color stringCol,
    Color kwCol,
    Color numCol,
    Set<String> keywords,
  ) {
    // 檢查整行單行註釋 //
    final commentIdx = line.indexOf('//');
    String codePart = line;
    String? commentPart;

    if (commentIdx != -1) {
      // 確保不是在字串內部
      var inSingle = false;
      var inDouble = false;
      var found = -1;
      for (var i = 0; i < line.length - 1; i++) {
        final c = line[i];
        if (c == "'" && !inDouble) inSingle = !inSingle;
        if (c == '"' && !inSingle) inDouble = !inDouble;
        if (!inSingle && !inDouble && c == '/' && line[i + 1] == '/') {
          found = i;
          break;
        }
      }
      if (found != -1) {
        codePart = line.substring(0, found);
        commentPart = line.substring(found);
      }
    }

    _tokenizeGeneric(codePart, spans, base, stringCol, kwCol, numCol, keywords);

    if (commentPart != null) {
      spans.add(TextSpan(
        text: commentPart,
        style: (base ?? const TextStyle()).copyWith(color: commentCol, fontStyle: FontStyle.italic),
      ));
    }
  }

  static void _tokenizePython(
    String line,
    List<TextSpan> spans,
    TextStyle? base,
    Color commentCol,
    Color stringCol,
    Color kwCol,
    Color numCol,
  ) {
    // 檢查 # 註釋
    var inSingle = false;
    var inDouble = false;
    var found = -1;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == "'" && !inDouble) inSingle = !inSingle;
      if (c == '"' && !inSingle) inDouble = !inDouble;
      if (!inSingle && !inDouble && c == '#') {
        found = i;
        break;
      }
    }

    final codePart = found != -1 ? line.substring(0, found) : line;
    final commentPart = found != -1 ? line.substring(found) : null;

    _tokenizeGeneric(codePart, spans, base, stringCol, kwCol, numCol, _pyKeywords);

    if (commentPart != null) {
      spans.add(TextSpan(
        text: commentPart,
        style: (base ?? const TextStyle()).copyWith(color: commentCol, fontStyle: FontStyle.italic),
      ));
    }
  }

  static void _tokenizeShell(
    String line,
    List<TextSpan> spans,
    TextStyle? base,
    Color commentCol,
    Color stringCol,
    Color kwCol,
  ) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('#')) {
      spans.add(TextSpan(
        text: line,
        style: (base ?? const TextStyle()).copyWith(color: commentCol, fontStyle: FontStyle.italic),
      ));
      return;
    }
    _tokenizeGeneric(line, spans, base, stringCol, kwCol, null, _shKeywords);
  }

  static void _tokenizeYaml(
    String line,
    List<TextSpan> spans,
    TextStyle? base,
    Color commentCol,
    Color stringCol,
    Color keyCol,
    Color numCol,
  ) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('#')) {
      spans.add(TextSpan(
        text: line,
        style: (base ?? const TextStyle()).copyWith(color: commentCol, fontStyle: FontStyle.italic),
      ));
      return;
    }

    // key: value 模式
    final colonIdx = line.indexOf(':');
    if (colonIdx != -1) {
      final keyPart = line.substring(0, colonIdx);
      final rest = line.substring(colonIdx);

      spans.add(TextSpan(
        text: keyPart,
        style: (base ?? const TextStyle()).copyWith(color: keyCol, fontWeight: FontWeight.w600),
      ));
      _tokenizeGeneric(rest, spans, base, stringCol, null, numCol, _yamlKeywords);
      return;
    }

    _tokenizeGeneric(line, spans, base, stringCol, null, numCol, _yamlKeywords);
  }

  static void _tokenizeJson(
    String line,
    List<TextSpan> spans,
    TextStyle? base,
    Color stringCol,
    Color keyCol,
    Color numCol,
    Color kwCol,
  ) {
    // 檢查是否包含 "key":
    final colonIdx = line.indexOf(':');
    if (colonIdx != -1) {
      final keyPart = line.substring(0, colonIdx);
      final rest = line.substring(colonIdx);

      if (keyPart.contains('"')) {
        final firstQuote = keyPart.indexOf('"');
        final lastQuote = keyPart.lastIndexOf('"');
        if (firstQuote != -1 && lastQuote > firstQuote) {
          if (firstQuote > 0) {
            spans.add(TextSpan(text: keyPart.substring(0, firstQuote), style: base));
          }
          spans.add(TextSpan(
            text: keyPart.substring(firstQuote, lastQuote + 1),
            style: (base ?? const TextStyle()).copyWith(color: keyCol, fontWeight: FontWeight.w500),
          ));
          if (lastQuote + 1 < keyPart.length) {
            spans.add(TextSpan(text: keyPart.substring(lastQuote + 1), style: base));
          }
          _tokenizeGeneric(rest, spans, base, stringCol, kwCol, numCol, _jsonKeywords);
          return;
        }
      }
    }

    _tokenizeGeneric(line, spans, base, stringCol, kwCol, numCol, _jsonKeywords);
  }

  static void _tokenizeMarkdown(
    String line,
    List<TextSpan> spans,
    TextStyle? base,
    Color headerCol,
    Color codeCol,
    Color quoteCol,
  ) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('#')) {
      spans.add(TextSpan(
        text: line,
        style: (base ?? const TextStyle()).copyWith(color: headerCol, fontWeight: FontWeight.bold),
      ));
      return;
    }
    if (trimmed.startsWith('>')) {
      spans.add(TextSpan(
        text: line,
        style: (base ?? const TextStyle()).copyWith(color: quoteCol, fontStyle: FontStyle.italic),
      ));
      return;
    }
    _tokenizeGeneric(line, spans, base, codeCol, null, null, const {});
  }

  static void _tokenizeGeneric(
    String code,
    List<TextSpan> spans,
    TextStyle? base,
    Color? stringCol,
    Color? kwCol,
    Color? numCol,
    Set<String> keywords,
  ) {
    final tokenRegex = RegExp(
      r'''("[^"\\]*(?:\\.[^"\\]*)*"|'[^'\\]*(?:\\.[^'\\]*)*'|\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b|\b[a-zA-Z_]\w*\b|[^"'\s\w]+|\s+)''',
    );

    final matches = tokenRegex.allMatches(code);
    if (matches.isEmpty) {
      if (code.isNotEmpty) {
        spans.add(TextSpan(text: code, style: base));
      }
      return;
    }

    for (final m in matches) {
      final token = m.group(0)!;
      if (token.startsWith('"') || token.startsWith("'")) {
        spans.add(TextSpan(
          text: token,
          style: (base ?? const TextStyle()).copyWith(color: stringCol),
        ));
      } else if (keywords.contains(token)) {
        spans.add(TextSpan(
          text: token,
          style: (base ?? const TextStyle()).copyWith(color: kwCol, fontWeight: FontWeight.w600),
        ));
      } else if (numCol != null && RegExp(r'^\d').hasMatch(token)) {
        spans.add(TextSpan(
          text: token,
          style: (base ?? const TextStyle()).copyWith(color: numCol),
        ));
      } else {
        spans.add(TextSpan(text: token, style: base));
      }
    }
  }
}
