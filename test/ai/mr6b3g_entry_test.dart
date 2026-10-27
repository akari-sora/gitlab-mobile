import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_page.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';
import 'package:gitlab_mobile/features/ai/ai_scope.dart';

import 'fx_coord_support.dart';

const _invalidGids = [
  'gid://gitlab/Project/7',
  'gid://gitlab/Namespaces::ProjectNamespace/7',
  'gid://gitlab/WorkItem/7',
  'gid://gitlab/Group/07',
  'gid://gitlab/Group/0',
  'gid://gitlab/Group/-7',
  'gid://gitlab/Group/9223372036854775808',
  'gid://gitlab/Group/7/extra',
];

void main() {
  test('group origin factory validates the exact Group GID and iid', () {
    for (final gid in _invalidGids) {
      final group = GraphResourceRef(id: gid, fullPath: 'team/sub');
      expect(
        AiGroupWorkItemOrigin.tryCreate(group: group, iid: 5, title: 'Item'),
        isNull,
        reason: gid,
      );
      expect(
        () => AiGroupWorkItemOrigin(group: group, iid: 5, title: 'Item').key,
        throwsA(
          isA<ApiFailure>().having(
            (failure) => failure.kind,
            'kind',
            FailureKind.validation,
          ),
        ),
      );
    }
    const group = GraphResourceRef(
      id: 'gid://gitlab/Group/7',
      fullPath: 'team/sub',
    );
    for (final iid in [0, -1]) {
      expect(
        AiGroupWorkItemOrigin.tryCreate(group: group, iid: iid, title: 'Item'),
        isNull,
      );
    }
    expect(
      AiGroupWorkItemOrigin.tryCreate(group: group, iid: 5, title: 'Item')!.key,
      'group-item:7:5',
    );
  });

  testWidgets(
    'openAiChat refuses unverified group origins without creating sessions',
    (tester) async {
      final h = (await tester.runAsync(StackHarness.create))!;
      addTearDown(h.dispose);
      var creations = 0;
      final registry = AccountAiRunRegistry(
        session: h.session,
        settings: h.settings,
        sessionFactory:
            ({
              required origin,
              required session,
              required settings,
              required runningCount,
              wireClientFactory,
            }) {
              creations++;
              throw StateError('Invalid origins must never create sessions');
            },
      );
      addTearDown(registry.dispose);
      late BuildContext entryContext;
      await tester.pumpWidget(
        AiScope(
          controllers: AiControllers(
            settings: h.settings,
            history: AiHistoryCoordinator.instance,
          ),
          accountKey: h.account,
          child: AiRunRegistryScope(
            registry: registry,
            child: MaterialApp(
              home: Builder(
                builder: (context) {
                  entryContext = context;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );
      for (final gid in _invalidGids) {
        final origin = AiGroupWorkItemOrigin(
          group: GraphResourceRef(id: gid, fullPath: 'team/sub'),
          iid: 5,
          title: 'Item',
        );
        expect(() => registry.open(origin), throwsStateError);
        expect(await openAiChat(entryContext, origin), isFalse, reason: gid);
      }
      expect(creations, 0);
      expect(registry.runningCount, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
