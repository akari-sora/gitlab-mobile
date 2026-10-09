import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_weight_models.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_attributes.dart';
import 'package:gitlab_mobile/features/workspace/work_item_weight.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _project = GraphResourceRef(
  id: 'gid://gitlab/Project/42',
  fullPath: 'studio/mobile-workspace',
);
const _namespace = GraphResourceRef(
  id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
  fullPath: 'studio/mobile-workspace',
);
const _group = GraphResourceRef(
  id: 'gid://gitlab/Group/8',
  fullPath: 'group/board',
);
const _type = WorkItemGraphType(
  id: 'gid://gitlab/WorkItems::Type/9',
  name: 'Task',
);

enum _Widgets { present, absent, unavailable }

void main() {
  testWidgets(
    'fresh read shows the server weight and ignores the displayed title',
    (tester) async {
      final harness = await _start(
        tester,
        weight: 8,
        title: 'Fresh weight item',
      );
      await _open(tester);

      expect(harness.server.reads, 1);
      expect(harness.server.writes, 0);
      expect(find.text('Fresh weight item'), findsOneWidget);
      expect(find.text('Displayed weight item'), findsNothing);
      expect(find.text('目前權重：8'), findsOneWidget);
      expect(find.text('studio/mobile-workspace · 工作項目 #31'), findsOneWidget);
      expect(
        find.text('@mobile-owner · https://example.com/gitlab'),
        findsOneWidget,
      );
      expect(harness.route, isNotNull);
    },
  );

  testWidgets('a group work item shows its group scope from the fresh read', (
    tester,
  ) async {
    await _start(tester, group: true, weight: null);
    await _open(tester);

    expect(find.text('group/board · 工作項目 #44'), findsOneWidget);
    expect(find.text('目前未設定'), findsOneWidget);
  });

  testWidgets('null stays unset and zero stays a stored weight', (
    tester,
  ) async {
    await _start(tester, weight: null);
    await _open(tester);
    expect(find.text('目前未設定'), findsOneWidget);
    expect(find.text('目前權重：0'), findsNothing);
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey('work-item-weight-remove')),
      ),
      isSemantics(isChecked: true),
    );

    final zero = await _start(tester, weight: 0);
    await _open(tester);
    expect(find.text('目前權重：0'), findsOneWidget);
    expect(find.text('目前未設定'), findsNothing);
    expect(
      tester
          .widget<TextField>(
            find.byKey(const ValueKey('work-item-weight-input')),
          )
          .controller!
          .text,
      '0',
    );
    await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
    await settleNetworkWidgets(tester);
    expect(zero.server.writes, 0);
    expect(zero.server.sent, isEmpty);
    expect(find.text('已儲存：0/10/3'), findsOneWidget);
  });

  testWidgets(
    'saving the current weight sends no mutation and cancel sends nothing',
    (tester) async {
      final harness = await _start(tester, weight: 7);
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await settleNetworkWidgets(tester);

      expect(harness.server.writes, 0);
      expect(harness.server.reads, greaterThanOrEqualTo(2));
      expect(find.text('已儲存：7/10/3'), findsOneWidget);

      final cancelled = await _start(tester, weight: 7);
      await _open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('work-item-weight-input')),
        '3',
      );
      await tester.pump();
      await tester.pageBack();
      await settleNetworkWidgets(tester);
      expect(cancelled.server.writes, 0);
      expect(cancelled.server.reads, 1);
      expect(cancelled.saves, isEmpty);
      expect(find.text('尚未儲存'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('work-item-weight-input')),
        findsNothing,
      );
    },
  );

  testWidgets('an empty set input is invalid and is not a clear', (
    tester,
  ) async {
    final harness = await _start(tester, weight: 4);
    await _open(tester);
    await tester.enterText(
      find.byKey(const ValueKey('work-item-weight-input')),
      '   ',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
    await tester.pump();

    expect(harness.server.writes, 0);
    expect(find.text('請輸入權重。空白不會清除權重。'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('work-item-weight-save')),
          )
          .onPressed,
      isNotNull,
    );

    await tester.enterText(
      find.byKey(const ValueKey('work-item-weight-input')),
      '5',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
    await settleNetworkWidgets(tester);
    expect(harness.server.sent, [5]);
    expect(find.text('已儲存：5/10/3'), findsOneWidget);
  });

  testWidgets('invalid numbers stay as typed and never become a saved weight', (
    tester,
  ) async {
    final harness = await _start(tester, weight: 4);
    await _open(tester);
    final input = find.byKey(const ValueKey('work-item-weight-input'));
    final keyboard = tester.widget<TextField>(input).keyboardType;
    expect(keyboard, TextInputType.number);
    expect(keyboard.signed, isFalse);
    expect(keyboard.decimal, isFalse);
    for (final sample in ['-1', '1.5', '20.0', '+8']) {
      await tester.enterText(input, sample);
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, sample);
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await tester.pump();
      expect(find.text('請輸入 0 或正整數。'), findsOneWidget);
      expect(find.textContaining('2147483647'), findsNothing);
    }
    await tester.enterText(input, '2147483648');
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '2147483648');
    await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
    await tester.pump();
    expect(find.text('權重必須是 0 到 2147483647 的整數。'), findsOneWidget);
    expect(harness.server.writes, 0);
    expect(harness.server.sent, isEmpty);
    expect(find.textContaining('草稿已保留'), findsNothing);
  });

  testWidgets(
    'remove sends null, keeps the typed text, and preserves aggregates',
    (tester) async {
      final harness = await _start(tester, weight: 8);
      await _open(tester);
      final input = find.byKey(const ValueKey('work-item-weight-input'));
      await tester.enterText(input, '21');
      await tester.pump();
      expect(find.text('彙整權重：10'), findsOneWidget);
      expect(find.text('已完成彙整權重：3'), findsOneWidget);
      expect(find.textContaining('彙整權重：21'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('work-item-weight-remove')));
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, '21');
      expect(tester.widget<TextField>(input).enabled, isFalse);
      expect(find.text('將移除權重'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await settleNetworkWidgets(tester);

      expect(harness.server.sent, [null]);
      expect(find.text('已儲存：null/10/3'), findsOneWidget);
    },
  );

  testWidgets(
    'set accepts zero, values above 20 and the 32-bit max with fresh aggregates',
    (tester) async {
      final harness = await _start(tester, weight: null);
      await _open(tester);
      await tester.tap(find.byKey(const ValueKey('work-item-weight-set')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('work-item-weight-input')),
        '0',
      );
      await tester.pump();
      expect(find.text('將設定權重：0'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await settleNetworkWidgets(tester);
      expect(harness.server.sent, [0]);
      expect(find.text('已儲存：0/10/3'), findsOneWidget);

      harness.server.rolledAfterWrite = 40;
      harness.server.completedAfterWrite = 6;
      await _open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('work-item-weight-input')),
        '21',
      );
      await tester.pump();
      expect(find.text('彙整權重：10'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await settleNetworkWidgets(tester);
      expect(harness.server.sent, [0, 21]);
      expect(find.text('已儲存：21/40/6'), findsOneWidget);

      await _open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('work-item-weight-input')),
        '2147483647',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await settleNetworkWidgets(tester);
      expect(harness.server.sent.last, 2147483647);
      expect(find.text('已儲存：2147483647/40/6'), findsOneWidget);
    },
  );

  testWidgets(
    'permission comes from the fresh admin flag, not metadata or the detail',
    (tester) async {
      final harness = await _start(
        tester,
        weight: 8,
        admin: false,
        extraPermissions: true,
        widgetTypes: const {'WEIGHT', 'MILESTONE'},
      );
      await _open(tester);

      expect(harness.server.reads, 1);
      expect(harness.server.writes, 0);
      expect(find.text('目前帳號沒有變更權重的權限。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('work-item-weight-input')),
        findsNothing,
      );
      expect(find.text('彙整權重：10'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('work-item-weight-save')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('absent and unavailable weights are explicit and read-only', (
    tester,
  ) async {
    final absent = await _start(tester, widgets: _Widgets.absent, admin: true);
    await _open(tester);
    expect(find.text('這個工作項目沒有權重欄位。'), findsOneWidget);
    expect(find.byKey(const ValueKey('work-item-weight-input')), findsNothing);
    expect(find.text('目前權重：0'), findsNothing);
    expect(absent.server.writes, 0);

    final unavailable = await _start(
      tester,
      widgets: _Widgets.unavailable,
      admin: true,
    );
    await _open(tester);
    expect(find.text('伺服器未提供這個工作項目的欄位資訊。'), findsOneWidget);
    expect(find.byKey(const ValueKey('work-item-weight-input')), findsNothing);
    expect(unavailable.server.writes, 0);
  });

  testWidgets(
    'each choice is one semantics node and the number field is separate',
    (tester) async {
      await _start(tester, weight: 8);
      await _open(tester);

      final setFinder = find.byKey(const ValueKey('work-item-weight-set'));
      final removeFinder = find.byKey(
        const ValueKey('work-item-weight-remove'),
      );
      final inputFinder = find.byKey(const ValueKey('work-item-weight-input'));
      expect(
        find.descendant(of: setFinder, matching: inputFinder),
        findsNothing,
      );
      expect(
        find.descendant(of: removeFinder, matching: inputFinder),
        findsNothing,
      );

      final setNode = tester.getSemantics(setFinder);
      final removeNode = tester.getSemantics(removeFinder);
      expect(_semanticsRect(setNode), isNot(Rect.zero));
      expect(_rects(tester, setNode), 1);
      expect(_rects(tester, removeNode), 1);
      expect(
        setNode,
        isSemantics(
          label: '設定權重',
          isButton: true,
          isChecked: true,
          isInMutuallyExclusiveGroup: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      expect(
        setNode.childrenCountInTraversalOrder,
        0,
        reason: 'the radio row must be one complete semantics node',
      );
      expect(
        removeNode,
        isSemantics(
          label: '移除權重',
          isButton: true,
          isChecked: false,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
        ),
      );
      expect(
        removeNode.childrenCountInTraversalOrder,
        0,
        reason: 'the radio row must be one complete semantics node',
      );

      final fields = _textFields(tester);
      expect(fields, hasLength(1));
      final field = fields.single.getSemanticsData();
      expect(field.flagsCollection.isTextField, isTrue);
      expect(field.flagsCollection.isFocused, isNot(Tristate.none));
      expect(field.flagsCollection.isEnabled, Tristate.isTrue);
      expect(field.label, contains('權重'));
      expect(_semanticsRect(fields.single), isNot(_semanticsRect(setNode)));
      expect(_semanticsRect(fields.single), isNot(_semanticsRect(removeNode)));

      _performSemanticsTap(tester, removeNode);
      await tester.pump();
      final removeChecked = tester.getSemantics(removeFinder);
      expect(
        removeChecked,
        isSemantics(
          label: '移除權重',
          isButton: true,
          isChecked: true,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
        ),
      );
      expect(
        removeChecked.childrenCountInTraversalOrder,
        0,
        reason: 'the radio row must be one complete semantics node',
      );
      final setUnchecked = tester.getSemantics(setFinder);
      expect(
        setUnchecked,
        isSemantics(
          label: '設定權重',
          isButton: true,
          isChecked: false,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
        ),
      );
      expect(
        setUnchecked.childrenCountInTraversalOrder,
        0,
        reason: 'the radio row must be one complete semantics node',
      );
      expect(
        _textFields(tester).single.getSemanticsData().flagsCollection.isEnabled,
        Tristate.isFalse,
      );
      expect(tester.widget<TextField>(inputFinder).controller!.text, '8');

      final setAgain = tester.getSemantics(setFinder);
      _performSemanticsTap(tester, setAgain);
      await tester.pump();
      expect(
        tester.getSemantics(setFinder),
        isSemantics(label: '設定權重', isChecked: true),
      );
      expect(
        tester.getSemantics(removeFinder),
        isSemantics(label: '移除權重', isChecked: false),
      );
      expect(
        _textFields(tester).single.getSemanticsData().flagsCollection.isEnabled,
        Tristate.isTrue,
      );
      expect(tester.widget<TextField>(inputFinder).controller!.text, '8');
    },
  );

  testWidgets(
    'validation, conflict and an uncertain write lock replay without a draft claim',
    (tester) async {
      final rejected = await _start(tester, weight: 4);
      rejected.server.rejectNext = true;
      await _open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('work-item-weight-input')),
        '9',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await settleNetworkWidgets(tester);

      expect(rejected.server.writes, 1);
      expect(find.textContaining('權重設定未被接受'), findsOneWidget);
      expect(find.textContaining('草稿已保留'), findsNothing);
      expect(find.text('重新整理'), findsNothing);
      expect(find.text('請關閉並重新開啟，讀取最新狀態後再變更。'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('work-item-weight-save')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await tester.pump();
      expect(rejected.server.writes, 1);

      await tester.pageBack();
      await settleNetworkWidgets(tester);
      await _open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('work-item-weight-input')),
        '9',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await settleNetworkWidgets(tester);
      expect(rejected.server.writes, 2);
      expect(find.text('已儲存：9/10/3'), findsOneWidget);

      final conflict = await _start(tester, weight: 4);
      await _open(tester);
      conflict.server.driftNextRead = true;
      await tester.enterText(
        find.byKey(const ValueKey('work-item-weight-input')),
        '6',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await settleNetworkWidgets(tester);
      expect(conflict.server.writes, 0);
      expect(find.textContaining('工作項目已變更'), findsOneWidget);
      expect(find.textContaining('草稿已保留'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('work-item-weight-save')),
            )
            .onPressed,
        isNull,
      );

      final uncertain = await _start(tester, weight: 4);
      uncertain.server.loseNext = true;
      await _open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('work-item-weight-input')),
        '6',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await settleNetworkWidgets(tester);
      expect(uncertain.server.writes, 1);
      expect(find.textContaining('請重新開啟確認目前權重'), findsOneWidget);
      expect(find.textContaining('草稿已保留'), findsNothing);
      expect(find.text('重新整理'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('work-item-weight-save')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('owner replacement closes the editor and drops a late result', (
    tester,
  ) async {
    final harness = await _start(tester, weight: 4);
    final gate = Completer<void>();
    harness.server.holdRead = gate;
    await tester.tap(find.byKey(const ValueKey('work-item-weight-edit')));
    await _until(tester, () => harness.server.reads >= 1);
    harness.replace(() => harness.account = _account(8));
    await tester.pump();
    gate.complete();
    await settleNetworkWidgets(tester);
    expect(find.byKey(const ValueKey('work-item-weight-input')), findsNothing);
    expect(harness.saves, isEmpty);

    final open = await _start(tester, weight: 4);
    await _open(tester);
    final saveGate = Completer<void>();
    open.server.holdRead = saveGate;
    await tester.enterText(
      find.byKey(const ValueKey('work-item-weight-input')),
      '11',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
    await _until(tester, () => open.server.reads >= 2);
    open.replace(() {
      open.generation.value = 8;
      open.api = testApi(open.server.adapter);
    });
    await _frames(tester);
    expect(find.byKey(const ValueKey('work-item-weight-input')), findsNothing);
    saveGate.complete();
    await settleNetworkWidgets(tester);
    expect(open.saves, isEmpty);
    expect(open.server.writes, 0);

    final revision = await _start(tester, weight: 4);
    await _open(tester);
    revision.replace(() {
      revision.detail = _detail(updatedAt: DateTime.utc(2026, 10, 4));
    });
    await _frames(tester);
    expect(find.byKey(const ValueKey('work-item-weight-input')), findsNothing);
    expect(revision.saves, isEmpty);
    expect(revision.server.writes, 0);
  });

  testWidgets('a non-current owner cannot start a weight read', (tester) async {
    final harness = await _start(tester, weight: 4);
    final press = tester
        .widget<TextButton>(find.byKey(const ValueKey('work-item-weight-edit')))
        .onPressed!;
    harness.current = false;
    press();
    await tester.pump();
    expect(harness.server.reads, 0);
    expect(find.text('讀取權重權限…'), findsNothing);
    expect(harness.route, isNull);

    harness.current = true;
    press();
    await settleNetworkWidgets(tester);
    expect(harness.server.reads, 1);
    expect(
      find.byKey(const ValueKey('work-item-weight-input')),
      findsOneWidget,
    );
  });

  testWidgets('a repeated open does not read twice or replace the route', (
    tester,
  ) async {
    final harness = await _start(tester, weight: 4);
    final press = tester
        .widget<TextButton>(find.byKey(const ValueKey('work-item-weight-edit')))
        .onPressed!;
    press();
    press();
    await settleNetworkWidgets(tester);
    expect(harness.server.reads, 1);
    final route = harness.route;
    expect(route, isNotNull);
    expect(route!.isActive, isTrue);
    expect(
      find.byKey(const ValueKey('work-item-weight-input')),
      findsOneWidget,
    );

    press();
    await tester.pump();
    expect(harness.server.reads, 1);
    expect(identical(harness.route, route), isTrue);
    expect(route.isActive, isTrue);
    expect(harness.saves, isEmpty);
  });

  testWidgets('a current owner signal leaves the open editor in place', (
    tester,
  ) async {
    final harness = await _start(tester, weight: 4);
    await _open(tester);
    final route = harness.route!;
    final reads = harness.server.reads;
    harness.owner.ping();
    await _frames(tester);
    expect(route.isActive, isTrue);
    expect(identical(harness.route, route), isTrue);
    expect(harness.server.reads, reads);
    expect(harness.saves, isEmpty);
    expect(
      find.byKey(const ValueKey('work-item-weight-input')),
      findsOneWidget,
    );
  });

  testWidgets('a non-current owner closes the route and drops the late save', (
    tester,
  ) async {
    final harness = await _start(tester, weight: 4);
    await _open(tester);
    final route = harness.route!;
    final gate = Completer<void>();
    harness.server.holdRead = gate;
    await tester.enterText(
      find.byKey(const ValueKey('work-item-weight-input')),
      '11',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
    await _until(tester, () => harness.server.reads >= 2);
    harness.current = false;
    harness.owner.ping();
    await _frames(tester);
    expect(route.isActive, isFalse);
    expect(find.byKey(const ValueKey('work-item-weight-input')), findsNothing);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('work-item-weight-edit')),
          )
          .onPressed,
      isNull,
    );
    gate.complete();
    await settleNetworkWidgets(tester);
    expect(harness.saves, isEmpty);
    expect(harness.server.writes, 0);
    expect(find.textContaining('草稿已保留'), findsNothing);
    expect(find.text('尚未儲存'), findsOneWidget);
  });

  testWidgets('the weight control listens only to the current owner', (
    tester,
  ) async {
    final harness = await _start(tester, weight: 4);
    await _open(tester);
    final first = harness.owner;
    final second = _Owner();
    harness.replace(() => harness.owner = second);
    await tester.pump();
    final route = harness.route!;
    harness.current = false;
    first.ping();
    await _frames(tester);
    expect(route.isActive, isTrue);
    expect(
      find.byKey(const ValueKey('work-item-weight-input')),
      findsOneWidget,
    );

    second.ping();
    await _frames(tester);
    expect(route.isActive, isFalse);
    expect(find.byKey(const ValueKey('work-item-weight-input')), findsNothing);
    expect(harness.saves, isEmpty);
    expect(harness.server.writes, 0);
    first.dispose();
  });

  testWidgets('disposing the weight control dismisses its route', (
    tester,
  ) async {
    final harness = await _start(tester, weight: 4);
    await _open(tester);
    final route = harness.route!;
    expect(route.isActive, isTrue);
    harness.replace(() => harness.show = false);
    await _frames(tester);
    expect(route.isActive, isFalse);
    expect(find.byKey(const ValueKey('work-item-weight-input')), findsNothing);
    expect(harness.saves, isEmpty);
  });

  testWidgets('a title or type-name change does not close the weight editor', (
    tester,
  ) async {
    final harness = await _start(tester, weight: 4);
    await _open(tester);
    final route = harness.route!;
    harness.replace(() {
      harness.detail = _shifted(
        harness.detail,
        title: '只改標題',
        type: const WorkItemGraphType(
          id: 'gid://gitlab/WorkItems::Type/9',
          name: 'Issue',
        ),
      );
    });
    await _frames(tester);
    expect(route.isActive, isTrue);
    expect(identical(harness.route, route), isTrue);
    expect(harness.server.reads, 1);
    expect(harness.saves, isEmpty);
    expect(
      find.byKey(const ValueKey('work-item-weight-input')),
      findsOneWidget,
    );
  });

  for (final closure in _identityClosures) {
    testWidgets(
      '${closure.label} closes the weight route and drops the late save',
      (tester) async {
        final harness = await _start(tester, weight: 4);
        await _open(tester);
        await _dropLateSave(tester, harness, closure.apply(harness.detail));
      },
    );
  }

  testWidgets(
    'a stale read epoch during preflight locks the save and sends nothing',
    (tester) async {
      final harness = await _start(tester, weight: 4);
      await _open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('work-item-weight-input')),
        '9',
      );
      await tester.pump();
      final gate = Completer<void>();
      harness.server.holdRead = gate;
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await _until(tester, () => harness.server.reads >= 2);
      expect(harness.current, isTrue);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      harness.api.clearReadCache();
      gate.complete();
      await settleNetworkWidgets(tester);

      expect(harness.server.writes, 0);
      expect(harness.server.sent, isEmpty);
      expect(harness.saves, isEmpty);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('儲存'), findsOneWidget);
      expect(find.text('權重沒有變更。請重新開啟確認目前狀態。'), findsOneWidget);
      expect(find.text('請關閉並重新開啟，讀取最新狀態後再變更。'), findsOneWidget);
      expect(find.textContaining('草稿'), findsNothing);
      expect(harness.route!.isActive, isTrue);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('work-item-weight-save')),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await settleNetworkWidgets(tester);
      expect(harness.server.writes, 0);
      expect(harness.server.reads, 2);

      final invalidated = await _start(tester, weight: 4);
      await _open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('work-item-weight-input')),
        '9',
      );
      await tester.pump();
      final invalidatedGate = Completer<void>();
      invalidated.server.holdRead = invalidatedGate;
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await _until(tester, () => invalidated.server.reads >= 2);
      invalidated.api.clearReadCache();
      invalidated.current = false;
      invalidated.owner.ping();
      await _frames(tester);
      invalidatedGate.complete();
      await settleNetworkWidgets(tester);
      expect(invalidated.route!.isActive, isFalse);
      expect(invalidated.server.writes, 0);
      expect(invalidated.saves, isEmpty);
      expect(find.text('權重沒有變更。請重新開啟確認目前狀態。'), findsNothing);
      expect(find.text('尚未儲存'), findsOneWidget);

      final disposed = await _start(tester, weight: 4);
      await _open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('work-item-weight-input')),
        '9',
      );
      await tester.pump();
      final disposedGate = Completer<void>();
      disposed.server.holdRead = disposedGate;
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await _until(tester, () => disposed.server.reads >= 2);
      disposed.api.clearReadCache();
      disposed.replace(() => disposed.show = false);
      await _frames(tester);
      disposedGate.complete();
      await settleNetworkWidgets(tester);
      expect(disposed.route!.isActive, isFalse);
      expect(disposed.server.writes, 0);
      expect(disposed.saves, isEmpty);
      expect(
        find.byKey(const ValueKey('work-item-weight-input')),
        findsNothing,
      );
      expect(find.text('權重沒有變更。請重新開啟確認目前狀態。'), findsNothing);
      expect(find.text('尚未儲存'), findsOneWidget);
    },
  );

  testWidgets('narrow 2x text keeps Save above the keyboard inset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 1600);
    tester.view.devicePixelRatio = 2;
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    tester.view.padding = FakeViewPadding.zero;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetPadding);
    await _start(tester, weight: 4, textScale: 2);
    await _open(tester);

    const keyboardPhysical = 640.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboardPhysical);
    await tester.pump();
    final ratio = tester.view.devicePixelRatio;
    final logicalHeight = tester.view.physicalSize.height / ratio;
    final logicalWidth = tester.view.physicalSize.width / ratio;
    final keyboardInset = tester.view.viewInsets.bottom / ratio;
    expect(logicalWidth, 320);
    expect(keyboardInset, keyboardPhysical / ratio);

    final input = find.byKey(const ValueKey('work-item-weight-input'));
    await tester.scrollUntilVisible(input, 48, scrollable: _weightBodyScroll());
    await tester.enterText(input, '21');
    await tester.pump();
    expect(tester.widget<TextField>(input).controller!.text, '21');
    expect(find.text('請輸入 0 或正整數；清除請選「移除權重」。'), findsOneWidget);
    final inputRect = tester.getRect(input);
    expect(inputRect.bottom, lessThanOrEqualTo(logicalHeight - keyboardInset));
    expect(tester.hitTestOnBinding(inputRect.center).path, isNotEmpty);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('work-item-weight-completed')),
      80,
      scrollable: _weightBodyScroll(),
    );
    await tester.pump();

    final save = find.byKey(const ValueKey('work-item-weight-save'));
    final rect = tester.getRect(save);
    final keyboardTop = logicalHeight - keyboardInset;
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(logicalWidth));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(keyboardTop));
    expect(keyboardTop - rect.bottom, closeTo(16, 0.5));
    expect(rect.height, greaterThanOrEqualTo(48));
    expect(tester.hitTestOnBinding(rect.center).path, isNotEmpty);
    expect(find.text('彙整權重：10'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.viewInsets = FakeViewPadding.zero;
    tester.view.padding = const FakeViewPadding(bottom: 48);
    await tester.pump();
    final closed = tester.getRect(save);
    final systemTop = logicalHeight - (tester.view.padding.bottom / ratio);
    expect(closed.bottom, lessThanOrEqualTo(systemTop));
    expect(systemTop - closed.bottom, closeTo(16, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'revision during a weight write refetches and ignores the stale row',
    (tester) async {
      final panel = await _startPanel(tester, weight: 4);
      await _openPanelEditor(tester);
      final ack = Completer<void>();
      panel.server.holdWrite = ack;
      panel.server.rolledAfterWrite = 41;
      panel.server.completedAfterWrite = 17;
      await tester.enterText(
        find.byKey(const ValueKey('work-item-weight-input')),
        '9',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await _until(tester, () => panel.server.writes == 1);
      final readsAtWrite = panel.server.attributeReads;
      panel.replace(() {
        panel.detail = _shifted(
          panel.detail,
          updatedAt: DateTime.utc(2026, 10, 4),
        );
      });
      await _frames(tester);
      expect(
        find.byKey(const ValueKey('work-item-weight-input')),
        findsNothing,
      );
      expect(panel.server.writes, 1);
      expect(panel.server.attributeReads, readsAtWrite);
      ack.complete();
      await _until(
        tester,
        () =>
            panel.server.attributeReads == readsAtWrite + 1 &&
            find.text('權重：9').evaluate().isNotEmpty &&
            find.text('彙整權重：41').evaluate().isNotEmpty,
      );
      expect(find.text('已完成彙整權重：17'), findsOneWidget);
      expect(find.text('權重：9'), findsOneWidget);
      expect(find.text('權重：4'), findsNothing);
      expect(find.text('彙整權重：41'), findsOneWidget);
      expect(find.text('彙整權重：10'), findsNothing);
      expect(panel.server.writes, 1);
    },
  );

  testWidgets('a pending attribute read cannot replace the saved weight', (
    tester,
  ) async {
    final panel = await _startPanel(tester, weight: 4, expand: false);
    final stale = Completer<void>();
    panel.server.holdAttribute = stale;
    await tester.tap(find.text('屬性'));
    await tester.pump();
    await _until(tester, () => panel.server.attributeReads == 1);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('work-item-weight-edit')));
    await _until(
      tester,
      () => find
          .byKey(const ValueKey('work-item-weight-save'))
          .evaluate()
          .isNotEmpty,
    );
    panel.server.rolledAfterWrite = 55;
    panel.server.completedAfterWrite = 6;
    await tester.enterText(
      find.byKey(const ValueKey('work-item-weight-input')),
      '9',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
    await _until(tester, () => find.text('權重：9').evaluate().isNotEmpty);
    expect(find.text('彙整權重：55'), findsWidgets);
    expect(panel.server.writes, 1);
    stale.complete();
    await settleNetworkWidgets(tester);
    expect(find.text('權重：9'), findsOneWidget);
    expect(find.text('權重：4'), findsNothing);
    expect(find.text('彙整權重：10'), findsNothing);
    expect(panel.server.writes, 1);
  });

  testWidgets(
    'Graph project and group refresh keep Weight gated through terminal',
    (tester) async {
      for (final group in [false, true]) {
        final detail = _detail(group: group, widgetTypes: const {'WEIGHT'});
        final server = _WeightServer(detail: detail, weight: 4);
        final api = testApi(server.adapter);
        addTearDown(api.close);
        final apply = Completer<void>();
        final ack = Completer<void>();
        server.holdWriteApply = apply;
        server.holdWrite = ack;
        try {
          await _pumpGraphWeight(tester, api, server, group: group);
          await _revealGraphWeight(
            tester,
            find.byKey(const ValueKey('work-item-attributes')),
          );
          await tester.tap(find.text('屬性'));
          await pumpUntil(
            tester,
            () =>
                server.attributeReads == 1 &&
                find
                    .byKey(const ValueKey('work-item-weight-edit'))
                    .evaluate()
                    .isNotEmpty,
          );
          await tester.pump(const Duration(milliseconds: 500));
          final edit = tester.widget<TextButton>(
            find.byKey(const ValueKey('work-item-weight-edit')),
          );
          expect(edit.onPressed, isNotNull);
          edit.onPressed!.call();
          await tester.pump();
          await pumpUntil(
            tester,
            () => find
                .byKey(const ValueKey('work-item-weight-save'))
                .evaluate()
                .isNotEmpty,
          );
          await tester.pump(const Duration(milliseconds: 300));
          await tester.enterText(
            find.byKey(const ValueKey('work-item-weight-input')),
            '9',
          );
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
          await pumpUntil(tester, () => server.writes == 1);
          final readsAtHandoff = server.reads;
          final attributesAtHandoff = server.attributeReads;

          final editorContext = tester.element(
            find.byKey(const ValueKey('work-item-weight-save')),
          );
          Navigator.of(
            editorContext,
          ).removeRoute(ModalRoute.of(editorContext)!);
          await tester.pump();
          final detailReads = server.detailReads;
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.refresh).last,
              )
              .onPressed!
              .call();
          await pumpUntil(tester, () => server.detailReads > detailReads);
          await tester.pump(const Duration(milliseconds: 300));

          expect(server.reads, readsAtHandoff);
          expect(server.attributeReads, attributesAtHandoff);
          expect(server.writes, 1);
          expect(
            tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('work-item-weight-edit')),
                )
                .onPressed,
            isNull,
          );
          expect(
            find.byKey(const ValueKey('work-item-weight-save')),
            findsNothing,
          );

          apply.complete();
          await tester.pump();
          expect(server.reads, readsAtHandoff);
          expect(server.attributeReads, attributesAtHandoff);
          expect(server.writes, 1);
          expect(
            tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('work-item-weight-edit')),
                )
                .onPressed,
            isNull,
          );

          ack.complete();
          await pumpUntil(
            tester,
            () =>
                server.reads == readsAtHandoff + 1 &&
                server.attributeReads == attributesAtHandoff + 1 &&
                find.text('權重：9').evaluate().isNotEmpty,
          );
          expect(server.writes, 1);
          expect(
            tester
                .widget<TextButton>(
                  find.byKey(const ValueKey('work-item-weight-edit')),
                )
                .onPressed,
            isNotNull,
          );
        } finally {
          if (!apply.isCompleted) apply.complete();
          if (!ack.isCompleted) ack.complete();
        }
      }
    },
  );

  testWidgets(
    'project and group delayed APPLY survive back and keep B disabled',
    (tester) async {
      for (final group in [false, true]) {
        final panel = await _startPanel(tester, weight: 4, group: group);
        await _openPanelEditor(tester);
        final apply = Completer<void>();
        final ack = Completer<void>();
        panel.server.holdWriteApply = apply;
        panel.server.holdWrite = ack;
        await tester.enterText(
          find.byKey(const ValueKey('work-item-weight-input')),
          '9',
        );
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
        await _until(tester, () => panel.server.writes == 1);
        final readsAtHandoff = panel.server.reads;

        await tester.pageBack();
        await tester.pump();
        final editBeforeRefresh = tester.widget<TextButton>(
          find.byKey(const ValueKey('work-item-weight-edit')),
        );
        expect(editBeforeRefresh.onPressed, isNull);
        expect(panel.server.reads, readsAtHandoff);

        final attributesBeforeRefresh = panel.server.attributeReads;
        panel.replace(() {
          panel.detail = _shifted(
            panel.detail,
            updatedAt: DateTime.utc(2026, 10, 4),
          );
        });
        await tester.pump();
        expect(panel.server.attributeReads, attributesBeforeRefresh);
        final editAfterRefresh = tester.widget<TextButton>(
          find.byKey(const ValueKey('work-item-weight-edit')),
        );
        expect(editAfterRefresh.onPressed, isNull);
        expect(panel.server.reads, readsAtHandoff);
        expect(panel.server.writes, 1);

        apply.complete();
        await tester.pump();
        expect(
          tester
              .widget<TextButton>(
                find.byKey(const ValueKey('work-item-weight-edit')),
              )
              .onPressed,
          isNull,
        );
        expect(panel.server.reads, readsAtHandoff);

        final attributesBeforeSettle = panel.server.attributeReads;
        ack.complete();
        await _until(
          tester,
          () =>
              panel.server.attributeReads == attributesBeforeSettle + 1 &&
              find.text('權重：9').evaluate().isNotEmpty,
        );
        expect(panel.server.writes, 1);
        expect(panel.server.reads, readsAtHandoff + 1);
        expect(
          tester
              .widget<TextButton>(
                find.byKey(const ValueKey('work-item-weight-edit')),
              )
              .onPressed,
          isNotNull,
        );
      }
    },
  );

  testWidgets('a fully disposed weight panel ignores the old terminal', (
    tester,
  ) async {
    final panel = await _startPanel(tester, weight: 4);
    await _openPanelEditor(tester);
    final apply = Completer<void>();
    final ack = Completer<void>();
    panel.server.holdWriteApply = apply;
    panel.server.holdWrite = ack;
    await tester.enterText(
      find.byKey(const ValueKey('work-item-weight-input')),
      '9',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
    await _until(tester, () => panel.server.writes == 1);
    final readsAtHandoff = panel.server.reads;

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    apply.complete();
    await tester.pump();
    ack.complete();
    await settleNetworkWidgets(tester);

    expect(panel.server.writes, 1);
    expect(panel.server.reads, readsAtHandoff);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'disposed project and group parents cannot settle B held before APPLY',
    (tester) async {
      for (final group in [false, true]) {
        final detail = _detail(group: group, widgetTypes: const {'WEIGHT'});
        final server = _WeightServer(detail: detail, weight: 4);
        final sharedApi = testApi(server.adapter);
        addTearDown(sharedApi.close);
        final applyA = Completer<void>();
        final ackA = Completer<void>();
        final applyB = Completer<void>();
        final ackB = Completer<void>();
        server.holdWriteApply = applyA;
        try {
          final oldParent = await _mountIndependentPanel(
            tester,
            server: server,
            detail: detail,
            api: sharedApi,
            expectedWeight: 4,
          );
          await _openPanelEditor(tester);
          await tester.enterText(
            find.byKey(const ValueKey('work-item-weight-input')),
            '9',
          );
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
          await _until(
            tester,
            () => server.writes == 1 && oldParent.weightPhases.length == 1,
          );
          expect(server.sent, [9]);
          expect(oldParent.weightPhases, [WorkItemWeightWritePhase.start]);
          final oldRoute = oldParent.route!;
          expect(oldRoute.isActive, isTrue);

          await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
          await _frames(tester);
          expect(oldParent.mounted, isFalse);
          expect(oldRoute.isActive, isFalse);

          server.holdWriteApply = applyB;
          final newParent = await _mountIndependentPanel(
            tester,
            server: server,
            detail: detail,
            api: sharedApi,
            expectedWeight: 4,
          );
          expect(identical(oldParent, newParent), isFalse);
          expect(identical(oldParent.owner, newParent.owner), isFalse);
          expect(identical(oldParent.api, newParent.api), isTrue);
          await _openPanelEditor(tester);
          await tester.enterText(
            find.byKey(const ValueKey('work-item-weight-input')),
            '12',
          );
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
          await _until(
            tester,
            () => server.writes == 2 && newParent.weightPhases.length == 1,
          );
          expect(server.sent, [9, 12]);
          expect(newParent.weightPhases, [WorkItemWeightWritePhase.start]);
          final newRoute = newParent.route!;
          final attributesBeforeASettle = server.attributeReads;

          server.holdWrite = ackA;
          applyA.complete();
          await _until(
            tester,
            () => server.weight == 9 && server.holdWrite == null,
          );
          ackA.complete();
          await _until(tester, () => oldParent.weightPhases.length == 2);

          final save = find.byKey(const ValueKey('work-item-weight-save'));
          expect(oldParent.weightPhases, [
            WorkItemWeightWritePhase.start,
            WorkItemWeightWritePhase.settle,
          ]);
          expect(newParent.weightPhases, [WorkItemWeightWritePhase.start]);
          expect(newRoute.isActive, isTrue);
          expect(tester.widget<FilledButton>(save).onPressed, isNull);
          expect(
            find.descendant(
              of: save,
              matching: find.byType(CircularProgressIndicator),
            ),
            findsOneWidget,
          );
          expect(server.attributeReads, attributesBeforeASettle);
          expect(find.text('權重：9'), findsNothing);
          expect(find.text('權重：12'), findsNothing);
          expect(tester.takeException(), isNull);

          server.holdWrite = ackB;
          applyB.complete();
          await _until(
            tester,
            () => server.weight == 12 && server.holdWrite == null,
          );
          ackB.complete();
          await _until(
            tester,
            () =>
                newParent.weightPhases.length == 2 &&
                server.attributeReads == attributesBeforeASettle + 1 &&
                find.text('權重：12').evaluate().isNotEmpty,
          );
          expect(newParent.weightPhases, [
            WorkItemWeightWritePhase.start,
            WorkItemWeightWritePhase.settle,
          ]);
          expect(find.text('權重：9'), findsNothing);
          expect(server.sent, [9, 12]);
          expect(tester.takeException(), isNull);
        } finally {
          if (!applyA.isCompleted) applyA.complete();
          if (!ackA.isCompleted) ackA.complete();
          if (!applyB.isCompleted) applyB.complete();
          if (!ackB.isCompleted) ackB.complete();
        }
      }
    },
  );

  testWidgets(
    'disposed project and group API owners cannot settle B held before ACK',
    (tester) async {
      for (final group in [false, true]) {
        final detail = _detail(group: group, widgetTypes: const {'WEIGHT'});
        final server = _WeightServer(detail: detail, weight: 4);
        final apiA = testApi(server.adapter);
        final apiB = testApi(server.adapter);
        addTearDown(apiA.close);
        addTearDown(apiB.close);
        final ackA = Completer<void>();
        final ackB = Completer<void>();
        server.holdWrite = ackA;
        try {
          final oldParent = await _mountIndependentPanel(
            tester,
            server: server,
            detail: detail,
            api: apiA,
            expectedWeight: 4,
          );
          await _openPanelEditor(tester);
          await tester.enterText(
            find.byKey(const ValueKey('work-item-weight-input')),
            '9',
          );
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
          await _until(
            tester,
            () =>
                server.writes == 1 &&
                server.weight == 9 &&
                oldParent.weightPhases.length == 1,
          );
          expect(server.sent, [9]);
          expect(oldParent.weightPhases, [WorkItemWeightWritePhase.start]);
          final oldRoute = oldParent.route!;

          await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
          await _frames(tester);
          expect(oldParent.mounted, isFalse);
          expect(oldRoute.isActive, isFalse);

          final newParent = await _mountIndependentPanel(
            tester,
            server: server,
            detail: detail,
            api: apiB,
            expectedWeight: 9,
          );
          expect(identical(oldParent, newParent), isFalse);
          expect(identical(oldParent.owner, newParent.owner), isFalse);
          expect(identical(oldParent.api, newParent.api), isFalse);
          server.holdWrite = ackB;
          await _openPanelEditor(tester);
          await tester.enterText(
            find.byKey(const ValueKey('work-item-weight-input')),
            '12',
          );
          await tester.pump();
          await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
          await _until(
            tester,
            () =>
                server.writes == 2 &&
                server.weight == 12 &&
                newParent.weightPhases.length == 1,
          );
          expect(server.sent, [9, 12]);
          expect(newParent.weightPhases, [WorkItemWeightWritePhase.start]);
          final newRoute = newParent.route!;
          final attributesBeforeASettle = server.attributeReads;

          ackA.complete();
          await _until(tester, () => oldParent.weightPhases.length == 2);

          final save = find.byKey(const ValueKey('work-item-weight-save'));
          expect(oldParent.weightPhases, [
            WorkItemWeightWritePhase.start,
            WorkItemWeightWritePhase.settle,
          ]);
          expect(newParent.weightPhases, [WorkItemWeightWritePhase.start]);
          expect(newRoute.isActive, isTrue);
          expect(tester.widget<FilledButton>(save).onPressed, isNull);
          expect(
            find.descendant(
              of: save,
              matching: find.byType(CircularProgressIndicator),
            ),
            findsOneWidget,
          );
          expect(server.attributeReads, attributesBeforeASettle);
          expect(find.text('權重：12'), findsNothing);
          expect(find.text('權重：9'), findsWidgets);
          expect(tester.takeException(), isNull);

          ackB.complete();
          await _until(
            tester,
            () =>
                newParent.weightPhases.length == 2 &&
                server.attributeReads == attributesBeforeASettle + 1 &&
                find.text('權重：12').evaluate().isNotEmpty,
          );
          expect(newParent.weightPhases, [
            WorkItemWeightWritePhase.start,
            WorkItemWeightWritePhase.settle,
          ]);
          expect(find.text('權重：9'), findsNothing);
          expect(server.sent, [9, 12]);
          expect(tester.takeException(), isNull);
        } finally {
          if (!ackA.isCompleted) ackA.complete();
          if (!ackB.isCompleted) ackB.complete();
        }
      }
    },
  );

  testWidgets('weight callback failure settles once without a send', (
    tester,
  ) async {
    final detail = _detail();
    final server = _WeightServer(detail: detail, weight: 4);
    final api = testApi(server.adapter);
    addTearDown(api.close);
    final phases = <WorkItemWeightWritePhase>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkItemWeightControl(
            account: _account(7),
            api: api,
            detail: detail,
            onSaved: (_) => fail('callback failure published a save'),
            onWeightWrite: (phase, token, account, owner, expected) {
              phases.add(phase);
              if (phase == WorkItemWeightWritePhase.start) {
                throw StateError('synthetic callback failure');
              }
            },
          ),
        ),
      ),
    );
    await _open(tester);
    await tester.enterText(
      find.byKey(const ValueKey('work-item-weight-input')),
      '9',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
    await _until(tester, () => phases.length == 2);

    expect(phases, [
      WorkItemWeightWritePhase.start,
      WorkItemWeightWritePhase.settle,
    ]);
    expect(server.writes, 0);
  });

  testWidgets('a revision before send closes the editor without a mutation', (
    tester,
  ) async {
    final panel = await _startPanel(tester, weight: 4);
    await _openPanelEditor(tester);
    panel.replace(() {
      panel.detail = _shifted(
        panel.detail,
        updatedAt: DateTime.utc(2026, 10, 4),
      );
    });
    await _frames(tester);
    expect(find.byKey(const ValueKey('work-item-weight-input')), findsNothing);
    expect(panel.server.writes, 0);
    expect(find.text('權重：9'), findsNothing);
    await settleNetworkWidgets(tester);
  });

  testWidgets('identity changes during a weight write ignore the old settle', (
    tester,
  ) async {
    Future<void> begin(_PanelState panel) async {
      await _openPanelEditor(tester);
      final ack = Completer<void>();
      panel.server.holdWrite = ack;
      panel.server.rolledAfterWrite = 41;
      panel.server.completedAfterWrite = 17;
      await tester.enterText(
        find.byKey(const ValueKey('work-item-weight-input')),
        '9',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
      await _until(tester, () => panel.server.writes == 1);
      panel.pendingAck = ack;
    }

    final accountPanel = await _startPanel(tester, weight: 4);
    await begin(accountPanel);
    accountPanel.server.staleAttributeOwn = 2;
    accountPanel.server.staleAttributeRolled = 8;
    accountPanel.server.staleAttributeCompleted = 1;
    accountPanel.replace(() => accountPanel.account = _account(8));
    await _frames(tester);
    accountPanel.pendingAck!.complete();
    await settleNetworkWidgets(tester);
    expect(accountPanel.server.writes, 1);
    expect(find.text('彙整權重：41'), findsNothing);
    expect(find.text('權重：9'), findsNothing);

    final apiPanel = await _startPanel(tester, weight: 4);
    await begin(apiPanel);
    apiPanel.server.staleAttributeOwn = 2;
    apiPanel.server.staleAttributeRolled = 8;
    apiPanel.server.staleAttributeCompleted = 1;
    apiPanel.replace(() => apiPanel.api = testApi(apiPanel.server.adapter));
    await _frames(tester);
    apiPanel.pendingAck!.complete();
    await settleNetworkWidgets(tester);
    expect(apiPanel.server.writes, 1);
    expect(find.text('權重：2'), findsOneWidget);
    expect(find.text('彙整權重：8'), findsOneWidget);
    expect(find.text('彙整權重：41'), findsNothing);

    final itemPanel = await _startPanel(tester, weight: 4);
    await begin(itemPanel);
    itemPanel.server.staleAttributeOwn = 2;
    itemPanel.server.staleAttributeRolled = 8;
    itemPanel.server.staleAttributeCompleted = 1;
    itemPanel.replace(() {
      itemPanel.detail = _shifted(
        itemPanel.detail,
        id: 'gid://gitlab/WorkItem/99',
      );
    });
    await _frames(tester);
    itemPanel.pendingAck!.complete();
    await settleNetworkWidgets(tester);
    expect(itemPanel.server.writes, 1);
    expect(find.text('權重：2'), findsOneWidget);
    expect(find.text('彙整權重：41'), findsNothing);
    expect(find.text('權重：9'), findsNothing);

    final ownerPanel = await _startPanel(tester, weight: 4);
    await begin(ownerPanel);
    ownerPanel.replace(() => ownerPanel.current = false);
    ownerPanel.owner.ping();
    await _frames(tester);
    ownerPanel.pendingAck!.complete();
    await settleNetworkWidgets(tester);
    expect(ownerPanel.server.writes, 1);
    expect(find.text('權重：9'), findsNothing);
    expect(find.text('彙整權重：41'), findsNothing);
  });

  testWidgets('API replacement waits for A terminal before starting B', (
    tester,
  ) async {
    final panel = await _startPanel(tester, weight: 4);
    await _openPanelEditor(tester);
    final ackA = Completer<void>();
    panel.server.holdWrite = ackA;
    await tester.enterText(
      find.byKey(const ValueKey('work-item-weight-input')),
      '9',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
    await _until(tester, () => panel.server.writes == 1);

    panel.server.staleAttributeOwn = 4;
    panel.server.staleAttributeRolled = 10;
    panel.server.staleAttributeCompleted = 3;
    panel.replace(() => panel.api = testApi(panel.server.adapter));
    addTearDown(panel.api.close);
    await _frames(tester);
    await _until(tester, () => find.text('權重：4').evaluate().isNotEmpty);
    expect(find.text('權重：9'), findsNothing);
    expect(panel.server.writes, 1);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('work-item-weight-edit')),
          )
          .onPressed,
      isNull,
    );
    ackA.complete();
    await _until(
      tester,
      () =>
          tester
              .widget<TextButton>(
                find.byKey(const ValueKey('work-item-weight-edit')),
              )
              .onPressed !=
          null,
    );

    final ackB = Completer<void>();
    panel.server.holdWrite = ackB;
    panel.server.rolledAfterWrite = 41;
    panel.server.completedAfterWrite = 17;
    await _openPanelEditor(tester);
    await tester.enterText(
      find.byKey(const ValueKey('work-item-weight-input')),
      '12',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
    await _until(tester, () => panel.server.writes == 2);
    expect(panel.server.sent, [9, 12]);

    final readsAtWrite = panel.server.attributeReads;
    panel.replace(() {
      panel.detail = _shifted(
        panel.detail,
        updatedAt: DateTime.utc(2026, 10, 5),
      );
    });
    await _frames(tester);
    expect(panel.server.attributeReads, readsAtWrite);
    expect(find.text('權重：9'), findsNothing);
    expect(panel.server.writes, 2);

    final readsBeforeSettle = panel.server.attributeReads;
    ackB.complete();
    await _until(
      tester,
      () =>
          find.text('權重：12').evaluate().isNotEmpty &&
          find.text('彙整權重：41').evaluate().isNotEmpty &&
          panel.server.attributeReads > readsBeforeSettle,
    );
    expect(find.text('已完成彙整權重：17'), findsOneWidget);
    expect(find.text('權重：4'), findsNothing);
    expect(find.text('權重：9'), findsNothing);
    expect(panel.server.writes, 2);
    expect(panel.server.sent, [9, 12]);
  });

  testWidgets('owner away and back retains A gate before starting B', (
    tester,
  ) async {
    final panel = await _startPanel(tester, weight: 4);
    await _openPanelEditor(tester);
    final ackA = Completer<void>();
    panel.server.holdWrite = ackA;
    await tester.enterText(
      find.byKey(const ValueKey('work-item-weight-input')),
      '9',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
    await _until(tester, () => panel.server.writes == 1);

    panel.replace(() => panel.current = false);
    panel.owner.ping();
    await _frames(tester);
    expect(find.byKey(const ValueKey('work-item-weight-input')), findsNothing);
    panel.replace(() => panel.current = true);
    panel.owner.ping();
    await _frames(tester);
    final readsBeforeReturn = panel.server.attributeReads;
    await tester.tap(find.text('屬性'));
    await tester.pump();
    await tester.tap(find.text('屬性'));
    await tester.pump();
    expect(panel.server.attributeReads, readsBeforeReturn);
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('work-item-weight-edit')),
          )
          .onPressed,
      isNull,
    );
    expect(panel.server.writes, 1);
    ackA.complete();
    await _until(
      tester,
      () =>
          panel.server.attributeReads == readsBeforeReturn + 1 &&
          find.text('權重：9').evaluate().isNotEmpty,
    );

    final ackB = Completer<void>();
    panel.server.holdWrite = ackB;
    panel.server.rolledAfterWrite = 41;
    panel.server.completedAfterWrite = 17;
    await _openPanelEditor(tester);
    await tester.enterText(
      find.byKey(const ValueKey('work-item-weight-input')),
      '12',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
    await _until(tester, () => panel.server.writes == 2);

    final readsAtWrite = panel.server.attributeReads;
    panel.replace(() {
      panel.detail = _shifted(
        panel.detail,
        updatedAt: DateTime.utc(2026, 10, 6),
      );
    });
    await _frames(tester);
    expect(panel.server.attributeReads, readsAtWrite);
    expect(panel.server.writes, 2);
    expect(panel.server.sent, [9, 12]);

    final readsBeforeSettle = panel.server.attributeReads;
    ackB.complete();
    await _until(
      tester,
      () =>
          find.text('權重：12').evaluate().isNotEmpty &&
          find.text('彙整權重：41').evaluate().isNotEmpty &&
          panel.server.attributeReads > readsBeforeSettle,
    );
    expect(find.text('已完成彙整權重：17'), findsOneWidget);
    expect(panel.server.writes, 2);
    expect(panel.server.sent, [9, 12]);
  });
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

