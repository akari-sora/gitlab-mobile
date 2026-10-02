import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/repository_ref.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
import 'package:gitlab_mobile/features/workspace/pipeline_graph_page.dart';
import 'package:gitlab_mobile/features/workspace/registries_page.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/resource_share.dart';
import 'support/fake_adapter.dart';
import 'support/workspace_fixture.dart';
import 'workspace_widget_test.dart' show workspaceHost, settleWorkspace;

class _SubscriptionFixture extends WorkspaceFixture {
  bool written = false;
  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (request.method == 'POST' &&
        request.uri.path.endsWith('/issues/1/subscribe')) {
      written = true;
    }
    if (written &&
        request.method == 'GET' &&
        request.uri.path.endsWith('/issues/1')) {
      return jsonResponse({
        'message': 'Synthetic refresh failure',
      }, status: 503);
    }
    return super.respond(request);
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('subscription success remains visible after refresh failure', (
    tester,
  ) async {
    final fixture = _SubscriptionFixture();
    fixture.issues[1] = {
      ...fixture.issue(1, 'Synthetic issue'),
      'subscribed': false,
    };
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      workspaceHost(
        WorkItemPage(
          account: fixture.account,
          api: fixture.api,
          project: fixture.project,
          resource: 'issues',
          iid: 1,
        ),
      ),
    );
    await settleWorkspace(tester);
    final toggle = find.byKey(const ValueKey('work-item-subscribe'));
    await tester.scrollUntilVisible(
      toggle,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ListView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(toggle);
    await settleWorkspace(tester);
    expect(fixture.written, isTrue);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(find.text('已開啟通知'), findsOneWidget);
  });

