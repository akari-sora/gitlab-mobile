import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart';
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';

const account = 'https://example.com/gitlab#7';
final head = 'a' * 40;
const scope = AiWriteScope(
  accountKey: account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 9,
      projectPath: 'team/app',
    ),
  ],
);

final class Server {
  Server() {
    adapter = FakeAdapter(respond);
    port = GitLabAiWritePort(api, accountKey: account);
  }
  late final FakeAdapter adapter;
  // Keep the client inferred; tests never expose credentials or real transport.
  late final api = testApi(adapter);
  late final GitLabAiWritePort port;
  String sha = head;
  Object? config = '';
  String target = 'feature-target';
  String description = '';
  bool protected = false;
  bool auto = true;
  bool foreignSource = false;
  bool omitAuto = false;
  bool canMerge = false;
  String mrState = 'opened';
  String baseSha = 'b' * 40;
  int compareStatus = 200;
  int status = 200;
  int readbackStatus = 200;
  int listStatus = 200;
  String? badList;
  String cancelStatus = 'success';
  String? resultState;
  bool sent = false;
  bool mutateDrafts = true;
  bool draftMore = false;
  bool commitsMore = false;
  bool closesMore = false;
  bool diffMore = false;
  bool twoDiffPages = false;
  Object? changesCount = '1';
  List<Map<String, dynamic>> diffs = [change('lib/a.dart')];
  List<Map<String, dynamic>> closes = [];
  List<Map<String, dynamic>> drafts = [
    {'id': 8, 'note': 'review text'},
  ];
  final commitMessages = <String>['change'];
  Map<String, Object?> mr() => {
    'id': 33,
    'project_id': 9,
    'iid': 3,
    'state': mrState,
    'sha': sha,
    'source_project_id': foreignSource ? 10 : 9,
    'target_project_id': 9,
    'source_branch': 'topic/a',
    'target_branch': target,
    'description': description,
    'changes_count': changesCount,
    'diff_refs': {'head_sha': sha, 'base_sha': baseSha, 'start_sha': 'c' * 40},
    if (!omitAuto) 'auto_merge_enabled': auto,
    'author': {'id': 5},
    'user': {'can_merge': canMerge},
  };
  ResponseBody respond(RequestOptions r) {
    final path = r.uri.path;
    if (r.method != 'GET') {
      sent = true;
      if (status >= 300) return jsonResponse({}, status: status);
      if (path.endsWith('bulk_publish')) {
        if (mutateDrafts) drafts = [];
        return jsonResponse(null, status: 204);
      }
      if (r.method == 'DELETE') {
        if (mutateDrafts) drafts = [];
        return jsonResponse(null, status: 204);
      }
      if (path.endsWith('cancel_merge_when_pipeline_succeeds')) {
        return jsonResponse({
          'status': cancelStatus,
          'message': 'glpat-ABCDEFGHIJKLMNOPQRST',
        }, status: 201);
      }
      return jsonResponse({
        ...mr(),
        if (resultState != null) 'state': resultState,
      });
    }
    if (path.endsWith('/user')) {
      return jsonResponse({'id': 7, 'username': 'tester'});
    }
    if (path.endsWith('/projects/9')) {
      return jsonResponse({
        ...projectJson(9),
        'path_with_namespace': 'team/app',
        'ci_config_path': config,
      });
    }
    if (path.endsWith('/merge_requests/3')) {
      return jsonResponse(mr(), status: sent ? readbackStatus : 200);
    }
    if (path.contains('/repository/branches/')) {
      return jsonResponse({'name': target, 'protected': protected});
    }
    if (path.endsWith('/compare')) {
      return jsonResponse({
        'commits': [
          {'id': sha},
        ],
        'compare_timeout': false,
      }, status: compareStatus);
    }
    if (badList != null && path.endsWith('/$badList')) {
      return jsonResponse({}, status: listStatus);
    }
    if (path.endsWith('/diffs')) {
      final page = r.uri.queryParameters['page'];
      return jsonResponse(
        twoDiffPages
            ? (page != '2' ? [diffs.first] : diffs.skip(1).toList())
            : diffs,
        headers: diffMore || (twoDiffPages && page != '2')
            ? {
                'x-next-page': [page == '2' ? '3' : '2'],
              }
            : {},
      );
    }
    if (path.endsWith('/commits')) {
      return jsonResponse(
        [
          for (var i = 0; i < commitMessages.length; i++)
            {'id': '${i + 1}'.padLeft(40, 'd'), 'message': commitMessages[i]},
        ],
        headers: commitsMore
            ? {
                'x-next-page': ['2'],
              }
            : {},
      );
    }
    if (path.endsWith('/closes_issues')) {
      return jsonResponse(
        closes,
        headers: closesMore
            ? {
                'x-next-page': ['2'],
              }
            : {},
      );
    }
    if (path.endsWith('/draft_notes/8')) return jsonResponse(drafts.first);
    if (path.endsWith('/draft_notes')) {
      return jsonResponse(
        drafts,
        headers: draftMore
            ? {
                'x-next-page': ['2'],
              }
            : {},
      );
    }
    return jsonResponse({}, status: 404);
  }

