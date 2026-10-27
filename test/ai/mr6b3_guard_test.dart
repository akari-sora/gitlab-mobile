import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr6b3_matrix_support.dart';
import 'mr6b3_support.dart';

/// §15 row 13: 「唯讀 port 的既有 GET/HEAD 測試與成員白名單不變，
/// 不為寫入流程放寬。」 「前置讀取與 readback 需要的 GraphQL query
/// 必須是 app 內固定、已審核的唯讀文件（`graphQuery`），不接受模型提供的
/// query、operationName 或任意 variables。」 「任何等級下，每個有副作用的
/// REST mutation 與 `graphMutation` 都恰好對應一筆已核准或依政策自動執行的
/// 提議（一對一、帶相同執行 ID）；固定 GraphQL query 的 POST 計入 HTTP
/// 預算，但不算 mutation，也不能取得 mutation 權限；OAuth token refresh
/// 與資源 mutation 分開計。」
/// §15 row 21: 「測試列舉 `lib/` 中每個寫入呼叫點（畫面上的通用通道呼叫、
/// 具名寫入方法、`graphMutation: true` 呼叫），每一個都必須對應一列 ledger、
/// 「v2 不提供」中的一項，或「待 MR6b-x 交付」清單」；「每個新包裝的固定
/// path 與欄位白名單有負向測試。」
///
/// The real adapter is the assertion boundary. Direct graph-row checks are
/// below, including the three MR6b-3t rows that left the §7t deferral list;
/// the exhaustive inventory remains in its own test file.
/// NOT_RUN §15 row 13: exhaustive non-graph REST mutation and importer checks.
/// Fixed graph documents are checked by operation/variables, without a separate
/// reviewed full-document snapshot or arbitrary-document semantic audit.
/// NOT_RUN §15 row 21: exhaustive lib call-site enumeration, screen migration,
/// and every wrapper's fixed-path/field negative test in this file.

const _fixedReads = <String, Set<String>>{
  'updateWorkItemState': {'MobileWorkItemState'},
  'updateWorkItemStatus': {'MobileWorkItemStatus'},
  'updateWorkItemDates': {
    'MobileWorkItemDatesBase',
    'MobileWorkItemDatesProbe',
  },
  'updateWorkItemHealthStatus': {'MobileWorkItemHealthEdit'},
  'updateWorkItemAssignees': {
    'MobileWorkItemAssignees',
    'MobileProjectAssigneeCandidates',
  },
  'updateWorkItemMilestone': {
    'MobileWorkItemMilestone',
    'MobileProjectWorkItemMilestones',
  },
  'updateWorkItemWeight': {'MobileWorkItemWeight'},
  'createWorkItemActivityComment': {
    'MobileWorkItemActivityWriteAccess',
    'MobileWorkItemActivityNoteReadback',
  },
  'createWorkItemActivityReply': {
    'MobileWorkItemActivity',
    'MobileWorkItemActivityWriteAccess',
    'MobileWorkItemActivityReplyPreflight',
    'MobileWorkItemActivityNoteReadback',
  },
  'deleteWorkItemActivityNote': {
    'MobileWorkItemActivity',
    'MobileWorkItemActivityEditAccess',
    'MobileWorkItemActivityDeleteReadback',
  },
  'setWorkItemActivityNoteReaction': {
    'MobileWorkItemActivity',
    'MobileWorkItemActivityReactionAccess',
  },
  'setWorkItemNotifications': {'MobileWorkItemNotifications'},
  'setIncidentStatus': {'MobileIncidentStatus'},
  'snoozeTodo': {'MobilePendingTodosForSnooze'},
  'unsnoozeTodo': {'MobileSnoozedTodosForUnsnooze'},
};

const _fixedMutations = <String, Set<String>>{
  'updateWorkItemState': {'MobileUpdateWorkItemState'},
  'updateWorkItemStatus': {'MobileUpdateWorkItemStatus'},
  'updateWorkItemDates': {
    'MobileSetWorkItemDatesEe',
    'MobileSetWorkItemDatesCe',
  },
  'updateWorkItemHealthStatus': {'MobileSetWorkItemHealthStatus'},
  'updateWorkItemAssignees': {'MobileSetWorkItemAssignees'},
  'updateWorkItemMilestone': {'MobileSetWorkItemMilestone'},
  'updateWorkItemWeight': {'MobileSetWorkItemWeight'},
  'createWorkItemActivityComment': {'MobileCreateWorkItemActivityNote'},
  'createWorkItemActivityReply': {'MobileCreateWorkItemActivityNote'},
  'deleteWorkItemActivityNote': {'MobileDestroyWorkItemActivityNote'},
  'setWorkItemActivityNoteReaction': {
    'MobileAddWorkItemActivityNoteReaction',
    'MobileRemoveWorkItemActivityNoteReaction',
  },
  'setWorkItemNotifications': {'MobileSetWorkItemNotifications'},
  'setIncidentStatus': {'MobileSetIncidentStatus'},
  'snoozeTodo': {'MobileTodoSnooze'},
  'unsnoozeTodo': {'MobileTodoUnsnooze'},
};

const _graphReadMembers = {
  'projectWorkItem',
  'workItemState',
  'workItemStatus',
  'workItemDates',
  'workItemHealthEdit',
  'workItemAssignees',
  'searchWorkItemAssigneeCandidates',
  'workItemMilestone',
  'workItemMilestoneChoices',
  'workItemWeight',
  'workItemActivityWriteAccess',
  'workItemActivity',
  'workItemActivityNext',
  'workItemDiscussionNotesNext',
  'workItemActivityDeleteAccess',
  'workItemActivityReactionAccess',
  'workItemNotifications',
  'incidentStatus',
  'pendingTodosForSnooze',
  'snoozedTodosForUnsnooze',
};

const _readPortMembers = {
  'textFile',
  'tree',
  'cachedRecord',
  'cachedRecords',
  'record',
  'records',
  'jobTraceChunk',
  'commit',
  'commitDiff',
  'search',
  'snippetText',
};

// Frozen from 574e406: two tokens before and three after every code-only _api.
// Preserve order and duplicates; changing API use requires reviewing this list.
// This list locks local token sequences, not call-site identity.
const _readPortApiOccurrences = <String, List<String>>{
  'GitLabAiReadPort': [
    'this . _api , this .',
    'final GitLabApi _api ; final int',
    ') => _api . record (',
    ') => _api . record (',
    ') => _api . record (',
    ') => _api . snippetText (',
    ') => _api . record (',
    ') => _api . snippetText (',
    ') => _api . textFile (',
    ') => _api . tree (',
    ') => _api . cachedRecord (',
    ') => _api . cachedRecord (',
    ') => _api . cachedRecords (',
    ') => _api . cachedRecords (',
    ') => _api . records (',
    ') => _api . jobTraceChunk (',
    ') => _api . commit (',
    ') => _api . commitDiff (',
    ') => _api . search (',
  ],
  'GitLabAiGroupReadPort': [
    'this . _api , { required',
    'final GitLabApi _api ; final GitLabInstance',
    '= await _api . namespaceWorkItem (',
    'apiOwner : _api , generation :',
  ],
};

