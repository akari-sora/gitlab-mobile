// U-add (MR6b-3g §6.1, decision D27): a group work item the user adds to a
// conversation's write scope from a pasted link. Synthetic GitLab only.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_controller.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_page.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_scope_add.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import 'fx_coord_support.dart';
import 'mr6b3g_support.dart' show G0eLedger;

const _link = 'https://example.com/gitlab/groups/team/sub/-/work_items/5';
const _item91 = 'gid://gitlab/WorkItem/91';

final _instance = GitLabInstance.parse('https://example.com/gitlab');

/// The namespace document the strict reader receives for `team/sub` #5.
Map<String, Object?> _namespace({
  String groupGid = 'gid://gitlab/Group/7',
  String path = 'team/sub',
  String workItemGid = _item91,
  bool withProject = true,
  Object? project,
  Map<String, Object?>? owner,
  String title = 'Fresh group item',
}) => {
  'data': {
    'namespace': {
      'id': groupGid,
      'fullPath': path,
      'workItem': {
        'id': workItemGid,
        'iid': '5',
        'title': title,
        'state': 'OPEN',
        'createdAt': '2026-10-01T00:00:00Z',
        'updatedAt': '2026-10-02T00:00:00Z',
        if (withProject) 'project': project,
        'namespace': owner ?? {'id': groupGid, 'fullPath': path},
        'workItemType': {
          'id': 'gid://gitlab/WorkItems::Type/1',
          'name': 'Task',
        },
        'description': 'Synthetic group body',
        'widgets': <Object?>[],
      },
    },
  },
};

/// Mutable synthetic GitLab for one group: the REST owner lookup by path, the
/// REST lookup by numeric id, and the strict namespace reads in order.
final class _Group {
  int restId = 7;
  String restPath = 'team/sub';
  String idPath = 'team/sub';
  bool restMissing = false;
  Completer<void>? holdRest;
  Map<String, Object?> Function(int read) namespace = (_) => _namespace();
  int restReads = 0;
  int idReads = 0;
  int namespaceReads = 0;

  void serve(StackServer server) {
    server.overrides['GET groups/team/sub'] = (request) async {
      restReads++;
      expect(request.uri.queryParameters, {'with_projects': 'false'});
      await holdRest?.future;
      if (restMissing) {
        return jsonResponse({'message': '404 Not Found'}, status: 404);
      }
      return jsonResponse({
        'id': restId,
        'name': 'Sub',
        'full_path': restPath,
        'visibility': 'private',
      });
    };
    for (final id in [7, 8, 9]) {
      server.overrides['GET groups/$id'] = (request) {
        idReads++;
        return jsonResponse({
          'id': id,
          'full_path': idPath,
          'visibility': 'private',
        });
      };
    }
    server.overrides['POST '] = (request) {
      final body = request.data! as Map<String, Object?>;
      expect(body['query'], namespaceWorkItemQuery);
      namespaceReads++;
      return jsonResponse(namespace(namespaceReads));
    };
  }
}

Future<(StackHarness, _Group)> _harness({
  AiChatOrigin? origin,
  AiAutonomyLevel level = AiAutonomyLevel.lowRiskAuto,
  void Function(StackServer server)? configure,
}) async {
  final group = _Group();
  final h = await StackHarness.create(
    origin: origin,
    level: level,
    configure: (server) {
      configure?.call(server);
      group.serve(server);
    },
  );
  addTearDown(h.dispose);
  return (h, group);
}

List<RequestOptions> _after(StackHarness h, int before) =>
    h.server.adapter.requests.skip(before).toList();

List<String> _shape(List<RequestOptions> requests) => [
  for (final request in requests)
    '${request.method} ${request.uri.path.replaceFirst('/gitlab/api/', '')}',
];

List<VerifiedLike> _uiAdded(AiChatController controller) => [
  for (final identity
      in controller.writePolicySnapshot!.scope.uiAddedGroupWorkItems)
    (
      groupId: identity.groupId,
      fullPath: identity.fullPath,
      iid: identity.iid,
      workItemGid: identity.workItemGid,
    ),
];

typedef VerifiedLike = ({
  int groupId,
  String fullPath,
  int iid,
  String workItemGid,
});

List<AiScopeGrant> _groupGrants(AiChatController controller) => [
  for (final grant in controller.writePolicySnapshot!.scope.grants)
    if (grant.kind == AiScopeKind.groupWorkItem) grant,
];

void _gate() {
  aiGroupWorkItemWritesEnabledForTesting = true;
  addTearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
}

AiTargetRef _groupTarget(int groupId, {int iid = 5, String? gid = _item91}) =>
    AiTargetRef(
      kind: AiTargetKind.groupWorkItem,
      side: AiResourceSide.group,
      groupId: groupId,
      groupFullPath: 'team/sub',
      iid: iid,
      workItemGid: gid,
      origin: AiTargetOrigin.uiAdded,
    );

/// Checks [_link] and confirms the verified candidate.
Future<void> _add(AiChatController controller, [String link = _link]) async {
  final check = await controller.checkGroupWorkItem(link);
  expect(
    check,
    isA<AiGroupWorkItemCandidate>(),
    reason: switch (check) {
      AiGroupWorkItemRefused(:final reason, :final failure) =>
        '$reason $failure ${controller.phase} ${controller.blocker}',
      _ => '',
    },
  );
  expect(
    await controller.addGroupWorkItem(check as AiGroupWorkItemCandidate),
    isNull,
  );
}