Future<void> _dropLateSave(
  WidgetTester tester,
  _HarnessState harness,
  WorkItemGraphDetail next,
) async {
  final route = harness.route!;
  final gate = Completer<void>();
  harness.server.holdRead = gate;
  await tester.enterText(
    find.byKey(const ValueKey('work-item-weight-input')),
    '11',
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('work-item-weight-save')));
  await _until(tester, () => harness.server.reads >= 2);
  harness.replace(() => harness.detail = next);
  await _frames(tester);
  expect(route.isActive, isFalse);
  expect(find.byKey(const ValueKey('work-item-weight-input')), findsNothing);
  gate.complete();
  await settleNetworkWidgets(tester);
  expect(harness.saves, isEmpty);
  expect(harness.server.writes, 0);
  expect(find.textContaining('草稿已保留'), findsNothing);
  expect(find.text('尚未儲存'), findsOneWidget);
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  await pumpUntil(
    tester,
    ready,
    step: const Duration(milliseconds: 1),
    realDelay: const Duration(milliseconds: 1),
  );
}

Finder _weightBodyScroll() {
  return find.byElementPredicate((Element element) {
    if (element.widget is! Scrollable) return false;
    if (element.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    final view = element.findAncestorWidgetOfExactType<CustomScrollView>();
    return view?.key == const ValueKey<String>('work-item-weight-scroll');
  }, description: 'weight editor body scroll');
}

Rect _semanticsRect(SemanticsNode node) {
  var rect = node.rect;
  for (
    SemanticsNode? current = node;
    current != null;
    current = current.parent
  ) {
    final transform = current.transform;
    if (transform != null) {
      rect = MatrixUtils.transformRect(transform, rect);
    }
  }
  return rect;
}

void _performSemanticsTap(WidgetTester tester, SemanticsNode node) {
  tester.binding.performSemanticsAction(
    SemanticsActionEvent(
      type: SemanticsAction.tap,
      viewId: tester.view.viewId,
      nodeId: node.id,
    ),
  );
}

SemanticsNode _semanticsRoot(WidgetTester tester) {
  final viewId = tester.view.viewId;
  for (final view in tester.binding.renderViews) {
    if (view.flutterView.viewId != viewId) continue;
    final root = view.owner?.semanticsOwner?.rootSemanticsNode;
    if (root != null) return root;
  }
  final root =
      tester.binding.rootPipelineOwner.semanticsOwner?.rootSemanticsNode;
  expect(root, isNotNull);
  return root!;
}

int _rects(WidgetTester tester, SemanticsNode target) {
  final wanted = _semanticsRect(target);
  final root = _semanticsRoot(tester);
  var count = 0;
  void visit(SemanticsNode node) {
    if (_semanticsRect(node) == wanted) count++;
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  return count;
}

List<SemanticsNode> _textFields(WidgetTester tester) {
  final root = _semanticsRoot(tester);
  final found = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    if (node.getSemanticsData().flagsCollection.isTextField) {
      found.add(node);
    }
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }

  visit(root);
  return found;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('work-item-weight-edit')));
  await settleNetworkWidgets(tester);
}

