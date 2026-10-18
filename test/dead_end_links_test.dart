import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/repository_ref.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/commit_page.dart';
import 'package:gitlab_mobile/features/workspace/project_extras.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/features/workspace/search_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost;

final class _FakeUrlLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final List<String> launched = [];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

String _apiPath(RequestOptions request) {
  final parts = request.uri.pathSegments;
  return parts.skip(parts.indexOf('v4') + 1).join('/');
}

/// A binary blob, a merge request pipeline and a job that names its pipeline
/// on top of the shared workspace fixture.
final class _LinkFixture extends WorkspaceFixture {
  static const mrPipelineSha = 'cccccccccccccccccccccccccccccccccccccccc';

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final path = _apiPath(request);
    if (path == 'projects/42/repository/files/assets/logo.png') {
      return ResponseBody.fromString(
        '',
        200,
        headers: {
          'x-gitlab-size': ['12'],
          'x-gitlab-last-commit-id': [WorkspaceFixture.sha],
        },
      );
    }
    if (path == 'projects/42/repository/files/assets/logo.png/raw') {
      return ResponseBody.fromBytes(
        const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13],
        200,
        headers: {
          'content-type': ['image/png'],
        },
      );
    }
    if (path == 'projects/42/pipelines/77') {
      return jsonResponse({
        'id': 77,
        'iid': 5,
        'ref': 'refs/merge-requests/12/head',
        'sha': mrPipelineSha,
        'status': 'success',
        'source': 'merge_request_event',
      });
    }
    if (path == 'projects/42/pipelines/77/jobs') return jsonResponse(<Json>[]);
    if (path == 'projects/42/jobs/501') {
      return jsonResponse({
        ...job(501),
        'ref': 'feature/navigation',
        'pipeline': {
          'id': 77,
          'iid': 5,
          'project_id': 42,
          'ref': 'feature/navigation',
          'status': 'success',
        },
      });
    }
    return super.respond(request);
  }
}