  for (final resource in ['issues', 'merge_requests']) {
    testWidgets(
      '$resource exposes a canonical direct share at 320dp and 2x text',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 1000);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = WorkspaceFixture();
        fixture.issues[1] = fixture.issue(1, 'Synthetic title');
        addTearDown(fixture.api.close);
        await tester.pumpWidget(
          workspaceHost(
            WorkItemPage(
              account: fixture.account,
              api: fixture.api,
              project: fixture.project,
              resource: resource,
              iid: 1,
            ),
            scale: 2,
          ),
        );
        await settleWorkspace(tester);
        final share = tester.widget<ResourceShareButton>(
          find.byType(ResourceShareButton),
        );
        expect(
          share.uri.toString(),
          'https://example.com/gitlab/studio/mobile-workspace/-/$resource/1',
        );
        expect(find.byTooltip('分享連結'), findsOneWidget);
        expect(
          tester.getRect(find.byTooltip('分享連結')).right,
          lessThanOrEqualTo(320),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'pipeline links use global ID while its header displays project IID',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = WorkspaceFixture();
      final api = testApi(
        FakeAdapter((request) {
          if (request.uri.path.endsWith('/pipelines/99')) {
            return jsonResponse({'id': 99, 'iid': 4, 'status': 'success'});
          }
          if (request.uri.path.endsWith('test_report_summary')) {
            return jsonResponse({
              'total': {'count': 0},
              'test_suites': <Object>[],
            });
          }
          return jsonResponse([]);
        }),
      );
      addTearDown(api.close);
      addTearDown(fixture.api.close);
      await tester.pumpWidget(
        workspaceHost(
          PipelinePage(
            account: fixture.account,
            api: api,
            project: fixture.project,
            id: 99,
          ),
          scale: 2,
        ),
      );
      await settleWorkspace(tester);
      expect(find.text('Pipeline #4'), findsOneWidget);
      expect(
        tester
            .widget<ResourceShareButton>(find.byType(ResourceShareButton))
            .uri
            .path,
        endsWith('/-/pipelines/99'),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'repository share pins SHA and selected line rather than slash-bearing branch',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final api = testApi(
        FakeAdapter((request) {
          if (request.method == 'HEAD') {
            return ResponseBody.fromString(
              '',
              200,
              headers: {
                'x-gitlab-size': ['21'],
                'x-gitlab-last-commit-id': [WorkspaceFixture.sha],
              },
            );
          }
          if (request.uri.path.endsWith('/raw')) {
            return ResponseBody.fromString('line 1\nline 2\nline 3\n', 200);
          }
          return jsonResponse(<Object>[]);
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        workspaceHost(
          RepositoryFilePage(
            account: fixture.account,
            api: api,
            project: fixture.project,
            ref: const RepositoryRef(
              kind: RepositoryRefKind.branch,
              name: 'feature/navigation',
              sha: WorkspaceFixture.sha,
              protected: false,
            ),
            filePath: 'lib/main.dart',
            targetLine: 3,
          ),
        ),
      );
      await settleWorkspace(tester);
      final uri = tester
          .widget<ResourceShareButton>(find.byType(ResourceShareButton))
          .uri;
      expect(
        uri.toString(),
        'https://example.com/gitlab/studio/mobile-workspace/-/blob/${WorkspaceFixture.sha}/lib/main.dart#L3',
      );
    },
  );

  testWidgets(
    'job link follows a retried attempt and refuses a replacement route owner',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final api = testApi(
        FakeAdapter((request) {
          if (request.method == 'POST') {
            return jsonResponse({
              'id': 88,
              'name': 'Synthetic retry',
              'status': 'pending',
            });
          }
          if (request.uri.path.endsWith('/trace')) {
            return ResponseBody.fromString('Synthetic log\n', 200);
          }
          final id = request.uri.path.endsWith('/88') ? 88 : 77;
          return jsonResponse({
            'id': id,
            'name': 'Synthetic job',
            'status': id == 77 ? 'failed' : 'pending',
          });
        }),
      );
      addTearDown(api.close);
      Widget host(int id) => workspaceHost(
        JobLogPage(
          account: fixture.account,
          api: api,
          project: fixture.project,
          id: id,
        ),
      );
      await tester.pumpWidget(host(77));
      await settleWorkspace(tester);
      expect(
        tester
            .widget<ResourceShareButton>(find.byType(ResourceShareButton))
            .uri
            .path,
        endsWith('/-/jobs/77'),
      );
      await tester.tap(find.byKey(const ValueKey('job-banner-retry-77')));
      await settleWorkspace(tester);
      await tester.tap(find.widgetWithText(FilledButton, '確認'));
      await settleWorkspace(tester);
      expect(
        tester
            .widget<ResourceShareButton>(find.byType(ResourceShareButton))
            .uri
            .path,
        endsWith('/-/jobs/88'),
      );
      await tester.pumpWidget(host(99));
      await settleWorkspace(tester);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.share_outlined),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'diff file shares its canonical merge request diffs URL and closes with its API',
    (tester) async {
      const headSha = '3333333333333333333333333333333333333333';
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final api = testApi(
        FakeAdapter((request) {
          if (request.uri.path.endsWith('/versions')) {
            return jsonResponse([
              {'id': 1, 'head_commit_sha': headSha},
            ]);
          }
          if (request.uri.path.endsWith('/versions/1')) {
            return jsonResponse({
              'id': 1,
              'head_commit_sha': headSha,
              'base_commit_sha': '1111111111111111111111111111111111111111',
              'start_commit_sha': '2222222222222222222222222222222222222222',
              'diffs': [
                {
                  'old_path': 'lib/main.dart',
                  'new_path': 'lib/main.dart',
                  'new_file': false,
                  'renamed_file': false,
                  'deleted_file': false,
                  'diff': '@@ -1 +1 @@\n-old\n+new\n',
                },
              ],
            });
          }
          return jsonResponse(<Object>[]);
        }),
      );
      addTearDown(() {
        if (!api.isClosed) api.close();
      });

      await tester.pumpWidget(
        workspaceHost(
          ReviewDiffPage(
            account: fixture.account,
            api: api,
            project: fixture.project,
            iid: 12,
            expectedSha: headSha,
          ),
        ),
      );
      await settleWorkspace(tester);
      await tester.tap(find.text('lib/main.dart'));
      await settleWorkspace(tester);

      final share = tester.widget<ResourceShareButton>(
        find.byType(ResourceShareButton),
      );
      expect(
        share.uri.toString(),
        'https://example.com/gitlab/studio/mobile-workspace/-/merge_requests/12/diffs',
      );

      api.close();
      expect(share.isCurrent?.call(), isFalse);
    },
  );

  testWidgets(
    'pipeline graph shares the global pipeline ID and closes with its API',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final api = testApi(
        FakeAdapter(
          (_) => jsonResponse({
            'data': {
              'project': {
                'id': 'gid://gitlab/Project/42',
                'pipeline': {
                  'id': 'gid://gitlab/Ci::Pipeline/99',
                  'iid': '4',
                  'stages': {
                    'nodes': <Object>[],
                    'pageInfo': {'hasNextPage': false},
                  },
                  'jobs': {
                    'nodes': <Object>[],
                    'pageInfo': {'hasNextPage': false, 'endCursor': null},
                  },
                },
              },
            },
          }),
        ),
      );
      addTearDown(() {
        if (!api.isClosed) api.close();
      });

      await tester.pumpWidget(
        workspaceHost(
          PipelineGraphPage(
            account: fixture.account,
            api: api,
            project: fixture.project,
            pipelineId: 99,
          ),
        ),
      );
      await settleWorkspace(tester);
      final share = tester.widget<ResourceShareButton>(
        find.byType(ResourceShareButton),
      );
      expect(share.uri.path, endsWith('/-/pipelines/99'));

      api.close();
      expect(share.isCurrent?.call(), isFalse);
    },
  );

  testWidgets(
    'package detail shares its numeric package ID and closes with its API',
    (tester) async {
      final fixture = WorkspaceFixture();
      addTearDown(fixture.api.close);
      final api = testApi(
        FakeAdapter((request) {
          if (request.uri.path.endsWith('/packages/73')) {
            return jsonResponse({
              'id': 73,
              'name': 'mobile-kit',
              'version': '1.2.3',
              'package_type': 'npm',
              'status': 'default',
              'created_at': '2026-10-01T08:00:00Z',
            });
          }
          if (request.uri.path.endsWith('/packages/73/package_files')) {
            return jsonResponse(<Object>[]);
          }
          return jsonResponse(<Object>[]);
        }),
      );
      addTearDown(() {
        if (!api.isClosed) api.close();
      });

      await tester.pumpWidget(
        workspaceHost(
          PackageDetailPage(
            account: fixture.account,
            api: api,
            project: fixture.project,
            packageId: 73,
            isCurrent: () => true,
          ),
        ),
      );
      await settleWorkspace(tester);
      final share = tester.widget<ResourceShareButton>(
        find.byType(ResourceShareButton),
      );
      expect(share.uri.path, endsWith('/-/packages/73'));

      api.close();
      expect(share.isCurrent?.call(), isFalse);
    },
  );
}
