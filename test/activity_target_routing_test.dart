import 'dart:async';

import 'package:dio/dio.dart' show ResponseBody;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/activity_page.dart';
import 'package:gitlab_mobile/features/workspace/commit_page.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'session_test.dart';
import 'support/activity_target_routing_fixture.dart';
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

void main() {
  late ActivityFakeUrlLauncher launcher;
  late UrlLauncherPlatform originalLauncher;

  setUp(() {
    launcher = ActivityFakeUrlLauncher();
    originalLauncher = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher;
  });

  tearDown(() {
    UrlLauncherPlatform.instance = originalLauncher;
  });

  Finder inSheet(Finder finder) =>
      find.descendant(of: find.byType(BottomSheet), matching: finder);

  Future<GitLabApi> pumpActivity(
    WidgetTester tester,
    ActivityEventServer server, {
    Account? account,
    Project? project,
    Size size = const Size(412, 2400),
    double devicePixelRatio = 1,
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = devicePixelRatio;
    tester.view.physicalSize = size * devicePixelRatio;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    final api = testApi(server.adapter);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        builder: textScale == 1
            ? null
            : (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(textScale),
                  ),
                  child: child!,
                ),
        home: ActivityPage(
          account: account ?? activityAccount(),
          api: api,
          project: project,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    return api;
  }

  Future<
      ({
        ActivityEventServer server,
        SessionController session,
        Account account,
        GitLabApi api,
      })> createSession(
    WidgetTester tester,
    ActivityEventServer server, {
    FakeAdapter? adapter,
  }) async {
    final session = controllerFor(MemoryAccountStore(), adapter ?? server.adapter);
    addTearDown(session.dispose);
    await tester.runAsync(session.initialize);
    await tester.runAsync(
      () => session.connect('https://example.com/gitlab', 'synthetic-test-token'),
    );
    return (
      server: server,
      session: session,
      account: session.active!,
      api: session.api!,
    );
  }

  Future<void> pumpActivityWithSession(
    WidgetTester tester,
    SessionController session,
    GitLabApi api,
    Account account, {
    Project? project,
    Size size = const Size(412, 2400),
    double devicePixelRatio = 1,
    double textScale = 1,
  }) async {
    tester.view.devicePixelRatio = devicePixelRatio;
    tester.view.physicalSize = size * devicePixelRatio;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: MaterialApp(
          builder: textScale == 1
              ? null
              : (context, child) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(textScale),
                  ),
                  child: child!,
                ),
          home: ActivityPage(
            account: account,
            api: api,
            project: project,
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
  }

  // ---------------------------------------------------------------------------
  // T01 - T05: Native Supported Routes (Preserved Behavior / Old GREEN)
  // ---------------------------------------------------------------------------

  testWidgets('T01: native issue route opens WorkItemPage without sheet',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 1,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Issue',
        targetIid: 42,
        targetTitle: 'Valid Issue Target',
      ),
    ]);
    await pumpActivity(tester, server);

    await tester.tap(find.text('Valid Issue Target'));
    await settleNetworkWidgets(tester);

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(WorkItemPage), findsOneWidget);
    expect(server.issueGets, 1);
  });

  testWidgets(
      'T02: native merge request route opens WorkItemPage in project feed',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 2,
        projectId: 10,
        actionName: 'opened',
        targetType: 'MergeRequest',
        targetIid: 84,
        targetTitle: 'Valid MR Target',
      ),
    ]);
    final project = Project.fromJson(activityProject);
    await pumpActivity(tester, server, project: project);

    await tester.tap(find.text('Valid MR Target'));
    await settleNetworkWidgets(tester);

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(WorkItemPage), findsOneWidget);
    expect(server.mrGets, 1);
  });

  testWidgets('T03: native note on issue routes to WorkItemPage without sheet',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 3,
        projectId: 10,
        actionName: 'commented on',
        targetType: 'Note',
        targetIid: 999,
        note: {
          'id': 1001,
          'noteable_type': 'Issue',
          'noteable_iid': 42,
          'body': 'Issue comment body',
        },
      ),
    ]);
    await pumpActivity(tester, server);

    await tester.tap(find.text('Issue comment body'));
    await settleNetworkWidgets(tester);

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(WorkItemPage), findsOneWidget);
    expect(server.issueGets, 1);
  });

  testWidgets('T04: native 40-hex commit push routes to CommitDetailPage',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 4,
        projectId: 10,
        actionName: 'pushed to',
        pushData: {
          'action': 'pushed',
          'ref': 'main',
          'ref_type': 'branch',
          'commit_to': activityCommit40Sha,
          'commit_count': 1,
          'commit_title': 'Native 40hex commit title',
        },
      ),
    ]);
    await pumpActivity(tester, server);

    await tester.tap(find.text('Native 40hex commit title'));
    await settleNetworkWidgets(tester);

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(CommitDetailPage), findsOneWidget);
    expect(server.commitGets, 1);
  });

  testWidgets('T05: native 64-hex commit push routes to CommitDetailPage',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 5,
        projectId: 10,
        actionName: 'pushed to',
        pushData: {
          'action': 'pushed',
          'ref': 'main',
          'ref_type': 'branch',
          'commit_to': activityCommit64Sha,
          'commit_count': 1,
          'commit_title': 'Native 64hex commit title',
        },
      ),
    ]);
    await pumpActivity(tester, server);

    await tester.tap(find.text('Native 64hex commit title'));
    await settleNetworkWidgets(tester);

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(CommitDetailPage), findsOneWidget);
    expect(server.commitGets, 1);
  });

  // ---------------------------------------------------------------------------
  // T06 - T12: Meaningful Old-Source RED Discriminators
  // ---------------------------------------------------------------------------

  testWidgets(
      'T06: invalid commit with short SHA opens explanation sheet without dispatching commit lookup',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 6,
        projectId: 10,
        actionName: 'pushed to',
        pushData: {
          'action': 'pushed',
          'ref': 'main',
          'ref_type': 'branch',
          'commit_to': '0123456',
          'commit_count': 1,
          'commit_title': 'Short sha commit title',
        },
      ),
    ]);
    await pumpActivity(tester, server);
    final commitGetsBefore = server.commitGets;

    await tester.tap(find.text('Short sha commit title'));
    await settleNetworkWidgets(tester);

    // Old source RED: old source called open.commit('10', '0123456'), pushed
    // CommitDetailPage, incremented commitGets, and had no BottomSheet.
    expect(find.byType(CommitDetailPage), findsNothing);
    expect(server.commitGets - commitGetsBefore, 0,
        reason: 'Short SHA must not trigger network commit lookup');
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.text('無法開啟此動態')), findsOneWidget);
    expect(inSheet(find.text('這則提交動態缺少可辨識目標的資料，無法在 App 內開啟。')), findsOneWidget);
  });

  testWidgets(
      'T07: push action removed opens sheet and does not silently open project',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 7,
        projectId: 10,
        actionName: 'pushed to',
        pushData: {
          'action': 'removed',
          'ref': 'feature-x',
          'ref_type': 'branch',
          'commit_to': '',
          'commit_count': 0,
        },
      ),
    ], projectHeaders: const {
      'cache-control': ['no-store'],
    });
    await pumpActivity(tester, server);
    final projectGetsBefore = server.projectDetailGets;

    await tester.tap(find.textContaining('刪除了分支 feature-x'));
    await settleNetworkWidgets(tester);

    // Removed pushes must leave project navigation to the explicit sheet action.
    expect(find.byType(ProjectPage), findsNothing);
    expect(server.projectDetailGets - projectGetsBefore, 0,
        reason: 'Removed push must not silently open project');
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.byKey(const ValueKey('activity-target-view-project'))),
        findsOneWidget);

    // Now explicit "查看專案" button opens project
    await tester.tap(
        inSheet(find.byKey(const ValueKey('activity-target-view-project'))));
    await settleNetworkWidgets(tester);
    expect(find.byType(ProjectPage), findsOneWidget);
    expect(tester.widget<ProjectPage>(find.byType(ProjectPage)).project.id, 10);
    expect(server.projectDetailGets - projectGetsBefore, 2,
        reason: 'Licensed project lookup and uncached overview decoration');
  });

  testWidgets(
      'T08: issue with missing iid opens explanation sheet instead of project overview',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 8,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Issue',
        targetIid: 0,
        targetTitle: 'Issue with missing IID',
      ),
    ]);
    await pumpActivity(tester, server);
    final projectGetsBefore = server.projectGets;

    await tester.tap(find.text('Issue with missing IID'));
    await settleNetworkWidgets(tester);

    // Old source RED: old source silently pushed ProjectPage on iid <= 0.
    expect(find.byType(ProjectPage), findsNothing);
    expect(server.projectGets - projectGetsBefore, 0,
        reason: 'Missing IID must not silently open project');
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.text('這則議題動態缺少可辨識目標的資料，無法在 App 內開啟。')), findsOneWidget);
  });

  testWidgets(
      'T09: milestone with target_url opens sheet with web and project actions',
      (tester) async {
    const milestoneUrl = 'https://example.com/gitlab/team/core/-/milestones/1';
    final server = ActivityEventServer([
      activityEvent(
        id: 9,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Milestone',
        targetIid: 1,
        targetTitle: 'v1.0 Release Milestone',
        targetUrl: milestoneUrl,
      ),
    ]);
    await pumpActivity(tester, server);
    final projectGetsBefore = server.projectGets;

    await tester.tap(find.text('v1.0 Release Milestone'));
    await settleNetworkWidgets(tester);

    // Old source RED: old source silently pushed ProjectPage.
    expect(find.byType(ProjectPage), findsNothing);
    expect(server.projectGets - projectGetsBefore, 0);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.text('無法在 App 內開啟')), findsOneWidget);
    expect(inSheet(find.text('「里程碑」類型的動態目前沒有 App 內頁面。')), findsOneWidget);
    expect(inSheet(find.byKey(const ValueKey('activity-target-open-web'))),
        findsOneWidget);
    expect(inSheet(find.byKey(const ValueKey('activity-target-view-project'))),
        findsOneWidget);

    await tester.tap(
        inSheet(find.byKey(const ValueKey('activity-target-open-web'))));
    await settleNetworkWidgets(tester);
    expect(launcher.launched, [milestoneUrl]);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets(
      'T10: wiki, snippet, and design events display friendly labels without raw type leak',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 10,
        projectId: 10,
        actionName: 'created',
        targetType: 'WikiPage::Meta',
        targetTitle: 'Architecture Documentation',
      ),
      activityEvent(
        id: 11,
        projectId: 10,
        actionName: 'created',
        targetType: 'Snippet',
        targetTitle: 'Helper Script',
      ),
      activityEvent(
        id: 12,
        projectId: 10,
        actionName: 'created',
        targetType: 'DesignManagement::Design',
        targetTitle: 'Mockup v2',
      ),
    ]);
    await pumpActivity(tester, server);

    final projectGetsBefore = server.projectGets;
    await tester.tap(find.text('Architecture Documentation'));
    await settleNetworkWidgets(tester);

    // Old source RED: old source silently pushed ProjectPage.
    expect(find.byType(ProjectPage), findsNothing);
    expect(server.projectGets - projectGetsBefore, 0);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.text('「Wiki 頁面」類型的動態目前沒有 App 內頁面。')), findsOneWidget);
    expect(find.textContaining('WikiPage::Meta'), findsNothing);

    await tester.tap(inSheet(find.byKey(const ValueKey('activity-target-close'))));
    await settleNetworkWidgets(tester);
    expect(find.byType(BottomSheet), findsNothing);

    await tester.tap(find.text('Helper Script'));
    await settleNetworkWidgets(tester);
    expect(inSheet(find.text('「程式碼片段」類型的動態目前沒有 App 內頁面。')), findsOneWidget);
    await tester.tap(inSheet(find.byKey(const ValueKey('activity-target-close'))));
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('Mockup v2'));
    await settleNetworkWidgets(tester);
    expect(inSheet(find.text('「設計」類型的動態目前沒有 App 內頁面。')), findsOneWidget);
  });

  testWidgets(
      'T11: member events without target type show generic sheet label and allow viewing project',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 13,
        projectId: 10,
        actionName: 'joined',
        targetType: null,
        targetTitle: '',
      ),
    ]);
    await pumpActivity(tester, server);
    final projectGetsBefore = server.projectGets;

    await tester.tap(find.textContaining('加入了專案'));
    await settleNetworkWidgets(tester);

    // Old source RED: old source silently pushed ProjectPage.
    expect(find.byType(ProjectPage), findsNothing);
    expect(server.projectGets - projectGetsBefore, 0);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.text('「其他 GitLab 動態」類型的動態目前沒有 App 內頁面。')), findsOneWidget);
    expect(inSheet(find.byKey(const ValueKey('activity-target-view-project'))),
        findsOneWidget);
  });

  testWidgets(
      'T12: off-instance, credentials, and path traversal URLs suppress web button',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 14,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Milestone',
        targetTitle: 'Off Instance Milestone',
        targetUrl: 'https://evil.com/gitlab/team/core/-/milestones/1',
      ),
      activityEvent(
        id: 15,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Milestone',
        targetTitle: 'Credential Token Milestone',
        targetUrl:
            'https://example.com/gitlab/team/core/-/milestones/1?private_token=secret',
      ),
      activityEvent(
        id: 16,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Milestone',
        targetTitle: 'Traversal Milestone',
        targetUrl: 'https://example.com/gitlab/team/core/../../admin',
      ),
    ]);
    await pumpActivity(tester, server);
    final projectGetsBefore = server.projectGets;

    // 1. Off-instance
    await tester.tap(find.text('Off Instance Milestone'));
    await settleNetworkWidgets(tester);
    expect(find.byType(ProjectPage), findsNothing);
    expect(server.projectGets - projectGetsBefore, 0);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.byKey(const ValueKey('activity-target-open-web'))),
        findsNothing);
    expect(inSheet(find.text('此動態沒有屬於目前 GitLab 實例的有效連結，無法開啟。')), findsOneWidget);
    await tester.tap(inSheet(find.byKey(const ValueKey('activity-target-close'))));
    await settleNetworkWidgets(tester);

    // 2. Token query
    await tester.tap(find.text('Credential Token Milestone'));
    await settleNetworkWidgets(tester);
    expect(inSheet(find.byKey(const ValueKey('activity-target-open-web'))),
        findsNothing);
    await tester.tap(inSheet(find.byKey(const ValueKey('activity-target-close'))));
    await settleNetworkWidgets(tester);

    // 3. Path traversal
    await tester.tap(find.text('Traversal Milestone'));
    await settleNetworkWidgets(tester);
    expect(inSheet(find.byKey(const ValueKey('activity-target-open-web'))),
        findsNothing);
    expect(launcher.launched, isEmpty);
  });

  // ---------------------------------------------------------------------------
  // T13 - T15: Session, Fence, and Lifecycle Safety
  // ---------------------------------------------------------------------------

  testWidgets(
      'T13: session switch cancels held project lookup before push (conditional check)',
      (tester) async {
    final completer = Completer<ResponseBody>();
    final lookupStarted = Completer<void>();
    final server = ActivityEventServer([
      activityEvent(
        id: 17,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Issue',
        targetIid: 42,
        targetTitle: 'Gated Issue Target',
      ),
    ]);
    final adapter = FakeAdapter((request) {
      if (request.method == 'GET' &&
          request.uri == activityInstance.api(['projects', '10'], {'license': 'true'})) {
        lookupStarted.complete();
        return completer.future;
      }
      return server.adapter.respond(request);
    });

    final sessionData = await createSession(tester, server, adapter: adapter);
    await pumpActivityWithSession(
      tester,
      sessionData.session,
      sessionData.api,
      sessionData.account,
    );

    await tester.tap(find.text('Gated Issue Target'));
    await tester.pump();
    await tester.runAsync(
        () => lookupStarted.future.timeout(const Duration(seconds: 20)));
    expect(find.byType(WorkItemPage), findsNothing);

    // End or switch session while lookup is held in flight
    await tester.runAsync(sessionData.session.endSession);
    completer.complete(jsonResponse(activityProject));
    await settleNetworkWidgets(tester);

    expect(find.byType(WorkItemPage), findsNothing,
        reason: 'WorkItemPage must not mount after session cancellation');
    // Drain the attached read-cache disk coordinator so its bounded
    // invalidation wait cancels its FakeAsync timer before teardown.
    await pumpUntilComplete(tester, sessionData.session.readCache.quiesced);
  });

  testWidgets('T14: closed client blocks web launch from open sheet',
      (tester) async {
    const url = 'https://example.com/gitlab/team/core/-/milestones/1';
    final server = ActivityEventServer([
      activityEvent(
        id: 18,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Milestone',
        targetTitle: 'Closing Client Milestone',
        targetUrl: url,
      ),
    ]);
    final sessionData = await createSession(tester, server);
    await pumpActivityWithSession(
      tester,
      sessionData.session,
      sessionData.api,
      sessionData.account,
    );

    await tester.tap(find.text('Closing Client Milestone'));
    await settleNetworkWidgets(tester);
    expect(inSheet(find.byKey(const ValueKey('activity-target-open-web'))),
        findsOneWidget);

    // Close the API client while sheet is open
    sessionData.api.close();

    await tester.tap(
        inSheet(find.byKey(const ValueKey('activity-target-open-web'))));
    await settleNetworkWidgets(tester);

    expect(launcher.launched, isEmpty,
        reason: 'Closed client must block external web launch');
    await pumpUntilComplete(tester, sessionData.session.readCache.quiesced);
  });

  testWidgets(
      'T15: incremented session generation blocks sheet actions while account and API remain identical',
      (tester) async {
    const url = 'https://example.com/gitlab/team/core/-/milestones/1';
    final server = ActivityEventServer([
      activityEvent(
        id: 19,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Milestone',
        targetTitle: 'Session Swapped Milestone',
        targetUrl: url,
      ),
    ]);
    final sessionData = await createSession(tester, server);
    await pumpActivityWithSession(
      tester,
      sessionData.session,
      sessionData.api,
      sessionData.account,
    );

    await tester.tap(find.text('Session Swapped Milestone'));
    await settleNetworkWidgets(tester);
    expect(find.byType(BottomSheet), findsOneWidget);

    // Preconditions before generation bump: account, API, client open
    expect(sessionData.session.active?.key, sessionData.account.key);
    expect(identical(sessionData.session.api, sessionData.api), isTrue);
    expect(sessionData.api.isClosed, isFalse);

    // Increment generation directly on the SAME session object without endSession.
    // session.generation is a public mutable int in SessionController.
    sessionData.session.generation++;

    // Assert preconditions remain satisfied: SAME session, SAME active account,
    // SAME open API instance. Only generation changed.
    expect(sessionData.session.active?.key, sessionData.account.key);
    expect(identical(sessionData.session.api, sessionData.api), isTrue);
    expect(sessionData.api.isClosed, isFalse);

    final projectGetsBefore = server.projectGets;

    // Tap "在 GitLab 開啟" -> dispatched zero
    await tester.tap(
        inSheet(find.byKey(const ValueKey('activity-target-open-web'))));
    await settleNetworkWidgets(tester);
    expect(launcher.launched, isEmpty,
        reason: 'Generation fence must block web launch even when account and API match');

    // Tap "查看專案" -> dispatched zero
    await tester.tap(
        inSheet(find.byKey(const ValueKey('activity-target-view-project'))));
    await settleNetworkWidgets(tester);
    expect(find.byType(ProjectPage), findsNothing,
        reason: 'Generation fence must block project push even when account and API match');
    expect(server.projectGets - projectGetsBefore, 0);
    await pumpUntilComplete(tester, sessionData.session.readCache.quiesced);
  });

  // ---------------------------------------------------------------------------
  // T16: Mobile Ergonomics (320dp viewport & 2x text scale)
  // ---------------------------------------------------------------------------

  testWidgets(
      'T16: 320dp viewport with 2x text scale has zero overflow and tap targets >= 48dp',
      (tester) async {
    const url = 'https://example.com/gitlab/team/core/-/milestones/1';
    final server = ActivityEventServer([
      activityEvent(
        id: 20,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Milestone',
        targetTitle: 'Very Long Milestone Description That Might Wrap Extensively',
        targetUrl: url,
      ),
    ]);
    await pumpActivity(
      tester,
      server,
      size: const Size(320, 600),
      textScale: 2.0,
    );

    await tester.tap(find.text('Very Long Milestone Description That Might Wrap Extensively'));
    await settleNetworkWidgets(tester);
    expect(find.byType(BottomSheet), findsOneWidget);

    // Verify button tap target sizes are >= 48x48
    final closeButtonFinder =
        inSheet(find.byKey(const ValueKey('activity-target-close')));
    final projectButtonFinder =
        inSheet(find.byKey(const ValueKey('activity-target-view-project')));
    final webButtonFinder =
        inSheet(find.byKey(const ValueKey('activity-target-open-web')));

    expect(closeButtonFinder, findsOneWidget);
    expect(projectButtonFinder, findsOneWidget);
    expect(webButtonFinder, findsOneWidget);

    final closeSize = tester.getSize(closeButtonFinder);
    final projectSize = tester.getSize(projectButtonFinder);
    final webSize = tester.getSize(webButtonFinder);

    expect(closeSize.width, greaterThanOrEqualTo(48.0));
    expect(closeSize.height, greaterThanOrEqualTo(48.0));
    expect(projectSize.width, greaterThanOrEqualTo(48.0));
    expect(projectSize.height, greaterThanOrEqualTo(48.0));
    expect(webSize.width, greaterThanOrEqualTo(48.0));
    expect(webSize.height, greaterThanOrEqualTo(48.0));

    // Ensure no layout overflow exceptions occurred
    expect(tester.takeException(), isNull);
  });

  // ---------------------------------------------------------------------------
  // Additional Official REST Events Docs & Review Cases
  // ---------------------------------------------------------------------------

  testWidgets(
      'Project Note docs example: routes to noteable_iid 377 without requesting 1312',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 21,
        projectId: 10,
        actionName: 'commented on',
        targetType: 'Note',
        targetIid: 1312,
        note: {
          'id': 9999,
          'noteable_type': 'Issue',
          'noteable_iid': 377,
          'body': 'Project Note body targeting issue 377',
        },
      ),
    ]);
    await pumpActivity(tester, server);

    await tester.tap(find.text('Project Note body targeting issue 377'));
    await settleNetworkWidgets(tester);

    expect(find.byType(WorkItemPage), findsOneWidget);
    expect(server.issueGets, 1);
    expect(
      server.requests.where((r) => r.uri.path.contains('/issues/1312')),
      isEmpty,
      reason: 'target_iid 1312 is Note own ID and must not be used as Issue IID',
    );
  });

  testWidgets(
      'User Note without noteable_iid opens explanation sheet without native routing',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 22,
        projectId: 10,
        actionName: 'commented on',
        targetType: 'Note',
        targetIid: 1312,
        note: {
          'id': 9999,
          'noteable_type': 'Issue',
          'noteable_id': 377, // Global noteable_id, no noteable_iid
          'body': 'User Note body without noteable_iid',
        },
      ),
    ]);
    await pumpActivity(tester, server);
    final projectGetsBefore = server.projectGets;

    await tester.tap(find.text('User Note body without noteable_iid'));
    await settleNetworkWidgets(tester);

    expect(find.byType(WorkItemPage), findsNothing);
    expect(find.byType(ProjectPage), findsNothing);
    expect(server.projectGets - projectGetsBefore, 0);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.text('這則議題動態缺少可辨識目標的資料，無法在 App 內開啟。')), findsOneWidget);
  });

  testWidgets('Note event with no note object opens explanation sheet',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 23,
        projectId: 10,
        actionName: 'commented on',
        targetType: 'Note',
        targetIid: 1312,
        targetTitle: 'Note with missing note body',
        note: null,
      ),
    ]);
    await pumpActivity(tester, server);
    final projectGetsBefore = server.projectGets;

    await tester.tap(find.text('Note with missing note body'));
    await settleNetworkWidgets(tester);

    expect(find.byType(WorkItemPage), findsNothing);
    expect(find.byType(ProjectPage), findsNothing);
    expect(server.projectGets - projectGetsBefore, 0);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.text('「其他 GitLab 動態」類型的動態目前沒有 App 內頁面。')), findsOneWidget);
  });

  testWidgets('Commit-noteable note opens explanation sheet', (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 24,
        projectId: 10,
        actionName: 'commented on',
        targetType: 'Note',
        note: {
          'id': 8888,
          'noteable_type': 'Commit',
          'body': 'Commit comment body',
        },
      ),
    ]);
    await pumpActivity(tester, server);
    final projectGetsBefore = server.projectGets;

    await tester.tap(find.text('Commit comment body'));
    await settleNetworkWidgets(tester);

    expect(find.byType(CommitDetailPage), findsNothing);
    expect(find.byType(ProjectPage), findsNothing);
    expect(server.projectGets - projectGetsBefore, 0);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.text('這則提交動態缺少可辨識目標的資料，無法在 App 內開啟。')), findsOneWidget);
  });

  testWidgets('author.web_url alone does not produce a web action',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 25,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Milestone',
        targetTitle: 'Profile URL Milestone',
        targetUrl: null, // No target_url
        author: {
          'id': 7,
          'name': 'Tester',
          'username': 'tester',
          'web_url': 'https://example.com/gitlab/tester',
        },
      ),
    ]);
    await pumpActivity(tester, server);

    await tester.tap(find.text('Profile URL Milestone'));
    await settleNetworkWidgets(tester);

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.byKey(const ValueKey('activity-target-open-web'))),
        findsNothing,
        reason: 'Author web_url must never be treated as the resource web link');
    expect(inSheet(find.text('此動態沒有屬於目前 GitLab 實例的有效連結，無法開啟。')), findsOneWidget);
  });

  testWidgets(
      'Row with missing project (projectId <= 0) shows sheet with no project button and zero requests',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 26,
        projectId: 0,
        actionName: 'opened',
        targetType: 'Issue',
        targetIid: 42,
        targetTitle: 'Orphaned Issue Event',
      ),
    ]);
    await pumpActivity(tester, server);

    await tester.tap(find.text('Orphaned Issue Event'));
    await settleNetworkWidgets(tester);

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.byKey(const ValueKey('activity-target-view-project'))),
        findsNothing,
        reason: 'Missing projectId must omit 查看專案 button');
    expect(server.nonEventRequests, isEmpty,
        reason: 'Zero network requests should be made for orphaned event');
  });

  testWidgets(
      'Launched web URL preserves exact query and fragment without credentials',
      (tester) async {
    const complexUrl =
        'https://example.com/gitlab/team/core/-/blob/main/doc.md?ref_type=heads&view=parallel#L10-L25';
    final server = ActivityEventServer([
      activityEvent(
        id: 27,
        projectId: 10,
        actionName: 'opened',
        targetType: 'WikiPage',
        targetTitle: 'Complex URL Event',
        targetUrl: complexUrl,
      ),
    ]);
    await pumpActivity(tester, server);

    await tester.tap(find.text('Complex URL Event'));
    await settleNetworkWidgets(tester);

    await tester.tap(
        inSheet(find.byKey(const ValueKey('activity-target-open-web'))));
    await settleNetworkWidgets(tester);

    expect(launcher.launched, [complexUrl],
        reason: 'Exact query and fragment must be preserved byte-for-byte');
  });

  testWidgets(
      'Exact sheet route closing avoids closing overlying cover route',
      (tester) async {
    const url = 'https://example.com/gitlab/team/core/-/milestones/1';
    final server = ActivityEventServer([
      activityEvent(
        id: 28,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Milestone',
        targetTitle: 'Overlying Route Milestone',
        targetUrl: url,
      ),
    ]);
    await pumpActivity(tester, server);

    await tester.tap(find.text('Overlying Route Milestone'));
    await settleNetworkWidgets(tester);
    expect(find.byType(BottomSheet), findsOneWidget);

    // Push a dialog over the sheet
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(BottomSheet)),
        builder: (_) => const AlertDialog(
          key: ValueKey('test-dialog'),
          title: Text('Overlying Dialog'),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('test-dialog')), findsOneWidget);

    // Close the sheet via close button's onPressed while dialog is covering it
    final closeFinder =
        inSheet(find.byKey(const ValueKey('activity-target-close')));
    tester.widget<TextButton>(closeFinder).onPressed!();
    await settleNetworkWidgets(tester);

    // The covering dialog should still be present and ActivityPage remains!
    expect(find.byKey(const ValueKey('test-dialog')), findsOneWidget);
    expect(find.byType(ActivityPage), findsOneWidget);

    // Dismiss dialog to clean up
    Navigator.of(tester.element(find.byKey(const ValueKey('test-dialog')))).pop();
    await settleNetworkWidgets(tester);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets(
      'Search page user-events smoke: activityRow renders and taps into sheet without constructor fence assumptions',
      (tester) async {
    // Note: This smoke test renders activityRow directly inside ProviderScope,
    // mirroring search_page.dart:271. It validates row-level fence behavior without
    // asserting on full SearchPage structure; full SearchPage test coverage is a stated gap.
    final server = ActivityEventServer([
      activityEvent(
        id: 29,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Milestone',
        targetTitle: 'Search Feed Milestone',
      ),
    ]);
    final sessionData = await createSession(tester, server);

    // Render activityRow directly as done in search_page.dart:271
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(sessionData.session)],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => activityRow(
                context,
                server.events.first,
                account: sessionData.account,
                api: sessionData.api,
              ),
            ),
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    expect(find.text('Search Feed Milestone'), findsOneWidget);
    await tester.tap(find.text('Search Feed Milestone'));
    await settleNetworkWidgets(tester);

    expect(find.byType(BottomSheet), findsOneWidget);
    expect(inSheet(find.text('「里程碑」類型的動態目前沒有 App 內頁面。')), findsOneWidget);
    expect(inSheet(find.byKey(const ValueKey('activity-target-view-project'))),
        findsOneWidget);
    await pumpUntilComplete(tester, sessionData.session.readCache.quiesced);
  });

  // ---------------------------------------------------------------------------
  // Positive In-Scope Sheet Actions (Live ProviderScope Session / 27 Forecast)
  // ---------------------------------------------------------------------------

  testWidgets(
      'In-scope positive: viewing project from sheet opens ProjectPage with GET delta under live session',
      (tester) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 30,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Milestone',
        targetTitle: 'Positive In-Scope Project Milestone',
      ),
    ], projectHeaders: const {
      'cache-control': ['no-store'],
    });
    final sessionData = await createSession(tester, server);
    await pumpActivityWithSession(
      tester,
      sessionData.session,
      sessionData.api,
      sessionData.account,
    );

    final projectGetsBefore = server.projectDetailGets;
    await tester.tap(find.text('Positive In-Scope Project Milestone'));
    await settleNetworkWidgets(tester);
    expect(find.byType(BottomSheet), findsOneWidget);

    await tester.tap(
        inSheet(find.byKey(const ValueKey('activity-target-view-project'))));
    await settleNetworkWidgets(tester);

    expect(find.byType(ProjectPage), findsOneWidget);
    expect(tester.widget<ProjectPage>(find.byType(ProjectPage)).project.id, 10);
    expect(server.projectDetailGets - projectGetsBefore, 2,
        reason: 'Licensed project lookup and uncached overview decoration');
    expect(find.byType(BottomSheet), findsNothing);
    await pumpUntilComplete(tester, sessionData.session.readCache.quiesced);
  });

  testWidgets(
      'In-scope positive: opening safe web link from sheet launches exact URI under live session',
      (tester) async {
    const targetUri =
        'https://example.com/gitlab/team/core/-/milestones/1?tab=issues#note-123';
    final server = ActivityEventServer([
      activityEvent(
        id: 31,
        projectId: 10,
        actionName: 'opened',
        targetType: 'Milestone',
        targetTitle: 'Positive In-Scope Web Milestone',
        targetUrl: targetUri,
      ),
    ]);
    final sessionData = await createSession(tester, server);
    await pumpActivityWithSession(
      tester,
      sessionData.session,
      sessionData.api,
      sessionData.account,
    );

    await tester.tap(find.text('Positive In-Scope Web Milestone'));
    await settleNetworkWidgets(tester);
    expect(find.byType(BottomSheet), findsOneWidget);

    await tester.tap(
        inSheet(find.byKey(const ValueKey('activity-target-open-web'))));
    await settleNetworkWidgets(tester);

    expect(launcher.launched, [targetUri],
        reason: 'Exact URI query and fragment must be preserved byte-for-byte');
    expect(find.byType(BottomSheet), findsNothing);
    await pumpUntilComplete(tester, sessionData.session.readCache.quiesced);
  });

  testWidgets('a WorkItem event opens the work item page named by its link', (
    tester,
  ) async {
    final server = ActivityEventServer([
      activityEvent(
        id: 32,
        projectId: 10,
        actionName: 'opened',
        targetType: 'WorkItem',
        targetIid: 5,
        targetTitle: 'Work item target',
        targetUrl: 'https://example.com/gitlab/team/core/-/work_items/5',
      ),
    ]);
    await pumpActivity(tester, server);

    await tester.tap(find.text('Work item target'));
    await settleNetworkWidgets(tester);

    expect(find.byType(BottomSheet), findsNothing);
    final page = tester.widget<GraphWorkItemDetailPage>(
      find.byType(GraphWorkItemDetailPage),
    );
    expect(page.iid, 5);
    expect(page.project?.id, 10);
    expect(launcher.launched, isEmpty);
  });
}
