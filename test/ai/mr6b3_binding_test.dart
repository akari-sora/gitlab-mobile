import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/intent_lexicon.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_matrix_support.dart';
import 'mr6b3_support.dart';

// docs/plans/ai-writes-plan-v6.md §15 row 16: 「複合目標只綁一個元件時改為
// 確認；多專案範圍下不帶專案路徑的 #iid 改為確認；同 iid 不同專案、同路徑
// 不同 ref；群組 Work Item 只能以 URL 或 UI 綁定；否定句、引用、條件句、
// 方向相反（標星對取消標星、訂閱對取消訂閱、通知開對關、延後對取消延後）
// 只產生確認卡；介面語言與裝置語言中任一語系的否定詞都使其改為確認；
// 從紀錄恢復的訊息不建立 T1 授權」。
// §15 row 10: 「suggestion、todo、GID 指向其他專案時被拒……從群組 Work
// Item 頁開啟的專案議題得到專案 key、只授權該議題與其子資源」。
// §15 row 24: 「foreign Group GID 被拒……project 為 null 的群組 Work Item
// 待辦可延後……foreign account 或 foreign Group 的 target 與不支援的 target
// 型別被拒」。This packet covers the MR6b-3 project/group-denial subset.
// Current production deliberately refuses projectless group todos (D16 in
// docs/plans/mr6b3-decisions.md; breakdown §7 item 8 and appendix B).
// NOT_RUN row 10: suggestion/batch and unrelated REST whitelist cases, and a
// project issue opened through a group Work Item page.
// NOT_RUN row 16: intent words only in a code block or pasted long text,
// same path with different refs, and group Work Item URL/UI authorization.
// NOT_RUN row 24: group Work Item todo snooze through AI authorization (MR6b-3g),
// successful projectless group proposals, groupWorkItem scope restrictions,
// group release names, rename/board/group-page aliases, truncated target paging,
// foreign-account and unsupported target types beyond the cases below.

typedef _Direction = ({
  String operation,
  AiIntentDirection intent,
  Map<String, Object?> arguments,
});

const _directions = <_Direction>[
  (
    operation: 'setWorkItemActivityNoteReaction',
    intent: AiIntentDirection.workItemReactionAdd,
    arguments: {'add': true},
  ),
  (
    operation: 'setWorkItemActivityNoteReaction',
    intent: AiIntentDirection.workItemReactionRemove,
    arguments: {'add': false},
  ),
  (
    operation: 'setWorkItemNotifications',
    intent: AiIntentDirection.workItemNotificationsOn,
    arguments: {'enabled': true},
  ),
  (
    operation: 'setWorkItemNotifications',
    intent: AiIntentDirection.workItemNotificationsOff,
    arguments: {'enabled': false},
  ),
  (
    operation: 'snoozeTodo',
    intent: AiIntentDirection.snoozeTodo,
    arguments: {},
  ),
  (
    operation: 'unsnoozeTodo',
    intent: AiIntentDirection.unsnoozeTodo,
    arguments: {},
  ),
];

const _twoProjects = AiWriteScope(
  accountKey: mr6b3Account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 9,
      projectPath: 'team/example-9',
    ),
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 10,
      projectPath: 'team/example-10',
    ),
  ],
);

