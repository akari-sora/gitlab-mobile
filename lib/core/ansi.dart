import 'dart:ui' show Brightness, Color;
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/material.dart'
    show FontStyle, FontWeight, TextDecoration, TextSpan, TextStyle;

/// ANSI color representation supporting standard 16 colors, 256-color palette,
/// and 24-bit RGB truecolor, with theme-aware brightness contrast adaptation.
enum AnsiColorType { standard, color256, rgb }

@immutable
final class AnsiColor {
  const AnsiColor.standard(this.index)
      : type = AnsiColorType.standard,
        r = 0,
        g = 0,
        b = 0;

  const AnsiColor.color256(this.index)
      : type = AnsiColorType.color256,
        r = 0,
        g = 0,
        b = 0;

  const AnsiColor.rgb(this.r, this.g, this.b)
      : type = AnsiColorType.rgb,
        index = -1;

  final AnsiColorType type;
  final int index;
  final int r, g, b;

  Color toColor(Brightness brightness) {
    switch (type) {
      case AnsiColorType.standard:
        return _standardColor(index, brightness);
      case AnsiColorType.color256:
        return _color256(index, brightness);
      case AnsiColorType.rgb:
        return Color.fromARGB(
          255,
          r.clamp(0, 255),
          g.clamp(0, 255),
          b.clamp(0, 255),
        );
    }
  }

  static Color _standardColor(int idx, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    switch (idx) {
      case 0: // Black
        return dark ? const Color(0xFF6C7086) : const Color(0xFF24292E);
      case 1: // Red
        return dark ? const Color(0xFFF38BA8) : const Color(0xFFD73A49);
      case 2: // Green
        return dark ? const Color(0xFFA6E3A1) : const Color(0xFF22863A);
      case 3: // Yellow
        return dark ? const Color(0xFFF9E2AF) : const Color(0xFFB08800);
      case 4: // Blue
        return dark ? const Color(0xFF89B4FA) : const Color(0xFF0366D6);
      case 5: // Magenta
        return dark ? const Color(0xFFF5C2E7) : const Color(0xFF6F42C1);
      case 6: // Cyan
        return dark ? const Color(0xFF94E2D5) : const Color(0xFF1B7C83);
      case 7: // White
        return dark ? const Color(0xFFCDD6F4) : const Color(0xFF6A737D);
      case 8: // Bright Black (Gray)
        return dark ? const Color(0xFF9399B2) : const Color(0xFF586069);
      case 9: // Bright Red
        return dark ? const Color(0xFFEBA0AC) : const Color(0xFFCB2431);
      case 10: // Bright Green
        return dark ? const Color(0xFF89DCEB) : const Color(0xFF28A745);
      case 11: // Bright Yellow
        return dark ? const Color(0xFFF9E2AF) : const Color(0xFFDBAB09);
      case 12: // Bright Blue
        return dark ? const Color(0xFF74C7EC) : const Color(0xFF2188FF);
      case 13: // Bright Magenta
        return dark ? const Color(0xFFCBA6F7) : const Color(0xFF8A63D2);
      case 14: // Bright Cyan
        return dark ? const Color(0xFF89DCEB) : const Color(0xFF3192AA);
      case 15: // Bright White
        return dark ? const Color(0xFFBAC2DE) : const Color(0xFF24292E);
      default:
        return dark ? const Color(0xFFCDD6F4) : const Color(0xFF24292E);
    }
  }

  static Color _color256(int idx, Brightness brightness) {
    if (idx < 16) {
      return _standardColor(idx, brightness);
    }
    if (idx >= 16 && idx <= 231) {
      final n = idx - 16;
      final r = (n ~/ 36) % 6;
      final g = (n ~/ 6) % 6;
      final b = n % 6;
      int step(int val) => val == 0 ? 0 : 55 + val * 40;
      return Color.fromARGB(255, step(r), step(g), step(b));
    }
    if (idx >= 232 && idx <= 255) {
      final gray = 8 + (idx - 232) * 10;
      return Color.fromARGB(255, gray, gray, gray);
    }
    return _standardColor(7, brightness);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnsiColor &&
          type == other.type &&
          index == other.index &&
          r == other.r &&
          g == other.g &&
          b == other.b;

  @override
  int get hashCode => Object.hash(type, index, r, g, b);
}

/// SGR graphic rendition attributes.
@immutable
final class AnsiStyle {
  const AnsiStyle({
    this.foreground,
    this.background,
    this.bold = false,
    this.dim = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.inverse = false,
  });

