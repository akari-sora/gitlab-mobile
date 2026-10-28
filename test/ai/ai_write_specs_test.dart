import 'release_policy_support.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart';
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

const _account = 'https://example.com#7';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('ai-write-specs-'));
  tearDown(() => root.deleteSync(recursive: true));

  PolicyAiWriteCoordinator coordinator(List<AiScopeGrant> grants) =>
      PolicyAiWriteCoordinator(
        releasePolicy: fixtureReleasePolicy,
        snapshot: () => AiWritePolicySnapshot(
          scope: AiWriteScope(accountKey: _account, grants: grants),
          level: AiAutonomyLevel.confirmEach,
          ceiling: AiAutonomyLevel.bypass,
          consentHash: 'consent-v2',
          writePolicyRevision: 1,
          scopeRevision: 1,
          sessionGeneration: 1,
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
        conversationId: 'conversation-1',
        budget: () => AiToolBudget(maxGitLabRequests: 40),
        readFreshness: (_) async => throw StateError('no reads in this test'),
        placeholders: UploadPlaceholderTable(
          instance: GitLabInstance.parse('https://example.com'),
        ),
        knownSecrets: () => const {},
        safeDisplay: (value) => value,
      );

  test('write tools name the project ids the conversation covers', () {
    final specs = coordinator(const [
      AiScopeGrant(
        kind: AiScopeKind.workItem,
        projectId: 42,
        projectPath: 'group/app',
        iid: 11,
      ),
    ]).specs;
    expect(specs, isNotEmpty);
    for (final spec in specs) {
      final properties = spec.parameters['properties']! as Map<String, Object?>;
      if (properties['projectId'] case final Map<String, Object?> projectId) {
        expect(projectId['enum'], [42], reason: spec.name);
      }
      expect(
        spec.description,
        endsWith(' In scope: issue #11 in project 42 (group/app).'),
        reason: spec.name,
      );
    }
    expect(
      specs.where(
        (spec) => (spec.parameters['properties']! as Map<String, Object?>)
            .containsKey('projectId'),
      ),
      isNotEmpty,
    );
  });

  test('a merge request scope is described as one', () {
    final specs = coordinator(const [
      AiScopeGrant(kind: AiScopeKind.mergeRequest, projectId: 5, iid: 3),
    ]).specs;
    expect(
      specs.first.description,
      endsWith(' In scope: merge request !3 in project 5.'),
    );
  });
}
