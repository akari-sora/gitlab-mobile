import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_preview.dart';

void main() {
  test('P1 field previews snapshot standalone mutable maps', () {
    final fields = <String, Object?>{'title': 'original'};
    final preview = AiFieldsPreview(fields);
    fields['title'] = 'changed';
    expect(preview.fields, {'title': 'original'});
    expect(() => preview.fields.clear(), throwsUnsupportedError);
  });

  test('P1 previews and text scans snapshot the lists owned by callers', () {
    final lines = <AiDiffLine>[
      const AiDiffLine(kind: AiDiffLineKind.deletion, text: 'old', oldLine: 4),
      const AiDiffLine(kind: AiDiffLineKind.addition, text: 'new', newLine: 4),
    ];
    final diff = AiDiffPreview(
      path: 'a.md',
      ref: 'topic',
      lines: lines,
      preexistingSecretHits: 2,
      ciPath: true,
    );
    final paths = <String>['.gitlab-ci.yml'];
    final closing = <AiClosingIssue>[
      const AiClosingIssue(projectId: 9, iid: 3, outOfScope: true),
    ];
    final commits = <String>['12345678'];
    final merge = AiMergePreview(
      sourceBranch: 'topic',
      targetBranch: 'main',
      shortSha: 'abcdef12',
      pathCount: 1,
      squash: true,
      removeSourceBranch: true,
      autoMerge: true,
      ciPaths: paths,
      closingIssues: closing,
      headMovedCommits: commits,
    );
    final names = <String>['SYNTHETIC_NAME'];
    final pipeline = AiPipelinePreview(
      ref: 'topic',
      pipelineId: 100,
      jobId: 101,
      jobName: 'test',
      stage: 'verify',
      environment: 'synthetic',
      scheduleVariableNames: names,
      scheduleParamsUnreadable: true,
      newVariableNames: names,
    );
    final drafts = <AiDraftPreview>[
      const AiDraftPreview(id: 8, body: 'draft', createdInSegment: false),
    ];
    final publish = AiDraftPublishPreview(drafts: drafts);
    final newTexts = <String>['new'];
    final windows = <AiTextWindow>[
      const AiTextWindow(
        before: 'context\nold\nend',
        after: 'context\nnew\nend',
      ),
    ];
    final serverClassA = <String>['draft'];
    final scan = AiTextScan(
      original: 'context\nold\nend',
      newTexts: newTexts,
      windows: windows,
      markdown: true,
      serverClassA: serverClassA,
    );
    lines.clear();
    paths.clear();
    closing.clear();
    commits.clear();
    names.clear();
    drafts.clear();
    newTexts.clear();
    windows.clear();
    serverClassA.clear();

    expect(diff.lines.map((line) => line.text), ['old', 'new']);
    expect(diff.lines.first.oldLine, 4);
    expect(diff.lines.last.newLine, 4);
    expect(diff.preexistingSecretHits, 2);
    expect(diff.ciPath, isTrue);
    expect(merge.ciPaths, ['.gitlab-ci.yml']);
    expect(merge.closingIssues.single.outOfScope, isTrue);
    expect(merge.headMovedCommits, ['12345678']);
    expect(pipeline.scheduleVariableNames, ['SYNTHETIC_NAME']);
    expect(pipeline.newVariableNames, ['SYNTHETIC_NAME']);
    expect(pipeline.scheduleParamsUnreadable, isTrue);
    expect(publish.drafts.single.createdInSegment, isFalse);
    expect(scan.newTexts, ['new']);
    expect(scan.windows.single.before, scan.original);
    expect(scan.windows.single.after, 'context\nnew\nend');
    expect(scan.serverClassA, ['draft']);
    for (final list in <List<Object?>>[
      diff.lines,
      merge.ciPaths,
      merge.closingIssues,
      merge.headMovedCommits,
      pipeline.scheduleVariableNames,
      pipeline.newVariableNames,
      publish.drafts,
      scan.newTexts,
      scan.windows,
      scan.serverClassA,
    ]) {
      expect(list.clear, throwsUnsupportedError);
    }
  });

  test(
    'P1 specialized previews and journal expose metadata without UI copy',
    () {
      const deletion = AiDeletePreview(
        targetName: '#3',
        path: 'a.txt',
        ref: 'topic',
        count: 20,
        hasMore: true,
      );
      const cancellation = AiCancelAutoMergePreview(
        iid: 3,
        sourceBranch: 'topic',
        targetBranch: 'main',
        mayLackPermission: true,
      );
      const journal = AiJournalBindings(
        headSha: 'head',
        lastCommitId: 'last',
        updatedAt: 'timestamp',
        mergeCheckSummary: 'digest',
      );
      expect(deletion.targetName, '#3');
      expect(deletion.hasMore, isTrue);
      expect(cancellation.iid, 3);
      expect(cancellation.mayLackPermission, isTrue);
      expect(journal.headSha, 'head');
      expect(journal.lastCommitId, 'last');
      expect(journal.updatedAt, 'timestamp');
      expect(journal.mergeCheckSummary, 'digest');
    },
  );
}