Future<_HarnessState> _start(
  WidgetTester tester, {
  int? weight,
  String title = 'Fresh weight item',
  bool group = false,
  bool admin = true,
  bool extraPermissions = false,
  _Widgets widgets = _Widgets.present,
  Set<String> widgetTypes = const {},
  double textScale = 1,
}) async {
  final detail = _detail(group: group, widgetTypes: widgetTypes);
  final server = _WeightServer(
    detail: detail,
    weight: weight,
    title: title,
    admin: admin,
    extraPermissions: extraPermissions,
    widgets: widgets,
  );
  await tester.pumpWidget(
    _Harness(
      key: UniqueKey(),
      server: server,
      detail: detail,
      textScale: textScale,
    ),
  );
  return tester.state<_HarnessState>(find.byType(_Harness));
}

Future<_PanelState> _startPanel(
  WidgetTester tester, {
  required int? weight,
  bool expand = true,
  bool group = false,
}) async {
  final detail = _detail(group: group, widgetTypes: const {'WEIGHT'});
  final server = _WeightServer(detail: detail, weight: weight);
  await tester.pumpWidget(
    _PanelHarness(key: UniqueKey(), server: server, detail: detail),
  );
  final state = tester.state<_PanelState>(find.byType(_PanelHarness));
  addTearDown(state.api.close);
  await tester.pump();
  if (!expand) return state;
  await tester.tap(find.text('屬性'));
  await tester.pump();
  await _until(
    tester,
    () => find.text('權重：${weight ?? '未知'}').evaluate().isNotEmpty,
  );
  return state;
}

