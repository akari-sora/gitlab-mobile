import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_health_edit_models.dart';
import 'package:gitlab_mobile/features/workspace/work_item_health.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/work_item_health_fixture.dart';

/// Host-side callback recorder. It stands in for the future Phase 3 parent;
/// it is not a real Graph parent integration.
final class _Log {
  final List<String> raw = [];
  final List<String> accepted = [];
  int rawCount(String event) => raw.where((item) => item == event).length;
  int acceptedCount(String event) =>
      accepted.where((item) => item == event).length;
}

final class _Owner extends ChangeNotifier {
  void ping() => notifyListeners();
}

class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.fixture,
    required this.log,
    this.textScale = 1,
  });

  final WorkItemHealthFixture fixture;
  final _Log log;
  final double textScale;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late Account account = healthAccount();
  late GitLabApi api = testApi(widget.fixture.adapter);
  int generation = 7;
  bool current = true;
  final _Owner owner = _Owner();
  bool showControl = true;
  bool denyReserve = false;
  bool throwOnStart = false;
  bool closeApiOnStart = false;
  Object? token;
  String? _tokenAccount;
  GitLabApi? _tokenApi;
  int? _tokenGeneration;
  int builds = 0;

  _Log get log => widget.log;

  void replace(VoidCallback change) => setState(change);

  bool _matches(Object candidate) =>
      identical(candidate, token) &&
      _tokenAccount == account.key &&
      identical(_tokenApi, api) &&
      _tokenGeneration == generation &&
      current;

  bool _reserve(Object candidate) {
    log.raw.add('reserve');
    if (!mounted || denyReserve || token != null || !current) {
      log.raw.add('reserve-denied');
      return false;
    }
    setState(() {
      token = candidate;
      _tokenAccount = account.key;
      _tokenApi = api;
      _tokenGeneration = generation;
    });
    log.accepted.add('reserve');
    return true;
  }

  void _release(Object candidate) {
    log.raw.add('release');
    if (!mounted || !identical(candidate, token)) {
      log.raw.add('release-ignored');
      return;
    }
    setState(() => token = null);
    log.accepted.add('release');
  }

  void _phase(WorkItemHealthWritePhase phase, Object candidate) {
    log.raw.add(phase.name);
    if (!mounted) {
      log.raw.add('ignored-disposed');
      return;
    }
    if (!_matches(candidate)) {
      log.raw.add('ignored-${phase.name}');
      return;
    }
    if (phase == WorkItemHealthWritePhase.start) {
      log.accepted.add('start');
      if (closeApiOnStart) api.close();
      if (throwOnStart) throw StateError('synthetic START observer failure');
      return;
    }
    setState(() => token = null);
    log.accepted.add('settle');
  }

  @override
  void dispose() {
    owner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    builds++;
    return MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(widget.textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: ListView(
          children: [
            const ListTile(title: Text('健康狀態')),
            if (showControl)
              WorkItemHealthControl(
                key: const ValueKey('health-row'),
                api: api,
                account: account,
                detail: healthDetail(),
                generation: generation,
                isCurrent: () => mounted && current,
                changes: owner,
                enabled: token == null,
                reserveWrite: _reserve,
                releaseUnsentWrite: _release,
                onWritePhase: _phase,
                onOutcome: (candidate, outcome) =>
                    log.raw.add('outcome-${outcome.name}'),
              ),
          ],
        ),
      ),
    );
  }
}

final _hostKey = GlobalKey<_HostState>();
final _edit = find.byKey(const ValueKey('work-item-health-edit'));
final _save = find.byKey(const ValueKey('work-item-health-save'));
final _cancel = find.byKey(const ValueKey('work-item-health-cancel'));
final _feedback = find.byKey(const ValueKey('work-item-health-feedback'));
Finder _choice(String name) =>
    find.byKey(ValueKey('work-item-health-choice-$name'));

Future<_Log> _pumpHost(
  WidgetTester tester,
  WorkItemHealthFixture fixture, {
  double textScale = 1,
}) async {
  addTearDown(fixture.releaseAll);
  final log = _Log();
  await tester.pumpWidget(
    _Host(key: _hostKey, fixture: fixture, log: log, textScale: textScale),
  );
  return log;
}

Future<void> _open(WidgetTester tester, WorkItemHealthFixture fixture) async {
  final reads = fixture.reads;
  await tester.tap(_edit);
  await pumpUntil(
    tester,
    () => _save.evaluate().isNotEmpty && fixture.reads == reads + 1,
    description: 'editor opened from a real Health read',
  );
  await tester.pump(const Duration(milliseconds: 400));
}

bool _saveEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(_save).onPressed != null;

Future<void> _frames(WidgetTester tester, [int count = 6]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
}

void _expectClean(WorkItemHealthFixture fixture) {
  expect(fixture.unknownRequests, isEmpty);
  expect(fixture.authorizationPresent, everyElement(isTrue));
  expect(fixture.redirectsDisabled, everyElement(isTrue));
  expect(fixture.mutationsReceived, lessThanOrEqualTo(1));
}

