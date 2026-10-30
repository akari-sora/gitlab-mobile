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
import 'package:gitlab_mobile/features/workspace/ci_overview_page.dart';
import 'package:gitlab_mobile/features/workspace/ci_page.dart';
import 'package:gitlab_mobile/features/workspace/commit_page.dart';
import 'package:gitlab_mobile/features/workspace/compare_page.dart';
import 'package:gitlab_mobile/features/workspace/diff_page.dart';
import 'package:gitlab_mobile/features/workspace/editor.dart';
import 'package:gitlab_mobile/features/workspace/file_history.dart';
import 'package:gitlab_mobile/features/workspace/pipeline_graph_page.dart';
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
            of: find.byType(DetailSkeleton),
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

    expect(ltrEarly.dx, closeTo(-0.5, 1e-6));
    expect(ltrLate.dx, closeTo(0.5, 1e-6));
    expect(rtlEarly.dx, closeTo(0.5, 1e-6));
    expect(rtlLate.dx, closeTo(-0.5, 1e-6));
    expect(ltrEarly.dx, lessThan(ltrLate.dx));
    expect(rtlEarly.dx, greaterThan(rtlLate.dx));

    final ltrMatrix = ltrEarly.transform(bounds)!;
    final rtlMatrix = rtlEarly.transform(bounds)!;
    expect(ltrMatrix.getTranslation().x, closeTo(-100.0, 1e-6));
    expect(rtlMatrix.getTranslation().x, closeTo(100.0, 1e-6));

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
    'no jump: top-left inset of first bone matches real page content inset',
    (tester) async {
      final dummyApi = testApi(FakeAdapter((_) => jsonResponse({})));
      addTearDown(dummyApi.close);

      // 1. MarkdownSkeleton vs real MarkdownView padding
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MarkdownSkeleton(
              padding: MarkdownSkeleton.overviewReadmePadding,
            ),
          ),
        ),
      );
      final mdBoneTopLeft = tester.getTopLeft(find.byType(SkeletonBone).first);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: MarkdownSkeleton.overviewReadmePadding,
              child: MarkdownView(
                'Heading',
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
      final mdRealTopLeft = tester.getTopLeft(find.byType(MarkdownView));
      expect(mdBoneTopLeft, equals(mdRealTopLeft));
      expect(
        mdBoneTopLeft,
        equals(
          Offset(
            MarkdownSkeleton.overviewReadmePadding.left,
            MarkdownSkeleton.overviewReadmePadding.top,
          ),
        ),
      );

      // 2. CodeSkeleton vs real CodeTextView line-number gutter inset
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CodeSkeleton())),
      );
      final codeBoneTopLeft = tester.getTopLeft(
        find.byType(SkeletonBone).first,
      );
      final vertical = ScrollController();
      final horizontal = ScrollController();
      addTearDown(vertical.dispose);
      addTearDown(horizontal.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeTextView(
              index: CodeTextIndex('void main() {}'),
              visibleIndices: const [0],
              filePath: 'main.dart',
              syntaxSpans: SyntaxSpanCache(),
              wrap: true,
              vertical: vertical,
              horizontal: horizontal,
            ),
          ),
        ),
      );
      expect(
        codeBoneTopLeft,
        equals(
          Offset(
            CodeSkeleton.defaultPadding.left,
            CodeSkeleton.defaultPadding.top,
          ),
        ),
      );

      // 3. DiffSkeleton vs real diff content inset
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DiffSkeleton())),
      );
      final diffBoneTopLeft = tester.getTopLeft(
        find.byType(SkeletonBone).first,
      );
      expect(
        diffBoneTopLeft,
        equals(
          Offset(
            DiffSkeleton.defaultPadding.left,
            DiffSkeleton.defaultPadding.top,
          ),
        ),
      );

      // 4. LogSkeleton vs real JobLogPage list inset
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: LogSkeleton())),
      );
      final logBoneTopLeft = tester.getTopLeft(find.byType(SkeletonBone).first);
      expect(
        logBoneTopLeft,
        equals(
          Offset(
            LogSkeleton.defaultPadding.left,
            LogSkeleton.defaultPadding.top,
          ),
        ),
      );

      // 5. DetailSkeleton vs real WorkItemPage header inset
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DetailSkeleton())),
      );
      final detailBoneTopLeft = tester.getTopLeft(
        find.byType(SkeletonBone).first,
      );
      expect(
        detailBoneTopLeft,
        equals(
          Offset(
            DetailSkeleton.headerPadding.left,
            DetailSkeleton.headerPadding.top,
          ),
        ),
      );

      // 6. HomeSectionSkeleton vs real HubRow leading tile inset
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: HomeSectionSkeleton())),
      );
      final homeBoneTopLeft = tester.getTopLeft(
        find.byType(SkeletonBone).first,
      );
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
      expect(
        homeBoneTopLeft.dx,
        equals(HomeSectionSkeleton.rowPadding.left),
      );
      expect(
        homeBoneTopLeft.dy,
        equals(HomeSectionSkeleton.rowPadding.top),
      );
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('hub-leading'))).dx,
        equals(homeBoneTopLeft.dx),
      );
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

      Future<void> checkScreen(Widget screen, Type expectedSkeleton) async {
        await tester.pumpWidget(workspaceHost(Scaffold(body: screen)));
        expect(
          find.byType(expectedSkeleton),
          findsWidgets,
          reason:
              '${screen.runtimeType} must show $expectedSkeleton on first load',
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
        CodeSkeleton,
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
      expect(find.byType(DiffSkeleton), findsOneWidget);
      _expectNoSpinners(tester);

      // 7. commit_page.dart
      await checkScreen(
        CommitDetailPage(
          account: _account,
          api: api,
          project: _project,
          sha: ref.sha,
        ),
        DiffSkeleton,
      );

      // 8. ci_page.dart (PipelinePage & JobLogPage)
      await checkScreen(
        PipelinePage(
          account: _account,
          api: api,
          project: _project,
          id: 10,
        ),
        RowsSkeleton,
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
        ListSkeleton,
      );

      // 11. work_item_page.dart
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

      // 12. home_page.dart
      await checkScreen(
        HomePage(session: session),
        HomeSectionSkeleton,
      );

      // 13. records_feed.dart
      await checkScreen(
        RecordsFeed(
          identity: 'feed-pending',
          load: (_) => Completer<ApiPage<Json>>().future,
          itemBuilder: (_, _) => const SizedBox.shrink(),
        ),
        RowsSkeleton,
      );

      // 14. projects_page.dart
      await checkScreen(
        ProjectsPage(session: session),
        RowsSkeleton,
      );

      // 15. project_page.dart
      await checkScreen(
        ProjectPage(
          account: _account,
          api: api,
          project: _project,
          initialTab: 0,
        ),
        RowsSkeleton,
      );

      // 16. snippets_page.dart
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
    },
  );
}
