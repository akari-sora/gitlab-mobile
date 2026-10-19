import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'support/fake_shortcuts.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show workspaceHost;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'the sort stays on screen on a narrow phone while the scopes scroll',
    (tester) async {
      final api = testApi(FakeAdapter((_) => jsonResponse([])));
      final session = SessionController(MemoryAccountStore())
        ..active = Account(
          instance: api.instance,
          user: const GitLabUser(id: 7, username: 'first', name: 'First'),
          token: 'synthetic-first',
        )
        ..api = api;
      addTearDown(api.close);
      addTearDown(session.dispose);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        workspaceHost(
          ProjectsPage(
            session: session,
            recentStore: MemoryRecentProjectStore(),
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      final sort = find.byTooltip('排序方式');
      expect(sort.hitTestable(), findsOneWidget);
      expect(tester.getRect(sort).right, lessThanOrEqualTo(320 - 16));

      // The last scope is reached by scrolling, without moving the sort.
      final sortRect = tester.getRect(sort);
      await tester.dragUntilVisible(
        find.text('群組'),
        find.text('我的專案'),
        const Offset(-80, 0),
      );
      await tester.tap(find.text('群組'));
      await settleNetworkWidgets(tester);
      expect(sort, findsNothing, reason: 'groups have no sort');
      await tester.drag(find.text('群組'), const Offset(400, 0));
      await tester.tap(find.text('我的專案'));
      await settleNetworkWidgets(tester);
      expect(tester.getRect(find.byTooltip('排序方式')), sortRect);
    },
  );
}
