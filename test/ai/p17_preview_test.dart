import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/exact_edit.dart' as exact;
import 'package:gitlab_mobile/core/ai/redaction.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/instance.dart';
import 'package:gitlab_mobile/features/ai/ai_journal_key_store.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import 'mr6b2_merge_port_test.dart' as merge;
import 'fx_coord_support.dart';
import 'p6_support.dart';
import '../support/fake_adapter.dart';

const _known = 'opaque-known-secret';
const _pattern = 'glpat-ABCDEFGHIJKLMNOPQRST';
const _displayPathSecret = 'display-only-sentinel';
const _displayPattern = 'DISPLAY_PATTERN_SENTINEL';
const _timeout = Duration(seconds: 20);

void main() {
  test('preview copier redacts every string in all seven variants', () {
    final redactor = Redactor(secrets: const _Secrets([_known]));
    String safe(String value) => redactor.redactSource(value).text;
    String secret(String label) => '$label $_known $_pattern';

    final fields =
        redactAiWritePreview(
              port.AiFieldsPreview({
                secret('top-key'): {
                  secret('nested-key'): [
                    secret('nested-value'),
                    17,
                    true,
                    null,
                  ],
                  9: secret('non-string-key-value'),
                },
              }),
              safe,
            )
            as port.AiFieldsPreview;
    _expectAllStringsRedacted(fields);
    final nested = fields.fields.values.single as Map<Object?, Object?>;
    expect(nested[9], contains('[REDACTED]'));
    final nestedList = nested.values.first as List<Object?>;
    expect(nestedList.sublist(1), [17, true, null]);

    final diff =
        redactAiWritePreview(
              port.AiDiffPreview(
                path: secret('path'),
                ref: secret('ref'),
                lines: [
                  port.AiDiffLine(
                    kind: port.AiDiffLineKind.context,
                    text: secret('line'),
                    oldLine: 3,
                    newLine: 4,
                  ),
                ],
                newFile: true,
                preexistingSecretHits: 2,
                ciPath: true,
              ),
              safe,
              preexistingSecretHits: 7,
            )
            as port.AiDiffPreview;
    _expectAllStringsRedacted(diff);
    expect(diff.newFile, isTrue);
    expect(diff.preexistingSecretHits, 7);
    expect(diff.ciPath, isTrue);
    expect(diff.lines.single.kind, port.AiDiffLineKind.context);
    expect(diff.lines.single.oldLine, 3);
    expect(diff.lines.single.newLine, 4);

    final mergePreview =
        redactAiWritePreview(
              port.AiMergePreview(
                sourceBranch: secret('source'),
                targetBranch: secret('target'),
                shortSha: secret('sha'),
                pathCount: 4,
                squash: true,
                removeSourceBranch: true,
                autoMerge: true,
                ciPaths: [secret('ci')],
                closingIssues: const [
                  port.AiClosingIssue(projectId: 9, iid: 3, outOfScope: true),
                ],
                headMovedCommits: [secret('commit')],
              ),
              safe,
            )
            as port.AiMergePreview;
    _expectAllStringsRedacted(mergePreview);
    expect(mergePreview.pathCount, 4);
    expect(mergePreview.squash, isTrue);
    expect(mergePreview.removeSourceBranch, isTrue);
    expect(mergePreview.autoMerge, isTrue);
    expect(mergePreview.closingIssues.single.projectId, 9);
    expect(mergePreview.closingIssues.single.iid, 3);
    expect(mergePreview.closingIssues.single.outOfScope, isTrue);

    final pipeline =
        redactAiWritePreview(
              port.AiPipelinePreview(
                ref: secret('pipeline-ref'),
                pipelineId: 11,
                jobId: 12,
                jobName: secret('job'),
                stage: secret('stage'),
                environment: secret('environment'),
                scheduleVariableNames: [secret('scheduled-variable')],
                scheduleParamsUnreadable: true,
                newVariableNames: [secret('new-variable')],
              ),
              safe,
            )
            as port.AiPipelinePreview;
    _expectAllStringsRedacted(pipeline);
    expect(pipeline.pipelineId, 11);
    expect(pipeline.jobId, 12);
    expect(pipeline.scheduleParamsUnreadable, isTrue);

    final drafts =
        redactAiWritePreview(
              port.AiDraftPublishPreview(
                drafts: [
                  port.AiDraftPreview(
                    id: 13,
                    body: secret('draft'),
                    createdInSegment: true,
                  ),
                ],
              ),
              safe,
            )
            as port.AiDraftPublishPreview;
    _expectAllStringsRedacted(drafts);
    expect(drafts.drafts.single.id, 13);
    expect(drafts.drafts.single.createdInSegment, isTrue);

    final delete =
        redactAiWritePreview(
              port.AiDeletePreview(
                targetName: secret('delete-target'),
                path: secret('delete-path'),
                ref: secret('delete-ref'),
                count: 14,
                hasMore: true,
              ),
              safe,
            )
            as port.AiDeletePreview;
    _expectAllStringsRedacted(delete);
    expect(delete.count, 14);
    expect(delete.hasMore, isTrue);

    final cancel =
        redactAiWritePreview(
              port.AiCancelAutoMergePreview(
                iid: 15,
                sourceBranch: secret('cancel-source'),
                targetBranch: secret('cancel-target'),
                mayLackPermission: true,
              ),
              safe,
            )
            as port.AiCancelAutoMergePreview;
    _expectAllStringsRedacted(cancel);
    expect(cancel.iid, 15);
    expect(cancel.mayLackPermission, isTrue);
  });

  test(
    'coordinator masks unchanged diff secrets and path but writes exact bytes',
    () async {
      final server = P6Server();
      const original = '$_known\n$_pattern\nalpha\n';
      const expected = '$_known\n$_pattern\nbeta\n';
      server.contents[p6L] = original;
      final harness = await _FilePreviewHarness.create(server);
      addTearDown(harness.dispose);

      final proposal = (await harness.propose())!;
      final preview = proposal.preview as port.AiDiffPreview;
      expect(preview.path, isNot(contains(_displayPathSecret)));
      expect(preview.path, contains('[REDACTED]'));
      expect(preview.preexistingSecretHits, 2);
      expect(
        preview.lines.map((line) => line.text).join('\n'),
        isNot(anyOf(contains(_known), contains(_pattern))),
      );
      expect(
        preview.lines.map((line) => line.text).join('\n'),
        contains('[REDACTED]'),
      );
      expect(server.contents[p6L], original, reason: 'raw source is untouched');

      final outcome = await harness.coordinator
          .approve(proposal)
          .timeout(_timeout);
      expect(outcome.state, AiJournalState.succeeded);
      expect(server.mutations, 1);
      final body = server.writes.single.data! as Map<String, dynamic>;
      expect(body['content'], expected);
      expect(server.contents[p6NextL], expected);
    },
  );

  test(
    'coordinator masks draft bodies with the live display redactor',
    () async {
      final harness = await _DraftPreviewHarness.create();
      addTearDown(harness.dispose);
      harness.server.drafts = [
        {'id': 8, 'note': '$_displayPathSecret $_displayPattern'},
      ];

      final proposal = (await harness.propose())!;
      final preview = proposal.preview as port.AiDraftPublishPreview;
      expect(preview.drafts.single.body, '[REDACTED] [REDACTED]');
      expect(
        harness.server.drafts.single['note'],
        '$_displayPathSecret $_displayPattern',
      );
      expect(harness.server.writes, isEmpty);
    },
  );

  test(
    'edited fields preview is masked while approval writes exact raw bytes',
    () async {
      final server = _FieldsServer();
      final harness = await _FieldsPreviewHarness.create(server);
      addTearDown(harness.dispose);

      final proposal = (await harness.propose())!;
      const edited = 'approved $_displayPathSecret';
      final edit = await harness.coordinator
          .approve(proposal, editedText: edited)
          .timeout(_timeout);

      expect(edit.reasonCode, 'approvalRequired');
      expect(server.mutations, 0);
      final preview = proposal.preview as port.AiFieldsPreview;
      expect(_previewStrings(preview), isNot(contains(edited)));
      expect(_previewStrings(preview), contains('approved [REDACTED]'));
      expect(proposal.fields['body'], 'approved [REDACTED]');

      final outcome = await harness.coordinator
          .approve(proposal)
          .timeout(_timeout);
      expect(outcome.state, AiJournalState.succeeded);
      expect(server.mutations, 1);
      expect(server.body, edited);
    },
  );
}

