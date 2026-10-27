import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/intent_lexicon.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/target_binding.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/core/read_cache_disk_contract.dart';
import 'package:gitlab_mobile/core/request_meter.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';

import '../support/fake_adapter.dart';
import 'mr6b3_support.dart';

const _emptyClear = DiskClearResult(keyGoneConfirmed: false,
    directoryGoneConfirmed: false, markerDurable: false, complete: false);

final class _HeldFence implements DiskInvalidationFence {
  _HeldFence(this.barrier);
  @override
  final Future<DiskClearResult> barrier;
  @override
  Future<void> get quiesced => barrier.then((_) {}, onError: (Object _) {});
  @override
  bool get isCurrent => true;
  @override
  void revoke() {}
}

final class _MutationBarrier implements ReadCacheDiskBackend {
  _MutationBarrier(this.begin);
  final Future<DiskClearResult> Function() begin;
  final entered = Completer<void>();
  int meterAtEntry = -1;
  RequestMeter? meter;
  @override
  DiskInvalidationFence invalidate(DiskInvalidation invalidation) {
    meter = RequestMeter.current;
    meterAtEntry = meter?.count ?? -1;
    if (!entered.isCompleted) entered.complete();
    return _HeldFence(begin());
  }
  @override
  Future<ProjectedDiskEntry?> lookup(DiskLookup lookup) async => null;
  @override
  void accept(DiskWriteCandidate candidate, ProjectedDiskEntry entry) {}
  @override
  void revoke(DiskBinding binding) {}
  @override
  Future<DiskClearResult> clear(DiskBinding binding, ReadCacheCleanupOperation operation) async => _emptyClear;
  @override
  void reportCleanup(ReadCacheCleanupState state) {}
}

const _operations = ['snoozeTodo', 'unsnoozeTodo'];
const _global = AiWriteScope(
  accountKey: mr6b3Account,
  grants: [AiScopeGrant(kind: AiScopeKind.accountGlobal)],
);
final _future = DateTime.now().toUtc().add(const Duration(days: 30));

// GitLab's Time scalar emits whole seconds, without a fractional part.
String _timeScalar(DateTime time) =>
    '${time.toUtc().toIso8601String().split('.').first}Z';

Map<String, Object?> _args(String op) => {
  'todoId': op == 'snoozeTodo' ? 1 : 2,
  if (op == 'snoozeTodo') 'until': _future.toIso8601String(),
};

Map<String, Object?> _project({int id = 9, String path = 'team/example-9'}) => {
  'id': 'gid://gitlab/Project/$id',
  'fullPath': path,
};

Map<String, Object?> _node(
  int id, {
  String type = 'WorkItem',
  bool snoozed = false,
}) => {
  'id': 'gid://gitlab/Todo/$id',
  'targetType': {
    'Issue': 'ISSUE',
    'MergeRequest': 'MERGEREQUEST',
    'WorkItem': 'WORKITEM',
  }[type],
  'snoozedUntil': snoozed ? _timeScalar(_future) : null,
  'project': _project(),
  'group': null,
  'targetEntity': <String, Object?>{
    '__typename': type,
    if (type == 'Issue') 'issueId': 'gid://gitlab/Issue/91',
    if (type == 'MergeRequest') 'mergeRequestId': 'gid://gitlab/MergeRequest/91',
    if (type == 'WorkItem') 'workItemId': 'gid://gitlab/WorkItem/91',
    'iid': '3',
    if (type == 'Issue') 'projectId': 9,
    if (type == 'MergeRequest') 'mergeRequestProject': _project(),
    if (type == 'WorkItem') 'workItemProject': _project(),
    if (type == 'WorkItem')
      'namespace': {'id': 'gid://gitlab/Namespaces::ProjectNamespace/9', 'fullPath': 'team/example-9'},
  },
};

// Every response comes through the real API adapter. Unknown endpoints fail,
// including the old observation query and any REST todo/target fallback.
final class _Server {
  _Server({this.oauthReplay = false}) {
    todos = [
      _node(1), // Never snoozed.
      _node(2, snoozed: true), // Future snooze.
      _node(3)..['snoozedUntil'] = '2020-01-01T00:00:00Z', // Expired.
      _node(4), // Done; excluded from both pending sets.
    ];
    adapter = FakeAdapter((request) async {
      await beforeRequest?.call(request);
      if (request.uri.path.endsWith('/oauth/token')) {
        refreshes++;
        return jsonResponse({
          'access_token': 'synthetic-access-$refreshes',
          'refresh_token': 'synthetic-refresh-$refreshes',
          'token_type': 'bearer',
        });
      }
      final query = request.data is Map ? (request.data as Map)['query'] : null;
      final read =
          request.method == 'GET' ||
          (query is String && query.startsWith('query '));
      if (read) {
        final failure = readFailure?.call(request);
        if (failure != null) return failure;
      }
      if (oauthReplay && read) {
        _replayNext = !_replayNext;
        if (_replayNext) return jsonResponse({}, status: 401);
      }
      if (request.method == 'GET' && request.uri.path.endsWith('/user')) {
        userReads++;
        return jsonResponse({
          'id': user,
          'username': 'tester',
          'name': 'Tester',
        });
      }
      expect(request.uri.path, '/gitlab/api/graphql');
      expect(request.method, 'POST');
      final body = request.data as Map;
      final variables = body['variables'] as Map;
      if (query is String && query.startsWith('query ')) {
        expect(
          query,
          anyOf(
            startsWith('query MobilePendingTodosForSnooze('),
            startsWith('query MobileSnoozedTodosForUnsnooze('),
          ),
        );
        final snoozed = query.startsWith(
          'query MobileSnoozedTodosForUnsnooze(',
        );
        expect(query, contains('state: pending, isSnoozed: $snoozed'));
        expect(query, contains('project { id fullPath }'));
        expect(query, contains('group { id fullPath }'));
        expect(query, contains('namespace { id fullPath }'));
        expect(variables['first'], 100);
        ownershipReads++;
        final offset = variables['after'] == null
            ? 0
            : int.parse('${variables['after']}');
        final eligible = todos.where((node) {
          final id = int.parse((node['id']! as String).split('/').last);
          final raw = node['snoozedUntil'];
          final future =
              raw is String &&
              (DateTime.tryParse(raw)?.isAfter(DateTime.now()) ?? false);
          return !done.contains(id) && snoozed == future;
        }).toList();
        final nodes = eligible.skip(offset).take(pageSize).toList();
        final more = forceMore || offset + nodes.length < eligible.length;
        final envelope = <String, Object?>{
          'data': {
            'currentUser': {
              'id': 'gid://gitlab/User/$actor',
              'todos': {
                'nodes': nodes,
                'pageInfo': {
                  'hasNextPage': more,
                  'endCursor': more ? '${offset + nodes.length}' : null,
                },
              },
            },
          },
        };
        editPage?.call(envelope, offset);
        return jsonResponse(envelope);
      }
      expect(query, startsWith('mutation MobileTodo'));
      mutations++;
      await onMutation?.call();
      final response = mutationResponse;
      if (response != null) return response();
      final status = mutationStatus;
      if (status != null) return jsonResponse({}, status: status);
      if (cancelMutation) {
        throw DioException(
          requestOptions: request,
          type: DioExceptionType.cancel,
        );
      }
      final snooze = (query! as String).startsWith(
        'mutation MobileTodoSnooze(',
      );
      final field = snooze ? 'todoSnooze' : 'todoUnSnooze';
      final todo = <String, Object?>{
        'id': variables['id'],
        'snoozedUntil': snooze
            ? _timeScalar(DateTime.parse(variables['until'] as String))
            : null,
      };
      final payload = <String, Object?>{'todo': todo, 'errors': <String>[]};
      editAck?.call(payload);
      return jsonResponse({
        'data': {field: payload},
      });
    });
    if (oauthReplay) {
      final dio = Dio()..httpClientAdapter = adapter;
      final instance = GitLabInstance.parse('https://example.com/gitlab');
      api = GitLabApi(
        instance: instance,
        credential: const OAuthCredential(
          accessToken: 'synthetic-access',
          refreshToken: 'synthetic-refresh',
          clientId: 'synthetic-client',
        ),
        dio: dio,
        oauth: OAuthTokenClient(
          instance: instance,
          clientId: 'synthetic-client',
          dio: dio,
        ),
      );
    } else {
      api = testApi(adapter);
    }
    writePort = port.GitLabAiWritePort(api, accountKey: mr6b3Account);
  }

