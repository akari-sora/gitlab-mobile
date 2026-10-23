import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';

const _account = 'https://example.com/gitlab#7';
const _scope = AiWriteScope(
  accountKey: _account,
  grants: [
    AiScopeGrant(
      kind: AiScopeKind.project,
      projectId: 9,
      projectPath: 'team/example-9',
    ),
  ],
);
const _timeout = Duration(seconds: 20);

const _resourceOps = <String>[
  'addAwardEmoji',
  'removeAwardEmoji',
  'setSubscribed',
  'createNote',
  'updateNote',
  'createTodo',
  'createDiscussion',
  'createDiscussionNote',
  'updateDiscussionNote',
  'setDiscussionResolved',
  'deleteNote',
  'deleteDiscussionNote',
];

Map<String, Object?> _validArgs(String operation) {
  final base = <String, Object?>{
    'projectId': 9,
    'resource': 'issues',
    'iid': 3,
  };
  switch (operation) {
    case 'addAwardEmoji':
      return {...base, 'name': 'thumbsup'};
    case 'removeAwardEmoji':
      return {...base, 'awardId': 8};
    case 'setSubscribed':
      return {...base, 'subscribed': true};
    case 'createNote':
      return {...base, 'body': 'synthetic body'};
    case 'updateNote':
      return {...base, 'noteId': 31, 'body': 'synthetic body'};
    case 'createTodo':
      return base;
    case 'createDiscussion':
      return {...base, 'body': 'synthetic body'};
    case 'createDiscussionNote':
      return {...base, 'discussionId': 'abc', 'body': 'synthetic body'};
    case 'updateDiscussionNote':
      return {
        ...base,
        'discussionId': 'abc',
        'noteId': 31,
        'body': 'synthetic body',
      };
    case 'setDiscussionResolved':
      return {...base, 'discussionId': 'abc', 'resolved': true};
    case 'deleteNote':
      return {...base, 'noteId': 8};
    case 'deleteDiscussionNote':
      return {...base, 'discussionId': 'abc', 'noteId': 8};
    default:
      throw StateError('unknown resource operation $operation');
  }
}

void main() {
  test('model schema closes resource to issues and merge_requests', () {
    final root = Directory.systemTemp.createTempSync('fix3-resource-enum-');
    addTearDown(() => root.deleteSync(recursive: true));
    final coordinator = _specsCoordinator(root);
    addTearDown(() => coordinator.stop());
    final byName = {
      for (final spec in coordinator.specs) spec.name: spec,
    };
    for (final operation in _resourceOps) {
      final spec = byName[operation];
      expect(spec, isNotNull, reason: operation);
      final properties = spec!.parameters['properties']! as Map;
      expect(
        properties['resource'],
        {'type': 'string', 'enum': ['issues', 'merge_requests']},
        reason: operation,
      );
    }
  });

  late _Fixture f;
  setUp(() async => f = await _Fixture.create());
  tearDown(() async => f.dispose());

  test('singular issue is rejected as invalidArguments without HTTP', () async {
    for (final operation in _resourceOps) {
      f.reset();
      final args = {..._validArgs(operation), 'resource': 'issue'};
      expect(await f.propose(operation, args), isNull, reason: operation);
      expect(
        f.coordinator.outcomeFor('call')?.reasonCode,
        'invalidArguments',
        reason: operation,
      );
      expect(f.freshnessReads, 0, reason: operation);
      expect(f.captured, isEmpty, reason: operation);
      expect(f.adapter.requests, isEmpty, reason: operation);
    }
  });

  test(
    'singular merge_request and snippets are rejected without HTTP',
    () async {
      for (final resource in ['merge_request', 'snippets']) {
        for (final operation in _resourceOps) {
          f.reset();
          final args = {..._validArgs(operation), 'resource': resource};
          expect(await f.propose(operation, args), isNull, reason: operation);
          expect(
            f.coordinator.outcomeFor('call')?.reasonCode,
            'invalidArguments',
            reason: operation,
          );
          expect(f.freshnessReads, 0, reason: operation);
          expect(f.captured, isEmpty, reason: operation);
          expect(f.adapter.requests, isEmpty, reason: operation);
        }
      }
    },
  );

  test('issues still passes argument validation', () async {
    for (final operation in _resourceOps) {
      f.reset();
      await f.propose(operation, _validArgs(operation));
      expect(f.captured, hasLength(1), reason: operation);
      expect(
        (f.captured.single.arguments['resource']),
        'issues',
        reason: operation,
      );
      expect(f.freshnessReads, 1, reason: operation);
      expect(
        f.coordinator.outcomeFor('call')?.reasonCode,
        isNot('invalidArguments'),
        reason: operation,
      );
      expect(f.adapter.requests, isEmpty, reason: operation);
    }
  });

  test('merge_requests still passes argument validation', () async {
    for (final operation in _resourceOps) {
      f.reset();
      final args = {..._validArgs(operation), 'resource': 'merge_requests'};
      await f.propose(operation, args);
      expect(f.captured, hasLength(1), reason: operation);
      expect(
        (f.captured.single.arguments['resource']),
        'merge_requests',
        reason: operation,
      );
      expect(f.freshnessReads, 1, reason: operation);
      expect(
        f.coordinator.outcomeFor('call')?.reasonCode,
        isNot('invalidArguments'),
        reason: operation,
      );
      expect(f.adapter.requests, isEmpty, reason: operation);
    }
  });

  test('AiArgSpec enumValues requires a string type', () {
    expect(
      () => AiArgSpec(AiArgType.integer, enumValues: const ['issues']),
      throwsA(isA<AssertionError>()),
    );
    expect(
      () => AiArgSpec(AiArgType.object, enumValues: const ['issues']),
      throwsA(isA<AssertionError>()),
    );
    expect(
      const AiArgSpec(AiArgType.string, enumValues: ['issues']),
      isA<AiArgSpec>(),
    );
    expect(const AiArgSpec(AiArgType.integer), isA<AiArgSpec>());
  });
}