void _expectAllStringsRedacted(port.AiWritePreview preview) {
  final strings = _previewStrings(preview).toList();
  expect(strings, isNotEmpty);
  for (final value in strings) {
    expect(value, isNot(contains(_known)), reason: value);
    expect(value, isNot(contains(_pattern)), reason: value);
    expect(value, contains('[REDACTED]'), reason: value);
  }
}

Iterable<String> _values(Object? value) sync* {
  if (value is String) {
    yield value;
  } else if (value is List<Object?>) {
    for (final child in value) {
      yield* _values(child);
    }
  } else if (value is Map<Object?, Object?>) {
    for (final entry in value.entries) {
      yield* _values(entry.key);
      yield* _values(entry.value);
    }
  }
}

Iterable<String> _previewStrings(port.AiWritePreview preview) sync* {
  switch (preview) {
    case port.AiFieldsPreview(:final fields):
      yield* _values(fields);
    case port.AiDiffPreview(:final path, :final ref, :final lines):
      yield path;
      yield ref;
      for (final line in lines) {
        yield line.text;
      }
    case port.AiMergePreview(
      :final sourceBranch,
      :final targetBranch,
      :final shortSha,
      :final ciPaths,
      :final headMovedCommits,
    ):
      yield sourceBranch;
      yield targetBranch;
      yield shortSha;
      yield* ciPaths;
      yield* headMovedCommits;
    case port.AiPipelinePreview(
      :final ref,
      :final jobName,
      :final stage,
      :final environment,
      :final scheduleVariableNames,
      :final newVariableNames,
    ):
      yield ref;
      if (jobName != null) yield jobName;
      if (stage != null) yield stage;
      if (environment != null) yield environment;
      yield* scheduleVariableNames;
      yield* newVariableNames;
    case port.AiDraftPublishPreview(:final drafts):
      for (final draft in drafts) {
        yield draft.body;
      }
    case port.AiDeletePreview(:final targetName, :final path, :final ref):
      yield targetName;
      if (path != null) yield path;
      if (ref != null) yield ref;
    case port.AiCancelAutoMergePreview(
      :final sourceBranch,
      :final targetBranch,
    ):
      yield sourceBranch;
      yield targetBranch;
  }
}