  final bool oauthReplay;
  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final port.GitLabAiWritePort writePort;
  late List<Map<String, Object?>> todos;
  final done = <int>{4};
  int pageSize = 100;
  bool forceMore = false;
  int user = 7;
  int actor = 7;
  int userReads = 0;
  int ownershipReads = 0;
  int mutations = 0;
  int refreshes = 0;
  int? mutationStatus;
  bool cancelMutation = false;
  bool _replayNext = false;
  FutureOr<void> Function(RequestOptions)? beforeRequest;
  ResponseBody? Function(RequestOptions)? readFailure;
  FutureOr<void> Function()? onMutation;
  ResponseBody Function()? mutationResponse;
  void Function(Map<String, Object?>, int)? editPage;
  void Function(Map<String, Object?>)? editAck;

  Iterable<RequestOptions> get requests => adapter.requests.where(
    (request) => !request.uri.path.endsWith('/oauth/token'),
  );

  port.AiWriteRequest request(
    String op, {
    Map<String, Object?>? args,
    AiWriteScope scope = mr6b3Scope,
    String execution = 'p13-direct',
  }) => port.AiWriteRequest(
    operationId: op,
    executionId: execution,
    scope: scope,
    arguments: args ?? _args(op),
  );

  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    Future<void> Function()? beforeMutation,
    bool Function()? mayStart,
  }) {
    prepared.bindGraphBeforeMutation(beforeMutation ?? () async {});
    return writePort.commit(prepared, mayStart: mayStart ?? () => true);
  }
}

// Before P14 only this test ledger exposed P13; production rows are visible now.
final class _Ledger implements AiCapabilityLedger {
  const _Ledger();
  @override
  AiCapability? find(String operationId) {
    final row = productionAiLedger.find(operationId);
    if (row == null || !_operations.contains(operationId)) return null;
    return AiCapability(
      operationId: row.operationId,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      arguments: row.arguments,
      boundary: row.boundary,
      httpCap: row.httpCap,
      readback: row.readback,
    );
  }

  @override
  List<AiCapability> get modelVisible => [
    for (final op in _operations) find(op)!,
  ];
}

