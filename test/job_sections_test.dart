import 'dart:async';
import 'dart:ui' show Tristate;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
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
    final header = find.byWidgetPredicate((widget) =>
        widget is Semantics && (widget.properties.label ?? '').contains('prepare executor'));
    expect(tester.getSize(header).height, greaterThanOrEqualTo(48));
    final semantics = tester.widget<Semantics>(header);
    expect(semantics.properties.button, isTrue);
    expect(semantics.properties.expanded, isFalse);
    expect(semantics.excludeSemantics, isTrue);
    final node = tester.getSemantics(header);
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.label, 'prepare executor · 2 秒');
    tester.semantics.performAction(find.semantics.byLabel(node.label), SemanticsAction.tap);
    await tester.pump();
    expect(find.text('hidden line'), findsOneWidget);
    expect(tester.widget<Semantics>(header).properties.expanded, isTrue);
    expect(tester.getSemantics(header).flagsCollection.isExpanded, Tristate.isTrue);
    await tester.tap(header);
    await tester.pump();
    expect(find.text('hidden line'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('job-log-search-501')), 'hidden');
    await tester.pump();
    expect(find.text('hidden line'), findsOneWidget);
  });

  test('runner timestamp headers are removed and continued lines joined', () {
    // The header GitLab Runner writes since GitLab 17.1, as in a gitlab.com
    // trace: `+` continues the previous line, here across section markers.
    final parsed = JobTrace.parse([
      '2026-10-20T06:56:03.198557Z 00O \x1b[0KRunning with gitlab-runner 19.4.1\x1b[0;m',
      '2026-10-20T06:56:03.198694Z 00O section_start:1792479363:prepare_executor\r\x1b[0K',
      '2026-10-20T06:56:03.198699Z 00O+\x1b[0K\x1b[36;1mPreparing the "docker" executor\x1b[0;m',
      '2026-10-20T06:56:03.747404Z 00O section_end:1792479365:prepare_executor\r\x1b[0K',
      '2026-10-20T06:56:03.747480Z 00O+section_start:1792479365:prepare_script\r\x1b[0K',
      '2026-10-20T06:56:03.747483Z 00O+\x1b[0K\x1b[36;1mPreparing environment\x1b[0;m',
      '2026-10-20T06:56:03.879411Z 01E warning: on stderr',
      '2026-10-20T06:56:03.879412Z 01O ',
    ].join('\n'));
    expect(parsed.lines.map((line) => '${line.section ?? '-'}:${line.text}'), [
      '-:Running with gitlab-runner 19.4.1',
      'prepare_executor:Preparing the "docker" executor',
      'prepare_script:Preparing environment',
      'prepare_script:warning: on stderr',
      'prepare_script:',
    ]);
    expect(parsed.ansiStripped, isNot(contains('Z 0')));
    final executor = parsed.sections.firstWhere((section) => section.name == 'prepare_executor');
    expect(executor.durationSeconds, 2);
    expect((executor.startLine, executor.endLine), (1, 2));
  });

  test('a continued line joins the text before it and the trailing newline stays', () {
    const header = '2026-10-20T06:56:03.198557Z 00O ', continued = '2026-10-20T06:56:03.198558Z 00O+';
    final parsed = JobTrace.parse('${header}ab\n${continued}cd\n${header}e\n');
    expect(parsed.lines.map((line) => line.text), ['abcd', 'e', '']);
  });

  testWidgets('the job log page shows runner output without timestamp headers', (tester) async {
    final fixture = _TimestampFixture();
    addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(JobLogPage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 501,
    )));
    await settleWorkspace(tester);
    expect(find.text('Running with gitlab-runner 19.4.1'), findsOneWidget);
    expect(find.text('Preparing environment'), findsOneWidget);
    expect(find.textContaining('Z 00O', findRichText: true), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('job-log-search-501')), '00O');
    await tester.pump();
    expect(find.textContaining('Z 00O', findRichText: true), findsNothing);
  });

  test('a trace whose first line has no timestamp header is left as it is', () {
    final parsed = JobTrace.parse('plain first\n2026-10-20T06:56:03.198557Z 00O kept');
    expect(parsed.lines.map((line) => line.text), ['plain first', '2026-10-20T06:56:03.198557Z 00O kept']);
  });

  test('CRLF body lines drop the trailing carriage return', () {
    final parsed = JobTrace.parse('alpha\r\nbeta\r');
    expect(parsed.lines.map((line) => line.text), ['alpha', 'beta']);
    expect(parsed.lines.every((line) => !line.text.contains('\r')), isTrue);
  });

  test('a newline-only trace is rejected before line objects are built', () {
    expect(
      () => JobTrace.parse('\n' * GitLabApi.maxTextLines),
      throwsA(isA<ApiFailure>().having((error) => error.kind, 'kind', FailureKind.tooLarge)),
    );
    expect(JobTrace.parse('a\nb', maxLines: 2).lines.map((line) => line.text), ['a', 'b']);
    expect(
      () => JobTrace.parse('a\nb\nc', maxLines: 2),
      throwsA(isA<ApiFailure>().having((error) => error.kind, 'kind', FailureKind.tooLarge)),
    );
  });

  test('inline section markers count toward the row budget', () {
    const piece = '!section_start:1:a';
    expect(piece.length, 18);
    expect(JobTrace.parse('$piece y', maxLines: 2).lines.map((line) => line.text), ['!', ' y']);
    expect(
      () => JobTrace.parse(piece * 3, maxLines: 2),
      throwsA(isA<ApiFailure>().having((error) => error.kind, 'kind', FailureKind.tooLarge)),
    );
    final dense = piece * 100001;
    expect(dense.length, 1800018);
    expect(
      () => JobTrace.parse(dense),
      throwsA(isA<ApiFailure>().having((error) => error.kind, 'kind', FailureKind.tooLarge)),
    );
  });

  test('deeply nested and marker-dense traces stay within the section budget', () {
    final nested = StringBuffer();
    for (var i = 0; i < 40; i++) {
      nested.writeln('section_start:$i:level$i');
    }
    nested.writeln('leaf');
    for (var i = 39; i >= 0; i--) {
      nested.writeln('section_end:${i + 1}:level$i');
    }
    final deep = JobTrace.parse(nested.toString());
    expect(deep.sections.length, JobTrace.maxDepth);
    expect(deep.sections.every((section) => section.depth < JobTrace.maxDepth), isTrue);
    expect(deep.lines.map((line) => line.text), contains('leaf'));

    final dense = StringBuffer();
    for (var i = 0; i < 3000; i++) {
      dense.writeln('section_start:$i:step$i[collapsed=true]');
      dense.writeln('line $i');
      dense.writeln('section_end:${i + 1}:step$i');
    }
    final many = JobTrace.parse(dense.toString());
    expect(many.sections.length, JobTrace.maxSections);
    expect(many.lines.length, lessThan(GitLabApi.maxTextLines));
    expect(many.lines.map((line) => line.text), contains('line 2999'));
  });

  testWidgets('a deeply nested log renders the leaf without a stack overflow', (tester) async {
    final fixture = _DeepFixture();
    addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(JobLogPage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 501,
    )));
    await settleWorkspace(tester);
    expect(tester.takeException(), isNull);
    final list = find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable));
    await tester.scrollUntilVisible(find.text('leaf'), 400, scrollable: list);
    expect(find.text('leaf'), findsOneWidget);
    await tester.drag(list, const Offset(0, 4000));
    await tester.pump();
    expect(find.textContaining('level0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search expands a collapsed ancestor to reveal a nested hit', (tester) async {
    final fixture = _NestedSearchFixture();
    addTearDown(fixture.api.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(workspaceHost(JobLogPage(
      account: fixture.account, api: fixture.api, project: fixture.project, id: 501,
    )));
    await settleWorkspace(tester);
    expect(find.text('secret line'), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('job-log-search-501')), 'secret');
    await tester.pump();
    expect(find.text('secret line'), findsOneWidget);
    expect(find.textContaining('outer gate'), findsOneWidget);
    expect(find.textContaining('inner gate'), findsOneWidget);
  });
}