void main() {
  group('§15 row 16 graph direction binding and intent', () {
    for (final direction in _directions) {
      test(
        '${direction.intent.name} guards produce a T1 card, never auto-send',
        () async {
          final h = await _harness();
          h.policy.level = AiAutonomyLevel.lowRiskAuto;
          final arguments = {
            ...mr6b3ApiArguments(direction.operation),
            ...direction.arguments,
          };
          final prepared = await h.server.writePort.prepare(
            _request(direction.operation, arguments: arguments),
          );
          final en = languageForTag('en')!;
          final phrase = AiIntentLexicon.phrases(en, direction.intent).first;
          final opposite = AiIntentLexicon.phrases(
            en,
            oppositeIntent(direction.intent)!,
          ).first;
          final positive = _bind(
            '$phrase team/example-9#3 note:401.',
            prepared.bindingTargets,
            operation: direction.operation,
            arguments: arguments,
          );
          expect(positive.allBound, isTrue);
          expect(positive.intentAuthorizesLowRisk, isTrue);
          expect(positive.matchedDirection, direction.intent);
          expect(
            _tier(direction.operation, arguments, prepared, positive).decision,
            AiGateDecision.execute,
          );

          for (final message in [
            'Do not $phrase team/example-9#3 note:401.',
            'If $phrase team/example-9#3 note:401.',
            '> $phrase\nteam/example-9#3 note:401.',
            '$phrase and $opposite team/example-9#3 note:401.',
            '$opposite team/example-9#3 note:401.',
          ]) {
            final binding = _bind(
              message,
              prepared.bindingTargets,
              operation: direction.operation,
              arguments: arguments,
            );
            expect(binding.allBound, isTrue, reason: message);
            expect(binding.intentAuthorizesLowRisk, isFalse, reason: message);
            final decision = _tier(
              direction.operation,
              arguments,
              prepared,
              binding,
            );
            expect(decision.tier, AiWriteTier.t1);
            expect(decision.decision, AiGateDecision.requireApproval);
            expect(
              decision.reasons,
              contains(AiFixedConfirmReason.intentNotUnique),
            );
          }

          final restored = _bind(
            '$phrase team/example-9#3 note:401.',
            prepared.bindingTargets,
            operation: direction.operation,
            arguments: arguments,
            restored: true,
          );
          expect(restored.intentAuthorizesLowRisk, isFalse);
          expect(
            _tier(direction.operation, arguments, prepared, restored).decision,
            AiGateDecision.requireApproval,
          );

          // Exercise execute's actual waiting path. A model's positive reason and
          // explicit direction arguments cannot override trusted user negation.
          h.coordinator.beginRun('Do not $phrase team/example-9#3 note:401.');
          h.coordinator.beginTurn();
          final waiting = Completer<void>();
          final pending = h.coordinator.execute(
            AiToolCall(
              id: 'negated-${direction.intent.name}',
              name: direction.operation,
              arguments: {...arguments, 'reason': '$phrase immediately'},
            ),
            onAwaitingApproval: (value) {
              if (value && !waiting.isCompleted) waiting.complete();
            },
          );
          await waiting.future.timeout(mr6b3Timeout);
          final proposal = h.coordinator.proposals.single;
          expect(proposal.tier.tier, AiWriteTier.t1);
          expect(proposal.tier.decision, AiGateDecision.requireApproval);
          expect(
            proposal.tier.reasons,
            contains(AiFixedConfirmReason.intentNotUnique),
          );
          expect(h.server.mutations, 0);
          expect(h.journal.entries(mr6b3Account), isEmpty);
          h.coordinator.stop();
          expect((await pending).mutationCount, 0);
          expect(h.server.mutations, 0);
        },
      );

      test(
        '${direction.intent.name} interface and device negation both guard',
        () {
          final zh = languageForTag('zh-TW')!;
          final phrase = AiIntentLexicon.phrases(zh, direction.intent).first;
          final withoutJapanese = assessIntent(
            message: 'しないで $phrase',
            restoredFromHistory: false,
            operationId: direction.operation,
            arguments: direction.arguments,
            interfaceLanguage: 'zh-TW',
            deviceLanguages: const ['en'],
          );
          expect(withoutJapanese.negated, isFalse);
          expect(withoutJapanese.authorizes, isTrue);
          for (final languages in [
            (interface: 'ja', device: const ['zh-TW']),
            (interface: 'zh-TW', device: const ['ja']),
          ]) {
            final assessment = assessIntent(
              message: 'しないで $phrase',
              restoredFromHistory: false,
              operationId: direction.operation,
              arguments: direction.arguments,
              interfaceLanguage: languages.interface,
              deviceLanguages: languages.device,
            );
            expect(assessment.negated, isTrue);
            expect(assessment.authorizes, isFalse);
            final positive = assessIntent(
              message: phrase,
              restoredFromHistory: false,
              operationId: direction.operation,
              arguments: direction.arguments,
              interfaceLanguage: languages.interface,
              deviceLanguages: languages.device,
            );
            expect(positive.authorizes, isTrue);
          }
        },
      );
    }

    for (final event in ['close', 'reopen']) {
      test('$event remains T2 confirmation at lowRiskAuto', () async {
        final h = await _harness();
        h.policy.level = AiAutonomyLevel.lowRiskAuto;
        h.coordinator.beginRun('Do not $event team/example-9#3.');
        h.coordinator.beginTurn();
        final proposal = await h.propose(
          'updateWorkItemState',
          arguments: {'stateEvent': event},
        );
        expect(proposal, isNotNull);
        expect(proposal!.tier.tier, AiWriteTier.t2);
        expect(proposal.tier.decision, AiGateDecision.requireApproval);
        // Lifecycle is T2 and has no T1 lexicon. This asserts the real tier
        // boundary rather than pretending close/reopen is a T1 direction.
        expect(directionsFor('updateWorkItemState'), isEmpty);
        expect(h.server.mutations, 0);
        expect(h.journal.entries(mr6b3Account), isEmpty);
      });
    }
  });

  group('§15 rows 10 and 16 project keys and composite targets', () {
    test(
      'same iid in two projects prepares distinct nonintersecting keys',
      () async {
        final first = await _harness();
        final second = await _harness();
        // Project 10 is answered by onRequest; skip the project-9 variables
        // check on this server only.
        second.server.checkGraphqlIdentity = false;
        second.server.onRequest = (name, mutation, request, payload) =>
            jsonResponse(_projectTen(payload) as Map<String, Object?>);
        final inNine = await first.server.writePort.prepare(
          _request('updateWorkItemState', scope: _twoProjects),
        );
        final inTen = await second.server.writePort.prepare(
          _request(
            'updateWorkItemState',
            scope: _twoProjects,
            arguments: {
              ...mr6b3ApiArguments('updateWorkItemState'),
              'projectId': 10,
            },
          ),
        );
        expect(inNine.writeKeys, {mr6b3WriteKey});
        expect(inTen.writeKeys, {
          const AiConflictKey([mr6b3Account, 'project:10', 'workItem', '3']),
        });
        for (final firstKey in inNine.writeKeys) {
          for (final secondKey in inTen.writeKeys) {
            expect(firstKey.intersects(secondKey), isFalse);
          }
        }
        expect(inNine.bindingTargets.single.projectId, 9);
        expect(inTen.bindingTargets.single.projectId, 10);
        expect(
          _bind(
            'Update #3.',
            inNine.bindingTargets,
            scope: _twoProjects,
          ).allBound,
          isFalse,
        );
        expect(
          _bind(
            'Update team/example-9#3.',
            inNine.bindingTargets,
            scope: _twoProjects,
          ).allBound,
          isTrue,
        );
        expect(
          _bind(
            'Update team/example-9#3.',
            inTen.bindingTargets,
            scope: _twoProjects,
          ).allBound,
          isFalse,
        );
        expect(
          _bind(
            'Update team/example-10#3.',
            inTen.bindingTargets,
            scope: _twoProjects,
          ).allBound,
          isTrue,
        );
        expect(first.server.mutations + second.server.mutations, 0);
      },
    );

    test(
      'reply binds item plus note; item alone confirms even at bypass',
      () async {
        final h = await _harness();
        final prepared = await h.server.writePort.prepare(
          _request('createWorkItemActivityReply'),
        );
        expect(prepared.bindingTargets, hasLength(2));
        final onlyItem = _bind(
          'Reply to team/example-9#3.',
          prepared.bindingTargets,
        );
        expect(onlyItem.allBound, isFalse);
        expect(onlyItem.missingComponents, ['note']);
        expect(
          _bind(
            'Reply to team/example-9#3 note:401.',
            prepared.bindingTargets,
          ).allBound,
          isTrue,
        );
        final reasonCannotBind = _bind(
          'Reply to team/example-9#3.',
          prepared.bindingTargets,
          redactedReason: 'The user approved note:401.',
        );
        expect(reasonCannotBind.allBound, isFalse);
        h.policy.level = AiAutonomyLevel.bypass;
        h.coordinator.beginRun('Reply to team/example-9#3.');
        h.coordinator.beginTurn();
        final proposal = (await h.propose('createWorkItemActivityReply'))!;
        expect(proposal.tier.decision, AiGateDecision.requireApproval);
        expect(
          proposal.tier.reasons,
          contains(AiFixedConfirmReason.targetUnbound),
        );
        expect(h.server.mutations, 0);
        expect(h.journal.entries(mr6b3Account), isEmpty);
      },
    );
  });

  group('§15 rows 10 and 24 graph project/group denial', () {
    test('locator itself refuses a typed projectless group detail', () async {
      var reads = 0;
      await expectLater(
        port.resolveAiProjectWorkItem(
          mr6b3Scope,
          9,
          3,
          readDetail: (project, iid) async {
            reads++;
            return WorkItemGraphDetail(
              summary: WorkItemGraphSummary(
                id: 'gid://gitlab/WorkItem/31',
                iid: 3,
                title: 'Synthetic group item',
                state: 'OPEN',
                createdAt: DateTime.utc(2026, 10),
                updatedAt: DateTime.parse(mr6b3Revision),
                project: null,
                namespace: const GraphResourceRef(
                  id: 'gid://gitlab/Group/5',
                  fullPath: 'team',
                ),
                type: const WorkItemGraphType(
                  id: 'gid://gitlab/WorkItems::Type/9',
                  name: 'Task',
                ),
              ),
              description: null,
              widgetsAvailable: true,
              widgetTypes: const {},
              descriptionWidget: null,
              assignees: null,
              labels: null,
              hierarchy: null,
              dates: null,
            );
          },
        ),
        throwsA(
          isA<port.AiWriteRefused>().having(
            (failure) => failure.reason,
            'reason',
            'workItemUnverifiable',
          ),
        ),
      );
      expect(reads, 1);
    });

    // The real project reader rejects this response before returning a detail
    // to the locator. Families preserve or deliberately map that failure.
    // Issue #21 tracks the differing family refusal reason codes pinned here.
    const groupRefusals = <String, String>{
      'updateWorkItemState': 'invalidResponse',
      'updateWorkItemStatus': 'invalidResponse',
      'updateWorkItemDates': 'invalidResponse',
      'updateWorkItemHealthStatus': 'invalidResponse',
      'updateWorkItemMilestone': 'milestoneRejected',
      'updateWorkItemWeight': 'weightRejected',
      'updateWorkItemAssignees': 'assigneeConflict',
      'createWorkItemActivityComment': 'activityUnverifiable',
      'createWorkItemActivityReply': 'activityUnverifiable',
      'deleteWorkItemActivityNote': 'invalidResponse',
      'setWorkItemActivityNoteReaction': 'invalidResponse',
      'setWorkItemNotifications': 'invalidResponse',
      'setIncidentStatus': 'invalidResponse',
    };
    for (final entry in groupRefusals.entries) {
      test(
        '${entry.key} refuses projectless group item before proposal',
        () async {
          final h = await _harness();
          h.server.onRequest = (name, mutation, request, payload) {
            if (name == 'MobileProjectWorkItem') {
              final item = _detailNode(payload);
              item['project'] = null;
              item['namespace'] = {
                'id': 'gid://gitlab/Group/5',
                'fullPath': 'team',
              };
            }
            return null;
          };
          final proposal = await h.propose(entry.key, id: 'group-only');
          expect(proposal, isNull);
          expect(
            h.coordinator.outcomeFor('group-only')?.reasonCode,
            entry.value,
          );
          expect(h.coordinator.proposals, isEmpty);
          expect(h.server.reads['MobileProjectWorkItem'], 1);
          expect(h.server.mutations, 0);
          expect(h.journal.entries(mr6b3Account), isEmpty);
        },
      );
    }

    for (final foreign in ['project', 'group', 'groupGidAsItem']) {
      test('locator refuses foreign $foreign GID before proposal', () async {
        final h = await _harness();
        h.server.onRequest = (name, mutation, request, payload) {
          if (name == 'MobileProjectWorkItem') {
            final item = _detailNode(payload);
            switch (foreign) {
              case 'project':
                item['project'] = {
                  'id': 'gid://gitlab/Project/10',
                  'fullPath': 'team/example-10',
                };
              case 'group':
                item['namespace'] = {
                  'id': 'gid://gitlab/Group/999',
                  'fullPath': 'foreign',
                };
              case 'groupGidAsItem':
                item['id'] = 'gid://gitlab/Group/31';
            }
          }
          return null;
        };
        expect(await h.propose('updateWorkItemState', id: 'foreign'), isNull);
        expect(
          h.coordinator.outcomeFor('foreign')?.reasonCode,
          foreign == 'project' ? 'invalidResponse' : 'workItemUnverifiable',
        );
        expect(h.coordinator.proposals, isEmpty);
        expect(h.server.mutations, 0);
        expect(h.journal.entries(mr6b3Account), isEmpty);
      });
    }

    for (final operation in ['snoozeTodo', 'unsnoozeTodo']) {
      test(
        '$operation group target remains refused by AI even accountGlobal',
        () async {
          final h = await _harness();
          _makeGroupTodo(h.server);
          expect(await h.propose(operation, id: 'group-todo'), isNull);
          expect(
            h.coordinator.outcomeFor('group-todo')?.reasonCode,
            'todoUnsupportedTarget',
          );
          await expectLater(
            h.server.writePort.prepare(
              _request(
                operation,
                scope: const AiWriteScope(
                  accountKey: mr6b3Account,
                  grants: [AiScopeGrant(kind: AiScopeKind.accountGlobal)],
                ),
              ),
            ),
            throwsA(
              isA<port.AiWriteRefused>().having(
                (failure) => failure.reason,
                'reason',
                'todoUnsupportedTarget',
              ),
            ),
          );
          expect(h.coordinator.proposals, isEmpty);
          expect(h.server.mutations, 0);
          expect(h.journal.entries(mr6b3Account), isEmpty);
        },
      );
    }

    test(
      'core only, not row 24 evidence: group todo snooze uses todo coordinates',
      () async {
        final h = await _harness();
        _makeGroupTodo(h.server);
        final owned = await h.server.api.pendingTodosForSnooze(maxPages: 4);
        expect(owned.unsupportedIds, contains(400));
        expect(owned.items.where((item) => item['id'] == 400), isEmpty);
        expect(h.server.mutations, 0);
        final acknowledged = await h.server.api.snoozeTodo(
          400,
          DateTime.parse(mr6b3SnoozeUntil),
        );
        expect(acknowledged, DateTime.parse(mr6b3SnoozeUntil));
        final mutation = h.server.adapter.requests.singleWhere(
          (request) =>
              request.data is Map &&
              ((request.data as Map)['query'] as String).startsWith(
                'mutation ',
              ),
        );
        expect((mutation.data as Map)['variables'], {
          'id': 'gid://gitlab/Todo/400',
          'until': mr6b3SnoozeUntil,
        });
        expect(h.server.mutations, 1);
        expect(h.coordinator.proposals, isEmpty);
        expect(h.journal.entries(mr6b3Account), isEmpty);
      },
    );
  });
}