const _mainWriteMembers = <String>{
  'addAwardEmoji',
  'createBoard',
  'createBoardList',
  'createDiscussion',
  'createDiscussionNote',
  'createDraftNote',
  'createIssue',
  'createLabel',
  'createMergeRequest',
  'createMilestone',
  'createNote',
  'createTodo',
  'currentUser',
  'instance',
  'markTodoDone',
  'moveBoardCard',
  'moveBoardList',
  'record',
  'records',
  'removeAwardEmoji',
  'renameBoard',
  'setBoardSystemListHidden',
  'setDiscussionResolved',
  'setMilestoneState',
  'setStar',
  'setSubscribed',
  'unapproveMergeRequest',
  'updateDiscussionNote',
  'updateDraftNote',
  'updateIssue',
  'updateLabel',
  'updateMergeRequest',
  'updateMilestone',
  'updateNote',
  'uploadProjectFile',
};

const _nonGraphWriteMembers = <String>{
  'applySuggestion',
  'approveMergeRequest',
  'batchApplySuggestions',
  'cancelAutoMerge',
  'createBranch',
  'createPipeline',
  'createProject',
  'createRelease',
  'createRepositoryFile',
  'createSnippet',
  'createTag',
  'currentUser',
  'deleteBoard',
  'deleteBoardList',
  'deleteBranch',
  'deleteContainerRepository',
  'deleteContainerTag',
  'deleteDiscussionNote',
  'deleteDraftNote',
  'deleteFile',
  'deleteIssue',
  'deleteLabel',
  'deleteMergeRequest',
  'deleteMilestone',
  'deleteNote',
  'deletePackage',
  'deletePackageFile',
  'deletePipeline',
  'deleteProject',
  'deleteRelease',
  'deleteSnippet',
  'deleteSnippetFile',
  'deleteTag',
  'editProject',
  'effectiveProjectAccess',
  'fileMetadata',
  'forkProject',
  'instance',
  'jobAction',
  'markAllTodosDone',
  'mergeRequest',
  'pipelineAction',
  'playPipelineSchedule',
  'publishDraftNotes',
  'rebaseMergeRequest',
  'record',
  'records',
  'snippetText',
  'textFile',
  'updateRelease',
  'updateRepositoryFile',
  'updateSnippet',
  'updateSnippetFiles',
  'updateSnippetMetadata',
};

// Delivered by MR6b-3t (§7t), with their own fixed reads.
const _mr6b3tMethods = {
  'updateWorkItemContent',
  'editWorkItemActivityNote',
  'updateWorkItemLabels',
};

const _mr6b3tReads = {
  'workItemContent',
  'workItemActivityEditAccess',
  'workItemLabels',
  'workItemLabelCandidates',
};