Future<_PanelState> _mountIndependentPanel(
  WidgetTester tester, {
  required _WeightServer server,
  required WorkItemGraphDetail detail,
  required GitLabApi api,
  required int expectedWeight,
}) async {
  await tester.pumpWidget(
    _PanelHarness(
      key: UniqueKey(),
      server: server,
      detail: detail,
      api: api,
      observeWeightLifecycle: true,
    ),
  );
  final state = tester.state<_PanelState>(find.byType(_PanelHarness));
  await tester.pump();
  await tester.tap(find.text('屬性'));
  await tester.pump();
  await _until(
    tester,
    () => find.text('權重：$expectedWeight').evaluate().isNotEmpty,
  );
  return state;
}

Future<void> _openPanelEditor(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  final edit = find.byKey(const ValueKey('work-item-weight-edit'));
  await tester.ensureVisible(edit);
  await tester.tap(edit);
  await tester.pump();
  await _until(
    tester,
    () => find
        .byKey(const ValueKey('work-item-weight-save'))
        .evaluate()
        .isNotEmpty,
  );
}

Future<void> _pumpGraphWeight(
  WidgetTester tester,
  GitLabApi api,
  _WeightServer server, {
  required bool group,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: group
          ? GraphWorkItemDetailPage.namespace(
              account: _account(7),
              api: api,
              namespacePath: _group.fullPath,
              expectedNamespaceId: _group.id,
              iid: server.detail.summary.iid,
            )
          : GraphWorkItemDetailPage.project(
              account: _account(7),
              api: api,
              project: Project.fromJson({
                ...projectJson(42),
                'path_with_namespace': _project.fullPath,
              }),
              iid: server.detail.summary.iid,
            ),
    ),
  );
  await pumpUntil(
    tester,
    () =>
        server.detailReads == 1 &&
        find.text('Fresh weight item').evaluate().isNotEmpty,
  );
  await settleNetworkWidgets(tester);
}

