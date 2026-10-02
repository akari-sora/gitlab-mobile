import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/project_extras.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;

String _apiPath(RequestOptions request) {
  final parts = request.uri.pathSegments;
  return parts.skip(parts.indexOf('v4') + 1).join('/');
}

final class _SchedulesFixture extends WorkspaceFixture {
  _SchedulesFixture({
    required this.rows,
    this.host = 'https://example.com/gitlab',
    String projectPath = 'studio/mobile-workspace',
  }) {
    projectRecord['path_with_namespace'] = projectPath;
  }

  final List<Map<String, dynamic>> rows;
  final String host;
  Completer<ResponseBody>? readGate;
  Completer<ResponseBody>? writeGate;
  int writes = 0;

  late final _schedulesApi = testApi(adapter, host: host);
  @override
  GitLabApi get api => _schedulesApi;

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final path = _apiPath(request);
    if (path == 'projects/42/pipeline_schedules' && request.method == 'GET') {
      return readGate?.future ?? jsonResponse(rows);
    }
    if (path.startsWith('projects/42/pipeline_schedules/') &&
        path.endsWith('/play') &&
        request.method == 'POST') {
      writes++;
      return writeGate?.future ?? jsonResponse({'message': '201 Created'}, status: 201);
    }
    return super.respond(request);
  }
}

Widget _page(_SchedulesFixture fixture) => workspaceHost(
  PipelineSchedulesPage(
    account: fixture.account,
    api: fixture.api,
    project: fixture.project,
  ),
);

final class _OwnerHarness extends StatefulWidget {
  const _OwnerHarness({super.key, required this.first, required this.second});

  final _SchedulesFixture first;
  final _SchedulesFixture second;

  @override
  State<_OwnerHarness> createState() => _OwnerHarnessState();
}

final class _OwnerHarnessState extends State<_OwnerHarness> {
  bool replaced = false;

  void replace() => setState(() => replaced = true);

  @override
  Widget build(BuildContext context) {
    final fixture = replaced ? widget.second : widget.first;
    return PipelineSchedulesPage(
      account: fixture.account,
      api: fixture.api,
      project: fixture.project,
    );
  }
}

Map<String, dynamic> _schedule(int id, String description) => {
  'id': id,
  'description': description,
  'ref': 'main',
  'cron': '0 2 * * *',
  'cron_timezone': 'UTC',
  'active': true,
};

Future<void> _openConfirmation(WidgetTester tester) async {
  await settleNetworkWidgets(tester);
  await tester.tap(find.byTooltip('立即執行'));
  await tester.pumpAndSettle();
  expect(find.text('立即執行排程？'), findsOneWidget);
}

IconButton _playButton(WidgetTester tester) => tester.widget<IconButton>(
  find.widgetWithIcon(IconButton, Icons.play_circle_outline),
);