void main() {
  group('§15 row 13 fixed read boundary', () {
    test('read-port member whitelist and graph delta remain exact', () {
      final boundary = File(
        'tool/tests/test_ai_boundaries.py',
      ).readAsStringSync();
      expect(_pythonSet(boundary, 'READ_PORT_MEMBERS'), _readPortMembers);
      final readSource = File(
        'lib/core/ai/tools/gitlab_read_port.dart',
      ).readAsStringSync();
      expect(_readPortViolations(readSource), isEmpty);
      expect(_pythonSet(boundary, 'GROUP_READ_PORT_MEMBERS'), {
        'namespaceWorkItem',
      });
      expect(_graphReadMembers, hasLength(20));
      expect(_fixedReads.keys.toSet(), _fixedMutations.keys.toSet());
      expect(_fixedReads, hasLength(15));
      final graphDelta = {..._graphReadMembers, ..._fixedReads.keys};
      expect(_pythonSet(boundary, '_MR6B3_WRITE_PORT_MEMBERS'), graphDelta);
      final called = <String>{};
      final nonGraphCalled = <String>{};
      final groupCalled = <String>{};
      final mainWrite = File('lib/core/ai/tools/gitlab_write_port.dart');
      final mainCalled = _apiMembers(mainWrite.readAsStringSync());
      final parts = _writePartSources(
        mainWrite.absolute.uri,
        mainWrite.readAsStringSync(),
        (uri) => File.fromUri(uri).readAsStringSync(),
      );
      for (final entry in parts.entries) {
        final name = entry.key.pathSegments.last;
        final source = entry.value;
        final members = _apiMembers(source);
        if (name.startsWith('gitlab_write_port_group_')) {
          groupCalled.addAll(members);
        } else if (name.startsWith('gitlab_write_port_graphql_')) {
          called.addAll(members);
        } else {
          nonGraphCalled.addAll(members);
        }
      }
      expect(mainCalled, _mainWriteMembers);
      expect(nonGraphCalled, _nonGraphWriteMembers);
      expect(groupCalled, isEmpty);
      final allCalled = {
        ...mainCalled,
        ...nonGraphCalled,
        ...called,
        ...groupCalled,
      };
      expect(allCalled, isNot(contains('namespaceWorkItem')));
      expect(
        allCalled.intersection({'graphQuery', 'graphMutation', '_send'}),
        isEmpty,
      );
      expect(_pythonSet(boundary, '_MR6B3T_WRITE_PORT_MEMBERS'), {
        ..._mr6b3tReads,
        ..._mr6b3tMethods,
      });
      expect(called, {
        ...graphDelta,
        ..._mr6b3tReads,
        ..._mr6b3tMethods,
        'instance',
        'currentUser',
      });
      expect(called, isNot(contains('namespaceWorkItem')));
      expect(called, isNot(contains('snoozedTodos')));
      expect(
        called.intersection({'graphQuery', 'graphMutation', '_send'}),
        isEmpty,
      );
    });

    test('read port guard rejects class moves and extra API access', () {
      expect(_readPortViolations(_readPortFixture()), isEmpty);
      expect(
        _readPortViolations(
          _readPortFixture(project: '_api.namespaceWorkItem();').replaceFirst(
            'await _api.namespaceWorkItem(',
            'await other.namespaceWorkItem(',
          ),
        ),
        contains('unexpected GitLabAiReadPort API members'),
      );
      expect(
        _readPortViolations(_readPortFixture(group: '_api.record();')),
        contains('unexpected GitLabAiGroupReadPort API members'),
      );
      expect(
        _readPortViolations(
          _readPortFixture(extra: 'void f() => _api.record();'),
        ),
        contains('API access outside concrete classes'),
      );
      expect(
        _readPortViolations(
          _readPortFixture(extra: 'void f() => helper(_api);'),
        ),
        contains('API access outside concrete classes'),
      );
      expect(
        _readPortViolations(
          _readPortFixture(
            extra: 'final class Foreign { void f() => _api.record(); }',
          ),
        ),
        contains('API access in unknown class Foreign'),
      );
    });

    test('read port guard rejects API escapes in either known class', () {
      const shapes = <String, ({String attack, List<String> rules})>{
        'typed alias': (
          attack: 'void f() { final GitLabApi other = _api; other.record(); }',
          rules: ['invalid _api use', 'invalid GitLabApi use'],
        ),
        'parenthesized receiver': (
          attack: 'void f() { (_api).record(); }',
          rules: ['invalid _api use'],
        ),
        'getter': (
          attack: 'GitLabApi get _g => _api; void f() { _g.record(); }',
          rules: ['invalid _api use', 'invalid GitLabApi use'],
        ),
        'typed helper': (
          attack:
              'static void peek(GitLabApi a) { a.record(); } void f() { peek(_api); }',
          rules: ['invalid _api use', 'invalid GitLabApi use'],
        ),
        'dynamic cast': (
          attack: 'void f() { (_api as dynamic).record(); }',
          rules: ['invalid _api use', 'dynamic cast'],
        ),
        'free dynamic helper': (
          attack: 'void f() { helper(_api); }',
          rules: ['invalid _api use'],
        ),
        'typed parameter only': (
          attack: 'void f(GitLabApi other) {}',
          rules: ['invalid GitLabApi use'],
        ),
        'typed getter only': (
          attack: 'GitLabApi get other => someValue;',
          rules: ['invalid GitLabApi use'],
        ),
        'typed local only': (
          attack: 'void f() { GitLabApi other = someValue; }',
          rules: ['invalid GitLabApi use'],
        ),
        'local shadows field': (
          attack: 'void f() { final GitLabApi _api; }',
          rules: ['invalid _api use', 'invalid GitLabApi use'],
        ),
        'constructor call in method': (
          attack: 'void f() { GitLabAiGroupReadPort(this._api, 1); }',
          rules: ['invalid _api use'],
        ),
        'constructor call in initializer': (
          attack: 'final other = GitLabAiGroupReadPort(this._api, 1);',
          rules: ['invalid _api use'],
        ),
        'dynamic cast only': (
          attack: 'void f(Object value) { value as dynamic; }',
          rules: ['dynamic cast'],
        ),
      };
      for (final shape in shapes.entries) {
        for (final target in ['project', 'group']) {
          final source = _readPortFixture(
            project: target == 'project' ? shape.value.attack : '',
            group: target == 'group' ? shape.value.attack : '',
            extra: 'void helper(a) { a.record(); }',
          );
          final name = target == 'project'
              ? 'GitLabAiReadPort'
              : 'GitLabAiGroupReadPort';
          final violations = _readPortViolations(source);
          for (final rule in shape.value.rules) {
            expect(
              violations,
              contains('$rule in $name'),
              reason: '${shape.key} in $target class',
            );
          }
        }
      }
      for (final target in ['GitLabAiReadPort', 'GitLabAiGroupReadPort']) {
        for (final constructor in [
          '$target(this._api);',
          '$target.named(this._api);',
          '$target(Object other, this._api);',
          '$target({required this._api});',
        ]) {
          // Keep the formal-parameter rule's positive coverage; adding any API
          // occurrence now also requires editing the frozen snapshot.
          expect(
            _knownReadClassViolations(
              target,
              'class $target { final GitLabApi _api; $constructor }',
              target == 'GitLabAiReadPort'
                  ? _readPortMembers
                  : {'namespaceWorkItem'},
            ),
            isEmpty,
            reason: constructor,
          );
          expect(
            _readPortViolations(
              _readPortFixture(
                project: target == 'GitLabAiReadPort'
                    ? 'final GitLabApi _api; $constructor'
                    : '',
                group: target == 'GitLabAiGroupReadPort'
                    ? 'final GitLabApi _api; $constructor'
                    : '',
              ),
            ),
            contains('unexpected $target API occurrence snapshot'),
            reason: constructor,
          );
        }
      }
    });

    test('API owner exception belongs only to the group evidence factory', () {
      const factory = 'VerifiedGroupWorkItemIdentity.fromServerEvidence';
      expect(_readPortViolations(_readPortFixture()), isEmpty);
      expect(
        _knownReadClassViolations(
          'GitLabAiGroupReadPort',
          'class GitLabAiGroupReadPort { void workItem() async { $factory(apiOwner: _api, generation: 1); } }',
          {'namespaceWorkItem'},
        ),
        isEmpty,
      );
      for (final invalid in [
        'void f() { helper(apiOwner: _api); }',
        'void f() { $factory(apiOwner: _api); }',
        'void workItem() async { $factory(other: helper(apiOwner: _api)); }',
        'void workItem() async { $factory(apiOwner: _api, apiOwner: _api); }',
        'void workItem() async { $factory(apiOwner: _api); helper(apiOwner: _api); }',
      ]) {
        // Isolate malformed factories: appending workItem to the real source
        // also rejects its original owner argument due to duplicate methods.
        expect(
          _knownReadClassViolations(
            'GitLabAiGroupReadPort',
            'class GitLabAiGroupReadPort { final GitLabApi _api; $invalid }',
            {'namespaceWorkItem'},
          ),
          contains('invalid _api use in GitLabAiGroupReadPort'),
          reason: invalid,
        );
        expect(
          _readPortViolations(_readPortFixture(group: invalid)),
          contains('invalid _api use in GitLabAiGroupReadPort'),
          reason: invalid,
        );
      }
    });

    test('read port guard examines string interpolation code', () {
      expect(
        _readPortViolations(
          _readPortFixture(
            group: r'''void f() { print('${helper(_api)}'); }''',
          ),
        ),
        contains('invalid _api use in GitLabAiGroupReadPort'),
      );
      expect(
        _readPortViolations(
          _readPortFixture(group: r'''void f() { print('$_api'); }'''),
        ),
        contains('invalid _api use in GitLabAiGroupReadPort'),
      );
      expect(
        _readPortViolations(
          _readPortFixture(group: r'''void f() { print(r'$_api'); }'''),
        ),
        isEmpty,
      );
    });

    test('read port line comments end at CR or LF in real source', () {
      const attack =
          "  Future<Object?> escaped() => _api.writeRecord('POST', const ['projects'], const {});";
      for (final ending in ['\r', '\r\n', '\n']) {
        for (final comment in ['//', '///']) {
          for (final addition in [
            '  $comment bait$ending$attack\n',
            "  String escaped() => '\${$comment bait$ending"
                "_api.writeRecord('POST', const ['projects'], const {})}';\n",
          ]) {
            final source = _readPortFixture(project: addition);
            final code = _codeOnly(source);
            expect(code.length, source.length);
            expect(
              '\r'.allMatches(code).length,
              '\r'.allMatches(source).length,
            );
            final violations = _readPortViolations(source);
            expect(
              violations,
              contains('invalid _api use in GitLabAiReadPort'),
              reason: addition,
            );
            expect(
              violations,
              contains('unexpected GitLabAiReadPort API occurrence snapshot'),
              reason: addition,
            );
          }
        }
      }
    });

    test('read port CR stays inside literals and nested block comments', () {
      const bait = 'before\r_api.writeRecord dynamic apiOwner\r\nafter';
      for (final quote in ["'''", '"""']) {
        for (final prefix in ['', 'r']) {
          final addition = 'String bait() => $prefix$quote$bait$quote;';
          expect(
            _readPortViolations(_readPortFixture(project: addition)),
            isEmpty,
            reason: addition,
          );
        }
      }
      for (final addition in [
        '/* outer\r /* _api.writeRecord */\r\n dynamic apiOwner */',
        "String bait() => r'''before\r\${_api.writeRecord()}\r\nafter''';",
        "String bait() => '''before\\'''\r_api.writeRecord\r\nafter''';",
      ]) {
        expect(
          _readPortViolations(_readPortFixture(project: addition)),
          isEmpty,
          reason: addition,
        );
      }
    });

    test('read port ignores top-level comment and raw string API bait', () {
      for (final addition in [
        '// _api.namespaceWorkItem',
        "const bait = r'_api.namespaceWorkItem';",
      ]) {
        expect(
          _readPortViolations(_readPortFixture(extra: addition)),
          isEmpty,
          reason: addition,
        );
      }
    });

    test('read port rejects Opus smuggling with normal member sets', () {
      const ns =
          "namespaceWorkItem('a/b', 1, expectedNamespaceId: 'gid://gitlab/Group/1', strictIdentity: true)";
      const shapes = <String, ({String target, String attack})>{
        'G1': (target: 'group', attack: 'void f() { _api..$ns..group(7); }'),
        'G2': (
          target: 'group',
          attack: 'Future<Object?> f() => (_api..$ns).group(7);',
        ),
        'G3': (
          target: 'group',
          attack:
              'Future<Object?> f() async { final (api, _) = (_api..$ns, 0); return api.group(7); }',
        ),
        'G4': (
          target: 'group',
          attack:
              'late final _leaked = (_api..$ns); Future<Object?> f() => _leaked.group(7);',
        ),
        'G5': (
          target: 'group',
          attack:
              'late final _getter = () => _api..$ns; Future<Object?> f() => _getter().group(7);',
        ),
        'G6': (
          target: 'group',
          attack:
              'Future<Object?> f() async { final dynamic owner = _verifiedIdentity?.apiOwner; return owner?.currentUser(); }',
        ),
        'P1': (
          target: 'project',
          attack:
              "void f() { _api..record(const ['x'])..writeRecord('POST', const ['projects'], const {}); }",
        ),
        'P2': (
          target: 'project',
          attack:
              "Future<Object?> f() => (_api..record).writeRecord('POST', const ['projects'], const {});",
        ),
        'P3': (
          target: 'project',
          attack: 'void f() => _leakHelper(_api..record);',
        ),
      };
      for (final entry in shapes.entries) {
        final shape = entry.value;
        final source = _readPortFixture(
          project: shape.target == 'project' ? shape.attack : '',
          group: shape.target == 'group' ? shape.attack : '',
          extra: entry.key == 'P3'
              ? "void _leakHelper(dynamic api) => api.writeRecord('POST', const ['projects'], const {});"
              : '',
        );
        final violations = _readPortViolations(source);
        expect(_apiMembers(_codeOnly(source)), {
          ..._readPortMembers,
          'namespaceWorkItem',
        }, reason: entry.key);
        expect(
          violations.where(
            (value) =>
                value.contains('API members') || value.contains('API union'),
          ),
          isEmpty,
          reason: entry.key,
        );
        if (entry.key == 'G6') {
          expect(violations, contains('dynamic keyword in read port'));
          expect(
            violations,
            contains('unexpected apiOwner occurrence in read port'),
          );
          expect(
            violations.where((value) => value.contains('snapshot')),
            isEmpty,
          );
        } else {
          final name = shape.target == 'project'
              ? 'GitLabAiReadPort'
              : 'GitLabAiGroupReadPort';
          expect(
            violations,
            contains('unexpected $name API occurrence snapshot'),
            reason: entry.key,
          );
          expect(violations, contains('API cascade in read port'));
        }
      }
    });

    test(
      'read port snapshots reject extra missing reordered or changed use',
      () {
        final source = _readPortFixture();
        for (final mutant in [
          _readPortFixture(project: "void f() => _api.record(const ['x']);"),
          source.replaceFirst(
            'await _api.namespaceWorkItem(',
            'await other.namespaceWorkItem(',
          ),
          source.replaceFirst(
            '_api.commit(projectId, sha)',
            '_api.commit.call(projectId, sha)',
          ),
          source
              .replaceFirst(
                '_api.commit(projectId, sha)',
                '_api.search(projectId, sha)',
              )
              .replaceFirst(
                '_api.search(scope, query,',
                '_api.commit(scope, query,',
              ),
        ]) {
          expect(
            _readPortViolations(
              mutant,
            ).where((value) => value.contains('snapshot')),
            isNotEmpty,
          );
        }
      },
    );

    test('read port bans cascades dynamic and API owner reads file wide', () {
      const shapes = <String, String>{
        'void f() => _api?..record();': 'API cascade in read port',
        'typedef X = dynamic;': 'dynamic keyword in read port',
        'List<dynamic> values = [];': 'dynamic keyword in read port',
        'void f(dynamic value) {}': 'dynamic keyword in read port',
        'Object? f(Object value) => value.apiOwner;':
            'unexpected apiOwner occurrence in read port',
        'Object? f(Object? value) => value?.apiOwner;':
            'unexpected apiOwner occurrence in read port',
        'void f({Object? apiOwner}) {}':
            'unexpected apiOwner occurrence in read port',
      };
      for (final entry in shapes.entries) {
        expect(
          _readPortViolations(_readPortFixture(extra: entry.key)),
          contains(entry.value),
          reason: entry.key,
        );
      }
      expect(
        _readPortViolations(
          _readPortFixture(
            group:
                "// _api..record(); dynamic apiOwner\n"
                "/* typedef X = dynamic; */ r'_api?..record(); dynamic .apiOwner';",
          ),
        ),
        isEmpty,
      );
    });

    test('group scope construction and producer aliases are restricted', () {
      final violations = <String>[];
      for (final file in Directory(
        'lib',
      ).listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        violations.addAll(
          _groupScopeConstructionViolations(
            file.path,
            file.readAsStringSync(),
          ).map((message) => '${file.path}: $message'),
        );
      }
      expect(violations, isEmpty);
      const construct = 'AiGroupResourceScope(accountKey: key)';
      const other = 'lib/features/ai/ai_chat_controller.dart';
      for (final allowed in [
        'lib/core/ai/tools/tool_scope.dart',
        'lib/features/ai/ai_chat_context.dart',
        'test/ai/group_scope_test.dart',
      ]) {
        expect(_groupScopeConstructionViolations(allowed, construct), isEmpty);
      }
      for (final mutant in [
        construct,
        'const AiGroupResourceScope(accountKey: key)',
        'final create = AiGroupResourceScope.new;',
        'factory Alias() = AiGroupResourceScope;',
        'final create = scopes.AiGroupResourceScope.new;',
        r"'${AiGroupResourceScope(accountKey: key)}'",
      ]) {
        expect(_groupScopeConstructionViolations(other, mutant), isNotEmpty);
      }
      expect(
        _groupScopeConstructionViolations(
          'lib/core/ai/tools/gitlab_read_port.dart',
          construct,
        ),
        isNotEmpty,
      );
      for (final producer in [
        'lib/core/ai/tools/tool_scope.dart',
        'lib/features/ai/ai_chat_context.dart',
        other,
      ]) {
        for (final alias in [
          'typedef S = AiGroupResourceScope;',
          'typedef S = scopes.AiGroupResourceScope;',
        ]) {
          expect(
            _groupScopeConstructionViolations(producer, alias),
            isNotEmpty,
          );
        }
        expect(
          _groupScopeConstructionViolations(
            producer,
            "AiGroupResourceScope? scope; // typedef S = AiGroupResourceScope;\n"
            "'no typedef S = AiGroupResourceScope; AiGroupResourceScope()';",
          ),
          isEmpty,
        );
      }
    });

    test('write part discovery follows URIs outside tools and validates part of', () {
      final main = Uri.file('/fixture/ai/tools/gitlab_write_port.dart');
      final external = main.resolve('../outside.dart');
      final unreferenced = main.resolve('../unreferenced.dart');
      final files = <Uri, String>{
        external:
            "part of 'tools/gitlab_write_port.dart'; void f() => _api.graphMutation();",
        unreferenced:
            "part of 'tools/gitlab_write_port.dart'; void f() => _api.record();",
      };
      final parts = _writePartSources(
        main,
        "// part '../unreferenced.dart';\npart /* nested /* comment */ */ '../outside.dart';",
        (uri) => files[uri]!,
      );
      expect(parts.keys, [external]);
      expect(_apiMembers(parts[external]!), contains('graphMutation'));
      expect(
        () => _writePartSources(
          main,
          "part '../outside.dart';",
          (_) => "part of 'wrong.dart';",
        ),
        throwsStateError,
      );
      expect(
        () => _writePartSources(
          main,
          "part '../outside.dart';",
          (_) => 'void f() {}',
        ),
        throwsStateError,
      );
      for (final source in [
        "part of 'wrong.dart';",
        'part notAUri;',
        "void f() { part '../outside.dart'; }",
        "part 'gitlab_write_port.dart';",
        "part '../outside.dart'; part '../outside.dart';",
      ]) {
        expect(
          () => _writePartSources(main, source, (uri) => files[uri]!),
          throwsStateError,
          reason: source,
        );
      }
      expect(
        () => _writePartSources(
          main,
          "part '../outside.dart';",
          (_) => "part of 'tools/gitlab_write_port.dart'; part 'nested.dart';",
        ),
        throwsStateError,
      );
      expect(
        _writePartSources(
          main,
          "part '../outside.dart';",
          (_) => "part /* a */ of /* b */ 'tools/gitlab_write_port.dart';",
        ).keys,
        [external],
      );
    });

    for (final operation in _fixedReads.keys) {
      test(
        '$operation rejects model documents, names and variables before HTTP',
        () async {
          final h = await _harness();
          for (final entry in <String, Object?>{
            'query': 'mutation P15Injected { todoMarkAllDone { errors } }',
            'operationName': 'P15Injected',
            'variables': {
              'input': {'id': 'gid://gitlab/WorkItem/999'},
            },
          }.entries) {
            await expectLater(
              h.server.writePort.prepare(
                port.AiWriteRequest(
                  operationId: operation,
                  executionId: 'tampered-$operation-${entry.key}',
                  scope: mr6b3Scope,
                  arguments: {
                    ...mr6b3ApiArguments(operation),
                    entry.key: entry.value,
                  },
                ),
              ),
              throwsA(
                isA<ApiFailure>().having(
                  (e) => e.kind,
                  'kind',
                  FailureKind.validation,
                ),
              ),
            );
          }
          expect(h.server.adapter.requests, isEmpty);
          expect(h.server.mutations, 0);
          expect(h.journal.entries(mr6b3Account), isEmpty);
        },
      );

      test(
        '$operation fixed-query POSTs alone cannot obtain mutation rights',
        () async {
          final h = await _harness();
          final prepared = await h.server.writePort.prepare(
            port.AiWriteRequest(
              operationId: operation,
              executionId: 'read-only-$operation',
              scope: mr6b3Scope,
              arguments: mr6b3ApiArguments(operation),
            ),
          );
          expect(prepared.boundary, AiWriteBoundary.graph);
          expect(h.server.logicalReads, greaterThan(0));
          expect(h.server.mutations, 0);
          expect(
            h.server.adapter.requests.any((r) => r.method == 'POST'),
            isTrue,
          );
          final requests = h.server.adapter.requests.length;
          final noApproval = await h.server.writePort.commit(
            prepared,
            mayStart: () =>
                fail('the absent journal boundary must refuse first'),
          );
          expect(
            noApproval,
            isA<port.AiWriteNotSent>().having(
              (e) => e.reasonCode,
              'reason',
              'graphBoundaryUnavailable',
            ),
          );
          expect(h.server.adapter.requests, hasLength(requests));
          expect(h.server.mutations, 0);
          expect(h.journal.entries(mr6b3Account), isEmpty);
        },
      );
    }

    for (final field in ['query', 'operationName', 'variables']) {
      test('coordinator refuses $field before reserving or reading', () async {
        final h = await _harness();
        final proposal = await h.propose(
          'updateWorkItemState',
          id: 'model-$field',
          arguments: {
            field: field == 'variables' ? <String, Object?>{} : 'P15Injected',
          },
        );
        expect(proposal, isNull);
        expect(
          h.coordinator.outcomeFor('model-$field')?.reasonCode,
          'invalidArguments',
        );
        expect(h.budget.gitLabRequests, 0);
        expect(h.server.adapter.requests, isEmpty);
        expect(h.server.mutations, 0);
        expect(h.journal.entries(mr6b3Account), isEmpty);
      });
    }

    test(
      'fixed-query OAuth replays use HTTP budget; token refresh is separate',
      () async {
        final h = await Mr6b3ApiHarness.create(oauth: true);
        addTearDown(h.dispose);
        final proposal = (await h.propose('updateWorkItemState'))!;
        // The shared allowance reserves every read, replay, mutation and readback.
        expect(h.budget.gitLabRequests, 21);
        expect(h.server.logicalReads, 4);
        expect(h.server.refreshes, 4);
        expect(h.server.adapter.requests, hasLength(8));
        expect(h.server.refreshAdapter.requests, hasLength(4));
        expect(
          h.server.adapter.requests.where((r) => r.method == 'POST'),
          hasLength(4),
        );
        expect(h.server.mutations, 0);
        expect(h.journal.entries(mr6b3Account), isEmpty);
        final outcome = await h.approve(proposal);
        expect(outcome.state, AiJournalState.succeeded);
        expect(outcome.mutationCount, 1);
        expect(h.server.logicalReads, 10);
        expect(h.server.refreshes, 10);
        expect(h.server.adapter.requests, hasLength(21));
        expect(h.server.refreshAdapter.requests, hasLength(10));
        expect(h.budget.gitLabRequests, 21);
        expect(
          h.server.adapter.requests.where(
            (r) => r.uri.path.endsWith('/oauth/token'),
          ),
          isEmpty,
        );
        expect(
          h.server.refreshAdapter.requests.every(
            (r) => r.uri.path.endsWith('/oauth/token'),
          ),
          isTrue,
        );
        expect(h.journal.entries(mr6b3Account), hasLength(1));
      },
    );
  });

  group('§15 row 13 one proposal and execution id per graph mutation', () {
    for (final operation in _fixedReads.keys) {
      for (final automatic in [false, true]) {
        test(
          '$operation ${automatic ? 'policy-auto' : 'approved'} is one-to-one at adapter',
          () async {
            final h = await _harness();
            h.policy.level = automatic
                ? AiAutonomyLevel.bypass
                : AiAutonomyLevel.confirmEach;
            h.coordinator.beginRun('Update team/example-9#3 and note:401.');
            h.coordinator.beginTurn();
            final call = AiToolCall(
              id: 'guard-$operation',
              name: operation,
              arguments: {
                ...mr6b3ApiArguments(operation),
                'reason': 'synthetic guard request',
              },
            );
            final proposal = (await h.coordinator.propose(call))!;
            expect(
              proposal.tier.decision,
              automatic
                  ? AiGateDecision.execute
                  : AiGateDecision.requireApproval,
            );
            expect(h.server.mutations, 0);
            expect(h.journal.entries(mr6b3Account), isEmpty);
            expect(h.budget.gitLabRequests, greaterThan(0));
            var observed = 0;
            h.server.onRequest = (name, mutation, request, payload) {
              if (mutation) {
                observed++;
                expect(_fixedMutations[operation], contains(name));
                expect(h.coordinator.proposalFor(call.id), same(proposal));
                expect(
                  h.coordinator.executionIdFor(call.id),
                  proposal.executionId,
                );
                expect(proposal.valid, isTrue);
                final entry = h.journal.entries(mr6b3Account).single;
                expect(entry.executionId, proposal.executionId);
                expect(entry.operationId, operation);
                expect(entry.payloadSha256, proposal.payloadDigest);
                expect(entry.state, AiJournalState.dispatching);
                expect(
                  h.journal.isolated(mr6b3Account, entry.writeKeys),
                  isTrue,
                );
                expect(h.coordinator.outcomeFor(call.id), isNull);
              }
              return null;
            };
            final outcome = automatic
                ? await h.coordinator.execute(call).timeout(mr6b3Timeout)
                : await h.approve(proposal);
            expect(
              outcome.state,
              AiJournalState.succeeded,
              reason: outcome.reasonCode,
            );
            expect(outcome.executionId, proposal.executionId);
            expect(outcome.operationId, operation);
            expect(outcome.mutationCount, 1);
            expect(observed, 1);
            expect(h.server.mutations, 1);
            expect(h.journal.entries(mr6b3Account), hasLength(1));
            _expectFixedDocuments(h, operation);
            final requests = h.server.adapter.requests.length;
            expect(await h.approve(proposal), same(outcome));
            expect(h.server.adapter.requests, hasLength(requests));
            expect(observed, 1);
          },
        );
      }
    }
  });

  group('§15 row 21 P14 inventory cross-check and §7t delivery', () {
    test(
      'all eighteen graph rows are delivered and visible; none is deferred',
      () {
        final graphRows = ProductionAiLedger.rows
            .where((r) => r.boundary == AiWriteBoundary.graph)
            .toList();
        expect(graphRows.map((r) => r.operationId).toSet(), {
          ..._fixedReads.keys,
          ..._mr6b3tMethods,
        });
        expect(graphRows, hasLength(18));
        for (final row in graphRows) {
          expect(row.namedMethod, row.operationId);
          expect(row.modelVisible, isTrue);
        }
      },
    );
  });
}