Future<Mr6b3ApiHarness> _harness() async {
  final h = await Mr6b3ApiHarness.create(oauth: false);
  addTearDown(h.dispose);
  return h;
}

port.AiWriteRequest _request(
  String operation, {
  AiWriteScope scope = mr6b3Scope,
  Map<String, Object?>? arguments,
}) => port.AiWriteRequest(
  operationId: operation,
  executionId: 'binding-$operation',
  scope: scope,
  arguments: arguments ?? mr6b3ApiArguments(operation),
);

AiBindingResult _bind(
  String message,
  List<AiTargetRef> targets, {
  AiWriteScope scope = mr6b3Scope,
  String operation = '',
  Map<String, Object?> arguments = const {},
  bool restored = false,
  String? redactedReason,
}) => bindTargets(
  userMessage: message,
  restoredFromHistory: restored,
  scope: scope,
  targets: targets,
  interfaceLanguage: 'en',
  deviceLanguages: const ['en'],
  operationId: operation,
  arguments: arguments,
  redactedReason: redactedReason,
);

AiTierDecision _tier(
  String operation,
  Map<String, Object?> arguments,
  port.AiWritePrepared prepared,
  AiBindingResult binding,
) => decideTier(
  AiTierInput(
    level: AiAutonomyLevel.lowRiskAuto,
    capability: productionAiLedger.find(operation)!,
    scope: mr6b3Scope,
    binding: binding,
    target: prepared.bindingTargets.first,
    arguments: arguments,
  ),
);