void main() {
  test('fixture releaseAll releases a read gate already consumed by a parked '
      'read', () async {
    final fixture = WorkItemHealthFixture();
    addTearDown(fixture.releaseAll);
    final gate = HealthGate();
    addTearDown(gate.release);
    fixture.nextReadGate = gate;
    final api = testApi(fixture.adapter);
    addTearDown(api.close);

    final read = api.workItemHealthEdit(
      healthDetail(),
      expectedUserId: healthUserId,
      generation: 7,
      isCurrent: () => true,
    );
    unawaited(read.then<void>((_) {}, onError: (Object _) {}));
    await gate.reached.timeout(const Duration(seconds: 5));
    expect(gate.isReached, isTrue);
    expect(gate.isReleased, isFalse);
    expect(fixture.reads, 1);

    fixture.releaseAll();

    expect(gate.isReleased, isTrue);
    final access = await read.timeout(const Duration(seconds: 5));
    expect(access.snapshot.value, WorkItemHealthEditValue.needsAttention);
    expect(fixture.reads, 1);
    _expectClean(fixture);
  });

  testWidgets('opens with real access and shows CJK value, rollup and four '
      'explicit choices', (tester) async {
    final fixture = WorkItemHealthFixture();
    await _pumpHost(tester, fixture);
    await _open(tester, fixture);

    expect(find.text('讀取時：需關注'), findsOneWidget);
    expect(find.text('子項目彙整：正常 2'), findsOneWidget);
    expect(find.text('未設定（清除健康狀態）'), findsOneWidget);
    expect(find.text('正常'), findsOneWidget);
    expect(find.text('需關注'), findsOneWidget);
    expect(find.text('有風險'), findsOneWidget);
    expect(find.textContaining('@health-owner'), findsOneWidget);
    expect(find.text('studio/mobile-workspace · 工作項目 #31'), findsOneWidget);
    expect(_saveEnabled(tester), isTrue);
    expect(find.byType(CalendarDatePicker), findsNothing);
    expect(fixture.operations, ['read']);
    _expectClean(fixture);
  });

  testWidgets('reservation denial burns the target and sends zero requests', (
    tester,
  ) async {
    final fixture = WorkItemHealthFixture();
    final log = await _pumpHost(tester, fixture);
    await _open(tester, fixture);
    _hostKey.currentState!.denyReserve = true;
    final requests = fixture.requests;

    await tester.tap(_choice('atRisk'));
    await tester.pump();
    await tester.tap(_save);
    await _frames(tester);

    expect(fixture.requests, requests);
    expect(log.raw, ['reserve', 'reserve-denied']);
    expect(find.text('目前有其他變更進行中，沒有送出健康狀態變更。'), findsOneWidget);
    expect(_saveEnabled(tester), isFalse);
    _expectClean(fixture);
  });

  testWidgets('fresh preflight noop releases once with zero START', (
    tester,
  ) async {
    final fixture = WorkItemHealthFixture();
    final log = await _pumpHost(tester, fixture);
    await _open(tester, fixture);

    await tester.tap(_save);
    await pumpUntil(tester, () => _feedback.evaluate().isNotEmpty);

    expect(fixture.operations, ['read', 'read']);
    expect(log.raw, ['reserve', 'release', 'outcome-noop']);
    expect(log.rawCount('start'), 0);
    expect(find.text('健康狀態已是「需關注」，沒有送出變更。'), findsOneWidget);
    expect(_saveEnabled(tester), isFalse);
    expect(_hostKey.currentState!.token, isNull);
    _expectClean(fixture);
  });

  testWidgets('fresh preflight permission denial releases once with zero '
      'START', (tester) async {
    final fixture = WorkItemHealthFixture();
    final log = await _pumpHost(tester, fixture);
    await _open(tester, fixture);
    fixture.adminWorkItem = false;

    await tester.tap(_choice('onTrack'));
    await tester.pump();
    await tester.tap(_save);
    await pumpUntil(tester, () => _feedback.evaluate().isNotEmpty);

    expect(fixture.mutationsReceived, 0);
    expect(log.raw, ['reserve', 'release', 'outcome-notSent']);
    expect(find.textContaining('沒有送出健康狀態變更。'), findsOneWidget);
    expect(find.textContaining('權限'), findsWidgets);
    _expectClean(fixture);
  });

  testWidgets('START observer throw is invalidResponse false with zero sends '
      'and one settle', (tester) async {
    final fixture = WorkItemHealthFixture();
    final log = await _pumpHost(tester, fixture);
    await _open(tester, fixture);
    _hostKey.currentState!.throwOnStart = true;

    await tester.tap(_choice('atRisk'));
    await tester.pump();
    await tester.tap(_save);
    await pumpUntil(tester, () => _feedback.evaluate().isNotEmpty);

    expect(fixture.mutationsReceived, 0);
    expect(fixture.value, WorkItemHealthEditValue.needsAttention);
    expect(log.raw, ['reserve', 'start', 'settle', 'outcome-notSent']);
    expect(log.accepted, ['reserve', 'start', 'settle']);
    expect(
      find.textContaining(const ApiFailure(FailureKind.invalidResponse).detail),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('work-item-health-confirmed')),
      findsNothing,
    );
    _expectClean(fixture);
  });

  for (final (name, arrange, outcome, text)
      in <
        (
          String,
          void Function(WorkItemHealthFixture, _HostState),
          String,
          String,
        )
      >[
        (
          'payload validation is rejected with mutationSent true',
          (fixture, host) => fixture.nextMutationErrors = ['Health is invalid'],
          'rejected',
          'GitLab 未接受健康狀態更新',
        ),
        (
          'transport failure is unknown with mutationSent true',
          (fixture, host) => fixture.nextMutationTransportFailure = true,
          'unknown',
          '尚未確認健康狀態是否已更新',
        ),
        (
          'START observer closing the API is unknown with mutationSent true',
          (fixture, host) => host.closeApiOnStart = true,
          'unknown',
          '尚未確認健康狀態是否已更新',
        ),
      ]) {
    testWidgets('post-handoff $name and settles once', (tester) async {
      final fixture = WorkItemHealthFixture();
      final log = await _pumpHost(tester, fixture);
      await _open(tester, fixture);
      arrange(fixture, _hostKey.currentState!);

      await tester.tap(_choice('atRisk'));
      await tester.pump();
      await tester.tap(_save);
      await pumpUntil(tester, () => _feedback.evaluate().isNotEmpty);

      expect(log.raw, ['reserve', 'start', 'settle', 'outcome-$outcome']);
      expect(log.rawCount('release'), 0);
      expect(find.textContaining(text), findsOneWidget);
      expect(
        find.byKey(const ValueKey('work-item-health-confirmed')),
        findsNothing,
      );
      expect(_saveEnabled(tester), isFalse);
      expect(fixture.appliedChanges, 0);
      _expectClean(fixture);
    });
  }

  for (final (choice, desired, graphValue, confirmed)
      in <(String, WorkItemHealthEditValue?, String?, String)>[
        (
          'atRisk',
          WorkItemHealthEditValue.atRisk,
          'atRisk',
          'GitLab 已確認健康狀態為「有風險」。',
        ),
        ('clear', null, null, 'GitLab 已確認清除健康狀態。'),
      ]) {
    testWidgets('$choice applies a same-second change confirmed by an '
        'independent readback and settles once', (tester) async {
      final fixture = WorkItemHealthFixture();
      final log = await _pumpHost(tester, fixture);
      await _open(tester, fixture);
      final revision = fixture.updatedAt;

      await tester.tap(_choice(choice));
      await tester.pump();
      await tester.tap(_save);
      await pumpUntil(tester, () => _feedback.evaluate().isNotEmpty);

      expect(fixture.operations, ['read', 'read', 'mutation', 'apply', 'read']);
      expect(fixture.updatedAt, revision);
      expect(fixture.value, desired);
      expect(fixture.mutationInputs.single, {
        'id': healthSummary().id,
        'healthStatusWidget': {'healthStatus': graphValue},
      });
      expect(log.raw, ['reserve', 'start', 'settle', 'outcome-confirmed']);
      expect(find.text(confirmed), findsOneWidget);
      expect(
        find.text('伺服器回讀：${desired == null ? '未設定' : '有風險'}'),
        findsOneWidget,
      );
      expect(_saveEnabled(tester), isFalse);
      _expectClean(fixture);
    });
  }

  testWidgets('notApplied acknowledgement is reported truthfully', (
    tester,
  ) async {
    final fixture = WorkItemHealthFixture()..nextMutationNotApplied = true;
    final log = await _pumpHost(tester, fixture);
    await _open(tester, fixture);

    await tester.tap(_choice('onTrack'));
    await tester.pump();
    await tester.tap(_save);
    await pumpUntil(tester, () => _feedback.evaluate().isNotEmpty);

    expect(fixture.operations, ['read', 'read', 'mutation', 'read']);
    expect(log.raw, ['reserve', 'start', 'settle', 'outcome-notApplied']);
    expect(find.text('GitLab 沒有套用這次變更，健康狀態仍為「需關注」。'), findsOneWidget);
    _expectClean(fixture);
  });

  testWidgets('duplicate Save taps send once and the burned target never '
      'replays', (tester) async {
    final fixture = WorkItemHealthFixture()..beforeAck = HealthGate();
    final log = await _pumpHost(tester, fixture);
    await _open(tester, fixture);

    await tester.tap(_choice('atRisk'));
    await tester.pump();
    await tester.tap(_save);
    await tester.tap(_save, warnIfMissed: false);
    await pumpUntil(tester, () => fixture.beforeAck!.isReached);
    await tester.tap(_save, warnIfMissed: false);
    await _frames(tester);
    expect(fixture.mutationsReceived, 1);
    expect(log.rawCount('reserve'), 1);

    fixture.beforeAck!.release();
    await pumpUntil(tester, () => _feedback.evaluate().isNotEmpty);
    await tester.tap(_save, warnIfMissed: false);
    await _frames(tester);

    expect(fixture.mutationsReceived, 1);
    expect(log.rawCount('reserve'), 1);
    expect(log.rawCount('settle'), 1);
    _expectClean(fixture);
  });

  for (final (name, change) in <(String, void Function(_HostState))>[
    (
      'account',
      (host) => host.account = healthAccount(id: 8, username: 'other'),
    ),
    ('API', (host) => host.api = testApi(host.widget.fixture.adapter)),
    ('generation', (host) => host.generation = 8),
    (
      'owner current',
      (host) {
        host.current = false;
        host.owner.ping();
      },
    ),
  ]) {
    testWidgets('held load result is dropped after $name changes', (
      tester,
    ) async {
      final fixture = WorkItemHealthFixture();
      final log = await _pumpHost(tester, fixture);
      final gate = HealthGate();
      fixture.nextReadGate = gate;
      await tester.tap(_edit);
      await pumpUntil(
        tester,
        () => gate.isReached,
        description: 'opening read parked on the armed gate',
      );
      expect(gate.isReleased, isFalse);
      expect(fixture.readsAnswered, 0);
      expect(find.text('讀取健康狀態…'), findsOneWidget);

      _hostKey.currentState!.replace(() => change(_hostKey.currentState!));
      await tester.pump();
      gate.release();
      await pumpUntil(
        tester,
        () => fixture.readsAnswered == 1,
        description: 'stale opening read answered by the server',
      );
      await _frames(tester, 10);

      expect(fixture.reads, 1);
      expect(fixture.readsAnswered, 1);
      expect(_save, findsNothing);
      expect(log.raw, isEmpty);
      expect(_hostKey.currentState!.token, isNull);
      expect(fixture.mutationsReceived, 0);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      _expectClean(fixture);
    });
  }

  testWidgets('dispose before handoff releases the unsent reservation once '
      'and never sends', (tester) async {
    final fixture = WorkItemHealthFixture();
    final log = await _pumpHost(tester, fixture);
    await _open(tester, fixture);
    final preflight = HealthGate();
    fixture.nextReadGate = preflight;

    await tester.tap(_choice('atRisk'));
    await tester.pump();
    await tester.tap(_save);
    await pumpUntil(tester, () => preflight.isReached);
    await tester.tap(_cancel);
    await pumpUntil(
      tester,
      () => _save.evaluate().isEmpty,
      description: 'editor route disposed',
    );
    expect(log.raw, ['reserve', 'release']);
    expect(log.accepted, ['reserve', 'release']);
    expect(_hostKey.currentState!.token, isNull);
    expect(tester.takeException(), isNull);
    await pumpUntil(
      tester,
      () => tester.widget<TextButton>(_edit).onPressed != null,
      description: 'parent rebuild after the accepted release re-enables edit',
    );

    preflight.release();
    await _frames(tester, 10);

    expect(fixture.mutationsReceived, 0);
    expect(log.rawCount('start'), 0);
    expect(log.rawCount('settle'), 0);
    expect(log.rawCount('release'), 1);
    expect(log.acceptedCount('release'), 1);
    expect(log.raw.last, 'outcome-notSent');
    expect(_hostKey.currentState!.token, isNull);
    expect(tester.takeException(), isNull);

    await _open(tester, fixture);
    expect(_saveEnabled(tester), isTrue);
    expect(log.accepted, ['reserve', 'release']);
    expect(fixture.mutationsReceived, 0);
    _expectClean(fixture);
  });

  testWidgets('binding change before handoff releases the held reservation '
      'outside dispose and never starts or sends', (tester) async {
    final fixture = WorkItemHealthFixture();
    final log = await _pumpHost(tester, fixture);
    await _open(tester, fixture);
    final host = _hostKey.currentState!;
    final preflight = HealthGate();
    fixture.nextReadGate = preflight;

    await tester.tap(_choice('atRisk'));
    await tester.pump();
    await tester.tap(_save);
    await pumpUntil(
      tester,
      () => preflight.isReached,
      description: 'fresh preflight read parked',
    );
    expect(log.accepted, ['reserve']);
    expect(host.token, isNotNull);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(
              const ValueKey('work-item-health-edit'),
              skipOffstage: false,
            ),
          )
          .onPressed,
      isNull,
    );

    host.replace(() => host.generation = 8);
    await pumpUntil(
      tester,
      () => _save.evaluate().isEmpty,
      description: 'editor removed by the binding change',
    );
    await pumpUntil(
      tester,
      () => tester.widget<TextButton>(_edit).onPressed != null,
      description: 'parent rebuild after the accepted release re-enables edit',
    );
    expect(log.raw, ['reserve', 'release']);
    expect(log.accepted, ['reserve', 'release']);
    expect(host.token, isNull);
    expect(fixture.mutationsReceived, 0);
    expect(tester.takeException(), isNull);

    preflight.release();
    await pumpUntil(
      tester,
      () => log.raw.contains('outcome-notSent'),
      description: 'operation reported the unsent write',
    );
    await _frames(tester, 10);

    expect(fixture.operations, ['read', 'read']);
    expect(fixture.mutationsReceived, 0);
    expect(log.rawCount('start'), 0);
    expect(log.rawCount('settle'), 0);
    expect(log.rawCount('release'), 1);
    expect(log.accepted, ['reserve', 'release']);
    expect(log.raw.last, 'outcome-notSent');
    expect(host.token, isNull);
    expect(tester.takeException(), isNull);
    _expectClean(fixture);
  });

  testWidgets('BEFORE_APPLY and BEFORE_ACK holds survive editor pop and row '
      'unmount until the exact update Future completes', (tester) async {
    final fixture = WorkItemHealthFixture()
      ..beforeApply = HealthGate()
      ..beforeAck = HealthGate();
    final log = await _pumpHost(tester, fixture);
    await _open(tester, fixture);
    final host = _hostKey.currentState!;

    await tester.tap(_choice('atRisk'));
    await tester.pump();
    await tester.tap(_save);
    await pumpUntil(tester, () => fixture.beforeApply!.isReached);
    expect(log.raw, ['reserve', 'start']);
    final heldToken = host.token;
    expect(heldToken, isNotNull);

    await tester.tap(_cancel);
    await pumpUntil(
      tester,
      () => _save.evaluate().isEmpty,
      description: 'editor route disposed while the write is pending',
    );
    expect(log.rawCount('settle'), 0);
    host.replace(() => host.showControl = false);
    await _frames(tester);
    expect(find.byKey(const ValueKey('health-row')), findsNothing);
    expect(_save, findsNothing);

    // PRE_APPLY: backend received the mutation, server state still old.
    expect(fixture.mutationsReceived, 1);
    expect(fixture.appliedChanges, 0);
    expect(fixture.value, WorkItemHealthEditValue.needsAttention);
    expect(log.rawCount('settle'), 0);
    expect(log.rawCount('release'), 0);
    expect(identical(host.token, heldToken), isTrue);

    // A competing row stays gated: disabled open, denied reservation.
    host.replace(() => host.showControl = true);
    await _frames(tester);
    expect(tester.widget<TextButton>(_edit).onPressed, isNull);
    final reads = fixture.reads;
    expect(host._reserve(Object()), isFalse);
    expect(fixture.reads, reads);
    host.replace(() => host.showControl = false);
    await _frames(tester);

    fixture.beforeApply!.release();
    await pumpUntil(tester, () => fixture.beforeAck!.isReached);
    expect(fixture.appliedChanges, 1);
    expect(fixture.value, WorkItemHealthEditValue.atRisk);
    await _frames(tester);
    expect(log.rawCount('settle'), 0);
    expect(identical(host.token, heldToken), isTrue);
    expect(fixture.reads, reads);

    fixture.beforeAck!.release();
    await pumpUntil(tester, () => log.rawCount('settle') == 1);
    await _frames(tester);

    expect(fixture.operations, ['read', 'read', 'mutation', 'apply', 'read']);
    expect(log.raw, [
      'reserve',
      'start',
      'reserve',
      'reserve-denied',
      'settle',
      'outcome-confirmed',
    ]);
    expect(log.accepted, ['reserve', 'start', 'settle']);
    expect(log.rawCount('settle'), 1);
    expect(log.rawCount('release'), 0);
    expect(host.token, isNull);
    expect(tester.takeException(), isNull);
    _expectClean(fixture);
  });

  testWidgets('fully disposed parent ignores the late terminal callback at '
      'the host guard', (tester) async {
    final fixture = WorkItemHealthFixture()..beforeAck = HealthGate();
    final log = await _pumpHost(tester, fixture);
    await _open(tester, fixture);

    await tester.tap(_choice('onTrack'));
    await tester.pump();
    await tester.tap(_save);
    await pumpUntil(tester, () => fixture.beforeAck!.isReached);
    await tester.pumpWidget(const SizedBox());
    await _frames(tester);
    expect(log.rawCount('settle'), 0);

    fixture.beforeAck!.release();
    await pumpUntil(tester, () => log.rawCount('settle') == 1);
    await _frames(tester);

    expect(log.raw, contains('ignored-disposed'));
    expect(log.acceptedCount('settle'), 0);
    expect(log.rawCount('release'), 0);
    expect(fixture.mutationsReceived, 1);
    expect(tester.takeException(), isNull);
    _expectClean(fixture);
  });

  testWidgets('generation change after handoff is rejected by the host guard '
      'while the operation still settles once', (tester) async {
    final fixture = WorkItemHealthFixture()..beforeApply = HealthGate();
    final log = await _pumpHost(tester, fixture);
    await _open(tester, fixture);
    final host = _hostKey.currentState!;

    await tester.tap(_choice('atRisk'));
    await tester.pump();
    await tester.tap(_save);
    await pumpUntil(tester, () => fixture.beforeApply!.isReached);
    host.replace(() => host.generation = 8);
    await _frames(tester);
    expect(_save, findsNothing);

    fixture.beforeApply!.release();
    await pumpUntil(tester, () => log.rawCount('settle') == 1);
    await _frames(tester);

    expect(log.raw, contains('ignored-settle'));
    expect(log.acceptedCount('settle'), 0);
    expect(log.rawCount('release'), 0);
    expect(fixture.mutationsReceived, 1);
    expect(tester.takeException(), isNull);
    _expectClean(fixture);
  });

  for (final (name, arrange, text)
      in <(String, void Function(WorkItemHealthFixture), String)>[
        (
          'unavailable widgets',
          (fixture) => fixture.widgets = HealthWidgetMode.unavailable,
          '實例沒有提供這個工作項目的元件資訊，健康狀態僅供檢視。',
        ),
        (
          'absent widget',
          (fixture) => fixture.widgets = HealthWidgetMode.absent,
          '這個工作項目類型沒有健康狀態欄位。',
        ),
        (
          'missing admin permission',
          (fixture) => fixture.adminWorkItem = false,
          '目前帳號沒有管理這個工作項目健康狀態的權限，僅供檢視。',
        ),
      ]) {
    testWidgets('read-only copy for $name', (tester) async {
      final fixture = WorkItemHealthFixture();
      arrange(fixture);
      final log = await _pumpHost(tester, fixture);
      await _open(tester, fixture);

      expect(find.text(text), findsOneWidget);
      expect(_choice('atRisk'), findsNothing);
      expect(_saveEnabled(tester), isFalse);
      expect(log.raw, isEmpty);
      _expectClean(fixture);
    });
  }

  testWidgets('unknown widget value and missing read permission fail closed '
      'without an editor', (tester) async {
    for (final arrange in <void Function(WorkItemHealthFixture)>[
      (fixture) => fixture.widgets = HealthWidgetMode.unknownValue,
      (fixture) => fixture.readWorkItem = false,
    ]) {
      final fixture = WorkItemHealthFixture();
      arrange(fixture);
      final log = await _pumpHost(tester, fixture);
      await tester.tap(_edit);
      await pumpUntil(
        tester,
        () => find.byType(SnackBar).evaluate().isNotEmpty,
      );

      expect(_save, findsNothing);
      expect(log.raw, isEmpty);
      expect(fixture.mutationsReceived, 0);
      _expectClean(fixture);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('320dp at 2x text wraps CJK, keeps 48dp controls reachable and '
      'docks above one IME inset', (tester) async {
    tester.view.physicalSize = const Size(640, 1600);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final fixture = WorkItemHealthFixture();
    await _pumpHost(tester, fixture, textScale: 2);
    await _open(tester, fixture);

    const logicalHeight = 800.0;
    final scroll = find.byKey(const ValueKey('work-item-health-scroll'));
    final scrollable = find.descendant(
      of: scroll,
      matching: find.byType(Scrollable),
    );
    for (final key in [
      'work-item-health-save',
      'work-item-health-cancel',
      'work-item-health-choice-clear',
      'work-item-health-choice-atRisk',
    ]) {
      final target = find.byKey(ValueKey(key));
      if (key.startsWith('work-item-health-choice-')) {
        await tester.scrollUntilVisible(
          target,
          100,
          scrollable: scrollable,
          maxScrolls: 20,
        );
      }
      final size = tester.getSize(target);
      expect(size.height, greaterThanOrEqualTo(48), reason: key);
      expect(size.width, lessThanOrEqualTo(320), reason: key);
    }
    await tester.scrollUntilVisible(
      find.text('有風險'),
      100,
      scrollable: find.descendant(
        of: scroll,
        matching: find.byType(Scrollable),
      ),
    );
    expect(tester.takeException(), isNull);

    const keyboardPhysical = 600.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboardPhysical);
    await tester.pump();
    const inset = keyboardPhysical / 2;
    expect(
      tester.getBottomLeft(_save).dy,
      lessThanOrEqualTo(logicalHeight - inset),
    );
    expect(
      tester.getBottomLeft(_cancel).dy,
      lessThanOrEqualTo(logicalHeight - inset),
    );
    expect(
      tester.getBottomLeft(_save).dy,
      greaterThan(logicalHeight - inset - 120),
      reason: 'single inset only, not doubled',
    );
    expect(tester.takeException(), isNull);

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    expect(tester.getBottomLeft(_save).dy, greaterThan(logicalHeight - 120));
    expect(tester.takeException(), isNull);
    _expectClean(fixture);
  });

  for (final exit in _EditorExit.values) {
    testWidgets('${exit.label} without a write re-enables edit with no parent '
        'rebuild and a second real tap reopens from a fresh read', (
      tester,
    ) async {
      final fixture = WorkItemHealthFixture();
      final log = await _pumpHost(tester, fixture);
      final host = _hostKey.currentState!;
      await _open(tester, fixture);
      final builds = host.builds;

      await _exitEditor(tester, exit);
      await tester.pumpAndSettle();

      expect(_save, findsNothing);
      expect(host.builds, builds, reason: 'no parent rebuild after the exit');
      expect(tester.widget<TextButton>(_edit).onPressed, isNotNull);
      expect(find.text('變更健康狀態'), findsOneWidget);

      await _open(tester, fixture);
      expect(_saveEnabled(tester), isTrue);
      expect(host.builds, builds);
      expect(fixture.operations, ['read', 'read']);
      expect(log.raw, isEmpty);
      expect(host.token, isNull);
      expect(tester.takeException(), isNull);
      _expectClean(fixture);
    });

    testWidgets('${exit.label} without a write re-enables edit on the detail '
        'route and a second real tap reopens from a fresh read', (
      tester,
    ) async {
      final fixture = WorkItemHealthFixture();
      final h = await _pumpDetailRoute(tester, fixture);
      await _openDetail(tester, fixture, h);
      final editor = h.editorRoute!;

      await _exitEditor(tester, exit);
      await tester.pumpAndSettle();

      _expectEditorClosedOverDetail(h, editor);
      expect(tester.widget<TextButton>(_edit).onPressed, isNotNull);

      await _openDetail(tester, fixture, h);
      expect(identical(h.editorRoute, editor), isFalse);
      expect(_saveEnabled(tester), isTrue);
      expect(fixture.operations, ['read', 'read']);
      expect(h.token, isNull);
      expect(h.phases, isEmpty);
      expect(tester.takeException(), isNull);
      _expectClean(fixture);
    });
  }

  testWidgets('owner loss with the editor open removes it without re-enabling '
      'the stale binding; a restored owner reopens from a fresh read', (
    tester,
  ) async {
    final fixture = WorkItemHealthFixture();
    final log = await _pumpHost(tester, fixture);
    final host = _hostKey.currentState!;
    await _open(tester, fixture);

    host.current = false;
    host.owner.ping();
    await tester.pumpAndSettle();

    expect(_save, findsNothing);
    expect(tester.widget<TextButton>(_edit).onPressed, isNull);
    await _frames(tester);
    expect(tester.widget<TextButton>(_edit).onPressed, isNull);
    expect(fixture.reads, 1);

    host.current = true;
    host.owner.ping();
    await tester.pump();
    expect(tester.widget<TextButton>(_edit).onPressed, isNotNull);

    await _open(tester, fixture);
    expect(_saveEnabled(tester), isTrue);
    expect(fixture.operations, ['read', 'read']);
    expect(log.raw, isEmpty);
    expect(tester.takeException(), isNull);
    _expectClean(fixture);
  });

  testWidgets('row dispose with the editor open removes it without painting '
      'the disposed control; a remounted row opens from a fresh read', (
    tester,
  ) async {
    final fixture = WorkItemHealthFixture();
    final log = await _pumpHost(tester, fixture);
    final host = _hostKey.currentState!;
    await _open(tester, fixture);

    host.replace(() => host.showControl = false);
    await tester.pumpAndSettle();

    expect(_save, findsNothing);
    expect(_edit, findsNothing);
    expect(tester.takeException(), isNull);

    host.replace(() => host.showControl = true);
    await tester.pump();
    await _open(tester, fixture);
    expect(_saveEnabled(tester), isTrue);
    expect(fixture.operations, ['read', 'read']);
    expect(log.raw, isEmpty);
    expect(tester.takeException(), isNull);
    _expectClean(fixture);
  });

  for (final exit in _EditorExit.values) {
    testWidgets(
      '${exit.label} before START closes the gate while the exit transition runs',
      (tester) async {
        final fixture = WorkItemHealthFixture();
        final h = await _pumpDetailRoute(tester, fixture);
        await _openDetail(tester, fixture, h);
        final editor = h.editorRoute!;
        await tester.tap(_choice('atRisk'));
        await tester.pump();

        final gate = HealthGate();
        fixture.nextReadGate = gate;
        final reads = fixture.reads;
        final readsAnswered = fixture.readsAnswered;

        await tester.tap(find.byKey(const ValueKey('work-item-health-save')));
        await pumpUntil(tester, () => fixture.reads > reads);
        expect(fixture.reads, reads + 1);
        expect(fixture.readsAnswered, readsAnswered);
        expect(gate.isReached, isTrue);

        await _exitEditor(tester, exit);
        _expectEditorExiting(h, editor);

        gate.release();
        await _driveNetworkWithFrozenClock(
          tester,
          () => fixture.readsAnswered > readsAnswered,
          description: 'held fence read responds during the exit transition',
        );
        await _driveNetworkWithFrozenClock(tester, () => false, cycles: 30);

        expect(fixture.mutationsReceived, 0);
        expect(_mutationRequests(fixture), 0);
        expect(h.phases, isEmpty);
        expect(h.token, isNull);
        _expectEditorExiting(h, editor);

        await settleNetworkWidgets(tester);
        _expectEditorClosedOverDetail(h, editor);
        expect(fixture.mutationsReceived, 0);
        expect(_mutationRequests(fixture), 0);
        expect(h.phases, isEmpty);
        expect(h.token, isNull);
        expect(
          find.byKey(const ValueKey('work-item-health-edit')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${exit.label} after START keeps the detail route when ACK and readback '
      'land during the exit transition',
      (tester) async {
        final gate = HealthGate();
        final fixture = WorkItemHealthFixture()..beforeAck = gate;
        final h = await _pumpDetailRoute(tester, fixture);
        await _openDetail(tester, fixture, h);
        final editor = h.editorRoute!;
        await tester.tap(_choice('atRisk'));
        await tester.pump();

        await tester.tap(find.byKey(const ValueKey('work-item-health-save')));
        await pumpUntil(tester, () => fixture.appliedChanges == 1);
        expect(h.phases.map((entry) => entry.$1), [
          WorkItemHealthWritePhase.start,
        ]);
        expect(fixture.acksAnswered, 0);

        await _exitEditor(tester, exit);
        _expectEditorExiting(h, editor);

        gate.release();
        await _driveNetworkWithFrozenClock(
          tester,
          () => h.phases.length == 2,
          description: 'write Future terminal during the exit transition',
        );

        _expectEditorExiting(h, editor);
        expect(fixture.acksAnswered, 1);
        expect(fixture.mutationsReceived, 1);
        expect(fixture.value, WorkItemHealthEditValue.atRisk);
        expect(h.phases.map((entry) => entry.$1), [
          WorkItemHealthWritePhase.start,
          WorkItemHealthWritePhase.settle,
        ]);
        expect(identical(h.phases[0].$2, h.phases[1].$2), isTrue);
        expect(h.token, isNull);
        expect(
          find.byKey(
            const ValueKey('work-item-health-feedback'),
            skipOffstage: false,
          ),
          findsNothing,
        );

        await settleNetworkWidgets(tester);
        _expectEditorClosedOverDetail(h, editor);
        expect(h.phases, hasLength(2));
        expect(fixture.mutationsReceived, 1);
        expect(_mutationRequests(fixture), 1);
        expect(
          find.byKey(const ValueKey('work-item-health-edit')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'after the editor fully closes a held write settles once without UI or '
    'navigation',
    (tester) async {
      final applyGate = HealthGate();
      final ackGate = HealthGate();
      final fixture = WorkItemHealthFixture()
        ..beforeApply = applyGate
        ..beforeAck = ackGate;
      final h = await _pumpDetailRoute(tester, fixture);
      await _openDetail(tester, fixture, h);
      final editor = h.editorRoute!;
      await tester.tap(_choice('atRisk'));
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('work-item-health-save')));
      await pumpUntil(tester, () => fixture.mutationsReceived == 1);
      expect(fixture.appliedChanges, 0);

      await tester.tap(find.byKey(const ValueKey('work-item-health-cancel')));
      await tester.pumpAndSettle();
      _expectEditorClosedOverDetail(h, editor);
      expect(h.phases.map((entry) => entry.$1), [
        WorkItemHealthWritePhase.start,
      ]);

      final newer = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('newer-page')),
      );
      unawaited(h.navigator.push(newer));
      await tester.pumpAndSettle();
      expect(newer.isCurrent, isTrue);

      applyGate.release();
      await pumpUntil(tester, () => fixture.appliedChanges == 1);
      expect(h.phases, hasLength(1));
      ackGate.release();
      await settleNetworkWidgets(tester);

      expect(h.phases.map((entry) => entry.$1), [
        WorkItemHealthWritePhase.start,
        WorkItemHealthWritePhase.settle,
      ]);
      expect(identical(h.phases[0].$2, h.phases[1].$2), isTrue);
      expect(h.token, isNull);
      expect(newer.isCurrent, isTrue);
      expect(h.detailRoute.isActive, isTrue);
      expect(h.log.popped, [editor]);
      expect(h.log.removed, isEmpty);
      expect(fixture.mutationsReceived, 1);
      expect(_mutationRequests(fixture), 1);
      expect(fixture.acksAnswered, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'close button under a newer covering route removes only its own editor route',
    (tester) async {
      final fixture = WorkItemHealthFixture();
      final h = await _pumpDetailRoute(tester, fixture);
      await _openDetail(tester, fixture, h);
      final editor = h.editorRoute!;

      final newer = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('newer-page')),
      );
      unawaited(h.navigator.push(newer));
      await tester.pumpAndSettle();
      expect(newer.isCurrent, isTrue);
      expect(editor.isActive, isTrue);

      final cancelButton = tester.widget<OutlinedButton>(
        find.byKey(
          const ValueKey('work-item-health-cancel'),
          skipOffstage: false,
        ),
      );
      cancelButton.onPressed?.call();
      await tester.pumpAndSettle();

      expect(newer.isCurrent, isTrue);
      expect(find.text('newer-page'), findsOneWidget);
      expect(editor.isActive, isFalse);
      expect(h.detailRoute.isActive, isTrue);
      expect(h.log.popped, isEmpty);
      expect(h.log.removed, [editor]);
      expect(tester.takeException(), isNull);
    },
  );
}

enum _EditorExit {
  cancel('Cancel'),
  systemBack('system back');

  const _EditorExit(this.label);
  final String label;
}

Future<void> _exitEditor(WidgetTester tester, _EditorExit exit) async {
  switch (exit) {
    case _EditorExit.cancel:
      await tester.tap(find.byKey(const ValueKey('work-item-health-cancel')));
      break;
    case _EditorExit.systemBack:
      expect(await tester.binding.handlePopRoute(), isTrue);
      break;
  }
  // Zero-duration frame: starts the reverse animation without advancing it.
  await tester.pump();
}

/// Runs real Dio turns with zero-duration frames, so the route animation clock
/// stays inside the exit transition while network work completes.
Future<void> _driveNetworkWithFrozenClock(
  WidgetTester tester,
  bool Function() condition, {
  int cycles = 120,
  String? description,
}) async {
  for (var cycle = 0; cycle < cycles; cycle++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump(Duration.zero);
  }
  if (description != null && !condition()) {
    fail('timed out with a frozen clock: $description');
  }
}

void _expectEditorExiting(_DetailRouteHarness h, Route<dynamic> editor) {
  expect(
    (editor as TransitionRoute<dynamic>).animation!.status,
    AnimationStatus.reverse,
  );
  expect(editor.isActive, isFalse);
  expect(
    find.byKey(const ValueKey('work-item-health-save'), skipOffstage: false),
    findsOneWidget,
    reason: 'editor State is still mounted during the exit transition',
  );
  expect(h.detailRoute.isCurrent, isTrue);
  expect(h.log.popped, [editor]);
  expect(h.log.removed, isEmpty);
}

void _expectEditorClosedOverDetail(
  _DetailRouteHarness h,
  Route<dynamic> editor,
) {
  expect(editor.isActive, isFalse);
  expect(
    find.byKey(const ValueKey('work-item-health-save'), skipOffstage: false),
    findsNothing,
  );
  expect(h.detailRoute.isCurrent, isTrue);
  expect(find.text('detail-page'), findsOneWidget);
  expect(h.log.popped, [editor]);
  expect(h.log.removed, isEmpty);
}

int _mutationRequests(WorkItemHealthFixture fixture) =>
    fixture.adapter.requests.where((request) {
      final body = request.data;
      return body is Map &&
          (body['query'] as String? ?? '').startsWith(
            'mutation MobileSetWorkItemHealthStatus',
          );
    }).length;

final class _RouteLog extends NavigatorObserver {
  final popped = <Route<dynamic>>[];
  final removed = <Route<dynamic>>[];

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      popped.add(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      removed.add(route);
}

final class _DetailRouteHarness {
  _DetailRouteHarness(this.navigator, this.detailRoute, this.log);

  final NavigatorState navigator;
  final Route<void> detailRoute;
  final _RouteLog log;
  final phases = <(WorkItemHealthWritePhase, Object)>[];
  final outcomes = <(Object, WorkItemHealthSaveOutcome)>[];
  Route<dynamic>? editorRoute;
  Object? token;
}

Future<_DetailRouteHarness> _pumpDetailRoute(
  WidgetTester tester,
  WorkItemHealthFixture fixture, {
  bool denyReserve = false,
}) async {
  addTearDown(fixture.releaseAll);
  final navigatorKey = GlobalKey<NavigatorState>();
  final log = _RouteLog();
  await tester.pumpWidget(
    MaterialApp(
      key: UniqueKey(),
      navigatorKey: navigatorKey,
      navigatorObservers: [log],
      home: const Scaffold(body: Text('root-page')),
    ),
  );
  late final _DetailRouteHarness h;
  final api = testApi(fixture.adapter);
  addTearDown(api.close);
  final owner = _Owner();
  addTearDown(owner.dispose);
  final detail = MaterialPageRoute<void>(
    builder: (_) => Scaffold(
      body: Column(
        children: [
          const Text('detail-page'),
          StatefulBuilder(
            builder: (context, setState) {
              return WorkItemHealthControl(
                account: healthAccount(),
                api: api,
                detail: healthDetail(),
                generation: 7,
                isCurrent: () => true,
                changes: owner,
                enabled: h.token == null,
                reserveWrite: (token) {
                  if (denyReserve || h.token != null) return false;
                  setState(() => h.token = token);
                  return true;
                },
                releaseUnsentWrite: (token) {
                  if (identical(token, h.token)) {
                    setState(() => h.token = null);
                  }
                },
                onWritePhase: (phase, token) {
                  h.phases.add((phase, token));
                  if (phase == WorkItemHealthWritePhase.settle) {
                    setState(() => h.token = null);
                  }
                },
                onOutcome: (token, outcome) {
                  h.outcomes.add((token, outcome));
                },
                onRoute: (route) => h.editorRoute = route,
              );
            },
          ),
        ],
      ),
    ),
  );
  h = _DetailRouteHarness(navigatorKey.currentState!, detail, log);
  unawaited(h.navigator.push(detail));
  await tester.pumpAndSettle();
  expect(detail.isCurrent, isTrue);
  return h;
}

Future<void> _openDetail(
  WidgetTester tester,
  WorkItemHealthFixture fixture,
  _DetailRouteHarness h,
) async {
  final reads = fixture.reads;
  await tester.tap(find.byKey(const ValueKey('work-item-health-edit')));
  await pumpUntil(
    tester,
    () =>
        h.editorRoute != null &&
        find
            .byKey(const ValueKey('work-item-health-save'))
            .evaluate()
            .isNotEmpty &&
        fixture.reads > reads,
    description: 'editor opened from real health read',
  );
  await tester.pump(const Duration(milliseconds: 400));
}
