import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/repository_ref.dart';
import 'package:gitlab_mobile/core/syntax_highlighter.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/shell/home_page.dart';
import 'package:gitlab_mobile/features/workspace/boards_page.dart';
import 'package:gitlab_mobile/features/workspace/ci_overview_page.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/commit_page.dart';
import 'package:gitlab_mobile/features/workspace/compare_page.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';
import 'package:gitlab_mobile/features/workspace/file_history.dart';
import 'package:gitlab_mobile/features/workspace/pipeline_graph_page.dart';
import 'package:gitlab_mobile/features/workspace/project_analytics_page.dart';
import 'package:gitlab_mobile/features/workspace/project_more_page.dart';
import 'package:gitlab_mobile/features/workspace/project_overview.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/projects_page.dart';
import 'package:gitlab_mobile/features/workspace/records_feed.dart';
import 'package:gitlab_mobile/features/workspace/repository_page.dart';
import 'package:gitlab_mobile/features/workspace/snippets_page.dart';
import 'package:gitlab_mobile/features/workspace/work_item_page.dart';
import 'package:gitlab_mobile/shared/code_text_view.dart';
import 'package:gitlab_mobile/shared/hub_ui.dart';
import 'package:gitlab_mobile/shared/markdown_view.dart';
import 'package:gitlab_mobile/shared/skeleton.dart';
import 'package:gitlab_mobile/shared/workspace_ui.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';
import 'workspace_widget_test.dart' show workspaceHost;

final _instance = GitLabInstance.parse('https://example.com/gitlab');

final _account = Account(
  instance: _instance,
  user: const GitLabUser(id: 7, username: 'tester', name: 'Tester'),
  token: 'synthetic-test-token',
);

const _project = Project(
  id: 42,
  name: 'Mobile',
  path: 'studio/mobile',
  visibility: 'private',
  defaultBranch: 'main',
);

