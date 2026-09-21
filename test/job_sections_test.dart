import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/job_trace.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  test('trace without markers keeps every line', () {
    final parsed = JobTrace.parse('alpha\n\nbeta');
    expect(parsed.sections, isEmpty);
    expect(parsed.lines.map((line) => line.text), ['alpha', '', 'beta']);
    expect(parsed.lines.every((line) => line.section == null), isTrue);
  });

  test('section markers are removed and a collapsed section records its range', () {
    final parsed = JobTrace.parse(
      '\x1b[31mred\x1b[0m\n'
      '\x1b[0Ksection_start:1789993773:prepare_executor[collapsed=true]\r\x1b[0Kfetch\n'
      '\x1b[0Ksection_end:1789993775:prepare_executor\r\x1b[0K',
    );
    expect(parsed.lines.map((line) => line.text), ['red', 'fetch']);
    expect(parsed.lines.first.section, isNull);
    expect(parsed.lines.last.section, 'prepare_executor');
    expect(parsed.lines.any((line) => line.text.contains('section_start')), isFalse);
    final section = parsed.sections.single;
    expect(section.name, 'prepare_executor');
    expect(section.label, 'prepare executor');
    expect(section.start, 1789993773);
    expect(section.end, 1789993775);
    expect(section.durationSeconds, 2);
    expect(section.collapsed, isTrue);
    expect(section.startLine, 1);
    expect(section.endLine, 2);
  });

  test('nested sections close inner first and unterminated sections stay open', () {
    final nested = JobTrace.parse([
      'section_start:1:outer\r',
      'a',
      'section_start:2:inner[collapsed=true]\r',
      'b',
      'section_end:4:inner\r',
      'c',
      'section_end:6:outer\r',
      'd',
    ].join('\n'));
    expect(nested.lines.map((line) => '${line.section ?? '-'}:${line.text}'), ['outer:a', 'inner:b', 'outer:c', '-:d']);
    final inner = nested.sections.firstWhere((section) => section.name == 'inner');
    final outer = nested.sections.firstWhere((section) => section.name == 'outer');
    expect(inner.collapsed, isTrue);
    expect(inner.depth, 1);
    expect(inner.startLine, 1);
    expect(inner.endLine, 2);
    expect(inner.end, 4);
    expect(outer.collapsed, isFalse);
    expect(outer.depth, 0);
    expect(outer.startLine, 0);
    expect(outer.endLine, 3);
    expect(outer.durationSeconds, 5);
    final open = JobTrace.parse('section_start:10:build\rcompiling\nstill');
    expect(open.lines.map((line) => line.text), ['compiling', 'still']);
    expect(open.sections.single.end, isNull);
    expect(open.sections.single.startLine, 0);
    expect(open.sections.single.endLine, 2);
    expect(open.sections.single.durationSeconds, isNull);
    final stray = JobTrace.parse('section_end:1:missing\rhello');
    expect(stray.sections, isEmpty);
    expect(stray.lines.single.text, 'hello');
  });

  testWidgets('a collapsed section hides its lines until the header is tapped', (tester) async {
    final fixture = _SectionFixture();
    addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(JobLogPage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 501,
    )));
    await settleWorkspace(tester);
    expect(find.text('before section'), findsOneWidget);
    expect(find.text('after section'), findsOneWidget);
    expect(find.textContaining('prepare executor'), findsOneWidget);
    expect(find.textContaining('2 秒'), findsOneWidget);
    expect(find.text('hidden line'), findsNothing);
    expect(find.textContaining('section_start'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('job-log-search-501')), 'hidden');
    await tester.pump();
    expect(find.text('hidden line'), findsNothing);
    await tester.tap(find.textContaining('prepare executor'));
    await tester.pump();
    expect(find.text('hidden line'), findsOneWidget);
  });
}

class _SectionFixture extends WorkspaceFixture {
  static const trace = 'before section\n'
      '\x1b[0Ksection_start:1789993773:prepare_executor[collapsed=true]\r\x1b[0Khidden line\n'
      '\x1b[0Ksection_end:1789993775:prepare_executor\r\x1b[0K'
      'after section\n';
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (request.uri.path.endsWith('/jobs/501/trace')) return ResponseBody.fromString(trace, 200);
    return super.respond(request);
  }
}
