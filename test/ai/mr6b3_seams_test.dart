import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_work_item_write_registry.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_status.dart';

import '../support/work_item_status_fixture.dart';

const _gid = WorkItemStatusFixture.projectItemId;
const _edit = ValueKey('work-item-status-edit');

AiWorkItemWriteRegistry _registry(
  WorkItemStatusFixture fixture, {
  GitLabApi? api,
  String? accountKey,
  String? instanceKey,
  int generation = 12,
  bool Function()? isCurrent,
}) {
  final client = api ?? fixture.api;
  return createAiWorkspaceWorkItemWriteRegistry(
    api: client,
    accountKey: accountKey ?? fixture.account.key,
    instanceKey: instanceKey ?? client.instance.key,
    generation: generation,
    isCurrent: isCurrent ?? () => true,
  );
}

void main() {
  testWidgets('AI Dates lease blocks the real UI STATUS control', (
    tester,
  ) async {
    final fixture = WorkItemStatusFixture();
    addTearDown(fixture.closeAll);
    final registry = _registry(fixture);
    final lease = registry.tryStart(_gid, AiWorkItemWriteKind.dates);
    expect(lease, isNotNull);
    expect(
      WorkItemStatusWriteRegistry.instance.isActive(fixture.api, _gid),
      isTrue,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkItemStatusControl(
            account: fixture.account,
            api: fixture.api,
            detail: fixture.detail(group: false),
            sessionGeneration: 12,
            onSaved: (_) {},
          ),
        ),
      ),
    );
    expect(tester.widget<TextButton>(find.byKey(_edit)).onPressed, isNull);

    registry.settle(lease!, AiWorkItemWriteResult.notSent, null);
    await tester.pump();
    expect(
      WorkItemStatusWriteRegistry.instance.isActive(fixture.api, _gid),
      isFalse,
    );
    expect(tester.widget<TextButton>(find.byKey(_edit)).onPressed, isNotNull);
  });

  test('leases are unique per API and item but isolated by API identity', () {
    final fixture = WorkItemStatusFixture();
    addTearDown(fixture.closeAll);
    final firstApi = fixture.api;
    final first = _registry(fixture);
    final sameApiOtherAccount = _registry(
      fixture,
      accountKey: '${fixture.api.instance.key}#99',
    );
    final otherApi = fixture.replaceApi();
    final isolated = _registry(
      fixture,
      api: otherApi,
      accountKey: '${otherApi.instance.key}#99',
    );
    final uiToken = Object();

    expect(
      WorkItemStatusWriteRegistry.instance.tryStartExternal(
        firstApi,
        _gid,
        uiToken,
      ),
      isTrue,
    );
    expect(first.tryStart(_gid, AiWorkItemWriteKind.dates), isNull);
    WorkItemStatusWriteRegistry.instance.settleExternal(
      firstApi,
      _gid,
      token: uiToken,
      mutationSent: false,
    );

    final held = first.tryStart(_gid, AiWorkItemWriteKind.health);
    expect(held, isNotNull);
    expect(
      sameApiOtherAccount.tryStart(_gid, AiWorkItemWriteKind.status),
      isNull,
    );
    final separate = isolated.tryStart(_gid, AiWorkItemWriteKind.health);
    expect(separate, isNotNull);

    first.settle(held!, AiWorkItemWriteResult.notSent, null);
    isolated.settle(separate!, AiWorkItemWriteResult.notSent, null);
  });

  test('Dates releases its STATUS reservation without changing STATUS freshness', () {
    for (final seedStatus in [false, true]) {
      for (final result in AiWorkItemWriteResult.values) {
        final fixture = WorkItemStatusFixture();
        addTearDown(fixture.closeAll);
        final registry = _registry(fixture);
        final status = WorkItemStatusWriteRegistry.instance;
        final earlier = DateTime.utc(2026, 10, 22);
        final newer = DateTime.utc(2026, 10, 23);
        if (seedStatus) {
          final lease = registry.tryStart(_gid, AiWorkItemWriteKind.status)!;
          registry.settle(lease, AiWorkItemWriteResult.confirmed, earlier);
        }
        final terminal = status.terminal(fixture.api, _gid);
        final lease = registry.tryStart(_gid, AiWorkItemWriteKind.dates)!;
        expect(status.isActive(fixture.api, _gid), isTrue);
        registry.settle(lease, result, newer);
        expect(status.isActive(fixture.api, _gid), isFalse);
        expect(status.terminal(fixture.api, _gid), same(terminal));
        final dates = aiWorkspaceWriteFreshnessForTesting(
          fixture.api, _gid, AiWorkItemWriteKind.dates,
        );
        expect(dates, switch (result) {
          AiWorkItemWriteResult.notSent => null,
          AiWorkItemWriteResult.confirmed =>
            (revision: newer, confirmed: true, knownNotApplied: false),
          AiWorkItemWriteResult.uncertain =>
            (revision: null, confirmed: false, knownNotApplied: false),
        });
      }
    }
  });

  test('external STATUS ownership ignores wrong and stale settle tokens', () {
    final fixture = WorkItemStatusFixture();
    addTearDown(fixture.closeAll);
    final registry = WorkItemStatusWriteRegistry.instance;
    final first = Object();
    final second = Object();
    final wrong = Object();

    expect(registry.tryStartExternal(fixture.api, _gid, first), isTrue);
    registry.settleExternal(
      fixture.api,
      _gid,
      token: wrong,
      mutationSent: false,
    );
    expect(registry.isActive(fixture.api, _gid), isTrue);
    registry.settleExternal(
      fixture.api,
      _gid,
      token: first,
      mutationSent: false,
    );

    expect(registry.tryStartExternal(fixture.api, _gid, second), isTrue);
    registry.settleExternal(
      fixture.api,
      _gid,
      token: first,
      mutationSent: true,
      confirmedRevision: DateTime.utc(2026, 10, 23),
    );
    expect(registry.isActive(fixture.api, _gid), isTrue);
    expect(registry.terminal(fixture.api, _gid), isNull);
    registry.settleExternal(
      fixture.api,
      _gid,
      token: second,
      mutationSent: false,
    );
    expect(registry.isActive(fixture.api, _gid), isFalse);
  });

  test('stale or mismatched owners fail closed and cannot reserve', () {
    final fixture = WorkItemStatusFixture();
    addTearDown(fixture.closeAll);
    var current = true;
    final stale = _registry(fixture, isCurrent: () => current);
    current = false;
    expect(stale.isActive(_gid), isTrue);
    expect(stale.tryStart(_gid, AiWorkItemWriteKind.status), isNull);

    final wrongInstance = _registry(
      fixture,
      instanceKey: 'https://wrong.example',
    );
    expect(wrongInstance.isActive(_gid), isTrue);
    expect(wrongInstance.tryStart(_gid, AiWorkItemWriteKind.dates), isNull);
    final wrongGeneration = _registry(fixture, generation: -1);
    expect(wrongGeneration.isActive(_gid), isTrue);
    expect(wrongGeneration.tryStart(_gid, AiWorkItemWriteKind.health), isNull);
    final wrongAccount = _registry(fixture, accountKey: 'unbound-account');
    expect(wrongAccount.isActive(_gid), isTrue);
    final throwing = _registry(
      fixture,
      isCurrent: () => throw StateError('stale owner'),
    );
    expect(throwing.isActive(_gid), isTrue);
    expect(throwing.tryStart(_gid, AiWorkItemWriteKind.status), isNull);
    final malformedGid = _registry(fixture);
    expect(malformedGid.isActive('gid://gitlab/WorkItem/0'), isTrue);
    expect(
      malformedGid.tryStart(
        'gid://gitlab/WorkItem/0',
        AiWorkItemWriteKind.status,
      ),
      isNull,
    );

    final closedFixture = WorkItemStatusFixture();
    closedFixture.api.close();
    final closed = _registry(closedFixture);
    expect(closed.isActive(_gid), isTrue);
    expect(closed.tryStart(_gid, AiWorkItemWriteKind.status), isNull);
    closedFixture.closeAll();
  });

  test(
    'reservation is reentrant-safe and a stale owner still releases once',
    () {
      final fixture = WorkItemStatusFixture();
      addTearDown(fixture.closeAll);
      var current = true;
      final registry = _registry(fixture, isCurrent: () => current);
      final peer = _registry(fixture);
      AiWorkItemWriteLease? raced;
      void listener() {
        raced ??= peer.tryStart(_gid, AiWorkItemWriteKind.health);
      }

      WorkItemStatusWriteRegistry.instance.addListener(listener);
      addTearDown(
        () => WorkItemStatusWriteRegistry.instance.removeListener(listener),
      );
      final lease = registry.tryStart(_gid, AiWorkItemWriteKind.dates);
      expect(lease, isNotNull);
      expect(raced, isNull);

      current = false;
      registry.settle(lease!, AiWorkItemWriteResult.notSent, null);
      registry.settle(lease, AiWorkItemWriteResult.uncertain, null);
      expect(
        WorkItemStatusWriteRegistry.instance.isActive(fixture.api, _gid),
        isFalse,
      );
      expect(
        aiWorkspaceWriteFreshnessForTesting(
          fixture.api,
          _gid,
          AiWorkItemWriteKind.dates,
        ),
        isNull,
      );
    },
  );

  test('notSent, confirmed, uncertain, and one-settle remain distinct', () {
    final fixture = WorkItemStatusFixture();
    addTearDown(fixture.closeAll);
    final registry = _registry(fixture);
    final newer = DateTime.utc(2026, 10, 23, 12);
    final older = DateTime.utc(2026, 10, 23, 11);

    final unsent = registry.tryStart(_gid, AiWorkItemWriteKind.dates)!;
    registry.settle(unsent, AiWorkItemWriteResult.notSent, newer);
    expect(
      aiWorkspaceWriteFreshnessForTesting(
        fixture.api,
        _gid,
        AiWorkItemWriteKind.dates,
      ),
      isNull,
    );

    final confirmed = registry.tryStart(_gid, AiWorkItemWriteKind.dates)!;
    registry.settle(confirmed, AiWorkItemWriteResult.confirmed, newer);
    expect(
      aiWorkspaceWriteFreshnessForTesting(
        fixture.api,
        _gid,
        AiWorkItemWriteKind.dates,
      ),
      (revision: newer, confirmed: true, knownNotApplied: false),
    );
    registry.settle(confirmed, AiWorkItemWriteResult.uncertain, null);
    expect(registry.isActive(_gid), isFalse);

    final olderConfirmed = registry.tryStart(_gid, AiWorkItemWriteKind.dates)!;
    registry.settle(olderConfirmed, AiWorkItemWriteResult.confirmed, older);
    expect(
      aiWorkspaceWriteFreshnessForTesting(
        fixture.api,
        _gid,
        AiWorkItemWriteKind.dates,
      )?.revision,
      newer,
    );

    final uncertain = registry.tryStart(_gid, AiWorkItemWriteKind.dates)!;
    registry.settle(uncertain, AiWorkItemWriteResult.uncertain, older);
    expect(
      aiWorkspaceWriteFreshnessForTesting(
        fixture.api,
        _gid,
        AiWorkItemWriteKind.dates,
      ),
      (revision: newer, confirmed: false, knownNotApplied: false),
    );
  });

  test(
    'status and health preserve floors and health refuses a second start',
    () {
      final fixture = WorkItemStatusFixture();
      addTearDown(fixture.closeAll);
      final registry = _registry(fixture);
      final peer = _registry(fixture);
      final newer = DateTime.utc(2026, 10, 23, 14);
      final older = DateTime.utc(2026, 10, 23, 13);

      for (final kind in [
        AiWorkItemWriteKind.status,
        AiWorkItemWriteKind.health,
      ]) {
        final confirmed = registry.tryStart(_gid, kind)!;
        if (kind == AiWorkItemWriteKind.health) {
          expect(peer.tryStart(_gid, kind), isNull);
        }
        registry.settle(confirmed, AiWorkItemWriteResult.confirmed, newer);
        final oldLease = registry.tryStart(_gid, kind)!;
        registry.settle(oldLease, AiWorkItemWriteResult.confirmed, older);
        expect(
          aiWorkspaceWriteFreshnessForTesting(
            fixture.api,
            _gid,
            kind,
          )?.revision,
          newer,
        );
        final uncertain = registry.tryStart(_gid, kind)!;
        registry.settle(uncertain, AiWorkItemWriteResult.uncertain, null);
        expect(aiWorkspaceWriteFreshnessForTesting(fixture.api, _gid, kind), (
          revision: newer,
          confirmed: false,
          knownNotApplied: false,
        ));
      }
    },
  );
}