Future<void> _untilPhase(AiChatController controller, AiChatPhase phase) async {
  for (var i = 0; i < 1000 && controller.phase != phase; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(controller.phase, phase);
}

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  group('link parser', () {
    AiGroupWorkItemLinkResult parse(String text) =>
        parseAiGroupWorkItemLink(text, _instance);

    AiGroupWorkItemLinkRefusal? refusal(String text) => switch (parse(text)) {
      AiGroupWorkItemLinkRefused(:final reason) => reason,
      AiGroupWorkItemLink() => null,
    };

    test('accepts only a group work item on the same instance', () {
      for (final text in [
        _link,
        '$_link/',
        '  $_link  ',
        '$_link#note_12',
        '$_link?show=1',
        'HTTPS://EXAMPLE.com/gitlab/groups/team/sub/-/work_items/5',
        'https://example.com:443/gitlab/groups/team/sub/-/work_items/5',
      ]) {
        final result = parse(text);
        expect(result, isA<AiGroupWorkItemLink>(), reason: text);
        result as AiGroupWorkItemLink;
        expect(result.fullPath, 'team/sub', reason: text);
        expect(result.iid, 5, reason: text);
      }
      final deep = parse(
        'https://example.com/gitlab/groups/a/b.c/d_e-f/-/work_items/2147483647',
      );
      expect((deep as AiGroupWorkItemLink).fullPath, 'a/b.c/d_e-f');
      expect(deep.iid, 2147483647);
    });

    test('refuses another instance or installation path', () {
      for (final text in [
        'http://example.com/gitlab/groups/team/sub/-/work_items/5',
        'https://other.example/gitlab/groups/team/sub/-/work_items/5',
        'https://example.com:8443/gitlab/groups/team/sub/-/work_items/5',
        'https://example.com/groups/team/sub/-/work_items/5',
        'https://example.com/other/groups/team/sub/-/work_items/5',
        'https://user@example.com/gitlab/groups/team/sub/-/work_items/5',
        'ftp://example.com/gitlab/groups/team/sub/-/work_items/5',
      ]) {
        expect(
          refusal(text),
          AiGroupWorkItemLinkRefusal.otherInstance,
          reason: text,
        );
      }
    });

    test('refuses project resources', () {
      for (final text in [
        'https://example.com/gitlab/team/sub/app/-/work_items/5',
        'https://example.com/gitlab/team/sub/-/work_items/5',
        'https://example.com/gitlab/team/app/-/issues/5',
        'https://example.com/gitlab/team/app/-/merge_requests/5',
      ]) {
        expect(
          refusal(text),
          AiGroupWorkItemLinkRefusal.projectLink,
          reason: text,
        );
      }
    });

    test('refuses group links that are not one work item', () {
      for (final text in [
        'https://example.com/gitlab/groups/team/sub',
        'https://example.com/gitlab/groups/team/sub/-/work_items',
        'https://example.com/gitlab/groups/team/sub/-/work_items/5/designs',
        'https://example.com/gitlab/groups/team/sub/-/epics/5',
        'https://example.com/gitlab/groups/team/sub/-/issues/5',
        'https://example.com/gitlab/team',
      ]) {
        expect(
          refusal(text),
          AiGroupWorkItemLinkRefusal.notWorkItem,
          reason: text,
        );
      }
    });

    test('refuses malformed links before any request', () {
      for (final text in [
        '',
        '#5',
        'team/sub#5',
        'example.com/gitlab/groups/team/sub/-/work_items/5',
        'https://example.com/gitlab',
        'https://example.com/gitlab/groups/-/work_items/5',
        'https://example.com/gitlab/groups/team/sub/-/work_items/0',
        'https://example.com/gitlab/groups/team/sub/-/work_items/05',
        'https://example.com/gitlab/groups/team/sub/-/work_items/+5',
        'https://example.com/gitlab/groups/team/sub/-/work_items/x',
        'https://example.com/gitlab/groups/team/sub/-/work_items/99999999999',
        'https://example.com/gitlab/groups/team%2Fsub/-/work_items/5',
        'https://example.com/gitlab/groups/team/%2e%2e/-/work_items/5',
        'https://example.com/gitlab/groups/team/../-/work_items/5',
        // Both normalise to a valid group link once Uri drops dot segments.
        'https://example.com/gitlab/groups/ignored/../team/sub/-/work_items/5',
        'https://example.com/other/../gitlab/groups/team/sub/-/work_items/5',
        'https://example.com/gitlab/./groups/team/sub/-/work_items/5',
        'https://example.com/gitlab/groups/team//sub/-/work_items/5',
        r'https://example.com/gitlab/groups/team\sub/-/work_items/5',
        'https://example.com/gitlab/groups/te am/-/work_items/5',
        '$_link?private_token=synthetic',
        '$_link?Access_Token=synthetic',
        'https://example.com/gitlab/groups/team/sub/-/work_items/5\nx',
      ]) {
        expect(
          refusal(text),
          AiGroupWorkItemLinkRefusal.malformed,
          reason: text,
        );
      }
    });
  });

  group('controller', () {
    test('a verified item enters scope only after the confirmation, as one '
        'grant and one trusted identity', () async {
      _gate();
      final (h, group) = await _harness();
      final controller = h.controller;
      expect(controller.offersGroupWorkItemAdd, isTrue);
      expect(controller.canAddGroupWorkItem, isTrue);
      final grantsBefore = controller.writePolicySnapshot!.scope.grants;
      final revisionBefore = controller.writePolicySnapshot!.scopeRevision;
      final before = h.server.adapter.requests.length;

      final check = await controller.checkGroupWorkItem(_link);
      expect(check, isA<AiGroupWorkItemCandidate>());
      final candidate = check as AiGroupWorkItemCandidate;
      expect(candidate.fullPath, 'team/sub');
      expect(candidate.iid, 5);
      expect(candidate.title, 'Fresh group item');
      expect(candidate.endsConversationGrant, isFalse);
      // The owner by path, the context's numeric owner and strict read,
      // then the read port's own strict read. No mutation.
      final reads = _after(h, before);
      expect(_shape(reads), [
        'GET v4/groups/team%2Fsub',
        'GET v4/groups/7',
        'POST graphql',
        'POST graphql',
      ]);
      for (final read in reads.where((read) => read.method == 'POST')) {
        final body = read.data! as Map<String, Object?>;
        expect(body['query'], namespaceWorkItemQuery);
        expect(body['variables'], {'path': 'team/sub', 'iid': '5'});
      }
      // A check alone changes nothing.
      expect(controller.addedGroupWorkItems, isEmpty);
      expect(_uiAdded(controller), isEmpty);
      expect(_groupGrants(controller), isEmpty);
      expect(controller.writePolicySnapshot!.scopeRevision, revisionBefore);

      expect(await controller.addGroupWorkItem(candidate), isNull);
      expect(h.server.adapter.requests, hasLength(before + 4));
      final scope = controller.writePolicySnapshot!.scope;
      expect(scope.grants, hasLength(grantsBefore.length + 1));
      for (final grant in grantsBefore) {
        expect(
          scope.grants.where(
            (kept) =>
                kept.kind == grant.kind &&
                kept.projectId == grant.projectId &&
                kept.projectPath == grant.projectPath,
          ),
          isNotEmpty,
        );
      }
      final added = _groupGrants(controller).single;
      expect(added.groupId, 7);
      expect(added.groupFullPath, 'team/sub');
      expect(added.iid, 5);
      expect(added.projectId, isNull);
      expect(added.projectPath, isNull);
      expect(_uiAdded(controller), [
        (groupId: 7, fullPath: 'team/sub', iid: 5, workItemGid: _item91),
      ]);
      expect(
        controller.writePolicySnapshot!.scopeRevision,
        greaterThan(revisionBefore),
      );
      final shown = controller.addedGroupWorkItems.single;
      expect(shown.key, 'group:7:5');
      expect(shown.fullPath, 'team/sub');
      expect(shown.iid, 5);

      // The grant is that one item: never another group with the same
      // iid, a sibling item, a forged Work Item GID or the whole group.
      final capability = const G0eLedger().find('updateGroupWorkItemState')!;
      expect(scopeAdmits(scope, capability, _groupTarget(7)), isTrue);
      expect(scopeAdmits(scope, capability, _groupTarget(9)), isFalse);
      expect(scopeAdmits(scope, capability, _groupTarget(7, iid: 6)), isFalse);
      expect(
        scopeAdmits(
          scope,
          capability,
          _groupTarget(7, gid: 'gid://gitlab/WorkItem/92'),
        ),
        isFalse,
      );
      expect(
        scopeAdmits(scope, capability, _groupTarget(7, gid: null)),
        isFalse,
      );
      expect(group.restReads, 1);
    });

    test(
      'another instance, a project or a malformed link reads nothing',
      () async {
        final (h, _) = await _harness();
        final before = h.server.adapter.requests.length;
        for (final (link, reason) in [
          (
            'https://other.example/gitlab/groups/team/sub/-/work_items/5',
            AiGroupWorkItemRefusal.otherInstance,
          ),
          (
            'https://example.com/gitlab/team/sub/app/-/work_items/5',
            AiGroupWorkItemRefusal.projectLink,
          ),
          (
            'https://example.com/gitlab/groups/team/sub/-/epics/5',
            AiGroupWorkItemRefusal.notWorkItem,
          ),
          ('not a link', AiGroupWorkItemRefusal.malformed),
          (
            'https://example.com/gitlab/groups/ignored/../team/sub/-/work_items/5',
            AiGroupWorkItemRefusal.malformed,
          ),
          (
            'https://example.com/other/../gitlab/groups/team/sub/-/work_items/5',
            AiGroupWorkItemRefusal.malformed,
          ),
        ]) {
          final check = await h.controller.checkGroupWorkItem(link);
          expect(
            (check as AiGroupWorkItemRefused).reason,
            reason,
            reason: link,
          );
        }
        expect(h.server.adapter.requests, hasLength(before));
        expect(h.controller.budgetAllocator.activeLeases, 0);
        expect(_groupGrants(h.controller), isEmpty);
        expect(_uiAdded(h.controller), isEmpty);
        expect(h.controller.addedGroupWorkItems, isEmpty);
      },
    );

    final refusals =
        <String, ({void Function(_Group group) arrange, int reads})>{
          'identity drift between the two strict reads': (
            arrange: (group) => group.namespace = (read) => read == 1
                ? _namespace()
                : _namespace(workItemGid: 'gid://gitlab/WorkItem/92'),
            reads: 4,
          ),
          'a rename between the owner lookups': (
            arrange: (group) {
              group.idPath = 'team/renamed';
              group.namespace = (_) => _namespace(path: 'team/renamed');
            },
            reads: 3,
          ),
          'the same iid in a foreign group': (
            arrange: (group) =>
                group.namespace = (_) =>
                    _namespace(groupGid: 'gid://gitlab/Group/9'),
            reads: 3,
          ),
          'a project descendant under the group path': (
            arrange: (group) => group.namespace = (_) => _namespace(
              project: const {
                'id': 'gid://gitlab/Project/42',
                'fullPath': 'team/sub/app',
              },
              owner: const {
                'id': 'gid://gitlab/Namespaces::ProjectNamespace/42',
                'fullPath': 'team/sub/app',
              },
            ),
            reads: 3,
          ),
          'a reply without the project key': (
            arrange: (group) =>
                group.namespace = (_) => _namespace(withProject: false),
            reads: 3,
          ),
          'a Group owner that is not the item namespace': (
            arrange: (group) => group.namespace = (_) => _namespace(
              owner: const {'id': 'gid://gitlab/Group/8', 'fullPath': 'team'},
            ),
            reads: 3,
          ),
          'a REST owner path that differs from the link': (
            arrange: (group) => group.restPath = 'team/other',
            reads: 1,
          ),
        };
    for (final MapEntry(key: name, value: refusal) in refusals.entries) {
      test('$name adds nothing', () async {
        _gate();
        final (h, group) = await _harness();
        refusal.arrange(group);
        final revision = h.controller.writePolicySnapshot!.scopeRevision;
        final before = h.server.adapter.requests.length;
        final check = await h.controller.checkGroupWorkItem(_link);
        expect(check, isA<AiGroupWorkItemRefused>());
        expect(
          (check as AiGroupWorkItemRefused).reason,
          AiGroupWorkItemRefusal.notGroupOwned,
        );
        expect(_after(h, before), hasLength(refusal.reads));
        expect(
          _after(h, before).every(
            (request) =>
                request.method == 'GET' ||
                !(request.data! as Map)['query'].toString().contains(
                  'mutation',
                ),
          ),
          isTrue,
        );
        expect(h.controller.addedGroupWorkItems, isEmpty);
        expect(_uiAdded(h.controller), isEmpty);
        expect(_groupGrants(h.controller), isEmpty);
        expect(
          h.controller.writePolicySnapshot!.scope.grants.where(
            (grant) => grant.projectId != null && grant.projectId != 42,
          ),
          isEmpty,
        );
        expect(h.controller.writePolicySnapshot!.scopeRevision, revision);
        expect(h.controller.budgetAllocator.activeLeases, 0);
        expect(h.controller.canAddGroupWorkItem, isTrue);
      });
    }

    test(
      'a 404 stays ambiguous, names the resource and adds nothing',
      () async {
        final (h, group) = await _harness();
        group.restMissing = true;
        final check = await h.controller.checkGroupWorkItem(_link);
        check as AiGroupWorkItemRefused;
        expect(check.reason, AiGroupWorkItemRefusal.readFailed);
        expect(check.failure, isA<ApiFailure>());
        expect((check.failure! as ApiFailure).kind, FailureKind.invisible);
        expect(check.fullPath, 'team/sub');
        expect(check.iid, 5);
        expect(_groupGrants(h.controller), isEmpty);
      },
    );

    test('the reads count against the shared AI read budget', () async {
      final (h, group) = await _harness();
      final allocator = h.controller.budgetAllocator;
      group.holdRest = Completer<void>();
      final pending = h.controller.checkGroupWorkItem(_link);
      await Future<void>.delayed(Duration.zero);
      // While reading, the check holds a lease like a run and blocks a
      // second check.
      expect(allocator.activeLeases, 1);
      expect(allocator.unconsumedReservations, 8);
      expect(h.controller.canAddGroupWorkItem, isFalse);
      expect(
        (await h.controller.checkGroupWorkItem(_link) as AiGroupWorkItemRefused)
            .reason,
        AiGroupWorkItemRefusal.unavailable,
      );
      group.holdRest!.complete();
      expect(await pending, isA<AiGroupWorkItemCandidate>());
      expect(allocator.activeLeases, 0);

      // With the shared allocator full, nothing is read or added.
      final held = [for (var i = 0; i < 3; i++) allocator.acquire(1)!];
      final before = h.server.adapter.requests.length;
      final refused =
          await h.controller.checkGroupWorkItem(_link)
              as AiGroupWorkItemRefused;
      for (final lease in held) {
        lease.release();
      }
      expect(refused.reason, AiGroupWorkItemRefusal.readFailed);
      expect(refused.failure, isA<AiFailure>());
      expect((refused.failure! as AiFailure).gitLabBudget, isTrue);
      expect(h.server.adapter.requests, hasLength(before));
      expect(allocator.activeLeases, 0);
      expect(_groupGrants(h.controller), isEmpty);
    });

    test('a change of conversation during the reads adds nothing', () async {
      final (h, group) = await _harness();
      group.holdRest = Completer<void>();
      final pending = h.controller.checkGroupWorkItem(_link);
      await Future<void>.delayed(Duration.zero);
      h.controller.startNewConversation();
      group.holdRest!.complete();
      expect(
        (await pending as AiGroupWorkItemRefused).reason,
        AiGroupWorkItemRefusal.unavailable,
      );
      await _untilPhase(h.controller, AiChatPhase.idle);
      expect(_groupGrants(h.controller), isEmpty);
      expect(h.controller.budgetAllocator.activeLeases, 0);
    });

    test('a candidate is accepted once, from the latest check only', () async {
      final (h, _) = await _harness();
      final first =
          await h.controller.checkGroupWorkItem(_link)
              as AiGroupWorkItemCandidate;
      final second =
          await h.controller.checkGroupWorkItem(_link)
              as AiGroupWorkItemCandidate;
      expect(
        await h.controller.addGroupWorkItem(first),
        AiGroupWorkItemRefusal.stale,
      );
      // The refused older candidate also voids the newer one.
      expect(
        await h.controller.addGroupWorkItem(second),
        AiGroupWorkItemRefusal.stale,
      );
      expect(_groupGrants(h.controller), isEmpty);
      final third =
          await h.controller.checkGroupWorkItem(_link)
              as AiGroupWorkItemCandidate;
      expect(await h.controller.addGroupWorkItem(third), isNull);
      expect(
        await h.controller.addGroupWorkItem(third),
        AiGroupWorkItemRefusal.stale,
      );
      expect(_groupGrants(h.controller), hasLength(1));
      // Already in scope: refused before any read.
      final before = h.server.adapter.requests.length;
      expect(
        (await h.controller.checkGroupWorkItem(_link) as AiGroupWorkItemRefused)
            .reason,
        AiGroupWorkItemRefusal.alreadyInScope,
      );
      expect(h.server.adapter.requests, hasLength(before));
    });

    test('adding opens a new segment and needs the provider consent', () async {
      final (h, _) = await _harness();
      await h.controller.send('First question');
      expect(h.provider.bodies, hasLength(1));
      final segmentNotices = h.controller.items.whereType<AiNoticeItem>().where(
        (item) => item.kind == AiNoticeKind.segmentSummary,
      );
      expect(segmentNotices, isEmpty);
      await _add(h.controller);
      await h.controller.send('Second question');
      expect(h.provider.bodies, hasLength(2));
      expect(
        h.controller.items.whereType<AiNoticeItem>().where(
          (item) => item.kind == AiNoticeKind.segmentSummary,
        ),
        hasLength(1),
      );
      expect(h.provider.bodies.last, contains('conversation_summary'));
      // Group rows stay hidden until G14: the new segment offers none.
      for (final id in G0eLedger.ids) {
        expect(h.provider.bodies.last, isNot(contains('"$id"')));
      }

      // Without a valid consent for the provider nothing is added and the
      // page is asked to show the consent.
      final candidate =
          await h.controller.checkGroupWorkItem(
                'https://example.com/gitlab/groups/team/sub/-/work_items/5',
              )
              as AiGroupWorkItemRefused;
      expect(candidate.reason, AiGroupWorkItemRefusal.alreadyInScope);
      h.controller.removeGroupWorkItem(h.controller.addedGroupWorkItems.single);
      final again =
          await h.controller.checkGroupWorkItem(_link)
              as AiGroupWorkItemCandidate;
      await h.settings.revokeConsent(h.account, stackProviderConfig.id);
      expect(await h.controller.addGroupWorkItem(again), isNot(isNull));
      expect(h.controller.blocker, AiChatBlocker.consentRequired);
      expect(h.controller.consentRequest, isNotNull);
      expect(_groupGrants(h.controller), isEmpty);
    });

    test(
      'adding ends the conversation grant given for the earlier scope',
      () async {
        final (h, _) = await _harness(level: AiAutonomyLevel.conversationGrant);
        expect(h.controller.autonomyLevel, AiAutonomyLevel.conversationGrant);
        final candidate =
            await h.controller.checkGroupWorkItem(_link)
                as AiGroupWorkItemCandidate;
        expect(candidate.endsConversationGrant, isTrue);
        // Confirming is the only path into scope.
        expect(h.controller.autonomyLevel, AiAutonomyLevel.conversationGrant);
        expect(await h.controller.addGroupWorkItem(candidate), isNull);
        expect(h.controller.autonomyLevel, AiAutonomyLevel.lowRiskAuto);
        // The user can grant the wider conversation again.
        await h.controller.setAutonomyLevel(AiAutonomyLevel.conversationGrant);
        expect(h.controller.autonomyLevel, AiAutonomyLevel.conversationGrant);
      },
    );

    test('not available while a run is active or waits for approval', () async {
      final (h, _) = await _harness();
      final candidate =
          await h.controller.checkGroupWorkItem(_link)
              as AiGroupWorkItemCandidate;
      bool? canAddWhileRunning;
      Future<AiGroupWorkItemCheck>? checkWhileRunning;
      h.provider.script
        ..add((_) {
          canAddWhileRunning = h.controller.canAddGroupWorkItem;
          checkWhileRunning = h.controller.checkGroupWorkItem(_link);
          return toolTurn('createNote', {
            'projectId': 42,
            'resource': 'issues',
            'iid': 5,
            'body': 'Synthetic note',
            'reason': 'Requested.',
          });
        })
        ..add((_) => answerTurn);
      final before = h.server.adapter.requests.length;
      final sending = h.controller.send('Comment on #5');
      await _untilPhase(h.controller, AiChatPhase.awaitingApproval);
      expect(canAddWhileRunning, isFalse);
      expect(
        (await checkWhileRunning! as AiGroupWorkItemRefused).reason,
        AiGroupWorkItemRefusal.unavailable,
      );
      expect(h.controller.proposals, isNotEmpty);
      expect(h.controller.canAddGroupWorkItem, isFalse);
      expect(
        await h.controller.addGroupWorkItem(candidate),
        AiGroupWorkItemRefusal.unavailable,
      );
      await h.controller.rejectWrite(h.controller.proposals.single);
      await sending;
      await _untilPhase(h.controller, AiChatPhase.idle);
      expect(
        _after(
          h,
          before,
        ).where((request) => request.uri.path.contains('/groups/')),
        isEmpty,
      );
      expect(_groupGrants(h.controller), isEmpty);
      // The confirmed candidate was spent; a fresh check works when idle.
      expect(
        await h.controller.addGroupWorkItem(candidate),
        AiGroupWorkItemRefusal.stale,
      );
      expect(h.controller.canAddGroupWorkItem, isTrue);
    });

    test('a model or tool result cannot add scope', () async {
      final (h, group) = await _harness();
      h.provider.script
        ..add(
          (_) => toolTurn(
            'add_group_work_item',
            {'link': _link, 'reason': 'Add it'},
            calls: [
              ('addGroupWorkItem', {'groupId': 7, 'iid': 5}),
              ('get_group_work_item', {'groupId': 7, 'iid': 5}),
              (
                'updateGroupWorkItemState',
                {'groupId': 7, 'iid': 5, 'stateEvent': 'close'},
              ),
            ],
          ),
        )
        ..add((_) => answerTurn);
      // The user's own text naming the link is not an add either.
      await h.controller.send('Please look at $_link');
      expect(group.restReads + group.idReads + group.namespaceReads, 0);
      expect(h.controller.addedGroupWorkItems, isEmpty);
      expect(_uiAdded(h.controller), isEmpty);
      expect(_groupGrants(h.controller), isEmpty);
      expect(h.controller.proposals, isEmpty);
      final tools = h.controller.items.whereType<AiToolRunItem>().toList();
      expect(tools, hasLength(4));
      expect(
        tools.every(
          (item) =>
              item.status == AiToolRunStatus.failed ||
              item.status == AiToolRunStatus.skipped,
        ),
        isTrue,
      );
    });

    test('removal, a new conversation and a session change clear it', () async {
      _gate();
      final (h, _) = await _harness();
      await _add(h.controller);
      final capability = const G0eLedger().find('updateGroupWorkItemState')!;
      expect(
        scopeAdmits(
          h.controller.writePolicySnapshot!.scope,
          capability,
          _groupTarget(7),
        ),
        isTrue,
      );
      final revision = h.controller.writePolicySnapshot!.scopeRevision;
      h.controller.removeGroupWorkItem(h.controller.addedGroupWorkItems.single);
      expect(h.controller.addedGroupWorkItems, isEmpty);
      expect(_uiAdded(h.controller), isEmpty);
      expect(_groupGrants(h.controller), isEmpty);
      expect(
        h.controller.writePolicySnapshot!.scopeRevision,
        greaterThan(revision),
      );
      expect(
        scopeAdmits(
          h.controller.writePolicySnapshot!.scope,
          capability,
          _groupTarget(7),
        ),
        isFalse,
      );

      await _add(h.controller);
      h.controller.startNewConversation();
      await h.controller.recheck();
      expect(h.controller.phase, AiChatPhase.idle);
      expect(h.controller.addedGroupWorkItems, isEmpty);
      expect(_groupGrants(h.controller), isEmpty);

      await _add(h.controller);
      final candidate =
          await h.controller.checkGroupWorkItem(
                'https://example.com/gitlab/groups/team/sub/-/work_items/5',
              )
              as AiGroupWorkItemRefused;
      expect(candidate.reason, AiGroupWorkItemRefusal.alreadyInScope);
      await h.session.endSession();
      expect(h.controller.isDisposed, isTrue);
      expect(h.controller.offersGroupWorkItemAdd, isFalse);
      expect(h.controller.canAddGroupWorkItem, isFalse);
      expect(h.controller.addedGroupWorkItems, isEmpty);
    });

    test('an Inbox or read-only conversation does not offer it', () async {
      final (inbox, _) = await _harness(origin: const AiInboxOrigin());
      expect(inbox.controller.offersGroupWorkItemAdd, isFalse);
      expect(
        (await inbox.controller.checkGroupWorkItem(_link)
                as AiGroupWorkItemRefused)
            .reason,
        AiGroupWorkItemRefusal.unavailable,
      );
      // Lowering the ceiling to read only needs no new consent.
      final (readOnly, _) = await _harness();
      expect(readOnly.controller.offersGroupWorkItemAdd, isTrue);
      await readOnly.settings.setAutonomySettings(
        readOnly.account,
        ceiling: AiAutonomyLevel.readOnly,
        startingLevel: AiAutonomyLevel.readOnly,
      );
      await readOnly.controller.recheck();
      expect(readOnly.controller.offersGroupWorkItemAdd, isFalse);
      expect(readOnly.controller.canAddGroupWorkItem, isFalse);
    });
  });

  group('page', () {
    testWidgets('adds through the sheet only after the user confirms', (
      tester,
    ) async {
      final session = _FakeAddSession();
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      await _openSheet(tester);
      expect(
        find.text(l10n.aiAddGroupWorkItemIntro('https://example.com/gitlab')),
        findsOneWidget,
      );

      session.next = (_) =>
          const AiGroupWorkItemRefused(AiGroupWorkItemRefusal.projectLink);
      await tester.enterText(
        find.byKey(const ValueKey('ai-add-group-item-link')),
        'https://example.com/gitlab/team/app/-/issues/5',
      );
      await tester.pump();
      await _tapVisible(tester, const ValueKey('ai-add-group-item-check'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.aiAddGroupWorkItemProjectLink), findsOneWidget);
      expect(session.adds, isEmpty);

      session.next = (_) => AiGroupWorkItemCandidate(
        fullPath: 'team/sub',
        iid: 5,
        title: 'Fresh group item',
        endsConversationGrant: true,
      );
      await tester.enterText(
        find.byKey(const ValueKey('ai-add-group-item-link')),
        _link,
      );
      await tester.pump();
      expect(find.text(l10n.aiAddGroupWorkItemProjectLink), findsNothing);
      await _tapVisible(tester, const ValueKey('ai-add-group-item-check'));
      await tester.pumpAndSettle();
      expect(
        find.text('${isolated('team/sub')} ${isolated('#5')}'),
        findsOneWidget,
      );
      expect(find.text(isolated('Fresh group item')), findsOneWidget);
      expect(
        find.text(
          l10n.aiAddGroupWorkItemGrantEnds(l10n.aiLevelConversationGrant),
        ),
        findsOneWidget,
      );
      expect(session.adds, isEmpty);

      await _tapVisible(tester, const ValueKey('ai-add-group-item-confirm'));
      await tester.pumpAndSettle();
      expect(session.adds, hasLength(1));
      expect(
        find.byKey(const ValueKey('ai-add-group-item-sheet')),
        findsNothing,
      );
      expect(
        find.text(l10n.aiAddedGroupWorkItem('team/sub', 5)),
        findsOneWidget,
      );
      final chip = find.byKey(const ValueKey('ai-added-group-item-group:7:5'));
      expect(chip, findsOneWidget);
      expect(
        find.descendant(
          of: chip,
          matching: find.text('${isolated('team/sub')} ${isolated('#5')}'),
        ),
        findsOneWidget,
      );
      await tester.tap(
        find.descendant(
          of: chip,
          matching: find.byTooltip(l10n.aiRemoveGroupWorkItem),
        ),
      );
      await tester.pumpAndSettle();
      expect(session.added, isEmpty);
      expect(chip, findsNothing);
    });

    for (final stage in ['check', 'add']) {
      testWidgets('an unexpected error at $stage never leaves the sheet '
          'waiting and adds nothing', (tester) async {
        final session = _FakeAddSession()..throwOnAdd = stage == 'add';
        session.next = stage == 'check'
            ? (_) => throw StateError('synthetic $stage')
            : (_) => AiGroupWorkItemCandidate(
                fullPath: 'team/sub',
                iid: 5,
                title: 'Fresh group item',
                endsConversationGrant: false,
              );
        await tester.pumpWidget(_host(AiChatPage(session: session)));
        await tester.pumpAndSettle();
        await _openSheet(tester);
        await tester.enterText(
          find.byKey(const ValueKey('ai-add-group-item-link')),
          _link,
        );
        await tester.pump();
        await _tapVisible(tester, const ValueKey('ai-add-group-item-check'));
        await tester.pumpAndSettle();
        if (stage == 'add') {
          await _tapVisible(
            tester,
            const ValueKey('ai-add-group-item-confirm'),
          );
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const ValueKey('ai-add-group-item-busy')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('ai-add-group-item-sheet')),
          findsNothing,
        );
        expect(session.added, isEmpty);
        expect(
          find.byKey(const ValueKey('ai-added-group-item-group:7:5')),
          findsNothing,
        );
        // Shown through showFailure, on top where the user can see it.
        final failure = safeFailure(StateError('synthetic $stage'));
        final shown = find.text(
          l10n.titleThenDetail(failure.title, failure.detail),
        );
        expect(shown, findsOneWidget);
        expect(
          tester
              .hitTestOnBinding(tester.getCenter(shown))
              .path
              .any((entry) => entry.target == tester.renderObject(shown)),
          isTrue,
        );
      });
    }

    testWidgets('a GitLab failure keeps its ambiguous notice', (tester) async {
      final session = _FakeAddSession()
        ..next = (_) => const AiGroupWorkItemRefused(
          AiGroupWorkItemRefusal.readFailed,
          failure: ApiFailure(FailureKind.invisible),
          fullPath: 'team/sub',
          iid: 5,
        );
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pumpAndSettle();
      await _openSheet(tester);
      await tester.enterText(
        find.byKey(const ValueKey('ai-add-group-item-link')),
        _link,
      );
      await tester.pump();
      await _tapVisible(tester, const ValueKey('ai-add-group-item-check'));
      await tester.pumpAndSettle();
      final notice = find.byKey(const ValueKey('ai-add-group-item-failure'));
      expect(notice, findsOneWidget);
      expect(
        tester.widget<FailureNotice>(notice).error.kind,
        FailureKind.invisible,
      );
      expect(
        find.text(
          l10n.targetResource('${isolated('team/sub')} ${isolated('#5')}'),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('ai-add-group-item-confirm')),
        findsNothing,
      );
      expect(session.adds, isEmpty);
    });

    testWidgets('the action and removal wait while the conversation runs', (
      tester,
    ) async {
      final session = _FakeAddSession()
        ..added.add(
          const AiAddedGroupWorkItem(
            key: 'group:7:5',
            fullPath: 'team/sub',
            iid: 5,
            title: 'Fresh group item',
          ),
        )
        ..phase = AiChatPhase.running;
      await tester.pumpWidget(_host(AiChatPage(session: session)));
      await tester.pump();
      final chip = find.byKey(const ValueKey('ai-added-group-item-group:7:5'));
      expect(chip, findsOneWidget);
      // No remove button while the run may use the grant.
      expect(
        find.descendant(
          of: chip,
          matching: find.byTooltip(l10n.aiRemoveGroupWorkItem),
        ),
        findsNothing,
      );
      session.phase = AiChatPhase.idle;
      session.canAdd = false;
      session.notify();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-chat-menu')));
      await tester.pumpAndSettle();
      final item = tester.widget<PopupMenuItem<String>>(
        find.byKey(const ValueKey('ai-chat-add-group-item')),
      );
      expect(item.enabled, isFalse);
    });

    for (final tag in ['zh-TW', 'de', 'ar']) {
      testWidgets('the sheet and the strip fit $tag at 2x on 320 dp', (
        tester,
      ) async {
        final ratio = tester.view.devicePixelRatio;
        tester.view.physicalSize = const Size(320, 640) * ratio;
        addTearDown(tester.view.reset);
        if (tag != 'zh-TW') useLanguage(languageForTag(tag)!);
        addTearDown(() => useLanguage(languageForTag('zh-TW')!));
        final session = _FakeAddSession()
          ..next = (_) => AiGroupWorkItemCandidate(
            fullPath: 'a-rather-long-group/with-a-subgroup/and-another-level',
            iid: 123456,
            title: 'A long synthetic group work item title that wraps',
            endsConversationGrant: true,
          );
        await tester.pumpWidget(
          _host(AiChatPage(session: session), tag: tag, scale: 2),
        );
        await tester.pumpAndSettle();
        await _openSheet(tester);
        await tester.enterText(
          find.byKey(const ValueKey('ai-add-group-item-link')),
          _link,
        );
        await tester.pump();
        await _tapVisible(tester, const ValueKey('ai-add-group-item-check'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final confirm = find.byKey(const ValueKey('ai-add-group-item-confirm'));
        await tester.ensureVisible(confirm);
        await tester.pumpAndSettle();
        final rect = tester.getRect(confirm);
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(320));
        expect(rect.bottom, lessThanOrEqualTo(640));
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final chip = find.byKey(
          const ValueKey('ai-added-group-item-group:7:123456'),
        );
        expect(chip, findsOneWidget);
        final chipRect = tester.getRect(chip);
        expect(chipRect.left, greaterThanOrEqualTo(0));
        expect(chipRect.right, lessThanOrEqualTo(320));
        final send = tester.getRect(find.byKey(const ValueKey('ai-chat-send')));
        expect(send.right, lessThanOrEqualTo(320));
        expect(send.top, greaterThanOrEqualTo(chipRect.bottom));
      });
    }
  });
}

/// Scrolls the sheet to [key] first: at a large text size the buttons can
/// sit below the fold.
Future<void> _tapVisible(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('ai-chat-menu')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('ai-chat-add-group-item')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('ai-add-group-item-sheet')), findsOneWidget);
}

Widget _host(Widget child, {String tag = 'zh-TW', double scale = 1}) {
  final locale = switch (tag) {
    'ar' => const Locale('ar'),
    'de' => const Locale('de'),
    _ => const Locale('zh', 'TW'),
  };
  return MaterialApp(
    theme: appTheme(Brightness.light),
    locale: locale,
    supportedLocales: const [Locale('zh', 'TW'), Locale('ar'), Locale('de')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: child,
  );
}

/// The page's view of a conversation that can take group work items.
final class _FakeAddSession extends ChangeNotifier
    implements AiChatSession, AiScopeAddSession {
  @override
  final AiChatOrigin origin = const AiGeneralOrigin();
  @override
  String get id => 'u-add';
  @override
  List<AiChatItem> items = const [
    AiAssistantItem(text: 'Ready.', state: AiAssistantState.done),
  ];
  @override
  AiChatPhase phase = AiChatPhase.idle;
  @override
  AiChatBlocker get blocker => AiChatBlocker.none;
  @override
  List<AiProviderConfig> get providers => const [];
  @override
  AiProviderConfig? get provider => null;
  @override
  AiConsentContract? get consentRequest => null;
  @override
  UserFacingFailure? get failure => null;
  @override
  AiRunEnd? get lastEnd => null;
  @override
  bool get offerNewConversation => false;
  @override
  bool get historySaved => false;
  @override
  bool get reportNotSaved => false;
  @override
  bool get canSend => phase == AiChatPhase.idle;
  @override
  Future<void> send(String text) async {}
  @override
  void markReported(AiAssistantItem item) {}
  @override
  AiAssistantItem? currentOf(AiAssistantItem item) =>
      items.contains(item) ? item : null;
  @override
  Future<bool> refreshSecrets() async => true;
  @override
  void stop() {}
  @override
  void startNewConversation() {}
  @override
  Future<void> useProvider(String providerId) async {}
  @override
  Future<void> recheck() async {}
  @override
  set confirmCleartext(Future<bool> Function()? callback) {}
  @override
  String displaySafe(String text) => text;
  @override
  String draftSafe(String text) => text;

  bool canAdd = true;
  bool throwOnAdd = false;
  final added = <AiAddedGroupWorkItem>[];
  final adds = <AiGroupWorkItemCandidate>[];
  AiGroupWorkItemCheck Function(String link) next = (_) =>
      const AiGroupWorkItemRefused(AiGroupWorkItemRefusal.malformed);

  void notify() => notifyListeners();

  @override
  bool get offersGroupWorkItemAdd => true;
  @override
  String get scopeAddInstance => 'https://example.com/gitlab';
  @override
  bool get canAddGroupWorkItem => canAdd && phase == AiChatPhase.idle;
  @override
  List<AiAddedGroupWorkItem> get addedGroupWorkItems =>
      List.unmodifiable(added);
  @override
  Future<AiGroupWorkItemCheck> checkGroupWorkItem(String link) async =>
      next(link);
  @override
  Future<AiGroupWorkItemRefusal?> addGroupWorkItem(
    AiGroupWorkItemCandidate candidate,
  ) async {
    adds.add(candidate);
    if (throwOnAdd) throw StateError('synthetic add');
    added.add(
      AiAddedGroupWorkItem(
        key: 'group:7:${candidate.iid}',
        fullPath: candidate.fullPath,
        iid: candidate.iid,
        title: candidate.title,
      ),
    );
    notifyListeners();
    return null;
  }

  @override
  void removeGroupWorkItem(AiAddedGroupWorkItem item) {
    added.removeWhere((added) => added.key == item.key);
    notifyListeners();
  }
}