  AiWriteRequest request(
    String op, {
    String execution = 'one',
    Map<String, Object?> args = const {},
    Set<AiCreatedRef> created = const {},
  }) => AiWriteRequest(
    operationId: op,
    executionId: execution,
    scope: scope,
    arguments: {'projectId': 9, 'iid': 3, ...args},
    segmentCreated: created,
  );
  Future<AiWritePrepared> prepare(
    String op, {
    String execution = 'one',
    Map<String, Object?> args = const {},
    Set<AiCreatedRef> created = const {},
  }) => port.prepare(
    request(op, execution: execution, args: args, created: created),
  );
  Future<AiWriteSettled> commit(AiWritePrepared p) async =>
      await port.commit(p, mayStart: () => true) as AiWriteSettled;
  List<RequestOptions> get writes =>
      adapter.requests.where((r) => r.method != 'GET').toList();
  void close() => api.close();
}

Map<String, dynamic> change(String path, {String? old, bool deleted = false}) =>
    {
      'old_path': old ?? path,
      'new_path': path,
      'new_file': false,
      'deleted_file': deleted,
      'renamed_file': old != null,
    };

Matcher reason(String code) =>
    isA<AiJournalException>().having((e) => e.reason, 'reason', code);

AiTierDecision tier(
  AiWritePrepared p, {
  AiAutonomyLevel level = AiAutonomyLevel.conversationGrant,
  bool bound = true,
}) => decideTier(
  AiTierInput(
    level: level,
    capability: productionAiLedger.find(p.request.operationId)!,
    scope: scope,
    binding: AiBindingResult(
      userMessage: '',
      allBound: bound,
      intentAuthorizesLowRisk: true,
    ),
    target: p.bindingTargets.single,
    facts: p.facts,
    typedName: p.confirmName,
    arguments: p.request.arguments,
  ),
);

