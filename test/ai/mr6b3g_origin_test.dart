import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_context.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_run_registry.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import 'fx_coord_support.dart';
import 'p17_controller_support.dart' show p17ToolNames;

const _group = GraphResourceRef(
  id: 'gid://gitlab/Group/7',
  fullPath: 'team/sub',
);
const _project = Project(
  id: 42,
  name: 'Synthetic',
  path: 'studio/mobile-workspace',
);
const _groupOrigin = AiGroupWorkItemOrigin(
  group: _group,
  iid: 5,
  title: 'Group item',
);
const _projectOrigin = AiProjectWorkItemFromGroupPageOrigin(
  viewGroupId: 7,
  project: _project,
  iid: 5,
  title: 'Project descendant',
);

void _configureGroup(
  StackServer server, {
  bool Function()? descriptionLoaded,
  String description = 'Synthetic group body',
  String Function()? visibility,
  String Function()? path,
}) {
  server.overrides['POST '] = (request) {
    final body = request.data! as Map<String, Object?>;
    final currentPath = path?.call() ?? _group.fullPath;
    expect(body['query'], namespaceWorkItemQuery);
    expect(body['variables'], {'path': currentPath, 'iid': '5'});
    return jsonResponse({
      'data': {
        'namespace': {
          'id': _group.id,
          'fullPath': currentPath,
          'workItem': {
            'id': 'gid://gitlab/WorkItem/91',
            'iid': '5',
            'title': 'Fresh group item',
            'state': 'OPEN',
            'createdAt': '2026-10-01T00:00:00Z',
            'updatedAt': '2026-10-02T00:00:00Z',
            'project': null,
            'namespace': {'id': _group.id, 'fullPath': currentPath},
            'workItemType': {
              'id': 'gid://gitlab/WorkItems::Type/1',
              'name': 'Task',
            },
            if (descriptionLoaded?.call() ?? true) 'description': description,
            'widgets': <Object?>[],
          },
        },
      },
    });
  };
  server.overrides['GET groups/7'] = (_) => jsonResponse({
    'id': 7,
    'full_path': path?.call() ?? _group.fullPath,
    'visibility': visibility?.call() ?? 'private',
  });
}