Map<String, Object?> _detailNode(Map<String, Object?> payload) {
  final project = (payload['data'] as Map)['project'] as Map;
  return ((project['workItems'] as Map)['nodes'] as List).single
      as Map<String, Object?>;
}

Object? _projectTen(Object? value) {
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key as String: _projectTen(entry.value),
    };
  }
  if (value is List) return [for (final item in value) _projectTen(item)];
  return switch (value) {
    'gid://gitlab/Project/9' => 'gid://gitlab/Project/10',
    'gid://gitlab/Namespaces::ProjectNamespace/9' =>
      'gid://gitlab/Namespaces::ProjectNamespace/10',
    'gid://gitlab/WorkItem/31' => 'gid://gitlab/WorkItem/41',
    'team/example-9' => 'team/example-10',
    _ => value,
  };
}

void _makeGroupTodo(Mr6b3ApiServer server) {
  server.onRequest = (name, mutation, request, payload) {
    if (name == 'MobilePendingTodosForSnooze' ||
        name == 'MobileSnoozedTodosForUnsnooze') {
      final copy = (jsonDecode(jsonEncode(payload)) as Map)
          .cast<String, Object?>();
      final user = (copy['data'] as Map)['currentUser'] as Map;
      final nodes = (user['todos'] as Map)['nodes'] as List;
      for (final node in nodes.cast<Map<String, dynamic>>()) {
        if (node['id'] != 'gid://gitlab/Todo/400') continue;
        node['project'] = null;
        final target = node['targetEntity'] as Map;
        target['workItemProject'] = null;
        target['namespace'] = {
          'id': 'gid://gitlab/Group/5',
          'fullPath': 'team',
        };
      }
      return jsonResponse(copy);
    }
    return null;
  };
}