Future<Mr6b3ApiHarness> _harness() async {
  final h = await Mr6b3ApiHarness.create(oauth: false);
  addTearDown(h.dispose);
  return h;
}

Set<String> _pythonSet(String source, String name) {
  final match = RegExp(
    '${RegExp.escape(name)} = \\{([^}]+)\\}',
  ).firstMatch(source);
  expect(match, isNotNull, reason: name);
  return RegExp(
    '"([A-Za-z0-9_]+)"',
  ).allMatches(match!.group(1)!).map((m) => m.group(1)!).toSet();
}

Set<String> _apiMembers(String source) {
  final receivers = <String>{'_api'};
  final aliases = RegExp(r'\b(?:final|var)\s+(\w+)\s*=\s*(\w+)\b');
  var changed = true;
  while (changed) {
    changed = false;
    for (final match in aliases.allMatches(source)) {
      if (receivers.contains(match.group(2)) &&
          receivers.add(match.group(1)!)) {
        changed = true;
      }
    }
  }
  return {
    for (final receiver in receivers)
      for (final match in RegExp(
        '\\b${RegExp.escape(receiver)}(?:\\.\\.|\\.)(\\w+)\\b',
      ).allMatches(source))
        match.group(1)!,
  };
}

// Resolve only parts actually declared by the main library, including paths
// outside tools/, and reject a part that belongs to a different library.
Map<Uri, String> _writePartSources(
  Uri main,
  String mainSource,
  String Function(Uri) readPart,
) {
  List<({bool isPartOf, String uri})> directives(String source) {
    final code = _codeOnly(source);
    final result = <({bool isPartOf, String uri})>[];
    int trivia(int offset) {
      while (offset < source.length) {
        if (RegExp(r'\s').hasMatch(source[offset])) {
          offset++;
        } else if (source.startsWith('//', offset)) {
          final newline = source.indexOf('\n', offset + 2);
          offset = newline < 0 ? source.length : newline + 1;
        } else if (source.startsWith('/*', offset)) {
          var depth = 1;
          offset += 2;
          while (offset < source.length && depth > 0) {
            if (source.startsWith('/*', offset)) {
              depth++;
              offset += 2;
            } else if (source.startsWith('*/', offset)) {
              depth--;
              offset += 2;
            } else {
              offset++;
            }
          }
          if (depth != 0) throw StateError('unterminated comment');
        } else {
          break;
        }
      }
      return offset;
    }

    for (final token in RegExp(r'\bpart\b').allMatches(code)) {
      var offset = trivia(token.end);
      final looksLikeDirective =
          RegExp(r'^of\b').hasMatch(code.substring(offset)) ||
          (offset < source.length &&
              (source[offset] == "'" || source[offset] == '"'));
      if (_nestingDepthAt(code, token.start) != 0) {
        if (looksLikeDirective) throw StateError('nested part directive');
        continue;
      }
      var isPartOf = false;
      if (RegExp(r'^of\b').hasMatch(code.substring(offset))) {
        isPartOf = true;
        offset = trivia(offset + 2);
      }
      if (offset >= source.length ||
          (source[offset] != "'" && source[offset] != '"')) {
        throw StateError('unrecognized part directive');
      }
      final quote = source[offset++];
      final end = source.indexOf(quote, offset);
      if (end < 0) throw StateError('unterminated part URI');
      final uri = source.substring(offset, end);
      if (uri.isEmpty || uri.contains(r'\') || uri.contains(r'$')) {
        throw StateError('unsupported part URI');
      }
      offset = trivia(end + 1);
      if (offset >= code.length || code[offset] != ';') {
        throw StateError('unrecognized part directive');
      }
      result.add((isPartOf: isPartOf, uri: uri));
    }
    return result;
  }

  Uri resolve(Uri base, String value) {
    final relative = Uri.parse(value);
    if (relative.isAbsolute ||
        relative.hasAuthority ||
        relative.path.startsWith('/') ||
        relative.hasQuery ||
        relative.hasFragment) {
      throw StateError('part URI must be relative: $value');
    }
    return base.resolveUri(relative).normalizePath();
  }

  final result = <Uri, String>{};
  for (final directive in directives(mainSource)) {
    if (directive.isPartOf) throw StateError('main library declares part of');
    final uri = resolve(main, directive.uri);
    if (result.containsKey(uri) || uri == main) {
      throw StateError('duplicate or self-referencing part: $uri');
    }
    final source = readPart(uri);
    final owners = directives(source);
    if (owners.length != 1 ||
        !owners.single.isPartOf ||
        resolve(uri, owners.single.uri) != main) {
      throw StateError('part does not belong to $main: $uri');
    }
    result[uri] = source;
  }
  return result;
}

// Preserve source offsets while hiding comments and literal text; Dart
// interpolation is executable code and must remain visible to the guard.
String _codeOnly(String source) {
  final result = source.split('');
  void hide(int index) {
    if (source[index] != '\r' && source[index] != '\n') result[index] = ' ';
  }

  late int Function(int, {bool interpolation}) codeAt;
  int stringAt(int i) {
    final quote = source[i];
    final triple = source.startsWith(quote * 3, i);
    final delimiter = triple ? quote * 3 : quote;
    final raw = i > 0 && source[i - 1] == 'r';
    for (var j = 0; j < delimiter.length; j++) {
      hide(i++);
    }
    while (i < source.length) {
      if (source.startsWith(delimiter, i)) {
        for (var j = 0; j < delimiter.length; j++) {
          hide(i++);
        }
        return i;
      }
      if (!raw && source.startsWith(r'${', i)) {
        hide(i++);
        hide(i++);
        i = codeAt(i, interpolation: true);
        continue;
      }
      if (!raw &&
          source[i] == r'$' &&
          i + 1 < source.length &&
          RegExp(r'[A-Za-z_]').hasMatch(source[i + 1])) {
        hide(i++);
        while (i < source.length &&
            RegExp(r'[A-Za-z0-9_]').hasMatch(source[i])) {
          i++;
        }
        continue;
      }
      if (!raw && source[i] == r'\' && i + 1 < source.length) {
        hide(i++);
        hide(i++);
      } else {
        hide(i++);
      }
    }
    return i;
  }

  codeAt = (int i, {bool interpolation = false}) {
    var braces = 0;
    while (i < source.length) {
      if (source.startsWith('//', i)) {
        while (i < source.length && source[i] != '\r' && source[i] != '\n') {
          hide(i++);
        }
      } else if (source.startsWith('/*', i)) {
        var depth = 0;
        do {
          if (source.startsWith('/*', i)) {
            hide(i++);
            hide(i++);
            depth++;
          } else if (source.startsWith('*/', i)) {
            hide(i++);
            hide(i++);
            depth--;
          } else {
            hide(i++);
          }
        } while (i < source.length && depth > 0);
      } else if (source[i] == "'" || source[i] == '"') {
        i = stringAt(i);
      } else if (interpolation && source[i] == '}' && braces == 0) {
        hide(i++);
        return i;
      } else {
        if (interpolation && source[i] == '{') braces++;
        if (interpolation && source[i] == '}') braces--;
        i++;
      }
    }
    return i;
  };
  codeAt(0);
  return result.join();
}

int _braceDepthAt(String code, int end) {
  var depth = 0;
  for (var i = 0; i < end; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}') depth--;
  }
  return depth;
}