final class _Harness {
  _Harness(this.server, this.root, this.keys, this.files, this.journal);
  static Future<_Harness> create(
    _Server server, {
    AiWriteScope scope = mr6b3Scope,
    AiAutonomyLevel level = AiAutonomyLevel.confirmEach,
    int limit = 40,
  }) async {
    final root = Directory.systemTemp.createTempSync('p13-snooze-');
    final keys = Mr6b3JournalKeyStore();
    final files = Mr6b3JournalFiles(root);
    final journal = AiWriteJournal(
      keys: keys,
      applicationSupport: root,
      files: files,
      processId: 'p13-snooze',
    );
    await journal.recoverAfterAccountsLoaded([mr6b3Account]);
    await journal.ensureInitialized(mr6b3Account);
    final h = _Harness(server, root, keys, files, journal)
      ..scope = scope
      ..level = level;
    h.budget = AiToolBudget(maxGitLabRequests: limit);
    h.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: h.scope,
        level: h.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'synthetic-p13',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: h.generation,
        alive: h.alive,
        consentValid: true,
        clientMayStart: h.mayStart,
      ),
      createPort: () => server.writePort,
      journal: journal,
      conversationId: 'p13-snooze',
      budget: () => h.budget,
      readFreshness: (_) async =>
          const AiWriteFreshness(visibilityUnreadable: false),
      placeholders: text.UploadPlaceholderTable(instance: server.api.instance),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: const _Ledger(),
    );
    h.coordinator.beginRun('Review the requested todo.');
    h.coordinator.beginTurn();
    return h;
  }

  final _Server server;
  final Directory root;
  final Mr6b3JournalKeyStore keys;
  final Mr6b3JournalFiles files;
  final AiWriteJournal journal;
  late PolicyAiWriteCoordinator coordinator;
  late AiToolBudget budget;
  late AiWriteScope scope;
  late AiAutonomyLevel level;
  bool alive = true;
  bool mayStart = true;
  int generation = 7;
  int _calls = 0;
  String lastCall = '';
  Future<AiWriteProposal?> propose(
    String op, {
    Map<String, Object?>? args,
    String? message,
    String reason = 'synthetic request',
  }) {
    if (message != null) {
      coordinator.beginRun(message);
      coordinator.beginTurn();
    }
    lastCall = 'p13-${_calls++}';
    return coordinator.propose(
      AiToolCall(
        id: lastCall,
        name: op,
        arguments: {...(args ?? _args(op)), 'reason': reason},
      ),
    );
  }

  Future<AiWriteOutcome> approve(AiWriteProposal proposal) =>
      coordinator.approve(proposal, typedName: proposal.tier.typedName);
  Future<Map<String, Object?>> durable() => AiHistoryCipher.decryptJson(
    File(files.pathFor(mr6b3Account)).readAsBytesSync(),
    keys.keys[mr6b3Account]!,
    mr6b3Account,
    AiJournalFiles.fileName,
  );
  Future<void> dispose() async {
    files.releaseBarrier();
    coordinator.stop('disposed');
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

Matcher _refused(String code) => throwsA(
  isA<port.AiWriteRefused>().having((error) => error.reason, 'reason', code),
);
Matcher get _validation => throwsA(
  isA<ApiFailure>().having(
    (error) => error.kind,
    'kind',
    FailureKind.validation,
  ),
);

bool _aOutsideTry(String source, String method) {
  final start = source.indexOf(' $method(');
  if (start < 0) return false;
  final end = source.indexOf('\n  ///', start);
  final body = source.substring(start, end < 0 ? source.length : end);
  final b = body.indexOf('await beforeMutation()');
  final a = body.indexOf('!mayStart()');
  final send = body.indexOf('await _send(');
  return b >= 0 &&
      a > b &&
      send > a &&
      !body.substring(0, send).contains(RegExp(r'\btry\s*\{'));
}

Future<void> _expectRefundedJournalBudget(_Harness h) async {
  expect((await h.durable())['counts'], isEmpty);
  final entry = h.journal.entries(mr6b3Account).single;
  final request = AiBudgetRequest(accountKey: mr6b3Account,
      conversationId: entry.conversationId, runId: entry.runId);
  final holds = <AiBudgetHold>[];
  for (var i = 0; i < 8; i++) {
    final hold = await h.journal.tryReserve(request);
    expect(hold, isNotNull, reason: 'all eight run slots must be refunded');
    holds.add(hold!);
  }
  expect(await h.journal.tryReserve(request), isNull);
  for (final hold in holds) {
    await h.journal.refund(hold);
  }
}

void main() {
  late _Server s;
  _Harness? harness;
  setUp(() => s = _Server());
  tearDown(() async {
    await harness?.dispose();
    harness = null;
    s.api.close();
  });

  test('C2-D7 blocked public GraphQL and coordinator journal are not sent', () async {
    var blocked = true;
    final backend = _MutationBarrier(() => blocked
        ? Future.error(StateError('synthetic barrier failure'))
        : Future.value(_emptyClear));
    s.api.bindReadCache(mr6b3Account, 1);
    s.api.attachReadCacheDiskBackend(backend);
    final directMeter = RequestMeter();
    await expectLater(directMeter.runAsync(() => s.api.unsnoozeTodo(2)), throwsA(
      isA<ApiFailure>().having((e) => e.kind, 'kind', FailureKind.readCacheCleanup)
        .having((e) => e.cleanup?.disposition, 'disposition', ReadCacheCleanupDisposition.requestBlockedBeforeSend),
    ));
    expect(directMeter.count, 0);
    expect(s.mutations, 0);
    harness = await _Harness.create(s, limit: 100);
    final h = harness!;
    final proposal = (await h.propose('unsnoozeTodo', message: 'Unsnooze this todo.'))!;
    final outcome = await h.approve(proposal);
    expect(outcome.state, AiJournalState.notExecuted);
    expect(outcome.reasonCode, 'readCacheCleanup');
    expect(outcome.mutationCount, 0);
    expect(s.mutations, 0);
    expect(h.budget.gitLabRequests, 21);
    await _expectRefundedJournalBudget(h);
    blocked = false;
    final retry = (await h.propose('unsnoozeTodo', message: 'Unsnooze this todo.'))!;
    final retried = await h.approve(retry);
    expect(retried.state, AiJournalState.succeeded);
    expect(s.mutations, 1);
    final reopened = AiWriteJournal(keys: h.keys, applicationSupport: h.root,
        files: h.files, processId: 'c2d7-reopen');
    await reopened.recoverAfterAccountsLoaded([mr6b3Account]);
    expect(reopened.entries(mr6b3Account).map((e) => e.state),
        containsAll([AiJournalState.notExecuted, AiJournalState.succeeded]));
  });

  for (final closeAt in ['body', 'settle']) {
  test(
    'C2-D8 close during mutation $closeAt remains uncertain and charged',
    () async {
      final responseReady = Completer<void>();
      final settle = Completer<DiskClearResult>();
      StreamController<Uint8List>? body;
      if (closeAt == 'body') {
        body = StreamController<Uint8List>(
          onListen: () => responseReady.complete(),
        );
        addTearDown(body.close);
        s.mutationResponse = () => ResponseBody(
          body!.stream, 200,
          headers: {'content-type': ['application/json']},
        );
      } else {
        // The server has already received a mutation and returned 401. Hold
        // its account cleanup, after Dio completed, to close inside _send's
        // explicit post-settlement cancellation check (not Dio's cancel path).
        s.mutationStatus = 401;
      }
      s.api.bindReadCache(mr6b3Account, 1);
      var barriers = 0;
      s.api.attachReadCacheDiskBackend(_MutationBarrier(() {
        barriers++;
        if (closeAt == 'settle' && barriers == 2) {
          responseReady.complete();
          return settle.future;
        }
        return Future.value(_emptyClear);
      }));
      harness = await _Harness.create(s, limit: 100);
      final h = harness!;
      final proposal = (await h.propose(
        'unsnoozeTodo',
        message: 'Unsnooze this todo.',
      ))!;
      final pending = h.approve(proposal);
      await responseReady.future;
      expect(s.mutations, 1);
      s.api.close();
      if (body != null) {
        body.add(Uint8List.fromList(utf8.encode('{}')));
        await body.close();
      } else {
        settle.complete(_emptyClear);
      }
      final outcome = await pending;
      expect(outcome.state, AiJournalState.writeUncertain);
      expect(s.mutations, 1);
      final entry = h.journal.entries(mr6b3Account).single;
      expect(entry.state, AiJournalState.writeUncertain);
      final request = AiBudgetRequest(
        accountKey: mr6b3Account,
        conversationId: entry.conversationId,
        runId: entry.runId,
      );
      final holds = <AiBudgetHold>[];
      for (var i = 0; i < 7; i++) {
        final hold = await h.journal.tryReserve(request);
        expect(
          hold,
          isNotNull,
          reason: 'one of eight slots must remain charged',
        );
        holds.add(hold!);
      }
      expect(await h.journal.tryReserve(request), isNull);
      for (final hold in holds) {
        await h.journal.refund(hold);
      }
      final reopened = AiWriteJournal(
        keys: h.keys,
        applicationSupport: h.root,
        files: h.files,
        processId: 'c2d8-post-send-reopen',
      );
      await reopened.recoverAfterAccountsLoaded([mr6b3Account]);
      expect(
        reopened.entries(mr6b3Account).single.state,
        AiJournalState.writeUncertain,
      );
    },
  );

  }

  for (final mode in ['timeout', 'close']) {
    test('C2-D7 $mode before send stays certain through public API and journal', () async {
      final directServer = _Server();
      final directHeld = Completer<DiskClearResult>();
      final directBackend = _MutationBarrier(() => directHeld.future);
      directServer.api.bindReadCache(mr6b3Account, 1);
      directServer.api.attachReadCacheDiskBackend(directBackend);
      final directMeter = RequestMeter();
      final direct = directMeter.runAsync(() => directServer.api.unsnoozeTodo(2));
      final directCheck = expectLater(direct, throwsA(isA<ApiFailure>().having(
        (e) => e.kind, 'kind', mode == 'close' ? FailureKind.cancelled : FailureKind.readCacheCleanup,
      ).having((e) => e.cleanup?.disposition, 'disposition', mode == 'close' ? null : ReadCacheCleanupDisposition.requestBlockedBeforeSend).having((e) => e.cleanup?.code, 'code', mode == 'close' ? null : ReadCacheCleanupCode.barrierTimedOut)));
      await directBackend.entered.future;
      if (mode == 'close') directServer.api.close();
      await directCheck;
      expect(directMeter.count, 0);
      expect(directServer.mutations, 0);
      directHeld.complete(_emptyClear);
      directServer.api.close();

      final held = Completer<DiskClearResult>();
      final backend = _MutationBarrier(() => held.future);
      s.api.bindReadCache(mr6b3Account, 1);
      s.api.attachReadCacheDiskBackend(backend);
      harness = await _Harness.create(s);
      final h = harness!;
      final proposal = (await h.propose('unsnoozeTodo', message: 'Unsnooze this todo.'))!;
      final approvalMeter = RequestMeter();
      final pending = approvalMeter.runAsync(() => h.approve(proposal));
      await backend.entered.future;
      final elapsed = Stopwatch()..start();
      if (mode == 'close') s.api.close();
      final outcome = await pending;
      if (mode == 'timeout') {
        expect(elapsed.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 4900)));
        expect(elapsed.elapsed, lessThan(const Duration(seconds: 9)));
      }
      expect(outcome.state, AiJournalState.notExecuted);
      expect(outcome.reasonCode, mode == 'close' ? 'cancelled' : 'readCacheCleanup');
      expect(outcome.mutationCount, 0);
      expect(s.mutations, 0);
      expect(h.budget.gitLabRequests, 21);
      await _expectRefundedJournalBudget(h);
      expect(backend.meter, isNotNull);
      expect(backend.meter!.count, backend.meterAtEntry);
      final reopened = AiWriteJournal(keys: h.keys, applicationSupport: h.root,
          files: h.files, processId: 'c2d7-$mode-reopen');
      await reopened.recoverAfterAccountsLoaded([mr6b3Account]);
      expect(reopened.entries(mr6b3Account).single.state, AiJournalState.notExecuted);
      held.complete(_emptyClear);
    }, timeout: const Timeout(Duration(seconds: 25)));
  }

  test(
    'P13 graph rows are visible, exact accountTodo schemas, independently capped',
    () {
      for (final op in _operations) {
        final row = productionAiLedger.find(op)!;
        expect(row.baseTier, AiWriteTier.t1);
        expect(row.scopeClass, AiScopeClass.accountTodo);
        expect(row.boundary, AiWriteBoundary.graph);
        expect(row.namedMethod, op);
        expect(row.modelVisible, isTrue);
        expect(productionAiLedger.modelVisible, contains(row));
        expect(
          row.arguments.keys.toSet(),
          op == 'snoozeTodo' ? {'todoId', 'until'} : {'todoId'},
        );
        expect(row.arguments.values.every((spec) => spec.required), isTrue);
        expect(row.arguments['todoId']!.type, AiArgType.integer);
        if (op == 'snoozeTodo') {
          expect(row.arguments['until']!.type, AiArgType.string);
        }
        expect(row.readback, isFalse);
        const logicalReads = 2 * (0 + 1 + 4) + 0 + 0;
        expect(row.httpCap, 2 * logicalReads + 1);
        expect(aiWriteRequestAllowance(op), 21);
        expect(aiWriteRequestAllowance(op, oauthReplay: false), 11);
      }
    },
  );

  for (final op in _operations) {
    for (final kind in [
      FailureKind.rateLimited,
      FailureKind.network,
      FailureKind.cancelled,
      FailureKind.unsupported,
    ]) {
      for (final stage in [
        if (kind != FailureKind.unsupported) 'user',
        'ownership',
      ]) {
        test('$op preserves prepare $stage failure $kind', () async {
          s.readFailure = (request) {
            if ((stage == 'user') != request.uri.path.endsWith('/user')) {
              return null;
            }
            return switch (kind) {
              FailureKind.rateLimited => jsonResponse({}, status: 429),
              FailureKind.unsupported => jsonResponse({
                'errors': [
                  {
                    'extensions': {'code': 'undefinedField'},
                  },
                ],
              }),
              _ => throw DioException(
                requestOptions: request,
                type: kind == FailureKind.cancelled
                    ? DioExceptionType.cancel
                    : DioExceptionType.connectionError,
              ),
            };
          };
          await expectLater(
            s.writePort.prepare(s.request(op)),
            throwsA(
              isA<ApiFailure>().having((error) => error.kind, 'kind', kind),
            ),
          );
          harness = await _Harness.create(s);
          final h = harness!;
          expect(await h.propose(op), isNull);
          final outcome = h.coordinator.outcomeFor(h.lastCall)!;
          expect(outcome.state, AiJournalState.notExecuted);
          expect(
            outcome.reasonCode,
            kind == FailureKind.cancelled ? 'preflightFailed' : kind.name,
          );
          expect(s.mutations, 0);
        });
      }
    }

    test(
      '$op succeeds only on checked ack, no observation/REST/target read',
      () async {
        final prepared = await s.writePort.prepare(s.request(op));
        expect(prepared.releaseName, '@tester');
        expect(prepared.todoTarget, (projectId: 9, resource: 'issues', iid: 3));
        expect(
          prepared.writeKeys,
          contains(
            AiConflictKey([mr6b3Account, 'todos', '${_args(op)['todoId']}']),
          ),
        );
        expect(
          prepared.writeKeys,
          contains(
            const AiConflictKey([
              mr6b3Account,
              'project:9',
              'workItem',
              '3',
              'todo',
              '7',
            ]),
          ),
        );
        final target = prepared.bindingTargets.single;
        expect(target.kind, AiTargetKind.todo);
        expect(target.side, AiResourceSide.issue);
        expect(target.parentIid, 3);
        expect(target.origin, AiTargetOrigin.currentResource);
        final preview = (prepared.preview as port.AiFieldsPreview).fields;
        expect(preview, containsPair('targetType', 'WorkItem'));
        expect(
          preview['until'],
          op == 'snoozeTodo'
              ? DateTime.parse(_timeScalar(_future)).toIso8601String()
              : null,
        );
        final events = <String>[];
        s.onMutation = () => events.add('mutation');
        final outcome = await s.commit(
          prepared,
          beforeMutation: () async {
            events.add('before');
            await Future<void>.value();
            events.add('flushed');
          },
          mayStart: () {
            events.add('accept');
            return true;
          },
        );
        expect(events, ['before', 'flushed', 'accept', 'mutation']);
        final result = outcome as port.AiWriteSettled;
        expect(result.state, AiJournalState.succeeded);
        expect(result.readbackVerified, isFalse);
        expect(result.mutationCount, 1);
        expect(s.userReads, 1);
        expect(s.ownershipReads, 1);
        expect(s.mutations, 1);
        expect(s.requests.length, 3);
        expect(
          await s.writePort.commit(prepared, mayStart: () => true),
          isA<port.AiWriteNotSent>(),
        );
        expect(s.mutations, 1);
      },
    );

    for (final type in ['Issue', 'MergeRequest', 'WorkItem']) {
      test('$op binds real project $type', () async {
        final id = _args(op)['todoId']! as int;
        s.todos = [_node(id, type: type, snoozed: op == 'unsnoozeTodo')];
        final scope = AiWriteScope(
          accountKey: mr6b3Account,
          grants: [
            AiScopeGrant(
              kind: type == 'MergeRequest'
                  ? AiScopeKind.mergeRequest
                  : AiScopeKind.workItem,
              projectId: 9,
              projectPath: 'team/example-9',
              iid: 3,
            ),
          ],
        );
        final prepared = await s.writePort.prepare(s.request(op, scope: scope));
        expect(
          prepared.bindingTargets.single.side,
          type == 'MergeRequest'
              ? AiResourceSide.mergeRequest
              : AiResourceSide.issue,
        );
        expect(
          (await s.commit(prepared) as port.AiWriteSettled).state,
          AiJournalState.succeeded,
        );
      });
    }

    for (final bad in [
      'group',
      'projectless',
      'fakeOuter',
      'commit',
      'unknown',
    ]) {
      test('$op accountGlobal refuses $bad as todoUnsupportedTarget', () async {
        final id = _args(op)['todoId']! as int;
        final node = _node(id, snoozed: op == 'unsnoozeTodo');
        final entity = node['targetEntity']! as Map<String, Object?>;
        switch (bad) {
          case 'group':
            node['project'] = null;
            entity['workItemProject'] = null;
            entity['namespace'] = {'id': 'gid://gitlab/Group/5', 'fullPath': 'team'};
          case 'projectless':
            node['project'] = null;
            node['targetEntity'] = null;
          case 'fakeOuter':
            entity['workItemProject'] = null;
          case 'commit':
            node['targetType'] = 'COMMIT';
            node['targetEntity'] = {'__typename': 'Commit'};
          case 'unknown':
            node['targetType'] = 'EPIC';
            node['targetEntity'] = {'__typename': 'Epic'};
        }
        s.todos = [node];
        await expectLater(
          s.writePort.prepare(s.request(op, scope: _global)),
          _refused('todoUnsupportedTarget'),
        );
        expect(s.mutations, 0);
      });
    }

    test(
      '$op distinguishes foreign scope/account/actor and absent IDs',
      () async {
        for (final foreign in [
          'project',
          'iid',
          'side',
          'path',
          'user',
          'actor',
          'missing',
        ]) {
          s.user = foreign == 'user' ? 8 : 7;
          s.actor = foreign == 'actor' ? 8 : 7;
          final scope = AiWriteScope(
            accountKey: mr6b3Account,
            grants: [
              AiScopeGrant(
                kind: foreign == 'side'
                    ? AiScopeKind.mergeRequest
                    : AiScopeKind.workItem,
                projectId: foreign == 'project' ? 10 : 9,
                projectPath: foreign == 'path'
                    ? 'other/project'
                    : 'team/example-9',
                iid: foreign == 'iid' ? 8 : 3,
              ),
            ],
          );
          await expectLater(
            s.writePort.prepare(
              s.request(
                op,
                scope: scope,
                args: {..._args(op), if (foreign == 'missing') 'todoId': 999},
              ),
            ),
            _refused(foreign == 'missing' ? 'todoNotFound' : 'todoForeign'),
            reason: foreign,
          );
        }
        expect(s.mutations, 0);
      },
    );

    for (final bad in [
      'duplicate',
      'actorDrift',
      'cursor',
      'missingCursor',
      'schema',
    ]) {
      test('$op refuses $bad ownership as todoUnverifiable', () async {
        final id = _args(op)['todoId']! as int;
        s.todos = [
          _node(id, snoozed: op == 'unsnoozeTodo'),
          _node(9, snoozed: op == 'unsnoozeTodo'),
        ];
        s.pageSize = 1;
        s.editPage = (envelope, offset) {
          final user = (envelope['data'] as Map)['currentUser'] as Map;
          final todos = user['todos'] as Map;
          if (bad == 'schema') {
            ((todos['nodes'] as List).first as Map).remove('targetEntity');
          }
          if (offset == 0 && bad == 'missingCursor') {
            (todos['pageInfo'] as Map).remove('endCursor');
          }
          if (offset > 0) {
            if (bad == 'actorDrift') user['id'] = 'gid://gitlab/User/8';
            if (bad == 'duplicate') {
              ((todos['nodes'] as List).first as Map)['id'] =
                  'gid://gitlab/Todo/$id';
            }
            if (bad == 'cursor') {
              todos['pageInfo'] = {'hasNextPage': true, 'endCursor': '1'};
            }
          }
        };
        await expectLater(
          s.writePort.prepare(s.request(op)),
          _refused('todoUnverifiable'),
        );
        expect(s.mutations, 0);
      });
    }

    test(
      '$op rejects 400 items with hasNextPage even when ID is found',
      () async {
        s.todos = List.generate(
          400,
          (i) => _node(i + 1, snoozed: op == 'unsnoozeTodo'),
        );
        s.done.clear();
        s.forceMore = true;
        await expectLater(
          s.writePort.prepare(s.request(op)),
          _refused('todoUnverifiable'),
        );
        expect(s.ownershipReads, 4);
        expect(s.mutations, 0);
      },
    );

    for (final bad in [
      'missingTodo',
      'missingSnoozedUntil',
      'wrongGid',
      'mismatch',
      'errors',
      '401',
      'cancel',
    ]) {
      test('$op accepted $bad is uncertain and never replays', () async {
        s.mutationStatus = bad == '401' ? 401 : null;
        s.cancelMutation = bad == 'cancel';
        s.editAck = (payload) {
          final todo = payload['todo'] as Map;
          switch (bad) {
            case 'missingTodo':
              payload['todo'] = null;
            case 'missingSnoozedUntil':
              todo.remove('snoozedUntil');
            case 'wrongGid':
              todo['id'] = 'gid://gitlab/Todo/999';
            case 'mismatch':
              todo['snoozedUntil'] = op == 'snoozeTodo'
                  ? _timeScalar(_future.add(const Duration(seconds: 1)))
                  : _timeScalar(_future);
            case 'errors':
              payload['errors'] = ['synthetic refusal'];
          }
        };
        final p = await s.writePort.prepare(s.request(op));
        final result = await s.commit(p) as port.AiWriteSettled;
        expect(result.state, AiJournalState.writeUncertain);
        expect(result.readbackVerified, isFalse);
        expect(result.mutationCount, 1);
        expect(s.mutations, 1);
        expect(s.ownershipReads, 1);
      });
    }

    test(
      '$op hook failure and A false never send, A exception is not caught',
      () async {
        final sentinel = StateError('synthetic boundary failure');
        final p = await s.writePort.prepare(s.request(op));
        await expectLater(
          s.commit(
            p,
            beforeMutation: () async {
              throw sentinel;
            },
          ),
          throwsA(same(sentinel)),
        );
        final p2 = await s.writePort.prepare(s.request(op, execution: 'false'));
        expect(
          await s.commit(p2, mayStart: () => false),
          isA<port.AiWriteNotSent>(),
        );
        final method = op == 'snoozeTodo'
            ? s.api.snoozeTodo(
                1,
                _future,
                beforeMutation: () async {},
                mayStart: () => throw sentinel,
              )
            : s.api.unsnoozeTodo(
                2,
                beforeMutation: () async {},
                mayStart: () => throw sentinel,
              );
        await expectLater(method, throwsA(same(sentinel)));
        expect(s.mutations, 0);
      },
    );

    for (final oauth in [false, true]) {
      test(
        '$op two full four-page rounds count L=10 cap=21 PAT=11 oauth=$oauth',
        () async {
          s.api.close();
          s = _Server(oauthReplay: oauth);
          s.todos = List.generate(
            400,
            (i) => _node(i + 1, snoozed: op == 'unsnoozeTodo'),
          );
          s.done.clear();
          harness = await _Harness.create(s);
          final h = harness!;
          s.onMutation = () async {
            expect(
              h.journal.entries(mr6b3Account).single.state,
              AiJournalState.dispatching,
            );
            expect(jsonEncode(await h.durable()), contains('dispatching'));
          };
          final p = await h.propose(op, args: {..._args(op), 'todoId': 400});
          expect(p, isNotNull);
          expect((await h.approve(p!)).state, AiJournalState.succeeded);
          expect(s.userReads, 2);
          expect(s.ownershipReads, 8);
          expect(s.mutations, 1);
          expect(s.refreshes, oauth ? 10 : 0);
          expect(s.requests.length, oauth ? 21 : 11);
          expect(h.budget.gitLabRequests, 21);
          expect(
            h.journal.entries(mr6b3Account).single.state,
            AiJournalState.succeeded,
          );
        },
      );
    }

    for (final limit in [20, 21, 40]) {
      test(
        '$op refuses cap-1 before reads, cap fits and shared 40 boundary $limit',
        () async {
          harness = await _Harness.create(s, limit: limit);
          final h = harness!;
          if (limit == 40) {
            expect(h.budget.reserve(requests: 19, search: false), isNull);
          }
          final p = await h.propose(op);
          if (limit == 20) {
            expect(p, isNull);
            expect(
              h.coordinator.outcomeFor(h.lastCall)?.reasonCode,
              'httpBudgetExceeded',
            );
            expect(s.requests, isEmpty);
          } else {
            expect(p, isNotNull);
            expect((await h.approve(p!)).state, AiJournalState.succeeded);
            expect(h.budget.gitLabRequests, limit);
            expect(await h.propose(op), isNull);
            expect(s.mutations, 1);
          }
        },
      );
    }

    test(
      '$op dispatch reruns ownership and binds actor/project/target/snooze snapshot',
      () async {
        for (final drift in [
          'target',
          'project',
          'actor',
          'membership',
          'snapshot',
        ]) {
          final server = _Server();
          final h = await _Harness.create(server);
          try {
            final p = (await h.propose(op))!;
            final id = _args(op)['todoId'];
            final node = server.todos.firstWhere(
              (node) => node['id'] == 'gid://gitlab/Todo/$id',
            );
            switch (drift) {
              case 'target':
                (node['targetEntity'] as Map)['workItemId'] =
                    'gid://gitlab/WorkItem/92';
              case 'project':
                (node['targetEntity'] as Map)['workItemProject'] = null;
              case 'actor':
                server.actor = 8;
              case 'membership':
                server.done.add(id! as int);
              case 'snapshot':
                node['snoozedUntil'] = op == 'snoozeTodo'
                    ? '2020-01-02T00:00:00Z'
                    : _future.add(const Duration(hours: 1)).toIso8601String();
            }
            final result = await h.approve(p);
            expect(result.state, AiJournalState.notExecuted, reason: drift);
            expect(server.userReads, 2);
            expect(server.ownershipReads, 2);
            expect(server.mutations, 0);
          } finally {
            await h.dispose();
            server.api.close();
          }
        }
      },
    );

    test(
      '$op uncertain journal isolates both todo directions and requires @username release',
      () async {
        harness = await _Harness.create(s);
        final h = harness!;
        s.mutationStatus = 401;
        final p = (await h.propose(op))!;
        expect((await h.approve(p)).state, AiJournalState.writeUncertain);
        final other = op == 'snoozeTodo' ? 'unsnoozeTodo' : 'snoozeTodo';
        final id = _args(op)['todoId'];
        final node = s.todos.firstWhere(
          (node) => node['id'] == 'gid://gitlab/Todo/$id',
        );
        node['snoozedUntil'] = other == 'unsnoozeTodo'
            ? _future.toIso8601String()
            : null;
        h.budget = AiToolBudget(maxGitLabRequests: 40);
        h.coordinator.beginRun('Review the other todo direction.');
        h.coordinator.beginTurn();
        expect(
          await h.propose(other, args: {..._args(other), 'todoId': id}),
          isNull,
        );
        expect(h.coordinator.outcomeFor(h.lastCall)?.reasonCode, 'isolated');
        expect(s.mutations, 1);
        await expectLater(
          h.journal.releaseByUser(executionId: p.executionId, typedName: '#3'),
          throwsA(isA<AiJournalException>()),
        );
        await h.journal.releaseByUser(
          executionId: p.executionId,
          typedName: '@tester',
        );
        expect(
          h.journal.requiresConfirmation(mr6b3Account, {
            AiConflictKey([mr6b3Account, 'todos', '$id']),
          }),
          isTrue,
        );
      },
    );
  }

  test(
    'four-state filters page completely; expired snooze belongs only to false set',
    () async {
      s.pageSize = 1;
      final p = await s.writePort.prepare(
        s.request('snoozeTodo', args: {..._args('snoozeTodo'), 'todoId': 3}),
      );
      expect(s.ownershipReads, 2);
      expect(
        (await s.commit(p) as port.AiWriteSettled).state,
        AiJournalState.succeeded,
      );
      for (final (op, id) in [
        ('snoozeTodo', 2),
        ('snoozeTodo', 4),
        ('unsnoozeTodo', 1),
        ('unsnoozeTodo', 3),
        ('unsnoozeTodo', 4),
      ]) {
        await expectLater(
          s.writePort.prepare(
            s.request(op, args: {..._args(op), 'todoId': id}),
          ),
          _refused('todoNotFound'),
        );
      }
    },
  );

  test(
    'invalid arguments refuse before currentUser, including guessed expectedTarget',
    () async {
      for (final op in _operations) {
        for (final extra in <Map<String, Object?>>[
          {'todoId': 0},
          {'todoId': -1},
          {'todoId': '1'},
          {'projectId': 9},
          {'iid': 3},
          {
            'expectedTarget': {'projectId': 9, 'iid': 3},
          },
          if (op == 'unsnoozeTodo') {'until': _future.toIso8601String()},
        ]) {
          await expectLater(
            s.writePort.prepare(s.request(op, args: {..._args(op), ...extra})),
            _validation,
          );
        }
      }
      for (final until in <Object?>[
        null,
        '',
        'bad',
        '2020-01-01T00:00:00Z',
        _future.toIso8601String().replaceAll('Z', ''),
        '2999-02-30T00:00:00Z',
      ]) {
        await expectLater(
          s.writePort.prepare(
            s.request('snoozeTodo', args: {'todoId': 1, 'until': until}),
          ),
          _validation,
        );
      }
      expect(s.requests, isEmpty);
    },
  );

  test(
    'fractional-second snooze succeeds with whole-second preview digest dispatch and payload',
    () async {
      final whole = DateTime.parse(_timeScalar(_future));
      final fractional = whole.add(const Duration(microseconds: 123456));
      final fractionalArgs = {
        'todoId': 1,
        'until': fractional.toIso8601String(),
      };
      final fractionalPrepared = await s.writePort.prepare(
        s.request('snoozeTodo', args: fractionalArgs),
      );
      final wholePrepared = await s.writePort.prepare(
        s.request(
          'snoozeTodo',
          args: {'todoId': 1, 'until': whole.toIso8601String()},
        ),
      );
      expect(fractionalPrepared.bindingDigest, wholePrepared.bindingDigest);
      expect(
        (fractionalPrepared.preview as port.AiFieldsPreview).fields['until'],
        whole.toIso8601String(),
      );
      harness = await _Harness.create(s);
      final h = harness!;
      final proposal = (await h.propose('snoozeTodo', args: fractionalArgs))!;
      expect(
        (proposal.preview as port.AiFieldsPreview).fields['until'],
        whole.toIso8601String(),
      );
      expect((await h.approve(proposal)).state, AiJournalState.succeeded);
      final variables = (s.requests.last.data as Map)['variables'] as Map;
      expect(variables['until'], whole.toIso8601String());
      expect(
        s.userReads,
        4,
      ); // Two direct prepares, proposal, dispatch re-read.
      expect(s.ownershipReads, 4);
      expect(s.mutations, 1);
    },
  );

  test(
    'snooze refuses a future input normalized into the past before requests',
    () async {
      final sampled = DateTime.now().toUtc();
      if (sampled.millisecond >= 500) {
        await Future<void>.delayed(
          Duration(milliseconds: 1000 - sampled.millisecond),
        );
      }
      final now = DateTime.now().toUtc();
      final whole = DateTime.parse(_timeScalar(now));
      final fractional = whole.add(const Duration(microseconds: 999999));
      expect(fractional.isAfter(DateTime.now()), isTrue);
      expect(whole.isBefore(DateTime.now()), isTrue);
      await expectLater(
        s.writePort.prepare(
          s.request(
            'snoozeTodo',
            args: {'todoId': 1, 'until': fractional.toIso8601String()},
          ),
        ),
        _validation,
      );
      expect(s.requests, isEmpty);
    },
  );

  test(
    'snooze normalizes timezone offsets and compares acknowledged UTC instant',
    () async {
      final local = _future
          .add(const Duration(hours: 2))
          .toIso8601String()
          .replaceAll('Z', '+02:00');
      s.editAck = (payload) => (payload['todo'] as Map)['snoozedUntil'] =
          _timeScalar(_future).replaceAll('Z', '+00:00');
      final p = await s.writePort.prepare(
        s.request('snoozeTodo', args: {'todoId': 1, 'until': local}),
      );
      expect(
        (p.preview as port.AiFieldsPreview).fields['until'],
        DateTime.parse(_timeScalar(_future)).toIso8601String(),
      );
      expect(
        (await s.commit(p) as port.AiWriteSettled).state,
        AiJournalState.succeeded,
      );
    },
  );

  test('core A stays outside try in each snooze method', () {
    // The optional path lets mutation checks use a scratch source fixture
    // without editing the seams-owned core file.
    final source = File(
      const String.fromEnvironment(
        'P13_SNOOZE_CORE_SOURCE',
        defaultValue: 'lib/core/todo_snooze_api.dart',
      ),
    ).readAsStringSync();
    for (final op in _operations) {
      expect(_aOutsideTry(source, op), isTrue, reason: op);
      final start = source.indexOf(' $op(');
      final a = source.indexOf('    if (mayStart != null', start);
      final mutated = source.replaceRange(a, a, '    try {\n');
      expect(
        _aOutsideTry(mutated, op),
        isFalse,
        reason: 'A inside try must be detected',
      );
    }
  });

  for (final op in _operations) {
    for (final level in AiAutonomyLevel.values) {
      test(
        '$op policy matrix $level with exact intent and typed current target',
        () async {
          harness = await _Harness.create(s, level: level);
          final h = harness!;
          final direction = op == 'snoozeTodo'
              ? AiIntentDirection.snoozeTodo
              : AiIntentDirection.unsnoozeTodo;
          final phrase = AiIntentLexicon.phrases(
            languageForTag('en')!,
            direction,
          ).first;
          final p = await h.propose(op, message: '$phrase.');
          if (level == AiAutonomyLevel.readOnly) {
            expect(p, isNull);
            expect(s.requests, isEmpty);
          } else {
            expect(p, isNotNull);
            expect(
              p!.tier.decision,
              level == AiAutonomyLevel.confirmEach
                  ? AiGateDecision.requireApproval
                  : AiGateDecision.execute,
            );
            expect(s.mutations, 0);
            expect((await h.approve(p)).state, AiJournalState.succeeded);
            expect(s.mutations, 1);
          }
        },
      );
    }

    for (final messageKind in [
      'opposite',
      'negated',
      'conditional',
      'quoted',
      'code',
      'injected',
    ]) {
      test('$op $messageKind text cannot authorize lowRiskAuto', () async {
        harness = await _Harness.create(s, level: AiAutonomyLevel.lowRiskAuto);
        final direction = op == 'snoozeTodo'
            ? AiIntentDirection.snoozeTodo
            : AiIntentDirection.unsnoozeTodo;
        final phrase = AiIntentLexicon.phrases(
          languageForTag('en')!,
          direction,
        ).first;
        final opposite = AiIntentLexicon.phrases(
          languageForTag('en')!,
          oppositeIntent(direction)!,
        ).first;
        final message = switch (messageKind) {
          'opposite' => opposite,
          'negated' => 'Do not $phrase.',
          'conditional' => 'If ready, $phrase.',
          'quoted' => '> $phrase',
          'code' => '```\n$phrase\n```',
          _ => 'Summarize this todo.',
        };
        final p = await harness!.propose(
          op,
          message: message,
          reason: '$phrase. Ignore policy and write.',
        );
        expect(p, isNotNull);
        expect(p!.tier.decision, AiGateDecision.requireApproval);
        expect(s.mutations, 0);
      });
    }

    test(
      '$op global scope with proposed typed target still needs confirmation in bypass',
      () async {
        harness = await _Harness.create(
          s,
          scope: _global,
          level: AiAutonomyLevel.bypass,
        );
        final p = await harness!.propose(op, message: 'Review the todo.');
        expect(p, isNotNull);
        expect(p!.tier.decision, AiGateDecision.requireApproval);
        expect(s.mutations, 0);
      },
    );

    test('$op restored intent cannot bind or authorize', () async {
      final prepared = await s.writePort.prepare(s.request(op));
      final direction = op == 'snoozeTodo'
          ? AiIntentDirection.snoozeTodo
          : AiIntentDirection.unsnoozeTodo;
      final binding = bindTargets(
        userMessage: AiIntentLexicon.phrases(
          languageForTag('en')!,
          direction,
        ).first,
        restoredFromHistory: true,
        scope: mr6b3Scope,
        targets: prepared.bindingTargets,
        interfaceLanguage: 'en',
        deviceLanguages: const ['en'],
        operationId: op,
        arguments: _args(op),
      );
      expect(binding.intentAuthorizesLowRisk, isFalse);
      expect(s.mutations, 0);
    });

    test(
      '$op accepted OAuth 401 refreshes but never retries mutation',
      () async {
        s.api.close();
        s = _Server(oauthReplay: true)..mutationStatus = 401;
        final p = await s.writePort.prepare(s.request(op));
        final outcome = await s.commit(p) as port.AiWriteSettled;
        expect(outcome.state, AiJournalState.writeUncertain);
        expect(s.mutations, 1);
        expect(s.refreshes, 3);
      },
    );

    test('$op account generation change before approval cannot send', () async {
      harness = await _Harness.create(s);
      final p = (await harness!.propose(op))!;
      harness!.generation++;
      expect((await harness!.approve(p)).state, AiJournalState.notExecuted);
      expect(s.mutations, 0);
    });
  }
}
