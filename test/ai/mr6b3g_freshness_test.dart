import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_endpoint.dart';
import 'package:gitlab_mobile/core/ai/ai_transport.dart';
import 'package:gitlab_mobile/core/ai/ai_wire_client.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_read_port.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_scope.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/wire/responses.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_context.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import 'fx_coord_support.dart';
import 'mr6b3g_support.dart';
import 'p17_controller_support.dart' show p17ToolNames;

const _groupWriteOffers = {
  'snoozeTodo',
  'unsnoozeTodo',
  'updateGroupWorkItemState',
  'updateGroupWorkItemStatus',
  'updateGroupWorkItemDates',
  'updateGroupWorkItemHealthStatus',
  'updateGroupWorkItemAssignees',
  'updateGroupWorkItemMilestone',
  'updateGroupWorkItemWeight',
  'createGroupWorkItemActivityComment',
  'createGroupWorkItemActivityReply',
  'deleteGroupWorkItemActivityNote',
  'setGroupWorkItemActivityNoteReaction',
  'setGroupWorkItemNotifications',
  'updateGroupWorkItemContent',
  'editGroupWorkItemActivityNote',
  'updateGroupWorkItemLabels',
};

const _group = GraphResourceRef(
  id: 'gid://gitlab/Group/7',
  fullPath: 'team/sub',
);
const _origin = AiGroupWorkItemOrigin(
  group: _group,
  iid: 5,
  title: 'Group item',
);
const _aliases = {
  'updateGroupWorkItemContent',
  'editGroupWorkItemActivityNote',
  'updateGroupWorkItemLabels',
};

// Synthetic rows exercise future freshness without offering any write tool,
// changing production gates, or depending on a groupId/name heuristic.
final class _Rows implements AiCapabilityLedger {
  const _Rows();

  @override
  AiCapability? find(String operationId) =>
      _aliases.contains(operationId) || operationId == 'syntheticGroupState'
      ? AiCapability(
          operationId: operationId,
          baseTier: AiWriteTier.t2,
          scopeClass: AiScopeClass.groupWorkItem,
          modelVisible: false,
        )
      : productionAiLedger.find(operationId);

  @override
  List<AiCapability> get modelVisible => const [];
}

void _configureGroup(
  StackServer server, {
  String workItemGid = 'gid://gitlab/WorkItem/91',
  GraphResourceRef group = _group,
  int iid = 5,
}) {
  server.overrides['POST '] = (request) {
    expect(request.uri.path, '/gitlab/api/graphql');
    final body = request.data! as Map<String, Object?>;
    expect(body['query'], namespaceWorkItemQuery);
    expect(body['variables'], {'path': group.fullPath, 'iid': '$iid'});
    return jsonResponse({
      'data': {
        'namespace': {
          'id': group.id,
          'fullPath': group.fullPath,
          'workItem': {
            'id': workItemGid,
            'iid': '$iid',
            'title': 'Group item',
            'state': 'OPEN',
            'createdAt': '2026-10-01T00:00:00Z',
            'updatedAt': '2026-10-02T00:00:00Z',
            'project': null,
            'namespace': {'id': group.id, 'fullPath': group.fullPath},
            'workItemType': {
              'id': 'gid://gitlab/WorkItems::Type/1',
              'name': 'Task',
            },
            'description': 'Synthetic group body',
            'widgets': <Object?>[],
          },
        },
      },
    });
  };
  server.overrides['GET groups/7'] = (_) => jsonResponse({
    'id': 7,
    'full_path': _group.fullPath,
    'visibility': 'private',
  });
}

port.AiWriteRequest _request(
  StackHarness h, {
  String operation = 'updateGroupWorkItemContent',
  Map<String, Object?>? arguments,
  AiWriteScope? scope,
}) => port.AiWriteRequest(
  operationId: operation,
  executionId: 'synthetic-freshness',
  scope:
      scope ??
      AiWriteScope(
        accountKey: h.account,
        grants: const [
          AiScopeGrant(
            kind: AiScopeKind.groupWorkItem,
            groupId: 7,
            groupFullPath: 'team/sub',
            iid: 5,
          ),
        ],
      ),
  arguments: arguments ?? const {'groupId': 7, 'iid': 5, 'title': 'Updated'},
);