int _nestingDepthAt(String code, int end) {
  var depth = 0;
  for (var i = 0; i < end; i++) {
    if ('({['.contains(code[i])) depth++;
    if (')}]'.contains(code[i])) depth--;
  }
  return depth;
}

// Find the contents of a balanced delimiter, splitting only top-level commas.
({int end, List<({int start, int end})> arguments})? _delimited(
  String code,
  int open,
) {
  const pairs = {'(': ')', '[': ']', '{': '}'};
  final first = pairs[code[open]];
  if (first == null) return null;
  final stack = <String>[first];
  final arguments = <({int start, int end})>[];
  var start = open + 1;
  for (var i = start; i < code.length; i++) {
    final char = code[i];
    final close = pairs[char];
    if (close != null) {
      stack.add(close);
    } else if (char == ')' || char == ']' || char == '}') {
      if (stack.isEmpty || stack.removeLast() != char) return null;
      if (stack.isEmpty) {
        arguments.add((start: start, end: i));
        return (end: i + 1, arguments: arguments);
      }
    } else if (char == ',' && stack.length == 1) {
      arguments.add((start: start, end: i));
      start = i + 1;
    }
  }
  return null;
}

Set<int> _groupOwnerApiOffsets(String code) {
  final methods = RegExp(r'\bworkItem\s*\(').allMatches(code).toList();
  if (methods.length != 1) return {};
  final parameters = _delimited(code, methods.single.end - 1);
  if (parameters == null) return {};
  final bodyStart = RegExp(
    r'^\s*async\s*\{',
  ).firstMatch(code.substring(parameters.end));
  if (bodyStart == null) return {};
  final open = parameters.end + bodyStart.end - 1;
  final body = _delimited(code, open);
  if (body == null) return {};
  final methodBody = code.substring(open + 1, body.end - 1);
  final factories = RegExp(
    r'\bVerifiedGroupWorkItemIdentity\s*\.\s*fromServerEvidence\s*\(',
  ).allMatches(methodBody).toList();
  if (factories.length != 1) return {};
  final factoryOpen = open + 1 + factories.single.end - 1;
  final factory = _delimited(code, factoryOpen);
  if (factory == null || factory.end > body.end) return {};
  final owners = <int>[];
  for (final argument in factory.arguments) {
    final text = code.substring(argument.start, argument.end);
    final match = RegExp(r'^\s*apiOwner\s*:\s*(_api)\s*$').firstMatch(text);
    if (match != null) {
      owners.add(
        argument.start + match.start + match.group(0)!.indexOf('_api'),
      );
    }
  }
  return owners.length == 1 ? owners.toSet() : {};
}

