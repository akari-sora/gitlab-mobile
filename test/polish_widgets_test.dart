import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show workspaceHost;

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final light = la > lb ? la : lb, darkL = la > lb ? lb : la;
  return (light + 0.05) / (darkL + 0.05);
}

Widget _host(Widget child, {Brightness brightness = Brightness.light}) => MaterialApp(
  theme: appTheme(brightness), home: Scaffold(body: Center(child: child)));

List<SemanticsNode> _semanticsUnder(SemanticsNode root) {
  final nodes = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    nodes.add(node);
    node.visitChildren((SemanticsNode child) {
      visit(child);
      return true;
    });
  }
  visit(root);
  return nodes;
}

const _statusLabels = {
  'opened': '開啟中', 'active': '進行中', 'closed': '已關閉', 'merged': '已合併',
  'success': '成功', 'passed': '成功', 'failed': '失敗', 'running': '執行中',
  'pending': '等待中', 'created': '等待中', 'waiting_for_resource': '等待中', 'preparing': '等待中',
  'canceled': '已取消', 'skipped': '已略過', 'manual': '等待手動啟動',
  'private': '私有', 'internal': '內部', 'public': '公開',
};

void main() {
  test('workshop colours compare by value', () {
    expect(WorkshopColors.light.copyWith(), WorkshopColors.light);
    expect(WorkshopColors.light.lerp(WorkshopColors.dark, 0), WorkshopColors.light);
    expect(WorkshopColors.light, isNot(WorkshopColors.dark));
  });

  testWidgets('appearance picker falls back to wrapping chips at 320 dp with double text', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ThemeMode? chosen;
    await tester.pumpWidget(MaterialApp(theme: appTheme(Brightness.light), home: MediaQuery(
      data: const MediaQueryData(size: Size(320, 900), textScaler: TextScaler.linear(2)),
      child: Scaffold(body: Padding(padding: const EdgeInsets.all(20),
        child: AppearancePicker(mode: ThemeMode.system, onChanged: (m) => chosen = m))))));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byType(SegmentedButton<ThemeMode>), findsNothing);
    expect(find.text('跟隨系統'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      expect(tester.getSize(find.byType(ChoiceChip).at(i)).height, greaterThanOrEqualTo(48));
    }
    await tester.tap(find.widgetWithText(ChoiceChip, '深色'));
    expect(chosen, ThemeMode.dark);
  });

  testWidgets('appearance picker is a segmented control when there is room', (tester) async {
    await tester.pumpWidget(_host(AppearancePicker(mode: ThemeMode.light, onChanged: (_) {})));
    expect(find.byType(SegmentedButton<ThemeMode>), findsOneWidget);
  });

  testWidgets('appearance segments are at least 48 dp at 412 dp', (tester) async {
    tester.view.physicalSize = const Size(412, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(body: AppearancePicker(mode: ThemeMode.light, onChanged: (_) {})),
    ));
    final segments = find.descendant(
      of: find.byType(SegmentedButton<ThemeMode>), matching: find.byType(TextButton));
    expect(segments, findsNWidgets(3));
    for (var i = 0; i < 3; i++) {
      final size = tester.getSize(segments.at(i));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
  });
  test('monogram initials keep at least 4.5:1 contrast for every hue in both modes', () {
    for (final brightness in Brightness.values) {
      for (var i = 0; i < 64; i++) {
        final name = String.fromCharCode(65 + i % 26) + 'x' * (i ~/ 26);
        final (container, foreground) = Monogram.colorsFor(name, brightness);
        expect(_contrast(container, foreground), greaterThanOrEqualTo(4.5),
          reason: '$name ${brightness.name} ${container.toARGB32().toRadixString(16)} on ${foreground.toARGB32().toRadixString(16)}');
      }
    }
  });

  test('workshop status tints keep readable text in both modes', () {
    for (final colors in [WorkshopColors.light, WorkshopColors.dark]) {
      expect(_contrast(colors.successContainer, colors.onSuccessContainer), greaterThanOrEqualTo(4.5));
      expect(_contrast(colors.runningContainer, colors.onRunningContainer), greaterThanOrEqualTo(4.5));
      expect(_contrast(colors.pendingContainer, colors.onPendingContainer), greaterThanOrEqualTo(4.5));
      expect(_contrast(colors.neutralContainer, colors.onNeutralContainer), greaterThanOrEqualTo(4.5));
    }
  });

  for (final entry in _statusLabels.entries) {
    testWidgets('status ${entry.key} announces ${entry.value} exactly once', (tester) async {
      await tester.pumpWidget(_host(StatusBadge(entry.key)));
      final label = tester.getSemantics(find.byType(StatusBadge)).label;
      expect(label, entry.value);
      expect(entry.value.allMatches(label).length, 1);
    });
  }

  testWidgets('entity card merges label, status and tap action into one node', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(EntityCard(
      title: const Text('Test issue'),
      meta: const [StatusBadge('opened'), MetaChip('#7', mono: true)], onTap: () => taps++)));
    // Merged descendants are only visible through the effective data.
    final node = tester.getSemantics(find.byType(EntityCard));
    final data = node.getSemanticsData();
    expect(data.label, contains('Test issue'));
    expect(data.label, contains('#7'));
    expect(data.label, contains('開啟中'));
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    // The test view's semantics owner still lives on this binding field.
    // ignore: deprecated_member_use
    tester.binding.pipelineOwner.semanticsOwner!.performAction(node.id, SemanticsAction.tap);
    expect(taps, 1);
  });

  testWidgets('trailing control stays outside the merged card action', (tester) async {
    var taps = 0, trailingTaps = 0;
    await tester.pumpWidget(_host(EntityCard(
      title: const Text('Todo'), onTap: () => taps++,
      subtitle: const Text('studio/mobile-workspace'),
      meta: const [StatusBadge('opened'), MetaChip('#7', mono: true)],
      trailing: IconButton(tooltip: 'X', onPressed: () => trailingTaps++, icon: const Icon(Icons.check)))));
    final card = tester.getSemantics(find.byType(EntityCard));
    final nodes = [card, ..._semanticsUnder(card)];
    final content = nodes.where((node) => node.getSemanticsData().label.contains('Todo'));
    final action = nodes.where((node) {
      final data = node.getSemanticsData();
      return data.tooltip == 'X' || data.label == 'X';
    });
    expect(content, hasLength(1));
    expect(action, hasLength(1));
    expect(content.single.id, isNot(action.single.id));
    // The tappable content is itself the named button node.
    final contentData = content.single.getSemanticsData();
    expect(contentData.label, contains('開啟中'));
    expect(contentData.label, contains('#7'));
    expect(contentData.label, contains('studio/mobile-workspace'));
    expect(contentData.flagsCollection.isButton, isTrue);
    expect(contentData.hasAction(SemanticsAction.tap), isTrue);
    // ignore: deprecated_member_use
    final owner = tester.binding.pipelineOwner.semanticsOwner!;
    owner.performAction(content.single.id, SemanticsAction.tap);
    expect(taps, 1);
    expect(trailingTaps, 0);
    owner.performAction(action.single.id, SemanticsAction.tap);
    expect(trailingTaps, 1);
    expect(taps, 1);
  });

  testWidgets('merge request card merges project, branches, pipeline and time', (tester) async {
    await tester.pumpWidget(_host(Builder(builder: (context) => workItemCard(context, {
      'iid': 7, 'title': 'Ship navigation', 'state': 'opened',
      'source_branch': 'feature/nav', 'target_branch': 'main',
      'updated_at': '2020-01-15T12:00:00Z',
      'head_pipeline': {'id': 3, 'status': 'success'},
    }, mr: true, project: 'group/proj', onTap: () {}))));
    final label = tester.getSemantics(find.byType(EntityCard)).getSemanticsData().label;
    for (final piece in const [
      'Ship navigation', 'group/proj', 'feature/nav → main', '開啟中', '成功', '!7', '2020/01/15',
    ]) {
      expect(label, contains(piece), reason: piece);
    }
  });

  testWidgets('issue and merge request cards say who opened them', (tester) async {
    for (final mr in [false, true]) {
      await tester.pumpWidget(_host(Builder(builder: (context) => workItemCard(context, {
        'iid': 114, 'title': 'Readings flicker', 'state': 'opened',
        'updated_at': '2020-01-15T12:00:00Z',
        'author': {'id': 9, 'username': 'synthetic-dev', 'name': 'Synthetic Dev'},
      }, mr: mr, onTap: () {}))));
      expect(find.text('@synthetic-dev'), findsOneWidget, reason: 'mr: $mr');
      final label = tester.getSemantics(find.byType(EntityCard)).getSemanticsData().label;
      expect(label, contains(l10n.authorLabel('@synthetic-dev')), reason: 'mr: $mr');
    }
    // A row without an author has no empty chip.
    await tester.pumpWidget(_host(Builder(builder: (context) => workItemCard(context, {
      'iid': 3, 'title': 'No author', 'state': 'opened', 'updated_at': '2020-01-15T12:00:00Z',
    }, mr: false, onTap: () {}))));
    expect(find.byType(PersonChip), findsNothing);
  });

  testWidgets('work item titles lay out three lines at 412 dp', (tester) async {
    tester.view.physicalSize = const Size(412, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final title = List.filled(24, 'Navigation polish').join(' ');
    await tester.pumpWidget(MaterialApp(theme: appTheme(Brightness.light), home: Scaffold(
      body: Builder(builder: (context) => workItemCard(context, {
        'iid': 4, 'title': title, 'state': 'opened', 'updated_at': '2020-01-15T12:00:00Z',
      }, mr: false, onTap: () {})))));
    final finder = find.text(title);
    final text = tester.widget<Text>(finder);
    expect(text.maxLines ?? DefaultTextStyle.of(tester.element(finder)).maxLines, 3);
    final paragraph = tester.renderObject<RenderParagraph>(finder);
    expect(paragraph.maxLines, 3);
    expect(paragraph.didExceedMaxLines, isTrue);
    final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: title.length));
    final lines = boxes.map((box) => box.top.round()).toSet();
    expect(lines, hasLength(3), reason: boxes.map((box) => '${box.top}-${box.bottom}').join(', '));
  });

  testWidgets('feed gutter follows the viewport width', (tester) async {
    final expected = {320.0: 16.0, 412.0: 16.0, 672.0: 16.0, 673.0: 16.5, 840.0: 100.0};
    for (final entry in expected.entries) {
      double? gutter;
      await tester.pumpWidget(MediaQuery(
        data: MediaQueryData(size: Size(entry.key, 800)),
        child: Builder(builder: (context) {
          gutter = feedGutter(context);
          return const SizedBox.shrink();
        }),
      ));
      expect(gutter, entry.value, reason: 'width ${entry.key}');
    }
  });

  testWidgets('milestone list labels active and closed and omits a missing state', (tester) async {
    final adapter = FakeAdapter((request) => request.uri.path.endsWith('/milestones')
      ? jsonResponse([
          {'id': 1, 'title': 'Active sprint', 'state': 'active'},
          {'id': 2, 'title': 'Closed sprint', 'state': 'closed'},
          {'id': 3, 'title': 'Undated sprint'},
        ])
      : jsonResponse({'error': 'unused'}, status: 404));
    final api = testApi(adapter);
    addTearDown(api.close);
    final account = Account(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      user: const GitLabUser(id: 7, username: 'tester', name: 'Tester'),
      token: 'synthetic-test-token',
    );
    final project = Project.fromJson(<String, dynamic>{
      'id': 42, 'name': 'Example', 'path_with_namespace': 'team/example',
      'visibility': 'private', 'default_branch': 'main', 'archived': false,
    });
    await tester.pumpWidget(workspaceHost(MetadataPage(
      account: account, api: api, project: project, kind: MetadataKind.milestones)));
    await settleNetworkWidgets(tester);
    Finder cardOf(String title) => find.ancestor(of: find.text(title), matching: find.byType(EntityCard));
    expect(find.descendant(of: cardOf('Active sprint'), matching: find.text('進行中')), findsOneWidget);
    expect(find.descendant(of: cardOf('Closed sprint'), matching: find.text('已關閉')), findsOneWidget);
    expect(find.descendant(of: cardOf('Undated sprint'), matching: find.byType(StatusBadge)), findsNothing);
  });

  testWidgets('entity card wraps its meta row at 320 dp with double text scale', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: appTheme(Brightness.dark), home: MediaQuery(
      data: const MediaQueryData(size: Size(320, 900), textScaler: TextScaler.linear(2)),
      child: Scaffold(body: ListView(children: [EntityCard(
        leading: const Monogram('gitlab-mobile'), title: const Text('A fairly long merge request title that wraps'),
        subtitle: const Text('aa22396584/gitlab-mobile'),
        body: const MetaChip('feature/navigation → main', icon: Icons.call_split, mono: true),
        meta: const [StatusBadge('opened'), StatusBadge('running'), MetaChip('!12', mono: true),
          MetaChip('2026/09/01', icon: Icons.schedule_outlined)], onTap: () {},
        trailing: IconButton(tooltip: '完成', onPressed: () {}, icon: const Icon(Icons.check_circle_outline)))])))));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
