import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';

import 'ai/fx_coord_support.dart';
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';

const _timeout = Duration(seconds: 10);

Future<void> _until(bool Function() predicate) async {
  final elapsed = Stopwatch()..start();
  while (!predicate() && elapsed.elapsed < _timeout) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(predicate(), isTrue, reason: 'fixture did not settle');
}

AiWriteScope _scope(StackHarness harness) => AiWriteScope(
  accountKey: harness.account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: harness.server.workspace.project.id,
      projectPath: harness.server.workspace.project.path,
    ),
  ],
);

Future<AiChatController> _controller(
  StackHarness harness,
  AiWriteFreshnessReader readFreshness,
) async {
  final controller = AiChatController(
    origin: AiFileOrigin(
      project: harness.server.workspace.project,
      path: 'README.md',
      sha: WorkspaceFixture.sha,
    ),
    session: harness.session,
    settings: harness.settings,
    runningCount: () => 0,
    appInForeground: () => true,
    clientMayStart: () => true,
    writeJournal: harness.journal,
    writeScope: () => _scope(harness),
    readWriteFreshness: readFreshness,
    wireClientFactory:
        ({required config, required apiKey, required conversationId}) =>
            AiWireClient(
              transport: AiTransport(
                endpoint: AiEndpoint.parse(
                  config.baseUrl,
                  allowLanCleartext: false,
                ),
                apiKey: apiKey ?? '',
                authStyle: config.authStyle,
                adapter: harness.provider.adapter,
              ),
              wire: const ResponsesFormat(),
              config: config,
              conversationId: conversationId,
              appVersion: 'test',
            ),
  );
  await controller.recheck();
  expect(controller.canSend, isTrue);
  return controller;
}

void main() {
  for (final dispose in [false, true]) {
    for (final stage in ['freshness', 'prepare']) {
      test(
        '${dispose ? 'dispose' : 'stop'} retains the write lease while $stage HTTP settles',
        () async {
          final entered = Completer<void>();
          final release = Completer<void>();
          final harness = await StackHarness.create();
          addTearDown(harness.dispose);
          harness.server.overrides['GET projects/42'] = (_) async {
            if (!entered.isCompleted) entered.complete();
            await release.future.timeout(_timeout);
            return jsonResponse({
              ...harness.server.workspace.projectRecord,
              'visibility': 'private',
            });
          };
          final controller = await _controller(
            harness,
            stage == 'freshness'
                ? (_) async {
                    await harness.session.api!.record(['projects', '42']);
                    return const AiWriteFreshness(visibilityUnreadable: false);
                  }
                : (_) async =>
                      const AiWriteFreshness(visibilityUnreadable: false),
          );
          addTearDown(() {
            if (!dispose) controller.dispose();
          });
          harness.provider.script.add(
            (_) => toolTurn('setStar', {
              'projectId': 42,
              'starred': true,
              'reason': 'synthetic lease regression',
            }),
          );

          final sending = controller.send('star the synthetic project');
          await entered.future.timeout(_timeout);
          expect(controller.budgetAllocator.activeLeases, 1);

          if (dispose) {
            controller.dispose();
          } else {
            controller.stop();
          }
          await sending;
          expect(controller.budgetAllocator.activeLeases, 1);

          final peerOne = controller.budgetAllocator.acquire(40);
          final peerTwo = controller.budgetAllocator.acquire(40);
          expect(peerOne, isNotNull);
          expect(peerTwo, isNotNull);
          expect(
            controller.budgetAllocator.acquire(40),
            isNull,
            reason: 'the unsettled write still owns one of three run slots',
          );

          release.complete();
          await _until(() => controller.budgetAllocator.activeLeases == 2);
          expect(harness.server.mutations, isEmpty);
          peerOne!.release();
          peerTwo!.release();
          expect(controller.budgetAllocator.activeLeases, 0);
        },
      );
    }
  }
}
