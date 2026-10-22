import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'p6_support.dart';

Matcher reason(String code) =>
    isA<AiJournalException>().having((e) => e.reason, 'reason', code);

void main() {
  late P6Server s;
  setUp(() => s = P6Server());
  tearDown(() => s.close());

  for (final op in ['applySuggestion', 'batchApplySuggestions']) {
    test(
      'P6 $op verifies scoped discussion then dispatches global ids once',
      () async {
        final p = await s.writePort.prepare(p6Request(op, p6Args(op)));
        expect(p.releaseName, '!3');
        expect(p.writeKeys.single.parts, [
          p6Account,
          'project:9',
          'ref',
          'work',
          'src/a.txt',
        ]);
        expect(p.dependencyKeys.single.parts, [
          p6Account,
          'project:9',
          'mergeRequest',
          '3',
        ]);
        expect(p.textScan!.newTexts, ['beta']);
        expect(p.bindingTargets, hasLength(2));
        final preview = p.preview as AiFieldsPreview;
        final changes = preview.fields['changes']! as List;
        expect((changes.single as Map)['path'], 'src/a.txt');
        final result =
            await s.writePort.commit(p, mayStart: () => true) as AiWriteSettled;
        expect(result.state, AiJournalState.succeeded);
        expect(s.writes, hasLength(1));
        expect(s.writes.single.method, 'PUT');
        expect(
          s.writes.single.uri.path,
          op == 'applySuggestion'
              ? '/gitlab/api/v4/suggestions/42/apply'
              : '/gitlab/api/v4/suggestions/batch_apply',
        );
        expect(result.projection.keys, isNot(contains('to_content')));
        expect(
          s.adapter.requests.where((r) => r.uri.path.contains('/discussions/')),
          hasLength(2),
        );
      },
    );
  }

  test(
    'P6 parser-resolved server suggestion body is previewed and scanned',
    () async {
      s.suggestionAfter = '';
      s.suggestionBody = '```suggestion\nresolved replacement\n```';
      final p = await s.writePort.prepare(
        p6Request('applySuggestion', p6Args('applySuggestion')),
      );
      expect(p.textScan!.newTexts, ['resolved replacement\n']);
      final changes = (p.preview as AiFieldsPreview).fields['changes']! as List;
      final lines = (changes.single as Map)['lines']! as List;
      expect(
        lines.any(
          (line) =>
              (line as List)[0] == 'addition' &&
              line[1] == 'resolved replacement',
        ),
        isTrue,
      );
    },
  );

  for (final variant in [
    'type',
    'head',
    'pathType',
    'missingPaths',
    'sensitiveOld',
  ]) {
    test(
      'P6 malformed or stale suggestion position refuses: $variant',
      () async {
        if (variant == 'type') s.positionType = 'image';
        if (variant == 'head') s.positionHead = p6NextL;
        if (variant == 'pathType') s.positionOldPath = 42;
        if (variant == 'missingPaths') s.omitPositionPaths = true;
        if (variant == 'sensitiveOld') s.suggestionOldPath = '.env';
        await expectLater(
          s.writePort.prepare(
            p6Request('applySuggestion', p6Args('applySuggestion')),
          ),
          throwsA(
            reason(
              variant == 'sensitiveOld'
                  ? 'sensitivePath'
                  : variant == 'missingPaths'
                  ? 'invalidPath'
                  : 'suggestionForeign',
            ),
          ),
        );
        expect(s.writes, isEmpty);
      },
    );
  }

  for (final variant in ['fork', 'note', 'suggestion']) {
    test(
      'P6 foreign suggestion $variant is rejected before global mutation',
      () async {
        if (variant == 'fork') s.sourceProjectId = 10;
        if (variant == 'note') s.noteIdOffset = 100;
        if (variant == 'suggestion') s.suggestionOffset = 100;
        await expectLater(
          s.writePort.prepare(
            p6Request('applySuggestion', p6Args('applySuggestion')),
          ),
          throwsA(reason('suggestionForeign')),
        );
        expect(s.writes, isEmpty);
      },
    );
  }

  for (final applied in [true, false]) {
    test('P6 applied or nonappliable suggestion refuses: $applied', () async {
      s.suggestionApplied = applied;
      s.suggestionAppliable = applied;
      await expectLater(
        s.writePort.prepare(
          p6Request('applySuggestion', p6Args('applySuggestion')),
        ),
        throwsA(reason('suggestionNotAppliable')),
      );
      expect(s.writes, isEmpty);
    });
  }

  test('P6 batch validates every item before any mutation', () async {
    final args = {
      ...p6Args('batchApplySuggestions'),
      'suggestions': [
        p6Item(1),
        {...p6Item(2), 'suggestionId': 999},
      ],
    };
    await expectLater(
      s.writePort.prepare(p6Request('batchApplySuggestions', args)),
      throwsA(reason('suggestionForeign')),
    );
    expect(
      s.adapter.requests.where((r) => r.uri.path.contains('/discussions/')),
      hasLength(2),
    );
    expect(s.writes, isEmpty);
  });

  test(
    'P6 batch caps twenty and rejects duplicate global ids before reads',
    () async {
      for (final entries in [
        [for (var i = 1; i <= 21; i++) p6Item(i)],
        [p6Item(1), p6Item(1)],
      ]) {
        await expectLater(
          s.writePort.prepare(
            p6Request('batchApplySuggestions', {
              ...p6Args('batchApplySuggestions'),
              'suggestions': entries,
            }),
          ),
          throwsA(
            reason(
              entries.length == 21 ? 'batchTooLarge' : 'suggestionForeign',
            ),
          ),
        );
      }
      expect(s.adapter.requests, isEmpty);
    },
  );

  test(
    'P6 suggestion CI is based on owned paths, including renamed old path',
    () async {
      s.ciConfig = 'ci/custom.yml';
      s.suggestionPath = 'ci/custom.yml';
      var p = await s.writePort.prepare(
        p6Request('applySuggestion', p6Args('applySuggestion')),
      );
      expect(p.facts.touchesCiConfig, isTrue);
      expect(p.confirmName, 'ci/custom.yml');
      s.suggestionPath = 'src/a.txt';
      s.suggestionOldPath = 'ci/custom.yml';
      p = await s.writePort.prepare(
        p6Request('applySuggestion', p6Args('applySuggestion')),
      );
      expect(p.facts.touchesCiConfig, isTrue);
      expect(p.confirmName, 'ci/custom.yml');
      s.suggestionOldPath = null;
      p = await s.writePort.prepare(
        p6Request('applySuggestion', {
          ...p6Args('applySuggestion'),
          'commitMessage': 'mention .gitlab-ci.yml',
        }),
      );
      expect(p.facts.touchesCiConfig, isFalse);
    },
  );

  test('P6 batch checks the highest path tier and binds every path', () async {
    s.ciConfig = 'ci/custom.yml';
    s.beforeRequest = (r) {
      if (r.uri.path.contains('/discussions/')) {
        s.suggestionPath = r.uri.path.endsWith('/d2')
            ? 'ci/custom.yml'
            : 'src/a.txt';
      }
    };
    final p = await s.writePort.prepare(
      p6Request('batchApplySuggestions', {
        ...p6Args('batchApplySuggestions'),
        'suggestions': [p6Item(1), p6Item(2)],
      }),
    );
    expect(p.facts.touchesCiConfig, isTrue);
    expect(p.confirmName, 'ci/custom.yml');
    expect(
      p.writeKeys.map((key) => key.parts.last),
      unorderedEquals(['src/a.txt', 'ci/custom.yml']),
    );
    expect(
      p.bindingTargets
          .where((target) => target.path != null)
          .map((target) => target.path),
      unorderedEquals(['src/a.txt', 'ci/custom.yml']),
    );
    expect(p.textScan!.newTexts, ['beta', 'beta']);
  });

  for (final path in ['.env', '../outside']) {
    test('P6 unsafe suggestion path is refused: $path', () async {
      s.suggestionPath = path;
      await expectLater(
        s.writePort.prepare(
          p6Request('applySuggestion', p6Args('applySuggestion')),
        ),
        throwsA(reason(path == '.env' ? 'sensitivePath' : 'invalidPath')),
      );
      expect(s.writes, isEmpty);
    });
  }

  test('P6 readback must observe each applied suggestion', () async {
    final p = await s.writePort.prepare(
      p6Request('applySuggestion', p6Args('applySuggestion')),
    );
    s.suggestionReadbackApplied = false;
    final result =
        await s.writePort.commit(p, mayStart: () => true) as AiWriteSettled;
    expect(result.state, AiJournalState.writeUncertain);
    expect(result.resultCode, 'readbackFailed');
    expect(s.writes, hasLength(1));
  });

  test(
    'P6 twenty-discussion batch actual request count fits truthful replay cap',
    () async {
      final args = {
        ...p6Args('batchApplySuggestions'),
        'suggestions': [for (var i = 1; i <= 20; i++) p6Item(i)],
      };
      final first = await s.writePort.prepare(
        p6Request('batchApplySuggestions', args),
      );
      final fresh = await s.writePort.prepare(
        p6Request('batchApplySuggestions', args),
      );
      expect(first.bindingDigest, fresh.bindingDigest);
      final result =
          await s.writePort.commit(fresh, mayStart: () => true)
              as AiWriteSettled;
      expect(result.state, AiJournalState.succeeded);
      // 24 proposal reads + 24 dispatch reads + 20 readback reads + one PUT.
      expect(s.adapter.requests, hasLength(69));
      final actualWorstReplay =
          (s.adapter.requests.length - s.writes.length) * 2 + s.writes.length;
      expect(actualWorstReplay, 137);
      expect(
        actualWorstReplay,
        lessThanOrEqualTo(
          productionAiLedger.find('batchApplySuggestions')!.httpCap,
        ),
      );
    },
  );
}