Future<void> _revealGraphWeight(WidgetTester tester, Finder finder) async {
  for (var step = 0; step < 50; step++) {
    if (finder.hitTestable().evaluate().isNotEmpty) return;
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -320));
    await tester.pump();
  }
  expect(finder.hitTestable(), findsWidgets);
}

WorkItemGraphDetail _detail({
  DateTime? updatedAt,
  bool group = false,
  Set<String> widgetTypes = const {},
}) => WorkItemGraphDetail(
  summary: WorkItemGraphSummary(
    id: group ? 'gid://gitlab/WorkItem/44' : 'gid://gitlab/WorkItem/31',
    iid: group ? 44 : 31,
    title: 'Displayed weight item',
    state: 'OPEN',
    createdAt: DateTime.utc(2026, 10, 1),
    updatedAt: updatedAt ?? DateTime.utc(2026, 10, 2),
    project: group ? null : _project,
    namespace: group ? _group : _namespace,
    type: _type,
  ),
  description: null,
  widgetsAvailable: true,
  widgetTypes: widgetTypes,
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

WorkItemGraphDetail _shifted(
  WorkItemGraphDetail detail, {
  String? id,
  int? iid,
  String? title,
  DateTime? updatedAt,
  GraphResourceRef? project,
  GraphResourceRef? namespace,
  WorkItemGraphType? type,
}) {
  final summary = detail.summary;
  return WorkItemGraphDetail(
    summary: WorkItemGraphSummary(
      id: id ?? summary.id,
      iid: iid ?? summary.iid,
      title: title ?? summary.title,
      state: summary.state,
      createdAt: summary.createdAt,
      updatedAt: updatedAt ?? summary.updatedAt,
      project: project ?? summary.project,
      namespace: namespace ?? summary.namespace,
      type: type ?? summary.type,
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

final class _IdentityClosure {
  const _IdentityClosure(this.label, this.apply);

  final String label;
  final WorkItemGraphDetail Function(WorkItemGraphDetail detail) apply;
}

final List<_IdentityClosure> _identityClosures = [
  _IdentityClosure(
    'work item id',
    (WorkItemGraphDetail detail) =>
        _shifted(detail, id: 'gid://gitlab/WorkItem/99'),
  ),
  _IdentityClosure(
    'iid',
    (WorkItemGraphDetail detail) => _shifted(detail, iid: 99),
  ),
  _IdentityClosure(
    'type id',
    (WorkItemGraphDetail detail) => _shifted(
      detail,
      type: const WorkItemGraphType(
        id: 'gid://gitlab/WorkItems::Type/99',
        name: 'Task',
      ),
    ),
  ),
  _IdentityClosure(
    'project id',
    (WorkItemGraphDetail detail) => _shifted(
      detail,
      project: const GraphResourceRef(
        id: 'gid://gitlab/Project/99',
        fullPath: 'studio/mobile-workspace',
      ),
    ),
  ),
  _IdentityClosure(
    'project path',
    (WorkItemGraphDetail detail) => _shifted(
      detail,
      project: const GraphResourceRef(
        id: 'gid://gitlab/Project/42',
        fullPath: 'studio/renamed',
      ),
    ),
  ),
  _IdentityClosure(
    'namespace id',
    (WorkItemGraphDetail detail) => _shifted(
      detail,
      namespace: const GraphResourceRef(
        id: 'gid://gitlab/Namespaces::ProjectNamespace/99',
        fullPath: 'studio/mobile-workspace',
      ),
    ),
  ),
  _IdentityClosure(
    'namespace path',
    (WorkItemGraphDetail detail) => _shifted(
      detail,
      namespace: const GraphResourceRef(
        id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
        fullPath: 'studio/renamed',
      ),
    ),
  ),
  _IdentityClosure(
    'revision',
    (WorkItemGraphDetail detail) =>
        _shifted(detail, updatedAt: DateTime.utc(2026, 10, 4)),
  ),
];

final class _Owner extends ChangeNotifier {
  void ping() => notifyListeners();
}

Account _account(int id) => Account(
  instance: GitLabInstance.parse('https://example.com/gitlab'),
  user: GitLabUser(id: id, username: 'mobile-owner', name: '行動版擁有者'),
  token: 'synthetic-test-token',
);

class _PanelHarness extends StatefulWidget {
  const _PanelHarness({
    super.key,
    required this.server,
    required this.detail,
    this.api,
    this.observeWeightLifecycle = false,
  });

  final _WeightServer server;
  final WorkItemGraphDetail detail;
  final GitLabApi? api;
  final bool observeWeightLifecycle;

  @override
  State<_PanelHarness> createState() => _PanelState();
}

class _PanelState extends State<_PanelHarness> {
  final generation = ValueNotifier<int>(7);
  _Owner owner = _Owner();
  var current = true;
  late Account account = _account(7);
  late GitLabApi api = widget.api ?? testApi(widget.server.adapter);
  late WorkItemGraphDetail detail = widget.detail;
  Completer<void>? pendingAck;
  final weightPhases = <WorkItemWeightWritePhase>[];
  Route<dynamic>? route;

  _WeightServer get server => widget.server;

  void replace(VoidCallback change) => setState(change);

  void _captureRoute(Route<dynamic> opened) => route = opened;

  void _captureWeightPhase(
    WorkItemWeightWritePhase phase,
    Object token,
    Account account,
    GitLabApi api,
    WorkItemGraphDetail detail,
  ) {
    weightPhases.add(phase);
  }

  @override
  void dispose() {
    owner.dispose();
    generation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            WorkItemAttributesPanel(
              account: account,
              api: api,
              detail: detail,
              isCurrent: () =>
                  current && generation.value == 7 && account.user.id == 7,
              ownerChanges: owner,
              onRoute: widget.observeWeightLifecycle ? _captureRoute : null,
              onWeightWrite: widget.observeWeightLifecycle
                  ? _captureWeightPhase
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    required this.server,
    required this.detail,
    this.textScale = 1,
  });

  final _WeightServer server;
  final WorkItemGraphDetail detail;
  final double textScale;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final generation = ValueNotifier<int>(7);
  final saves = <WorkItemWeightSnapshot>[];
  _Owner owner = _Owner();
  var current = true;
  var show = true;
  late Account account = _account(7);
  late GitLabApi api = testApi(widget.server.adapter);
  late WorkItemGraphDetail detail = widget.detail;
  Route<dynamic>? route;

  _WeightServer get server => widget.server;

  void replace(VoidCallback change) => setState(change);

  void _captureRoute(Route<dynamic> opened) => route = opened;

  @override
  void dispose() {
    owner.dispose();
    generation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final latest = saves.isEmpty ? null : saves.last;
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
              Text(
                latest == null ? '尚未儲存' : _savedText(latest),
                key: const ValueKey('work-item-weight-saved'),
              ),
              if (show)
                WorkItemWeightControl(
                  account: account,
                  api: api,
                  detail: detail,
                  isCurrent: () =>
                      current && generation.value == 7 && account.user.id == 7,
                  ownerChanges: owner,
                  onRoute: _captureRoute,
                  onSaved: (snapshot) => setState(() => saves.add(snapshot)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _savedText(WorkItemWeightSnapshot snapshot) {
  final value = snapshot.value;
  if (value == null) return '已儲存：無欄位';
  return '已儲存：${value.weight}/${value.rolledUpWeight}/${value.rolledUpCompletedWeight}';
}

class _WeightServer {
  _WeightServer({
    required this.detail,
    this.weight,
    this.title = 'Fresh weight item',
    this.admin = true,
    this.extraPermissions = false,
    this.widgets = _Widgets.present,
  });

  final WorkItemGraphDetail detail;
  int? weight;
  int? rolled = 10;
  int? completed = 3;
  String title;
  bool admin;
  bool extraPermissions;
  _Widgets widgets;
  String updatedAt = '2026-10-03T10:00:00.000Z';
  bool rejectNext = false;
  bool loseNext = false;
  bool driftNextRead = false;
  int? rolledAfterWrite;
  int? completedAfterWrite;
  Completer<void>? holdRead;
  Completer<void>? holdWriteApply;
  Completer<void>? holdWrite;
  Completer<void>? holdAttribute;
  int? staleAttributeOwn;
  int? staleAttributeRolled;
  int? staleAttributeCompleted;
  var reads = 0;
  var writes = 0;
  var attributeReads = 0;
  var detailReads = 0;
  final sent = <Object?>[];
  late final FakeAdapter adapter = FakeAdapter(_respond);

  Future<ResponseBody> _respond(RequestOptions request) async {
    final body = _body(request);
    final query = body['query'];
    if (query is! String) throw StateError('Missing GraphQL query');
    final operation = body['operationName'];
    final name = operation is String ? operation : '';
    final isDetail =
        query.contains('MobileProjectWorkItem') ||
        query.contains('MobileNamespaceWorkItem');
    final isWrite =
        name == 'MobileSetWorkItemWeight' ||
        query.contains('MobileSetWorkItemWeight');
    final isAttribute =
        !isWrite &&
        (name == 'MobileWorkItemWeightAttribute' ||
            query.contains('MobileWorkItemWeightAttribute'));
    final isRead =
        !isWrite &&
        !isAttribute &&
        (name == 'MobileWorkItemWeight' ||
            query.contains('MobileWorkItemWeight'));
    if (isDetail) {
      detailReads++;
      return jsonResponse(_detailEnvelope());
    }
    if (!isRead && !isWrite && !isAttribute) {
      throw StateError('Unexpected weight operation: $name');
    }
    if (isAttribute) {
      attributeReads++;
      final variables = body['variables'];
      final requested = variables is Map ? variables['id'] : null;
      final own = staleAttributeOwn ?? weight;
      final rolledUp = staleAttributeRolled ?? rolled;
      final done = staleAttributeCompleted ?? completed;
      staleAttributeOwn = null;
      staleAttributeRolled = null;
      staleAttributeCompleted = null;
      final gate = holdAttribute;
      holdAttribute = null;
      if (gate != null) await gate.future;
      return jsonResponse({
        'data': {
          'workItem': _attributeItem(
            requested is String ? requested : null,
            own,
            rolledUp,
            done,
          ),
        },
      });
    }
    if (isRead) {
      reads++;
      final gate = holdRead;
      holdRead = null;
      if (gate != null) await gate.future;
      if (driftNextRead) {
        driftNextRead = false;
        updatedAt = '2026-10-03T10:05:00.000Z';
      }
      return jsonResponse({
        'data': {
          'currentUser': {'id': 'gid://gitlab/User/7'},
          'workItem': _workItem(),
        },
      });
    }
    writes++;
    final variables = body['variables'];
    if (variables is! Map) throw StateError('Missing mutation variables');
    final input = variables['input'];
    if (input is! Map) throw StateError('Missing weight input');
    final weightWidget = input['weightWidget'];
    if (weightWidget is! Map || !weightWidget.containsKey('weight')) {
      throw StateError('Missing weightWidget.weight');
    }
    final desired = weightWidget['weight'];
    sent.add(desired);
    if (rejectNext) {
      rejectNext = false;
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': ['Synthetic rejection'],
            'workItem': null,
          },
        },
      });
    }
    if (loseNext) {
      loseNext = false;
      return jsonResponse({
        'errors': [
          {'message': 'lost acknowledgement'},
        ],
      }, status: 503);
    }
    if (desired != null && desired is! int) {
      throw StateError('Weight must be an int or null');
    }
    final applyGate = holdWriteApply;
    holdWriteApply = null;
    if (applyGate != null) await applyGate.future;
    weight = desired as int?;
    if (rolledAfterWrite != null) {
      rolled = rolledAfterWrite;
      rolledAfterWrite = null;
    }
    if (completedAfterWrite != null) {
      completed = completedAfterWrite;
      completedAfterWrite = null;
    }
    updatedAt = '2026-10-03T10:06:00.000Z';
    final gate = holdWrite;
    holdWrite = null;
    if (gate != null) await gate.future;
    return jsonResponse({
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/7'},
        'workItemUpdate': {'errors': <String>[], 'workItem': _workItem()},
      },
    });
  }

  Map<String, Object?> _attributeItem(
    String? id,
    int? own,
    int? rolledUp,
    int? done,
  ) {
    final item = _workItem();
    if (id != null) item['id'] = id;
    item['widgets'] = [
      {
        'type': 'WEIGHT',
        'weight': own,
        'rolledUpWeight': rolledUp,
        'rolledUpCompletedWeight': done,
      },
    ];
    return item;
  }

  Map<String, Object?> _detailEnvelope() {
    final item = _workItem();
    final summary = detail.summary;
    if (summary.project == null) {
      return {
        'data': {
          'namespace': {
            'id': summary.namespace!.id,
            'fullPath': summary.namespace!.fullPath,
            'workItem': item,
          },
        },
      };
    }
    return {
      'data': {
        'project': {
          'id': summary.project!.id,
          'fullPath': summary.project!.fullPath,
          'workItems': {
            'nodes': [item],
            'pageInfo': {'hasNextPage': false, 'endCursor': null},
          },
        },
      },
    };
  }

  Map<String, Object?> _workItem() {
    final summary = detail.summary;
    return {
      'id': summary.id,
      'iid': '${summary.iid}',
      'title': title,
      'state': 'OPEN',
      'createdAt': '2026-10-01T10:00:00.000Z',
      'updatedAt': updatedAt,
      'project': summary.project == null
          ? null
          : {'id': summary.project!.id, 'fullPath': summary.project!.fullPath},
      'namespace': summary.namespace == null
          ? null
          : {
              'id': summary.namespace!.id,
              'fullPath': summary.namespace!.fullPath,
            },
      'workItemType': {'id': summary.type.id, 'name': summary.type.name},
      'userPermissions': {
        'readWorkItem': true,
        'adminWorkItem': admin,
        if (extraPermissions) 'setWorkItemMetadata': true,
        if (extraPermissions) 'updateWorkItem': true,
      },
      'widgets': switch (widgets) {
        _Widgets.unavailable => null,
        _Widgets.absent => <Object>[],
        _Widgets.present => [
          {
            'type': 'WEIGHT',
            'weight': weight,
            'rolledUpWeight': rolled,
            'rolledUpCompletedWeight': completed,
          },
        ],
      },
    };
  }

  Map<String, dynamic> _body(RequestOptions request) {
    final data = request.data;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    if (data is String) {
      return Map<String, dynamic>.from(jsonDecode(data) as Map);
    }
    if (data is List<int>) {
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(data)) as Map);
    }
    throw StateError('Unexpected GraphQL body ${data.runtimeType}');
  }
}
