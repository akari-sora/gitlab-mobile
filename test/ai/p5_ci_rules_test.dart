import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/ci_rules.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/instance.dart';

final _instance = GitLabInstance.parse('https://gitlab.example:8443/install');
const _scope = AiWriteScope(
  accountKey: 'https://gitlab.example:8443/install#7',
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.mergeRequest,
      projectId: 10,
      projectPath: 'team/app',
      iid: 3,
    ),
    AiScopeGrant(
      kind: AiScopeKind.workItem,
      projectId: 10,
      projectPath: 'team/app',
      iid: 4,
    ),
  ],
);

Map<String, dynamic> _path(
  String name, {
  String? old,
  bool added = false,
  bool deleted = false,
}) => {
  'old_path': old ?? name,
  'new_path': name,
  'new_file': added,
  'deleted_file': deleted,
  'renamed_file': old != null,
};

AiMergeChanges _changes(List<Map<String, dynamic>> rows) =>
    collectMergeChanges([rows], changesCount: rows.length, hasMorePages: false);

AiMergeCheck _check({
  AiMergeChanges? changes,
  AiCiConfig? ci,
  List<Map<String, dynamic>>? closes = const [],
  String description = '',
  List<String> messages = const [],
  AiWriteScope scope = _scope,
}) => evaluateMergeCheck(
  changes: changes ?? _changes([_path('lib/main.dart')]),
  ci: ci ?? AiCiConfig.fromProject(const {'ci_config_path': ''}),
  closesIssues: closes,
  description: description,
  commitMessages: messages,
  scope: scope,
  instance: _instance,
);