List<RequestOptions> _since(StackHarness h, int count) =>
    h.server.adapter.requests.skip(count).toList();

void _assertGroupFreshRead(List<RequestOptions> requests) {
  expect(requests, hasLength(1));
  final request = requests.single;
  expect(request.method, 'GET');
  expect(request.uri.path, '/gitlab/api/v4/groups/7');
  expect(request.uri.queryParameters, {'with_projects': 'false'});
  expect(request.followRedirects, isFalse);
}

AiChatController _controller(
  StackHarness h, {
  AiChatOrigin origin = _origin,
  AiCapabilityLedger capabilityLedger = productionAiLedger,
  port.AiGitLabWritePort Function()? writePortFactory,
}) => AiChatController(
  origin: origin,
  session: h.session,
  settings: h.settings,
  runningCount: () => 0,
  writeJournal: h.journal,
  appInForeground: () => true,
  clientMayStart: () => true,
  capabilityLedger: capabilityLedger,
  writePortFactory: writePortFactory,
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

void main() {
  test(
    'injected ledger drives coordinator offers and default freshness',
    () async {
      final h = await StackHarness.create(configure: _configureGroup);
      addTearDown(h.dispose);
      final controller = _controller(
        h,
        origin: AiFileOrigin(
          project: h.server.workspace.project,
          path: 'README.md',
          sha: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        ),
        capabilityLedger: const _Rows(),
      );
      addTearDown(controller.dispose);
      await controller.recheck();
      await controller.send('Review this file');
      expect(
        p17ToolNames(h.provider.bodies.last).intersection(
          ProductionAiLedger.rows.map((row) => row.operationId).toSet(),
        ),
        isEmpty,
      );
      final before = h.server.adapter.requests.length;
      final fresh = await controller.readWriteFreshnessForTesting(
        _request(h, operation: 'syntheticGroupState'),
      );
      _assertGroupFreshRead(_since(h, before));
      expect(fresh.sourceVisibilityUnreadable, isFalse);
      expect(fresh.targetVisibility, 'private');
    },
  );

  test(
    'controller source unknown survives proposal, opening and dispatch',
    () async {
      aiGroupWorkItemWritesEnabledForTesting = true;
      addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
      final h = await StackHarness.create(
        origin: _origin,
        level: AiAutonomyLevel.bypass,
        configure: _configureGroup,
      );
      addTearDown(h.dispose);
      final api = h.session.api!;
      final graph = G0eGraphPort(api)
        ..identityForEpoch = (epoch) => g0eIdentity(
          api,
          generation: h.session.generation,
          readEpoch: epoch,
        );
      final controller = _controller(
        h,
        capabilityLedger: const G0eLedger(),
        writePortFactory: () => graph,
      );
      addTearDown(controller.dispose);
      await controller.recheck();
      await controller.setAutonomyLevel(AiAutonomyLevel.conversationGrant);
      final before = h.server.adapter.requests.length;
      for (var send = 0; send < 2; send++) {
        h.provider.script.add(
          (_) => toolTurn('updateGroupWorkItemContent', {
            'groupId': 7,
            'iid': 5,
            'description': 'Safe edit $send',
            'reason': 'Requested.',
          }),
        );
        final sending = controller.send('Update this group item');
        await waitFor(
          () =>
              controller.phase == AiChatPhase.awaitingApproval ||
              controller.phase == AiChatPhase.idle,
        );
        expect(controller.phase, AiChatPhase.awaitingApproval);
        final proposal = controller.proposals.single;
        expect(proposal.tier.decision, AiGateDecision.requireApproval);
        expect(
          proposal.tier.reasons,
          contains(AiFixedConfirmReason.confidentialOrVisibilityMix),
        );
        // A later, complete target opening may resolve only the target.
        graph.targetConfidential = false;
        final outcome = await controller.approveWrite(proposal);
        await sending;
        expect(
          outcome.state,
          AiJournalState.succeeded,
          reason: outcome.reasonCode,
        );
      }
      expect(graph.prepares, 4);
      expect(graph.mutations, 2);
      expect(
        _since(
          h,
          before,
        ).where((request) => request.uri.path.endsWith('/groups/7')),
        hasLength(4),
      );
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
      for (var round = 0; round < 2; round++) {
        for (final groupTarget in [true, false]) {
          final fresh = await controller.readWriteFreshnessForTesting(
            groupTarget
                ? _request(h)
                : _request(
                    h,
                    operation: 'updateIssue',
                    arguments: const {
                      'projectId': 43,
                      'iid': 6,
                      'fields': {'title': 'Safe'},
                    },
                  ),
            sourceGroupMetadata: const AiGroupContextMetadata(
              visibility: 'public',
              confidential: false,
            ),
          );
          expect(fresh.sourceVisibilityUnreadable, isTrue);
          expect(fresh.visibilityUnreadable, isTrue);
          expect(fresh.targetVisibility, groupTarget ? 'private' : 'public');
          if (!groupTarget) expect(fresh.polluted, isTrue);
        }
      }
    },
  );

  for (final groupTarget in [true, false]) {
    test(
      'freshness refuses a replaced account API generation, group=$groupTarget',
      () async {
        final h = await StackHarness.create(
          origin: _origin,
          configure: _configureGroup,
        );
        addTearDown(h.dispose);
        final api = h.session.api!;
        final generation = h.session.generation;
        await h.session.select(h.session.active!);
        expect(h.session.api, isNot(same(api)));
        expect(h.session.generation, isNot(generation));
        expect(api.isClosed, isTrue);
        final before = h.server.adapter.requests.length;
        await expectLater(
          h.controller.readWriteFreshnessForTesting(
            groupTarget
                ? _request(h)
                : _request(
                    h,
                    operation: 'updateIssue',
                    arguments: const {
                      'projectId': 43,
                      'iid': 6,
                      'fields': {'title': 'Safe'},
                    },
                  ),
            capabilityLedger: const _Rows(),
          ),
          throwsA(isA<AiJournalException>()),
        );
        expect(_since(h, before), isEmpty);
      },
    );

    test(
      'freshness refuses a superseded controller epoch, group=$groupTarget',
      () async {
        final h = await StackHarness.create(
          origin: _origin,
          configure: _configureGroup,
        );
        addTearDown(h.dispose);
        final entered = Completer<void>();
        final release = Completer<void>();
        h.server.overrides[groupTarget
            ? 'GET groups/7'
            : 'GET projects/43'] = (_) async {
          entered.complete();
          await release.future;
          return jsonResponse(
            groupTarget
                ? {'id': 7, 'full_path': 'team/sub', 'visibility': 'public'}
                : {
                    'id': 43,
                    'path_with_namespace': 'team/target',
                    'visibility': 'public',
                  },
          );
        };
        final pending = h.controller.readWriteFreshnessForTesting(
          groupTarget
              ? _request(h)
              : _request(
                  h,
                  operation: 'updateIssue',
                  arguments: const {
                    'projectId': 43,
                    'iid': 6,
                    'fields': {'title': 'Safe'},
                  },
                ),
          capabilityLedger: const _Rows(),
        );
        final rejected = expectLater(
          pending,
          throwsA(isA<AiJournalException>()),
        );
        await entered.future;
        await h.controller.recheck();
        release.complete();
        await rejected;
      },
    );
  }

  test(
    'ledger group row is routed before the no-project return every round',
    () async {
      final h = await StackHarness.create(
        origin: _origin,
        configure: _configureGroup,
      );
      addTearDown(h.dispose);
      final before = h.server.adapter.requests.length;
      for (var round = 0; round < 2; round++) {
        final fresh = await h.controller.readWriteFreshnessForTesting(
          _request(h, operation: 'syntheticGroupState'),
          capabilityLedger: const _Rows(),
        );
        expect(fresh.visibilityUnreadable, isTrue);
        expect(fresh.currentFields, isEmpty);
        expect(fresh.updatedAt, isNull);
        _assertGroupFreshRead(_since(h, before + round));
      }
    },
  );

  for (final response in [
    {'id': 8, 'full_path': 'team/sub', 'visibility': 'private'},
    {'id': '7', 'full_path': 'team/sub', 'visibility': 'private'},
    {'id': 7, 'full_path': 'renamed/sub', 'visibility': 'private'},
    {'id': 7, 'visibility': 'private'},
  ]) {
    test('group freshness refuses identity mismatch $response', () async {
      final h = await StackHarness.create(
        origin: _origin,
        configure: _configureGroup,
      );
      addTearDown(h.dispose);
      h.server.overrides['GET groups/7'] = (_) => jsonResponse(response);
      final before = h.server.adapter.requests.length;
      await expectLater(
        h.controller.readWriteFreshnessForTesting(
          _request(h),
          capabilityLedger: const _Rows(),
        ),
        throwsA(
          isA<AiJournalException>().having(
            (error) => error.reason,
            'reason',
            'targetChanged',
          ),
        ),
      );
      _assertGroupFreshRead(_since(h, before));
    });
  }

  test(
    'ungranted, mixed, foreign account and instance coordinates refuse before HTTP',
    () async {
      final h = await StackHarness.create(
        origin: _origin,
        configure: _configureGroup,
      );
      addTearDown(h.dispose);
      final normal = _request(h);
      for (final request in [
        _request(h, arguments: const {'groupId': 8, 'iid': 5}),
        _request(h, arguments: const {'groupId': 7, 'iid': 6}),
        _request(h, arguments: const {'groupId': 7, 'iid': 5, 'projectId': 7}),
        _request(h, arguments: const {'groupId': '7', 'iid': 5}),
        _request(h, arguments: const {'groupId': 7, 'iid': 0}),
        _request(
          h,
          scope: AiWriteScope(
            accountKey: '${h.account}0',
            grants: normal.scope.grants,
          ),
        ),
        _request(
          h,
          scope: AiWriteScope(
            accountKey: h.account,
            instance: GitLabInstance.parse('https://foreign.example/gitlab'),
            grants: normal.scope.grants,
          ),
        ),
        _request(
          h,
          scope: AiWriteScope(accountKey: h.account, grants: const []),
        ),
      ]) {
        final before = h.server.adapter.requests.length;
        await expectLater(
          h.controller.readWriteFreshnessForTesting(
            request,
            capabilityLedger: const _Rows(),
          ),
          throwsA(isA<AiJournalException>()),
        );
        expect(_since(h, before), isEmpty);
      }
    },
  );

  test(
    'accountTodo and unknown operations never infer group freshness from arguments',
    () async {
      final h = await StackHarness.create(
        origin: _origin,
        configure: _configureGroup,
      );
      addTearDown(h.dispose);
      for (final operation in [
        'snoozeTodo',
        'unsnoozeTodo',
        'markTodoDone',
        'unknownGroupOperation',
      ]) {
        final before = h.server.adapter.requests.length;
        await h.controller.readWriteFreshnessForTesting(
          _request(h, operation: operation),
          capabilityLedger: const _Rows(),
        );
        expect(_since(h, before), isEmpty);
      }
    },
  );

  test(
    'unknown group visibility retains provenance and confirmation without extra reads',
    () async {
      final h = await StackHarness.create(
        origin: _origin,
        configure: _configureGroup,
      );
      addTearDown(h.dispose);
      final api = h.session.api!;
      final readPort = GitLabAiGroupReadPort(
        api,
        instance: api.instance,
        actorUserId: h.session.active!.user.id,
        generation: h.session.generation,
        isCurrent: () => true,
      );
      // The actor is the session's real synthetic /user response. No identity is
      // fabricated from a grant or by the test calling the evidence factory.
      await readPort.workItem(h.controller.contextForTesting!.groupScope!);
      for (final visibility in [null, 'unexpected', 1]) {
        h.server.overrides['GET groups/7'] = (_) => jsonResponse({
          'id': 7,
          'full_path': _group.fullPath,
          'visibility': visibility,
        });
        final before = h.server.adapter.requests.length;
        final fresh = await h.controller.readWriteFreshnessForTesting(
          _request(h),
          capabilityLedger: const _Rows(),
          groupIdentity: () => readPort.verifiedIdentity,
        );
        _assertGroupFreshRead(_since(h, before));
        expect(fresh.visibilityUnreadable, isTrue);
        expect(fresh.targetVisibility, isNull);
        expect(fresh.sourceVisibilityUnreadable, isTrue);
        expect(fresh.provenance.keys, {'title', 'description'});
        final outcome = text.prepareWriteText(
          textClass: text.AiTextClass.quickActionMarkdown,
          field: fresh.provenance['description'],
          modelText: 'Synthetic safe description',
          placeholders: text.UploadPlaceholderTable(instance: api.instance),
          knownSecrets: const {},
          aiAttribution: false,
          visibility: text.AiVisibilityContext(
            polluted: fresh.polluted,
            visibilityUnreadable: fresh.visibilityUnreadable,
          ),
        );
        expect(outcome.policyBlocked, isFalse);
        expect(
          outcome.levelConfirmReasons,
          contains(text.AiLevelConfirmReason.visibilityPollution),
        );
      }
    },
  );

  test(
    'all group text aliases use exact field provenance from the strict read',
    () async {
      final h = await StackHarness.create(
        origin: _origin,
        configure: _configureGroup,
      );
      addTearDown(h.dispose);
      final api = h.session.api!;
      final readPort = GitLabAiGroupReadPort(
        api,
        instance: api.instance,
        actorUserId: h.session.active!.user.id,
        generation: h.session.generation,
        isCurrent: () => true,
      );
      await readPort.workItem(h.controller.contextForTesting!.groupScope!);
      for (final (operation, fields) in [
        ('updateGroupWorkItemContent', {'title', 'description'}),
        ('editGroupWorkItemActivityNote', {'body'}),
        ('updateGroupWorkItemLabels', {'labels'}),
      ]) {
        final before = h.server.adapter.requests.length;
        final fresh = await h.controller.readWriteFreshnessForTesting(
          _request(
            h,
            operation: operation,
            arguments: const {'groupId': 7, 'iid': 5, 'noteId': 12},
          ),
          capabilityLedger: const _Rows(),
          groupIdentity: () => readPort.verifiedIdentity,
        );
        _assertGroupFreshRead(_since(h, before));
        expect(fresh.currentFields, isEmpty);
        expect(fresh.provenance.keys, fields);
        for (final field in fresh.provenance.values) {
          expect(field.accountKey, h.account);
          expect(field.groupId, 7);
          expect(field.groupFullPath, 'team/sub');
          expect(field.projectId, isNull);
          expect(field.resourceKey.canonical, contains('group:7, workItem, 5'));
        }
        if (fields.contains('body')) {
          expect(
            fresh.provenance['body']!.resourceKey.canonical,
            endsWith('/note:12'),
          );
          expect(
            fresh.provenance['body']!.fieldName,
            text.AiWritableField.workItemNote,
          );
        }
        if (fields.contains('description')) {
          expect(
            fresh.provenance['description']!.fieldName,
            text.AiWritableField.workItemDescription,
          );
          expect(fresh.provenance['title']!.fieldName, 'title');
          expect(fresh.provenance['title']!.completeValue, isFalse);
        }
      }
      final absent = await h.controller.readWriteFreshnessForTesting(
        _request(h),
        capabilityLedger: const _Rows(),
      );
      expect(absent.provenance, isEmpty);
    },
  );

  test(
    'group provenance rechecks the port epoch after awaited freshness',
    () async {
      final h = await StackHarness.create(
        origin: _origin,
        configure: _configureGroup,
      );
      addTearDown(h.dispose);
      final api = h.session.api!;
      var current = true;
      final readPort = GitLabAiGroupReadPort(
        api,
        instance: api.instance,
        actorUserId: h.session.active!.user.id,
        generation: h.session.generation,
        isCurrent: () => current,
      );
      await readPort.workItem(h.controller.contextForTesting!.groupScope!);
      expect(readPort.verifiedIdentity, isNotNull);
      h.server.overrides['GET groups/7'] = (_) {
        current = false;
        return jsonResponse({
          'id': 7,
          'full_path': 'team/sub',
          'visibility': 'private',
        });
      };
      final fresh = await h.controller.readWriteFreshnessForTesting(
        _request(h),
        capabilityLedger: const _Rows(),
        groupIdentity: () => readPort.verifiedIdentity,
      );
      expect(fresh.provenance, isEmpty);
      expect(fresh.visibilityUnreadable, isTrue);
    },
  );

  for (final (name, group, groupId, iid) in [
    (
      'groupId',
      const GraphResourceRef(id: 'gid://gitlab/Group/8', fullPath: 'team/sub'),
      8,
      5,
    ),
    (
      'path',
      const GraphResourceRef(id: 'gid://gitlab/Group/7', fullPath: 'other/sub'),
      7,
      5,
    ),
    ('iid', _group, 7, 6),
  ]) {
    test(
      'group provenance refuses verified identity with a foreign $name',
      () async {
        final h = await StackHarness.create(
          origin: _origin,
          configure: _configureGroup,
        );
        addTearDown(h.dispose);
        final api = h.session.api!;
        final readPort = GitLabAiGroupReadPort(
          api,
          instance: api.instance,
          actorUserId: h.session.active!.user.id,
          generation: h.session.generation,
          isCurrent: () => true,
        );
        // Obtain real strict-reader evidence for a different item, rather than
        // manufacturing a VerifiedGroupWorkItemIdentity in the test.
        _configureGroup(h.server, group: group, iid: iid);
        await readPort.workItem(
          AiGroupResourceScope(
            accountKey: h.account,
            instanceKey: api.instance.key,
            groupId: groupId,
            groupFullPath: group.fullPath,
            iid: iid,
            workItemGid: 'gid://gitlab/WorkItem/91',
          ),
        );
        expect(readPort.verifiedIdentity, isNotNull);
        _configureGroup(h.server);
        final before = h.server.adapter.requests.length;
        final fresh = await h.controller.readWriteFreshnessForTesting(
          _request(h),
          capabilityLedger: const _Rows(),
          groupIdentity: () => readPort.verifiedIdentity,
        );
        _assertGroupFreshRead(_since(h, before));
        expect(fresh.provenance, isEmpty);
        expect(fresh.visibilityUnreadable, isTrue);
      },
    );
  }

  test(
    'group provenance refuses verified identity from another API owner',
    () async {
      final h = await StackHarness.create(
        origin: _origin,
        configure: _configureGroup,
      );
      addTearDown(h.dispose);
      final other = await StackHarness.create(
        origin: _origin,
        configure: _configureGroup,
      );
      addTearDown(other.dispose);
      final api = other.session.api!;
      final readPort = GitLabAiGroupReadPort(
        api,
        instance: api.instance,
        actorUserId: other.session.active!.user.id,
        // Generations are process-wide (C2d2), so pin h's generation to keep
        // the case "same account and generation, different API owner".
        generation: h.session.generation,
        isCurrent: () => true,
      );
      await readPort.workItem(other.controller.contextForTesting!.groupScope!);
      expect(readPort.verifiedIdentity, isNotNull);
      expect(readPort.verifiedIdentity!.accountKey, h.account);
      expect(readPort.verifiedIdentity!.generation, h.session.generation);
      final before = h.server.adapter.requests.length;
      final fresh = await h.controller.readWriteFreshnessForTesting(
        _request(h),
        capabilityLedger: const _Rows(),
        groupIdentity: () => readPort.verifiedIdentity,
      );
      _assertGroupFreshRead(_since(h, before));
      expect(fresh.provenance, isEmpty);
      expect(fresh.visibilityUnreadable, isTrue);
    },
  );

  for (final source in ['private', 'internal', 'public', null]) {
    test(
      'synthetic $source group source rank contaminates only broader project targets',
      () async {
        final h = await StackHarness.create(
          origin: _origin,
          configure: _configureGroup,
        );
        addTearDown(h.dispose);
        for (final (target, rank) in [
          ('private', 0),
          ('internal', 1),
          ('public', 2),
        ]) {
          h.server.overrides['GET projects/43'] = (_) => jsonResponse({
            'id': 43,
            'path_with_namespace': 'studio/target',
            'visibility': target,
          });
          h.server.overrides['GET projects/43/issues/6'] = (_) => jsonResponse({
            'id': 106,
            'iid': 6,
            'project_id': 43,
            'confidential': false,
          });
          final sourceRank = [
            'private',
            'internal',
            'public',
          ].indexOf(source ?? 'unknown');
          final fresh = await h.controller.readWriteFreshnessForTesting(
            _request(
              h,
              operation: 'updateIssue',
              arguments: const {
                'projectId': 43,
                'iid': 6,
                'fields': {'title': 'Updated'},
              },
            ),
            sourceGroupMetadata: AiGroupContextMetadata(
              visibility: source,
              confidential: false,
            ),
          );
          expect(
            fresh.visibilityUnreadable,
            source == null,
            reason: '$source -> $target',
          );
          expect(fresh.sourceVisibilityUnreadable, source == null);
          expect(fresh.targetVisibility, target);
          expect(
            fresh.polluted,
            sourceRank >= 0 && rank > sourceRank,
            reason: '$source -> $target',
          );
        }
      },
    );
  }

  test(
    'unknown confidentiality is not a false proof and confidential group source pollutes a project',
    () async {
      final h = await StackHarness.create(
        origin: _origin,
        configure: _configureGroup,
      );
      addTearDown(h.dispose);
      h.server.overrides['GET projects/43'] = (_) => jsonResponse({
        'id': 43,
        'path_with_namespace': 'studio/target',
        'visibility': 'private',
      });
      h.server.overrides['GET projects/43/issues/6'] = (_) => jsonResponse({
        'id': 106,
        'iid': 6,
        'project_id': 43,
        'confidential': false,
      });
      final request = _request(
        h,
        operation: 'updateIssue',
        arguments: const {
          'projectId': 43,
          'iid': 6,
          'fields': {'title': 'Updated'},
        },
      );
      for (final confidential in [null, false, true]) {
        final fresh = await h.controller.readWriteFreshnessForTesting(
          request,
          sourceGroupMetadata: AiGroupContextMetadata(
            visibility: 'private',
            confidential: confidential,
          ),
        );
        expect(fresh.visibilityUnreadable, confidential == null);
        expect(fresh.polluted, confidential == true);
      }
    },
  );

  for (final origin in <AiChatOrigin>[
    _origin,
    const AiProjectWorkItemFromGroupPageOrigin(
      viewGroupId: 7,
      project: Project(
        id: 42,
        name: 'Synthetic',
        path: 'studio/mobile-workspace',
      ),
      iid: 5,
      title: 'Project descendant',
    ),
  ]) {
    test(
      '${origin.key} injects its read catalogue and only its item write scope',
      () async {
        final h = await StackHarness.create(
          origin: origin,
          level: AiAutonomyLevel.bypass,
          configure: _configureGroup,
          writeScope: (server) => AiWriteScope(
            accountKey: server.workspace.account.key,
            grants: const [
              AiScopeGrant(kind: AiScopeKind.project, projectId: 42),
              AiScopeGrant(
                kind: AiScopeKind.groupWorkItem,
                groupId: 7,
                groupFullPath: 'team/sub',
                iid: 5,
              ),
            ],
          ),
        );
        addTearDown(h.dispose);
        await h.controller.send('Review this item');
        final names = p17ToolNames(h.provider.bodies.last);
        final writes = ProductionAiLedger.rows
            .map((row) => row.operationId)
            .toSet();
        if (origin is AiGroupWorkItemOrigin) {
          expect(names.intersection(writes), _groupWriteOffers);
        } else {
          expect(names, contains('createNote'));
          expect(names, isNot(contains('setStar')));
          expect(names, isNot(contains('createIssue')));
          expect(names, isNot(contains('markAllTodosDone')));
        }
        expect(
          names.contains('get_group_work_item'),
          origin is AiGroupWorkItemOrigin,
        );
        expect(
          names.contains('get_issue'),
          origin is AiProjectWorkItemFromGroupPageOrigin,
        );
        expect(h.controller.proposals, isEmpty);
        expect(h.controller.attachments, isEmpty);
        if (origin is AiGroupWorkItemOrigin) {
          h.provider.script.add(
            (_) => toolTurn('get_group_work_item', {'groupId': 7, 'iid': 5}),
          );
          await h.controller.send('Read this group item');
          expect(
            h.controller.items.whereType<AiToolRunItem>().last.status,
            AiToolRunStatus.completed,
          );
          expect(
            h.controller.items.whereType<AiToolRunItem>().last.name,
            'get_group_work_item',
          );
        }
        final before = h.server.adapter.requests.length;
        h.provider.script.add(
          (_) => toolTurn('createNote', {
            'projectId': 42,
            'resource': 'issues',
            'iid': 6,
            'body': 'Forbidden',
            'reason': 'Requested',
          }),
        );
        await h.controller.send('Attempt an ungranted write');
        expect(_since(h, before), isEmpty);
        expect(h.controller.proposals, isEmpty);
      },
    );
  }

  for (final changedIdentity in [false, true]) {
    test(
      'same-text group refresh ${changedIdentity ? 'restarts for changed identity' : 'retains context for unchanged identity'}',
      () async {
        final h = await StackHarness.create(
          origin: _origin,
          configure: _configureGroup,
        );
        addTearDown(h.dispose);
        var clock = DateTime.now();
        final controller = AiChatController(
          origin: _origin,
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
        await controller.send('Review group');
        final previous = controller.contextForTesting!;
        final workItemGid = changedIdentity
            ? 'gid://gitlab/WorkItem/92'
            : previous.groupScope!.workItemGid;
        _configureGroup(h.server, workItemGid: workItemGid);
        h.server.overrides['GET groups/7'] = (_) => jsonResponse({
          'id': 7,
          'full_path': _group.fullPath,
          'visibility': 'public',
        });
        clock = clock.add(const Duration(minutes: 6));
        await controller.send('Review refreshed group');
        final refreshed = controller.contextForTesting!;
        expect(
          refreshed.built.blocks.map(
            (block) => (block.source, block.plainData.plainText),
          ),
          previous.built.blocks.map(
            (block) => (block.source, block.plainData.plainText),
          ),
        );
        expect(
          refreshed.built,
          changedIdentity ? isNot(same(previous.built)) : same(previous.built),
        );
        expect(
          controller.items.whereType<AiNoticeItem>().where(
            (item) => item.kind == AiNoticeKind.segmentSummary,
          ),
          hasLength(changedIdentity ? 1 : 0),
        );
        expect(refreshed.groupMetadata!.visibility, 'public');
        expect(refreshed.groupMetadata!.confidential, isNull);
        expect(refreshed.groupScope, isNot(same(previous.groupScope)));
        expect(refreshed.groupScope!.groupId, 7);
        expect(refreshed.groupScope!.groupFullPath, _group.fullPath);
        expect(refreshed.groupScope!.iid, 5);
        expect(refreshed.groupScope!.workItemGid, workItemGid);
        expect(refreshed.fetchedAt, clock);
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
        final fresh = await controller.readWriteFreshnessForTesting(
          _request(
            h,
            operation: 'updateIssue',
            arguments: const {
              'projectId': 43,
              'iid': 6,
              'fields': {'title': 'Updated'},
            },
          ),
          sourceGroupMetadata: const AiGroupContextMetadata(
            visibility: 'public',
            confidential: false,
          ),
        );
        expect(
          fresh.polluted,
          isTrue,
          reason: 'Private context was already sent before refresh',
        );
        expect(
          fresh.visibilityUnreadable,
          isTrue,
          reason: 'Previously sent unknown confidentiality stays unknown',
        );
      },
    );
  }
}
