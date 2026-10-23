import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'p6_support.dart';

void main() {
  late P6Server s;
  P6Coordinator? h;
  setUp(() => s = P6Server());
  tearDown(() async {
    await h?.dispose();
    h = null;
    s.close();
  });

  for (final op in ['edit_file', 'createFile', 'deleteFile']) {
    for (final protected in [false, true]) {
      test(
        'P6 $op branch protection $protected uses correct tier and confirm name',
        () async {
          s.protected = protected;
          s.missing = op == 'createFile';
          h = await P6Coordinator.create(s);
          final p = await h!.propose(op);
          expect(p, isNotNull);
          expect(
            p!.tier.tier,
            protected || op == 'deleteFile' ? AiWriteTier.t4 : AiWriteTier.t3,
          );
          expect(
            p.tier.typedName,
            op == 'deleteFile'
                ? 'src/a.txt'
                : protected
                ? 'work'
                : null,
          );
          expect(s.writes, isEmpty);
        },
      );
    }
    for (final path in [
      '.gitlab-ci.yml',
      'ci/custom.yml',
      'docs/CODEOWNERS',
      '.gitlab/CODEOWNERS',
    ]) {
      test('P6 $op CI $path stays hard line even at bypass', () async {
        s.ciConfig = 'ci/custom.yml';
        s.missing = op == 'createFile';
        h = await P6Coordinator.create(s, level: AiAutonomyLevel.bypass);
        final p = await h!.propose(op, args: p6Args(op, path: path));
        expect(p, isNotNull);
        expect(p!.tier.tier, AiWriteTier.hardLine);
        expect(p.tier.requiresTypedName, isTrue);
        expect(p.tier.typedName, path);
        expect(s.writes, isEmpty);
      });
    }
  }

  test(
    'P6 defaults raise T4; present-null CI is default and malformed CI hardlines',
    () async {
      h = await P6Coordinator.create(s);
      s.defaultBranch = 'work';
      var p = await h!.propose('edit_file', id: 'a');
      expect(p!.tier.tier, AiWriteTier.t4);
      await h!.coordinator.reject(p);
      h!.beginRun('Change `work` `src/a.txt`');
      s.defaultBranch = 'main';
      s.branchDefault = true;
      p = await h!.propose('edit_file', id: 'b');
      expect(p!.tier.tier, AiWriteTier.t4);
      await h!.coordinator.reject(p);
      h!.beginRun('Change `work` `src/a.txt`');
      s.branchDefault = false;
      s.ciConfig = null;
      p = await h!.propose('edit_file', id: 'c');
      expect(p!.tier.tier, AiWriteTier.t3);
      await h!.coordinator.reject(p);
      h!.beginRun('Change `work` `src/a.txt`');
      s.ciConfig = '../ci.yml';
      p = await h!.propose('edit_file', id: 'd');
      expect(p!.tier.tier, AiWriteTier.hardLine);
    },
  );

  for (final change in ['revision', 'ci', 'protection']) {
    test(
      'P6 dispatch invalidates changed $change instead of retaining approval',
      () async {
        h = await P6Coordinator.create(s);
        final p = await h!.propose('edit_file');
        expect(p, isNotNull);
        if (change == 'revision') {
          s.lastCommit = p6NextL;
          s.contents[p6NextL] = 'alpha\n';
        }
        if (change == 'ci') s.ciConfig = 'src/a.txt';
        if (change == 'protection') s.protected = true;
        final result = await h!.coordinator.approve(p!).timeout(p6Timeout);
        expect(result.state, AiJournalState.notExecuted);
        expect(result.reasonCode, 'targetChanged');
        expect(s.writes, isEmpty);
      },
    );
  }

  for (final change in [
    'head',
    'base',
    'sourceBranch',
    'path',
    'stalePosition',
  ]) {
    test(
      'P6 suggestion dispatch revalidates $change before global mutation',
      () async {
        h = await P6Coordinator.create(s);
        final p = await h!.propose('applySuggestion');
        expect(p, isNotNull);
        if (change == 'head') s.mrSha = p6NextL;
        if (change == 'base') s.mrBase = p6NextL;
        if (change == 'sourceBranch') s.branchName = 'other';
        if (change == 'path') s.suggestionPath = 'src/other.txt';
        if (change == 'stalePosition') s.positionHead = p6NextL;
        final outcome = await h!.coordinator.approve(p!).timeout(p6Timeout);
        expect(outcome.state, AiJournalState.notExecuted);
        expect(
          outcome.reasonCode,
          change == 'stalePosition' ? 'suggestionForeign' : 'targetChanged',
        );
        expect(s.writes, isEmpty);
      },
    );
  }

  test('P6 suggestion requires MR and source ref and path binding', () async {
    h = await P6Coordinator.create(s, level: AiAutonomyLevel.conversationGrant);
    for (final message in [
      'Apply !3',
      'Apply !3 `work`',
      'Apply !3 `src/a.txt`',
      'Apply `work` `src/a.txt`',
    ]) {
      h!.beginRun(message);
      final p = await h!.propose('applySuggestion', id: message);
      expect(p, isNotNull);
      expect(p!.tier.decision, AiGateDecision.requireApproval);
      expect(p.tier.reasons, contains(AiFixedConfirmReason.targetUnbound));
      await h!.coordinator.reject(p);
    }
    h!.beginRun('Apply !3 `work` `src/a.txt`');
    final p = await h!.propose('applySuggestion', id: 'bound');
    expect(p!.tier.decision, AiGateDecision.execute);
    expect(s.writes, isEmpty);
  });

  for (final op in ['createFile', 'applySuggestion']) {
    test(
      'P6 $op rendered Markdown scans new body for media and mass mention',
      () async {
        const content = '@all ![image](https://outside.example/image.png)';
        s.missing = op == 'createFile';
        s.suggestionPath = 'README.md';
        s.suggestionAfter = content;
        h = await P6Coordinator.create(s, level: AiAutonomyLevel.bypass);
        final p = await h!.propose(
          op,
          args: {
            ...p6Args(op, path: 'README.md'),
            if (op == 'createFile') 'content': content,
          },
        );
        expect(p, isNotNull);
        expect(p!.tier.decision, AiGateDecision.requireApproval);
        expect(p.tier.reasons, contains(AiFixedConfirmReason.massMention));
        expect(
          p.tier.reasons,
          contains(AiFixedConfirmReason.externalMediaInRenderedMarkdown),
        );
        expect(s.writes, isEmpty);
      },
    );
  }

  test(
    'P6 mixed suggestion batch applies Markdown checks only to Markdown paths',
    () async {
      s.beforeRequest = (r) {
        if (r.uri.path.contains('/discussions/')) {
          final markdown = r.uri.path.endsWith('/d2');
          s.suggestionPath = markdown ? 'README.md' : 'src/a.txt';
          s.suggestionAfter = markdown
              ? 'safe'
              : '@all ![image](https://outside.example/image.png)';
        }
      };
      // An expanded synthetic budget exercises the port/coordinator scan seam;
      // the production forty-request budget is tested separately as blocked.
      h = await P6Coordinator.create(
        s,
        budget: 200,
        level: AiAutonomyLevel.bypass,
      );
      final p = await h!.propose(
        'batchApplySuggestions',
        args: {
          ...p6Args('batchApplySuggestions'),
          'suggestions': [p6Item(1), p6Item(2)],
        },
      );
      expect(p, isNotNull);
      expect(
        p!.tier.reasons,
        isNot(contains(AiFixedConfirmReason.massMention)),
      );
      expect(
        p.tier.reasons,
        isNot(contains(AiFixedConfirmReason.externalMediaInRenderedMarkdown)),
      );
      expect(s.writes, isEmpty);
    },
  );

  test(
    'P6 advance after approval pre-read gives certain 409 with L, never POST',
    () async {
      h = await P6Coordinator.create(s);
      final p = await h!.propose('edit_file');
      s.beforeRequest = (r) {
        if (r.method == 'PUT') s.lastCommit = p6NextL;
      };
      final result = await h!.coordinator.approve(p!).timeout(p6Timeout);
      expect(result.state, AiJournalState.failedCertain);
      expect(
        h!.journal.entries(p6Account).last.state,
        AiJournalState.failedCertain,
      );
      expect(s.writes.single.method, 'PUT');
      expect((s.writes.single.data! as Map)['last_commit_id'], p6L);
    },
  );

  test(
    'P6 uncertain edit blocks delete on same path across the next run',
    () async {
      h = await P6Coordinator.create(s);
      final p = await h!.propose('edit_file');
      s.mutationStatus = 503;
      final outcome = await h!.coordinator.approve(p!).timeout(p6Timeout);
      expect(outcome.state, AiJournalState.writeUncertain);
      h!.beginRun('Delete `work` `src/a.txt` in team/example-9');
      final deletion = await h!.propose('deleteFile', id: 'delete');
      expect(deletion, isNull);
      expect(h!.coordinator.outcomeFor('delete')!.reasonCode, 'isolated');
      expect(s.writes, hasLength(1));
    },
  );

  test('P6 file ref and path must both bind for automatic T3', () async {
    h = await P6Coordinator.create(s, level: AiAutonomyLevel.conversationGrant);
    for (final message in [
      'Change `work`',
      'Change `src/a.txt`',
      'Change artwork src/a.txt',
    ]) {
      h!.beginRun(message);
      final p = await h!.propose('edit_file', id: message);
      expect(p, isNotNull);
      expect(p!.tier.decision, AiGateDecision.requireApproval);
      expect(p.tier.reasons, contains(AiFixedConfirmReason.targetUnbound));
      await h!.coordinator.reject(p);
    }
    h!.beginRun('Change work src/a.txt');
    final mentioned = await h!.propose('edit_file', id: 'plain mentions');
    expect(mentioned!.tier.decision, AiGateDecision.requireApproval);
    expect(mentioned.tier.reasons, contains(AiFixedConfirmReason.targetNamedNotMarked));
    expect(s.writes, isEmpty);
    await h!.coordinator.reject(mentioned);
    for (final message in ['Change `work` `src/a.txt`']) {
      h!.beginRun(message);
      final p = await h!.propose('edit_file', id: message);
      expect(p!.tier.decision, AiGateDecision.execute);
      expect(p.tier.reasons, isNot(contains(AiFixedConfirmReason.targetUnbound)));
      expect(s.writes, isEmpty);
      await h!.coordinator.reject(p);
    }
  });

  test('P6 fragment checker refuses new secrets', () async {
    h = await P6Coordinator.create(s);
    h!.secrets = {'new-sensitive-value'};
    final p = await h!.propose(
      'edit_file',
      args: {
        ...p6Args('edit_file'),
        'edits': [
          {'old': 'alpha', 'new': 'new-sensitive-value'},
        ],
      },
    );
    expect(p, isNull);
    expect(s.writes, isEmpty);
  });

  test(
    'P6 create and suggestion server content scan is required and blocks secrets',
    () async {
      s.missing = true;
      h = await P6Coordinator.create(s);
      h!.secrets = {'new-sensitive-value'};
      final p = await h!.propose(
        'createFile',
        args: {...p6Args('createFile'), 'content': 'new-sensitive-value'},
      );
      expect(p, isNull);
      expect(s.writes, isEmpty);
      h!.beginRun('Apply !3 `work` `src/a.txt`');
      s.suggestionAfter = 'new-sensitive-value';
      expect(await h!.propose('applySuggestion', id: 'suggestion'), isNull);
      expect(s.writes, isEmpty);
    },
  );

  test(
    'P6 single suggestion uses highest tier and foreign batch is budget-blocked before HTTP',
    () async {
      s.protected = true;
      h = await P6Coordinator.create(s);
      final p = await h!.propose('applySuggestion');
      expect(p!.tier.tier, AiWriteTier.t4);
      expect(p.tier.typedName, 'work');
      expect(p.releaseName, '!3');
      await h!.coordinator.reject(p);
      h!.coordinator.beginTurn();
      final count = s.adapter.requests.length;
      expect(await h!.propose('batchApplySuggestions', id: 'batch'), isNull);
      expect(
        h!.coordinator.outcomeFor('batch')!.reasonCode,
        'httpBudgetExceeded',
      );
      expect(s.adapter.requests, hasLength(count));
    },
  );

  test(
    'P6 checker accepts preserved preexisting marker and secret outside the edit',
    () async {
      s.contents[p6L] = '[REDACTED:old]\nold-sensitive-value\nalpha\n';
      h = await P6Coordinator.create(s);
      h!.secrets = {'old-sensitive-value'};
      final p = await h!.propose('edit_file');
      expect(p, isNotNull);
      expect(s.writes, isEmpty);
    },
  );

  test('P6 digest binds original bytes as well as L and diff', () async {
    final context = 'context\n' * 10;
    s.contents[p6L] = 'first header\n${context}alpha\n';
    final first = await s.writePort.prepare(
      p6Request('edit_file', p6Args('edit_file')),
    );
    final other = P6Server();
    try {
      other.contents[p6L] = 'other header\n${context}alpha\n';
      final next = await other.writePort.prepare(
        p6Request('edit_file', p6Args('edit_file')),
      );
      expect(first.journal.lastCommitId, next.journal.lastCommitId);
      expect(
        (first.preview as port.AiDiffPreview).lines.map(
          (line) => (line.kind, line.text, line.oldLine, line.newLine),
        ),
        (next.preview as port.AiDiffPreview).lines.map(
          (line) => (line.kind, line.text, line.oldLine, line.newLine),
        ),
      );
      expect(first.bindingDigest, isNot(next.bindingDigest));
    } finally {
      other.close();
    }
  });

  test(
    'P6 binding digest includes final diff as well as original and L',
    () async {
      final first = await s.writePort.prepare(
        p6Request('edit_file', p6Args('edit_file')),
      );
      final second = await s.writePort.prepare(
        p6Request('edit_file', {
          ...p6Args('edit_file'),
          'edits': [
            {'old': 'alpha', 'new': 'gamma'},
          ],
        }),
      );
      expect(first.journal.lastCommitId, second.journal.lastCommitId);
      expect(first.textScan!.original, second.textScan!.original);
      expect(first.bindingDigest, isNot(second.bindingDigest));
    },
  );

  test(
    'P6 own reason codes cross the existing coordinator exception seam',
    () async {
      h = await P6Coordinator.create(s);
      final p = await h!.propose('createFile');
      expect(p, isNull);
      expect(h!.coordinator.outcomeFor('call')!.reasonCode, 'fileExists');
      expect(s.writes, isEmpty);
    },
  );

  test(
    'P6 cold-cache file request counts fit each independently counted OAuth cap',
    () async {
      for (final op in [
        'edit_file',
        'createFile',
        'deleteFile',
        'applySuggestion',
      ]) {
        final local = P6Server();
        try {
          local.missing = op == 'createFile';
          final args = p6Args(op);
          await local.writePort.prepare(p6Request(op, args));
          final fresh = await local.writePort.prepare(p6Request(op, args));
          final result =
              await local.writePort.commit(fresh, mayStart: () => true)
                  as port.AiWriteSettled;
          expect(result.state, AiJournalState.succeeded);
          // The port uses uncached write snapshots. This port-only harness
          // omits the two project freshness GETs proven by the controller test.
          final coldReads = local.adapter.requests.length - 1 + 2;
          final independent = coldReads * 2 + 1;
          final expected = {
            'edit_file': 35,
            'createFile': 27,
            'deleteFile': 29,
            'applySuggestion': 27,
          };
          expect(independent, expected[op]);
          expect(
            independent,
            lessThanOrEqualTo(productionAiLedger.find(op)!.httpCap),
          );
        } finally {
          local.close();
        }
      }
    },
  );
}
