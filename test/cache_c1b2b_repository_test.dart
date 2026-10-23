import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show settleWorkspace, workspaceHost;

void main() {
  testWidgets(
    '§3.4 fixture branch tree README cache empty viewport 412x900 clock fixed completion settled: first open reads branch tree HEAD raw once each',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      expect(fixture.branchReads, 1, reason: 'GET branch');
      expect(fixture.treeReads, 1, reason: 'GET pinned tree');
      expect(fixture.readmeHeadReads, 1, reason: 'HEAD README bounds');
      expect(fixture.readmeRawReads, 1, reason: 'GET pinned README raw');
      final branchReq = fixture.adapter.requests.firstWhere(
        (r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/repository/branches/main',
      );
      expect(branchReq.uri.queryParameters, isEmpty);
      final treeReq = fixture.adapter.requests.firstWhere(
        (r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/repository/tree',
      );
      expect(treeReq.uri.queryParameters, equals({'ref': _RepositoryFixture.sha, 'path': '', 'per_page': '50'}));
      final headReq = fixture.adapter.requests.firstWhere(
        (r) => r.method == 'HEAD' && r.uri.path == '/gitlab/api/v4/projects/42/repository/files/README.md',
      );
      expect(headReq.uri.queryParameters, equals({'ref': _RepositoryFixture.sha}));
      final rawReq = fixture.adapter.requests.firstWhere(
        (r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/repository/files/README.md/raw',
      );
      expect(rawReq.uri.queryParameters, equals({'ref': _RepositoryFixture.sha, 'lfs': 'false'}));
    },
  );

  testWidgets(
    '§3.4 fixture branch tree README cache warm viewport 412x900 clock +20s completion settled: second open reads 0 times',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      expect(fixture.branchReads, 1);
      expect(fixture.treeReads, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 20));
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      expect(fixture.branchReads, 1);
      expect(fixture.treeReads, 1);
      expect(fixture.readmeHeadReads, 1);
      expect(fixture.readmeRawReads, 1);
      final state = tester.state<RepositoryTabState>(find.byType(RepositoryTab));
      expect(state.currentRef?.sha, _RepositoryFixture.sha);
      expect(state.stale, isFalse);
    },
  );

  testWidgets(
    '§3.4 fixture branch stale viewport 412x900 clock +61s completion background response: stale then one fresh background read',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 61));
      final pending = Completer<ResponseBody>();
      fixture.nextBranch = pending;
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await pumpUntil(tester, () => fixture.branchReads == 2);
      final state = tester.state<RepositoryTabState>(find.byType(RepositoryTab));
      expect(state.currentRef?.sha, _RepositoryFixture.sha);
      expect(state.stale, isTrue);
      expect(state.revalidating, isTrue);
      pending.complete(jsonResponse({'name': 'main', 'commit': {'id': _RepositoryFixture.sha}}));
      await settleWorkspace(tester);
      expect(state.stale, isFalse);
      expect(state.revalidating, isFalse);
      expect(fixture.branchReads, 2);
    },
  );

  testWidgets(
    '§3.4 fixture branch tree 403 cache empty viewport 412x900 clock fixed completion settled: cold tree 403 keeps branch and project context',
    (tester) async {
      final fixture = _RepositoryFixture()..treeStatus = 403;
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      final state = tester.state<RepositoryTabState>(find.byType(RepositoryTab));
      expect(state.currentRef, isNotNull);
      expect(state.loadError, isNull);
      expect(fixture.branchReads, 1);
    },
  );

  testWidgets(
    '§3.4 fixture branch 404 cache stale viewport 412x900 clock +61s completion settled: branch 404 keeps the ref name, clears the sha and offers retry on the same ref',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 61));
      fixture.branchStatus = 404;
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      final state = tester.state<RepositoryTabState>(find.byType(RepositoryTab));
      expect(fixture.branchReads, 2, reason: 'stale branch revalidates in background');
      expect(state.currentRef, isNotNull, reason: 'ref name retained for retry');
      expect(state.currentRef?.name, 'main');
      expect(state.currentRef?.sha, isEmpty, reason: 'sha cleared');
      expect(state.loadError?.status, 404);
      final retry = tester.widget<FailureNotice>(find.byType(FailureNotice).first).onRetry;
      expect(retry, isNotNull);
      retry!();
      await settleWorkspace(tester);
      expect(fixture.branchReads, 3, reason: 'retry resolves the same ref');
      final reread = fixture.adapter.requests.lastWhere(
        (r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/repository/branches/main',
      );
      expect(reread.uri.path, '/gitlab/api/v4/projects/42/repository/branches/main');
    },
  );

  testWidgets(
    '§3.4 fixture branch stale viewport offstage then resumed clock +61s completion background response: pauses and resumes',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 61));
      await tester.pumpWidget(
        workspaceHost(TickerMode(enabled: false, child: fixture.tab(key: const ValueKey('repo')))),
      );
      await pumpUntil(tester, () => tester.state<RepositoryTabState>(find.byType(RepositoryTab)).currentRef != null);
      final state = tester.state<RepositoryTabState>(find.byType(RepositoryTab));
      expect(state.stale, isTrue);
      expect(state.revalidating, isFalse);
      expect(fixture.branchReads, 1);
      await tester.pumpWidget(
        workspaceHost(TickerMode(enabled: true, child: fixture.tab(key: const ValueKey('repo')))),
      );
      await settleWorkspace(tester);
      expect(fixture.branchReads, 2);
      expect(state.stale, isFalse);
    },
  );

  testWidgets(
    '§3.4 fixture branch queued background hidden viewport 412x900 clock +61s completion no HTTP: same hidden state sends nothing until visible',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      Widget host(bool on) => workspaceHost(TickerMode(enabled: on, child: fixture.tab(key: const ValueKey('same'))));
      await tester.pumpWidget(host(true));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 61));
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
        () => tester.state<RepositoryTabState>(find.byType(RepositoryTab)).revalidating,
        description: 'stale reopen queues a background branch revalidation',
      );
      final state = tester.state<RepositoryTabState>(find.byType(RepositoryTab));
      await tester.pumpWidget(host(false));
      expect(identical(tester.state<RepositoryTabState>(find.byType(RepositoryTab)), state), isTrue, reason: 'same state kept while hidden');
      occupied.complete();
      await settleNetworkWidgets(tester);
      await tester.runAsync(() => Future.wait(blockers));
      expect(fixture.branchReads, 1, reason: 'hidden queued read must send no HTTP');
      await tester.pumpWidget(host(true));
      expect(identical(tester.state<RepositoryTabState>(find.byType(RepositoryTab)), state), isTrue, reason: 'same state resumes');
      await settleWorkspace(tester);
      expect(fixture.branchReads, 2, reason: 'visibility resumes exactly one read');
    },
  );

  testWidgets(
    '§3.4 fixture branch README race viewport 412x900 clock fixed completion ordered: old README never clears the new SHA loading flag',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      const shaA = _RepositoryFixture.sha;
      const shaB = _RepositoryFixture.shaB;
      fixture.readmeBodyByRef[shaA] = '# README A marker-aaa';
      fixture.readmeBodyByRef[shaB] = '# README B marker-bbb';
      final heldReadmeA = Completer<ResponseBody>();
      final heldReadmeB = Completer<ResponseBody>();
      fixture.readmePending[shaA] = heldReadmeA;
      fixture.readmePending[shaB] = heldReadmeB;
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      // First open: branch A, tree A and the README A raw request are sent;
      // the raw body stays held so the fetch is still in flight.
      await pumpUntil(
        tester,
        () => tester.state<RepositoryTabState>(find.byType(RepositoryTab)).currentRef?.sha == shaA,
        description: 'branch A resolves',
      );
      await pumpUntil(tester, () => fixture.treeReads == 1, description: 'tree A loads');
      await pumpUntil(tester, () => fixture.readmeRawReads == 1, description: 'README A fetch starts');
      // Explicit refresh resolves the branch to B while README A is held.
      fixture.nextBranch = Completer<ResponseBody>()
        ..complete(jsonResponse({'name': 'main', 'commit': {'id': shaB}}));
      await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
      await pumpUntil(
        tester,
        () => tester.state<RepositoryTabState>(find.byType(RepositoryTab)).currentRef?.sha == shaB,
        description: 'branch resolves to B',
      );
      await pumpUntil(tester, () => fixture.treeReads == 2, description: 'tree for B loads', maxCycles: 40);
      await pumpUntil(tester, () => fixture.readmeRawReads == 2, description: 'README B fetch starts', maxCycles: 40);
      // Release the old request: it must neither show A's content nor clear
      // B's loading flag.
      heldReadmeA.complete(ResponseBody.fromString('# README A marker-aaa', 200));
      await settleNetworkWidgets(tester);
      expect(find.textContaining('marker-aaa', findRichText: true), findsNothing, reason: 'old README never applied');
      expect(
        find.descendant(of: find.byType(RepositoryReadmeCard), matching: find.byType(CircularProgressIndicator)),
        findsOneWidget,
        reason: 'B README still loading',
      );
      heldReadmeB.complete(ResponseBody.fromString('# README B marker-bbb', 200));
      await settleWorkspace(tester);
      expect(find.textContaining('marker-bbb', findRichText: true), findsOneWidget, reason: 'B README shows');
      expect(find.textContaining('marker-aaa', findRichText: true), findsNothing);
    },
  );

  testWidgets(
    '§3.4 fixture file pinned cache warm viewport 412x900 clock +20s completion settled: pinned file raw stays cached while fileMetadata HEAD always sends',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.runAsync(() => fixture.api.cachedRecord(['projects', '42', 'repository', 'branches', 'main']));
      await tester.pumpWidget(workspaceHost(fixture.filePage()));
      await settleWorkspace(tester);
      expect(fixture.readmeRawReads, 1, reason: 'GET pinned file raw');
      final headAfterFirst = fixture.readmeHeadReads;
      expect(headAfterFirst, 2, reason: 'HEAD fileMetadata plus HEAD textFile bounds');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 20));
      await tester.pumpWidget(workspaceHost(fixture.filePage()));
      await settleWorkspace(tester);
      expect(fixture.readmeRawReads, 1, reason: 'pinned file raw warm reread sends 0 requests');
      expect(fixture.readmeHeadReads, headAfterFirst + 1, reason: 'HEAD fileMetadata always sends; textFile HEAD stays cached');
    },
  );

  for (final background in [false, true]) {
    testWidgets(
      '§3.4 fixture late tree A README B held viewport 412x900 clock ${background ? '+61s' : 'fixed'} completion ${background ? 'background revalidation' : 'explicit refresh'}: late tree A never replaces README B',
      (tester) async {
        final fixture = _RepositoryFixture();
        addTearDown(fixture.close);
        _viewport(tester);
        const shaA = _RepositoryFixture.sha;
        const shaB = _RepositoryFixture.shaB;
        if (background) {
          // Warm the branch alone; the reopened tree A must still hit HTTP.
          fixture.treeStatus = 500;
          await tester.pumpWidget(workspaceHost(fixture.tab()));
          await settleWorkspace(tester);
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          fixture.now = fixture.now.add(const Duration(seconds: 61));
          fixture.treeStatus = null;
        }
        final treeBefore = fixture.treeReads;
        final heldTreeA = Completer<void>();
        final heldReadmeB = Completer<ResponseBody>();
        fixture.readmePending[shaB] = heldReadmeB;
        var holdTreeA = true;
        fixture.intercept = (request) {
          if (holdTreeA &&
              request.method == 'GET' &&
              request.uri.path ==
                  '/gitlab/api/v4/projects/42/repository/tree' &&
              request.uri.queryParameters['ref'] == shaA) {
            holdTreeA = false;
            return heldTreeA.future.then((_) => jsonResponse(_rootTree()));
          }
          return null;
        };
        final heldBranchB = Completer<ResponseBody>();
        if (background) fixture.nextBranch = heldBranchB;
        await tester.pumpWidget(workspaceHost(fixture.tab()));
        await pumpUntil(
          tester,
          () => fixture.treeReads == treeBefore + 1,
          description: 'tree A in flight',
        );
        final state = tester.state<RepositoryTabState>(
          find.byType(RepositoryTab),
        );
        expect(state.currentRef?.sha, shaA);
        if (!background) {
          fixture.nextBranch = heldBranchB;
          await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
        }
        await pumpUntil(
          tester,
          () => fixture.branchReads == 2,
          description: 'branch B read starts',
        );
        expect(state.revalidating, background);
        heldBranchB.complete(
          jsonResponse({
            'name': 'main',
            'commit': {'id': shaB},
          }),
        );
        await pumpUntil(
          tester,
          () => state.currentRef?.sha == shaB,
          description: 'branch B applied',
        );
        await pumpUntil(
          tester,
          () => fixture.treeReads == treeBefore + 2,
          description: 'tree B loads',
        );
        await pumpUntil(
          tester,
          () => fixture.readmeRawReads == 1,
          description: 'README B starts',
        );
        heldTreeA.complete();
        await settleNetworkWidgets(tester);
        expect(
          find.descendant(
            of: find.byType(RepositoryReadmeCard),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
          reason: 'late tree A must not end README B loading',
        );
        heldReadmeB.complete(
          ResponseBody.fromString('# README B marker-bbb', 200),
        );
        await settleWorkspace(tester);
        expect(
          find.textContaining('marker-bbb', findRichText: true),
          findsOneWidget,
        );
        expect(fixture.branchReads, 2);
        expect(fixture.treeReads, treeBefore + 2);
        _expectReadmeRequests(fixture, [shaB]);
      },
    );
  }

  testWidgets(
    '§3.4 fixture README A held branch stale viewport 412x900 clock +61s completion background revalidation: old README never clears the new SHA loading flag',
    (tester) async {
      final fixture = _RepositoryFixture()..treeStatus = 500;
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 61));
      fixture.treeStatus = null;
      final heldReadmeA = Completer<ResponseBody>();
      final heldReadmeB = Completer<ResponseBody>();
      fixture.readmePending[_RepositoryFixture.sha] = heldReadmeA;
      fixture.readmePending[_RepositoryFixture.shaB] = heldReadmeB;
      final heldBranchB = Completer<ResponseBody>();
      fixture.nextBranch = heldBranchB;
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await pumpUntil(
        tester,
        () => fixture.readmeRawReads == 1,
        description: 'README A in flight',
      );
      final state = tester.state<RepositoryTabState>(
        find.byType(RepositoryTab),
      );
      expect(state.revalidating, isTrue);
      heldBranchB.complete(
        jsonResponse({
          'name': 'main',
          'commit': {'id': _RepositoryFixture.shaB},
        }),
      );
      await pumpUntil(
        tester,
        () => state.currentRef?.sha == _RepositoryFixture.shaB,
        description: 'branch B applied in background',
      );
      await pumpUntil(
        tester,
        () => fixture.readmeRawReads == 2,
        description: 'README B starts',
      );
      heldReadmeA.complete(
        ResponseBody.fromString('# README A marker-aaa', 200),
      );
      await settleNetworkWidgets(tester);
      expect(
        find.textContaining('marker-aaa', findRichText: true),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(RepositoryReadmeCard),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
        reason: 'README A completion must not end README B loading',
      );
      heldReadmeB.complete(
        ResponseBody.fromString('# README B marker-bbb', 200),
      );
      await settleWorkspace(tester);
      expect(
        find.textContaining('marker-bbb', findRichText: true),
        findsOneWidget,
      );
      expect(fixture.branchReads, 2);
      expect(fixture.treeReads, 3);
      expect(fixture.readmeHeadReads, 2);
      expect(fixture.readmeRawReads, 2);
    },
  );

  for (final status in [200, 500]) {
    testWidgets(
      '§3.4 fixture same SHA README held viewport 412x900 clock fixed completion ${status == 200 ? 'success' : 'failure'}: same SHA explicit refresh releases README loading',
      (tester) async {
        final fixture = _RepositoryFixture();
        addTearDown(fixture.close);
        _viewport(tester);
        final heldReadme = Completer<ResponseBody>();
        fixture.readmePending[_RepositoryFixture.sha] = heldReadme;
        await tester.pumpWidget(workspaceHost(fixture.tab()));
        await pumpUntil(
          tester,
          () => fixture.readmeRawReads == 1,
          description: 'README A in flight',
        );
        await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
        await pumpUntil(
          tester,
          () => fixture.branchReads == 2,
          description: 'same SHA branch refresh',
        );
        await settleNetworkWidgets(tester);
        heldReadme.complete(
          ResponseBody.fromString('# README A marker-aaa', status),
        );
        await settleWorkspace(tester);
        expect(
          find.descendant(
            of: find.byType(RepositoryReadmeCard),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
          reason: 'same SHA refresh must not orphan a README completion',
        );
        if (status == 500) {
          final notice = tester.widget<FailureNotice>(
            find.descendant(
              of: find.byType(RepositoryReadmeCard),
              matching: find.byType(FailureNotice),
            ),
          );
          expect(notice.onRetry, isNotNull);
          fixture.readmePending.clear();
          fixture.readmeBodyByRef[_RepositoryFixture.sha] =
              '# README A marker-aaa';
          notice.onRetry!();
          await settleWorkspace(tester);
          expect(
            fixture.readmeRawReads,
            2,
            reason: 'failed README remains retryable',
          );
        } else {
          _expectReadmeRequests(fixture, [_RepositoryFixture.sha]);
        }
        expect(
          find.textContaining('marker-aaa', findRichText: true),
          findsOneWidget,
        );
        expect(fixture.branchReads, 2);
        expect(fixture.treeReads, 1);
      },
    );
  }

  testWidgets(
    '§3.4 fixture README A retry queued foreground full viewport 412x900 clock +61s completion branch B background response: superseded README sends no HTTP',
    (tester) async {
      final fixture = _RepositoryFixture()..treeStatus = 500;
      addTearDown(fixture.close);
      _viewport(tester);
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      fixture.now = fixture.now.add(const Duration(seconds: 61));
      fixture.treeStatus = null;
      final occupied = Completer<void>();
      fixture.intercept = (request) {
        if (request.uri.path.contains('/projects/8/issues/')) {
          return occupied.future.then((_) => jsonResponse({'id': 1}));
        }
        return null;
      };
      fixture.readmePending[_RepositoryFixture.sha] = Completer<ResponseBody>()
        ..complete(ResponseBody.fromString('', 500));
      final heldBranchB = Completer<ResponseBody>();
      fixture.nextBranch = heldBranchB;
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await pumpUntil(
        tester,
        () => fixture.readmeRawReads == 1,
        description: 'README A fails before retry',
      );
      await settleWorkspace(tester);
      final notice = tester.widget<FailureNotice>(
        find.descendant(
          of: find.byType(RepositoryReadmeCard),
          matching: find.byType(FailureNotice),
        ),
      );
      expect(notice.onRetry, isNotNull);
      final blockers = [
        for (var id = 1; id <= 16; id++)
          fixture.api.cachedRecord([
            'projects',
            '8',
            'issues',
            '$id',
          ], fresh: true),
      ];
      await pumpUntil(
        tester,
        () => fixture.blockerReads == 16,
        description: 'all foreground slots occupied',
      );
      // Invoke the explicit retry outside the tree's read Zone so only the
      // README request's own generation fence can cancel this queued read.
      notice.onRetry!();
      await settleNetworkWidgets(tester);
      expect(fixture.readmeHeadReads, 1, reason: 'README A retry is queued');
      expect(
        find.descendant(
          of: find.byType(RepositoryReadmeCard),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      final state = tester.state<RepositoryTabState>(
        find.byType(RepositoryTab),
      );
      expect(state.revalidating, isTrue);
      heldBranchB.complete(
        jsonResponse({
          'name': 'main',
          'commit': {'id': _RepositoryFixture.shaB},
        }),
      );
      await pumpUntil(
        tester,
        () => state.currentRef?.sha == _RepositoryFixture.shaB,
        description: 'branch B supersedes queued README A',
      );
      occupied.complete();
      await settleNetworkWidgets(tester);
      await tester.runAsync(() => Future.wait(blockers));
      await settleWorkspace(tester);
      _expectReadmeRequests(fixture, [
        _RepositoryFixture.sha,
        _RepositoryFixture.shaB,
      ]);
      expect(
        find.textContaining('Synthetic README', findRichText: true),
        findsOneWidget,
      );
      expect(fixture.branchReads, 2);
      expect(fixture.treeReads, 3);
    },
  );

  testWidgets(
    '§3.4 fixture README retry queued foreground full viewport 412x900 clock fixed completion explicit refresh: same SHA refresh preserves queued README',
    (tester) async {
      final fixture = _RepositoryFixture();
      addTearDown(fixture.close);
      _viewport(tester);
      fixture.readmePending[_RepositoryFixture.sha] = Completer<ResponseBody>()
        ..complete(ResponseBody.fromString('', 500));
      await tester.pumpWidget(workspaceHost(fixture.tab()));
      await settleWorkspace(tester);
      final notice = tester.widget<FailureNotice>(
        find.descendant(
          of: find.byType(RepositoryReadmeCard),
          matching: find.byType(FailureNotice),
        ),
      );
      expect(notice.onRetry, isNotNull);
      final occupied = Completer<void>();
      fixture.intercept = (request) =>
          request.uri.path.contains('/projects/8/issues/')
          ? occupied.future.then((_) => jsonResponse({'id': 1}))
          : null;
      final blockers = [
        for (var id = 1; id <= 16; id++)
          fixture.api.cachedRecord([
            'projects',
            '8',
            'issues',
            '$id',
          ], fresh: true),
      ];
      await pumpUntil(
        tester,
        () => fixture.blockerReads == 16,
        description: 'all foreground slots occupied',
      );
      fixture.readmePending.clear();
      fixture.readmeBodyByRef[_RepositoryFixture.sha] = '# README A marker-aaa';
      notice.onRetry!();
      await settleNetworkWidgets(tester);
      expect(fixture.readmeHeadReads, 1, reason: 'README retry remains queued');
      await tester.tap(find.widgetWithIcon(IconButton, Icons.refresh));
      await tester.pump();
      occupied.complete();
      await settleNetworkWidgets(tester);
      await tester.runAsync(() => Future.wait(blockers));
      await settleWorkspace(tester);
      expect(fixture.branchReads, 2);
      expect(fixture.treeReads, 1);
      _expectReadmeRequests(fixture, [
        _RepositoryFixture.sha,
        _RepositoryFixture.sha,
      ]);
      expect(
        find.textContaining('marker-aaa', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(RepositoryReadmeCard),
          matching: find.byType(FailureNotice),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    '§3.4 fixture file cold dropped viewport 412x900 clock fixed completion retry notice: dropped cold read shows retry and recovers',
    (tester) async {
      final fixture = _RepositoryFixture();
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
        await tester.pumpWidget(workspaceHost(fixture.filePage()));
        await settleWorkspace(tester);
        expect(refusals, greaterThan(0));
        expect(find.byType(FailureNotice), findsWidgets);
        admitted = true;
        final notices = tester.widgetList<FailureNotice>(find.byType(FailureNotice));
        expect(notices.any((n) => n.onRetry != null), isTrue);
        notices.firstWhere((n) => n.onRetry != null).onRetry!();
        await pumpUntil(tester, () => fixture.readmeRawReads >= 1);
        await settleWorkspace(tester);
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

List<Json> _rootTree() => [
  {'id': '1', 'name': 'lib', 'path': 'lib', 'type': 'tree', 'mode': '040000'},
  {
    'id': '2',
    'name': 'README.md',
    'path': 'README.md',
    'type': 'blob',
    'mode': '100644',
  },
];

void _expectReadmeRequests(_RepositoryFixture fixture, List<String> refs) {
  expect(fixture.readmeHeadReads, refs.length);
  expect(fixture.readmeRawReads, refs.length);
  final heads = fixture.adapter.requests
      .where(
        (r) =>
            r.method == 'HEAD' &&
            r.uri.path ==
                '/gitlab/api/v4/projects/42/repository/files/README.md',
      )
      .toList();
  final raws = fixture.adapter.requests
      .where(
        (r) =>
            r.method == 'GET' &&
            r.uri.path ==
                '/gitlab/api/v4/projects/42/repository/files/README.md/raw',
      )
      .toList();
  for (var i = 0; i < refs.length; i++) {
    expect(heads[i].uri.queryParameters, equals({'ref': refs[i]}));
    expect(
      raws[i].uri.queryParameters,
      equals({'ref': refs[i], 'lfs': 'false'}),
    );
  }
}

final class _RepositoryFixture {
  _RepositoryFixture() {
    final dio = Dio()..httpClientAdapter = adapter;
    api = GitLabApi(
      instance: GitLabInstance.parse('https://example.com/gitlab'),
      token: 'synthetic-test-token',
      dio: dio,
      readCacheClock: () => now,
    );
    api.bindReadCache(account.key, 1);
  }
  static const sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  static const shaB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  var now = DateTime.utc(2026, 10, 23, 1);
  late final FakeAdapter adapter = FakeAdapter(_respond);
  late final GitLabApi api;
  int? branchStatus;
  int? treeStatus;
  Completer<ResponseBody>? nextBranch;
  FutureOr<ResponseBody>? Function(RequestOptions)? intercept;
  final readmePending = <String, Completer<ResponseBody>>{};
  final readmeBodyByRef = <String, String>{};
  int get branchReads => adapter.requests
      .where((r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/repository/branches/main')
      .length;
  int get treeReads => adapter.requests
      .where((r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/repository/tree')
      .length;
  int get readmeHeadReads => adapter.requests
      .where((r) => r.method == 'HEAD' && r.uri.path == '/gitlab/api/v4/projects/42/repository/files/README.md')
      .length;
  int get readmeRawReads => adapter.requests
      .where((r) => r.method == 'GET' && r.uri.path == '/gitlab/api/v4/projects/42/repository/files/README.md/raw')
      .length;
  int get blockerReads => adapter.requests.where((r) => r.uri.path.contains('/projects/8/issues/')).length;

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
  Widget tab({Key? key}) => RepositoryTab(key: key, account: account, api: api, project: project);
  Widget filePage() => RepositoryFilePage(
    account: account,
    api: api,
    project: project,
    branch: 'main',
    sha: sha,
    filePath: 'README.md',
  );
  void close() => api.close();

  FutureOr<ResponseBody> _respond(RequestOptions request) {
    final intercepted = intercept?.call(request);
    if (intercepted != null) return intercepted;
    final path = request.uri.path;
    if (path == '/gitlab/api/v4/projects/42/repository/branches/main') {
      final pending = nextBranch;
      nextBranch = null;
      if (pending != null) return pending.future;
      final status = branchStatus;
      if (status != null) return jsonResponse({}, status: status);
      return jsonResponse({'name': 'main', 'commit': {'id': sha}});
    }
    if (path == '/gitlab/api/v4/projects/42/repository/tree') {
      final status = treeStatus;
      if (status != null) return jsonResponse({}, status: status);
      return jsonResponse([
        {'id': '1', 'name': 'lib', 'path': 'lib', 'type': 'tree', 'mode': '040000'},
        {'id': '2', 'name': 'README.md', 'path': 'README.md', 'type': 'blob', 'mode': '100644'},
      ]);
    }
    if (path == '/gitlab/api/v4/projects/42/repository/files/README.md' && request.method == 'HEAD') {
      return ResponseBody.fromString('', 200, headers: {'x-gitlab-size': ['80'], 'x-gitlab-last-commit-id': [sha]});
    }
    if (path == '/gitlab/api/v4/projects/42/repository/files/README.md/raw') {
      final ref = request.uri.queryParameters['ref'];
      final pending = readmePending[ref];
      if (pending != null) return pending.future;
      return ResponseBody.fromString(readmeBodyByRef[ref] ?? '# Synthetic README', 200);
    }
    if (path.endsWith('/award_emoji')) return jsonResponse([]);
    return jsonResponse({}, status: 404);
  }
}
