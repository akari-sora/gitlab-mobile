import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/failure.dart';

import 'p6_support.dart';

Matcher reason(String code) =>
    isA<AiWriteRefused>().having((e) => e.reason, 'reason', code);

void main() {
  late P6Server s;
  setUp(() => s = P6Server());
  tearDown(() => s.close());

  test(
    'P6 ledger preserves five model-visible closed named operations and counted caps',
    () {
      final expected = {
        'edit_file': ('updateRepositoryFile', 31, true),
        'createFile': ('createRepositoryFile', 23, true),
        'deleteFile': ('deleteFile', 25, false),
        'applySuggestion': ('applySuggestion', 23, true),
        'batchApplySuggestions': ('batchApplySuggestions', 137, true),
      };
      expect(aiFileRows, hasLength(5));
      for (final row in aiFileRows) {
        expect(row.modelVisible, isTrue);
        expect(row.namedMethod, expected[row.operationId]!.$1);
        expect(row.httpCap, expected[row.operationId]!.$2);
        expect(row.readback, expected[row.operationId]!.$3);
        expect(row.arguments.keys, isNot(contains('url')));
        expect(row.arguments.keys, isNot(contains('lastCommit')));
      }
      final batch = productionAiLedger.find('batchApplySuggestions')!;
      expect(
        batch.arguments['suggestions']!.properties.keys,
        unorderedEquals(['discussionId', 'noteId', 'suggestionId']),
      );
      expect(
        productionAiLedger.modelVisible.any(
          (r) => expected.containsKey(r.operationId),
        ),
        isTrue,
      );
    },
  );

  test(
    'P6 edit uses immutable L, exact payload, diff, scan, journal and composite keys',
    () async {
      final p = await s.writePort.prepare(
        p6Request('edit_file', p6Args('edit_file')),
      );
      expect(p.journal.lastCommitId, p6L);
      expect(p.releaseName, 'src/a.txt');
      expect(p.confirmName, isNull);
      expect(p.preview, isA<AiDiffPreview>());
      final preview = p.preview as AiDiffPreview;
      expect(
        preview.lines.any(
          (l) => l.kind == AiDiffLineKind.addition && l.text == 'beta',
        ),
        isTrue,
      );
      expect(p.textScan!.original, 'alpha\n');
      expect(p.textScan!.newTexts, ['beta']);
      expect(p.bindingTargets.single.kind, AiTargetKind.file);
      expect(p.bindingTargets.single.refName, 'work');
      expect(p.bindingTargets.single.path, 'src/a.txt');
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
        'ref',
        'work',
      ]);
      final raw = s.adapter.requests.singleWhere(
        (r) => r.uri.path.endsWith('/raw'),
      );
      expect(raw.uri.queryParameters['ref'], p6L);
      final outcome =
          await s.writePort.commit(p, mayStart: () => true) as AiWriteSettled;
      expect(outcome.state, AiJournalState.succeeded);
      expect(s.writes.single.method, 'PUT');
      expect(s.writes.single.data, {
        'branch': 'work',
        'content': 'beta\n',
        'commit_message': 'synthetic change',
        'last_commit_id': p6L,
      });
      expect(
        await s.writePort.commit(p, mayStart: () => true),
        isA<AiWriteNotSent>(),
      );
      expect(s.writes, hasLength(1));
    },
  );

  test(
    'P6 branch advance between metadata and raw never mixes content',
    () async {
      s.beforeRequest = (r) {
        if (r.uri.path.endsWith('/raw')) s.lastCommit = p6NextL;
      };
      final p = await s.writePort.prepare(
        p6Request('edit_file', p6Args('edit_file')),
      );
      expect(p.textScan!.original, 'alpha\n');
      final outcome =
          await s.writePort.commit(p, mayStart: () => true) as AiWriteSettled;
      expect(outcome.state, AiJournalState.failedCertain);
      expect(outcome.httpStatus, 409);
      expect(s.writes.single.method, 'PUT');
      expect((s.writes.single.data! as Map)['last_commit_id'], p6L);
    },
  );

  for (final op in ['edit_file', 'deleteFile']) {
    test('P6 $op missing revision never falls back to create', () async {
      s.lastCommit = null;
      await expectLater(
        s.writePort.prepare(p6Request(op, p6Args(op))),
        throwsA(isA<ApiFailure>()),
      );
      expect(s.writes, isEmpty);
    });
    test('P6 $op validates full revision hash', () async {
      s.lastCommit = 'short';
      await expectLater(
        s.writePort.prepare(p6Request(op, p6Args(op))),
        throwsA(
          isA<ApiFailure>().having(
            (e) => e.kind,
            'kind',
            FailureKind.invalidResponse,
          ),
        ),
      );
      expect(s.writes, isEmpty);
    });
    test('P6 $op missing file is refused ambiguously', () async {
      s.missing = true;
      await expectLater(
        s.writePort.prepare(p6Request(op, p6Args(op))),
        throwsA(reason('fileMissing')),
      );
      expect(s.writes, isEmpty);
    });
  }

  test(
    'P6 create existing file refuses; only actual 404 permits POST',
    () async {
      final request = p6Request('createFile', p6Args('createFile'));
      await expectLater(
        s.writePort.prepare(request),
        throwsA(reason('fileExists')),
      );
      expect(s.writes, isEmpty);
      s.missing = true;
      final p = await s.writePort.prepare(request);
      expect((p.preview as AiDiffPreview).newFile, isTrue);
      final outcome =
          await s.writePort.commit(p, mayStart: () => true) as AiWriteSettled;
      expect(outcome.state, AiJournalState.succeeded);
      expect(s.writes.single.method, 'POST');
      expect(
        (s.writes.single.data! as Map).containsKey('last_commit_id'),
        isFalse,
      );
    },
  );

  test(
    'P6 create 403 does not permit POST and create race 400 is certain',
    () async {
      s.beforeRequest = (r) {
        if (r.method == 'HEAD') {
          throw const ApiFailure(FailureKind.forbidden, status: 403);
        }
      };
      await expectLater(
        s.writePort.prepare(p6Request('createFile', p6Args('createFile'))),
        throwsA(isA<ApiFailure>()),
      );
      expect(s.writes, isEmpty);
      s.beforeRequest = null;
      s.missing = true;
      final p = await s.writePort.prepare(
        p6Request('createFile', p6Args('createFile')),
      );
      s.missing = false;
      final result =
          await s.writePort.commit(p, mayStart: () => true) as AiWriteSettled;
      expect(result.state, AiJournalState.failedCertain);
      expect(result.httpStatus, 400);
      expect(s.writes.single.method, 'POST');
    },
  );

  test(
    'P6 delete uses L, path confirmation and acknowledgement without 404 proof',
    () async {
      final p = await s.writePort.prepare(
        p6Request('deleteFile', p6Args('deleteFile')),
      );
      expect(p.confirmName, 'src/a.txt');
      expect(p.preview, isA<AiDeletePreview>());
      final result =
          await s.writePort.commit(p, mayStart: () => true) as AiWriteSettled;
      expect(result.state, AiJournalState.succeeded);
      expect(s.writes.single.method, 'DELETE');
      expect((s.writes.single.data! as Map)['last_commit_id'], p6L);
      expect(s.adapter.requests.last.method, 'DELETE');
    },
  );

  for (final entry in <String, List<Map<String, String>>>{
    'fragmentNotFound': [
      {'old': 'absent', 'new': 'beta'},
    ],
    'fragmentNotUnique': [
      {'old': '', 'new': 'beta'},
    ],
    'fragmentsOverlap': [
      {'old': 'alpha', 'new': 'beta'},
      {'old': 'pha', 'new': 'x'},
    ],
  }.entries) {
    test(
      'P6 exact engine rejection ${entry.key} reaches reason boundary',
      () async {
        await expectLater(
          s.writePort.prepare(
            p6Request('edit_file', {
              ...p6Args('edit_file'),
              'edits': entry.value,
            }),
          ),
          throwsA(reason(entry.key)),
        );
        expect(s.writes, isEmpty);
      },
    );
  }

  for (final path in ['../a', '/a', 'a//b', 'a/./b', 'a\\b', 'a\u0000b']) {
    test(
      'P6 invalid path rejected before traffic: ${path.codeUnits}',
      () async {
        await expectLater(
          s.writePort.prepare(
            p6Request('createFile', p6Args('createFile', path: path)),
          ),
          throwsA(reason('invalidPath')),
        );
        expect(s.adapter.requests, isEmpty);
      },
    );
  }
  for (final path in ['.env', 'keys/signing.properties', 'a/private.pem']) {
    test('P6 sensitive path rejected before traffic: $path', () async {
      await expectLater(
        s.writePort.prepare(
          p6Request('edit_file', p6Args('edit_file', path: path)),
        ),
        throwsA(reason('sensitivePath')),
      );
      expect(s.adapter.requests, isEmpty);
    });
  }

  for (final entry in <String, String>{
    'binaryFile': 'alpha\u0000',
    'fileTooLarge': 'alpha\n${'x' * (2 * 1024 * 1024)}',
  }.entries) {
    test('P6 source ${entry.key} rejected before mutation', () async {
      s.contents[p6L] = entry.value;
      await expectLater(
        s.writePort.prepare(p6Request('edit_file', p6Args('edit_file'))),
        throwsA(reason(entry.key)),
      );
      expect(s.writes, isEmpty);
    });
    test('P6 new content ${entry.key} rejected before reads', () async {
      await expectLater(
        s.writePort.prepare(
          p6Request('createFile', {
            ...p6Args('createFile'),
            'content': entry.value,
          }),
        ),
        throwsA(reason(entry.key)),
      );
      expect(s.adapter.requests, isEmpty);
    });
  }

  test('P6 new content line limit is enforced before reads', () async {
    await expectLater(
      s.writePort.prepare(
        p6Request('createFile', {
          ...p6Args('createFile'),
          'content': 'line\n' * 20000,
        }),
      ),
      throwsA(reason('fileTooLarge')),
    );
    expect(s.adapter.requests, isEmpty);
  });

  test(
    'P6 readback 401 preserves uncertainty after accepted mutation',
    () async {
      final p = await s.writePort.prepare(
        p6Request('edit_file', p6Args('edit_file')),
      );
      s.readbackFails = true;
      final outcome =
          await s.writePort.commit(p, mayStart: () => true) as AiWriteSettled;
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(outcome.resultCode, 'readbackFailed');
      expect(s.writes, hasLength(1));
    },
  );

  test(
    'P6 exact window provenance is retained for existing redaction markers',
    () async {
      s.contents[p6L] = '[REDACTED:old]\nalpha\n';
      final p = await s.writePort.prepare(
        p6Request('edit_file', p6Args('edit_file', path: 'README.md')),
      );
      expect(p.textScan!.markdown, isTrue);
      expect(p.textScan!.windows, isNotEmpty);
      // A full-source reconstruction would lose the exact-edit engine provenance.
      expect(p.textScan!.newTexts, ['beta']);
    },
  );

  test(
    'P6 foreign account, project or scoped resource never grants repository writes',
    () async {
      for (final scope in [
        const AiWriteScope(
          accountKey: 'https://example.com/gitlab#8',
          grants: [AiScopeGrant(kind: AiScopeKind.project, projectId: 9)],
        ),
        const AiWriteScope(
          accountKey: p6Account,
          grants: [
            AiScopeGrant(kind: AiScopeKind.workItem, projectId: 9, iid: 3),
          ],
        ),
        const AiWriteScope(
          accountKey: p6Account,
          grants: [AiScopeGrant(kind: AiScopeKind.project, projectId: 10)],
        ),
      ]) {
        await expectLater(
          s.writePort.prepare(
            p6Request('edit_file', p6Args('edit_file'), scope: scope),
          ),
          throwsA(isA<ApiFailure>()),
        );
      }
      expect(s.adapter.requests, isEmpty);
    },
  );

  test('P6 encoded branch and path remain single API path segments', () async {
    s.branchName = 'feature/topic';
    final args = {
      ...p6Args('edit_file', path: 'src/a b#.txt'),
      'branch': s.branchName,
    };
    final p = await s.writePort.prepare(p6Request('edit_file', args));
    await s.writePort.commit(p, mayStart: () => true);
    expect(s.writes.single.uri.pathSegments.last, 'src/a b#.txt');
    expect(s.writes.single.uri.queryParameters, isEmpty);
    expect(
      s.adapter.requests.any((r) => r.uri.pathSegments.last == 'feature/topic'),
      isTrue,
    );
  });
}