void main() {
  test('origins use numeric owner and entry keys, never paths or titles', () {
    expect(_groupOrigin.key, 'group-item:7:5');
    expect(_projectOrigin.key, 'group-page:7:project:42:workItem:5');
    expect(
      const AiGroupWorkItemOrigin(
        group: GraphResourceRef(
          id: 'gid://gitlab/Group/7',
          fullPath: 'renamed/sub',
        ),
        iid: 5,
        title: 'Renamed',
      ).key,
      _groupOrigin.key,
    );
    expect(
      const AiProjectWorkItemFromGroupPageOrigin(
        viewGroupId: 7,
        project: Project(id: 42, name: 'Renamed', path: 'renamed/project'),
        iid: 5,
        title: 'Renamed',
      ).key,
      _projectOrigin.key,
    );
    final keys = {
      _groupOrigin.key,
      _projectOrigin.key,
      const AiWorkItemOrigin(
        project: _project,
        kind: AiWorkItemKind.issue,
        iid: 5,
        title: 'Issue',
      ).key,
      const AiGroupWorkItemOrigin(
        group: GraphResourceRef(
          id: 'gid://gitlab/Group/42',
          fullPath: 'same/number',
        ),
        iid: 5,
        title: 'Group 42',
      ).key,
      const AiProjectWorkItemFromGroupPageOrigin(
        viewGroupId: 8,
        project: _project,
        iid: 5,
        title: 'Different view',
      ).key,
    };
    expect(keys, hasLength(5));
    expect(projectForAiChatOrigin(_groupOrigin), isNull);
    expect(projectForAiChatOrigin(_projectOrigin), same(_project));
  });

  test(
    'real group entry runs retain separate conversation grants and state',
    () async {
      var descriptionLoaded = true;
      var clock = DateTime.now();
      var path = _group.fullPath;
      var visibility = 'private';
      final h = await StackHarness.create(
        origin: _groupOrigin,
        level: AiAutonomyLevel.bypass,
        configure: (server) => _configureGroup(
          server,
          descriptionLoaded: () => descriptionLoaded,
          description: '',
          path: () => path,
          visibility: () => visibility,
        ),
      );
      addTearDown(h.dispose);
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
              final controller = AiChatController(
                origin: origin,
                session: session,
                settings: settings,
                runningCount: runningCount,
                writeJournal: h.journal,
                appInForeground: () => true,
                clientMayStart: () => true,
                wireClientFactory: wireClientFactory,
                // Project context's existing cache timestamps use wall time.
                now: origin is AiGroupWorkItemOrigin ? () => clock : null,
              );
              return (
                session: controller,
                capacityChanged: controller.notifyCapacityChanged,
                dispose: controller.dispose,
              );
            },
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
                    adapter: h.provider.adapter,
                  ),
                  wire: const ResponsesFormat(),
                  config: config,
                  conversationId: conversationId,
                  appVersion: 'test',
                ),
      );
      addTearDown(registry.dispose);
      final group = registry.open(_groupOrigin);
      final project = registry.open(_projectOrigin);
      await Future.wait([group.recheck(), project.recheck()]);
      expect(group.canSend, isTrue);
      expect(project.canSend, isTrue);
      expect(group.id, isNot(project.id));
      await group.setAutonomyLevel(AiAutonomyLevel.conversationGrant);
      expect(group.autonomyLevel, AiAutonomyLevel.conversationGrant);
      expect(project.autonomyLevel, AiAutonomyLevel.bypass);

      await group.send('Review only the group item');
      expect(group.items, isNotEmpty);
      expect(project.items, isEmpty);
      expect(group.proposals, isEmpty);
      expect(project.proposals, isEmpty);
      final writeNames = ProductionAiLedger.rows
          .map((row) => row.operationId)
          .toSet();
      expect(
        p17ToolNames(h.provider.bodies.single).intersection(writeNames),
        isEmpty,
      );
      expect(
        h.provider.bodies.single.toString(),
        contains('description_status'),
      );
      expect(h.provider.bodies.single.toString(), contains('loaded'));
      expect(
        h.provider.bodies.single.toString(),
        isNot(contains('unavailable')),
      );
      // Both descriptions project to the same empty text. The availability
      // status must nevertheless replace the context after it expires.
      descriptionLoaded = false;
      clock = clock.add(const Duration(minutes: 6));
      await group.send('Check the refreshed group item');
      expect(h.provider.bodies, hasLength(2));
      expect(h.provider.bodies.last.toString(), contains('unavailable'));
      expect(project.items, isEmpty);
      registry.release(group);
      final reopened = registry.open(
        const AiGroupWorkItemOrigin(
          group: GraphResourceRef(
            id: 'gid://gitlab/Group/7',
            fullPath: 'renamed/sub',
          ),
          iid: 5,
          title: 'Renamed entry',
        ),
      );
      expect(reopened, same(group));
      expect(reopened.autonomyLevel, AiAutonomyLevel.conversationGrant);
      expect(project.autonomyLevel, AiAutonomyLevel.bypass);
      expect(project.items, isEmpty);

      // The retained controller's original path is stale after the rename.
      // Numeric owner lookup must precede the strict read on the next send.
      path = 'renamed/sub';
      visibility = 'public';
      clock = clock.add(const Duration(minutes: 6));
      final beforeRefresh = h.server.adapter.requests.length;
      await reopened.send('Review the renamed group item');
      final refreshed = (reopened as AiChatController).contextForTesting!;
      expect(refreshed.groupScope!.groupId, 7);
      expect(refreshed.groupScope!.iid, 5);
      expect(refreshed.groupScope!.groupFullPath, path);
      expect(refreshed.groupScope!.workItemGid, 'gid://gitlab/WorkItem/91');
      expect(refreshed.groupMetadata!.visibility, 'public');
      expect(refreshed.groupMetadata!.confidential, isNull);
      final refreshRequests = h.server.adapter.requests.skip(beforeRefresh).toList();
      expect(refreshRequests.map((r) => r.method), ['GET', 'POST']);
      expect(refreshRequests.first.uri.path, '/gitlab/api/v4/groups/7');
      expect(refreshRequests.last.uri.path, '/gitlab/api/graphql');
      expect((refreshRequests.last.data! as Map)['query'], namespaceWorkItemQuery);
      expect((refreshRequests.last.data! as Map)['variables'], {'path': path, 'iid': '5'});
      expect(h.provider.bodies, hasLength(3));
      h.server.overrides['GET projects/43'] = (_) => jsonResponse({
        'id': 43,
        'path_with_namespace': 'studio/target',
        'visibility': 'public',
      });
      h.server.overrides['GET projects/43/issues/6'] = (_) => jsonResponse({
        'id': 106,
        'iid': 6,
        'project_id': 43,
        'confidential': false,
      });
      final freshness = await reopened.readWriteFreshnessForTesting(
        port.AiWriteRequest(
          operationId: 'updateIssue',
          executionId: 'rename-refresh',
          scope: AiWriteScope(accountKey: h.account, grants: const []),
          arguments: const {
            'projectId': 43,
            'iid': 6,
            'fields': {'title': 'Updated'},
          },
        ),
      );
      expect(freshness.sourceVisibilityUnreadable, isTrue);
      expect(freshness.polluted, isTrue);
    },
  );

  test('an unchanged group refresh keeps fresh scope and metadata', () async {
    var visibility = 'private';
    var clock = DateTime.now();
    final h = await StackHarness.create(
      origin: _groupOrigin,
      level: AiAutonomyLevel.bypass,
      configure: (server) =>
          _configureGroup(server, visibility: () => visibility),
    );
    addTearDown(h.dispose);
    final controller = AiChatController(
      origin: _groupOrigin,
      session: h.session,
      settings: h.settings,
      runningCount: () => 0,
      writeJournal: h.journal,
      appInForeground: () => true,
      clientMayStart: () => true,
      now: () => clock,
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
                  adapter: h.provider.adapter,
                ),
                wire: const ResponsesFormat(),
                config: config,
                conversationId: conversationId,
                appVersion: 'test',
              ),
    );
    addTearDown(controller.dispose);
    await controller.recheck();
    await controller.send('First look');
    expect(controller.contextForTesting?.groupScope?.iid, 5);
    expect(controller.contextForTesting?.groupMetadata?.visibility, 'private');

    // Visibility is metadata only, so the delivered text stays the same and
    // the controller takes the unchanged branch.
    visibility = 'public';
    clock = clock.add(const Duration(minutes: 6));
    await controller.send('Second look');
    expect(h.provider.bodies, hasLength(2));
    final context = controller.contextForTesting!;
    expect(context.scope, isNull);
    expect(context.groupScope?.iid, 5);
    expect(context.groupMetadata?.visibility, 'public');
  });

  for (final origin in <AiChatOrigin>[_groupOrigin, _projectOrigin]) {
    for (final suppliedScope in [false, true]) {
      test(
        '${origin.key} limits write grant with override=$suppliedScope',
        () async {
          final h = await StackHarness.create(
            origin: origin,
            level: AiAutonomyLevel.bypass,
            configure: _configureGroup,
            writeScope: suppliedScope
                ? (_) => const AiWriteScope(
                    accountKey: coordAccount,
                    grants: [
                      AiScopeGrant(
                        kind: AiScopeKind.project,
                        projectId: 42,
                        projectPath: 'studio/mobile-workspace',
                      ),
                    ],
                  )
                : null,
          );
          addTearDown(h.dispose);
          final before = h.server.adapter.requests.length;
          h.provider.script.add(
            (_) => toolTurn(
              'setStar',
              {
                'projectId': 42,
                'starred': true,
                'reason': 'Attempt a project-wide write',
              },
              calls: [
                (
                  'createNote',
                  {
                    'projectId': 42,
                    'resource': 'issues',
                    'iid': 6,
                    'body': 'Attempt a sibling-item write',
                    'reason': 'Synthetic request',
                  },
                ),
                (
                  'markAllTodosDone',
                  {'reason': 'Attempt an account-wide write'},
                ),
              ],
            ),
          );
          await h.controller
              .send('Review this item')
              .timeout(const Duration(seconds: 20));

          final names = p17ToolNames(h.provider.bodies.first);
          final writeNames = ProductionAiLedger.rows
              .map((row) => row.operationId)
              .toSet();
          if (origin is AiGroupWorkItemOrigin) {
            expect(names.intersection(writeNames), isEmpty);
            expect(h.controller.canAttach, isFalse);
          } else {
            expect(names, contains('createNote'));
            expect(names, isNot(contains('setStar')));
            expect(names, isNot(contains('markAllTodosDone')));
          }
          expect(h.controller.proposals, isEmpty);
          expect(h.server.adapter.requests, hasLength(before));
          final results = h.controller.items.whereType<AiToolRunItem>();
          expect(results, hasLength(3));
          expect(
            results.every(
              (item) =>
                  item.status == AiToolRunStatus.failed ||
                  item.status == AiToolRunStatus.skipped,
            ),
            isTrue,
          );
        },
      );
    }
  }
}
