import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/auth/recent_project.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show workspaceHost;

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final replacement in ['account', 'generation', 'api']) {
    for (final target in ['issue', 'project', 'recent']) {
      testWidgets(
        '$target navigation drops delayed project after $replacement changes',
        (tester) async {
          final pending = Completer<ResponseBody>();
          final adapter = FakeAdapter((request) {
            if (request.uri.pathSegments.last ==
                (target == 'recent' ? '42' : 'team/client')) {
              return pending.future;
            }
            return jsonResponse([]);
          });
          final originalApi = testApi(adapter);
          final secondApi = testApi(FakeAdapter((_) => jsonResponse([])));
          final originalAccount = Account(
            instance: originalApi.instance,
            user: const GitLabUser(id: 7, username: 'first', name: 'First'),
            token: 'synthetic-first',
          );
          final session = SessionController(MemoryAccountStore())
            ..active = originalAccount
            ..api = originalApi;
          final recentStore = SecureRecentProjectStore();
          if (target == 'recent') {
            await recentStore.touch(
              originalAccount.key,
              const RecentProject(
                id: 42,
                name: 'Stored recent project',
                path: 'team/client',
              ),
            );
          }
          addTearDown(originalApi.close);
          addTearDown(secondApi.close);
          addTearDown(session.dispose);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(412, 1000);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(
            workspaceHost(
              ProjectsPage(session: session, recentStore: recentStore),
            ),
          );
          await settleNetworkWidgets(tester);
          if (target == 'recent') {
            await tester.tap(find.byKey(const ValueKey('recent-project-42')));
          } else {
            await tester.tap(find.byTooltip('以連結或路徑開啟'));
            await settleNetworkWidgets(tester);
            await tester.enterText(
              find.descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(TextField),
              ),
              target == 'project'
                  ? 'team/client'
                  : 'https://example.com/gitlab/team/client/-/issues/5',
            );
            await tester.tap(find.widgetWithText(FilledButton, '開啟'));
          }
          await pumpUntil(
            tester,
            () => adapter.requests.any(
              (request) =>
                  request.uri.pathSegments.last ==
                  (target == 'recent' ? '42' : 'team/client'),
            ),
            description: 'project lookup started',
          );

          switch (replacement) {
            case 'account':
              session.active = Account(
                instance: originalApi.instance,
                user: const GitLabUser(
                  id: 8,
                  username: 'second',
                  name: 'Second',
                ),
                token: 'synthetic-second',
              );
            case 'generation':
              session.generation++;
            case 'api':
              session.api = secondApi;
          }
          await tester.pumpWidget(
            workspaceHost(
              ProjectsPage(session: session, recentStore: recentStore),
            ),
          );
          pending.complete(
            jsonResponse({
              'id': 42,
              'name': 'Old owner project',
              'path_with_namespace': 'team/client',
              'visibility': 'private',
              'default_branch': 'main',
            }),
          );
          await settleNetworkWidgets(tester);

          expect(find.byType(WorkItemPage), findsNothing);
          expect(find.text('Old owner project'), findsNothing);
          expect(
            adapter.requests.where(
              (request) => request.uri.pathSegments.contains('issues'),
            ),
            isEmpty,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