List<String> _knownReadClassViolations(
  String name,
  String code,
  Set<String> allowed,
) {
  final violations = <String>[];
  final fieldApi = <int>{};
  final fieldType = <int>{};
  for (final match in RegExp(
    r'\bfinal\s+GitLabApi\s+_api\s*;',
  ).allMatches(code)) {
    if (_braceDepthAt(code, match.start) != 1) continue;
    fieldApi.add(match.start + match.group(0)!.indexOf('_api'));
    fieldType.add(match.start + match.group(0)!.indexOf('GitLabApi'));
  }
  final constructorApi = <int>{};
  for (final match in RegExp(
    '\\b${RegExp.escape(name)}(?:\\s*\\.\\s*\\w+)?\\s*\\(',
  ).allMatches(code)) {
    if (_braceDepthAt(code, match.start) != 1) continue;
    final before = code.substring(0, match.start);
    final boundary = [
      before.lastIndexOf('{'),
      before.lastIndexOf('}'),
      before.lastIndexOf(';'),
    ].reduce((left, right) => left > right ? left : right);
    final prefix = before.substring(boundary + 1);
    if (!RegExp(r'^\s*(?:(?:const|external|factory)\s+)*$').hasMatch(prefix)) {
      continue;
    }
    final open = match.end - 1;
    final parameters = _delimited(code, open);
    if (parameters == null) continue;
    final text = code.substring(open, parameters.end);
    for (final parameter in RegExp(
      r'(?:^|[({,\[])\s*(?:required\s+)?this\s*\.\s*(_api)\s*(?=[,}\])])',
    ).allMatches(text)) {
      final offset = parameter.start + parameter.group(0)!.indexOf('_api');
      final beforeParameter = text.substring(1, offset);
      int count(String char) => char.allMatches(beforeParameter).length;
      if (count('(') != count(')') ||
          count('{') - count('}') + count('[') - count(']') > 1) {
        continue;
      }
      constructorApi.add(open + offset);
    }
  }
  final ownerApi = name == 'GitLabAiGroupReadPort'
      ? _groupOwnerApiOffsets(code)
      : <int>{};
  for (final token in RegExp(r'\b_api\b').allMatches(code)) {
    final suffix = RegExp(
      r'^(?:\.\.|\.)(\w+)\b',
    ).firstMatch(code.substring(token.end));
    if (!fieldApi.contains(token.start) &&
        !constructorApi.contains(token.start) &&
        !ownerApi.contains(token.start) &&
        (suffix == null || !allowed.contains(suffix.group(1)))) {
      violations.add('invalid _api use in $name');
    }
  }
  for (final token in RegExp(r'\bGitLabApi\b').allMatches(code)) {
    final staticLimit =
        name == 'GitLabAiReadPort' &&
        RegExp(r'^\.maxTextBytes\b').hasMatch(code.substring(token.end));
    if (!fieldType.contains(token.start) && !staticLimit) {
      violations.add('invalid GitLabApi use in $name');
    }
  }
  if (RegExp(r'\bas\s+dynamic\b').hasMatch(code)) {
    violations.add('dynamic cast in $name');
  }
  return violations;
}

