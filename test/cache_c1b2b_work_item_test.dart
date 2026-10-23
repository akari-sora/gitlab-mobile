import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_types.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  testWidgets(
    '§3.4 fixture MR detail with approvals cache warm viewport 412x900 clock +5s completion settled: second open reads each endpoint 0 times',
    (tester) async {
      final fixture = _WorkItemFixture.mr();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      expect(fixture.detailReads, 1, reason: 'GET work item detail');
      expect(fixture.approvalsReads, 1, reason: 'GET approvals');
      _expectDetailUri(fixture);
      _expectApprovalsUri(fixture);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      expect(fixture.detailReads, 1);
      expect(fixture.approvalsReads, 1);
      final state = tester.state<WorkItemPageState>(find.byType(WorkItemPage));
      expect(state.data?['title'], 'Synthetic MR');
      expect(state.stale, isFalse);
      expect(state.revalidating, isFalse);
      expect(state.fetchedAt, isNotNull);
    },
  );

  testWidgets(
    '§3.4 fixture MR detail with approvals cache warm viewport 412x900 clock +5s completion explicit refresh: detail and approvals each read fresh once',
    (tester) async {
      final fixture = _WorkItemFixture.mr();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      expect(fixture.detailReads, 1);
      expect(fixture.approvalsReads, 1);
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      await tester.tap(find.byIcon(Icons.refresh));
      await settleWorkspace(tester);
      expect(fixture.detailReads, 2, reason: 'explicit refresh re-reads detail');
      expect(fixture.approvalsReads, 2, reason: 'explicit refresh re-reads approvals');
    },
  );

  testWidgets(
    '§3.4 fixture MR detail changes cache stale viewport 412x900 clock +31s completion background response: stale then one fresh background read',
    (tester) async {
      final fixture = _WorkItemFixture.mr();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 31));
      final pending = Completer<ResponseBody>();
      fixture.nextDetail = pending;
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await pumpUntil(tester, () => fixture.detailReads == 2);
      final state = tester.state<WorkItemPageState>(find.byType(WorkItemPage));
      expect(state.data?['title'], 'Synthetic MR');
      expect(state.stale, isTrue);
      expect(state.revalidating, isTrue);
      expect(fixture.detailReads, 2);
      pending.complete(jsonResponse(fixture.mrDetail(title: 'Updated MR')));
      await settleWorkspace(tester);
      expect(state.data?['title'], 'Updated MR');
      expect(state.stale, isFalse);
      expect(state.revalidating, isFalse);
      expect(fixture.detailReads, 2);
    },
  );

  testWidgets(
    '§3.4 fixture issue detail with related links cache warm viewport 412x900 clock +5s completion settled: second open reads each endpoint 0 times',
    (tester) async {
      final fixture = _WorkItemFixture.issue();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      expect(fixture.detailReads, 1, reason: 'GET issue detail');
      expect(fixture.relatedReads, 1, reason: 'GET related_merge_requests');
      expect(fixture.linksReads, 1, reason: 'GET links');
      _expectIssueDetailUri(fixture);
      _expectRelatedUri(fixture);
      _expectLinksUri(fixture);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      expect(fixture.detailReads, 1);
      expect(fixture.relatedReads, 1);
      expect(fixture.linksReads, 1);
    },
  );

  testWidgets(
    '§3.4 fixture MR approvals 404 cache empty viewport 412x900 clock fixed completion settled: cold sub-resource 404 keeps the parent',
    (tester) async {
      final fixture = _WorkItemFixture.mr()..approvalsStatus = 404;
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      final state = tester.state<WorkItemPageState>(find.byType(WorkItemPage));
      expect(state.data?['title'], 'Synthetic MR');
      expect(state.readError, isNull);
      expect(fixture.detailReads, 1);
      expect(fixture.approvalsReads, 1);
    },
  );

  testWidgets(
    '§3.4 fixture MR approvals 403 after success viewport 412x900 clock +5s completion explicit refresh: revoked approvals withdraw the card but keep the MR',
    (tester) async {
      final fixture = _WorkItemFixture.mr();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      expect(find.byIcon(Icons.rule_outlined), findsOneWidget, reason: 'approvals card shown');
      fixture.approvalsStatus = 403;
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      await tester.tap(find.byIcon(Icons.refresh));
      await settleWorkspace(tester);
      expect(fixture.detailReads, 2, reason: 'explicit refresh re-reads detail');
      expect(fixture.approvalsReads, 2, reason: 'explicit refresh re-reads approvals');
      expect(find.byIcon(Icons.rule_outlined), findsNothing, reason: 'revoked approvals card withdrawn');
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
      final state = tester.state<WorkItemPageState>(find.byType(WorkItemPage));
      expect(state.data?['title'], 'Synthetic MR', reason: 'parent detail kept');
      expect(state.readError, isNull);
    },
  );

  testWidgets(
    '§3.4 fixture MR approvals change cache stale viewport 412x900 clock +31s completion settled: stale reopen re-reads approvals and updates the card',
    (tester) async {
      final fixture = _WorkItemFixture.mr();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      expect(find.byIcon(Icons.rule_outlined), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 31));
      fixture.nextApprovals = fixture.approvalsJson(
        approvedBy: [
          {'user': {'id': 7, 'username': 'developer'}},
        ],
        required: 1,
        left: 0,
      );
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      expect(fixture.detailReads, 2, reason: 'detail revalidated in background');
      expect(fixture.approvalsReads, 2, reason: 'stale approvals re-read from network');
      expect(find.byIcon(Icons.rule_outlined), findsNothing);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget, reason: 'threshold now reached');
    },
  );

  testWidgets(
    '§3.4 fixture MR merge checks approvals cache ages while detail revalidates viewport 412x900 clock +31s completion: merge checks independently re-reads stale approvals',
    (tester) async {
      final fixture = _WorkItemFixture.mr();
      addTearDown(fixture.close);
      _viewport(tester);
      const detailPath = ['projects', '42', 'merge_requests', '12'];
      const approvalsPath = [...detailPath, 'approvals'];
      await tester.runAsync(() async {
        await fixture.api.cachedRecord(detailPath);
        await fixture.api.cachedRecord(approvalsPath);
      });
      expect(fixture.detailReads, 1, reason: 'seed detail cache once');
      expect(fixture.approvalsReads, 1, reason: 'seed approvals cache once');

      fixture.now = fixture.now.add(const Duration(seconds: 31));
      await tester.runAsync(
        () => fixture.api.cachedRecord(approvalsPath, fresh: true),
      );
      expect(
        fixture.approvalsReads,
        2,
        reason: 'keep approvals fresh while detail is stale',
      );
      final pendingDetail = Completer<ResponseBody>();
      fixture.nextDetail = pendingDetail;
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await pumpUntil(
        tester,
        () =>
            tester
                .state<WorkItemPageState>(find.byType(WorkItemPage))
                .revalidating &&
            fixture.detailReads == 2,
        description: 'stale detail sends its background revalidation',
      );
      expect(
        fixture.detailReads,
        2,
        reason: 'one held background detail request',
      );
      expect(
        fixture.approvalsReads,
        2,
        reason:
            'the parent approvals read used the fresh cache and sent no HTTP',
      );
      await tester.tap(find.byType(Tab).last);
      await tester.pump();
      expect(
        fixture.approvalsReads,
        2,
        reason: 'initial merge checks read also used the fresh approvals cache',
      );

      fixture.now = fixture.now.add(const Duration(seconds: 31));
      fixture.nextApprovals = fixture.approvalsJson(
        approvedBy: [
          {
            'user': {'id': 9, 'username': 'fresh-reviewer'},
          },
        ],
        required: 1,
        left: 0,
      );
      pendingDetail.complete(
        jsonResponse(fixture.mrDetail(title: 'Revalidated MR')),
      );
      await pumpUntil(
        tester,
        () => fixture.approvalsReads == 3,
        description: 'merge checks independently re-reads approvals older than 30 seconds',
      );
      await settleWorkspace(tester);
      expect(fixture.detailReads, 2);
      expect(
        fixture.approvalsReads,
        3,
        reason: 'exactly one merge checks stale-cache read',
      );
      expect(find.text('@fresh-reviewer'), findsOneWidget);
      _expectDetailUri(fixture);
      _expectApprovalsUri(fixture);
    },
  );

  testWidgets(
    '§3.4 fixture issue related change cache stale viewport 412x900 clock +45s completion settled: stale reopen re-reads related and links and shows the new link',
    (tester) async {
      final fixture = _WorkItemFixture.issue();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      expect(fixture.relatedReads, 1);
      expect(fixture.linksReads, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 45));
      fixture.intercept = (request) =>
          request.uri.path == '/gitlab/api/v4/projects/42/issues/1/related_merge_requests'
          ? jsonResponse([
              {'id': 99, 'iid': 5, 'project_id': 42, 'title': 'Linked later', 'state': 'opened'},
            ])
          : null;
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      expect(fixture.detailReads, 2, reason: 'detail revalidated in background');
      expect(fixture.relatedReads, 2, reason: 'stale related re-read from network');
      expect(fixture.linksReads, 2, reason: 'stale links re-read from network');
      await tester.scrollUntilVisible(
        find.textContaining('Linked later'),
        400,
        scrollable: find.descendant(
          of: find.descendant(of: find.byType(TabBarView), matching: find.byType(ListView)),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.textContaining('Linked later'), findsOneWidget);
    },
  );

  testWidgets(
    '§3.4 fixture issue related cache warm viewport 412x900 clock +5s completion explicit refresh: refresh button refreshes the related list too',
    (tester) async {
      final fixture = _WorkItemFixture.issue();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      expect(fixture.relatedReads, 1);
      expect(fixture.linksReads, 1);
      fixture.now = fixture.now.add(const Duration(seconds: 5));
      fixture.intercept = (request) =>
          request.uri.path == '/gitlab/api/v4/projects/42/issues/1/related_merge_requests'
          ? jsonResponse([
              {'id': 99, 'iid': 5, 'project_id': 42, 'title': 'Linked on refresh', 'state': 'opened'},
            ])
          : null;
      await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.refresh)));
      await settleWorkspace(tester);
      expect(fixture.detailReads, 2, reason: 'explicit refresh re-reads detail');
      expect(fixture.relatedReads, 2, reason: 'explicit refresh drives the related list');
      expect(fixture.linksReads, 2, reason: 'explicit refresh drives the links list');
      await tester.scrollUntilVisible(
        find.textContaining('Linked on refresh'),
        400,
        scrollable: find.descendant(
          of: find.descendant(of: find.byType(TabBarView), matching: find.byType(ListView)),
          matching: find.byType(Scrollable),
        ),
      );
      expect(find.textContaining('Linked on refresh'), findsOneWidget);
    },
  );
  testWidgets(
    '§3.4 fixture issue related 404 cache empty viewport 412x900 clock fixed completion settled: cold sub-resource 404 keeps the parent',
    (tester) async {
      final fixture = _WorkItemFixture.issue()..relatedStatus = 404;
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      final state = tester.state<WorkItemPageState>(find.byType(WorkItemPage));
      expect(state.data?['title'], 'Synthetic issue');
      expect(state.readError, isNull);
      expect(fixture.detailReads, 1);
    },
  );

  testWidgets(
    '§3.4 fixture issue detail cache stale viewport offstage then resumed clock +31s completion background response: pauses and resumes',
    (tester) async {
      final fixture = _WorkItemFixture.issue();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.page()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 31));
      await tester.pumpWidget(
        workspaceHost(
          TickerMode(enabled: false, child: fixture.page(key: const ValueKey('work-item'))),
        ),
      );
      await pumpUntil(
        tester,
        () => tester.state<WorkItemPageState>(find.byType(WorkItemPage)).data != null,
      );
      final state = tester.state<WorkItemPageState>(find.byType(WorkItemPage));
      expect(state.data?['title'], 'Synthetic issue');
      expect(state.stale, isTrue);
      expect(state.revalidating, isFalse);
      expect(fixture.detailReads, 1);
      final pending = Completer<ResponseBody>();
      fixture.nextDetail = pending;
      await tester.pumpWidget(
        workspaceHost(TickerMode(enabled: true, child: fixture.page(key: const ValueKey('work-item')))),
      );
      await pumpUntil(tester, () => fixture.detailReads == 2);
      expect(state.revalidating, isTrue);
      pending.complete(jsonResponse(fixture.issueDetail(title: 'Resumed issue')));
      await settleWorkspace(tester);
      expect(state.data?['title'], 'Resumed issue');
      expect(state.stale, isFalse);
      expect(state.revalidating, isFalse);
    },
  );

  testWidgets(
    '§3.4 fixture issue detail queued background hidden viewport 412x900 clock +31s completion no HTTP: same hidden state sends nothing until visible',
    (tester) async {
      final fixture = _WorkItemFixture.issue();
      addTearDown(fixture.close);
      _viewport(tester);
      Widget host(bool on) => workspaceHost(TickerMode(enabled: on, child: fixture.page(key: const ValueKey('same'))));
      await tester.pumpWidget(host(true));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 31));
      final occupied = Completer<void>();
      fixture.intercept = (request) =>
          request.uri.path.contains('/projects/8/issues/') ? occupied.future.then((_) => jsonResponse({'id': 1})) : null;
      final blockers = [
        for (var id = 1; id <= 4; id++)
          fixture.api.cachedRecord(['projects', '8', 'issues', '$id'], fresh: true, background: true),
      ];
      await pumpUntil(tester, () => fixture.blockerReads == 4, description: 'background slots occupied');
      await tester.pumpWidget(host(true));
      await pumpUntil(
        tester,
        () => tester.state<WorkItemPageState>(find.byType(WorkItemPage)).revalidating,
        description: 'stale reopen queues a background revalidation',
      );
      final state = tester.state<WorkItemPageState>(find.byType(WorkItemPage));
      await tester.pumpWidget(host(false));
      expect(identical(tester.state<WorkItemPageState>(find.byType(WorkItemPage)), state), isTrue, reason: 'same state kept while hidden');
      occupied.complete();
      await settleNetworkWidgets(tester);
      await tester.runAsync(() => Future.wait(blockers));
      expect(fixture.detailReads, 1, reason: 'hidden queued read must send no HTTP');
      await tester.pumpWidget(host(true));
      expect(identical(tester.state<WorkItemPageState>(find.byType(WorkItemPage)), state), isTrue, reason: 'same state resumes');
      await settleWorkspace(tester);
      expect(fixture.detailReads, 2, reason: 'visibility resumes exactly one read');
    },
  );

  for (final background in [false, true]) {
    for (final sustained in [false, true]) {
      testWidgets(
        '§3.4 fixture issue detail ${background ? 'background' : 'cold'} supersedes ${sustained ? 'leave retryable failure' : 'recover after writes stop'} viewport 412x900 clock fixed completion bounded',
        (tester) async {
          final fixture = _WorkItemFixture.issue();
          addTearDown(fixture.close);
          _viewport(tester);
          if (background) {
            await tester.pumpWidget(workspaceHost(fixture.page()));
            await settleWorkspace(tester);
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
            fixture.now = fixture.now.add(const Duration(seconds: 31));
          }
          final responses = List.generate(sustained ? 6 : 4, (_) => Completer<ResponseBody>());
          var reads = 0;
          fixture.intercept = (request) {
            if (request.method != 'GET' || request.uri.path != fixture.detailPath) return null;
            final index = reads++;
            return index < responses.length ? responses[index].future : null;
          };
          await tester.pumpWidget(workspaceHost(fixture.page()));
          for (var index = 0; index < responses.length; index++) {
            await pumpUntil(tester, () => reads == index + 1, description: 'next bounded read after superseding write');
            await tester.runAsync(() => fixture.api.updateIssue(42, 1, {'title': 'synthetic write $index'}));
            responses[index].complete(jsonResponse(fixture.issueDetail(title: 'Updated $index')));
          }
          await pumpUntil(
            tester,
            () => sustained
                ? (background
                      ? tester.state<WorkItemPageState>(find.byType(WorkItemPage)).backgroundFailure != null
                      : tester.state<WorkItemPageState>(find.byType(WorkItemPage)).readError != null)
                : reads >= 5 &&
                      tester.state<WorkItemPageState>(find.byType(WorkItemPage)).data != null &&
                      !tester.state<WorkItemPageState>(find.byType(WorkItemPage)).stale &&
                      !tester.state<WorkItemPageState>(find.byType(WorkItemPage)).revalidating,
            description: 'quiet recovery finishes or reports bounded failure',
          );
          await settleNetworkWidgets(tester);
          final state = tester.state<WorkItemPageState>(find.byType(WorkItemPage));
          if (!sustained) {
            expect(reads, 5);
            expect(state.data, isNotNull);
            expect(state.readError, isNull);
            expect(state.backgroundFailure, isNull);
            expect(state.stale, isFalse);
          } else {
            expect(reads, 6, reason: 'recovery must be bounded');
            if (background) {
              expect(state.data, isNotNull);
              expect(state.backgroundFailure, FailureKind.cancelled);
            } else {
              expect(state.data, isNull);
              expect(state.readError?.kind, FailureKind.cancelled);
              final notice = tester.widget<FailureNotice>(find.byType(FailureNotice).first);
              expect(notice.onRetry, isNotNull);
              fixture.intercept = null;
              notice.onRetry!();
              await pumpUntil(tester, () => tester.state<WorkItemPageState>(find.byType(WorkItemPage)).data != null);
              await settleNetworkWidgets(tester);
            }
          }
          expect(state.revalidating, isFalse);
        },
      );
    }
  }

  for (final sustained in [false, true]) {
    testWidgets(
      '§3.4 fixture MR approvals cold supersedes ${sustained ? 'leave fail-soft without a card' : 'recover after writes stop'} viewport 412x900 clock fixed completion bounded',
      (tester) async {
        final fixture = _WorkItemFixture.mr();
        addTearDown(fixture.close);
        _viewport(tester);
        final responses = List.generate(sustained ? 6 : 4, (_) => Completer<ResponseBody>());
        var reads = 0;
        fixture.intercept = (request) {
          if (request.method != 'GET' || request.uri.path != _WorkItemFixture.approvalsPath) return null;
          final index = reads++;
          return index < responses.length ? responses[index].future : null;
        };
        await tester.pumpWidget(workspaceHost(fixture.page()));
        for (var index = 0; index < responses.length; index++) {
          await pumpUntil(tester, () => reads == index + 1, description: 'next bounded approvals read after superseding write');
          await tester.runAsync(() => fixture.api.updateMergeRequest(42, 12, {'title': 'synthetic write $index'}));
          responses[index].complete(jsonResponse(fixture.approvalsJson()));
        }
        if (!sustained) {
          await pumpUntil(
            tester,
            () => find.byIcon(Icons.rule_outlined).evaluate().isNotEmpty,
            description: 'approvals card recovers after writes stop',
          );
          await settleNetworkWidgets(tester);
          expect(reads, 5, reason: 'superseded approvals read is retried, not swallowed');
          expect(find.byIcon(Icons.rule_outlined), findsOneWidget);
          expect(tester.state<WorkItemPageState>(find.byType(WorkItemPage)).readError, isNull);
        } else {
          await pumpUntil(
            tester,
            () =>
                reads >= 6 &&
                tester.state<WorkItemPageState>(find.byType(WorkItemPage)).data != null &&
                !tester.state<WorkItemPageState>(find.byType(WorkItemPage)).revalidating,
            description: 'bounded approvals retry ends fail-soft',
          );
          await settleNetworkWidgets(tester);
          expect(reads, 6, reason: 'approvals recovery must be bounded');
          final state = tester.state<WorkItemPageState>(find.byType(WorkItemPage));
          expect(state.data?['title'], 'Synthetic MR', reason: 'parent detail kept');
          expect(state.readError, isNull, reason: 'transient approvals failure stays fail-soft');
          expect(find.byIcon(Icons.rule_outlined), findsNothing, reason: 'no card without approvals data');
        }
      },
    );
  }

  testWidgets(
    '§3.4 fixture MR detail failed refresh keeps error viewport 412x900 clock +31s completion settled: hidden toggle does not revalidate over a visible error',
    (tester) async {
      final fixture = _WorkItemFixture.mr();
      addTearDown(fixture.close);
      _viewport(tester);
      Widget host(bool on) => workspaceHost(TickerMode(enabled: on, child: fixture.page(key: const ValueKey('guard'))));
      await tester.pumpWidget(host(true));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 31));
      final held = Completer<ResponseBody>();
      fixture.nextDetail = held;
      await tester.pumpWidget(host(true));
      await pumpUntil(
        tester,
        () => fixture.detailReads == 2,
        description: 'stale reopen sends one background revalidation',
      );
      expect(
        tester.state<WorkItemPageState>(find.byType(WorkItemPage)).revalidating,
        isTrue,
      );
      fixture.intercept = (request) =>
          request.method == 'GET' && request.uri.path == fixture.detailPath ? jsonResponse({}, status: 500) : null;
      await tester.tap(find.byIcon(Icons.refresh));
      await pumpUntil(
        tester,
        () => fixture.detailReads == 3,
        description: 'explicit refresh sends while stale',
      );
      held.complete(jsonResponse(fixture.mrDetail()));
      await settleWorkspace(tester);
      expect(fixture.detailReads, 3, reason: 'explicit refresh sent while stale');
      expect(find.byType(FailureNotice), findsWidgets, reason: 'failed refresh surfaces the error');
      final state = tester.state<WorkItemPageState>(find.byType(WorkItemPage));
      expect(state.data?['title'], 'Synthetic MR', reason: 'old data kept');
      await tester.pumpWidget(host(false));
      expect(identical(tester.state<WorkItemPageState>(find.byType(WorkItemPage)), state), isTrue);
      await tester.pumpWidget(host(true));
      expect(identical(tester.state<WorkItemPageState>(find.byType(WorkItemPage)), state), isTrue);
      await settleNetworkWidgets(tester);
      expect(fixture.detailReads, 3, reason: 'hidden toggle must not revalidate over a visible error');
      fixture.intercept = null;
      final notice = tester.widget<FailureNotice>(find.byType(FailureNotice).first);
      expect(notice.onRetry, isNotNull);
      notice.onRetry!();
      await settleWorkspace(tester);
      expect(fixture.detailReads, 4, reason: 'retry re-reads fresh');
      expect(find.byType(FailureNotice), findsNothing, reason: 'error clears on success');
    },
  );

  testWidgets(
    '§3.4 fixture issue detail cold dropped viewport 412x900 clock fixed completion retry notice: dropped cold read shows retry and recovers',
    (tester) async {
      final fixture = _WorkItemFixture.issue();
      addTearDown(fixture.close);
      _viewport(tester);
      var admitted = true;
      var refusals = 0;
      Future<T> fenced<T>(Future<T> Function() body) => CachedRead.run(
        body,
        mayStart: () {
          if (!admitted) refusals++;
          return admitted;
        },
      );
      await fenced(() async {
        admitted = false;
        await tester.pumpWidget(workspaceHost(fixture.page()));
        await settleWorkspace(tester);
        expect(refusals, greaterThan(0));
        expect(fixture.detailReads, 0);
        final state = tester.state<WorkItemPageState>(find.byType(WorkItemPage));
        expect(state.data, isNull);
        expect(state.readError?.kind, FailureKind.cancelled);
        expect(find.byType(FailureNotice), findsWidgets);
        admitted = true;
        final notice = tester.widget<FailureNotice>(find.byType(FailureNotice).first);
        expect(notice.onRetry, isNotNull);
        notice.onRetry!();
        await pumpUntil(tester, () => tester.state<WorkItemPageState>(find.byType(WorkItemPage)).data != null);
        await settleWorkspace(tester);
        expect(tester.state<WorkItemPageState>(find.byType(WorkItemPage)).data?['title'], 'Synthetic issue');
        expect(fixture.detailReads, 1);
      });
    },
  );
}

