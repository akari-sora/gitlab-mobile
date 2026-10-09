import 'dart:ui' show CheckedState;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_attribute_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_weight_models.dart';
import 'package:gitlab_mobile/features/workspace/work_item_attributes.dart';
import 'package:gitlab_mobile/features/workspace/work_item_weight.dart';

import '../tool/emulator_ui.dart';
import 'support/widget_settle.dart';

const _projectId = 'gid://gitlab/WorkItem/1031';
const _groupId = 'gid://gitlab/WorkItem/1041';
const _edit = ValueKey('work-item-weight-edit');
const _set = ValueKey('work-item-weight-set');
const _remove = ValueKey('work-item-weight-remove');
const _input = ValueKey('work-item-weight-input');
const _save = ValueKey('work-item-weight-save');

Future<WorkItemGraphDetail> _detail(EmulatorQaFixture fixture, bool group) =>
    group
    ? fixture.api.namespaceWorkItem(
        'qa/synthetic-group',
        41,
        expectedNamespaceId: 'gid://gitlab/Group/84',
      )
    : fixture.api.projectWorkItem(fixture.project, 31);

Future<WorkItemWeightAccess> _open(
  EmulatorQaFixture fixture,
  WorkItemGraphDetail detail,
) =>
    fixture.api.workItemWeight(detail, expectedUserId: fixture.account.user.id);

Future<WorkItemWeightAttribute> _stored(
  EmulatorQaFixture fixture,
  WorkItemGraphDetail detail,
) async {
  final snapshot = await fixture.api.workItemAttribute(
    detail.summary,
    WorkItemAttributeKind.weight,
  );
  expect(snapshot.availability, WorkItemAttributeAvailability.present);
  final value = snapshot.value;
  expect(value, isA<WorkItemWeightAttribute>());
  return value! as WorkItemWeightAttribute;
}

void _expectRollups(WorkItemWeightAttribute value, bool group) {
  expect(value.rolledUpWeight, group ? 12 : isNull);
  expect(value.rolledUpCompletedWeight, group ? 5 : isNull);
}

void _expectInput(Map<String, Object?> event, String id, int? weight) {
  expect(event['input'], {
    'id': id,
    'weightWidget': {'weight': weight},
  });
  expect(event['accepted'], isTrue);
}

Future<WorkItemWeightSnapshot> _updateWeight(
  EmulatorQaFixture fixture,
  WorkItemWeightTarget target,
  int? weight,
) => fixture.api.updateWorkItemWeight(target, weight: weight);

Future<void> _expectWeightFailure(Future<Object?> future, FailureKind kind) {
  return expectLater(
    future,
    throwsA(isA<ApiFailure>().having((failure) => failure.kind, 'kind', kind)),
  );
}