List<String> _readPortViolations(String source) {
  final code = _codeOnly(source);
  final classes = <({String name, int start, int end})>[];
  for (final match in RegExp(r'\bclass\s+(\w+)[^{]*\{').allMatches(code)) {
    var depth = 1;
    var end = match.end;
    while (end < code.length && depth > 0) {
      if (code[end] == '{') depth++;
      if (code[end] == '}') depth--;
      end++;
    }
    if (depth != 0) return ['unterminated class'];
    classes.add((name: match.group(1)!, start: match.start, end: end));
  }
  final expected = <String, Set<String>>{
    'GitLabAiReadPort': _readPortMembers,
    'GitLabAiGroupReadPort': {'namespaceWorkItem'},
  };
  final violations = <String>[];
  if (RegExp(r'\b_api\s*\??\s*\.\.').hasMatch(code)) {
    violations.add('API cascade in read port');
  }
  if (RegExp(r'\bdynamic\b').hasMatch(code)) {
    violations.add('dynamic keyword in read port');
  }
  final ownerOffsets = <int>{};
  for (final entry in expected.entries) {
    final matches = classes.where((item) => item.name == entry.key).toList();
    if (matches.length != 1) {
      violations.add('expected one ${entry.key}');
      continue;
    }
    final item = matches.single;
    final classCode = code.substring(item.start, item.end);
    final actual = _apiMembers(classCode);
    if (actual.length != entry.value.length ||
        !actual.containsAll(entry.value)) {
      violations.add('unexpected ${entry.key} API members');
    }
    if (_apiOccurrences(classCode).join('\n') !=
        _readPortApiOccurrences[entry.key]!.join('\n')) {
      violations.add('unexpected ${entry.key} API occurrence snapshot');
    }
    violations.addAll(
      _knownReadClassViolations(entry.key, classCode, entry.value),
    );
    if (entry.key == 'GitLabAiGroupReadPort') {
      ownerOffsets.addAll(
        _groupOwnerApiOffsets(classCode).map((offset) => item.start + offset),
      );
    }
  }
  for (final token in RegExp(r'\bapiOwner\b').allMatches(code)) {
    final argument = RegExp(
      r'^apiOwner\s*:\s*(_api)\b',
    ).firstMatch(code.substring(token.start));
    if (argument == null ||
        !ownerOffsets.contains(
          token.start + argument.group(0)!.indexOf('_api'),
        )) {
      violations.add('unexpected apiOwner occurrence in read port');
    }
  }
  for (final item in classes.where(
    (item) => !expected.containsKey(item.name),
  )) {
    if (_apiMembers(code.substring(item.start, item.end)).isNotEmpty ||
        RegExp(
          r'\b(?:GitLabApi|_api)\b',
        ).hasMatch(code.substring(item.start, item.end))) {
      violations.add('API access in unknown class ${item.name}');
    }
  }
  final outside = code.split('');
  for (final item in classes) {
    for (var i = item.start; i < item.end; i++) {
      outside[i] = ' ';
    }
  }
  final outsideSource = outside.join();
  if (_apiMembers(outsideSource).isNotEmpty ||
      RegExp(r'\b(?:GitLabApi|_api)\b').hasMatch(outsideSource)) {
    violations.add('API access outside concrete classes');
  }
  final all = _apiMembers(code);
  final wanted = {..._readPortMembers, 'namespaceWorkItem'};
  if (all.length != wanted.length || !all.containsAll(wanted)) {
    violations.add('unexpected read-port API union');
  }
  return violations;
}

