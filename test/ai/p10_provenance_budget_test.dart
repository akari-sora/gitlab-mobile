import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/tools/write_tier.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/gitlab_api.dart';
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

  for (final op in [
    'createSnippet',
    'updateSnippetMetadata',
    'updateSnippet',
    'updateSnippetFiles',
    'deleteSnippetFile',
    'deleteSnippet',
  ]) {
    test('P10 $op exact worst-case OAuth request count fits row cap', () async {
      s.close();
      s = P10Server(
        oauthReplay: true,
        initialContents: switch (op) {
          'updateSnippetFiles' || 'deleteSnippetFile' => {'b.txt': 'alpha\n'},
          'deleteSnippet' => {'b.txt': 'b', 'c.txt': 'c', 'd.txt': 'd'},
          _ => {},
        },
      );
      h = await P10Coordinator.create(s);
      final p = await h!.propose(
        op,
        args: op == 'updateSnippetFiles'
            ? {
                'projectId': 9,
                'snippetId': 12,
                'actions': [
                  for (final path in ['a.txt', 'b.txt'])
                    {
                      'action': 'update',
                      'file_path': path,
                      'edits': [
                        {'old': 'alpha', 'new': 'beta'},
                      ],
                    },
                ],
              }
            : null,
      );
      expect(p, isNotNull);
      final result = await h!.coordinator.approve(
        p!,
        typedName: p.tier.typedName,
      );
      expect(result.state, AiJournalState.succeeded);
      expect(s.writes.length, 1);
      final gitlabRequests = s.adapter.requests.where(
        (r) => !r.uri.path.endsWith('/oauth/token'),
      );
      final cap = productionAiLedger.find(op)!.httpCap;
      expect(gitlabRequests.length, cap);
      expect(s.refreshes, (cap - 1) ~/ 2);
      expect(gitlabRequests.where((r) => r.method == 'GET').length, cap - 1);
      expect(cap, lessThanOrEqualTo(40));
      expect(h!.budget.gitLabRequests, cap);
    });
  }

  Future<text.AiFieldProvenance> freshnessHarness({
    int snippet = 12,
    bool complete = true,
  }) async {
    final source = text.AiFieldProvenance(
      resourceKey: text.AiConflictKey('project:9/snippet:$snippet'),
      fieldName: text.AiWritableField.snippetDescription,
      completeValue: complete,
      projectId: 9,
      projectFullPath: 'team/example-9',
      resourceWeb: s.api.instance.projectWeb(
        'team/example-9/-/snippets/$snippet',
      ),
    );
    h = await P10Coordinator.create(
      s,
      level: AiAutonomyLevel.bypass,
      readFreshness: (_) async {
        await s.api.record(['projects', '9']);
        return AiWriteFreshness(
          visibilityUnreadable: false,
          currentFields: {'description': s.record['description']! as String},
          provenance: {'description': source},
        );
      },
    );
    return source;
  }

  const original =
      'before ![shot](/uploads/0123456789abcdef0123456789abcdef/a.png) after';
  test(
    'P10 description restores its own upload and keeps exact class B text',
    () async {
      s.record['description'] = original;
      final source = await freshnessHarness();
      final display = h!.placeholders.redactOutgoing(original, field: source);
      expect(display, contains('[[upload:u-1]]'));
      const suffix = '\r\n/merge\n@param\n@decorator';
      final p = await h!.propose(
        'updateSnippetMetadata',
        args: {
          'projectId': 9,
          'snippetId': 12,
          'fields': {'description': '$display$suffix'},
        },
      );
      expect(p, isNotNull);
      expect((await h!.coordinator.approve(p!)).successful, isTrue);
      expect((s.writes.single.data! as Map)['description'], '$original$suffix');
      expect(s.record['description'], '$original$suffix');
    },
  );

  test(
    'P10 description card edits invalidate approval and can be approved again',
    () async {
      await freshnessHarness();
      final p = await h!.propose(
        'updateSnippetMetadata',
        args: {
          'projectId': 9,
          'snippetId': 12,
          'fields': {'description': 'first'},
        },
      );
      expect(p, isNotNull);
      final edited = await h!.coordinator.approve(
        p!,
        editedText: 'second\n/merge',
      );
      expect(edited.reasonCode, 'approvalRequired');
      expect(s.writes, isEmpty);
      expect(p.fields['description'], 'second\n/merge');
      expect((await h!.coordinator.approve(p)).successful, isTrue);
      expect((s.writes.single.data! as Map)['description'], 'second\n/merge');
    },
  );

  for (final destination in ['otherSnippet', 'newSnippet', 'codeFile']) {
    test('P10 description upload cannot restore into $destination', () async {
      s.record['description'] = original;
      final destinationSource = await freshnessHarness(
        snippet: destination == 'otherSnippet' ? 99 : 12,
      );
      final source = text.AiFieldProvenance(
        resourceKey: const text.AiConflictKey('project:9/snippet:12'),
        fieldName: text.AiWritableField.snippetDescription,
        completeValue: true,
        projectId: 9,
        projectFullPath: 'team/example-9',
        resourceWeb: s.api.instance.projectWeb('team/example-9/-/snippets/12'),
      );
      final display = h!.placeholders.redactOutgoing(original, field: source);
      expect(
        destinationSource.fieldName,
        text.AiWritableField.snippetDescription,
      );
      final op = destination == 'newSnippet'
          ? 'createSnippet'
          : destination == 'codeFile'
          ? 'updateSnippetFiles'
          : 'updateSnippetMetadata';
      final args = destination == 'newSnippet'
          ? {...p10Args(op), 'description': display}
          : destination == 'codeFile'
          ? {
              'projectId': 9,
              'snippetId': 12,
              'actions': [
                {'action': 'create', 'file_path': 'b.txt', 'content': display},
              ],
            }
          : {
              'projectId': 9,
              'snippetId': 12,
              'fields': {'description': display},
            };
      // New resources have no current description provenance.
      if (destination == 'newSnippet') {
        await h!.dispose();
        h = await P10Coordinator.create(s);
        h!.placeholders.redactOutgoing(original, field: source);
      }
      expect(await h!.propose(op, args: args), isNull);
      expect(h!.coordinator.outcomeFor('call')!.reasonCode, 'rereadField');
      expect(s.writes, isEmpty);
    });
  }

  for (final cut in [false, true]) {
    test(
      'P10 description ${cut ? 'later cut' : 'incomplete provenance'} blocks whole field',
      () async {
        final source = await freshnessHarness(complete: cut);
        if (cut) h!.placeholders.recordFieldDelivery(source, whole: false);
        expect(
          await h!.propose(
            'updateSnippetMetadata',
            args: {
              'projectId': 9,
              'snippetId': 12,
              'fields': {'description': 'replace'},
            },
          ),
          isNull,
        );
        expect(h!.coordinator.outcomeFor('call')!.reasonCode, 'fieldTooLong');
        expect(s.writes, isEmpty);
      },
    );
  }

  test(
    'P10 description dropping hidden spans requires confirmation at bypass',
    () async {
      s.record['description'] = 'visible glpat-ABCDEFGHIJKLMNOPQRST hidden';
      await freshnessHarness();
      final p = await h!.propose(
        'updateSnippetMetadata',
        args: {
          'projectId': 9,
          'snippetId': 12,
          'fields': {'description': 'visible'},
        },
      );
      expect(p, isNotNull);
      expect(
        p!.tier.reasons,
        contains(AiFixedConfirmReason.wholeFieldDropsHiddenSpans),
      );
      expect(p.tier.decision, AiGateDecision.requireApproval);
      expect(s.writes, isEmpty);
    },
  );

  test(
    'P10 description Markdown effects require confirmation and preserve payload',
    () async {
      h = await P10Coordinator.create(s, level: AiAutonomyLevel.bypass);
      const description =
          '@all\n![shot](https://outside.example/a.png)\n/merge';
      final p = await h!.propose(
        'updateSnippetMetadata',
        args: {
          'projectId': 9,
          'snippetId': 12,
          'fields': {'description': description},
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
      expect(p.tier.decision, AiGateDecision.requireApproval);
      expect((await h!.coordinator.approve(p)).successful, isTrue);
      expect((s.writes.single.data! as Map)['description'], description);
    },
  );
}
