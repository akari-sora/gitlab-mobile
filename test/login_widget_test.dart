import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/auth/login_screen.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'session_test.dart' show MemoryAccountStore;

void main() {
  for (final width in [320.0, 412.0, 840.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('login layout width=$width text-scale=$scale', (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final session = SessionController(MemoryAccountStore());
        addTearDown(session.dispose); await session.initialize();
        await tester.pumpWidget(MaterialApp(theme: appTheme(Brightness.light),
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale)), child: child!),
          home: LoginScreen(session: session)));
        expect(find.byKey(const Key('instanceField')), findsOneWidget);
        expect(find.byKey(const Key('tokenField')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.byKey(const Key('connectButton')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