PolicyAiWriteCoordinator _specsCoordinator(Directory root) {
  return PolicyAiWriteCoordinator(
    snapshot: () => AiWritePolicySnapshot(
      scope: _scope,
      level: AiAutonomyLevel.confirmEach,
      ceiling: AiAutonomyLevel.bypass,
      consentHash: 'fix3-consent',
      writePolicyRevision: 1,
      scopeRevision: 1,
      sessionGeneration: 7,
      consentValid: true,
      alive: true,
      appInForeground: true,
      clientMayStart: true,
    ),
    createPort: () => throw StateError('no writes in this test'),
    journal: AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
    ),
    conversationId: 'fix3-conversation',
    budget: () => AiToolBudget(maxGitLabRequests: 40),
    readFreshness: (_) async => throw StateError('no reads in this test'),
    placeholders: UploadPlaceholderTable(
      instance: GitLabInstance.parse('https://example.com'),
    ),
    knownSecrets: () => const {},
    safeDisplay: (value) => value,
  );
}

final class _Fixture implements port.AiGitLabWritePort {
  _Fixture._(this.root, this.journal, this.adapter, this.api);

  static Future<_Fixture> create() async {
    final root = Directory.systemTemp.createTempSync('fix3-resource-enum-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'fix3-resource-enum-test',
    );
    await journal.recoverAfterAccountsLoaded([_account]);
    await journal.ensureInitialized(_account);
    late final _Fixture fixture;
    final adapter = FakeAdapter((request) {
      throw StateError(
        'unexpected HTTP ${request.method} ${request.uri}',
      );
    });
    final api = testApi(adapter);
    fixture = _Fixture._(root, journal, adapter, api);
    fixture.reset();
    return fixture;
  }

  final Directory root;
  final AiWriteJournal journal;
  final FakeAdapter adapter;
  final GitLabApi api;
  PolicyAiWriteCoordinator? _coordinator;
  PolicyAiWriteCoordinator get coordinator => _coordinator!;
  late port.GitLabAiWritePort delegate;
  final captured = <port.AiWriteRequest>[];
  int freshnessReads = 0;
  late AiToolBudget budget;

  void reset() {
    _coordinator?.stop('superseded');
    captured.clear();
    freshnessReads = 0;
    adapter.requests.clear();
    budget = AiToolBudget(maxGitLabRequests: 40);
    delegate = port.GitLabAiWritePort(api, accountKey: _account);
    _coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: _scope,
        level: AiAutonomyLevel.confirmEach,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'synthetic-consent',
        writePolicyRevision: 1,
        scopeRevision: 1,
        sessionGeneration: 7,
        appInForeground: true,
      ),
      createPort: () => this,
      journal: journal,
      conversationId: 'fix3-conversation',
      budget: () => budget,
      readFreshness: (_) async {
        freshnessReads++;
        return const AiWriteFreshness(
          updatedAt: '2026-10-23T00:00:00Z',
          visibilityUnreadable: false,
        );
      },
      placeholders: UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: productionAiLedger,
    );
    _coordinator!.beginRun('Apply the requested change in team/example-9');
    _coordinator!.beginTurn();
  }

  Future<AiWriteProposal?> propose(
    String operation,
    Map<String, Object?> args,
  ) => coordinator
      .propose(
        AiToolCall(
          id: 'call',
          name: operation,
          arguments: {...args, 'reason': 'Synthetic fix3 request'},
        ),
      )
      .timeout(_timeout);

  @override
  Future<port.AiWritePrepared> prepare(port.AiWriteRequest request) async {
    captured.add(request);
    throw StateError(
      'Capture boundary; no family implementation in packet fix3',
    );
  }

  @override
  Future<port.AiWriteOutcome> commit(
    port.AiWritePrepared prepared, {
    required bool Function() mayStart,
  }) {
    return delegate.commit(prepared, mayStart: mayStart);
  }

  Future<void> dispose() async {
    _coordinator?.stop('disposed');
    api.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}
