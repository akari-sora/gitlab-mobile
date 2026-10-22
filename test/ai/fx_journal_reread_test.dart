import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart'
    show AiWriteLimits;
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/ai/ai_write_reread.dart';

import '../support/fake_adapter.dart';

// testApi's default host is installed under a subpath.
const _instance = 'https://example.com/gitlab';
const _account = '$_instance#7';
const _api = '/gitlab/api/v4';
final _digest = List.filled(64, 'c').join();

AiConflictKey _key(List<String> rest) => AiConflictKey([_account, ...rest]);

Map<String, Object?> _user(int id) => {
  'id': id,
  'username': 'user$id',
  'name': 'User $id',
};

ResponseBody _notFound() =>
    jsonResponse({'message': '404 Not found'}, status: 404);

void _onlyGet(FakeAdapter adapter) {
  expect(adapter.requests, isNotEmpty);
  expect(adapter.requests.map((request) => request.method).toSet(), {'GET'});
}

void main() {
  late Directory root;
  late MemoryAiJournalKeyStore keys;
  late AiWriteJournal journal;
  late DateTime clock;
  var serial = 0;

  AiWriteJournal owner(String process) =>
      AiWriteJournal(keys: keys, applicationSupport: root, processId: process)
        ..now = () => clock;

  setUp(() async {
    root = Directory(
      Directory.systemTemp.resolveSymbolicLinksSync(),
    ).createTempSync('fx-journal-reread-');
    keys = MemoryAiJournalKeyStore();
    clock = DateTime.utc(2026, 10, 23, 3);
    serial = 0;
    journal = owner('reread-one');
    await journal.recoverAfterAccountsLoaded(const <String>[_account]);
  });
  tearDown(() => root.deleteSync(recursive: true));

  AiJournalDraft draft(
    Set<AiConflictKey> writes, {
    String operation = 'updateIssue',
    String release = '#12',
    String account = _account,
    String instance = _instance,
  }) {
    final id = 'execution-${serial++}';
    return AiJournalDraft(
      executionId: id,
      accountKey: account,
      conversationId: 'conversation-$id',
      runId: 'run-$id',
      operationId: operation,
      writeKeys: writes,
      payloadSha256: _digest,
      releaseName: release,
      instance: instance,
    );
  }

  Future<String> dispatched(
    Set<AiConflictKey> writes, {
    String operation = 'updateIssue',
    String release = '#12',
  }) async {
    final value = draft(writes, operation: operation, release: release);
    await journal.prepare(draft: value);
    await journal.markDispatching(executionId: value.executionId);
    return value.executionId;
  }

  Future<String> interrupted(
    Set<AiConflictKey> writes, {
    String operation = 'updateIssue',
    String release = '#12',
  }) async {
    final id = await dispatched(writes, operation: operation, release: release);
    await journal.finish(
      executionId: id,
      terminal: AiJournalState.writeUncertain,
    );
    return id;
  }

  Future<AiJournalEntry> prepared(
    Set<AiConflictKey> writes, {
    String release = '#12',
    String account = _account,
    String instance = _instance,
  }) async {
    final value = draft(
      writes,
      release: release,
      account: account,
      instance: instance,
    );
    return (await journal.prepare(draft: value)).entry;
  }

  /// A small synthetic GitLab for the shapes the journal keys name.
  ResponseBody server(RequestOptions request, {int userId = 7}) {
    final path = request.uri.path;
    final issue = {
      'id': 900,
      'iid': 12,
      'project_id': 5,
      'state': 'closed',
      'subscribed': true,
    };
    return switch (path) {
      '$_api/user' => jsonResponse(_user(userId)),
      '$_api/projects/5' => jsonResponse(projectJson(5)),
      '$_api/projects/5/issues/12' => jsonResponse(issue),
      '$_api/projects/5/merge_requests/12' => jsonResponse({
        ...issue,
        'state': 'merged',
      }),
      '$_api/projects/5/issues' ||
      '$_api/projects/5/merge_requests' => jsonResponse(const <Object?>[]),
      '$_api/projects/5/issues/12/notes' ||
      '$_api/projects/5/merge_requests/12/notes' => jsonResponse(
        const <Object?>[],
      ),
      '$_api/projects/5/issues/12/notes/8' => jsonResponse({'id': 8}),
      '$_api/projects/5/merge_requests/12/award_emoji' => jsonResponse([
        {
          'id': 1,
          'name': 'thumbsup',
          'user': {'id': 7},
        },
      ]),
      '$_api/projects/5/merge_requests/12/discussions/abc' => jsonResponse({
        'id': 'abc',
        'notes': [
          {'id': 1, 'resolvable': true, 'resolved': true},
        ],
      }),
      '$_api/projects/5/merge_requests/12/draft_notes/9' => jsonResponse({
        'id': 9,
      }),
      '$_api/projects/5/labels/3' => jsonResponse({'id': 3}),
      '$_api/projects/5/milestones/4' => jsonResponse({
        'id': 4,
        'state': 'active',
      }),
      '$_api/projects/5/boards/6' => jsonResponse({'id': 6}),
      '$_api/todos' => jsonResponse([
        {'id': 31},
      ]),
      _ => _notFound(),
    };
  }

  test(
    'observation is recorded and the lock, state and typed release stay',
    () async {
      final key = _key(['project:5', 'workItem', '12']);
      final id = await interrupted({key});
      final adapter = FakeAdapter(server);
      final result = await rereadInterruptedWrite(
        journal: journal,
        accountKey: _account,
        executionId: id,
        api: testApi(adapter),
        now: () => clock,
      );
      expect(result.observation.presence, AiRereadPresence.present);
      expect(result.observation.subject, AiRereadSubject.issue);
      expect(result.observation.detail, AiRereadDetail.closed);
      expect(result.requests, 3);
      expect(result.projectPath, 'team/example-5');
      _onlyGet(adapter);

      final entry = journal.entries(_account).single;
      expect(entry.state, AiJournalState.writeUncertain);
      final stored = AiRereadObservation.decode(entry.observation)!;
      expect(stored.presence, AiRereadPresence.present);
      expect(stored.detail, AiRereadDetail.closed);
      expect(stored.observedAt, clock);
      // Only an observation: the lock holds and release still needs the name.
      expect(journal.isolated(_account, {key}), isTrue);
      await expectLater(
        journal.prepare(draft: draft({key})),
        throwsA(
          isA<AiJournalException>().having(
            (error) => error.reason,
            'reason',
            'isolated',
          ),
        ),
      );
      await expectLater(
        journal.releaseByUser(executionId: id, typedName: '#13'),
        throwsA(isA<AiJournalException>()),
      );

      final restarted = owner('reread-two');
      await restarted.recoverAfterAccountsLoaded(const <String>[_account]);
      final kept = restarted.entries(_account).single;
      expect(kept.state, AiJournalState.writeUncertain);
      expect(kept.observation, entry.observation);
    },
  );

  test('a 404 is absent: not found or not visible', () async {
    final id = await interrupted({
      _key(['project:5', 'workItem', '12']),
    });
    final adapter = FakeAdapter(
      (request) => request.uri.path == '$_api/projects/5/issues/12'
          ? _notFound()
          : server(request),
    );
    final result = await rereadInterruptedWrite(
      journal: journal,
      accountKey: _account,
      executionId: id,
      api: testApi(adapter),
    );
    expect(result.observation.presence, AiRereadPresence.absent);
    expect(result.observation.subject, AiRereadSubject.issue);
    expect(
      journal.entries(_account).single.state,
      AiJournalState.writeUncertain,
    );
    _onlyGet(adapter);
  });

  test(
    'a create compares this account\'s items within five minutes of dispatch',
    () async {
      final notes = _key(['project:5', 'mergeRequest', '12', 'notes']);
      final id = await interrupted(
        {notes},
        operation: 'createNote',
        release: '!12',
      );
      var page = <Map<String, Object?>>[
        {
          'id': 70,
          'author': {'id': 7},
          'created_at': clock.add(const Duration(minutes: 1)).toIso8601String(),
        },
      ];
      final adapter = FakeAdapter(
        (request) =>
            request.uri.path == '$_api/projects/5/merge_requests/12/notes'
            ? jsonResponse(page)
            : server(request),
      );
      final found = await rereadInterruptedWrite(
        journal: journal,
        accountKey: _account,
        executionId: id,
        api: testApi(adapter),
      );
      expect(found.observation.presence, AiRereadPresence.present);
      expect(found.observation.subject, AiRereadSubject.note);
      expect(found.observation.matches, 1);

      page = [
        {
          'id': 71,
          'author': {'id': 8},
          'created_at': clock.toIso8601String(),
        },
        {
          'id': 69,
          'author': {'id': 7},
          'created_at': clock
              .subtract(const Duration(minutes: 6))
              .toIso8601String(),
        },
      ];
      final none = await rereadInterruptedWrite(
        journal: journal,
        accountKey: _account,
        executionId: id,
        api: testApi(adapter),
      );
      expect(none.observation.presence, AiRereadPresence.absent);
      expect(none.observation.matches, 0);
      expect(
        AiRereadObservation.decode(
          journal.entries(_account).single.observation,
        )!.presence,
        AiRereadPresence.absent,
      );
      _onlyGet(adapter);
    },
  );

  test('requests are capped at rereadHttp', () async {
    expect(AiWriteLimits.rereadHttp, 10);
    final id = await interrupted(
      {
        _key(['project:5', 'mergeRequest', '12', 'notes']),
      },
      operation: 'createNote',
      release: '!12',
    );
    // Every page is inside the window, by someone else, with a next page.
    final adapter = FakeAdapter((request) {
      if (request.uri.path != '$_api/projects/5/merge_requests/12/notes') {
        return server(request);
      }
      final page = int.parse(request.uri.queryParameters['page'] ?? '1');
      return jsonResponse(
        [
          {
            'id': 1000 - page,
            'author': {'id': 8},
            'created_at': clock.toIso8601String(),
          },
        ],
        headers: {
          'x-next-page': ['${page + 1}'],
        },
      );
    });
    final result = await rereadInterruptedWrite(
      journal: journal,
      accountKey: _account,
      executionId: id,
      api: testApi(adapter),
    );
    expect(adapter.requests, hasLength(AiWriteLimits.rereadHttp));
    expect(result.requests, AiWriteLimits.rereadHttp);
    expect(result.observation.presence, AiRereadPresence.unknown);
    expect(result.observation.detail, AiRereadDetail.budgetExhausted);
    _onlyGet(adapter);
  });

  final shapes =
      <
        String,
        (List<String>, AiRereadPresence, AiRereadSubject, AiRereadDetail?)
      >{
        'star': (
          ['project:5', 'star', '7'],
          AiRereadPresence.present,
          AiRereadSubject.project,
          null,
        ),
        'createIssue': (
          ['project:5', 'workItem'],
          AiRereadPresence.absent,
          AiRereadSubject.issue,
          null,
        ),
        'subscription': (
          ['project:5', 'workItem', '12', 'subscription', '7'],
          AiRereadPresence.present,
          AiRereadSubject.issue,
          AiRereadDetail.subscribed,
        ),
        'updateMergeRequest': (
          ['project:5', 'mergeRequest', '12'],
          AiRereadPresence.present,
          AiRereadSubject.mergeRequest,
          AiRereadDetail.merged,
        ),
        'updateNote': (
          ['project:5', 'workItem', '12', 'notes', '8'],
          AiRereadPresence.present,
          AiRereadSubject.note,
          null,
        ),
        'missingNote': (
          ['project:5', 'workItem', '12', 'notes', '88'],
          AiRereadPresence.absent,
          AiRereadSubject.note,
          null,
        ),
        'award': (
          ['project:5', 'mergeRequest', '12', 'award', '7', 'thumbsup'],
          AiRereadPresence.present,
          AiRereadSubject.award,
          null,
        ),
        'discussion': (
          ['project:5', 'mergeRequest', '12', 'discussions', 'abc'],
          AiRereadPresence.present,
          AiRereadSubject.discussion,
          AiRereadDetail.resolved,
        ),
        'draftNote': (
          ['project:5', 'mergeRequest', '12', 'draftNotes', '9'],
          AiRereadPresence.present,
          AiRereadSubject.draftNote,
          null,
        ),
        'createDraftNote': (
          ['project:5', 'mergeRequest', '12', 'draftNotes'],
          AiRereadPresence.unknown,
          AiRereadSubject.draftNote,
          AiRereadDetail.notComparable,
        ),
        'label': (
          ['project:5', 'labels', '3'],
          AiRereadPresence.present,
          AiRereadSubject.label,
          null,
        ),
        'milestone': (
          ['project:5', 'milestones', '4'],
          AiRereadPresence.present,
          AiRereadSubject.milestone,
          AiRereadDetail.active,
        ),
        'board': (
          ['project:5', 'boards', '6'],
          AiRereadPresence.present,
          AiRereadSubject.board,
          null,
        ),
        'upload': (
          ['project:5', 'upload', 'f' * 64],
          AiRereadPresence.unknown,
          AiRereadSubject.upload,
          AiRereadDetail.notComparable,
        ),
        'pendingTodo': (
          ['todos', '31'],
          AiRereadPresence.present,
          AiRereadSubject.todo,
          AiRereadDetail.pending,
        ),
        'finishedTodo': (
          ['todos', '32'],
          AiRereadPresence.absent,
          AiRereadSubject.todo,
          AiRereadDetail.notPending,
        ),
        'goneProject': (
          ['project:6', 'labels', '3'],
          AiRereadPresence.absent,
          AiRereadSubject.project,
          null,
        ),
      };
  for (final MapEntry(key: name, value: shape) in shapes.entries) {
    test('$name: ${shape.$2.name} ${shape.$3.name}, GET only', () async {
      final id = await interrupted({_key(shape.$1)});
      final adapter = FakeAdapter(server);
      final result = await rereadInterruptedWrite(
        journal: journal,
        accountKey: _account,
        executionId: id,
        api: testApi(adapter),
      );
      expect(result.observation.presence, shape.$2);
      expect(result.observation.subject, shape.$3);
      expect(result.observation.detail, shape.$4);
      expect(adapter.requests.length, lessThanOrEqualTo(4));
      _onlyGet(adapter);
      final entry = journal.entries(_account).single;
      expect(entry.state, AiJournalState.writeUncertain);
      expect(
        AiRereadObservation.decode(entry.observation)?.encode(),
        result.observation.encode(),
      );
    });
  }

  group('refused while the original request may still be in flight', () {
    test('a dispatching entry is refused with no request', () async {
      final id = await dispatched({
        _key(['project:5', 'workItem', '12']),
      });
      final adapter = FakeAdapter(server);
      await expectLater(
        rereadInterruptedWrite(
          journal: journal,
          accountKey: _account,
          executionId: id,
          api: testApi(adapter),
        ),
        throwsA(
          isA<AiJournalException>().having(
            (error) => error.reason,
            'reason',
            'inFlight',
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
      expect(journal.entries(_account).single.observation, isNull);

      // After a restart the other process's request cannot be running.
      final restarted = owner('reread-two');
      await restarted.recoverAfterAccountsLoaded(const <String>[_account]);
      final result = await rereadInterruptedWrite(
        journal: restarted,
        accountKey: _account,
        executionId: id,
        api: testApi(adapter),
      );
      expect(result.observation.presence, AiRereadPresence.present);
      _onlyGet(adapter);
    });

    test('a pending journal reset refuses, its cancellation allows', () async {
      final id = await interrupted({
        _key(['project:5', 'workItem', '12']),
      });
      final reset = await journal.beginReset(_account);
      final adapter = FakeAdapter(server);
      await expectLater(
        rereadInterruptedWrite(
          journal: journal,
          accountKey: _account,
          executionId: id,
          api: testApi(adapter),
        ),
        throwsA(
          isA<AiJournalException>().having(
            (error) => error.reason,
            'reason',
            'inFlight',
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
      journal.cancelReset(reset);
      await rereadInterruptedWrite(
        journal: journal,
        accountKey: _account,
        executionId: id,
        api: testApi(adapter),
      );
      _onlyGet(adapter);
    });

    test('a settled or released entry is not interrupted', () async {
      final id = await dispatched({
        _key(['project:5', 'workItem', '12']),
      });
      await journal.finish(executionId: id, terminal: AiJournalState.succeeded);
      final adapter = FakeAdapter(server);
      await expectLater(
        rereadInterruptedWrite(
          journal: journal,
          accountKey: _account,
          executionId: id,
          api: testApi(adapter),
        ),
        throwsA(
          isA<AiJournalException>().having(
            (error) => error.reason,
            'reason',
            'notInterrupted',
          ),
        ),
      );
      expect(adapter.requests, isEmpty);
    });
  });

  test(
    'another account or instance is refused and nothing is recorded',
    () async {
      final id = await interrupted({
        _key(['project:5', 'workItem', '12']),
      });
      final otherUser = FakeAdapter((request) => server(request, userId: 8));
      await expectLater(
        rereadInterruptedWrite(
          journal: journal,
          accountKey: _account,
          executionId: id,
          api: testApi(otherUser),
        ),
        throwsA(
          isA<AiJournalException>().having(
            (error) => error.reason,
            'reason',
            'accountMismatch',
          ),
        ),
      );
      expect(otherUser.requests, hasLength(1));
      final otherHost = FakeAdapter(server);
      await expectLater(
        rereadInterruptedWrite(
          journal: journal,
          accountKey: _account,
          executionId: id,
          api: testApi(otherHost, host: 'https://example.com'),
        ),
        throwsA(isA<AiJournalException>()),
      );
      expect(otherHost.requests, isEmpty);
      expect(journal.entries(_account).single.observation, isNull);
    },
  );

  test('observation codes round trip and reject anything else', () {
    final value = AiRereadObservation(
      presence: AiRereadPresence.present,
      subject: AiRereadSubject.note,
      matches: 2,
      observedAt: DateTime.utc(2026, 10, 23, 3, 4, 5),
    );
    final decoded = AiRereadObservation.decode(value.encode())!;
    expect(decoded.encode(), value.encode());
    expect(value.encode(), isNot(contains('\n')));
    for (final other in [
      null,
      'done',
      'notDone',
      'reread.v1;present;note;-;2',
      'reread.v1;maybe;note;-;-;2026-10-23T03:04:05.000Z',
      'reread.v1;present;note;-;-1;2026-10-23T03:04:05.000Z',
      'reread.v1;present;note;-;-;2026-10-23T03:04:05.000',
    ]) {
      expect(AiRereadObservation.decode(other), isNull, reason: other);
    }
  });

  group('GitLab link from the verified instance and ids', () {
    final instance = GitLabInstance.parse(_instance);

    test('a subpath instance keeps its installation path', () async {
      final merge = await prepared({
        _key(['project:5', 'mergeRequest', '12', 'notes']),
      });
      expect(
        aiJournalTargetWebUri(
          instance,
          merge,
          projectPath: 'team/app',
        ).toString(),
        'https://example.com/gitlab/team/app/-/merge_requests/12',
      );
      final note = await prepared({
        _key(['project:5', 'workItem', '13', 'notes', '44']),
      }, release: '#13');
      expect(
        aiJournalTargetWebUri(
          instance,
          note,
          projectPath: 'team/app',
        ).toString(),
        'https://example.com/gitlab/team/app/-/issues/13#note_44',
      );
      final board = await prepared({
        _key(['project:5', 'boards', '6']),
      }, release: 'team/app');
      // A project-level write names the project path in its release name.
      expect(
        aiJournalTargetWebUri(instance, board).toString(),
        'https://example.com/gitlab/team/app/-/boards/6',
      );
      final create = await prepared({
        _key(['project:5', 'workItem']),
      }, release: 'team/app');
      expect(
        aiJournalTargetWebUri(instance, create).toString(),
        'https://example.com/gitlab/team/app/-/issues',
      );
      // Without a path, GitLab's numeric project address.
      expect(
        aiJournalTargetWebUri(instance, note).toString(),
        'https://example.com/gitlab/projects/5',
      );
      for (final unsafe in ['../evil/x', 'team/../../x', 'single', 'a//b']) {
        expect(
          aiJournalTargetWebUri(
            instance,
            merge,
            projectPath: unsafe,
          ).toString(),
          'https://example.com/gitlab/projects/5',
          reason: unsafe,
        );
      }
    });

    test('a port is kept and only the entry\'s instance qualifies', () async {
      const ported = 'https://example.com:8443/gitlab';
      const portedAccount = '$ported#7';
      await journal.recoverAfterAccountsLoaded(const <String>[
        _account,
        portedAccount,
      ]);
      final entry = await prepared(
        {
          const AiConflictKey([
            portedAccount,
            'project:5',
            'mergeRequest',
            '12',
          ]),
        },
        account: portedAccount,
        instance: ported,
      );
      expect(
        aiJournalTargetWebUri(
          GitLabInstance.parse(ported),
          entry,
          projectPath: 'team/app',
        ).toString(),
        'https://example.com:8443/gitlab/team/app/-/merge_requests/12',
      );
      expect(aiJournalTargetWebUri(instance, entry), isNull);
      expect(
        aiJournalTargetWebUri(
          GitLabInstance.parse('https://example.com'),
          entry,
        ),
        isNull,
      );
    });

    test('a target it cannot address is null', () async {
      final todo = await prepared({
        _key(['todos', '31']),
      }, release: '@user7');
      expect(aiJournalTargetWebUri(instance, todo), isNull);
      final upload = await prepared({
        _key(['project:5', 'upload', 'f' * 64]),
      }, release: 'screen.png');
      expect(
        aiJournalTargetWebUri(instance, upload, projectPath: 'team/app'),
        isNull,
      );
      // A to-do on an issue links to that issue.
      final issueTodo = await prepared({
        _key(['todos', '33']),
        _key(['project:5', 'workItem', '14', 'todo', '7']),
      }, release: '@user7');
      expect(
        aiJournalTargetWebUri(
          instance,
          issueTodo,
          projectPath: 'team/app',
        ).toString(),
        'https://example.com/gitlab/team/app/-/issues/14',
      );
    });
  });
}