void main() {
  late Server s;
  setUp(() => s = Server());
  tearDown(() => s.close());

  test(
    'six ledger rows stay hidden, closed arguments and independent caps',
    () {
      const expected = {
        'mergeRequest': 37,
        'approveMergeRequest': 23,
        'rebaseMergeRequest': 19,
        'cancelAutoMerge': 20,
        'publishDraftNotes': 23,
        'deleteDraftNote': 23,
      };
      expect(
        aiMergeRows.map((r) => r.operationId).toSet(),
        expected.keys.toSet(),
      );
      for (final row in aiMergeRows) {
        expect(row.modelVisible, false);
        expect(row.httpCap, expected[row.operationId]);
        expect(row.readback, true);
        expect(row.namedMethod, row.operationId);
        expect(row.arguments.containsKey('sha'), false);
        expect(row.arguments.containsKey('skipCi'), false);
      }
    },
  );
  test(
    'merge binds three components and uses separate typed and release names',
    () async {
      s.target = 'main';
      final p = await s.prepare(
        'mergeRequest',
        args: {'autoMerge': true, 'squash': true},
      );
      expect(p.releaseName, '!3');
      expect(p.confirmName, 'main');
      expect(tier(p).tier, AiWriteTier.t4);
      expect((p.preview as AiMergePreview).squash, true);
      expect((p.preview as AiMergePreview).autoMerge, true);
      expect(
        p.writeKeys.map((k) => k.parts),
        contains(equals([account, 'project:9', 'ref', 'main'])),
      );
      expect(p.bindingTargets.single.sourceRef, 'topic/a');
      final missing = bindTargets(
        userMessage: '!3',
        restoredFromHistory: false,
        scope: scope,
        targets: p.bindingTargets,
        interfaceLanguage: 'en',
        deviceLanguages: [],
      );
      expect(missing.allBound, false);
      final bound = bindTargets(
        userMessage: '!3 `topic/a` `main`',
        restoredFromHistory: false,
        scope: scope,
        targets: p.bindingTargets,
        interfaceLanguage: 'en',
        deviceLanguages: [],
      );
      expect(bound.allBound, true);
    },
  );
  test(
    'squash does not raise T3; removing source raises T4 and locks source',
    () async {
      final squash = await s.prepare('mergeRequest', args: {'squash': true});
      expect(tier(squash).tier, AiWriteTier.t3);
      final remove = await s.prepare(
        'mergeRequest',
        execution: 'two',
        args: {'removeSourceBranch': true},
      );
      expect(tier(remove).tier, AiWriteTier.t4);
      expect(
        remove.writeKeys.map((k) => k.parts),
        contains(equals([account, 'project:9', 'ref', 'topic/a'])),
      );
    },
  );
  for (final path in [
    '.gitlab-ci.yml',
    '.gitlab/a.yml',
    'CODEOWNERS',
    'docs/CODEOWNERS',
    '.gitlab/CODEOWNERS',
  ]) {
    test(
      'existing CI $path forces typed hard line at bypass without model text',
      () async {
        s.diffs = [change('lib/a.dart', old: path)];
        final p = await s.prepare('mergeRequest');
        expect(
          tier(p, level: AiAutonomyLevel.bypass).tier,
          AiWriteTier.hardLine,
        );
        expect(
          tier(p, level: AiAutonomyLevel.bypass).decision,
          AiGateDecision.requireApproval,
        );
        expect(p.confirmName, path);
        expect((p.preview as AiMergePreview).ciPaths, contains(path));
        expect(p.journal.mergeCheckSummary, isNot(contains(path)));
      },
    );
  }
  for (final deleted in [false, true]) {
    test('custom CI rename/delete is hard line ($deleted)', () async {
      s.config = 'ci/custom.yml';
      s.diffs = [
        change(
          deleted ? 'ci/custom.yml' : 'ci/new.yml',
          old: deleted ? null : 'ci/custom.yml',
          deleted: deleted,
        ),
      ];
      final p = await s.prepare('mergeRequest');
      expect(p.facts.touchesCiConfig, true);
      expect(p.confirmName, 'ci/custom.yml');
    });
  }
  for (final count in ['1+', '2', null, -1]) {
    test('incomplete changes count $count refuses without mutation', () async {
      s.changesCount = count;
      await expectLater(
        s.prepare('mergeRequest'),
        throwsA(reason('mergeCheckIncomplete')),
      );
      expect(s.writes, isEmpty);
    });
  }
  test(
    'diffs limited to two pages and all bounded lists reject pagination',
    () async {
      s.diffMore = true;
      await expectLater(
        s.prepare('mergeRequest'),
        throwsA(reason('mergeCheckIncomplete')),
      );
      expect(
        s.adapter.requests.where((r) => r.uri.path.endsWith('/diffs')),
        hasLength(2),
      );
      s.diffMore = false;
      s.commitsMore = true;
      await expectLater(
        s.prepare('mergeRequest'),
        throwsA(reason('mergeCheckIncomplete')),
      );
      s.commitsMore = false;
      s.closesMore = true;
      await expectLater(
        s.prepare('mergeRequest'),
        throwsA(reason('mergeCheckIncomplete')),
      );
    },
  );
  for (final status in [403, 404, 500]) {
    test('unreadable merge effects $status never become empty', () async {
      s.badList = 'closes_issues';
      s.listStatus = status;
      await expectLater(
        s.prepare('mergeRequest'),
        throwsA(
          reason(
            status == 404 ? 'mergeCheckUnsupported' : 'mergeCheckIncomplete',
          ),
        ),
      );
      expect(s.writes, isEmpty);
    });
  }
  test(
    'foreign closure and commit reference require confirmation even at bypass',
    () async {
      s.closes = [
        {'project_id': 10, 'iid': 5},
      ];
      final p = await s.prepare('mergeRequest');
      expect(
        tier(p, level: AiAutonomyLevel.bypass).decision,
        AiGateDecision.requireApproval,
      );
      expect(
        (p.preview as AiMergePreview).closingIssues.single.outOfScope,
        true,
      );
      s.closes = [];
      s.commitMessages[0] = 'Refer other/project#5';
      final q = await s.prepare('mergeRequest', execution: 'two');
      expect(
        q.facts.reasons,
        contains(AiFixedConfirmReason.foreignClosingOrCrossProject),
      );
    },
  );
  test(
    'dispatch reuses pinned diffs and commits but rereads closures and protection',
    () async {
      final request = s.request('mergeRequest');
      final p = await s.port.prepare(request);
      final q = await s.port.prepare(request);
      expect(p.bindingDigest, q.bindingDigest);
      expect(
        s.adapter.requests.where((r) => r.uri.path.endsWith('/diffs')),
        hasLength(1),
      );
      expect(
        s.adapter.requests.where((r) => r.uri.path.endsWith('/commits')),
        hasLength(1),
      );
      expect(
        s.adapter.requests.where((r) => r.uri.path.endsWith('/closes_issues')),
        hasLength(2),
      );
      expect(
        s.adapter.requests.where((r) => r.uri.path.contains('/branches/')),
        hasLength(2),
      );
    },
  );
  for (final changed in [
    'head',
    'closing',
    'config',
    'protection',
    'description',
  ]) {
    test('approval binding invalidates changed $changed', () async {
      await s.prepare('mergeRequest');
      switch (changed) {
        case 'head':
          s.sha = 'e' * 40;
        case 'closing':
          s.closes = [
            {'project_id': 9, 'iid': 7},
          ];
        case 'config':
          s.config = 'ci/other.yml';
        case 'protection':
          s.protected = true;
        case 'description':
          s.description = 'changed';
      }
      await expectLater(
        s.prepare('mergeRequest'),
        throwsA(reason('headMoved')),
      );
      expect(s.writes, isEmpty);
    });
  }
  for (final status in [405, 406, 409, 422]) {
    for (final op in [
      'mergeRequest',
      'approveMergeRequest',
      'rebaseMergeRequest',
      'cancelAutoMerge',
    ]) {
      test('$op mutation $status is certain with exactly one write', () async {
        s.status = status;
        final result = await s.commit(await s.prepare(op));
        expect(result.state, AiJournalState.failedCertain);
        expect(result.httpStatus, status);
        expect(s.writes, hasLength(1));
      });
    }
  }
  test(
    '409 persists per MR in the conversation and compares old and new SHA',
    () async {
      s.status = 409;
      final p = await s.prepare('approveMergeRequest');
      expect((s.writes), isEmpty);
      await s.commit(p);
      s.sha = 'e' * 40;
      final q = await s.prepare('mergeRequest', execution: 'new');
      expect(
        q.facts.reasons,
        contains(AiFixedConfirmReason.headMovedSincePreview),
      );
      expect((q.preview as AiMergePreview).headMovedCommits, [s.sha]);
      final compare = s.adapter.requests.singleWhere(
        (r) => r.uri.path.endsWith('/compare'),
      );
      expect(compare.uri.queryParameters['from'], head);
      expect(compare.uri.queryParameters['to'], s.sha);
    },
  );
  for (final mode in ['merged', 'scheduled', 'accepted']) {
    test('merge result $mode has distinct safe projection', () async {
      s.resultState = mode == 'merged' ? 'merged' : 'opened';
      final p = await s.prepare(
        'mergeRequest',
        args: {'autoMerge': mode == 'scheduled'},
      );
      final result = await s.commit(p);
      expect(
        result.resultCode,
        {
          'merged': 'merged',
          'scheduled': 'autoMergeScheduled',
          'accepted': 'mergeAccepted',
        }[mode],
      );
      final body = s.writes.single.data as Map;
      expect(body['sha'], head);
      expect(result.projection, isEmpty);
    });
  }
  test(
    'rebase never exposes skipCi; approve passes the pre-read SHA',
    () async {
      await s.commit(await s.prepare('rebaseMergeRequest'));
      expect(s.writes.single.data, isEmpty);
      s.sent = false;
      await s.commit(await s.prepare('approveMergeRequest', execution: 'two'));
      expect((s.writes.last.data as Map)['sha'], head);
      await expectLater(
        s.prepare('rebaseMergeRequest', args: {'skipCi': true}),
        throwsA(isA<Exception>()),
      );
    },
  );
  test('cancel precheck and advisory permissions use server data', () async {
    final p = await s.prepare('cancelAutoMerge');
    expect((p.preview as AiCancelAutoMergePreview).mayLackPermission, true);
    s.auto = false;
    await expectLater(
      s.prepare('cancelAutoMerge', execution: 'two'),
      throwsA(reason('autoMergeNotEnabled')),
    );
  });
  test('cancel 409 does not claim the source SHA moved', () async {
    s.status = 409;
    final result = await s.commit(await s.prepare('cancelAutoMerge'));
    expect(result.state, AiJournalState.failedCertain);
    expect(result.resultCode, 'conflict');
  });
  for (final mode in [
    'success',
    'stillOn',
    'readbackFailed',
    'error',
    'unknown',
    'missingFlags',
    '404',
  ]) {
    test('cancel result $mode never leaks server message or retries', () async {
      final p = await s.prepare('cancelAutoMerge');
      if (mode == 'success') s.auto = false;
      if (mode == 'readbackFailed') s.readbackStatus = 401;
      if (mode == 'error') s.cancelStatus = 'error';
      if (mode == 'unknown') s.cancelStatus = 'unexpected';
      if (mode == 'missingFlags') s.omitAuto = true;
      if (mode == '404') s.status = 404;
      final result = await s.commit(p);
      expect(
        result.state,
        mode == 'success'
            ? AiJournalState.succeeded
            : ['error', '404'].contains(mode)
            ? AiJournalState.failedCertain
            : AiJournalState.writeUncertain,
      );
      if (mode == 'error') expect(result.resultCode, 'autoMergeCancelError');
      if (mode == '404') expect(result.resultCode, 'cancelEndpointUnavailable');
      expect(result.projection.toString(), isNot(contains('glpat-')));
      expect(s.writes, hasLength(1));
    });
  }
  test(
    'drafts snapshot body, head, in-segment provenance and class-A scan',
    () async {
      final p = await s.prepare('publishDraftNotes');
      expect(
        p.facts.reasons,
        contains(AiFixedConfirmReason.foreignDraftsInPublish),
      );
      expect(p.textScan!.serverClassA, ['review text']);
      expect(
        (p.preview as AiDraftPublishPreview).drafts.single.createdInSegment,
        false,
      );
      final q = await s.prepare(
        'publishDraftNotes',
        execution: 'two',
        created: {
          AiCreatedRef(
            accountKey: account,
            kind: AiTargetKind.note,
            projectId: 9,
            id: 8,
            parentIid: 3,
          ),
        },
      );
      expect(q.facts.reasons, isEmpty);
      s.drafts.single['note'] = 'changed';
      await expectLater(
        s.prepare('publishDraftNotes'),
        throwsA(reason('draftsChanged')),
      );
      expect(s.writes, isEmpty);
    },
  );
  test('draft cap and pagination fail closed', () async {
    s.drafts = [
      for (var i = 1; i <= 21; i++) {'id': i, 'note': 'text'},
    ];
    await expectLater(
      s.prepare('publishDraftNotes'),
      throwsA(reason('batchTooLarge')),
    );
    s.drafts = [
      {'id': 8, 'note': 'text'},
    ];
    s.draftMore = true;
    await expectLater(
      s.prepare('publishDraftNotes'),
      throwsA(reason('mergeCheckIncomplete')),
    );
  });
  for (final op in ['deleteDraftNote', 'publishDraftNotes']) {
    test('$op confirms removal by independent draft readback', () async {
      final p = await s.prepare(
        op,
        args: op == 'deleteDraftNote' ? {'noteId': 8} : {},
      );
      if (op == 'deleteDraftNote') expect(p.confirmName, '!3');
      expect((await s.commit(p)).state, AiJournalState.succeeded);
    });
    test('$op unchanged readback is uncertain', () async {
      s.mutateDrafts = false;
      final p = await s.prepare(
        op,
        args: op == 'deleteDraftNote' ? {'noteId': 8} : {},
      );
      expect((await s.commit(p)).state, AiJournalState.writeUncertain);
    });
  }
  test(
    'draft deletion binds complete body and position before dispatch',
    () async {
      await s.prepare('deleteDraftNote', args: {'noteId': 8});
      s.drafts.single['position'] = {'head_sha': 'e' * 40};
      await expectLater(
        s.prepare('deleteDraftNote', args: {'noteId': 8}),
        throwsA(reason('draftsChanged')),
      );
    },
  );
  for (final op in [
    'mergeRequest',
    'approveMergeRequest',
    'rebaseMergeRequest',
    'cancelAutoMerge',
    'publishDraftNotes',
    'deleteDraftNote',
  ]) {
    test('$op independently counted worst-case request cap', () async {
      final a = op == 'deleteDraftNote'
          ? <String, Object?>{'noteId': 8}
          : <String, Object?>{};
      if (op == 'mergeRequest') {
        s.twoDiffPages = true;
        s.diffs = [change('lib/a.dart'), change('lib/b.dart')];
        s.changesCount = '2';
      }
      if (op == 'mergeRequest' || op == 'approveMergeRequest') {
        s.status = 409;
        await s.commit(
          await s.prepare('approveMergeRequest', execution: 'conflict'),
        );
        s.adapter.requests.clear();
        s.status = 200;
        s.sent = false;
      }
      await s.prepare(op, args: a);
      final p = await s.prepare(op, args: a);
      if (op == 'cancelAutoMerge') s.auto = false;
      await s.commit(p);
      final getCount = s.adapter.requests
          .where((r) => r.method == 'GET')
          .length;
      final countWithReplayAndControllerFreshness =
          (getCount + 2) * 2 + s.writes.length;
      expect(
        countWithReplayAndControllerFreshness,
        lessThanOrEqualTo(productionAiLedger.find(op)!.httpCap),
      );
      expect(s.writes, hasLength(1));
    });
  }
  test(
    'known local closing effect does not add foreign confirmation',
    () async {
      s.description = 'Closes #7';
      s.closes = [
        {'project_id': 9, 'iid': 7},
      ];
      final p = await s.prepare('mergeRequest');
      expect(
        p.facts.reasons,
        isNot(contains(AiFixedConfirmReason.foreignClosingOrCrossProject)),
      );
    },
  );
  test('unproven local closing effect requires confirmation', () async {
    s.description = 'Closes #7';
    final p = await s.prepare('mergeRequest');
    expect(
      p.facts.reasons,
      contains(AiFixedConfirmReason.foreignClosingOrCrossProject),
    );
  });
  for (final status in [401, 500]) {
    for (final mode in ['merged', 'scheduled', 'accepted']) {
      test('valid $mode mutation survives readback $status', () async {
        s.resultState = mode == 'merged' ? 'merged' : 'opened';
        s.readbackStatus = status;
        final result = await s.commit(
          await s.prepare(
            'mergeRequest',
            args: {'autoMerge': mode == 'scheduled'},
          ),
        );
        expect(result.state, AiJournalState.succeeded);
        expect(
          result.resultCode,
          {
            'merged': 'merged',
            'scheduled': 'autoMergeScheduled',
            'accepted': 'mergeAccepted',
          }[mode],
        );
      });
    }
  }
  test('malformed merge mutation remains uncertain', () async {
    s.resultState = 'unrecognized';
    expect(
      (await s.commit(await s.prepare('mergeRequest'))).state,
      AiJournalState.writeUncertain,
    );
  });
  test('cancel permission advisory changes invalidate approval', () async {
    await s.prepare('cancelAutoMerge');
    s.canMerge = true;
    await expectLater(
      s.prepare('cancelAutoMerge'),
      throwsA(reason('headMoved')),
    );
    expect(s.writes, isEmpty);
  });
  test(
    'terminal snapshots do not limit a conversation to 128 proposals',
    () async {
      for (var i = 0; i < 130; i++) {
        final p = await s.prepare(
          'approveMergeRequest',
          execution: 'terminal-$i',
        );
        expect((await s.commit(p)).state, AiJournalState.succeeded);
      }
      expect(s.writes, hasLength(130));
    },
  );
  test('abandoned snapshots do not permanently block new proposals', () async {
    for (var i = 0; i < 130; i++) {
      await s.prepare('approveMergeRequest', execution: 'abandoned-$i');
    }
    expect(s.writes, isEmpty);
    await expectLater(
      s.prepare('approveMergeRequest', execution: 'abandoned-0'),
      throwsA(reason('mergeCheckIncomplete')),
    );
  });
  test('terminal snapshot is released after settlement', () async {
    await s.commit(await s.prepare('approveMergeRequest'));
    s.sha = 'e' * 40;
    expect((await s.prepare('approveMergeRequest')).journal.headSha, s.sha);
  });
  test(
    'unchanged head with moved diff refs cannot reuse cached paths',
    () async {
      await s.prepare('mergeRequest');
      s.baseSha = 'e' * 40;
      await expectLater(
        s.prepare('mergeRequest'),
        throwsA(reason('headMoved')),
      );
    },
  );
  test('compare unavailable after 409 prevents a new proposal', () async {
    s.status = 409;
    await s.commit(await s.prepare('mergeRequest'));
    s.compareStatus = 404;
    await expectLater(
      s.prepare('approveMergeRequest', execution: 'retry'),
      throwsA(reason('mergeCheckUnsupported')),
    );
    expect(s.writes, hasLength(1));
  });
  test('already merged refuses cancel before any write', () async {
    s.mrState = 'merged';
    await expectLater(
      s.prepare('cancelAutoMerge'),
      throwsA(reason('alreadyMerged')),
    );
    expect(s.writes, isEmpty);
  });
  for (final config in [null, '../ci.yml']) {
    test('unreadable CI config $config fails closed to hard line', () async {
      s.config = config;
      expect(tier(await s.prepare('mergeRequest')).tier, AiWriteTier.hardLine);
    });
  }
  test(
    'cross-project source is unsupported instead of locking wrong source ref',
    () async {
      s.foreignSource = true;
      await expectLater(
        s.prepare('mergeRequest'),
        throwsA(reason('mergeCheckUnsupported')),
      );
    },
  );
}