List<String> _apiOccurrences(String code) {
  final tokens = RegExp(
    r'[A-Za-z_$][A-Za-z0-9_$]*|\?\.\.|\.\.|\?\.|=>|[^\s]',
  ).allMatches(code).map((match) => match.group(0)!).toList();
  return [
    for (var index = 0; index < tokens.length; index++)
      if (tokens[index] == '_api')
        tokens
            .skip(index < 2 ? 0 : index - 2)
            .take(index < 2 ? index + 4 : 6)
            .join(' '),
  ];
}

String _readPortFixture({
  String project = '',
  String group = '',
  String extra = '',
}) {
  var source = File(
    'lib/core/ai/tools/gitlab_read_port.dart',
  ).readAsStringSync();
  for (final entry in {
    '  final int projectId;\n': project,
    '  VerifiedGroupWorkItemIdentity? _verifiedIdentity;\n': group,
  }.entries) {
    if (entry.key.allMatches(source).length != 1) {
      throw StateError('read-port fixture marker changed: ${entry.key}');
    }
    source = source.replaceFirst(entry.key, '${entry.key}${entry.value}\n');
  }
  return '$source\n$extra';
}

List<String> _groupScopeConstructionViolations(String relative, String source) {
  if (!relative.startsWith('lib/')) return [];
  final code = _codeOnly(source);
  if (RegExp(r'\btypedef\b[^;]*\bAiGroupResourceScope\b').hasMatch(code)) {
    return ['group scope typedef alias is forbidden even in its producers'];
  }
  if ({
    'lib/core/ai/tools/tool_scope.dart',
    'lib/features/ai/ai_chat_context.dart',
  }.contains(relative)) {
    return [];
  }
  if (RegExp(r'\bAiGroupResourceScope\s*(?:\(|\.)').hasMatch(code) ||
      RegExp(r'=\s*(?:\w+\s*\.\s*)?AiGroupResourceScope\b').hasMatch(code)) {
    return ['group scope constructed or aliased outside its producers'];
  }
  return [];
}

void _expectFixedDocuments(Mr6b3ApiHarness h, String operation) {
  final allowedReads = {
    ..._fixedReads[operation]!,
    if (operation != 'snoozeTodo' && operation != 'unsnoozeTodo')
      'MobileProjectWorkItem',
  };
  final documents = <String, String>{};
  var reads = 0;
  var mutations = 0;
  for (final request in h.server.adapter.requests) {
    if (request.method != 'POST') continue;
    expect(request.uri, h.server.api.instance.graphQL);
    final data = request.data as Map;
    expect(data.keys.toSet(), {'query', 'variables'});
    final document = data['query'] as String;
    final declaration = RegExp(
      r'^(query|mutation)\s+(\w+)',
    ).firstMatch(document)!;
    final name = declaration.group(2)!;
    if (declaration.group(1) == 'query') {
      reads++;
      expect(allowedReads, contains(name), reason: operation);
    } else {
      mutations++;
      expect(_fixedMutations[operation], contains(name));
    }
    final opening = document.substring(0, document.indexOf('{'));
    final variables = RegExp(
      r'\$(\w+)\s*:',
    ).allMatches(opening).map((m) => m.group(1)!).toSet();
    expect(
      (data['variables'] as Map).keys.toSet().difference(variables),
      isEmpty,
    );
    final previous = documents[name];
    if (previous != null) {
      expect(document, previous, reason: '$name must stay fixed across reads');
    }
    documents[name] = document;
  }
  expect(reads, greaterThan(0));
  expect(mutations, 1);
  expect(
    h.server.adapter.requests.length,
    lessThanOrEqualTo(h.budget.gitLabRequests),
  );
}
