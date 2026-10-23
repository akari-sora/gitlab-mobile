import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_preview.dart';
import 'package:gitlab_mobile/features/ai/ai_write_previews.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

Widget _host(Widget child, {String tag = 'zh-TW', double scale = 1}) =>
    MaterialApp(
      theme: appTheme(Brightness.light),
      locale: switch (tag) {
        'ar' => const Locale('ar'),
        'de' => const Locale('de'),
        _ => const Locale('zh', 'TW'),
      },
      supportedLocales: const [Locale('zh', 'TW'), Locale('ar'), Locale('de')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: child,
        ),
      ),
    );

final _diff = AiDiffPreview(
  path: 'lib/main.dart',
  ref: 'main',
  ciPath: true,
  preexistingSecretHits: 2,
  lines: const [
    AiDiffLine(kind: AiDiffLineKind.hunk, text: '@@ -10,3 +10,3 @@'),
    AiDiffLine(
      kind: AiDiffLineKind.context,
      text: 'void main() {',
      oldLine: 10,
      newLine: 10,
    ),
    AiDiffLine(
      kind: AiDiffLineKind.deletion,
      text:
          "  runApp(const OldApp()); // a long line that keeps going past the edge",
      oldLine: 11,
    ),
    AiDiffLine(
      kind: AiDiffLineKind.addition,
      text: '  runApp(const NewApp());',
      newLine: 11,
    ),
  ],
);

final _merge = AiMergePreview(
  sourceBranch: 'feature/login',
  targetBranch: 'main',
  shortSha: 'a1b2c3d4',
  pathCount: 7,
  squash: true,
  removeSourceBranch: true,
  ciPaths: const ['.gitlab-ci.yml'],
  closingIssues: const [
    AiClosingIssue(projectId: 9, iid: 3, outOfScope: false),
    AiClosingIssue(projectId: 10, iid: 8, outOfScope: true),
  ],
  headMovedCommits: const ['c1', 'c2'],
);

final _rerun = AiPipelinePreview(
  ref: 'main',
  pipelineId: 1201,
  jobId: 77,
  jobName: 'deploy',
  stage: 'release',
  environment: 'production',
);

final _withVariables = AiPipelinePreview(
  ref: 'main',
  newVariableNames: const ['DEPLOY_TARGET'],
);

final _drafts = AiDraftPublishPreview(
  drafts: const [
    AiDraftPreview(id: 1, body: 'Please rename this.', createdInSegment: true),
    AiDraftPreview(id: 2, body: 'My own note.', createdInSegment: false),
  ],
);

void main() {
  setUp(() => useLanguage(languageForTag('zh-TW')!));

  testWidgets('a diff shows the file, the warnings and numbered lines', (
    tester,
  ) async {
    await tester.pumpWidget(_host(AiWritePreviewView(preview: _diff)));
    expect(find.byKey(const ValueKey('ai-preview-ci-file')), findsOne);
    expect(find.text(l10n.aiPreviewExistingSecrets('2')), findsOneWidget);
    expect(find.textContaining('runApp(const NewApp());'), findsOneWidget);
    expect(find.textContaining('11 + '), findsOneWidget);
    expect(find.textContaining('@@ -10,3 +10,3 @@'), findsOneWidget);
  });

  testWidgets('a merge names branches, sha and every closing issue', (
    tester,
  ) async {
    await tester.pumpWidget(_host(AiWritePreviewView(preview: _merge)));
    expect(find.text('a1b2c3d4'), findsOneWidget);
    expect(
      find.text(l10n.aiPreviewBranchFlow('feature/login', 'main')),
      findsOne,
    );
    expect(find.text(l10n.aiProposalClosesOnMerge('#3')), findsOneWidget);
    expect(find.text(l10n.aiPreviewClosesOutOfScope('#8')), findsOneWidget);
    expect(find.text(l10n.aiPreviewHeadMoved('2')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-preview-merge-ci')), findsOne);
  });

  testWidgets('a rerun warns about stored variables; new variables warn too', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(AiWritePreviewView(preview: _rerun, storedVariables: true)),
    );
    expect(find.byKey(const ValueKey('ai-preview-stored-variables')), findsOne);
    expect(find.textContaining('deploy'), findsOneWidget);
    await tester.pumpWidget(_host(AiWritePreviewView(preview: _withVariables)));
    expect(find.byKey(const ValueKey('ai-preview-new-variables')), findsOne);
    expect(
      find.byKey(const ValueKey('ai-preview-stored-variables')),
      findsNothing,
    );
  });

  testWidgets('a draft publish marks which drafts this conversation made', (
    tester,
  ) async {
    await tester.pumpWidget(_host(AiWritePreviewView(preview: _drafts)));
    expect(find.text(l10n.aiPreviewDraftSplit('2', '1')), findsOneWidget);
    expect(find.bySemanticsLabel(l10n.aiPreviewDraftByAi), findsOneWidget);
    expect(find.bySemanticsLabel(l10n.aiPreviewDraftByYou), findsOneWidget);
  });

  testWidgets('a delete says it cannot be undone', (tester) async {
    await tester.pumpWidget(
      _host(
        const AiWritePreviewView(
          preview: AiDeletePreview(
            targetName: 'v1.2.0',
            ref: 'v1.2.0',
            count: 30,
            hasMore: true,
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('ai-preview-cannot-undo')), findsOne);
    expect(find.text(l10n.aiPreviewAtLeast('30')), findsOneWidget);
    // The ref equals the target, so it is not repeated.
    expect(find.text(l10n.aiPreviewRef), findsNothing);
    expect(find.text('v1.2.0'), findsOneWidget);
  });

  testWidgets('marking all to-dos done is not shown as a delete', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const AiWritePreviewView(
          operationId: 'markAllTodosDone',
          preview: AiDeletePreview(targetName: '@someone', count: 5),
        ),
      ),
    );
    expect(find.text(l10n.accountLabel), findsOneWidget);
    expect(find.text(l10n.todoLabel), findsOneWidget);
    expect(find.text(l10n.aiPreviewDeleteTarget), findsNothing);
    expect(find.byKey(const ValueKey('ai-preview-cannot-undo')), findsNothing);
  });

  for (final tag in ['zh-TW', 'de', 'ar']) {
    testWidgets('previews fit $tag at 2x on 320 dp', (tester) async {
      tester.view.physicalSize =
          const Size(320, 640) * tester.view.devicePixelRatio;
      addTearDown(tester.view.reset);
      if (tag != 'zh-TW') useLanguage(languageForTag(tag)!);
      addTearDown(() => useLanguage(languageForTag('zh-TW')!));
      for (final preview in <AiWritePreview>[
        _diff,
        _merge,
        _rerun,
        _withVariables,
        _drafts,
        const AiCancelAutoMergePreview(
          iid: 44,
          sourceBranch: 'feature/a-very-long-branch-name-for-layout',
          targetBranch: 'main',
          mayLackPermission: true,
        ),
      ]) {
        await tester.pumpWidget(
          _host(AiWritePreviewView(preview: preview), tag: tag, scale: 2),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$preview');
      }
    });
  }

  testWidgets('code reads left to right in an Arabic interface', (
    tester,
  ) async {
    useLanguage(languageForTag('ar')!);
    addTearDown(() => useLanguage(languageForTag('zh-TW')!));
    await tester.pumpWidget(
      _host(AiWritePreviewView(preview: _diff), tag: 'ar'),
    );
    final code = find.textContaining('runApp(const NewApp());');
    final direction = Directionality.of(tester.element(code));
    expect(direction, TextDirection.ltr);
  });
}
