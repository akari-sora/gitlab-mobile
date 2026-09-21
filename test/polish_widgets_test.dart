import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final light = la > lb ? la : lb, darkL = la > lb ? lb : la;
  return (light + 0.05) / (darkL + 0.05);
}

Widget _host(Widget child, {Brightness brightness = Brightness.light}) => MaterialApp(
  theme: appTheme(brightness), home: Scaffold(body: Center(child: child)));

void main() {
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

  testWidgets('status badge announces its label exactly once', (tester) async {
    await tester.pumpWidget(_host(const StatusBadge('opened')));
    final semantics = tester.getSemantics(find.byType(StatusBadge));
    expect(semantics.label, '開啟中');
  });

  testWidgets('entity card merges label, status and tap action into one node', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(EntityCard(
      title: const Text('Test issue'),
      meta: const [StatusBadge('opened'), MetaChip('#7', mono: true)], onTap: () => taps++)));
    // Merged descendants are only visible through the effective data.
    final data = tester.getSemantics(find.byType(EntityCard)).getSemanticsData();
    expect(data.label, contains('Test issue'));
    expect(data.label, contains('#7'));
    expect(data.label, contains('開啟中'));
    expect(data.flagsCollection.isButton, isTrue);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    await tester.tap(find.byType(EntityCard));
    expect(taps, 1);
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
          MetaChip('2026/09/01', icon: Icons.schedule_outlined)], onTap: () {})])))));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