void _phone(WidgetTester tester, {double height = 900}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(412, height);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

_FakeUrlLauncher _stubLauncher() {
  final launcher = _FakeUrlLauncher();
  final original = UrlLauncherPlatform.instance;
  UrlLauncherPlatform.instance = launcher;
  addTearDown(() => UrlLauncherPlatform.instance = original);
  return launcher;
}

void main() {
  testWidgets(
    'a binary file offers to open its blob page in GitLab at the pinned commit',
    (tester) async {
      _phone(tester);
      final launcher = _stubLauncher();
      final fixture = _LinkFixture();
      addTearDown(fixture.api.close);
      await tester.pumpWidget(
        workspaceHost(
          RepositoryFilePage(
            account: fixture.account,
            api: fixture.api,
            project: fixture.project,
            ref: const RepositoryRef(
              kind: RepositoryRefKind.branch,
              name: 'main',
              sha: WorkspaceFixture.sha,
              protected: false,
            ),
            filePath: 'assets/logo.png',
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      expect(find.text('目前無法預覽此內容'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '在 GitLab 開啟'));
      await tester.pump();
      expect(launcher.launched, [
        'https://example.com/gitlab/studio/mobile-workspace/-/blob/${WorkspaceFixture.sha}/assets/logo.png',
      ]);
    },
  );

  testWidgets(
    'a merge request pipeline links its ref to the MR and its SHA to the commit',
    (tester) async {
      _phone(tester);
      final fixture = _LinkFixture();
      addTearDown(fixture.api.close);
      await tester.pumpWidget(
        workspaceHost(
          PipelinePage(
            account: fixture.account,
            api: fixture.api,
            project: fixture.project,
            id: 77,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      await tester.tap(find.text('refs/merge-requests/12/head'));
      await settleNetworkWidgets(tester);
      final mr = tester.widget<WorkItemPage>(find.byType(WorkItemPage));
      expect((mr.resource, mr.iid, mr.project.id), ('merge_requests', 12, 42));
      expect(find.text('Improve private-project navigation'), findsOneWidget);

      Navigator.of(tester.element(find.byType(WorkItemPage))).pop();
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('cccccccc'));
      await settleNetworkWidgets(tester);
      final commit = tester.widget<CommitDetailPage>(
        find.byType(CommitDetailPage),
      );
      expect((commit.sha, commit.project.id), (_LinkFixture.mrPipelineSha, 42));
    },
  );

  test('only merge request refs name a merge request', () {
    expect(mergeRequestIidOfRef('refs/merge-requests/12/head'), 12);
    expect(mergeRequestIidOfRef('refs/merge-requests/12/merge'), 12);
    expect(mergeRequestIidOfRef('refs/merge-requests/12/train'), 12);
    expect(mergeRequestIidOfRef('main'), isNull);
    expect(mergeRequestIidOfRef('refs/merge-requests/0/head'), isNull);
    expect(mergeRequestIidOfRef('feature/refs/merge-requests/12/head'), isNull);
  });

  testWidgets(
    'a job shows its pipeline, stage and ref and links back to the pipeline',
    (tester) async {
      _phone(tester);
      final fixture = _LinkFixture();
      addTearDown(fixture.api.close);
      await tester.pumpWidget(
        workspaceHost(
          JobLogPage(
            account: fixture.account,
            api: fixture.api,
            project: fixture.project,
            id: 501,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      expect(find.text('verify'), findsOneWidget);
      expect(find.text('feature/navigation'), findsOneWidget);
      await tester.tap(find.text('Pipeline #5'));
      await settleNetworkWidgets(tester);
      final pipeline = tester.widget<PipelinePage>(find.byType(PipelinePage));
      expect((pipeline.id, pipeline.project.id), (77, 42));
    },
  );

  testWidgets('the More tab fork snack bar opens the new fork', (tester) async {
    _phone(tester);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      workspaceHost(
        Scaffold(
          body: ProjectMoreTab(
            account: fixture.account,
            api: fixture.api,
            project: fixture.project,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Fork'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await settleNetworkWidgets(tester);
    expect(fixture.forks, 1);

    await tester.tap(find.widgetWithText(SnackBarAction, '開啟'));
    await settleNetworkWidgets(tester);
    final page = tester.widget<ProjectPage>(find.byType(ProjectPage));
    expect(
      (
        page.project.id,
        page.project.path,
        page.account.key,
        identical(page.api, fixture.api),
      ),
      (4242, 'developer/mobile-workspace', fixture.account.key, true),
    );
  });

  testWidgets('the overview fork snack bar opens the new fork', (tester) async {
    _phone(tester);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      workspaceHost(
        ProjectPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.byTooltip('Fork'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '確認'));
    await settleNetworkWidgets(tester);
    expect(fixture.forks, 1);

    await tester.tap(find.widgetWithText(SnackBarAction, '開啟'));
    await settleNetworkWidgets(tester);
    final pages = tester
        .widgetList<ProjectPage>(find.byType(ProjectPage, skipOffstage: false))
        .toList();
    expect(pages.map((page) => page.project.id), [42, 4242]);
    expect(identical(pages.last.api, fixture.api), isTrue);
  });

  testWidgets(
    'the author, assignees and reviewers of a merge request open their profiles',
    (tester) async {
      _phone(tester, height: 1600);
      final fixture = WorkspaceFixture();
      fixture.mergeFields.addAll({
        'assignees': [
          {'id': 8, 'username': 'reviewer', 'name': 'Reviewer'},
        ],
        'reviewers': [
          {'id': 9, 'username': 'qa', 'name': 'QA'},
        ],
      });
      addTearDown(fixture.api.close);
      await tester.pumpWidget(
        workspaceHost(
          WorkItemPage(
            account: fixture.account,
            api: fixture.api,
            project: fixture.project,
            resource: 'merge_requests',
            iid: 12,
          ),
        ),
      );
      await settleNetworkWidgets(tester);

      Future<void> openAndCheck(Finder target, int id, String username) async {
        await tester.ensureVisible(target);
        await tester.tap(target);
        await settleNetworkWidgets(tester);
        final page = tester.widget<UserPage>(find.byType(UserPage));
        expect(
          (valueInt(page.user, 'id'), page.account.key),
          (id, fixture.account.key),
        );
        expect(find.text('@$username'), findsWidgets);
        Navigator.of(tester.element(find.byType(UserPage))).pop();
        await settleNetworkWidgets(tester);
      }

      await openAndCheck(
        find.byKey(const ValueKey('work-item-author')),
        7,
        'developer',
      );
      await openAndCheck(
        find.byKey(const ValueKey('assignee-8')),
        8,
        'reviewer',
      );
      await openAndCheck(find.byKey(const ValueKey('reviewer-9')), 9, 'qa');
    },
  );

  testWidgets('a project member opens their profile', (tester) async {
    _phone(tester);
    final fixture = WorkspaceFixture();
    addTearDown(fixture.api.close);
    final members = <Json>[
      {'id': 8, 'username': 'reviewer', 'name': 'Reviewer', 'access_level': 30},
    ];
    final adapter = FakeAdapter(
      (request) => _apiPath(request) == 'projects/42/members/all'
          ? jsonResponse(members)
          : fixture.respond(request),
    );
    final api = testApi(adapter);
    addTearDown(api.close);
    await tester.pumpWidget(
      workspaceHost(
        MembersPage(
          account: fixture.account,
          api: api,
          project: fixture.project,
        ),
      ),
    );
    await settleNetworkWidgets(tester);

    await tester.tap(find.text('Reviewer'));
    await settleNetworkWidgets(tester);
    final page = tester.widget<UserPage>(find.byType(UserPage));
    expect(valueInt(page.user, 'id'), 8);
    expect(identical(page.api, api), isTrue);
  });
}