void main() {
  testWidgets('session ending before the dialog first build removes confirmation', (
    tester,
  ) async {
    final fixture = _SchedulesFixture(rows: [_schedule(3, 'Unbuilt old schedule')]);
    final session = SessionController(MemoryAccountStore())
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    addTearDown(session.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWithValue(session)],
      child: _page(fixture),
    ));
    await settleNetworkWidgets(tester);

    // Push the dialog without pumping its builder, then invalidate its owner.
    _playButton(tester).onPressed!();
    await session.endSession();
    await tester.pumpAndSettle();
    // confirmAction waits for its touch-through protection after route removal.
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('立即執行排程？'), findsNothing);
    expect(find.textContaining('Unbuilt old schedule'), findsNothing);
    expect(fixture.writes, 0);
  });

  testWidgets('rapid Play taps open one confirmation and cancel unlocks Play', (
    tester,
  ) async {
    final fixture = _SchedulesFixture(rows: [_schedule(3, 'Single confirmation')]);
    addTearDown(fixture.api.close);
    await tester.pumpWidget(_page(fixture));
    await settleNetworkWidgets(tester);
    final play = _playButton(tester).onPressed!;
    play();
    play();
    await tester.pumpAndSettle();

    expect(find.text('立即執行排程？'), findsOneWidget);
    expect(_playButton(tester).onPressed, isNull);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(_playButton(tester).onPressed, isNotNull);
    expect(fixture.writes, 0);
  });

  testWidgets('owner replacement dismisses the old confirmation and rows', (
    tester,
  ) async {
    final first = _SchedulesFixture(
      rows: [_schedule(3, 'First private schedule')],
    );
    final second = _SchedulesFixture(
      rows: [_schedule(4, 'Second schedule')],
      host: 'https://next.example/gitlab',
      projectPath: 'next/mobile-workspace',
    );
    addTearDown(first.api.close);
    addTearDown(second.api.close);
    final key = GlobalKey<_OwnerHarnessState>();
    await tester.pumpWidget(
      workspaceHost(_OwnerHarness(key: key, first: first, second: second)),
    );
    await _openConfirmation(tester);
    expect(find.text('First private schedule\nmain'), findsOneWidget);

    key.currentState!.replace();
    await settleNetworkWidgets(tester);

    expect(find.text('立即執行排程？'), findsNothing);
    expect(find.textContaining('First private schedule'), findsNothing);
    expect(find.text('Second schedule'), findsOneWidget);
    expect(first.writes, 0);
    expect(second.writes, 0);
  });

  testWidgets('ending the session dismisses schedule content and confirmation', (
    tester,
  ) async {
    final fixture = _SchedulesFixture(
      rows: [_schedule(3, 'Session private schedule')],
    );
    final session = SessionController(MemoryAccountStore())
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    addTearDown(session.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _page(fixture),
      ),
    );
    await _openConfirmation(tester);

    await session.endSession();
    await settleNetworkWidgets(tester);

    expect(find.text('立即執行排程？'), findsNothing);
    expect(find.textContaining('Session private schedule'), findsNothing);
    expect(find.byTooltip('立即執行'), findsNothing);
    expect(fixture.writes, 0);
  });

  testWidgets('an initially mismatched session cannot show schedules', (
    tester,
  ) async {
    final fixture = _SchedulesFixture(
      rows: [_schedule(3, 'Denied private schedule')],
    );
    final active = _SchedulesFixture(
      rows: const [],
      host: 'https://active.example/gitlab',
    );
    final session = SessionController(MemoryAccountStore())
      ..active = active.account
      ..api = active.api
      ..initializing = false;
    addTearDown(fixture.api.close);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _page(fixture),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Denied private schedule'), findsNothing);
    expect(find.byTooltip('立即執行'), findsNothing);
    expect(fixture.adapter.requests, isEmpty);
  });

  testWidgets('closed API rebuild dismisses schedule content and confirmation', (
    tester,
  ) async {
    final fixture = _SchedulesFixture(
      rows: [_schedule(3, 'Closed owner private schedule')],
    );
    addTearDown(fixture.api.close);
    await tester.pumpWidget(_page(fixture));
    await _openConfirmation(tester);

    fixture.api.close();
    await tester.pumpWidget(_page(fixture));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('立即執行排程？'), findsNothing);
    expect(find.textContaining('Closed owner private schedule'), findsNothing);
    expect(find.byTooltip('立即執行'), findsNothing);
    expect(fixture.writes, 0);
  });

  for (final status in [201, 503]) {
    testWidgets('old pending schedule response $status cannot affect replacement', (
      tester,
    ) async {
      final first = _SchedulesFixture(
        rows: [_schedule(3, 'Pending old schedule')],
      )..writeGate = Completer<ResponseBody>();
      final second = _SchedulesFixture(
        rows: [_schedule(4, 'Current schedule')],
        host: 'https://next.example/gitlab',
      );
      addTearDown(first.api.close);
      addTearDown(second.api.close);
      final key = GlobalKey<_OwnerHarnessState>();
      await tester.pumpWidget(
        workspaceHost(_OwnerHarness(key: key, first: first, second: second)),
      );
      await _openConfirmation(tester);
      await tester.tap(find.widgetWithText(FilledButton, '確認'));
      await pumpUntil(
        tester,
        () => first.writes == 1,
        description: 'old schedule write starts',
      );

      key.currentState!.replace();
      await settleNetworkWidgets(tester);
      expect(find.text('Current schedule'), findsOneWidget);
      expect(_playButton(tester).onPressed, isNotNull);

      first.writeGate!.complete(
        status == 201
            ? jsonResponse({'message': '201 Created'}, status: 201)
            : jsonResponse({'message': 'Synthetic failure'}, status: 503),
      );
      await settleNetworkWidgets(tester);

      expect(find.byType(SnackBar), findsNothing);
      expect(find.textContaining('已排入執行'), findsNothing);
      expect(second.writes, 0);
      expect(_playButton(tester).onPressed, isNotNull);
    });
  }

  testWidgets('same project ID replacement rejects a pending old feed', (
    tester,
  ) async {
    final first = _SchedulesFixture(
      rows: [_schedule(3, 'Late old private schedule')],
    )..readGate = Completer<ResponseBody>();
    final second = _SchedulesFixture(
      rows: [_schedule(4, 'Current owner schedule')],
      host: 'https://next.example/gitlab',
    );
    addTearDown(first.api.close);
    addTearDown(second.api.close);
    final key = GlobalKey<_OwnerHarnessState>();
    await tester.pumpWidget(
      workspaceHost(_OwnerHarness(key: key, first: first, second: second)),
    );
    await pumpUntil(
      tester,
      () => first.adapter.requests.isNotEmpty,
      description: 'old schedule feed starts',
    );

    key.currentState!.replace();
    await settleNetworkWidgets(tester);
    expect(find.text('Current owner schedule'), findsOneWidget);

    first.readGate!.complete(jsonResponse(first.rows));
    await settleNetworkWidgets(tester);
    expect(find.text('Current owner schedule'), findsOneWidget);
    expect(find.text('Late old private schedule'), findsNothing);
  });

  testWidgets('a schedule without a positive ID cannot be played', (
    tester,
  ) async {
    final fixture = _SchedulesFixture(
      rows: [_schedule(0, 'Invalid schedule')],
    );
    addTearDown(fixture.api.close);
    await tester.pumpWidget(_page(fixture));
    await settleNetworkWidgets(tester);

    expect(_playButton(tester).onPressed, isNull);
    expect(fixture.writes, 0);
  });
}