void main() {
  group('P5 CI path classification', () {
    test('default and all CODEOWNERS locations are CI paths', () {
      final config = AiCiConfig.fromProject(const {'ci_config_path': ''});
      for (final path in [
        '.gitlab-ci.yml',
        '.gitlab/ci/build.yml',
        '.gitlab/CODEOWNERS',
        'CODEOWNERS',
        'docs/CODEOWNERS',
        './.gitlab-ci.yml',
      ]) {
        expect(isCiConfigPath(path, config), isTrue, reason: path);
      }
      for (final path in [
        'lib/main.dart',
        'nested/.gitlab-ci.yml',
        'nested/CODEOWNERS',
        'docs/codeowners',
        '.gitlab-other/build.yml',
      ]) {
        expect(isCiConfigPath(path, config), isFalse, reason: path);
      }
    });

    test(
      'custom local path and external configurations keep default guards',
      () {
        final local = AiCiConfig.fromProject(const {
          'ci_config_path': 'ci/custom.yml',
        });
        expect(local, isA<AiCiConfigLocal>());
        expect(isCiConfigPath('ci/custom.yml', local), isTrue);
      expect(isCiConfigPath('custom.yml', local), isFalse);
      final atSign = AiCiConfig.fromProject(const {
        'ci_config_path': 'ci/custom@v1.yml',
      });
      expect(atSign, isA<AiCiConfigLocal>());
      expect(isCiConfigPath('ci/custom@v1.yml', atSign), isTrue);
        for (final path in [
          'x.yml@group/project',
          'https://ci.example/config.yml',
        ]) {
          final external = AiCiConfig.fromProject({'ci_config_path': path});
          expect(external, isA<AiCiConfigExternal>());
          expect(isCiConfigPath('.gitlab-ci.yml', external), isTrue);
          expect(isCiConfigPath('x.yml', external), isFalse);
        }
      },
    );

    test('present null uses the default path; absent and malformed fail closed', () {
      final defaultConfig = AiCiConfig.fromProject(const {
        'ci_config_path': null,
      });
      expect(defaultConfig, isA<AiCiConfigLocal>());
      expect(isCiConfigPath('.gitlab-ci.yml', defaultConfig), isTrue);
      expect(isCiConfigPath('lib/main.dart', defaultConfig), isFalse);

      for (final project in <Map<String, Object?>>[
        {},
        {'ci_config_path': 9},
        {'ci_config_path': []},
        {'ci_config_path': '../ci.yml'},
        {'ci_config_path': '/ci.yml'},
      ]) {
        final config = AiCiConfig.fromProject(project);
        expect(config, isA<AiCiConfigUnreadable>());
        expect(isCiConfigPath('lib/main.dart', config), isTrue);
      }
      for (final path in ['', '../a', 'a//b', 'a\\b', 'a\n']) {
        expect(
          isCiConfigPath(
            path,
            AiCiConfig.fromProject(const {'ci_config_path': ''}),
          ),
          isTrue,
        );
      }
    });
  });

  group('P5 bounded merge changes', () {
    test('count-checked pages retain rename old path and deletions', () {
      final changes = collectMergeChanges(
        [
          [_path('ci/renamed.yml', old: 'ci/custom.yml')],
          [_path('.gitlab/old.yml', deleted: true)],
        ],
        changesCount: '2',
        hasMorePages: false,
      );
      expect(changes.complete, isTrue);
      expect(changes.paths, hasLength(2));
      expect(
        _check(
          changes: changes,
          ci: AiCiConfig.fromProject(const {
            'ci_config_path': 'ci/custom.yml',
          }),
        ).ciPaths,
        ['.gitlab/old.yml', 'ci/custom.yml'],
      );
      expect(changes.paths.first.deletedFile, isTrue);
      expect(changes.paths.last.renamedFile, isTrue);
      expect(() => changes.paths.clear(), throwsUnsupportedError);
    });

    test('plus, missing, malformed or mismatched counts are incomplete', () {
      for (final count in <Object?>['1+', 0, 2, null, true, 'x', -1, 1.0]) {
        expect(
          collectMergeChanges(
            [
              [_path('a')],
            ],
            changesCount: count,
            hasMorePages: false,
          ).complete,
          isFalse,
          reason: '$count',
        );
      }
      expect(
        collectMergeChanges(
          [
            [_path('a')],
          ],
          changesCount: 1,
          hasMorePages: true,
        ).complete,
        isFalse,
      );
      expect(
        collectMergeChanges([], changesCount: 0, hasMorePages: false).complete,
        isFalse,
      );
      expect(_changes([]).complete, isTrue);
    });

    test('malformed rows and overlapping pages cannot appear complete', () {
      for (final row in [
        <String, dynamic>{},
        {..._path('a'), 'old_path': null},
        {..._path('a'), 'new_file': 'false'},
        _path('../a'),
      ]) {
        expect(_changes([row]).complete, isFalse);
      }
      expect(_changes([_path('a'), _path('a')]).complete, isFalse);
    });

    test(
      'digest binds paths, flags and completeness with stable page order',
      () {
        final first = _changes([_path('a'), _path('b')]);
        final reordered = collectMergeChanges(
          [
            [_path('b')],
            [_path('a')],
          ],
          changesCount: 2,
          hasMorePages: false,
        );
        expect(first.digest, reordered.digest);
        expect(first.digest, isNot(_changes([_path('c'), _path('b')]).digest));
        expect(
          first.digest,
          isNot(_changes([_path('a', deleted: true), _path('b')]).digest),
        );
        expect(
          first.digest,
          isNot(
            collectMergeChanges(
              [
                [_path('a'), _path('b')],
              ],
              changesCount: '2+',
              hasMorePages: false,
            ).digest,
          ),
        );
      },
    );
  });

  group('P5 existing merge effects', () {
    test('server closures validate numeric project and issue scope', () {
      expect(
        _check(
          closes: [
            {'project_id': 10, 'iid': 4},
          ],
        ).closesOutOfScope,
        isFalse,
      );
      for (final issue in [
        {'project_id': 10, 'iid': 5},
        {'project_id': 99, 'iid': 4},
      ]) {
        expect(_check(closes: [issue]).closesOutOfScope, isTrue);
      }
      const project = AiWriteScope(
        accountKey: 'account',
        grants: [
          AiScopeGrant(
            kind: AiScopeKind.project,
            projectId: 10,
            projectPath: 'team/app',
          ),
        ],
      );
      expect(
        _check(
          scope: project,
          closes: [
            {'project_id': 10, 'iid': 55},
          ],
        ).closesOutOfScope,
        isFalse,
      );
    });

    test(
      'description and commit messages reuse closing and reference rules',
      () {
        expect(_check(description: 'Fixes #4').closesOutOfScope, isFalse);
        expect(_check(description: 'Fixes #5').closesOutOfScope, isTrue);
        expect(_check(messages: ['Resolves #5']).closesOutOfScope, isTrue);
        expect(
          _check(description: 'See team/other!2').crossProjectReference,
          isTrue,
        );
        expect(
          _check(messages: ['See team/other#2']).crossProjectReference,
          isTrue,
        );
        expect(
          _check(
            messages: [
              'Fixes https://gitlab.example:8443/install/team/other/-/issues/2',
            ],
          ).crossProjectReference,
          isTrue,
        );
        expect(
          _check(description: 'See team/app!2').crossProjectReference,
          isFalse,
        );
      },
    );

    test('unreadable closure effects never become an empty safe result', () {
      expect(_check(closes: null).closingUnknown, isTrue);
      expect(_check(closes: [{}]).closingUnknown, isTrue);
      expect(
        _check(
          closes: [
            {'project_id': '10', 'iid': 4},
          ],
        ).closingUnknown,
        isTrue,
      );
      expect(
        _check(
          changes: collectMergeChanges(
            [
              [_path('a')],
            ],
            changesCount: '1+',
            hasMorePages: false,
          ),
        ).closingUnknown,
        isTrue,
      );
      expect(_check(description: '[[upload:u-1]]').closingUnknown, isTrue);
      expect(_check().closingUnknown, isFalse);
    });

    test('binding changes with closure set, content, CI or completeness', () {
      final baseline = _check();
      for (final check in [
        _check(
          closes: [
            {'project_id': 10, 'iid': 4},
          ],
        ),
        _check(description: 'updated'),
        _check(messages: ['updated']),
        _check(
          ci: AiCiConfig.fromProject(const {'ci_config_path': 'other.yml'}),
        ),
        _check(ci: const AiCiConfigUnreadable()),
        _check(closes: null),
        _check(changes: _changes([_path('new.dart')])),
      ]) {
        expect(check.digest, isNot(baseline.digest));
      }
      final issues = [
        {'project_id': 10, 'iid': 4},
        {'project_id': 10, 'iid': 5},
      ];
      expect(
        _check(closes: issues).digest,
        _check(closes: issues.reversed.toList()).digest,
      );
    });

    test('journal summary contains only counts and digest', () {
      final result = _check(
        description: 'unique server description',
        messages: ['unique commit message'],
        changes: _changes([_path('.gitlab/private-name.yml')]),
        closes: [
          {'project_id': 10, 'iid': 4},
        ],
      );
      expect(jsonDecode(result.journalSummary), {
        'paths': 1,
        'ciPaths': 1,
        'closesIssues': 1,
        'digest': result.digest,
      });
      expect(result.journalSummary, isNot(contains('unique')));
      expect(result.journalSummary, isNot(contains('private-name')));
      expect(() => result.ciPaths.clear(), throwsUnsupportedError);
    });
  });
}
