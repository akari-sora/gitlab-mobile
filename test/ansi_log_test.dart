import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ansi.dart';
import 'package:gitlab_mobile/core/job_trace.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  group('AnsiStateMachine & SGR styling', () {
    test('standard 16 foreground colors map to distinct non-null colors', () {
      final sm = AnsiStateMachine();
      for (var i = 0; i < 8; i++) {
        final spans = sm.parseSpans('\x1B[${30 + i}mcolor$i\x1B[0m');
        expect(spans.length, 1);
        expect(spans.first.text, 'color$i');
        expect(spans.first.style.foreground, isNotNull);
        expect(spans.first.style.foreground!.index, i);
        expect(spans.first.style.foreground!.type, AnsiColorType.standard);

        final darkColor = spans.first.style.foreground!.toColor(Brightness.dark);
        final lightColor = spans.first.style.foreground!.toColor(Brightness.light);
        expect(darkColor, isNotNull);
        expect(lightColor, isNotNull);
      }

      for (var i = 0; i < 8; i++) {
        final spans = sm.parseSpans('\x1B[${90 + i}mbright$i\x1B[0m');
        expect(spans.length, 1);
        expect(spans.first.text, 'bright$i');
        expect(spans.first.style.foreground, isNotNull);
        expect(spans.first.style.foreground!.index, 8 + i);
        expect(spans.first.style.foreground!.type, AnsiColorType.standard);
      }
    });

    test('standard 16 background colors map to distinct non-null colors', () {
      final sm = AnsiStateMachine();
      for (var i = 0; i < 8; i++) {
        final spans = sm.parseSpans('\x1B[${40 + i}mbg$i\x1B[0m');
        expect(spans.length, 1);
        expect(spans.first.text, 'bg$i');
        expect(spans.first.style.background, isNotNull);
        expect(spans.first.style.background!.index, i);
      }
      for (var i = 0; i < 8; i++) {
        final spans = sm.parseSpans('\x1B[${100 + i}mbgbright$i\x1B[0m');
        expect(spans.length, 1);
        expect(spans.first.text, 'bgbright$i');
        expect(spans.first.style.background, isNotNull);
        expect(spans.first.style.background!.index, 8 + i);
      }
    });

    test('256-color palette (38;5;n and 48;5;n) parses cube and grayscale', () {
      final sm = AnsiStateMachine();
      final fgCube = sm.parseSpans('\x1B[38;5;196mRedCube\x1B[0m');
      expect(fgCube.first.style.foreground!.type, AnsiColorType.color256);
      expect(fgCube.first.style.foreground!.index, 196);
      final fgColor = fgCube.first.style.foreground!.toColor(Brightness.dark);
      expect((fgColor.r * 255).round(), greaterThan(200));

      final bgGray = sm.parseSpans('\x1B[48;5;244mGrayBg\x1B[0m');
      expect(bgGray.first.style.background!.type, AnsiColorType.color256);
      expect(bgGray.first.style.background!.index, 244);
      final bgColor = bgGray.first.style.background!.toColor(Brightness.dark);
      expect((bgColor.r * 255).round(), equals((bgColor.g * 255).round()));
      expect((bgColor.g * 255).round(), equals((bgColor.b * 255).round()));
    });

    test('24-bit RGB truecolor (38;2;r;g;b and 48;2;r;g;b) parses full channels', () {
      final sm = AnsiStateMachine();
      final spans = sm.parseSpans('\x1B[38;2;12;34;56m\x1B[48;2;78;90;123mTrueColor\x1B[0m');
      expect(spans.first.text, 'TrueColor');
      final fg = spans.first.style.foreground!;
      final bg = spans.first.style.background!;
      expect(fg.type, AnsiColorType.rgb);
      expect(fg.r, 12);
      expect(fg.g, 34);
      expect(fg.b, 56);
      expect(bg.type, AnsiColorType.rgb);
      expect(bg.r, 78);
      expect(bg.g, 90);
      expect(bg.b, 123);
      final c = fg.toColor(Brightness.light);
      expect((c.r * 255).round(), 12);
      expect((c.g * 255).round(), 34);
      expect((c.b * 255).round(), 56);
    });

    test('bold, dim, italic, underline, inverse modifiers toggle and reset independently', () {
      final sm = AnsiStateMachine();
      final bold = sm.parseSpans('\x1B[1mBold\x1B[0m');
      expect(bold.first.style.bold, isTrue);

      final dim = sm.parseSpans('\x1B[2mDim\x1B[22mNormal');
      expect(dim[0].style.dim, isTrue);
      expect(dim[1].style.dim, isFalse);
      expect(dim[1].style.bold, isFalse);

      final italic = sm.parseSpans('\x1B[3mItalic\x1B[23mNot');
      expect(italic[0].style.italic, isTrue);
      expect(italic[1].style.italic, isFalse);

      final underline = sm.parseSpans('\x1B[4mUnder\x1B[24mNot');
      expect(underline[0].style.underline, isTrue);
      expect(underline[1].style.underline, isFalse);

      final inv = sm.parseSpans('\x1B[7mInv\x1B[27mNot');
      expect(inv[0].style.inverse, isTrue);
      expect(inv[1].style.inverse, isFalse);
    });

    test('compound sequence with semicolons applies multiple attributes', () {
      final sm = AnsiStateMachine();
      final spans = sm.parseSpans('\x1B[1;33;44mWarningOnBlue\x1B[0m');
      expect(spans.first.text, 'WarningOnBlue');
      expect(spans.first.style.bold, isTrue);
      expect(spans.first.style.foreground!.index, 3); // Yellow
      expect(spans.first.style.background!.index, 4); // Blue
    });

    test('consecutive spans with same style are merged into one', () {
      final sm = AnsiStateMachine();
      final spans = sm.parseSpans('\x1B[31mHello \x1B[31mWorld\x1B[0m');
      expect(spans.length, 1);
      expect(spans.first.text, 'Hello World');
      expect(spans.first.style.foreground!.index, 1);
    });

    test('default color resets (39 and 49) clear foreground and background', () {
      final sm = AnsiStateMachine();
      final spans = sm.parseSpans('\x1B[31;42mColored\x1B[39mDefaultFg\x1B[49mDefaultBg');
      expect(spans[0].style.foreground!.index, 1);
      expect(spans[0].style.background!.index, 2);
      expect(spans[1].style.foreground, isNull);
      expect(spans[1].style.background!.index, 2);
      expect(spans[2].style.foreground, isNull);
      expect(spans[2].style.background, isNull);
    });

    test('strikethrough (9 and 29) toggles independently and combines with underline', () {
      final sm = AnsiStateMachine();
      final spans = sm.parseSpans('\x1B[9mDeleted\x1B[29mRestored\x1B[9;4mBoth\x1B[0m');
      expect(spans[0].style.strikethrough, isTrue);
      expect(spans[0].style.underline, isFalse);
      expect(spans[1].style.strikethrough, isFalse);
      expect(spans[2].style.strikethrough, isTrue);
      expect(spans[2].style.underline, isTrue);

      final textStyle = spans[2].style.toTextStyle(brightness: Brightness.dark);
      expect(textStyle.decoration, isNotNull);
      expect(textStyle.decoration!.contains(TextDecoration.lineThrough), isTrue);
      expect(textStyle.decoration!.contains(TextDecoration.underline), isTrue);
    });

    test('dimming with default foreground color produces reduced opacity text', () {
      final sm = AnsiStateMachine();
      final spans = sm.parseSpans('\x1B[2mDimmedDefault\x1B[0m');
      expect(spans.first.style.dim, isTrue);
      expect(spans.first.style.foreground, isNull);

      final style = spans.first.style.toTextStyle(
        brightness: Brightness.dark,
        baseStyle: const TextStyle(color: Color(0xFFFFFFFF)),
      );
      expect(style.color, isNotNull);
      expect((style.color!.a * 255).round(), closeTo(153, 5)); // 0.6 alpha
    });

    test('ITU T.416 colon-separated truecolor formats (38:2::r:g:b and 38:2:r:g:b)', () {
      final sm = AnsiStateMachine();
      final spans6 = sm.parseSpans('\x1B[38:2::255:128:64m\x1B[48:2::10:20:30mTrueColor6\x1B[0m');
      expect(spans6.first.text, 'TrueColor6');
      final fg6 = spans6.first.style.foreground!;
      final bg6 = spans6.first.style.background!;
      expect(fg6.type, AnsiColorType.rgb);
      expect(fg6.r, 255);
      expect(fg6.g, 128);
      expect(fg6.b, 64);
      expect(bg6.type, AnsiColorType.rgb);
      expect(bg6.r, 10);
      expect(bg6.g, 20);
      expect(bg6.b, 30);

      final spans5 = sm.parseSpans('\x1B[38:2:255:128:64mTrueColor5\x1B[0m');
      expect(spans5.first.text, 'TrueColor5');
      final fg5 = spans5.first.style.foreground!;
      expect(fg5.type, AnsiColorType.rgb);
      expect(fg5.r, 255);
      expect(fg5.g, 128);
      expect(fg5.b, 64);

      final spans256 = sm.parseSpans('\x1B[38:5:196m\x1B[48:5:46mColon256\x1B[0m');
      expect(spans256.first.style.foreground!.type, AnsiColorType.color256);
      expect(spans256.first.style.foreground!.index, 196);
      expect(spans256.first.style.background!.type, AnsiColorType.color256);
      expect(spans256.first.style.background!.index, 46);
    });
  });

  group('AnsiStateMachine resilience and bounds', () {
    test('truncated escape sequences at chunk boundaries do not crash or throw', () {
      final sm = AnsiStateMachine();
      expect(() => sm.parseSpans('Normal \x1B'), returnsNormally);
      expect(() => sm.parseSpans('Normal \x1B['), returnsNormally);
      expect(() => sm.parseSpans('Normal \x1B[3'), returnsNormally);
      expect(() => sm.parseSpans('Normal \x1B[31;'), returnsNormally);
      expect(() => sm.parseSpans('Normal \x1B[38;5;'), returnsNormally);
      expect(() => sm.parseSpans('Normal \x1B[38;2;255;'), returnsNormally);

      final clean = sm.parseSpans('Prefix\x1B[31');
      expect(clean.first.text, 'Prefix');
    });

    test('malformed and over-long parameter buffers are safely capped without crashing', () {
      final sm = AnsiStateMachine();
      final hostile = '\x1B[${'9' * 200}mSafeText\x1B[0m';
      final spans = sm.parseSpans(hostile);
      expect(spans.first.text, 'SafeText');
    });

    test('non-SGR escape sequences (CSI K, H, J, OSC) are consumed cleanly', () {
      final sm = AnsiStateMachine();
      final spans = sm.parseSpans('\x1B[0K\x1B[2J\x1B]0;terminal-title\x07VisibleText');
      expect(spans.single.text, 'VisibleText');
      expect(spans.single.style.isPlain, isTrue);
    });

    test('interrupted escape sequence transitions cleanly to new sequence without leaking ESC', () {
      final sm = AnsiStateMachine();
      final spans = sm.parseSpans('\x1B[\x1B[31mRed\x1B[0m');
      expect(spans.length, 1);
      expect(spans.first.text, 'Red');
      expect(spans.first.style.foreground!.index, 1);
    });

    test('in-line carriage return without newline correctly overwrites previous text from column 0', () {
      final sm = AnsiStateMachine();
      final progress = sm.parseSpans('Progress 10%\rProgress 50%\rProgress 100%');
      expect(progress.length, 1);
      expect(progress.first.text, 'Progress 100%');

      final erase = sm.parseSpans('Loading artifacts\r\x1B[0KDone!');
      expect(erase.length, 1);
      expect(erase.first.text, 'Done!');
    });

    test('CSI 2K clears entire line buffer', () {
      final sm = AnsiStateMachine();
      final spans = sm.parseSpans('Stale text\x1B[2K\x1B[32mFresh green\x1B[0m');
      expect(spans.length, 1);
      expect(spans.first.text, 'Fresh green');
      expect(spans.first.style.foreground!.index, 2);
    });
  });

  group('JobTrace ANSI integration', () {
    test('ANSI colors persist across line boundaries until reset', () {
      final trace = JobTrace.parse(
        '\x1B[32mLine 1 green\nLine 2 still green\x1B[0m\nLine 3 plain',
      );
      expect(trace.lines.length, 3);
      expect(trace.lines[0].text, 'Line 1 green');
      expect(trace.lines[0].spans.single.style.foreground!.index, 2);

      expect(trace.lines[1].text, 'Line 2 still green');
      expect(trace.lines[1].spans.single.style.foreground!.index, 2);

      expect(trace.lines[2].text, 'Line 3 plain');
      expect(trace.lines[2].spans.single.style.isPlain, isTrue);
    });

    test('section markers with surrounding CSI 0K do not emit empty lines', () {
      final trace = JobTrace.parse(
        '\x1b[0Ksection_start:100:test_run[collapsed=true]\r\x1b[0K\x1B[34mrunning tests\x1B[0m\n'
        '\x1b[0Ksection_end:105:test_run\r\x1b[0K',
      );
      expect(trace.lines.length, 1);
      expect(trace.lines.first.text, 'running tests');
      expect(trace.lines.first.section, 'test_run');
      expect(trace.lines.first.spans.first.style.foreground!.index, 4); // Blue
      expect(trace.sections.single.name, 'test_run');
      expect(trace.sections.single.durationSeconds, 5);
    });

    test('JobTraceLine.toInlineSpan constructs styled TextSpan for Flutter rendering', () {
      final trace = JobTrace.parse('\x1B[1;31mError:\x1B[0m \x1B[33mWarning\x1B[0m');
      final line = trace.lines.single;
      expect(line.text, 'Error: Warning');
      expect(line.spans.length, 3);

      final span = line.toInlineSpan(
        brightness: Brightness.dark,
        baseStyle: const TextStyle(fontSize: 12),
      ) as TextSpan;

      expect(span.children, isNotNull);
      expect(span.children!.length, 3);
      final span1 = span.children![0] as TextSpan;
      final span2 = span.children![1] as TextSpan;
      final span3 = span.children![2] as TextSpan;

      expect(span1.text, 'Error:');
      expect(span1.style!.fontWeight, FontWeight.bold);
      expect(span1.style!.color, isNotNull);

      expect(span2.text, ' ');
      expect(span3.text, 'Warning');
      expect(span3.style!.color, isNotNull);
    });

    test('lines exceeding maxLineLength are safely chunked into protected rows', () {
      final longText = 'A' * 6000;
      final trace = JobTrace.parse('\x1B[32m$longText\x1B[0m');
      expect(trace.lines.length, 2);
      expect(trace.lines[0].text.length, 4096);
      expect(trace.lines[1].text.length, 1904);
      expect(trace.lines[0].spans.single.style.foreground!.index, 2);
      expect(trace.lines[1].spans.single.style.foreground!.index, 2);
    });

    test('JobTrace handles in-line carriage-return progress bars without leaking literal CR', () {
      final trace = JobTrace.parse(
        'Step 1\n'
        'Progress 10%\rProgress 50%\rProgress 100%\n'
        'Step 2',
      );
      expect(trace.lines.length, 3);
      expect(trace.lines[1].text, 'Progress 100%');
      expect(trace.lines.every((line) => !line.text.contains('\r')), isTrue);
    });

    test('JobTrace handles massive 50,000 character single line without crashing', () {
      final massive = 'B' * 50000;
      final trace = JobTrace.parse('\x1B[33m$massive\x1B[0m');
      final expectedChunks = (50000 / 4096).ceil();
      expect(trace.lines.length, expectedChunks);
      final totalChars = trace.lines.fold<int>(0, (sum, line) => sum + line.text.length);
      expect(totalChars, 50000);
      expect(trace.lines.every((line) => line.spans.every((s) => s.style.foreground?.index == 3)), isTrue);
    });
  });

  group('JobLogPage ANSI widget rendering', () {
    testWidgets('JobLogPage renders ANSI colored lines in Text.rich', (tester) async {
      final fixture = _AnsiTraceFixture();
      addTearDown(fixture.api.close);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(412, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(workspaceHost(JobLogPage(
        account: fixture.account,
        api: fixture.api,
        project: fixture.project,
        id: 501,
      )));
      await settleWorkspace(tester);

      expect(find.textContaining('Success step'), findsOneWidget);
      expect(find.textContaining('Failed test'), findsOneWidget);
      expect(find.byType(RichText), findsWidgets);
      expect(tester.takeException(), isNull);

      // Search filters lines and retains styled spans
      await tester.enterText(find.byKey(const ValueKey('job-log-search-501')), 'Failed');
      await tester.pump();
      expect(find.textContaining('Failed test'), findsOneWidget);
      expect(find.textContaining('Success step'), findsNothing);
    });
  });
}

class _AnsiTraceFixture extends WorkspaceFixture {
  static const trace =
      '\x1b[0Ksection_start:10:setup\r\x1b[0K\x1B[32mSuccess step\x1B[0m\n'
      '\x1b[0Ksection_end:12:setup\r\x1b[0K\n'
      '\x1B[1;31mFailed test execution\x1B[0m\n'
      '\x1B[38;5;244mDim debug details\x1B[0m\n';

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (request.uri.path.endsWith('/jobs/501/trace')) {
      return ResponseBody.fromString(trace, 200);
    }
    return super.respond(request);
  }
}
