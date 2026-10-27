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
      for (final file in Directory(
        'lib/core/ai/tools',
      ).listSync(recursive: true).whereType<File>()) {
        if (file.path == mainWrite.path || !file.path.endsWith('.dart')) {
          continue;
        }
        final source = file.readAsStringSync();
        if (!RegExp(
          r'''\bpart\s+of\s+['"](?:[^'"]*/)?gitlab_write_port\.dart['"]\s*;''',
        ).hasMatch(source)) {
          continue;
        }
        final name = file.path.split('/').last;
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
      final project = _readPortMembers.map((name) => '_api.$name();').join();
      const group = '_api.namespaceWorkItem();';
      String fixture(
        String projectBody,
        String groupBody, [
        String extra = '',
      ]) =>
          'final class GitLabAiReadPort { $projectBody }\n'
          'final class GitLabAiGroupReadPort { $groupBody }\n$extra';
      expect(_readPortViolations(fixture(project, group)), isEmpty);
      expect(_readPortViolations(fixture('$project $group', '')), isNotEmpty);
      expect(
        _readPortViolations(fixture(project, '$group _api.record();')),
        isNotEmpty,
      );
      expect(
        _readPortViolations(
          fixture(project, group, 'void f() => _api.record();'),
        ),
        isNotEmpty,
      );
      expect(
        _readPortViolations(
          fixture(project, group, 'void f() => helper(_api);'),
        ),
        isNotEmpty,
      );
      expect(
        _readPortViolations(
          fixture(
            project,
            group,
            'final class Foreign { void f() => _api.record(); }',
          ),
        ),
        isNotEmpty,
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

// Preserve source offsets while hiding braces in comments and Dart strings.
String _codeOnly(String source) {
  final result = source.split('');
  var i = 0;
  void hide(int index) {
    if (source[index] != '\n') result[index] = ' ';
  }

  while (i < source.length) {
    if (source.startsWith('//', i)) {
      while (i < source.length && source[i] != '\n') {
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
          break;
        }
        if (!raw && source[i] == r'\' && i + 1 < source.length) {
          hide(i++);
          hide(i++);
        } else {
          hide(i++);
        }
      }
    } else {
      i++;
    }
  }
  return result.join();
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
  for (final entry in expected.entries) {
    final matches = classes.where((item) => item.name == entry.key).toList();
    if (matches.length != 1) {
      violations.add('expected one ${entry.key}');
      continue;
    }
    final item = matches.single;
    final actual = _apiMembers(source.substring(item.start, item.end));
    if (actual.length != entry.value.length ||
        !actual.containsAll(entry.value)) {
      violations.add('unexpected ${entry.key} API members');
    }
  }
  for (final item in classes.where(
    (item) => !expected.containsKey(item.name),
  )) {
    if (_apiMembers(source.substring(item.start, item.end)).isNotEmpty ||
        RegExp(
          r'\b(?:GitLabApi|_api)\b',
        ).hasMatch(code.substring(item.start, item.end))) {
      violations.add('API access in unknown class ${item.name}');
    }
  }
  final outside = source.split('');
  for (final item in classes) {
    for (var i = item.start; i < item.end; i++) {
      outside[i] = ' ';
    }
  }
  final outsideSource = outside.join();
  if (_apiMembers(outsideSource).isNotEmpty ||
      RegExp(r'\b(?:GitLabApi|_api)\b').hasMatch(_codeOnly(outsideSource))) {
    violations.add('API access outside concrete classes');
  }
  final all = _apiMembers(source);
  final wanted = {..._readPortMembers, 'namespaceWorkItem'};
  if (all.length != wanted.length || !all.containsAll(wanted)) {
    violations.add('unexpected read-port API union');
  }
  return violations;
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
