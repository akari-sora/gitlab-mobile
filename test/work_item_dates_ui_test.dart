import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_dates_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/workspace/work_item_dates.dart';

import 'support/c2d7_barrier.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/work_item_dates_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('C2-D8 blocked dates START is reported as not sent', (
    tester,
  ) async {
    final fixture = WorkItemDatesFixture();
    addTearDown(fixture.api.close);
    final host = await _pump(tester, fixture);
    await _open(tester);
    await _enterDates(tester, '2026-10-04', '');
    fixture.api.bindReadCache(fixture.account.key, 4);
    fixture.api.attachReadCacheDiskBackend(C2d7Barrier());
    await _save(tester, fixture);
    expect(host.phases.map((entry) => entry.$1), [
      WorkItemDatesWritePhase.start,
      WorkItemDatesWritePhase.settle,
    ]);
    expect(fixture.mutations, 0);
    expect(
      find.byKey(const ValueKey('work-item-dates-save-feedback')),
      findsOneWidget,
    );
    expect(find.text(_unconfirmedCopy), findsNothing);
  });


  testWidgets('manual CE and EE set and explicit-null clear use public API', (
    tester,
  ) async {
    for (final edition in [
      WorkItemDatesEdition.ceFixed,
      WorkItemDatesEdition.ee,
    ]) {
      final set = WorkItemDatesFixture(edition: edition);
      addTearDown(set.api.close);
      final setHost = await _pump(tester, set);
      await _open(tester);
      await _enterDates(tester, '2026-10-04', '2026-10-04');
      await _save(tester, set);

      expect(set.mutations, 1);
      expect(set.lastWidget!['startDate'], '2026-10-04');
      expect(set.lastWidget!['dueDate'], '2026-10-04');
      expect(
        set.lastWidget!.containsKey('isFixed'),
        edition == WorkItemDatesEdition.ee,
      );
      expect(setHost.saves.single.startDate, '2026-10-04');

      final clear = WorkItemDatesFixture(
        edition: edition,
        startDate: '2026-10-01',
        dueDate: '2026-10-02',
      );
      addTearDown(clear.api.close);
      final clearHost = await _pump(tester, clear);
      await _open(tester);
      await tester.tap(
        find.byKey(const ValueKey('work-item-dates-start-clear')),
      );
      await tester.tap(find.byKey(const ValueKey('work-item-dates-due-clear')));
      await tester.pump();
      await _save(tester, clear);

      expect(clear.lastWidget!.containsKey('startDate'), isTrue);
      expect(clear.lastWidget!['startDate'], isNull);
      expect(clear.lastWidget!.containsKey('dueDate'), isTrue);
      expect(clear.lastWidget!['dueDate'], isNull);
      expect(clear.startDate, isNull);
      expect(clear.dueDate, isNull);
      expect(clearHost.saves.single.startDate, isNull);
      expect(clearHost.saves.single.dueDate, isNull);
    }
  });

  testWidgets('calendar picker opens and equal manual dates remain valid', (
    tester,
  ) async {
    final fixture = WorkItemDatesFixture();
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _open(tester);

    await tester.tap(
      find.byKey(const ValueKey('work-item-dates-start-picker')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await _enterDates(tester, '2028-02-29', '2028-02-29');
    await _save(tester, fixture);
    expect(fixture.mutations, 1);
    expect(fixture.lastWidget!['startDate'], '2028-02-29');
    expect(fixture.lastWidget!['dueDate'], '2028-02-29');
  });

  testWidgets('calendar picker selection writes strict date and reads back', (
    tester,
  ) async {
    final fixture = WorkItemDatesFixture(
      startDate: '2026-10-01',
      dueDate: '2026-10-31',
    );
    addTearDown(fixture.api.close);
    final host = await _pump(tester, fixture);
    await _open(tester);

    await tester.tap(
      find.byKey(const ValueKey('work-item-dates-start-picker')),
    );
    await tester.pumpAndSettle();
    final dialog = find.byType(DatePickerDialog);
    expect(dialog, findsOneWidget);
    await tester.tap(find.descendant(of: dialog, matching: find.text('15')));
    await tester.pump();
    final ok = MaterialLocalizations.of(tester.element(dialog)).okButtonLabel;
    await tester.tap(find.descendant(of: dialog, matching: find.text(ok)));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsNothing);

    final input = tester.widget<TextField>(
      find.byKey(const ValueKey('work-item-dates-start-input')),
    );
    expect(input.controller!.text, '2026-10-15');
    expect(
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(input.controller!.text),
      isTrue,
    );
    await _save(tester, fixture);

    expect(fixture.mutations, 1);
    expect(fixture.lastWidget!['startDate'], '2026-10-15');
    expect(fixture.lastWidget!['dueDate'], '2026-10-31');
    expect(fixture.startDate, '2026-10-15');
    expect(host.saves.single.startDate, '2026-10-15');
    expect(host.saves.single.dueDate, '2026-10-31');
    expect(fixture.operations, [
      'base',
      'probe',
      'base',
      'probe',
      'mutation',
      'base',
      'probe',
    ]);
  });

  testWidgets(
    'EE inherited mode is probed isFixed, read-only, and independent of rollUp',
    (tester) async {
      final fixture = WorkItemDatesFixture(
        mode: WorkItemDatesMode.inherited,
        startDate: '2026-09-01',
        dueDate: '2026-12-31',
        rollUp: false,
        startSourceWorkItemId: 'gid://gitlab/WorkItem/700',
        dueSourceMilestoneId: 'gid://gitlab/Milestone/800',
      );
      addTearDown(fixture.api.close);
      await _pump(tester, fixture);
      await _open(tester);

      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('work-item-dates-start-input')),
            )
            .enabled,
        isFalse,
      );
      expect(find.textContaining('工作項目 700'), findsOneWidget);
      expect(find.textContaining('里程碑 800'), findsOneWidget);
      expect(find.text('此類型可以彙整子項目日期'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('work-item-dates-mode-manual')),
      );
      await tester.pump();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('work-item-dates-start-input')),
            )
            .enabled,
        isTrue,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();

      final capability = WorkItemDatesFixture(
        mode: WorkItemDatesMode.manual,
        rollUp: true,
      );
      addTearDown(capability.api.close);
      await _pump(tester, capability);
      await _open(tester);
      expect(find.text('此類型可以彙整子項目日期'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('work-item-dates-start-input')),
            )
            .enabled,
        isTrue,
      );
    },
  );

  testWidgets('switching EE to inherited sends only isFixed false', (
    tester,
  ) async {
    final fixture = WorkItemDatesFixture(
      startDate: '2026-10-01',
      dueDate: '2026-10-02',
    );
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _open(tester);
    await tester.tap(
      find.byKey(const ValueKey('work-item-dates-mode-inherited')),
    );
    await tester.pump();
    await _save(tester, fixture);

    expect(fixture.lastWidget, {'isFixed': false});
    expect(fixture.startDate, '2026-09-01');
    expect(fixture.dueDate, '2026-12-31');
  });

  testWidgets('strict date validation rejects format calendar and order', (
    tester,
  ) async {
    final fixture = WorkItemDatesFixture();
    addTearDown(fixture.api.close);
    await _pump(tester, fixture);
    await _open(tester);

    for (final dates in [
      ('2026/10/04', '2026-10-05'),
      ('2026-02-31', '2026-10-05'),
      ('0999-12-31', '2026-10-05'),
      ('2026-10-05', '2026-10-04'),
    ]) {
      await _enterDates(tester, dates.$1, dates.$2);
      await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
      await tester.pump();
      expect(fixture.mutations, 0);
      expect(
        find.byKey(const ValueKey('work-item-dates-validation-error')),
        findsOneWidget,
      );
    }
  });

  testWidgets('unknown and denied access stay readable with Save disabled', (
    tester,
  ) async {
    final unknown = WorkItemDatesFixture(unknownProbe: true);
    addTearDown(unknown.api.close);
    await _pump(tester, unknown);
    await _open(tester);
    expect(find.text('日期模式不明'), findsWidgets);
    expect(_saveButton(tester).onPressed, isNull);
    expect(unknown.mutations, 0);

    final denied = WorkItemDatesFixture(setWorkItemMetadata: false);
    addTearDown(denied.api.close);
    await _pump(tester, denied);
    await _open(tester);
    expect(find.text('目前帳號不能變更日期'), findsOneWidget);
    expect(_saveButton(tester).onPressed, isNull);
    expect(denied.mutations, 0);
  });

  testWidgets('noop closes honestly with zero phases and zero mutations', (
    tester,
  ) async {
    final fixture = WorkItemDatesFixture(
      startDate: '2026-10-04',
      dueDate: '2026-10-05',
    );
    addTearDown(fixture.api.close);
    final host = await _pump(tester, fixture);
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
    await settleNetworkWidgets(tester);

    expect(fixture.mutations, 0);
    expect(host.phases, isEmpty);
    expect(host.saves, hasLength(1));
    expect(find.byKey(const ValueKey('work-item-dates-save')), findsNothing);
  });

  testWidgets(
    'notApplied and uncertain are truthful, single-use, and fresh reopen retries',
    (tester) async {
      final denied = WorkItemDatesFixture(notApplied: true);
      addTearDown(denied.api.close);
      await _pump(tester, denied);
      await _open(tester);
      await _enterDates(tester, '2026-10-04', '');
      await _save(tester, denied);
      expect(denied.mutations, 1);
      expect(find.text('伺服器未套用變更，請確認權限或重新整理'), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNull);

      final uncertain = WorkItemDatesFixture()..malformedAck = true;
      addTearDown(uncertain.api.close);
      await _pump(tester, uncertain);
      await _open(tester);
      await _enterDates(tester, '2026-10-04', '');
      await _save(tester, uncertain);
      expect(uncertain.mutations, 1);
      expect(find.textContaining('尚未確認'), findsOneWidget);
      expect(_saveButton(tester).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
      await tester.pump();
      expect(uncertain.mutations, 1);

      await tester.pageBack();
      await tester.pumpAndSettle();
      uncertain.malformedAck = false;
      await _open(tester);
      await _enterDates(tester, '2026-10-06', '');
      await _save(tester, uncertain);
      expect(uncertain.mutations, 2);
    },
  );

  testWidgets('fresh-fence drift reports proven no-send without phases', (
    tester,
  ) async {
    final fixture = WorkItemDatesFixture(
      startDate: '2026-10-01',
      dueDate: '2026-10-02',
    );
    addTearDown(fixture.api.close);
    final host = await _pump(tester, fixture);
    await _open(tester);
    await _enterDates(tester, '2026-10-04', '2026-10-05');
    fixture
      ..dueDate = '2026-10-20'
      ..updatedAt = '2026-10-04T09:00:00Z';
    await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
    await pumpUntil(
      tester,
      () => find
          .byKey(const ValueKey('work-item-dates-save-feedback'))
          .evaluate()
          .isNotEmpty,
      description: 'waiting for Dates no-send feedback',
    );
    await settleNetworkWidgets(tester);

    final feedback = tester.widget<Text>(
      find.byKey(const ValueKey('work-item-dates-save-feedback')),
    );
    expect(feedback.data, _notSentCopy);
    expect(find.textContaining('連線'), findsNothing);
    final refresh = find.text('請關閉並重新開啟，讀取最新日期後再變更。');
    await tester.scrollUntilVisible(
      refresh,
      80,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('work-item-dates-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();
    expect(refresh, findsOneWidget);
    expect(fixture.mutations, 0);
    expect(host.phases, isEmpty);
    expect(fixture.operations, ['base', 'probe', 'base', 'probe']);
    expect(_saveButton(tester).onPressed, isNull);
    expect(host.saves, isEmpty);
  });

  testWidgets('sent or unknown writes say unconfirmed without a cause', (
    tester,
  ) async {
    for (final failure in ['malformed-ack', 'http-503']) {
      final fixture = WorkItemDatesFixture();
      if (failure == 'malformed-ack') {
        fixture.malformedAck = true;
      } else {
        fixture.mutationHttpError = 503;
      }
      addTearDown(fixture.api.close);
      final host = await _pump(tester, fixture);
      await _open(tester);
      await _enterDates(tester, '2026-10-04', '');
      await _save(tester, fixture);

      final feedback = tester.widget<Text>(
        find.byKey(const ValueKey('work-item-dates-save-feedback')),
      );
      expect(feedback.data, _unconfirmedCopy, reason: failure);
      expect(find.textContaining('連線'), findsNothing, reason: failure);
      expect(fixture.mutations, 1, reason: failure);
      expect(host.phases.map((entry) => entry.$1), [
        WorkItemDatesWritePhase.start,
        WorkItemDatesWritePhase.settle,
      ], reason: failure);
      expect(fixture.operations, [
        'base',
        'probe',
        'base',
        'probe',
        'mutation',
      ], reason: failure);
      expect(_saveButton(tester).onPressed, isNull, reason: failure);
      await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
      await tester.pump();
      expect(fixture.mutations, 1, reason: failure);
      expect(host.saves, isEmpty, reason: failure);
    }
  });

  testWidgets('START and SETTLE bracket exact Future terminal once', (
    tester,
  ) async {
    final success = WorkItemDatesFixture();
    addTearDown(success.api.close);
    final successHost = await _pump(tester, success);
    await _open(tester);
    await _enterDates(tester, '2026-10-04', '');
    await _save(tester, success);
    expect(successHost.phases.map((entry) => entry.$1), [
      WorkItemDatesWritePhase.start,
      WorkItemDatesWritePhase.settle,
    ]);
    expect(
      identical(successHost.phases[0].$2, successHost.phases[1].$2),
      isTrue,
    );

    final failure = WorkItemDatesFixture()..mutationHttpError = 503;
    addTearDown(failure.api.close);
    final failureHost = await _pump(tester, failure);
    await _open(tester);
    await _enterDates(tester, '2026-10-04', '');
    await _save(tester, failure);
    expect(failureHost.phases.map((entry) => entry.$1), [
      WorkItemDatesWritePhase.start,
      WorkItemDatesWritePhase.settle,
    ]);

    final callback = WorkItemDatesFixture();
    addTearDown(callback.api.close);
    final callbackHost = await _pump(tester, callback, throwOnStart: true);
    await _open(tester);
    await _enterDates(tester, '2026-10-04', '');
    await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
    await settleNetworkWidgets(tester);
    expect(callback.mutations, 0);
    expect(callbackHost.phases.map((entry) => entry.$1), [
      WorkItemDatesWritePhase.start,
      WorkItemDatesWritePhase.settle,
    ]);
    expect(find.text(_unconfirmedCopy), findsNothing);
  });

  testWidgets('route close during preflight emits zero phases and sends zero', (
    tester,
  ) async {
    final fixture = WorkItemDatesFixture();
    addTearDown(fixture.api.close);
    final host = await _pump(tester, fixture);
    await _open(tester);
    await _enterDates(tester, '2026-10-04', '');
    fixture.holdNextBaseRead = Completer<void>();
    final reads = fixture.baseReads;
    await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
    await pumpUntil(tester, () => fixture.baseReads == reads + 1);
    await tester.pageBack();
    await tester.pumpAndSettle();
    fixture.releaseBaseRead();
    await settleNetworkWidgets(tester);

    expect(fixture.mutations, 0);
    expect(host.phases, isEmpty);
  });

  testWidgets(
    'route close keeps gate before APPLY and ACK until terminal then allows reopen',
    (tester) async {
      final fixture = WorkItemDatesFixture();
      fixture.holdMutationApply = Completer<void>();
      fixture.holdMutationAck = Completer<void>();
      addTearDown(fixture.api.close);
      final host = await _pump(tester, fixture);
      await _open(tester);
      await _enterDates(tester, '2026-10-04', '');
      await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
      await pumpUntil(tester, () => fixture.mutations == 1);
      expect(host.phases.map((entry) => entry.$1), [
        WorkItemDatesWritePhase.start,
      ]);
      expect(fixture.mutationApplies, 0);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_editButton(tester).onPressed, isNull);
      expect(find.text('正在更新日期…'), findsOneWidget);
      expect(fixture.baseReads, 2);

      fixture.releaseApply();
      await pumpUntil(tester, () => fixture.mutationApplies == 1);
      expect(host.phases, hasLength(1));
      expect(_editButton(tester).onPressed, isNull);

      fixture.releaseAck();
      await settleNetworkWidgets(tester);
      expect(host.phases.map((entry) => entry.$1), [
        WorkItemDatesWritePhase.start,
        WorkItemDatesWritePhase.settle,
      ]);
      expect(_editButton(tester).onPressed, isNotNull);
      await _open(tester);
      expect(fixture.baseReads, greaterThanOrEqualTo(4));
    },
  );

  testWidgets('row disposal preserves captured terminal completion once', (
    tester,
  ) async {
    final fixture = WorkItemDatesFixture();
    fixture.holdMutationApply = Completer<void>();
    fixture.holdMutationAck = Completer<void>();
    addTearDown(fixture.api.close);
    final host = await _pump(tester, fixture);
    await _open(tester);
    await _enterDates(tester, '2026-10-04', '');
    await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
    await pumpUntil(tester, () => fixture.mutations == 1);
    host.replace(() => host.show = false);
    await tester.pumpAndSettle();
    expect(host.phases, hasLength(1));
    expect(host.route!.isActive, isFalse);
    expect(find.byKey(const ValueKey('work-item-dates-edit')), findsNothing);

    fixture.releaseApply();
    await pumpUntil(tester, () => fixture.mutationApplies == 1);
    expect(host.phases, hasLength(1));
    fixture.releaseAck();
    await settleNetworkWidgets(tester);
    expect(host.phases.map((entry) => entry.$1), [
      WorkItemDatesWritePhase.start,
      WorkItemDatesWritePhase.settle,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'account API generation resource and owner replacement cancel preflight',
    (tester) async {
      for (final replacement in _Replacement.values) {
        final fixture = WorkItemDatesFixture();
        addTearDown(fixture.api.close);
        final host = await _pump(tester, fixture);
        await _open(tester);
        await _enterDates(tester, '2026-10-04', '');
        fixture.holdNextBaseRead = Completer<void>();
        final reads = fixture.baseReads;
        await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
        await pumpUntil(tester, () => fixture.baseReads == reads + 1);
        host.applyReplacement(replacement);
        await tester.pump();
        host.owner.ping();
        await tester.pumpAndSettle();
        fixture.releaseBaseRead();
        await settleNetworkWidgets(tester);
        if (!identical(host.api, fixture.api)) host.api.close();

        expect(fixture.mutations, 0, reason: replacement.name);
        expect(host.phases, isEmpty, reason: replacement.name);
        expect(
          find.byKey(const ValueKey('work-item-dates-save')),
          findsNothing,
        );
      }
    },
  );

  testWidgets('same-item updatedAt repaint does not invalidate operation', (
    tester,
  ) async {
    final fixture = WorkItemDatesFixture();
    fixture.holdMutationAck = Completer<void>();
    addTearDown(fixture.api.close);
    final host = await _pump(tester, fixture);
    await _open(tester);
    await _enterDates(tester, '2026-10-04', '');
    await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
    await pumpUntil(tester, () => fixture.mutationApplies == 1);

    host.replace(() {
      host.detail = _copyDetail(
        host.detail,
        updatedAt: DateTime.utc(2026, 10, 4, 8, 0, 1),
      );
    });
    await tester.pump();
    expect(find.byKey(const ValueKey('work-item-dates-save')), findsOneWidget);
    fixture.releaseAck();
    await settleNetworkWidgets(tester);

    expect(fixture.mutations, 1);
    expect(host.saves, hasLength(1));
    expect(host.phases.map((entry) => entry.$1), [
      WorkItemDatesWritePhase.start,
      WorkItemDatesWritePhase.settle,
    ]);
  });

  testWidgets(
    'replacement and cancellation after handoff reject old save and settle once',
    (tester) async {
      for (final replacement in _Replacement.values) {
        final fixture = WorkItemDatesFixture();
        fixture.holdMutationAck = Completer<void>();
        addTearDown(fixture.api.close);
        final host = await _pump(tester, fixture);
        await _open(tester);
        await _enterDates(tester, '2026-10-04', '');
        await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
        await pumpUntil(tester, () => fixture.mutationApplies == 1);
        expect(host.phases.map((entry) => entry.$1), [
          WorkItemDatesWritePhase.start,
        ]);

        host.applyReplacement(replacement);
        await tester.pump();
        host.owner.ping();
        await tester.pumpAndSettle();
        expect(host.phases.map((entry) => entry.$1), [
          WorkItemDatesWritePhase.start,
        ]);
        expect(_editButton(tester).onPressed, isNull);
        if (replacement == _Replacement.api) fixture.api.close();
        fixture.releaseAck();
        await settleNetworkWidgets(tester);
        if (!identical(host.api, fixture.api)) host.api.close();

        expect(host.saves, isEmpty, reason: replacement.name);
        expect(host.phases.map((entry) => entry.$1), [
          WorkItemDatesWritePhase.start,
          WorkItemDatesWritePhase.settle,
        ], reason: replacement.name);
      }
    },
  );

  testWidgets('enabled false blocks opening and reads', (tester) async {
    final fixture = WorkItemDatesFixture();
    addTearDown(fixture.api.close);
    await _pump(tester, fixture, enabled: false);
    expect(_editButton(tester).onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('work-item-dates-edit')));
    await tester.pump();
    expect(fixture.baseReads, 0);
  });

  testWidgets(
    '320dp 2x text and IME keep full CJK and 48dp Save Cancel targets visible',
    (tester) async {
      tester.view.physicalSize = const Size(640, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);

      final fixture = WorkItemDatesFixture(
        mode: WorkItemDatesMode.inherited,
        startDate: '2026-09-01',
        dueDate: '2026-12-31',
        startSourceWorkItemId:
            'gid://gitlab/WorkItem/700700700700700700700700700700',
        dueSourceMilestoneId:
            'gid://gitlab/Milestone/800800800800800800800800800800',
        rollUp: true,
      );
      addTearDown(fixture.api.close);
      await _pump(tester, fixture, textScale: 2);
      await _open(tester);

      final save = find.byKey(const ValueKey('work-item-dates-save'));
      final cancel = find.byKey(const ValueKey('work-item-dates-cancel'));
      final scrollView = find.byKey(const ValueKey('work-item-dates-scroll'));
      final editor = tester.widget<Scaffold>(
        find.ancestor(of: save, matching: find.byType(Scaffold)).first,
      );
      expect(editor.resizeToAvoidBottomInset, isFalse);
      final saveOff = tester.getRect(save);
      final cancelOff = tester.getRect(cancel);
      final scrollOff = tester.getRect(scrollView);
      expect(saveOff.bottom, lessThanOrEqualTo(800));

      tester.view.viewInsets = const FakeViewPadding(bottom: 640);
      await tester.pump();

      const logicalHeight = 800.0;
      const logicalWidth = 320.0;
      const keyboardInset = 320.0;
      const keyboardTop = logicalHeight - keyboardInset;
      final saveRect = tester.getRect(save);
      final cancelRect = tester.getRect(cancel);
      final scrollOn = tester.getRect(scrollView);
      expect(saveOff.top - saveRect.top, moreOrLessEquals(keyboardInset));
      expect(cancelOff.top - cancelRect.top, moreOrLessEquals(keyboardInset));
      expect(saveRect.size, saveOff.size);
      expect(
        scrollOff.bottom - scrollOn.bottom,
        moreOrLessEquals(keyboardInset),
      );
      expect(scrollOn.bottom, moreOrLessEquals(saveRect.top - 16));
      expect(saveRect.height, greaterThanOrEqualTo(48));
      expect(cancelRect.height, greaterThanOrEqualTo(48));
      final scroll = find
          .descendant(
            of: find.byKey(const ValueKey('work-item-dates-scroll')),
            matching: find.byType(Scrollable),
          )
          .first;
      for (final source in [
        find.text('此類型可以彙整子項目日期'),
        find.textContaining('700700700700'),
        find.textContaining('800800800800'),
      ]) {
        await tester.scrollUntilVisible(source, 80, scrollable: scroll);
        await tester.pump();
        expect(source, findsOneWidget);
      }
      for (final target in [
        find.byKey(const ValueKey('work-item-dates-start-picker')),
        find.byKey(const ValueKey('work-item-dates-start-clear')),
        find.byKey(const ValueKey('work-item-dates-due-picker')),
        find.byKey(const ValueKey('work-item-dates-due-clear')),
      ]) {
        await tester.scrollUntilVisible(target, 80, scrollable: scroll);
        await tester.pump();
        expect(tester.getSize(target).height, greaterThanOrEqualTo(48));
      }
      expect(saveRect.left, greaterThanOrEqualTo(0));
      expect(saveRect.right, lessThanOrEqualTo(logicalWidth));
      expect(saveRect.top, greaterThanOrEqualTo(0));
      expect(saveRect.bottom, lessThanOrEqualTo(keyboardTop));
      expect(cancelRect.left, greaterThanOrEqualTo(0));
      expect(cancelRect.right, lessThanOrEqualTo(logicalWidth));
      expect(cancelRect.top, greaterThanOrEqualTo(0));
      expect(cancelRect.bottom, lessThanOrEqualTo(keyboardTop));
      expect(tester.hitTestOnBinding(saveRect.center).path, isNotEmpty);
      expect(tester.hitTestOnBinding(cancelRect.center).path, isNotEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final exit in _EditorExit.values) {
    testWidgets(
      '${exit.label} before START closes the gate while the exit transition runs',
      (tester) async {
        final fixture = WorkItemDatesFixture();
        final h = await _pumpDetailRoute(tester, fixture);
        await _open(tester);
        final editor = h.editorRoute!;
        await _enterDates(tester, '2026-10-04', '');
        fixture.holdNextBaseRead = Completer<void>();
        final reads = fixture.baseReads;
        await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
        await pumpUntil(tester, () => fixture.baseReads == reads + 1);
        expect(fixture.operations, ['base', 'probe', 'base']);
        final responses = fixture.baseResponses;

        await _exitEditor(tester, exit);
        _expectEditorExiting(h, editor);

        fixture.releaseBaseRead();
        await _driveNetworkWithFrozenClock(
          tester,
          () => fixture.baseResponses > responses,
          description: 'held fence read responds during the exit transition',
        );
        await _driveNetworkWithFrozenClock(tester, () => false, cycles: 30);

        expect(fixture.operations, ['base', 'probe', 'base']);
        expect(fixture.mutations, 0);
        expect(_mutationRequests(fixture), 0);
        expect(h.phases, isEmpty);
        expect(h.saves, isEmpty);
        _expectEditorExiting(h, editor);

        await settleNetworkWidgets(tester);
        _expectEditorClosedOverDetail(h, editor);
        expect(fixture.mutations, 0);
        expect(_mutationRequests(fixture), 0);
        expect(h.phases, isEmpty);
        expect(h.saves, isEmpty);
        expect(_editButton(tester).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '${exit.label} after START keeps the detail route when ACK and readback '
      'land during the exit transition',
      (tester) async {
        final fixture = WorkItemDatesFixture()
          ..holdMutationAck = Completer<void>();
        final h = await _pumpDetailRoute(tester, fixture);
        await _open(tester);
        final editor = h.editorRoute!;
        await _enterDates(tester, '2026-10-04', '');
        await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
        await pumpUntil(tester, () => fixture.mutationApplies == 1);
        expect(h.phases.map((entry) => entry.$1), [
          WorkItemDatesWritePhase.start,
        ]);
        expect(fixture.mutationAcks, 0);

        await _exitEditor(tester, exit);
        _expectEditorExiting(h, editor);

        fixture.releaseAck();
        await _driveNetworkWithFrozenClock(
          tester,
          () => h.phases.length == 2,
          description: 'write Future terminal during the exit transition',
        );

        _expectEditorExiting(h, editor);
        expect(fixture.mutationAcks, 1);
        expect(fixture.operations, [
          'base',
          'probe',
          'base',
          'probe',
          'mutation',
          'base',
          'probe',
        ]);
        expect(fixture.startDate, '2026-10-04');
        expect(h.phases.map((entry) => entry.$1), [
          WorkItemDatesWritePhase.start,
          WorkItemDatesWritePhase.settle,
        ]);
        expect(identical(h.phases[0].$2, h.phases[1].$2), isTrue);
        expect(h.saves, isEmpty);
        expect(
          find.byKey(
            const ValueKey('work-item-dates-save-feedback'),
            skipOffstage: false,
          ),
          findsNothing,
        );
        expect(find.byType(SnackBar, skipOffstage: false), findsNothing);

        await settleNetworkWidgets(tester);
        _expectEditorClosedOverDetail(h, editor);
        expect(h.phases, hasLength(2));
        expect(h.saves, isEmpty);
        expect(fixture.mutations, 1);
        expect(_mutationRequests(fixture), 1);
        expect(_editButton(tester).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'after the editor fully closes a held write settles once without UI or '
    'navigation',
    (tester) async {
      final fixture = WorkItemDatesFixture()
        ..holdMutationApply = Completer<void>()
        ..holdMutationAck = Completer<void>();
      final h = await _pumpDetailRoute(tester, fixture);
      await _open(tester);
      final editor = h.editorRoute!;
      await _enterDates(tester, '2026-10-04', '');
      await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
      await pumpUntil(tester, () => fixture.mutations == 1);
      expect(fixture.mutationApplies, 0);

      await tester.tap(find.byKey(const ValueKey('work-item-dates-cancel')));
      await tester.pumpAndSettle();
      _expectEditorClosedOverDetail(h, editor);
      expect(h.phases.map((entry) => entry.$1), [
        WorkItemDatesWritePhase.start,
      ]);
      expect(find.text('正在更新日期…'), findsOneWidget);
      expect(_editButton(tester).onPressed, isNull);

      final newer = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('newer-page')),
      );
      unawaited(h.navigator.push(newer));
      await tester.pumpAndSettle();
      expect(newer.isCurrent, isTrue);

      fixture.releaseApply();
      await pumpUntil(tester, () => fixture.mutationApplies == 1);
      expect(h.phases, hasLength(1));
      fixture.releaseAck();
      await settleNetworkWidgets(tester);

      expect(h.phases.map((entry) => entry.$1), [
        WorkItemDatesWritePhase.start,
        WorkItemDatesWritePhase.settle,
      ]);
      expect(identical(h.phases[0].$2, h.phases[1].$2), isTrue);
      expect(h.saves, isEmpty);
      expect(newer.isCurrent, isTrue);
      expect(h.detailRoute.isActive, isTrue);
      expect(h.log.popped, [editor]);
      expect(h.log.removed, isEmpty);
      expect(fixture.mutations, 1);
      expect(_mutationRequests(fixture), 1);
      expect(fixture.mutationAcks, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a write applied under a newer route closes only its own editor route',
    (tester) async {
      final fixture = WorkItemDatesFixture()
        ..holdMutationAck = Completer<void>();
      final h = await _pumpDetailRoute(tester, fixture);
      await _open(tester);
      final editor = h.editorRoute!;
      await _enterDates(tester, '2026-10-04', '');
      await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
      await pumpUntil(tester, () => fixture.mutationApplies == 1);

      final newer = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('newer-page')),
      );
      unawaited(h.navigator.push(newer));
      await tester.pumpAndSettle();
      expect(newer.isCurrent, isTrue);
      expect(editor.isActive, isTrue);

      fixture.releaseAck();
      await settleNetworkWidgets(tester);

      expect(newer.isCurrent, isTrue);
      expect(find.text('newer-page'), findsOneWidget);
      expect(editor.isActive, isFalse);
      expect(h.detailRoute.isActive, isTrue);
      expect(h.log.popped, isEmpty);
      expect(h.log.removed, [editor]);
      expect(h.saves.single.startDate, '2026-10-04');
      expect(h.phases.map((entry) => entry.$1), [
        WorkItemDatesWritePhase.start,
        WorkItemDatesWritePhase.settle,
      ]);
      expect(fixture.mutations, 1);
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
      await tester.tap(find.byKey(const ValueKey('work-item-dates-cancel')));
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
    find.byKey(const ValueKey('work-item-dates-save'), skipOffstage: false),
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
    find.byKey(const ValueKey('work-item-dates-save'), skipOffstage: false),
    findsNothing,
  );
  expect(h.detailRoute.isCurrent, isTrue);
  expect(find.text('detail-page'), findsOneWidget);
  expect(h.log.popped, [editor]);
  expect(h.log.removed, isEmpty);
}

int _mutationRequests(WorkItemDatesFixture fixture) =>
    fixture.adapter.requests.where((request) {
      final body = request.data;
      return body is Map &&
          (body['query'] as String? ?? '').startsWith(
            'mutation MobileSetWorkItemDates',
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
  final saves = <WorkItemDatesSnapshot>[];
  final phases = <(WorkItemDatesWritePhase, Object)>[];
  Route<dynamic>? editorRoute;
}

/// Root page -> detail route hosting the control -> editor pushed by the
/// control, mirroring an editor opened from a pushed detail page.
Future<_DetailRouteHarness> _pumpDetailRoute(
  WidgetTester tester,
  WorkItemDatesFixture fixture,
) async {
  addTearDown(fixture.api.close);
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
  final detail = MaterialPageRoute<void>(
    builder: (_) => Scaffold(
      body: Column(
        children: [
          const Text('detail-page'),
          WorkItemDatesControl(
            account: fixture.account,
            api: fixture.api,
            detail: fixture.detail,
            generation: 4,
            onRoute: (route) => h.editorRoute = route,
            onDatesWrite: (phase, token) => h.phases.add((phase, token)),
            onSaved: (snapshot) => h.saves.add(snapshot),
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

const _notSentCopy = '沒有送出日期變更。';
const _unconfirmedCopy = '尚未確認日期是否已更新。請重新整理後再查看，不要重複送出同一次變更。';

enum _Replacement { account, api, generation, resource, owner }

Future<_DatesHostState> _pump(
  WidgetTester tester,
  WorkItemDatesFixture fixture, {
  bool enabled = true,
  bool throwOnStart = false,
  double textScale = 1,
}) async {
  addTearDown(fixture.releaseAll);
  await tester.pumpWidget(
    _DatesHost(
      key: UniqueKey(),
      fixture: fixture,
      enabled: enabled,
      throwOnStart: throwOnStart,
      textScale: textScale,
    ),
  );
  return tester.state<_DatesHostState>(find.byType(_DatesHost));
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('work-item-dates-edit')));
  await settleNetworkWidgets(tester);
  expect(find.byKey(const ValueKey('work-item-dates-save')), findsOneWidget);
}

Future<void> _enterDates(WidgetTester tester, String start, String due) async {
  await tester.enterText(
    find.byKey(const ValueKey('work-item-dates-start-input')),
    start,
  );
  await tester.enterText(
    find.byKey(const ValueKey('work-item-dates-due-input')),
    due,
  );
  await tester.pump();
}

Future<void> _save(WidgetTester tester, WorkItemDatesFixture fixture) async {
  final before = fixture.mutations;
  await tester.tap(find.byKey(const ValueKey('work-item-dates-save')));
  await pumpUntil(
    tester,
    () =>
        fixture.mutations > before ||
        find.byKey(const ValueKey('work-item-dates-save')).evaluate().isEmpty ||
        find
            .byKey(const ValueKey('work-item-dates-save-feedback'))
            .evaluate()
            .isNotEmpty,
    maxCycles: 80,
    description: 'waiting for Dates save result',
  );
  await settleNetworkWidgets(tester);
}

FilledButton _saveButton(WidgetTester tester) => tester.widget<FilledButton>(
  find.byKey(const ValueKey('work-item-dates-save')),
);

TextButton _editButton(WidgetTester tester) => tester.widget<TextButton>(
  find.byKey(const ValueKey('work-item-dates-edit')),
);

final class _Owner extends ChangeNotifier {
  void ping() => notifyListeners();
}

class _DatesHost extends StatefulWidget {
  const _DatesHost({
    super.key,
    required this.fixture,
    required this.enabled,
    required this.throwOnStart,
    required this.textScale,
  });

  final WorkItemDatesFixture fixture;
  final bool enabled;
  final bool throwOnStart;
  final double textScale;

  @override
  State<_DatesHost> createState() => _DatesHostState();
}

class _DatesHostState extends State<_DatesHost> {
  late Account account = widget.fixture.account;
  late GitLabApi api = widget.fixture.api;
  late WorkItemGraphDetail detail = widget.fixture.detail;
  final owner = _Owner();
  final saves = <WorkItemDatesSnapshot>[];
  final phases = <(WorkItemDatesWritePhase, Object)>[];
  var generation = 4;
  var current = true;
  var show = true;
  Route<dynamic>? route;

  void replace(VoidCallback change) => setState(change);

  void applyReplacement(_Replacement replacement) {
    replace(() {
      switch (replacement) {
        case _Replacement.account:
          account = Account(
            instance: widget.fixture.account.instance,
            user: const GitLabUser(id: 8, username: 'grace', name: 'Grace'),
            token: 'synthetic-other-token',
          );
          break;
        case _Replacement.api:
          api = testApi(widget.fixture.adapter);
          break;
        case _Replacement.generation:
          generation++;
          break;
        case _Replacement.resource:
          detail = _copyDetail(detail, id: 'gid://gitlab/WorkItem/999');
          break;
        case _Replacement.owner:
          current = false;
          break;
      }
    });
  }

  @override
  void dispose() {
    owner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(widget.textScale)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              if (show)
                WorkItemDatesControl(
                  account: account,
                  api: api,
                  detail: detail,
                  generation: generation,
                  enabled: widget.enabled,
                  isCurrent: () => current,
                  ownerChanges: owner,
                  onRoute: (opened) => route = opened,
                  onDatesWrite: (phase, token) {
                    phases.add((phase, token));
                    if (phase == WorkItemDatesWritePhase.start &&
                        widget.throwOnStart) {
                      throw StateError('synthetic START callback failure');
                    }
                    if (mounted) setState(() {});
                  },
                  onSaved: (snapshot) {
                    if (mounted) setState(() => saves.add(snapshot));
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

WorkItemGraphDetail _copyDetail(
  WorkItemGraphDetail detail, {
  String? id,
  DateTime? updatedAt,
}) {
  final summary = detail.summary;
  return WorkItemGraphDetail(
    summary: WorkItemGraphSummary(
      id: id ?? summary.id,
      iid: summary.iid,
      title: summary.title,
      state: summary.state,
      createdAt: summary.createdAt,
      updatedAt: updatedAt ?? summary.updatedAt,
      project: summary.project,
      namespace: summary.namespace,
      type: summary.type,
    ),
    description: detail.description,
    widgetsAvailable: detail.widgetsAvailable,
    widgetTypes: detail.widgetTypes,
    descriptionWidget: detail.descriptionWidget,
    assignees: detail.assignees,
    labels: detail.labels,
    hierarchy: detail.hierarchy,
    dates: detail.dates,
  );
}