void _expectNoSpinners(WidgetTester tester) {
  expect(
    find.byType(CircularProgressIndicator),
    findsNothing,
    reason: 'First load must show a skeleton, not CircularProgressIndicator',
  );
  expect(
    find.byType(LinearProgressIndicator),
    findsNothing,
    reason: 'First load must show a skeleton, not LinearProgressIndicator',
  );
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets(
    'reduced motion stops ticker, schedules 0 callbacks, and paints static faint blocks',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(body: MarkdownSkeleton()),
          ),
        ),
      );
      expect(tester.binding.transientCallbackCount, 0);
      expect(find.byType(ShaderMask), findsNothing);

      final firstColor =
          (tester
                      .widget<DecoratedBox>(
                        find.descendant(
                          of: find.byType(SkeletonBone).first,
                          matching: find.byType(DecoratedBox),
                        ),
                      )
                      .decoration
                  as BoxDecoration)
              .color;

      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(milliseconds: 1000));
      expect(tester.binding.transientCallbackCount, 0);

      final laterColor =
          (tester
                      .widget<DecoratedBox>(
                        find.descendant(
                          of: find.byType(SkeletonBone).first,
                          matching: find.byType(DecoratedBox),
                        ),
                      )
                      .decoration
                  as BoxDecoration)
              .color;
      expect(laterColor, equals(firstColor));
    },
  );

  testWidgets(
    'normal motion animates with one ShaderMask and one RepaintBoundary per skeleton group',
    (tester) async {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey(brightness),
            theme: ThemeData(brightness: brightness, useMaterial3: true),
            home: const Scaffold(body: DetailSkeleton()),
          ),
        );
        expect(tester.binding.transientCallbackCount, 1);
        expect(
          find.descendant(
            of: find.byType(DetailSkeleton),
            matching: find.byType(ShaderMask),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(ShaderMask),
            matching: find.byType(RepaintBoundary),
          ),
          findsOneWidget,
        );
        await tester.pump(const Duration(milliseconds: 750));
        expect(tester.binding.transientCallbackCount, 1);
      }
    },
  );

  testWidgets('TickerMode(enabled: false) schedules no frames', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TickerMode(enabled: false, child: CodeSkeleton()),
        ),
      ),
    );
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pump(const Duration(milliseconds: 750));
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets(
    'each skeleton exposes exactly one 正在載入 live region and excludes bones from semantics',
    (tester) async {
      final skeletons = <Widget>[
        const RowsSkeleton(),
        const ListSkeleton(),
        const MarkdownSkeleton(),
        const CodeSkeleton(),
        const DiffSkeleton(),
        const LogSkeleton(),
        const DetailSkeleton(),
        const HomeSectionSkeleton(),
        const PipelineSkeleton(),
        const CompareSkeleton(),
        const EditorSkeleton(),
        const CommitSkeleton(),
        const SnippetDetailSkeleton(),
        const BoardColumnsSkeleton(),
        const StageColumnsSkeleton(),
        const ChartSkeleton(),
      ];

      final semantics = tester.ensureSemantics();
      try {
        for (final skeleton in skeletons) {
          await tester.pumpWidget(
            MaterialApp(home: Scaffold(body: skeleton)),
          );
          final finder = find.bySemanticsLabel('正在載入');
          expect(
            finder,
            findsOneWidget,
            reason: '${skeleton.runtimeType} must have one 正在載入 node',
          );
          final node = tester.getSemantics(finder);
          final data = node.getSemanticsData();
          expect(
            data.flagsCollection.isLiveRegion,
            isTrue,
            reason: '${skeleton.runtimeType} must be a live region',
          );
          expect(
            node.childrenCount,
            0,
            reason:
                '${skeleton.runtimeType} bones must be excluded from semantics',
          );
          expect(
            data.flagsCollection.isFocused,
            Tristate.none,
            reason: '${skeleton.runtimeType} must never take focus',
          );
          final bones = tester.elementList(find.byType(SkeletonBone)).toList();
          expect(bones, isNotEmpty);
          for (final bone in bones) {
            expect(
              bone.renderObject?.debugSemantics,
              isNull,
              reason: 'SkeletonBone must not be in the semantics tree',
            );
          }
        }
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('shimmer sweep direction flips in RTL', (tester) async {
    const bounds = Rect.fromLTWH(0, 0, 200, 80);
    const ltrEarly = ShimmerGradientTransform(
      progress: 0.25,
      textDirection: TextDirection.ltr,
    );
    const ltrLate = ShimmerGradientTransform(
      progress: 0.75,
      textDirection: TextDirection.ltr,
    );
    const rtlEarly = ShimmerGradientTransform(
      progress: 0.25,
      textDirection: TextDirection.rtl,
    );
    const rtlLate = ShimmerGradientTransform(
      progress: 0.75,
      textDirection: TextDirection.rtl,
    );

    expect(ltrEarly.dx, closeTo(-0.375, 1e-6));
    expect(ltrLate.dx, closeTo(0.375, 1e-6));
    expect(rtlEarly.dx, closeTo(0.375, 1e-6));
    expect(rtlLate.dx, closeTo(-0.375, 1e-6));
    expect(ltrEarly.dx, lessThan(ltrLate.dx));
    expect(rtlEarly.dx, greaterThan(rtlLate.dx));

    final ltrMatrix = ltrEarly.transform(bounds)!;
    final rtlMatrix = rtlEarly.transform(bounds)!;
    expect(ltrMatrix.getTranslation().x, closeTo(-75.0, 1e-6));
    expect(rtlMatrix.getTranslation().x, closeTo(75.0, 1e-6));

    late LinearGradient ltrGrad;
    late LinearGradient rtlGrad;
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            Directionality(
              textDirection: TextDirection.ltr,
              child: Builder(
                builder: (context) {
                  ltrGrad = SkeletonShimmer.gradientFor(
                    context,
                    progress: 0.25,
                  );
                  return const SizedBox.shrink();
                },
              ),
            ),
            Directionality(
              textDirection: TextDirection.rtl,
              child: Builder(
                builder: (context) {
                  rtlGrad = SkeletonShimmer.gradientFor(
                    context,
                    progress: 0.25,
                  );
                  return const SizedBox.shrink();
                },
              ),
            ),
          ],
        ),
      ),
    );
    final ltrTransform = ltrGrad.transform! as ShimmerGradientTransform;
    final rtlTransform = rtlGrad.transform! as ShimmerGradientTransform;
    expect(ltrTransform.textDirection, TextDirection.ltr);
    expect(rtlTransform.textDirection, TextDirection.rtl);
    expect(ltrTransform.dx, equals(-rtlTransform.dx));
  });

  testWidgets(
    'no jump: skeletons align with completed production widgets and line pitches',
    (tester) async {
      final dummyApi = testApi(FakeAdapter((_) => jsonResponse({})));
      addTearDown(dummyApi.close);

      // 1. README first block: MarkdownSkeleton vs real MarkdownView
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MarkdownSkeleton(padding: ProjectOverview.readmePadding),
          ),
        ),
      );
      final mdBoneTopLeft = tester.getTopLeft(find.byType(SkeletonBone).first);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: ProjectOverview.readmePadding,
              child: MarkdownView(
                '# Heading\n\nFirst paragraph',
                base: Uri.parse('https://example.com'),
                api: dummyApi,
                projectId: 1,
                projectWeb: Uri.parse('https://example.com/p'),
                projectPath: 'p',
                account: _account,
              ),
            ),
          ),
        ),
      );
      final mdFirstBlockTopLeft = tester.getTopLeft(
        find
            .descendant(
              of: find.byType(MarkdownView),
              matching: find.byType(RichText),
            )
            .first,
      );
      expect(mdBoneTopLeft, equals(mdFirstBlockTopLeft));
      expect(
        mdBoneTopLeft,
        equals(
          Offset(
            ProjectOverview.readmePadding.left,
            ProjectOverview.readmePadding.top,
          ),
        ),
      );

      // 2. CodeTextView first text line and >=26dp line pitch vs CodeSkeleton
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CodeSkeleton())),
      );
      final codeGutterBone = tester.getTopLeft(
        find.byType(SkeletonBone).at(0),
      );
      final codeFirstTextBone = tester.getTopLeft(
        find.byType(SkeletonBone).at(1),
      );
      final codeSecondTextBone = tester.getTopLeft(
        find.byType(SkeletonBone).at(3),
      );
      expect(
        codeSecondTextBone.dy - codeFirstTextBone.dy,
        greaterThanOrEqualTo(26.0),
      );
      final vertical = ScrollController();
      final horizontal = ScrollController();
      addTearDown(vertical.dispose);
      addTearDown(horizontal.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeTextView(
              index: CodeTextIndex('void main() {}\nprint(1);'),
              visibleIndices: const [0, 1],
              filePath: 'main.dart',
              syntaxSpans: SyntaxSpanCache(),
              wrap: true,
              vertical: vertical,
              horizontal: horizontal,
            ),
          ),
        ),
      );
      final codeRow0 = tester.getTopLeft(
        find
            .descendant(
              of: find.byType(CodeTextView),
              matching: find.byType(InkWell),
            )
            .at(0),
      );
      final codeRow1 = tester.getTopLeft(
        find
            .descendant(
              of: find.byType(CodeTextView),
              matching: find.byType(InkWell),
            )
            .at(1),
      );
      final codeFirstTextReal = tester.getTopLeft(
        find
            .descendant(
              of: find.byType(CodeTextView),
              matching: find.byType(RichText),
            )
            .at(1),
      );
      expect(codeGutterBone.dy, closeTo(codeRow0.dy, 8.0));
      expect(codeFirstTextBone.dx, equals(codeFirstTextReal.dx));
      expect(codeRow1.dy - codeRow0.dy, greaterThanOrEqualTo(26.0));
      expect(
        codeSecondTextBone.dy - codeFirstTextBone.dy,
        equals(codeRow1.dy - codeRow0.dy),
      );

      // 3. DiffSkeleton vs completed ReviewDiffPage header
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: DiffSkeleton(padding: ReviewDiffPage.contentPadding),
          ),
        ),
      );
      final diffBoneTopLeft = tester.getTopLeft(
        find.byType(SkeletonBone).first,
      );
      final diffAdapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/versions')) {
          return jsonResponse([
            {
              'id': 1,
              'head_commit_sha': '1111111111111111111111111111111111111111',
            },
          ]);
        }
        if (path.endsWith('/versions/1')) {
          return jsonResponse({
            'id': 1,
            'head_commit_sha': '1111111111111111111111111111111111111111',
            'base_commit_sha': '0000000000000000000000000000000000000000',
            'start_commit_sha': '0000000000000000000000000000000000000000',
            'diffs': [
              {
                'old_path': 'lib/a.dart',
                'new_path': 'lib/a.dart',
                'new_file': false,
                'renamed_file': false,
                'deleted_file': false,
                'diff': '@@ -1,1 +1,1 @@\n-old\n+new',
              },
            ],
          });
        }
        return jsonResponse([]);
      });
      final diffApi = testApi(diffAdapter, host: _instance.key);
      addTearDown(diffApi.close);
      await tester.pumpWidget(
        workspaceHost(
          Scaffold(
            body: ReviewDiffPage(
              account: _account,
              api: diffApi,
              project: _project,
              iid: 1,
              expectedSha: '1111111111111111111111111111111111111111',
            ),
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      final realDiffHeaderTopLeft = tester.getTopLeft(
        find.textContaining('11111111').first,
      );
      expect(diffBoneTopLeft, equals(realDiffHeaderTopLeft));

      // 4. LogSkeleton (no 36dp gutter) vs completed JobLogPage first log line
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: LogSkeleton(padding: JobLogPage.logPadding)),
        ),
      );
      final logBoneTopLeft = tester.getTopLeft(find.byType(SkeletonBone).first);
      expect(logBoneTopLeft.dx, equals(JobLogPage.logPadding.left));
      final logAdapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/trace')) {
          return ResponseBody.fromString('first log line\nsecond log line', 200);
        }
        return jsonResponse({
          'id': 20,
          'name': 'unit-test',
          'status': 'success',
          'stage': 'test',
        });
      });
      final logApi = testApi(logAdapter, host: _instance.key);
      addTearDown(logApi.close);
      await tester.pumpWidget(
        workspaceHost(
          JobLogPage(
            account: _account,
            api: logApi,
            project: _project,
            id: 20,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      final realLogLineTopLeft = tester.getTopLeft(
        find.textContaining('first log line', findRichText: true).first,
      );
      expect(logBoneTopLeft.dx, equals(realLogLineTopLeft.dx));

      // 5. DetailSkeleton vs completed WorkItemPage title
      final detailPending = Completer<ResponseBody>();
      final detailAdapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/issues/1')) return detailPending.future;
        return jsonResponse([]);
      });
      final detailApi = testApi(detailAdapter, host: _instance.key);
      addTearDown(detailApi.close);
      await tester.pumpWidget(
        workspaceHost(
          WorkItemPage(
            account: _account,
            api: detailApi,
            project: _project,
            resource: 'issues',
            iid: 1,
          ),
        ),
      );
      await tester.pump();
      final detailBoneTopLeft = tester.getTopLeft(
        find.byType(SkeletonBone).first,
      );
      detailPending.complete(
        jsonResponse({
          'id': 101,
          'iid': 1,
          'project_id': _project.id,
          'title': 'Work item production title',
          'description': 'Body text',
          'state': 'opened',
          'created_at': '2026-10-01T00:00:00Z',
          'author': {'id': 7, 'username': 'tester', 'name': 'Tester'},
        }),
      );
      await settleNetworkWidgets(tester);
      final realWorkItemTitleTopLeft = tester.getTopLeft(
        find.text('Work item production title').first,
      );
      expect(detailBoneTopLeft, equals(realWorkItemTitleTopLeft));

      // 6. HomeSectionSkeleton vs real HubRow tile vertical centre
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: HomeSectionSkeleton())),
      );
      final homeBoneCenter = tester.getCenter(find.byType(SkeletonBone).first);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: HubRow(
              leading: SizedBox(
                key: ValueKey('hub-leading'),
                width: 32,
                height: 32,
              ),
              title: 'Mobile',
              subtitle: 'studio/mobile',
            ),
          ),
        ),
      );
      final realHubLeadingCenter = tester.getCenter(
        find.byKey(const ValueKey('hub-leading')),
      );
      expect(homeBoneCenter, equals(realHubLeadingCenter));
    },
  );

  testWidgets(
    'each replaced screen shows its skeleton and no spinner while first request is pending',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final pending = Completer<ResponseBody>();
      final adapter = FakeAdapter((_) => pending.future);
      final api = testApi(adapter, host: _instance.key);
      addTearDown(api.close);

      final store = MemoryAccountStore();
      final session = SessionController(store, readCache: store.readCache)
        ..active = _account
        ..api = api
        ..generation = 1;
      addTearDown(session.dispose);

      final semantics = tester.ensureSemantics();

      Future<void> checkScreen(Widget screen, Type expectedSkeleton) async {
        await tester.pumpWidget(workspaceHost(Scaffold(body: screen)));
        expect(
          find.byType(expectedSkeleton),
          findsWidgets,
          reason:
              '${screen.runtimeType} must show $expectedSkeleton on first load',
        );
        expect(
          find.bySemanticsLabel('正在載入'),
          findsOneWidget,
          reason:
              '${screen.runtimeType} must expose exactly one 正在載入 semantics node',
        );
        _expectNoSpinners(tester);
      }

      const ref = RepositoryRef(
        kind: RepositoryRefKind.branch,
        name: 'main',
        sha: '1111111111111111111111111111111111111111',
        protected: false,
      );

      // 1. project_overview.dart
      final overviewScroll = ScrollController();
      addTearDown(overviewScroll.dispose);
      await checkScreen(
        ProjectOverview(
          account: _account,
          api: api,
          project: _project,
          starControl: ProjectStarControl(
            starred: false,
            checked: true,
            busy: false,
            starCount: 0,
            revision: 0,
            recheck: () async {},
            setStar: (_) async => null,
          ),
          onSection: (_) {},
          isCurrent: () => true,
          controller: overviewScroll,
        ),
        MarkdownSkeleton,
      );

      // 2. repository_page.dart (RepositoryTab & RepositoryFilePage)
      await checkScreen(
        RepositoryTab(account: _account, api: api, project: _project),
        RowsSkeleton,
      );
      await checkScreen(
        RepositoryFilePage(
          account: _account,
          api: api,
          project: _project,
          ref: ref,
          filePath: 'lib/main.dart',
        ),
        CodeSkeleton,
      );
      await checkScreen(
        RepositoryFilePage(
          account: _account,
          api: api,
          project: _project,
          ref: ref,
          filePath: 'README.md',
        ),
        MarkdownSkeleton,
      );

      // 3. editor.dart
      await checkScreen(
        ResourceEditor(
          account: _account,
          title: 'Edit',
          resource: 'test-draft-scope',
          fields: [EditField('title', 'Title')],
          save: (_) async {},
        ),
        EditorSkeleton,
      );

      // 4. file_history.dart (BlamePage & FindFilePage)
      await checkScreen(
        BlamePage(
          account: _account,
          api: api,
          project: _project,
          sha: ref.sha,
          path: 'lib/main.dart',
        ),
        CodeSkeleton,
      );
      await checkScreen(
        FindFilePage(
          account: _account,
          api: api,
          project: _project,
          ref: ref,
        ),
        RowsSkeleton,
      );
      final findFileRows = tester.widget<RowsSkeleton>(
        find.byType(RowsSkeleton),
      );
      expect(findFileRows.itemHeight, FindFilePage.tileHeight);
      expect(findFileRows.leadingSize, FindFilePage.iconSize);

      // 5. diff_page.dart
      await checkScreen(
        ReviewDiffPage(
          account: _account,
          api: api,
          project: _project,
          iid: 1,
          expectedSha: ref.sha,
        ),
        DiffSkeleton,
      );

      // 6. compare_page.dart
      await tester.pumpWidget(
        workspaceHost(
          ComparePage(account: _account, api: api, project: _project),
        ),
      );
      await tester.enterText(find.byKey(const Key('compare-to')), 'feature');
      await tester.tap(find.byKey(const Key('compare-submit')));
      await tester.pump();
      expect(find.byType(CompareSkeleton), findsOneWidget);
      expect(find.bySemanticsLabel('正在載入'), findsOneWidget);
      _expectNoSpinners(tester);

      // 7. commit_page.dart
      await checkScreen(
        CommitDetailPage(
          account: _account,
          api: api,
          project: _project,
          sha: ref.sha,
        ),
        CommitSkeleton,
      );

      // 8. ci_page.dart (PipelinePage & JobLogPage)
      await checkScreen(
        PipelinePage(
          account: _account,
          api: api,
          project: _project,
          id: 10,
        ),
        PipelineSkeleton,
      );
      await checkScreen(
        JobLogPage(
          account: _account,
          api: api,
          project: _project,
          id: 20,
        ),
        LogSkeleton,
      );

      // 9. ci_overview_page.dart
      await checkScreen(
        CiOverviewPage(account: _account, api: api),
        ListSkeleton,
      );

      // 10. pipeline_graph_page.dart
      await checkScreen(
        PipelineGraphPage(
          account: _account,
          api: api,
          project: _project,
          pipelineId: 10,
        ),
        StageColumnsSkeleton,
      );

      // 11. boards_page.dart
      await checkScreen(
        BoardsPage(
          account: _account,
          api: api,
          project: _project,
        ),
        BoardColumnsSkeleton,
      );

      // 12. project_analytics_page.dart
      await checkScreen(
        ProjectAnalyticsPage(
          account: _account,
          api: api,
          project: _project,
        ),
        ChartSkeleton,
      );

      // 13. work_item_page.dart
      await checkScreen(
        WorkItemPage(
          account: _account,
          api: api,
          project: _project,
          resource: 'issues',
          iid: 1,
        ),
        DetailSkeleton,
      );

      // 14. home_page.dart
      await checkScreen(
        HomePage(session: session),
        HomeSectionSkeleton,
      );

      // 15. records_feed.dart
      await checkScreen(
        RecordsFeed(
          identity: 'feed-pending',
          load: (_) => Completer<ApiPage<Json>>().future,
          itemBuilder: (_, _) => const SizedBox.shrink(),
        ),
        RowsSkeleton,
      );

      // 16. projects_page.dart
      await checkScreen(
        ProjectsPage(session: session),
        RowsSkeleton,
      );

      // 17. project_page.dart
      await checkScreen(
        ProjectPage(
          account: _account,
          api: api,
          project: _project,
          initialTab: 0,
        ),
        RowsSkeleton,
      );

      // 18. snippets_page.dart
      await checkScreen(
        SnippetsPage(
          account: _account,
          api: api,
          project: _project,
        ),
        RowsSkeleton,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      semantics.dispose();
    },
  );

  testWidgets(
    'AnimatedSwitcher crossfades MarkdownSkeleton to README content with top-aligned Stack',
    (tester) async {
      final dummyApi = testApi(FakeAdapter((_) => jsonResponse({})));
      addTearDown(dummyApi.close);
      final loading = ValueNotifier<bool>(true);
      addTearDown(loading.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: loading,
              builder: (context, isLoading, _) => RepositoryReadmeCard(
                readme: isLoading
                    ? null
                    : const RepositoryReadme(
                        path: 'README.md',
                        sha: '1111111111111111111111111111111111111111',
                        markdown: 'Short README line',
                      ),
                loading: isLoading,
                error: null,
                expanded: true,
                onToggle: () {},
                onRetry: () {},
                account: _account,
                project: _project,
                api: dummyApi,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(MarkdownSkeleton), findsOneWidget);
      loading.value = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      // During the 200ms fade, both children are present in the Stack.
      expect(
        find.byType(MarkdownSkeleton, skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('repo-readme-content')),
        findsOneWidget,
      );
      final midTop = tester.getTopLeft(
        find.byKey(const ValueKey('repo-readme-content')),
      );

      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(MarkdownSkeleton, skipOffstage: false), findsNothing);
      final endTop = tester.getTopLeft(
        find.byKey(const ValueKey('repo-readme-content')),
      );
      expect(midTop, equals(endTop));
    },
  );

  testWidgets(
    'first-load-only: JobLogPage empty trace keeps empty state and shows thin bar on reload/poll without LogSkeleton',
    (tester) async {
      var reloadGate = Completer<ResponseBody>();
      var callCount = 0;
      final adapter = FakeAdapter((request) {
        if (request.uri.path.endsWith('/trace')) {
          callCount++;
          if (callCount == 1) return ResponseBody.fromString('', 200);
          return reloadGate.future;
        }
        return jsonResponse({
          'id': 20,
          'name': 'build-job',
          'status': 'pending',
          'stage': 'build',
        });
      });
      final api = testApi(adapter, host: _instance.key);
      addTearDown(api.close);

      await tester.pumpWidget(
        workspaceHost(
          JobLogPage(
            account: _account,
            api: api,
            project: _project,
            id: 20,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.byType(LogSkeleton), findsNothing);
      expect(find.text('尚無 Log'), findsOneWidget);

      // Trigger reload while trace is empty: empty state stays, thin bar shows, no LogSkeleton.
      await tester.tap(find.byTooltip('重新讀取 Log'));
      await tester.pump();
      expect(find.byType(LogSkeleton), findsNothing);
      expect(find.text('尚無 Log'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      reloadGate.complete(ResponseBody.fromString('', 200));
      await settleNetworkWidgets(tester);
      expect(find.byType(LogSkeleton), findsNothing);
      expect(find.text('尚無 Log'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'first-load-only: PipelinePage reload keeps its tabs and CommitDetailPage reload keeps no-text-diff card',
    (tester) async {
      var holdReload = false;
      final reloadGate = Completer<ResponseBody>();
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/pipelines/10')) {
          if (holdReload) return reloadGate.future;
          return jsonResponse({
            'id': 10,
            'iid': 10,
            'status': 'running',
            'ref': 'main',
            'sha': '1111111111111111111111111111111111111111',
            'source': 'push',
          });
        }
        if (path.endsWith('/pipelines/10/jobs')) {
          return jsonResponse([
            {'id': 1, 'name': 'job-1', 'status': 'running', 'stage': 'test'},
          ]);
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter, host: _instance.key);
      addTearDown(api.close);

      await tester.pumpWidget(
        workspaceHost(
          PipelinePage(
            account: _account,
            api: api,
            project: _project,
            id: 10,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.byType(PipelineSkeleton), findsNothing);

      holdReload = true;
      await tester.tap(find.byIcon(Icons.refresh).first);
      await tester.pump();
      expect(find.byType(TabBar), findsOneWidget);
      expect(find.byType(PipelineSkeleton), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsWidgets);

      reloadGate.complete(
        jsonResponse({
          'id': 10,
          'iid': 10,
          'status': 'success',
          'ref': 'main',
          'sha': '1111111111111111111111111111111111111111',
          'source': 'push',
        }),
      );
      holdReload = false;
      await settleNetworkWidgets(tester);

      // CommitDetailPage with empty diff: pull-to-refresh keeps "no text diff" card.
      final commitDiffGate = Completer<ResponseBody>();
      var holdCommitDiff = false;
      final commitAdapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/diff')) {
          if (holdCommitDiff) return commitDiffGate.future;
          return jsonResponse([]);
        }
        return jsonResponse({
          'id': '1111111111111111111111111111111111111111',
          'short_id': '11111111',
          'title': 'Empty commit',
          'message': 'Empty commit',
          'author_name': 'Tester',
          'created_at': '2026-10-01T00:00:00Z',
        });
      });
      final commitApi = testApi(commitAdapter, host: _instance.key);
      addTearDown(commitApi.close);

      await tester.pumpWidget(
        workspaceHost(
          CommitDetailPage(
            account: _account,
            api: commitApi,
            project: _project,
            sha: '1111111111111111111111111111111111111111',
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.text('此提交無檔案變更或無文字差異。'), findsOneWidget);
      expect(find.byType(DiffSkeleton), findsNothing);

      holdCommitDiff = true;
      await tester.drag(find.byType(RefreshIndicator), const Offset(0, 300));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('此提交無檔案變更或無文字差異。'), findsOneWidget);
      expect(find.byType(DiffSkeleton), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      commitDiffGate.complete(jsonResponse([]));
      await settleNetworkWidgets(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'first-load-only: BoardsPage board change keeps the loaded board with thin bar',
    (tester) async {
      final board2Gate = Completer<ResponseBody>();
      final adapter = FakeAdapter((request) {
        final path = request.uri.path;
        if (path.endsWith('/boards')) {
          return jsonResponse([
            {'id': 1, 'name': 'Development'},
            {'id': 2, 'name': 'Release'},
          ]);
        }
        if (path.endsWith('/boards/1/lists')) {
          return jsonResponse([
            {
              'id': 10,
              'position': 0,
              'label': {'id': 100, 'name': 'To Do', 'color': '#428BCA'},
            },
          ]);
        }
        if (path.endsWith('/boards/2/lists')) {
          return jsonResponse([
            {
              'id': 20,
              'position': 0,
              'label': {'id': 200, 'name': 'Ready', 'color': '#5CB85C'},
            },
          ]);
        }
        if (path.endsWith('/boards/2')) {
          return board2Gate.future;
        }
        if (path.endsWith('/boards/1')) {
          return jsonResponse({'id': 1, 'name': 'Development'});
        }
        return jsonResponse([]);
      });
      final api = testApi(adapter, host: _instance.key);
      addTearDown(api.close);

      await tester.pumpWidget(
        workspaceHost(
          BoardsPage(
            account: _account,
            api: api,
            project: _project,
          ),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.byType(BoardColumnsSkeleton), findsNothing);
      expect(find.textContaining('To Do'), findsOneWidget);

      // Switch to board 2 while its response is held: existing board stays visible.
      await tester.tap(find.byKey(const ValueKey('board-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Release').last);
      await tester.pump();
      expect(find.byType(BoardColumnsSkeleton), findsNothing);
      expect(find.textContaining('To Do'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsWidgets);

      board2Gate.complete(jsonResponse({'id': 2, 'name': 'Release'}));
      await settleNetworkWidgets(tester);
      expect(find.textContaining('Ready'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
