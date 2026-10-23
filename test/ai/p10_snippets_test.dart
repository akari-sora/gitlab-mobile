import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/exact_edit.dart' as exact;
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_preview.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'p10_support.dart';

void main() {
  late P10Server s;
  P10Coordinator? h;
  setUp(() => s = P10Server());
  tearDown(() async {
    await h?.dispose();
    h = null;
    s.close();
  });

  test('P10 six closed model-visible rows use independent counted budgets', () {
    const counts = {
      'createSnippet': (2, 3, 19),
      'updateSnippetMetadata': (3, 1, 19),
      'updateSnippet': (5, 3, 31),
      'updateSnippetFiles': (6, 4, 37),
      'deleteSnippetFile': (5, 1, 27),
      'deleteSnippet': (8, 0, 37),
    };
    expect(aiSnippetRows.length, 6);
    for (final row in aiSnippetRows) {
      final count = counts[row.operationId]!;
      expect(row.namedMethod, row.operationId);
      expect(row.modelVisible, isTrue);
      expect(row.scopeClass, AiScopeClass.project);
      expect(row.httpCap, 2 * (2 * (1 + count.$1) + count.$2) + 1);
      expect(row.httpCap, count.$3);
      expect(row.httpCap, lessThanOrEqualTo(40));
      expect(productionAiLedger.modelVisible, contains(row));
    }
    final metadata = productionAiLedger.find('updateSnippetMetadata')!;
    expect(metadata.editableField, 'description');
    final description =
        metadata.arguments['fields']!.properties['description']!;
    expect(description.writableField, 'snippetDescription');
    expect(description.text, AiTextRole.renderedMarkdown);
  });

  for (final op in [
    'createSnippet',
    'updateSnippetMetadata',
    'updateSnippet',
    'updateSnippetFiles',
    'deleteSnippetFile',
    'deleteSnippet',
  ]) {
    test('P10 $op named wire, stable locks and one dispatch', () async {
      if (op != 'updateSnippet') s = _replace(s, files: {'b.txt': 'second\n'});
      h = await P10Coordinator.create(s);
      final args = op == 'updateSnippetFiles'
          ? _actions([_create('new.txt', 'new\n')])
          : p10Args(op);
      final p = await h!.propose(op, args: args);
      expect(p, isNotNull);
      expect(p!.releaseName, 'team/example-9');
      expect(
        p.tier.tier,
        op.startsWith('delete') ? AiWriteTier.t4 : AiWriteTier.t2,
      );
      expect(s.writes, isEmpty);
      final result = await h!.coordinator
          .approve(p, typedName: p.tier.typedName)
          .timeout(p10Timeout);
      expect(result.state, AiJournalState.succeeded);
      expect(result.mutationCount, 1);
      expect(result.readbackConfirmed, op != 'deleteSnippet');
      expect(s.writes.length, 1);
      final wire = s.writes.single;
      expect(wire.uri.host, 'example.com');
      expect(
        wire.uri.path,
        op == 'createSnippet'
            ? '/gitlab/api/v4/projects/9/snippets'
            : '/gitlab/api/v4/projects/9/snippets/12',
      );
      expect(
        wire.method,
        op == 'createSnippet'
            ? 'POST'
            : op == 'deleteSnippet'
            ? 'DELETE'
            : 'PUT',
      );
      expect(wire.followRedirects, isFalse);
      final entry = h!.journal.entries(p10Account).single;
      expect(entry.writeKeys.single.parts, [
        p10Account,
        'project:9',
        'snippet',
        if (op != 'createSnippet') '12',
      ]);
      expect(entry.releaseName, 'team/example-9');
      expect(entry.payloadSha256, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(entry.observation, isNot(contains('alpha')));
      await h!.coordinator.approve(p, typedName: p.tier.typedName);
      expect(s.writes.length, 1);
      expect(
        s.adapter.requests.where((r) => r.uri.path.endsWith('graphql')),
        isEmpty,
      );
    });
  }

  for (final visibility in ['internal', 'public']) {
    test(
      'P10 new $visibility snippet is hard line at bypass with project name',
      () async {
        h = await P10Coordinator.create(s, level: AiAutonomyLevel.bypass);
        final p = await h!.propose(
          'createSnippet',
          args: {...p10Args('createSnippet'), 'visibility': visibility},
        );
        expect(p!.tier.tier, AiWriteTier.hardLine);
        expect(p.tier.typedName, 'team/example-9');
        expect(p.tier.requiresTypedName, isTrue);
        expect(s.writes, isEmpty);
      },
    );
  }

  for (final pair in [
    ('private', 'internal'),
    ('private', 'public'),
    ('internal', 'public'),
    ('public', 'internal'),
    ('internal', 'private'),
  ]) {
    test('P10 metadata visibility ${pair.$1} to ${pair.$2}', () async {
      s.record['visibility'] = pair.$1;
      h = await P10Coordinator.create(s, level: AiAutonomyLevel.bypass);
      final p = await h!.propose(
        'updateSnippetMetadata',
        args: {
          'projectId': 9,
          'snippetId': 12,
          'fields': {'visibility': pair.$2},
        },
      );
      final raised = pair.$1 == 'private' || pair == ('internal', 'public');
      expect(p!.tier.tier, raised ? AiWriteTier.hardLine : AiWriteTier.t2);
      expect(p.tier.typedName, raised ? '#12' : null);
      if (raised) {
        await h!.coordinator.approve(p, typedName: 'Snippet');
        expect(s.writes, isEmpty);
      }
    });
  }

  test(
    'P10 omitted metadata visibility preserves fresh value and class B bytes',
    () async {
      const description = '  @param\r\n/merge\n@decorator\n';
      s.record['visibility'] = 'internal';
      h = await P10Coordinator.create(s);
      final p = await h!.propose(
        'updateSnippetMetadata',
        args: {
          'projectId': 9,
          'snippetId': 12,
          'fields': {'description': description},
        },
      );
      expect(p!.tier.tier, AiWriteTier.t2);
      final result = await h!.coordinator.approve(p);
      expect(result.successful, isTrue);
      expect(s.writes.single.data, {
        'title': 'Snippet',
        'description': description,
        'visibility': 'internal',
      });
    },
  );

  test(
    'P10 single-file exact edits preserve multiline code and build local diff',
    () async {
      const original = '@param\r\nalpha\n/merge\n';
      const replacement = 'beta\n/approve\n@decorator';
      s.contents['a.txt'] = original;
      final args = {
        ...p10Args('updateSnippet'),
        'edits': [
          {'old': 'alpha', 'new': replacement},
        ],
      };
      final prepared = await s.writePort.prepare(
        p10Request('updateSnippet', args),
      );
      final scan = prepared.textScan!;
      expect(scan.markdown, isFalse);
      expect(scan.original, original);
      expect(scan.windows, isNotEmpty);
      final preview = prepared.preview as AiDiffPreview;
      expect(preview.path, 'a.txt');
      expect(preview.ref, '#12');
      expect(
        preview.lines.any(
          (line) =>
              line.kind == AiDiffLineKind.addition &&
              line.text.contains('beta'),
        ),
        isTrue,
      );
      h = await P10Coordinator.create(s);
      final p = await h!.propose('updateSnippet', args: args);
      final result = await h!.coordinator.approve(p!);
      expect(result.successful, isTrue);
      final body = s.writes.single.data! as Map;
      expect((body['files'] as List).single, {
        'action': 'update',
        'file_path': 'a.txt',
        'content': original.replaceFirst('alpha', replacement),
      });
    },
  );

  test(
    'P10 multi-file create move and exact update keep T2 and fixed payloads',
    () async {
      h = await P10Coordinator.create(s);
      final create = await h!.propose(
        'updateSnippetFiles',
        args: _actions([_create('nested/new.py', '@param\n/merge\r\n')]),
      );
      expect(create!.tier.tier, AiWriteTier.t2);
      expect((await h!.coordinator.approve(create)).successful, isTrue);
      expect((s.writes.last.data! as Map)['files'], [
        {
          'action': 'create',
          'file_path': 'nested/new.py',
          'content': '@param\n/merge\r\n',
        },
      ]);
      h!.beginRun();
      final move = await h!.propose(
        'updateSnippetFiles',
        id: 'move',
        args: _actions([
          {
            'action': 'move',
            'previous_path': 'nested/new.py',
            'file_path': 'nested/moved.py',
          },
        ]),
      );
      expect(move!.tier.tier, AiWriteTier.t2);
      expect((await h!.coordinator.approve(move)).successful, isTrue);
      expect((s.writes.last.data! as Map)['files'], [
        {
          'action': 'move',
          'previous_path': 'nested/new.py',
          'file_path': 'nested/moved.py',
        },
      ]);
      h!.beginRun();
      final update = await h!.propose(
        'updateSnippetFiles',
        id: 'edit',
        args: _actions([
          {
            'action': 'update',
            'file_path': 'nested/moved.py',
            'edits': [
              {'old': '@param', 'new': '@decorator'},
            ],
          },
        ]),
      );
      expect(update!.tier.tier, AiWriteTier.t2);
      expect((await h!.coordinator.approve(update)).successful, isTrue);
      expect(s.contents['nested/moved.py'], '@decorator\n/merge\r\n');
    },
  );

  test(
    'P10 file deletion confirms full pre-read path; last file is refused',
    () async {
      s = _replace(s, files: {'nested/b.txt': 'second'});
      h = await P10Coordinator.create(s);
      final p = await h!.propose(
        'deleteSnippetFile',
        args: p10Args('deleteSnippetFile', path: 'nested/b.txt'),
      );
      expect(p!.tier.typedName, 'nested/b.txt');
      expect(p.tier.tier, AiWriteTier.t4);
      expect(p.preview, isA<AiDeletePreview>());
      expect(
        (await h!.coordinator.approve(p, typedName: 'nested/b.txt')).successful,
        isTrue,
      );
      expect((s.writes.single.data! as Map)['files'], [
        {'action': 'delete', 'file_path': 'nested/b.txt'},
      ]);
      h!.beginRun();
      expect(await h!.propose('deleteSnippetFile', id: 'last'), isNull);
      expect(h!.coordinator.outcomeFor('last')!.reasonCode, 'snippetLastFile');
      expect(s.writes.length, 1);
    },
  );

  for (final change in [
    'timestamp',
    'visibility',
    'title',
    'description',
    'paths',
    'content',
    'rawRef',
    'projectIdentity',
  ]) {
    test('P10 dispatch rejects changed $change without mutation', () async {
      h = await P10Coordinator.create(s);
      final p = await h!.propose('updateSnippet');
      expect(p, isNotNull);
      switch (change) {
        case 'timestamp':
          s.record['updated_at'] = '2026-10-24T00:00:00Z';
        case 'visibility':
          s.record['visibility'] = 'public';
        case 'title':
          s.record['title'] = 'Other';
        case 'description':
          s.record['description'] = 'Other';
        case 'paths':
          (s.record['files']! as List).add(_file('extra.txt'));
        case 'content':
          s.contents['a.txt'] = 'alpha\nchanged\n';
        case 'rawRef':
          ((s.record['files']! as List).single
              as Map)['raw_url'] = (_file('a.txt')['raw_url']! as String)
              .replaceFirst('/main/', '/next/');
        case 'projectIdentity':
          s.beforeRequest = (r) {
            if (r.uri.path.endsWith('/projects/9')) s.projectId = 99;
          };
      }
      final result = await h!.coordinator.approve(p!);
      expect(result.state, AiJournalState.notExecuted);
      expect(
        result.reasonCode,
        change == 'paths'
            ? 'snippetFilesUnreadable'
            : change == 'projectIdentity'
            ? 'preflightFailed'
            : 'targetChanged',
      );
      expect(s.writes, isEmpty);
    });
  }

  test(
    'P10 changing REST metadata during content read refuses mixed snapshot',
    () async {
      s.beforeRequest = (r) {
        if (r.uri.path.endsWith('/raw')) {
          s.record['updated_at'] = '2026-10-24T00:00:00Z';
        }
      };
      h = await P10Coordinator.create(s);
      expect(await h!.propose('updateSnippet'), isNull);
      expect(h!.coordinator.outcomeFor('call')!.reasonCode, 'snippetChanged');
      expect(s.writes, isEmpty);
    },
  );

  test('P10 dispatch binds the current project path for creation', () async {
    h = await P10Coordinator.create(s);
    final p = await h!.propose('createSnippet');
    s.projectPath = 'team/renamed';
    final result = await h!.coordinator.approve(p!);
    expect(result.state, AiJournalState.notExecuted);
    expect(result.reasonCode, 'targetChanged');
    expect(s.writes, isEmpty);
  });

  for (final files in [
    null,
    'bad',
    <Object?>[],
    [null],
    [<String, Object?>{}],
    [
      {'path': 'a.txt'},
    ],
    [_file('../bad')],
    [_file('a.txt'), _file('a.txt')],
    [
      {'path': 'a.txt', 'raw_url': 'https://attacker.invalid/leak'},
    ],
    [
      {
        'path': 'a.txt',
        'raw_url':
            'https://attacker.invalid/gitlab/team/example-9/-/snippets/12/raw/main/a.txt',
      },
    ],
    [
      {
        'path': 'a.txt',
        'raw_url':
            'https://example.com/other/team/example-9/-/snippets/12/raw/main/a.txt',
      },
    ],
    [
      {
        'path': 'a.txt',
        'raw_url':
            'https://example.com/gitlab/team/example-9/-/snippets/99/raw/main/a.txt',
      },
    ],
  ]) {
    test(
      'P10 unreadable REST files ${jsonEncode(files)} refuses with reason',
      () async {
        s.record['files'] = files;
        h = await P10Coordinator.create(s);
        expect(await h!.propose('updateSnippetMetadata'), isNull);
        expect(
          h!.coordinator.outcomeFor('call')!.reasonCode,
          'snippetFilesUnreadable',
        );
        expect(s.writes, isEmpty);
        expect(
          s.adapter.requests.every((r) => r.uri.host == 'example.com'),
          isTrue,
        );
      },
    );
  }

  for (final path in [
    '',
    '../bad',
    '/absolute',
    'a//b',
    'a/./b',
    'a\\b',
    'a\n.txt',
    ' a.txt',
  ]) {
    test(
      'P10 invalid model path ${jsonEncode(path)} rejected before traffic',
      () async {
        await expectLater(
          s.writePort.prepare(
            p10Request('createSnippet', {
              ...p10Args('createSnippet'),
              'path': path,
            }),
          ),
          throwsA(anyOf(isA<port.AiWriteRefused>(), isA<ApiFailure>())),
        );
        expect(s.adapter.requests, isEmpty);
      },
    );
  }

  for (final bad in [
    {'projectId': 9, 'snippetId': 12, 'content': 'whole replacement'},
    {'projectId': 9, 'snippetId': 12, 'edits': <Object?>[]},
    _actions([
      {
        'action': 'update',
        'file_path': 'a.txt',
        'content': 'whole replacement',
      },
    ]),
    _actions([
      {'action': 'delete', 'file_path': 'a.txt'},
    ]),
    _actions([
      {
        'action': 'move',
        'file_path': 'b.txt',
        'previous_path': 'a.txt',
        'content': 'mixed',
      },
    ]),
    _actions([
      {
        'action': 'http',
        'file_path': 'a.txt',
        'url': 'https://attacker.invalid',
      },
    ]),
  ]) {
    test(
      'P10 no whole-file or generic action escape ${jsonEncode(bad)}',
      () async {
        final op = bad.containsKey('actions')
            ? 'updateSnippetFiles'
            : 'updateSnippet';
        await expectLater(
          s.writePort.prepare(p10Request(op, bad)),
          throwsA(isA<ApiFailure>()),
        );
        expect(s.adapter.requests, isEmpty);
      },
    );
  }

  for (final edits in [
    [
      {'old': 'missing', 'new': 'new'},
    ],
    [
      {'old': '', 'new': 'new'},
    ],
    [
      {'old': 'alpha', 'new': 'new'},
      {'old': 'lpha', 'new': 'new'},
    ],
  ]) {
    test(
      'P10 exact engine refuses invalid anchors ${jsonEncode(edits)}',
      () async {
        h = await P10Coordinator.create(s);
        expect(
          await h!.propose(
            'updateSnippet',
            args: {...p10Args('updateSnippet'), 'edits': edits},
          ),
          isNull,
        );
        expect(
          h!.coordinator.outcomeFor('call')!.reasonCode,
          edits.length == 2
              ? 'fragmentsOverlap'
              : edits.single['old'] == ''
              ? 'fragmentNotUnique'
              : 'fragmentNotFound',
        );
        expect(s.writes, isEmpty);
      },
    );
  }

  for (final op in ['createSnippet', 'updateSnippet', 'updateSnippetFiles']) {
    for (final bad in ['[REDACTED secret]', 'glpat-ABCDEFGHIJKLMNOPQRST']) {
      test(
        'P10 $op rejects new secret or marker ${bad.substring(0, 6)}',
        () async {
          h = await P10Coordinator.create(s, level: AiAutonomyLevel.bypass);
          final args = op == 'createSnippet'
              ? {...p10Args(op), 'content': bad}
              : op == 'updateSnippet'
              ? {
                  ...p10Args(op),
                  'edits': [
                    {'old': 'alpha', 'new': bad},
                  ],
                }
              : _actions([_create('new.txt', bad)]);
          expect(await h!.propose(op, args: args), isNull);
          expect(
            h!.coordinator.outcomeFor('call')!.reasonCode,
            bad.startsWith('[') ? 'redactionMarker' : 'secret',
          );
          expect(s.writes, isEmpty);
        },
      );
    }
  }

  test(
    'P10 existing secret and marker do not block unrelated exact edit',
    () async {
      const existing = 'glpat-ABCDEFGHIJKLMNOPQRST';
      s.contents['a.txt'] =
          '$existing\n[REDACTED]\n${'unchanged\n' * 8}alpha\n';
      h = await P10Coordinator.create(s);
      final p = await h!.propose('updateSnippet');
      expect(p, isNotNull);
      final prepared = await s.writePort.prepare(
        p10Request('updateSnippet', p10Args('updateSnippet')),
      );
      final checked = exact.checkFragments(
        prepared.textScan!,
        knownSecrets: {},
        instance: h!.placeholders.instance,
        visibility: const text.AiVisibilityContext(),
      );
      expect(checked.preexistingSecretHits, greaterThan(0));
      expect((await h!.coordinator.approve(p!)).successful, isTrue);
      expect(s.contents['a.txt'], contains(existing));
      expect(s.contents['a.txt'], contains('[REDACTED]'));
    },
  );

  test(
    'P10 nearby existing secret and marker retain engine window identity',
    () async {
      s.contents['a.txt'] = 'glpat-ABCDEFGHIJKLMNOPQRST\n[REDACTED]\nalpha\n';
      h = await P10Coordinator.create(s);
      final p = await h!.propose('updateSnippet');
      expect(p, isNotNull);
      expect((await h!.coordinator.approve(p!)).successful, isTrue);
      expect(
        s.contents['a.txt'],
        'glpat-ABCDEFGHIJKLMNOPQRST\n[REDACTED]\nbeta\n',
      );
    },
  );

  for (final field in ['title', 'description']) {
    test('P10 carried server $field is fully scanned before PUT', () async {
      s.record[field] = 'glpat-ABCDEFGHIJKLMNOPQRST';
      h = await P10Coordinator.create(s);
      expect(await h!.propose('updateSnippet'), isNull);
      expect(h!.coordinator.outcomeFor('call')!.reasonCode, 'secret');
      expect(s.writes, isEmpty);
    });
  }

  test('P10 carried server file paths are fully scanned before PUT', () async {
    s = _replace(s, files: {'glpat-ABCDEFGHIJKLMNOPQRST': 'second'});
    h = await P10Coordinator.create(s);
    expect(await h!.propose('updateSnippetMetadata'), isNull);
    expect(h!.coordinator.outcomeFor('call')!.reasonCode, 'secret');
    expect(s.writes, isEmpty);
  });

  test('P10 account and project-grant boundaries stop preflight', () async {
    await expectLater(
      s.writePort.prepare(
        p10Request('createSnippet', {
          ...p10Args('createSnippet'),
          'projectId': 99,
        }),
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(s.adapter.requests, isEmpty);
    s.actorId = 99;
    await expectLater(
      s.writePort.prepare(
        p10Request('createSnippet', p10Args('createSnippet')),
      ),
      throwsA(isA<ApiFailure>()),
    );
    expect(s.adapter.requests.length, 1);
    expect(s.writes, isEmpty);
  });

  test(
    'P10 existing snippet must match requested project and numeric id',
    () async {
      h = await P10Coordinator.create(s);
      s.snippetProjectId = 99;
      expect(await h!.propose('updateSnippetMetadata'), isNull);
      expect(s.writes, isEmpty);
      h!.beginRun();
      s.snippetProjectId = 9;
      s.record['id'] = 99;
      expect(await h!.propose('updateSnippetMetadata', id: 'other'), isNull);
      expect(s.writes, isEmpty);
    },
  );

  for (final actions in <List<Map<String, Object?>>>[
    [_create('a.txt', 'existing')],
    [_create('b.txt', 'first'), _create('b.txt', 'second')],
    [
      {'action': 'move', 'file_path': 'a.txt', 'previous_path': 'a.txt'},
    ],
    [
      {'action': 'move', 'file_path': 'b.txt', 'previous_path': 'missing.txt'},
    ],
    [
      {
        'action': 'update',
        'file_path': 'missing.txt',
        'edits': [
          {'old': 'alpha', 'new': 'beta'},
        ],
      },
    ],
  ]) {
    test(
      'P10 stale or overlapping actions refuse ${jsonEncode(actions)}',
      () async {
        h = await P10Coordinator.create(s);
        expect(
          await h!.propose('updateSnippetFiles', args: _actions(actions)),
          isNull,
        );
        expect(s.writes, isEmpty);
      },
    );
  }

  for (final pair in [
    ('glpat-ABCDEFGHIJKLMNOPQRST', 'glpat-', 'ABCDEFGHIJKLMNOPQRST'),
    ('[REDACTED]', '[REDA', 'CTED]'),
  ]) {
    test('P10 deletion seam assembling ${pair.$1} is blocked', () async {
      s.contents['a.txt'] = '${pair.$2}REMOVE${pair.$3}\n';
      h = await P10Coordinator.create(s);
      expect(
        await h!.propose(
          'updateSnippet',
          args: {
            ...p10Args('updateSnippet'),
            'edits': [
              {'old': 'REMOVE', 'new': ''},
            ],
          },
        ),
        isNull,
      );
      expect(s.writes, isEmpty);
    });
  }

  for (final markdown in [false, true]) {
    test(
      'P10 Markdown $markdown media and mentions classify without rewriting',
      () async {
        h = await P10Coordinator.create(s, level: AiAutonomyLevel.bypass);
        final content =
            '@all\n![image](https://outside.example/a.png)\n/merge\n';
        final p = await h!.propose(
          'createSnippet',
          args: {
            ...p10Args(
              'createSnippet',
              path: markdown ? 'README.md' : 'code.py',
            ),
            'content': content,
          },
        );
        expect(p, isNotNull);
        expect(
          p!.tier.reasons.contains(AiFixedConfirmReason.massMention),
          markdown,
        );
        expect(
          p.tier.reasons.contains(
            AiFixedConfirmReason.externalMediaInRenderedMarkdown,
          ),
          markdown,
        );
        expect((await h!.coordinator.approve(p)).successful, isTrue);
        expect(s.contents.values.single, content);
      },
    );
  }

  test(
    'P10 existing Markdown exact windows classify mentions and media',
    () async {
      s.record['file_name'] = 'README.md';
      s.record['files'] = [_file('README.md')];
      s.contents
        ..clear()
        ..['README.md'] = 'alpha\n';
      h = await P10Coordinator.create(s, level: AiAutonomyLevel.bypass);
      const replacement =
          '@all\n![shot](https://outside.example/a.png)\n/merge';
      final p = await h!.propose(
        'updateSnippet',
        args: {
          ...p10Args('updateSnippet'),
          'edits': [
            {'old': 'alpha', 'new': replacement},
          ],
        },
      );
      expect(p, isNotNull);
      expect(
        p!.tier.reasons,
        containsAll([
          AiFixedConfirmReason.massMention,
          AiFixedConfirmReason.externalMediaInRenderedMarkdown,
        ]),
      );
      expect((await h!.coordinator.approve(p)).successful, isTrue);
      expect(s.contents['README.md'], '$replacement\n');
    },
  );

  for (final content in [
    'a\u0000b',
    'x' * (2 * 1024 * 1024 + 1),
    '\n' * 20000,
  ]) {
    test(
      'P10 binary or oversized contents are refused (${content.length})',
      () async {
        s.contents['a.txt'] = content;
        h = await P10Coordinator.create(s);
        expect(await h!.propose('updateSnippet'), isNull);
        expect(
          h!.coordinator.outcomeFor('call')!.reasonCode,
          content.contains('\u0000') ? 'snippetBinary' : 'snippetTooLarge',
        );
        expect(s.writes, isEmpty);
      },
    );
  }

  test(
    'P10 bounded actions and whole deletion refuse before content reads',
    () async {
      h = await P10Coordinator.create(s);
      expect(
        await h!.propose(
          'updateSnippetFiles',
          args: _actions([
            _create('b.txt', ''),
            _create('c.txt', ''),
            _create('d.txt', ''),
          ]),
        ),
        isNull,
      );
      expect(
        h!.coordinator.outcomeFor('call')!.reasonCode,
        'snippetTooManyFiles',
      );
      h!.beginRun();
      (s.record['files']! as List).addAll(<Map<String, Object?>>[
        for (final name in ['b', 'c', 'd', 'e']) _file(name),
      ]);
      expect(await h!.propose('deleteSnippet', id: 'delete'), isNull);
      expect(
        h!.coordinator.outcomeFor('delete')!.reasonCode,
        'snippetTooManyFiles',
      );
      expect(
        s.adapter.requests.where((r) => r.uri.path.endsWith('/raw')),
        isEmpty,
      );
    },
  );

  for (final status in [401, 403, 404, 409, 422, 500]) {
    test('P10 mutation $status classification never retries', () async {
      s.mutationStatus = status;
      h = await P10Coordinator.create(s);
      final p = await h!.propose('updateSnippetMetadata');
      final result = await h!.coordinator.approve(p!);
      expect(
        result.state,
        status == 500
            ? AiJournalState.writeUncertain
            : AiJournalState.failedCertain,
      );
      expect(s.writes.length, 1);
    });
  }

  for (final corrupt in [false, true]) {
    test(
      'P10 readback ${corrupt ? 'identity mismatch' : '401'} stays uncertain',
      () async {
        if (corrupt) {
          s.corruptReadback = true;
        } else {
          s.readbackStatus = 401;
        }
        h = await P10Coordinator.create(s);
        final p = await h!.propose('updateSnippet');
        final result = await h!.coordinator.approve(p!);
        expect(result.state, AiJournalState.writeUncertain);
        expect(result.readbackConfirmed, isFalse);
        expect(s.writes.length, 1);
      },
    );
  }

  test('P10 mismatched readback content remains uncertain', () async {
    s.beforeRequest = (r) {
      if (s.mutations > 0 && r.uri.path.endsWith('/raw')) {
        s.contents['a.txt'] = 'unexpected';
      }
    };
    h = await P10Coordinator.create(s);
    final p = await h!.propose('updateSnippet');
    final result = await h!.coordinator.approve(p!);
    expect(result.state, AiJournalState.writeUncertain);
    expect(result.readbackConfirmed, isFalse);
    expect(s.writes.length, 1);
  });

  test('P10 refusal to reserve entire cap happens before traffic', () async {
    h = await P10Coordinator.create(s, budget: 18);
    expect(await h!.propose('createSnippet'), isNull);
    expect(h!.coordinator.outcomeFor('call')!.reasonCode, 'httpBudgetExceeded');
    expect(s.adapter.requests, isEmpty);
  });
}

P10Server _replace(P10Server old, {required Map<String, String> files}) {
  old.close();
  return P10Server(initialContents: files);
}

Map<String, Object?> _file(String path) => {
  'path': path,
  'raw_url':
      'https://example.com/gitlab/team/example-9/-/snippets/12/raw/main/$path',
};

Map<String, Object?> _actions(List<Map<String, Object?>> actions) => {
  'projectId': 9,
  'snippetId': 12,
  'actions': actions,
};

Map<String, Object?> _create(String path, String content) => {
  'action': 'create',
  'file_path': path,
  'content': content,
};
