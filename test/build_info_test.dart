import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';

void main() {
  const info = BuildInfo(version: '0.3.0', buildNumber: '3', commit: 'e941a6ac');
  const line = '版本 0.3.0 (3) · commit e941a6ac';

  testWidgets('injected loader renders the version line and the copy button writes the clipboard text', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    String? copied;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        final Object? arguments = call.arguments;
        if (arguments is Map<String, dynamic>) {
          final Object? text = arguments['text'];
          if (text is String) copied = text;
        }
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    final gate = Completer<BuildInfo>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete(info);
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BuildInfoLine(load: () => gate.future)),
      ),
    );
    expect(find.text('版本 …'), findsOneWidget);
    expect(find.byTooltip('複製版本資訊'), findsNothing);

    gate.complete(info);
    await tester.pump();

    expect(find.text(line), findsOneWidget);
    final button = find.byTooltip('複製版本資訊');
    expect(button, findsOneWidget);
    final lineNode = tester.getSemantics(find.text(line));
    final buttonNode = tester.getSemantics(button);
    expect(lineNode.id, isNot(buttonNode.id));
    expect(lineNode.label, line);
    expect(buttonNode.label, '複製版本資訊');

    await tester.tap(button);
    await tester.pump();
    await tester.pump();

    expect(copied, 'GitLab Mobile 0.3.0 (3) · e941a6ac · Android');
    expect(find.text('已複製'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('failure loader renders 版本未知', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BuildInfoLine(
            load: () async => throw StateError('package info unavailable'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('版本未知'), findsOneWidget);
    expect(find.text('版本 …'), findsNothing);
    expect(find.byTooltip('複製版本資訊'), findsNothing);
  });
}