class _DeepFixture extends WorkspaceFixture {
  static final trace = () {
    final buffer = StringBuffer();
    for (var i = 0; i < 40; i++) {
      buffer.writeln('section_start:$i:level$i');
    }
    buffer.writeln('leaf');
    for (var i = 39; i >= 0; i--) {
      buffer.writeln('section_end:${i + 1}:level$i');
    }
    return buffer.toString();
  }();
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (request.uri.path.endsWith('/jobs/501/trace')) return ResponseBody.fromString(trace, 200);
    return super.respond(request);
  }
}

class _TimestampFixture extends WorkspaceFixture {
  static const trace = '2026-10-20T06:56:03.198557Z 00O \x1b[0KRunning with gitlab-runner 19.4.1\x1b[0;m\n'
      '2026-10-20T06:56:03.747480Z 00O section_start:1792479365:prepare_script\r\x1b[0K\n'
      '2026-10-20T06:56:03.747483Z 00O+\x1b[0K\x1b[36;1mPreparing environment\x1b[0;m\n'
      '2026-10-20T06:56:04.000000Z 00O section_end:1792479366:prepare_script\r\x1b[0K\n';
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (request.uri.path.endsWith('/jobs/501/trace')) return ResponseBody.fromString(trace, 200);
    return super.respond(request);
  }
}

class _NestedSearchFixture extends WorkspaceFixture {
  static const trace = 'section_start:1:outer_gate[collapsed=true]\r\n'
      'section_start:2:inner_gate[collapsed=true]\r\n'
      'secret line\n'
      'section_end:3:inner_gate\r\n'
      'section_end:4:outer_gate\r\n';
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (request.uri.path.endsWith('/jobs/501/trace')) return ResponseBody.fromString(trace, 200);
    return super.respond(request);
  }
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
