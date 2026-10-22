import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';

import '../session_test.dart' show MemoryAccountStore, controllerFor;
import '../support/fake_adapter.dart';
import '../support/workspace_fixture.dart';

void main() {
  test('the client gate closes during a 429 wait and after close', () async {
    final adapter = FakeAdapter(
      (_) => jsonResponse(
        {},
        status: 429,
        headers: {
          'retry-after': ['60'],
        },
      ),
    );
    final api = testApi(adapter);
    expect(api.mayStartRequest, isTrue);
    await expectLater(api.currentUser(), throwsA(anything));
    expect(api.mayStartRequest, isFalse);

    final open = testApi(FakeAdapter((_) => jsonResponse({})));
    expect(open.mayStartRequest, isTrue);
    open.close();
    expect(open.mayStartRequest, isFalse);
    api.close();
  });

  testWidgets(
    'production conversations write only while the app is on screen',
    (tester) async {
      final fixture = WorkspaceFixture();
      final accounts = MemoryAccountStore()
        ..accounts = [fixture.account]
        ..lastActive = fixture.account.key;
      final session = controllerFor(accounts, fixture.adapter);
      final settings = AiSettingsController(MemoryAiStore());
      await tester.runAsync(() async {
        await session.initialize();
        await settings.initialize();
        await settings.loadAccount(fixture.account.key);
      });
      // The default factory, as AuthenticatedApp builds it.
      final registry = AccountAiRunRegistry(
        session: session,
        settings: settings,
      );
      final controller =
          registry.open(const AiGeneralOrigin()) as AiChatController;

      final binding = tester.binding;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(controller.writeGatesOpen, isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(controller.writeGatesOpen, isTrue);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(controller.writeGatesOpen, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(controller.writeGatesOpen, isFalse);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(controller.writeGatesOpen, isTrue);

      // A closed client shuts the gate even on screen.
      session.api!.close();
      expect(controller.writeGatesOpen, isFalse);

      registry.dispose();
      await tester.runAsync(() async {
        settings.dispose();
        session.dispose();
      });
    },
  );
}