Future<WorkItemGraphDetail> _loadDetail(
  WidgetTester tester,
  EmulatorQaFixture fixture,
  bool group,
) async {
  final detail = await tester.runAsync(() => _detail(fixture, group));
  expect(detail, isNotNull);
  return detail!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('synthetic weight API', () {
    for (final group in [false, true]) {
      final scope = group ? 'group' : 'project';
      final id = group ? _groupId : _projectId;

      test('$scope keeps null, zero and rollups apart', () async {
        final fixture = EmulatorQaFixture();
        final detail = await _detail(fixture, group);
        expect(detail.widgetTypes, contains('WEIGHT'));
        final initial = await _stored(fixture, detail);
        expect(initial.weight, group ? 7 : 0);
        _expectRollups(initial, group);
        expect(fixture.workItemWeightEvents, isEmpty);

        final opened = await _open(fixture, detail);
        expect(opened.canSetWeight, isTrue);
        expect(opened.target, isNotNull);
        expect(opened.snapshot.value!.weight, initial.weight);
        _expectRollups(opened.snapshot.value!, group);

        final noop = await _updateWeight(
          fixture,
          opened.target!,
          initial.weight,
        );
        expect(noop.value!.weight, initial.weight);
        _expectRollups(noop.value!, group);
        expect(fixture.workItemWeightEvents, isEmpty);
        await _expectWeightFailure(
          _updateWeight(fixture, opened.target!, 21),
          FailureKind.writeUncertain,
        );
        expect(fixture.workItemWeightEvents, isEmpty);

        final raised = await _open(fixture, detail);
        final changed = await _updateWeight(fixture, raised.target!, 21);
        expect(changed.value!.weight, 21);
        _expectRollups(changed.value!, group);
        expect(fixture.workItemWeightEvents, hasLength(1));
        _expectInput(fixture.workItemWeightEvents.single, id, 21);
        expect((await _stored(fixture, detail)).weight, 21);

        final zeroedAccess = await _open(fixture, detail);
        final zeroed = await _updateWeight(fixture, zeroedAccess.target!, 0);
        expect(zeroed.value!.weight, 0);
        _expectRollups(zeroed.value!, group);
        expect(fixture.workItemWeightEvents, hasLength(2));
        _expectInput(fixture.workItemWeightEvents[1], id, 0);
        expect((await _stored(fixture, detail)).weight, 0);

        final clearedAccess = await _open(fixture, detail);
        final cleared = await _updateWeight(
          fixture,
          clearedAccess.target!,
          null,
        );
        expect(cleared.value, isNotNull);
        expect(cleared.value!.weight, isNull);
        _expectRollups(cleared.value!, group);
        expect(fixture.workItemWeightEvents, hasLength(3));
        _expectInput(fixture.workItemWeightEvents[2], id, null);
        final stored = await _stored(fixture, detail);
        expect(stored.weight, isNull);
        _expectRollups(stored, group);
        expect(fixture.unhandled, isEmpty);
      });

      test('$scope rejects permission, revision and absence once', () async {
        final fixture = EmulatorQaFixture();
        final detail = await _detail(fixture, group);
        final before = (await _stored(fixture, detail)).weight;

        fixture.workItemWeightAllowed = false;
        final denied = await _open(fixture, detail);
        expect(denied.canSetWeight, isFalse);
        expect(denied.target, isNull);
        expect(fixture.workItemWeightEvents, isEmpty);

        fixture.workItemWeightAllowed = true;
        final permitted = await _open(fixture, detail);
        fixture.workItemWeightAllowed = false;
        final freshDenied = await _open(fixture, detail);
        expect(freshDenied.canSetWeight, isFalse);
        expect(freshDenied.target, isNull);
        await _expectWeightFailure(
          _updateWeight(fixture, permitted.target!, 9),
          FailureKind.forbidden,
        );
        expect(fixture.workItemWeightEvents, isEmpty);
        expect((await _stored(fixture, detail)).weight, before);

        fixture.workItemWeightAllowed = true;
        final current = await _open(fixture, detail);
        fixture.reviseWorkItemWeight(group: group);
        await _expectWeightFailure(
          _updateWeight(fixture, current.target!, 8),
          FailureKind.conflict,
        );
        expect(fixture.workItemWeightEvents, isEmpty);
        expect((await _stored(fixture, detail)).weight, before);

        fixture.workItemWeightPresent = false;
        final absent = await _open(fixture, detail);
        expect(
          absent.snapshot.availability,
          WorkItemAttributeAvailability.absent,
        );
        expect(absent.snapshot.value, isNull);
        expect(absent.target, isNull);
        expect(fixture.workItemWeightEvents, isEmpty);
        fixture.workItemWeightPresent = true;
        final present = await _open(fixture, detail);
        fixture.workItemWeightPresent = false;
        await _expectWeightFailure(
          _updateWeight(fixture, present.target!, null),
          FailureKind.conflict,
        );
        expect(fixture.workItemWeightEvents, isEmpty);
        expect(fixture.workItemWeights[group], before);
        fixture.workItemWeightPresent = true;
        expect((await _stored(fixture, detail)).weight, before);
        expect(fixture.unhandled, isEmpty);
      });
    }

    test('lost acknowledgement mutates once and does not replay', () async {
      final fixture = EmulatorQaFixture();
      final detail = await _detail(fixture, false);
      final access = await _open(fixture, detail);
      fixture.failNextWorkItemWeightAcknowledgement = true;
      await _expectWeightFailure(
        _updateWeight(fixture, access.target!, 30),
        FailureKind.writeUncertain,
      );
      expect(fixture.workItemWeightEvents, hasLength(1));
      _expectInput(fixture.workItemWeightEvents.single, _projectId, 30);
      expect(fixture.failNextWorkItemWeightAcknowledgement, isFalse);
      await _expectWeightFailure(
        _updateWeight(fixture, access.target!, 30),
        FailureKind.writeUncertain,
      );
      expect(fixture.workItemWeightEvents, hasLength(1));
      final reopened = await _open(fixture, detail);
      expect(reopened.snapshot.value!.weight, 30);
      _expectRollups(reopened.snapshot.value!, false);
      expect(fixture.workItemWeightEvents, hasLength(1));
      expect(fixture.unhandled, isEmpty);
    });

    test('stale read epoch and closed session do not send', () async {
      final fixture = EmulatorQaFixture();
      final detail = await _detail(fixture, false);
      final access = await _open(fixture, detail);
      fixture.api.clearReadCache();
      await _expectWeightFailure(
        _updateWeight(fixture, access.target!, 4),
        FailureKind.cancelled,
      );
      await _expectWeightFailure(
        _updateWeight(fixture, access.target!, 4),
        FailureKind.writeUncertain,
      );
      expect(fixture.workItemWeightEvents, isEmpty);

      final closed = await _open(fixture, detail);
      await _expectWeightFailure(
        fixture.api.updateWorkItemWeight(
          closed.target!,
          weight: 4,
          isCurrent: () => false,
        ),
        FailureKind.cancelled,
      );
      await _expectWeightFailure(
        fixture.api.updateWorkItemWeight(
          closed.target!,
          weight: 4,
          isCurrent: () => false,
        ),
        FailureKind.writeUncertain,
      );
      expect(fixture.workItemWeightEvents, isEmpty);
      expect((await _stored(fixture, detail)).weight, 0);
      expect(fixture.unhandled, isEmpty);
    });

    test('Int32 bounds stay on the client and do not fall through', () async {
      final fixture = EmulatorQaFixture();
      final detail = await _detail(fixture, false);
      final access = await _open(fixture, detail);
      final saved = await _updateWeight(fixture, access.target!, 2147483647);
      expect(saved.value!.weight, 2147483647);
      expect(fixture.workItemWeightEvents, hasLength(1));
      final next = await _open(fixture, detail);
      await _expectWeightFailure(
        _updateWeight(fixture, next.target!, 2147483648),
        FailureKind.validation,
      );
      await _expectWeightFailure(
        _updateWeight(fixture, next.target!, -1),
        FailureKind.validation,
      );
      expect(fixture.workItemWeightEvents, hasLength(1));
      expect((await _stored(fixture, detail)).weight, 2147483647);
      expect(fixture.unhandled, isEmpty);
    });

    test('weight handling leaves milestone mutation intact', () async {
      final fixture = EmulatorQaFixture();
      final detail = await _detail(fixture, false);
      final weight = await _open(fixture, detail);
      await _updateWeight(fixture, weight.target!, 11);
      final milestone = await fixture.api.workItemMilestone(
        detail,
        expectedUserId: fixture.account.user.id,
      );
      expect(milestone.snapshot.milestone?.id, 'gid://gitlab/Milestone/905');
      final cleared = await fixture.api.updateWorkItemMilestone(
        milestone.target!,
        selection: milestone.target!.clearSelection,
      );
      expect(cleared.snapshot.milestone, isNull);
      expect(fixture.workItemMilestoneEvents, hasLength(1));
      expect(fixture.workItemWeightEvents, hasLength(1));
      expect((await _stored(fixture, detail)).weight, 11);
      expect(fixture.unhandled, isEmpty);
    });
  });

  group('synthetic weight panel', () {
    testWidgets('set, zero, clear and noop update only the weight row', (
      tester,
    ) async {
      final fixture = EmulatorQaFixture();
      final detail = await _loadDetail(tester, fixture, false);
      await _pumpPanel(tester, fixture, detail);
      await _openEditor(tester, '權重：0');
      expect(find.text('目前權重：0'), findsOneWidget);
      expect(find.text('彙整權重：未設定'), findsOneWidget);
      expect(find.text('已完成彙整權重：未設定'), findsOneWidget);
      await tester.tap(find.byKey(_save));
      await tester.pump();
      await pumpUntil(tester, () => _rowReady('權重：0'), description: '權重：0');
      expect(find.text('變更權重'), findsOneWidget);
      expect(fixture.workItemWeightEvents, isEmpty);

      await _openEditor(tester, '權重：0');
      await tester.enterText(find.byKey(_input), '21');
      await tester.pump();
      await tester.tap(find.byKey(_save));
      await tester.pump();
      await pumpUntil(tester, () => _rowReady('權重：21'), description: '權重：21');
      expect(fixture.workItemWeightEvents, hasLength(1));
      expect(find.text('彙整權重：未知'), findsOneWidget);

      await _openEditor(tester, '權重：21');
      await tester.enterText(find.byKey(_input), '0');
      await tester.pump();
      await tester.tap(find.byKey(_save));
      await tester.pump();
      await pumpUntil(tester, () => _rowReady('權重：0'), description: '權重：0');
      expect(fixture.workItemWeightEvents, hasLength(2));

      await _openEditor(tester, '權重：0');
      await tester.tap(find.byKey(_remove));
      await tester.pump();
      await tester.tap(find.byKey(_save));
      await tester.pump();
      await pumpUntil(tester, () => _rowReady('權重：未知'), description: '權重：未知');
      expect(find.text('彙整權重：未知'), findsOneWidget);
      expect(find.text('已完成彙整權重：未知'), findsOneWidget);
      expect(find.text('變更里程碑'), findsWidgets);
      expect(fixture.workItemWeightEvents, hasLength(3));
      expect(fixture.workItemMilestoneEvents, isEmpty);
      expect(fixture.unhandled, isEmpty);
    });

    testWidgets('group save and clear keep rolled-up totals', (tester) async {
      final fixture = EmulatorQaFixture();
      final detail = await _loadDetail(tester, fixture, true);
      await _pumpPanel(tester, fixture, detail);
      await _openEditor(tester, '權重：7');
      expect(find.text('彙整權重：12'), findsWidgets);
      expect(find.text('已完成彙整權重：5'), findsWidgets);
      await tester.enterText(find.byKey(_input), '20');
      await tester.pump();
      await tester.tap(find.byKey(_save));
      await tester.pump();
      await pumpUntil(tester, () => _rowReady('權重：20'), description: '權重：20');
      expect(find.text('彙整權重：12'), findsOneWidget);
      expect(find.text('已完成彙整權重：5'), findsOneWidget);
      await _openEditor(tester, '權重：20');
      await tester.tap(find.byKey(_remove));
      await tester.pump();
      await tester.tap(find.byKey(_save));
      await tester.pump();
      await pumpUntil(tester, () => _rowReady('權重：未知'), description: '權重：未知');
      expect(find.text('彙整權重：12'), findsOneWidget);
      expect(find.text('已完成彙整權重：5'), findsOneWidget);
      expect(fixture.workItemWeightEvents, hasLength(2));
      expect(fixture.unhandled, isEmpty);
    });

    testWidgets('choices are unique and the numeric field is separate', (
      tester,
    ) async {
      final fixture = EmulatorQaFixture();
      final detail = await _loadDetail(tester, fixture, false);
      final handle = SemanticsBinding.instance.ensureSemantics();
      await _pumpPanel(tester, fixture, detail);
      await _openEditor(tester, '權重：0');
      final setNode = tester.getSemantics(find.byKey(_set));
      final removeNode = tester.getSemantics(find.byKey(_remove));
      expect(setNode.flagsCollection.isButton, isTrue);
      expect(setNode.flagsCollection.isChecked, CheckedState.isTrue);
      expect(setNode.flagsCollection.isInMutuallyExclusiveGroup, isTrue);
      expect(
        setNode,
        isSemantics(
          isButton: true,
          hasCheckedState: true,
          isChecked: true,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
          label: '設定權重',
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
          isButton: true,
          hasCheckedState: true,
          isChecked: false,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
          label: '移除權重',
        ),
      );
      expect(
        removeNode.childrenCountInTraversalOrder,
        0,
        reason: 'the radio row must be one complete semantics node',
      );
      expect(setNode.id, isNot(removeNode.id));
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      final setRect = tester.getRect(find.byKey(_set));
      final removeRect = tester.getRect(find.byKey(_remove));
      final fieldRect = tester.getRect(find.byKey(_input));
      expect(setRect, isNot(equals(removeRect)));
      expect(fieldRect, isNot(equals(setRect)));
      expect(fieldRect, isNot(equals(removeRect)));
      handle.dispose();
    });

    testWidgets('narrow keyboard keeps the 48dp footer inside the width', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(640, 1600);
      tester.view.devicePixelRatio = 2;
      // ViewPadding is physical pixels. 560 / 2 = 280 logical, matching 800 - 280.
      tester.view.viewInsets = const FakeViewPadding(bottom: 560);
      addTearDown(tester.view.reset);
      final fixture = EmulatorQaFixture();
      final detail = await _loadDetail(tester, fixture, false);
      await _pumpPanel(tester, fixture, detail, textScale: 2);
      await _openEditor(tester, '權重：0');
      final editorScroll = find.descendant(
        of: find.byKey(const ValueKey('work-item-weight-scroll')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      );
      await tester.scrollUntilVisible(
        find.byKey(_input),
        80,
        scrollable: editorScroll,
      );
      for (var step = 0; step < 8; step++) {
        final field = tester.getRect(find.byKey(_input));
        final save = tester.getRect(find.byKey(_save));
        final tapY = field.top + 8;
        if (tapY >= field.top && tapY < save.top && tapY < field.bottom) {
          break;
        }
        final position = tester.state<ScrollableState>(editorScroll).position;
        if (field.bottom > save.top &&
            position.pixels >= position.maxScrollExtent) {
          break;
        }
        final delta = field.bottom > save.top
            ? save.top - field.bottom - 8
            : -field.top + 8;
        await tester.drag(editorScroll, Offset(0, delta));
        await tester.pump();
      }
      final field = tester.getRect(find.byKey(_input));
      final saveTop = tester.getRect(find.byKey(_save)).top;
      final tapY = field.top + 8;
      expect(tapY, lessThan(saveTop));
      await tester.tapAt(Offset(field.center.dx, tapY));
      await tester.pump();
      final save = tester.getRect(find.byKey(_save));
      expect(save.height, greaterThanOrEqualTo(48));
      expect(save.left, greaterThanOrEqualTo(0));
      expect(save.right, lessThanOrEqualTo(320));
      expect(save.top, greaterThanOrEqualTo(0));
      expect(save.bottom, lessThanOrEqualTo(800 - 280));
    });

    testWidgets('collapsing the loaded row does not read weight again', (
      tester,
    ) async {
      final fixture = EmulatorQaFixture();
      final detail = await _loadDetail(tester, fixture, false);
      await _pumpPanel(tester, fixture, detail);
      await _reveal(tester, '權重：0');
      final reads = fixture.workItemWeightReads.length;
      expect(reads, greaterThan(0));
      await tester.tap(find.text('屬性'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('屬性'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(fixture.workItemWeightReads, hasLength(reads));
    });

    testWidgets('permission, revision, absence and loss do not repeat', (
      tester,
    ) async {
      final fixture = EmulatorQaFixture();
      final detail = await _loadDetail(tester, fixture, false);
      await _pumpPanel(tester, fixture, detail);

      fixture.workItemWeightAllowed = false;
      await _openEditor(tester, '權重：0');
      expect(find.text('目前帳號沒有變更權重的權限。'), findsOneWidget);
      expect(find.byKey(_set), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
      await _leaveEditor(tester);
      expect(fixture.workItemWeightEvents, isEmpty);

      fixture.workItemWeightAllowed = true;
      await _openEditor(tester, '權重：0');
      fixture.reviseWorkItemWeight(group: false);
      await tester.enterText(find.byKey(_input), '6');
      await tester.pump();
      await tester.tap(find.byKey(_save));
      await tester.pump();
      await pumpUntil(
        tester,
        () => find.text('請關閉並重新開啟，讀取最新狀態後再變更。').evaluate().isNotEmpty,
      );
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
      expect(fixture.workItemWeightEvents, isEmpty);
      await _leaveEditor(tester);

      fixture.workItemWeightPresent = false;
      await _openEditor(tester, '權重：0');
      expect(find.text('這個工作項目沒有權重欄位。'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
      expect(fixture.workItemWeightEvents, isEmpty);
      await _leaveEditor(tester);

      fixture.workItemWeightPresent = true;
      await _openEditor(tester, '權重：0');
      final readsBeforeLoss = fixture.workItemWeightReads.length;
      fixture.failNextWorkItemWeightAcknowledgement = true;
      await tester.enterText(find.byKey(_input), '30');
      await tester.pump();
      await tester.tap(find.byKey(_save));
      await tester.pump();
      await pumpUntil(
        tester,
        () => find.textContaining('連線在寫入時中斷').evaluate().isNotEmpty,
      );
      expect(find.text('變更權重'), findsWidgets);
      expect(find.byType(SnackBar), findsNothing);
      expect(fixture.workItemWeightEvents, hasLength(1));
      expect(fixture.failNextWorkItemWeightAcknowledgement, isFalse);
      expect(tester.widget<FilledButton>(find.byKey(_save)).onPressed, isNull);
      await _leaveEditor(tester);
      await pumpUntil(tester, () => _rowReady('權重：30'), description: '權重：30');
      expect(find.text('權重：0'), findsNothing);
      expect(fixture.workItemWeightReads.length, greaterThan(readsBeforeLoss));
      expect(
        fixture.workItemWeightReads.skip(readsBeforeLoss),
        contains('MobileWorkItemWeightAttribute'),
      );
      expect(fixture.workItemWeightEvents, hasLength(1));
      await _openEditor(tester, '權重：30');
      expect(find.text('目前權重：30'), findsOneWidget);
      expect(fixture.workItemWeightEvents, hasLength(1));
      expect(fixture.failNextWorkItemWeightAcknowledgement, isFalse);
      expect(fixture.unhandled, isEmpty);
    });

    testWidgets('an owner epoch closes the editor without a write', (
      tester,
    ) async {
      final fixture = EmulatorQaFixture();
      final detail = await _loadDetail(tester, fixture, false);
      final owner = _RouteOwner();
      final current = [true];
      await _pumpPanel(
        tester,
        fixture,
        detail,
        ownerChanges: owner,
        isCurrent: () => current[0],
      );
      await _openEditor(tester, '權重：0');
      expect(find.byKey(_save), findsOneWidget);
      current[0] = false;
      owner.close();
      await tester.pump();
      await pumpUntil(tester, () => find.byKey(_save).evaluate().isEmpty);
      expect(find.byKey(_save), findsNothing);
      expect(find.byType(WorkItemWeightControl), findsNothing);
      expect(find.text('變更權重'), findsNothing);
      expect(find.text('權重：0'), findsNothing);
      expect(fixture.workItemWeightEvents, isEmpty);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(WorkItemWeightControl), findsNothing);
      expect(find.text('變更權重'), findsNothing);
      expect(fixture.workItemWeightEvents, isEmpty);
      expect(fixture.unhandled, isEmpty);
    });
  });
}

final class _RouteOwner extends ChangeNotifier {
  void close() => notifyListeners();
}

Future<void> _pumpPanel(
  WidgetTester tester,
  EmulatorQaFixture fixture,
  WorkItemGraphDetail detail, {
  Listenable? ownerChanges,
  bool Function()? isCurrent,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: ListView(
          children: [
            WorkItemAttributesPanel(
              account: fixture.account,
              api: fixture.api,
              detail: detail,
              isCurrent: isCurrent,
              ownerChanges: ownerChanges,
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('屬性'));
  await tester.pump();
  await settleNetworkWidgets(tester);
}

Finder _outerScrollable() {
  return find.byElementPredicate((element) {
    if (element.widget is! Scrollable) return false;
    return element.findAncestorWidgetOfExactType<ListView>() != null &&
        element.findAncestorWidgetOfExactType<TextField>() == null;
  });
}

Future<void> _reveal(WidgetTester tester, String row) async {
  await pumpUntil(tester, () => find.text(row).evaluate().isNotEmpty);
  await tester.scrollUntilVisible(
    find.text(row),
    240,
    scrollable: _outerScrollable(),
  );
  await tester.pump();
}

Future<void> _openEditor(WidgetTester tester, String row) async {
  await _reveal(tester, row);
  await tester.tap(find.byKey(_edit).hitTestable());
  await tester.pump();
  await pumpUntil(tester, () => find.byKey(_save).evaluate().isNotEmpty);
}

bool _rowReady(String row) {
  return find.byKey(_save).evaluate().isEmpty &&
      find.text(row).hitTestable().evaluate().isNotEmpty;
}

Future<void> _leaveEditor(WidgetTester tester) async {
  await tester.tap(find.byType(BackButton));
  await pumpUntil(
    tester,
    () => find.byKey(_save).evaluate().isEmpty,
    description: 'weight editor closed',
  );
  await settleNetworkWidgets(tester);
}
