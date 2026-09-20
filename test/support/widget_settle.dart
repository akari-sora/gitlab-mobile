import 'package:flutter_test/flutter_test.dart';

/// Dio response cancellation and chained requests can cross the test clock and
/// real event loop. Animation settling alone does not imply HTTP readiness.
Future<void> settleNetworkWidgets(WidgetTester tester) async {
  for (var cycle = 0; cycle < 10; cycle++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
  }
  await tester.pumpAndSettle(const Duration(milliseconds: 50),
    EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
}