final class _Secrets implements KnownSecretsSource {
  const _Secrets(this.values);
  final List<String> values;
  @override
  Iterable<String> get current => values;
}

final class _FilePreviewHarness {
  _FilePreviewHarness(this.server, this.root, this.journal, this.budget);

  static Future<_FilePreviewHarness> create(P6Server server) async {
    final root = Directory.systemTemp.createTempSync('p17-preview-file-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'p17-preview-file',
    );
    await journal.recoverAfterAccountsLoaded([p6Account]);
    await journal.ensureInitialized(p6Account);
    final budget = AiToolBudget(maxGitLabRequests: 40);
    final harness = _FilePreviewHarness(server, root, journal, budget);
    final displayRedactor = Redactor(
      secrets: const _Secrets([_known, _displayPathSecret]),
    );
    harness.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => const AiWritePolicySnapshot(
        scope: p6Scope,
        level: AiAutonomyLevel.confirmEach,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'p17-preview',
        writePolicyRevision: 2,
        scopeRevision: 1,
        sessionGeneration: 7,
      ),
      createPort: () => server.writePort,
      journal: journal,
      conversationId: 'p17-preview-file',
      budget: () => budget,
      readFreshness: (_) async =>
          const AiWriteFreshness(visibilityUnreadable: false),
      placeholders: text.UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => const {_known},
      safeDisplay: (value) => displayRedactor.redactSource(value).text,
      ledger: const P6Ledger(),
      checkFragmentsWithCount: exact.checkFragments,
    );
    harness.coordinator.beginRun(
      'Change `work` `src/$_displayPathSecret.txt` in team/example-9',
    );
    harness.coordinator.beginTurn();
    return harness;
  }

  final P6Server server;
  final Directory root;
  final AiWriteJournal journal;
  final AiToolBudget budget;
  late final PolicyAiWriteCoordinator coordinator;

  Future<AiWriteProposal?> propose() => coordinator
      .propose(
        AiToolCall(
          id: 'p17-file',
          name: 'edit_file',
          arguments: {
            ...p6Args('edit_file', path: 'src/$_displayPathSecret.txt'),
            'reason': 'synthetic preview test',
          },
        ),
      )
      .timeout(_timeout);

  void dispose() {
    coordinator.stop('testEnd');
    server.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

final class _DraftPreviewHarness {
  _DraftPreviewHarness(this.server, this.root, this.journal, this.budget);

  static Future<_DraftPreviewHarness> create() async {
    final server = merge.Server();
    final root = Directory.systemTemp.createTempSync('p17-preview-draft-');
    final journal = AiWriteJournal(
      keys: MemoryAiJournalKeyStore(),
      applicationSupport: root,
      processId: 'p17-preview-draft',
    );
    await journal.recoverAfterAccountsLoaded([merge.account]);
    await journal.ensureInitialized(merge.account);
    final budget = AiToolBudget(maxGitLabRequests: 80);
    final harness = _DraftPreviewHarness(server, root, journal, budget);
    final displayRedactor = Redactor(
      secrets: const _Secrets([_displayPathSecret]),
      patterns: const [
        RedactionPattern('display-test', r'DISPLAY_PATTERN_[A-Z]+'),
      ],
    );
    harness.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => const AiWritePolicySnapshot(
        scope: merge.scope,
        level: AiAutonomyLevel.confirmEach,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'p17-preview',
        writePolicyRevision: 2,
        scopeRevision: 1,
        sessionGeneration: 7,
      ),
      createPort: () => server.port,
      journal: journal,
      conversationId: 'p17-preview-draft',
      budget: () => budget,
      readFreshness: (_) async =>
          const AiWriteFreshness(visibilityUnreadable: false),
      placeholders: text.UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => displayRedactor.redactSource(value).text,
      ledger: const _MergeLedger(),
    );
    return harness;
  }

  final merge.Server server;
  final Directory root;
  final AiWriteJournal journal;
  final AiToolBudget budget;
  late final PolicyAiWriteCoordinator coordinator;

  Future<AiWriteProposal?> propose() {
    coordinator.beginRun('Publish drafts for !3 in team/app');
    coordinator.beginTurn();
    return coordinator
        .propose(
          AiToolCall(
            id: 'p17-draft',
            name: 'publishDraftNotes',
            arguments: {'projectId': 9, 'iid': 3, 'reason': 'publish drafts'},
          ),
        )
        .timeout(_timeout);
  }

  void dispose() {
    coordinator.stop('testEnd');
    server.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

final class _FieldsPreviewHarness {
  _FieldsPreviewHarness(this.base, this.server);

  static Future<_FieldsPreviewHarness> create(_FieldsServer server) async {
    final base = await CoordHarness.create(responder: server.respond);
    base.coordinator.stop('replaceForPreviewTest');
    final displayRedactor = Redactor(
      secrets: const _Secrets([_displayPathSecret]),
    );
    base.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => const AiWritePolicySnapshot(
        scope: coordScope,
        level: AiAutonomyLevel.confirmEach,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'p17-preview',
        writePolicyRevision: 2,
        scopeRevision: 1,
        sessionGeneration: 7,
      ),
      createPort: () =>
          port.GitLabAiWritePort(base.api, accountKey: coordAccount),
      journal: base.journal,
      conversationId: 'p17-preview-fields',
      budget: () => base.budget,
      readFreshness: (_) async => const AiWriteFreshness(
        updatedAt: '2026-10-23T00:00:00Z',
        visibilityUnreadable: false,
      ),
      placeholders: text.UploadPlaceholderTable(
        instance: GitLabInstance.parse('https://example.com/gitlab'),
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => displayRedactor.redactSource(value).text,
    );
    return _FieldsPreviewHarness(base, server);
  }

  final CoordHarness base;
  final _FieldsServer server;

  PolicyAiWriteCoordinator get coordinator => base.coordinator;

  Future<AiWriteProposal?> propose() {
    base.newRun('Comment on #3 in team/example-9');
    return coordinator
        .propose(coordNoteCall('p17-fields', body: 'before edit'))
        .timeout(_timeout);
  }

  Future<void> dispose() => base.dispose();
}

final class _FieldsServer {
  String? body;
  int mutations = 0;

  ResponseBody respond(RequestOptions request) {
    final path = request.uri.path;
    if (request.method == 'POST' &&
        path.endsWith('/projects/9/issues/3/notes')) {
      mutations++;
      body = (request.data! as Map<String, dynamic>)['body']! as String;
      return jsonResponse({'id': 31, 'body': body}, status: 201);
    }
    if (request.method == 'GET' && path.endsWith('/user')) {
      return jsonResponse({'id': 7, 'username': 'tester'});
    }
    if (request.method == 'GET' && path.endsWith('/projects/9')) {
      return jsonResponse(projectJson(9));
    }
    if (request.method == 'GET' && path.endsWith('/projects/9/issues/3')) {
      return jsonResponse({'id': 30, 'iid': 3, 'project_id': 9});
    }
    if (request.method == 'GET' &&
        path.endsWith('/projects/9/issues/3/notes/31')) {
      return jsonResponse({'id': 31, 'body': body});
    }
    throw StateError('Unexpected request: ${request.method} ${request.uri}');
  }
}

final class _MergeLedger implements AiCapabilityLedger {
  const _MergeLedger();

  @override
  AiCapability? find(String operationId) {
    final row = productionAiLedger.find(operationId);
    if (row == null || !aiMergeRows.contains(row)) return null;
    return AiCapability(
      operationId: row.operationId,
      namedMethod: row.namedMethod,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      modelVisible: true,
      httpCap: row.httpCap,
      readback: row.readback,
      arguments: row.arguments,
    );
  }

  @override
  List<AiCapability> get modelVisible => [
    for (final row in aiMergeRows) find(row.operationId)!,
  ];
}