  final AnsiColor? foreground;
  final AnsiColor? background;
  final bool bold;
  final bool dim;
  final bool italic;
  final bool underline;
  final bool strikethrough;
  final bool inverse;

  static const plain = AnsiStyle();

  bool get isPlain =>
      foreground == null &&
      background == null &&
      !bold &&
      !dim &&
      !italic &&
      !underline &&
      !strikethrough &&
      !inverse;

  AnsiStyle copyWith({
    AnsiColor? Function()? foreground,
    AnsiColor? Function()? background,
    bool? bold,
    bool? dim,
    bool? italic,
    bool? underline,
    bool? strikethrough,
    bool? inverse,
  }) {
    return AnsiStyle(
      foreground: foreground != null ? foreground() : this.foreground,
      background: background != null ? background() : this.background,
      bold: bold ?? this.bold,
      dim: dim ?? this.dim,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      strikethrough: strikethrough ?? this.strikethrough,
      inverse: inverse ?? this.inverse,
    );
  }

  TextStyle toTextStyle({required Brightness brightness, TextStyle? baseStyle}) {
    if (isPlain) return baseStyle ?? const TextStyle();

    var fg = foreground?.toColor(brightness);
    var bg = background?.toColor(brightness);

    final defaultFg = brightness == Brightness.dark
        ? const Color(0xFFCDD6F4)
        : const Color(0xFF24292E);
    final defaultBg = brightness == Brightness.dark
        ? const Color(0xFF15181F)
        : const Color(0xFFFFFFFF);

    if (inverse) {
      final actualFg = fg ?? defaultFg;
      final actualBg = bg ?? defaultBg;
      fg = actualBg;
      bg = actualFg;
    }

    if (dim) {
      final effectiveFg = fg ?? baseStyle?.color ?? defaultFg;
      fg = effectiveFg.withValues(alpha: 0.6);
    }

    FontWeight? weight;
    if (bold) {
      weight = FontWeight.bold;
    } else if (dim) {
      weight = FontWeight.w300;
    }

    TextDecoration? decoration;
    if (underline && strikethrough) {
      decoration = TextDecoration.combine([
        TextDecoration.underline,
        TextDecoration.lineThrough,
      ]);
    } else if (underline) {
      decoration = TextDecoration.underline;
    } else if (strikethrough) {
      decoration = TextDecoration.lineThrough;
    }

    return (baseStyle ?? const TextStyle()).copyWith(
      color: fg,
      backgroundColor: bg,
      fontWeight: weight,
      fontStyle: italic ? FontStyle.italic : null,
      decoration: decoration,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnsiStyle &&
          foreground == other.foreground &&
          background == other.background &&
          bold == other.bold &&
          dim == other.dim &&
          italic == other.italic &&
          underline == other.underline &&
          strikethrough == other.strikethrough &&
          inverse == other.inverse;

  @override
  int get hashCode => Object.hash(
        foreground,
        background,
        bold,
        dim,
        italic,
        underline,
        strikethrough,
        inverse,
      );
}

/// A contiguous segment of text associated with an [AnsiStyle].
@immutable
final class AnsiSpan {
  const AnsiSpan(this.text, [this.style = AnsiStyle.plain]);

  final String text;
  final AnsiStyle style;

  TextSpan toTextSpan({required Brightness brightness, TextStyle? baseStyle}) {
    return TextSpan(
      text: text,
      style: style.toTextStyle(brightness: brightness, baseStyle: baseStyle),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AnsiSpan && text == other.text && style == other.style;

  @override
  int get hashCode => Object.hash(text, style);

  @override
  String toString() => 'AnsiSpan("$text", style: $style)';
}

enum _AnsiState { normal, escape, csi, osc }

final class _StyledChar {
  _StyledChar(this.char, this.style);
  int char;
  AnsiStyle style;
}

/// Robust, lightweight, non-crashing state machine for terminal ANSI sequences
/// and SGR styling. Maintains active style across streaming line boundaries.
final class AnsiStateMachine {
  AnsiStateMachine({this.maxLineLength = 4096});

  /// Maximum characters per emitted line before splitting to preserve UI performance.
  final int maxLineLength;

  AnsiStyle currentStyle = AnsiStyle.plain;

  _AnsiState _state = _AnsiState.normal;
  final StringBuffer _paramBuffer = StringBuffer();

  void reset() {
    currentStyle = AnsiStyle.plain;
    _state = _AnsiState.normal;
    _paramBuffer.clear();
  }

  /// Creates an independent copy of the active style and partial escape state.
  AnsiStateMachine copy() {
    final cloned = AnsiStateMachine(maxLineLength: maxLineLength)
      ..currentStyle = currentStyle
      .._state = _state;
    if (_paramBuffer.isNotEmpty) {
      cloned._paramBuffer.write(_paramBuffer.toString());
    }
    return cloned;
  }

  /// Parses a chunk or line of text into a list of [AnsiSpan]s.
  /// If [flushAtEnd] is true (default), unclosed escape sequences at EOF are safely dropped.
  List<AnsiSpan> parseSpans(String input, {bool flushAtEnd = true}) {
    if (input.isEmpty) return const <AnsiSpan>[];

    final usingCells = input.contains('\r');
    final cells = usingCells ? <_StyledChar>[] : null;
    var cursor = 0;

    final spans = <AnsiSpan>[];
    final textBuffer = StringBuffer();
    var spanStyle = currentStyle;

    void flushText() {
      if (textBuffer.isEmpty) return;
      final text = textBuffer.toString();
      textBuffer.clear();
      if (spans.isNotEmpty && spans.last.style == spanStyle) {
        final prev = spans.removeLast();
        spans.add(AnsiSpan('${prev.text}$text', spanStyle));
      } else {
        spans.add(AnsiSpan(text, spanStyle));
      }
    }

    final len = input.length;
    for (var i = 0; i < len; i++) {
      final code = input.codeUnitAt(i);
      switch (_state) {
        case _AnsiState.normal:
          if (code == 0x1B) {
            _state = _AnsiState.escape;
          } else if (code == 0x0D) {
            // Carriage return '\r' -> move cursor to column 0.
            if (usingCells) {
              cursor = 0;
            }
          } else if (code == 0x07 || code == 0x00) {
            // Drop bell / null control chars.
          } else {
            if (usingCells) {
              if (cursor < cells!.length) {
                cells[cursor].char = code;
                cells[cursor].style = currentStyle;
              } else {
                cells.add(_StyledChar(code, currentStyle));
              }
              cursor++;
            } else {
              textBuffer.writeCharCode(code);
            }
          }
          break;

        case _AnsiState.escape:
          if (code == 0x5B) { // '['
            _state = _AnsiState.csi;
            _paramBuffer.clear();
          } else if (code == 0x5D) { // ']'
            _state = _AnsiState.osc;
          } else if (code == 0x1B) {
            // Consecutive ESC, remain in escape state.
          } else {
            // 2-character escape sequence (e.g. ESC ( B, ESC 7, ESC 8). Safely consume.
            _state = _AnsiState.normal;
          }
          break;

        case _AnsiState.csi:
          if ((code >= 0x30 && code <= 0x3F)) {
            // Parameter characters: 0-9, :, ;, <, =, >, ?
            if (_paramBuffer.length < 64) {
              _paramBuffer.writeCharCode(code);
            }
          } else if (code >= 0x20 && code <= 0x2F) {
            // Intermediate bytes: space, !, ", etc. Safely ignore.
          } else if (code >= 0x40 && code <= 0x7E) {
            // Final character.
            if (code == 0x6D) { // 'm' -> SGR command
              flushText();
              _applySgr(_paramBuffer.toString());
              spanStyle = currentStyle;
            } else if (code == 0x4B) { // 'K' -> Erase in Line
              final param = int.tryParse(_paramBuffer.toString()) ?? 0;
              if (param == 0) {
                // Erase from cursor to end of line.
                if (usingCells && cursor < cells!.length) {
                  cells.removeRange(cursor, cells.length);
                }
              } else if (param == 1) {
                // Erase from start of line to cursor.
                if (usingCells) {
                  final limit = cursor < cells!.length ? cursor : cells.length;
                  for (var j = 0; j < limit; j++) {
                    cells[j].char = 0x20;
                    cells[j].style = AnsiStyle.plain;
                  }
                }
              } else if (param == 2) {
                // Erase entire line.
                if (usingCells) {
                  cells!.clear();
                  cursor = 0;
                } else {
                  textBuffer.clear();
                  spans.clear();
                }
              }
            } else if (code == 0x4A) { // 'J' -> Erase in Display
              final param = int.tryParse(_paramBuffer.toString()) ?? 0;
              if (param == 2 || param == 3) {
                if (usingCells) {
                  cells!.clear();
                  cursor = 0;
                } else {
                  textBuffer.clear();
                  spans.clear();
                }
              }
            }
            // All CSI sequences finish here.
            _state = _AnsiState.normal;
            _paramBuffer.clear();
          } else if (code == 0x1B) {
            // Interrupted / nested escape sequence.
            _state = _AnsiState.escape;
            _paramBuffer.clear();
          } else {
            // Unexpected byte in CSI: abort sequence safely.
            _state = _AnsiState.normal;
            _paramBuffer.clear();
          }
          break;

        case _AnsiState.osc:
          if (code == 0x07 ||
              (code == 0x5C && i > 0 && input.codeUnitAt(i - 1) == 0x1B) ||
              code == 0x0A) {
            _state = _AnsiState.normal;
          } else if (code == 0x1B) {
            // ESC inside OSC: remain or prepare for '\' terminator.
          }
          break;
      }
    }

    if (usingCells) {
      if (cells!.isEmpty) return const <AnsiSpan>[];
      final result = <AnsiSpan>[];
      final buffer = StringBuffer();
      var segStyle = cells.first.style;
      for (var idx = 0; idx < cells.length; idx++) {
        final cell = cells[idx];
        if (cell.style == segStyle) {
          buffer.writeCharCode(cell.char);
        } else {
          result.add(AnsiSpan(buffer.toString(), segStyle));
          buffer.clear();
          segStyle = cell.style;
          buffer.writeCharCode(cell.char);
        }
      }
      if (buffer.isNotEmpty) {
        result.add(AnsiSpan(buffer.toString(), segStyle));
      }
      if (flushAtEnd && _state != _AnsiState.normal) {
        _state = _AnsiState.normal;
        _paramBuffer.clear();
      }
      return result;
    }

    flushText();

    if (flushAtEnd && _state != _AnsiState.normal) {
      // Safely end dangling escape sequence at boundary.
      _state = _AnsiState.normal;
      _paramBuffer.clear();
    }

    return spans;
  }

  void _applySgr(String rawParams) {
    if (rawParams.isEmpty) {
      currentStyle = AnsiStyle.plain;
      return;
    }

    final args = rawParams.split(';');
    for (var a = 0; a < args.length; a++) {
      final arg = args[a];
      if (arg.contains(':')) {
        // ITU T.416 colon-separated subparameters:
        final sub = arg.split(':');
        final cmd = int.tryParse(sub[0]);
        if (cmd == 38 || cmd == 48) {
          final isFg = cmd == 38;
          final mode = sub.length > 1 ? int.tryParse(sub[1]) : null;
          if (mode == 5 && sub.length > 2) {
            final idx = int.tryParse(sub[2]);
            if (idx != null) {
              final color = AnsiColor.color256(idx);
              currentStyle = isFg
                  ? currentStyle.copyWith(foreground: () => color)
                  : currentStyle.copyWith(background: () => color);
            }
          } else if (mode == 2) {
            int? r, g, b;
            if (sub.length >= 6) {
              // 38:2:cs:r:g:b or 38:2::r:g:b
              r = int.tryParse(sub[3]);
              g = int.tryParse(sub[4]);
              b = int.tryParse(sub[5]);
            } else if (sub.length == 5) {
              // 38:2:r:g:b
              r = int.tryParse(sub[2]);
              g = int.tryParse(sub[3]);
              b = int.tryParse(sub[4]);
            }
            if (r != null && g != null && b != null) {
              final color = AnsiColor.rgb(r, g, b);
              currentStyle = isFg
                  ? currentStyle.copyWith(foreground: () => color)
                  : currentStyle.copyWith(background: () => color);
            }
          }
        } else if (cmd != null) {
          _applySingleCode(cmd);
        }
        continue;
      }

      // Semicolon-delimited parameter:
      if (arg.isEmpty) {
        _applySingleCode(0);
        continue;
      }
      final code = int.tryParse(arg);
      if (code == null) continue;

      if ((code == 38 || code == 48) && a + 1 < args.length) {
        final isFg = code == 38;
        final mode = int.tryParse(args[a + 1]);
        if (mode == 5 && a + 2 < args.length) {
          final idx = int.tryParse(args[a + 2]);
          if (idx != null) {
            final color = AnsiColor.color256(idx);
            currentStyle = isFg
                ? currentStyle.copyWith(foreground: () => color)
                : currentStyle.copyWith(background: () => color);
          }
          a += 2;
          continue;
        } else if (mode == 2) {
          if (a + 5 < args.length &&
              (args[a + 2].isEmpty || (int.tryParse(args[a + 2]) ?? -1) <= 1)) {
            final r = int.tryParse(args[a + 3]);
            final g = int.tryParse(args[a + 4]);
            final b = int.tryParse(args[a + 5]);
            if (r != null && g != null && b != null) {
              final color = AnsiColor.rgb(r, g, b);
              currentStyle = isFg
                  ? currentStyle.copyWith(foreground: () => color)
                  : currentStyle.copyWith(background: () => color);
            }
            a += 5;
            continue;
          } else if (a + 4 < args.length) {
            final r = int.tryParse(args[a + 2]);
            final g = int.tryParse(args[a + 3]);
            final b = int.tryParse(args[a + 4]);
            if (r != null && g != null && b != null) {
              final color = AnsiColor.rgb(r, g, b);
              currentStyle = isFg
                  ? currentStyle.copyWith(foreground: () => color)
                  : currentStyle.copyWith(background: () => color);
            }
            a += 4;
            continue;
          }
        }
      }

      _applySingleCode(code);
    }
  }

  void _applySingleCode(int code) {
    switch (code) {
      case 0:
        currentStyle = AnsiStyle.plain;
        break;
      case 1:
        currentStyle = currentStyle.copyWith(bold: true);
        break;
      case 2:
        currentStyle = currentStyle.copyWith(dim: true);
        break;
      case 3:
        currentStyle = currentStyle.copyWith(italic: true);
        break;
      case 4:
        currentStyle = currentStyle.copyWith(underline: true);
        break;
      case 7:
        currentStyle = currentStyle.copyWith(inverse: true);
        break;
      case 9:
        currentStyle = currentStyle.copyWith(strikethrough: true);
        break;
      case 21:
      case 22:
        currentStyle = currentStyle.copyWith(bold: false, dim: false);
        break;
      case 23:
        currentStyle = currentStyle.copyWith(italic: false);
        break;
      case 24:
        currentStyle = currentStyle.copyWith(underline: false);
        break;
      case 27:
        currentStyle = currentStyle.copyWith(inverse: false);
        break;
      case 29:
        currentStyle = currentStyle.copyWith(strikethrough: false);
        break;
      case 30:
      case 31:
      case 32:
      case 33:
      case 34:
      case 35:
      case 36:
      case 37:
        currentStyle = currentStyle.copyWith(
          foreground: () => AnsiColor.standard(code - 30),
        );
        break;
      case 39:
        currentStyle = currentStyle.copyWith(foreground: () => null);
        break;
      case 40:
      case 41:
      case 42:
      case 43:
      case 44:
      case 45:
      case 46:
      case 47:
        currentStyle = currentStyle.copyWith(
          background: () => AnsiColor.standard(code - 40),
        );
        break;
      case 49:
        currentStyle = currentStyle.copyWith(background: () => null);
        break;
      case 90:
      case 91:
      case 92:
      case 93:
      case 94:
      case 95:
      case 96:
      case 97:
        currentStyle = currentStyle.copyWith(
          foreground: () => AnsiColor.standard(code - 90 + 8),
        );
        break;
      case 100:
      case 101:
      case 102:
      case 103:
      case 104:
      case 105:
      case 106:
      case 107:
        currentStyle = currentStyle.copyWith(
          background: () => AnsiColor.standard(code - 100 + 8),
        );
        break;
    }
  }
}