void _viewport(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(412, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _expectDetailUri(_WorkItemFixture fixture) {
  final matches = fixture.adapter.requests.where(
    (r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/merge_requests/12',
  );
  expect(matches, isNotEmpty, reason: 'GET full path with installation subpath');
  for (final r in matches) {
    expect(r.uri.queryParameters, isEmpty, reason: 'exact query map for MR detail');
  }
}

void _expectApprovalsUri(_WorkItemFixture fixture) {
  final matches = fixture.adapter.requests.where(
    (r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/merge_requests/12/approvals',
  );
  expect(matches, isNotEmpty);
  for (final r in matches) {
    expect(r.uri.queryParameters, isEmpty, reason: 'exact query map for approvals');
  }
}

void _expectIssueDetailUri(_WorkItemFixture fixture) {
  final matches = fixture.adapter.requests.where(
    (r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/issues/1',
  );
  expect(matches, isNotEmpty);
  for (final r in matches) {
    expect(r.uri.queryParameters, isEmpty);
  }
}

void _expectRelatedUri(_WorkItemFixture fixture) {
  final matches = fixture.adapter.requests.where(
    (r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/issues/1/related_merge_requests',
  );
  expect(matches, isNotEmpty);
  for (final r in matches) {
    expect(r.uri.queryParameters, equals({'per_page': '30'}), reason: 'exact query map for related');
  }
}

void _expectLinksUri(_WorkItemFixture fixture) {
  final matches = fixture.adapter.requests.where(
    (r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/issues/1/links',
  );
  expect(matches, isNotEmpty);
  for (final r in matches) {
    expect(r.uri.queryParameters, equals({'per_page': '30'}), reason: 'exact query map for links');
  }
}

final class _WorkItemFixture {
  _WorkItemFixture.mr() : kind = _Kind.mr {
    _init();
  }
  _WorkItemFixture.issue() : kind = _Kind.issue {
    _init();
  }
  final _Kind kind;
  late final FakeAdapter adapter = FakeAdapter(_respond);
  late final GitLabApi api;
  var now = DateTime.utc(2026, 10, 23, 1);
  int? approvalsStatus;
  int? relatedStatus;
  Json? nextApprovals;
  Completer<ResponseBody>? nextDetail;
  FutureOr<ResponseBody>? Function(RequestOptions)? intercept;
  static const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

  void _init() {
    final dio = Dio()..httpClientAdapter = adapter;
    api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: dio,
      readCacheClock: () => now,
    );
    api.bindReadCache(account.key, 1);
  }

  Account get account => Account(
    instance: api.instance,
    user: const GitLabUser(id: 7, username: 'developer', name: 'Developer'),
    token: 'synthetic-test-token',
  );
  Project get project => Project.fromJson(const {
    'id': 42,
    'name': 'Mobile Workspace',
    'path_with_namespace': 'studio/mobile-workspace',
    'visibility': 'private',
    'default_branch': 'main',
    'archived': false,
  });
  String get detailPath => kind == _Kind.mr
      ? '/gitlab/api/v4/projects/42/merge_requests/12'
      : '/gitlab/api/v4/projects/42/issues/1';
  int get detailReads => adapter.requests
      .where((r) => r.method == 'GET' && r.uri.path == detailPath)
      .length;
  int get approvalsReads => adapter.requests
      .where((r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/merge_requests/12/approvals')
      .length;
  int get relatedReads => adapter.requests
      .where((r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/issues/1/related_merge_requests')
      .length;
  int get linksReads => adapter.requests
      .where((r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/issues/1/links')
      .length;
  int get blockerReads => adapter.requests.where((r) => r.uri.path.contains('/projects/8/issues/')).length;
  static const approvalsPath = '/gitlab/api/v4/projects/42/merge_requests/12/approvals';

  Json issueDetail({String title = 'Synthetic issue'}) => {
    'id': 1001,
    'iid': 1,
    'project_id': 42,
    'title': title,
    'description': 'Body',
    'state': 'opened',
    'author': {'id': 7, 'username': 'developer'},
    'assignees': <Json>[],
    'labels': <String>[],
    'confidential': false,
    'updated_at': '2026-10-23T00:00:00Z',
    'created_at': '2026-10-23T00:00:00Z',
    'user_notes_count': 0,
    'upvotes': 0,
    'subscribed': false,
  };
  Json approvalsJson({List<Json> approvedBy = const [], int required = 1, int left = 1}) => {
    'approved_by': approvedBy,
    'approvals_required': required,
    'approvals_left': left,
  };
  Json mrDetail({String title = 'Synthetic MR'}) => {
    'id': 1012,
    'iid': 12,
    'project_id': 42,
    'title': title,
    'description': 'Body',
    'state': 'opened',
    'author': {'id': 7, 'username': 'developer'},
    'assignees': <Json>[],
    'reviewers': <Json>[],
    'labels': <String>[],
    'source_branch': 'feature',
    'target_branch': 'main',
    'sha': sha,
    'draft': false,
    'updated_at': '2026-10-23T00:00:00Z',
    'created_at': '2026-10-23T00:00:00Z',
    'subscribed': false,
  };

  WorkItemPage page({Key? key}) => WorkItemPage(
    key: key,
    account: account,
    api: api,
    project: project,
    resource: kind == _Kind.mr ? 'merge_requests' : 'issues',
    type: ProjectWorkItemType.issue,
    iid: kind == _Kind.mr ? 12 : 1,
  );
  void close() => api.close();

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    final intercepted = intercept?.call(request);
    if (intercepted != null) return intercepted;
    final path = request.uri.path;
    if (path == '/gitlab/api/v4/projects/42/merge_requests/12') {
      final pending = nextDetail;
      nextDetail = null;
      if (pending != null) return pending.future;
      return jsonResponse(mrDetail());
    }
    if (path == '/gitlab/api/v4/projects/42/issues/1') {
      final pending = nextDetail;
      nextDetail = null;
      if (pending != null) return pending.future;
      return jsonResponse(issueDetail());
    }
    if (path == '/gitlab/api/v4/projects/42/merge_requests/12/approvals') {
      final next = nextApprovals;
      nextApprovals = null;
      if (next != null) return jsonResponse(next);
      final status = approvalsStatus;
      if (status != null) return jsonResponse({}, status: status);
      return jsonResponse(approvalsJson());
    }
    if (path == '/gitlab/api/v4/projects/42/issues/1/related_merge_requests') {
      final status = relatedStatus;
      if (status != null) return jsonResponse({}, status: status);
      return jsonResponse([]);
    }
    if (path == '/gitlab/api/v4/projects/42/issues/1/links') {
      return jsonResponse([]);
    }
    if (path.endsWith('/award_emoji')) return jsonResponse([]);
    if (request.uri == api.instance.graphQL) return jsonResponse({'data': {'project': null}});
    return jsonResponse({}, status: 404);
  }
}

enum _Kind { mr, issue }
