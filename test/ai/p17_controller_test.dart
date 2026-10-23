import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';

import '../support/fake_adapter.dart';
import 'fx_coord_support.dart';
import 'p17_controller_support.dart';

const _uploadSecret = '0123456789abcdef0123456789abcdef';
const _upload = '/uploads/$_uploadSecret/shot.png';
const _original = 'Before ![shot]($_upload) after';

void main() {
  test('AiInboxOrigin has a stable key distinct from general', () {
    expect(const AiInboxOrigin().key, 'inbox');
    expect(const AiInboxOrigin().key, isNot(const AiGeneralOrigin().key));
  });

  test(
    'Inbox production scope offers only account-global write tools',
    () async {
      final h = await StackHarness.create(origin: const AiInboxOrigin());
      addTearDown(h.dispose);
      h.provider.script.add((_) => answerTurn);

      await h.controller.send('Review my inbox');

      final names = p17ToolNames(h.provider.bodies.single);
      expect(names, contains('markAllTodosDone'));
      expect(names, isNot(contains('setStar')));
      expect(names, isNot(contains('updateIssue')));
      expect(names, isNot(contains('updateRelease')));
    },
  );

  test(
    'General production scope offers no account-global write tool',
    () async {
      final h = await StackHarness.create(origin: const AiGeneralOrigin());
      addTearDown(h.dispose);
      h.provider.script.add((_) => answerTurn);

      await h.controller.send('Review my account');

      expect(
        p17ToolNames(h.provider.bodies.single),
        isNot(contains('markAllTodosDone')),
      );
    },
  );

  test(
    'production exact checker carries old secret hits into diff preview',
    () async {
      final f = await P17ScanFixture.create();
      addTearDown(f.dispose);
      final sending = f.controller.send('Create the synthetic issue');
      await p17WaitFor(() => f.controller.proposals.isNotEmpty);

      final preview =
          f.controller.proposals.single.preview as port.AiDiffPreview;
      expect(preview.preexistingSecretHits, 1);
      expect(f.scanPort.prepares, 1);

      await f.controller.rejectWrite(f.controller.proposals.single);
      await sending.timeout(p17Timeout);
      expect(f.server.mutations, 0);
    },
  );

  for (final resource in _ResourceCase.values) {
    test(
      '${resource.name} production read provenance restores its own upload',
      () async {
        final state = _ResourceState();
        final h = await StackHarness.create(
          level: AiAutonomyLevel.confirmEach,
          configure: state.configure,
        );
        addTearDown(h.dispose);
        h.provider.script
          ..add((_) => toolTurn(resource.readTool, resource.readArguments))
          ..add((body) {
            expect(body, contains('[[upload:u-1]]'));
            return toolTurn(
              resource.writeTool,
              resource.writeArguments('Before ![shot]([[upload:u-1]]) after'),
            );
          });

        final sending = h.controller.send('Read and preserve the upload');
        await p17WaitFor(
          () => h.controller.proposals.isNotEmpty || _writeSettled(h),
        );
        expect(h.controller.proposals, isNotEmpty);
        final outcome = await h.controller.approveWrite(
          h.controller.proposals.single,
        );
        await sending.timeout(p17Timeout);

        expect(
          outcome.state,
          AiJournalState.succeeded,
          reason: outcome.reasonCode,
        );
        expect(state.description(resource), _original);
        expect(state.mutationsFor(resource), hasLength(1));
      },
    );
  }

  test('release upload placeholder cannot move to another release', () async {
    final state = _ResourceState();
    final h = await StackHarness.create(
      level: AiAutonomyLevel.bypass,
      configure: state.configure,
    );
    addTearDown(h.dispose);
    h.provider.script
      ..add((_) => toolTurn('get_release', {'tag_name': 'v1'}))
      ..add(
        (_) => toolTurn('updateRelease', {
          'projectId': 42,
          'tag_name': 'v2',
          'fields': {'description': '[[upload:u-1]]'},
          'reason': 'Move the description.',
        }),
      );

    await h.controller.send('Move the release notes');

    expect(h.controller.proposals, isEmpty);
    expect(_writeReason(h, 'updateRelease'), 'rereadField');
    expect(state.mutations, isEmpty);
  });

  test(
    'release description placeholder cannot move into its name field',
    () async {
      final state = _ResourceState();
      final h = await StackHarness.create(
        level: AiAutonomyLevel.bypass,
        configure: state.configure,
      );
      addTearDown(h.dispose);
      h.provider.script
        ..add((_) => toolTurn('get_release', {'tag_name': 'v1'}))
        ..add(
          (_) => toolTurn('updateRelease', {
            'projectId': 42,
            'tag_name': 'v1',
            'fields': {'name': '[[upload:u-1]]'},
            'reason': 'Rename the release.',
          }),
        );

      await h.controller.send('Use that link as the release name');

      expect(h.controller.proposals, isEmpty);
      expect(_writeReason(h, 'updateRelease'), 'rereadField');
      expect(state.mutations, isEmpty);
    },
  );

  test(
    'cut release description refuses a whole-field production write',
    () async {
      final state = _ResourceState()
        ..releases['v1']!['description'] = 'Long description. ' * 2000;
      final h = await StackHarness.create(
        level: AiAutonomyLevel.bypass,
        configure: state.configure,
      );
      addTearDown(h.dispose);
      h.provider.script
        ..add((_) => toolTurn('get_release', {'tag_name': 'v1'}))
        ..add(
          (_) => toolTurn('updateRelease', {
            'projectId': 42,
            'tag_name': 'v1',
            'fields': {'description': 'Replacement'},
            'reason': 'Replace the release notes.',
          }),
        );

      await h.controller.send('Replace all release notes');

      expect(h.controller.proposals, isEmpty);
      expect(_writeReason(h, 'updateRelease'), 'fieldTooLong');
      expect(state.mutations, isEmpty);
    },
  );

  for (final resource in _ResourceCase.values) {
    test(
      'removing a hidden span holds the production ${resource.name} write',
      () async {
        final state = _ResourceState()
          ..setDescription(resource, 'Visible synthetic-test-token hidden');
        final h = await StackHarness.create(
          level: AiAutonomyLevel.bypass,
          configure: state.configure,
        );
        addTearDown(h.dispose);
        h.provider.script
          ..add((_) => toolTurn(resource.readTool, resource.readArguments))
          ..add(
            (_) => toolTurn(
              resource.writeTool,
              resource.writeArguments('Visible hidden'),
            ),
          );

        final sending = h.controller.send('Clean the description');
        await p17WaitFor(() => h.controller.proposals.isNotEmpty);
        final proposal = h.controller.proposals.single;

        expect(
          proposal.tier.reasons,
          contains(AiFixedConfirmReason.wholeFieldDropsHiddenSpans),
        );
        expect(proposal.tier.decision, AiGateDecision.requireApproval);
        expect(state.mutations, isEmpty);

        await h.controller.rejectWrite(proposal);
        await sending.timeout(p17Timeout);
      },
    );
  }

  test('release freshness rejects a response for another tag', () async {
    final state = _ResourceState();
    var reads = 0;
    final h = await StackHarness.create(
      level: AiAutonomyLevel.bypass,
      configure: (server) {
        state.configure(server);
        server.overrides['GET projects/42/releases/v1'] = (_) {
          reads++;
          return jsonResponse(
            reads == 1
                ? {...state.releases['v1']!, 'tag_name': 'other'}
                : state.releases['v1']!,
          );
        };
      },
    );
    addTearDown(h.dispose);
    h.provider.script.add(
      (_) => toolTurn(
        _ResourceCase.release.writeTool,
        _ResourceCase.release.writeArguments('Replacement'),
      ),
    );

    await _sendUntilRefusedOrProposed(h, 'Update the release notes');

    expect(h.controller.proposals, isEmpty);
    expect(_writeReason(h, 'updateRelease'), 'accountChanged');
    expect(reads, 1, reason: 'the later valid port response was not consumed');
    expect(state.mutations, isEmpty);
  });

  test('snippet freshness rejects a response for another snippet id', () async {
    final state = _ResourceState();
    var reads = 0;
    final h = await StackHarness.create(
      level: AiAutonomyLevel.bypass,
      configure: (server) {
        state.configure(server);
        server.overrides['GET projects/42/snippets/12'] = (_) {
          reads++;
          return jsonResponse(
            reads == 1 ? {...state.snippet, 'id': 99} : state.snippet,
          );
        };
      },
    );
    addTearDown(h.dispose);
    h.provider.script.add(
      (_) => toolTurn(
        _ResourceCase.snippet.writeTool,
        _ResourceCase.snippet.writeArguments('Replacement'),
      ),
    );

    await _sendUntilRefusedOrProposed(h, 'Update the snippet description');

    expect(h.controller.proposals, isEmpty);
    expect(_writeReason(h, 'updateSnippetMetadata'), 'accountChanged');
    expect(reads, 1, reason: 'the later valid port response was not consumed');
    expect(state.mutations, isEmpty);
  });

  test('snippet freshness rejects a response for another project', () async {
    final state = _ResourceState();
    var reads = 0;
    final h = await StackHarness.create(
      level: AiAutonomyLevel.bypass,
      configure: (server) {
        state.configure(server);
        server.overrides['GET projects/42/snippets/12'] = (_) {
          reads++;
          return jsonResponse(
            reads == 1 ? {...state.snippet, 'project_id': 99} : state.snippet,
          );
        };
      },
    );
    addTearDown(h.dispose);
    h.provider.script.add(
      (_) => toolTurn(
        _ResourceCase.snippet.writeTool,
        _ResourceCase.snippet.writeArguments('Replacement'),
      ),
    );

    await _sendUntilRefusedOrProposed(h, 'Update the snippet description');

    expect(h.controller.proposals, isEmpty);
    expect(_writeReason(h, 'updateSnippetMetadata'), 'accountChanged');
    expect(reads, 1, reason: 'the later valid port response was not consumed');
    expect(state.mutations, isEmpty);
  });

  final invalidMilestoneFreshness =
      <(String, Map<String, Object?> Function(Map<String, Object?>))>[
        ('another milestone id', (milestone) => {...milestone, 'id': 99}),
        ('another project', (milestone) => {...milestone, 'project_id': 99}),
        ('a missing iid', (milestone) => {...milestone}..remove('iid')),
        ('a nonpositive iid', (milestone) => {...milestone, 'iid': 0}),
      ];
  for (final (caseName, invalidResponse) in invalidMilestoneFreshness) {
    test('milestone freshness rejects $caseName', () async {
      final state = _ResourceState();
      var reads = 0;
      final h = await StackHarness.create(
        level: AiAutonomyLevel.bypass,
        configure: (server) {
          state.configure(server);
          server.overrides['GET projects/42/milestones/101'] = (_) {
            reads++;
            return jsonResponse(
              reads == 1 ? invalidResponse(state.milestone) : state.milestone,
            );
          };
        },
      );
      addTearDown(h.dispose);
      h.provider.script.add(
        (_) => toolTurn(
          _ResourceCase.milestone.writeTool,
          _ResourceCase.milestone.writeArguments('Replacement'),
        ),
      );

      await _sendUntilRefusedOrProposed(h, 'Update the milestone description');

      expect(h.controller.proposals, isEmpty);
      expect(_writeReason(h, 'updateMilestone'), 'accountChanged');
      expect(
        reads,
        1,
        reason: 'the later valid port response was not consumed',
      );
      expect(state.mutations, isEmpty);
    });
  }

  for (final resource in [_ResourceCase.release, _ResourceCase.snippet]) {
    test(
      '${resource.name} freshness replaces the project GET with a target GET',
      () async {
        final state = _ResourceState();
        final h = await StackHarness.create(
          level: AiAutonomyLevel.confirmEach,
          configure: state.configure,
        );
        addTearDown(h.dispose);
        h.provider.script.add(
          (_) => toolTurn(
            resource.writeTool,
            resource.writeArguments('Plain description'),
          ),
        );

        final sending = h.controller.send('Update the description');
        await p17WaitFor(() => h.controller.proposals.isNotEmpty);

        expect(_getCount(h, 'projects/42'), 1);
        expect(_getCount(h, resource.targetPath), 2);

        await h.controller.rejectWrite(h.controller.proposals.single);
        await sending.timeout(p17Timeout);
      },
    );
  }
}

bool _writeSettled(StackHarness h) => h.controller.items
    .whereType<AiToolRunItem>()
    .any((item) => h.controller.writeRowFor(item)?.outcome != null);

Future<void> _sendUntilRefusedOrProposed(StackHarness h, String message) async {
  final sending = h.controller.send(message);
  await p17WaitFor(() => h.controller.proposals.isNotEmpty || _writeSettled(h));
  expect(h.controller.proposals, isEmpty);
  await sending.timeout(p17Timeout);
}

String? _writeReason(StackHarness h, String operation) {
  final item = h.controller.items.whereType<AiToolRunItem>().lastWhere(
    (item) => item.name == operation,
  );
  return h.controller.writeRowFor(item)?.outcome?.reasonCode;
}

int _getCount(StackHarness h, String suffix) => h.server.adapter.requests
    .where(
      (request) =>
          request.method == 'GET' && request.uri.path.endsWith('/$suffix'),
    )
    .length;

enum _ResourceCase {
  release,
  milestone,
  snippet;

  String get readTool => switch (this) {
    release => 'get_release',
    milestone => 'get_milestone',
    snippet => 'get_snippet',
  };

  Map<String, Object?> get readArguments => switch (this) {
    release => {'tag_name': 'v1'},
    milestone => {'milestone_id': 101},
    snippet => {'snippet_id': 12},
  };

  String get writeTool => switch (this) {
    release => 'updateRelease',
    milestone => 'updateMilestone',
    snippet => 'updateSnippetMetadata',
  };

  String get targetPath => switch (this) {
    release => 'projects/42/releases/v1',
    milestone => 'projects/42/milestones/101',
    snippet => 'projects/42/snippets/12',
  };

  Map<String, Object?> writeArguments(String token) => switch (this) {
    release => {
      'projectId': 42,
      'tag_name': 'v1',
      'fields': {'description': token},
      'reason': 'Preserve the release upload.',
    },
    milestone => {
      'projectId': 42,
      'milestoneId': 101,
      'fields': {'description': token},
      'reason': 'Preserve the milestone upload.',
    },
    snippet => {
      'projectId': 42,
      'snippetId': 12,
      'fields': {'description': token},
      'reason': 'Preserve the snippet upload.',
    },
  };
}

final class _ResourceState {
  final releases = <String, Map<String, Object?>>{
    'v1': {
      'tag_name': 'v1',
      'name': 'Version 1',
      'description': _original,
      'created_at': '2026-10-23T00:00:00Z',
      'released_at': '2026-10-23T00:00:00Z',
      'updated_at': '2026-10-23T00:00:00Z',
      'commit': {'id': 'a' * 40},
    },
    'v2': {
      'tag_name': 'v2',
      'name': 'Version 2',
      'description': 'Second release',
      'created_at': '2026-10-23T00:00:00Z',
      'released_at': '2026-10-23T00:00:00Z',
      'updated_at': '2026-10-23T00:00:00Z',
      'commit': {'id': 'b' * 40},
    },
  };
  final milestone = <String, Object?>{
    'id': 101,
    'iid': 2,
    'project_id': 42,
    'title': 'Version 1',
    'description': _original,
    'state': 'active',
    'created_at': '2026-10-23T00:00:00Z',
    'updated_at': '2026-10-23T00:00:00Z',
  };
  final snippet = <String, Object?>{
    'id': 12,
    'project_id': 42,
    'title': 'Snippet',
    'description': _original,
    'visibility': 'private',
    'created_at': '2026-10-23T00:00:00Z',
    'updated_at': '2026-10-23T00:00:00Z',
    'file_name': 'a.txt',
    'files': [
      {
        'path': 'a.txt',
        'raw_url':
            'https://example.com/gitlab/studio/mobile-workspace/-/snippets/12/raw/main/a.txt',
      },
    ],
  };
  final mutations = <RequestOptions>[];

  void configure(StackServer server) {
    for (final tag in releases.keys) {
      server.overrides['GET projects/42/releases/$tag'] = (_) =>
          jsonResponse(releases[tag]!);
      server.overrides['PUT projects/42/releases/$tag'] = (request) {
        mutations.add(request);
        releases[tag]!.addAll(Map<String, Object?>.from(request.data as Map));
        return jsonResponse(releases[tag]!);
      };
    }
    server.overrides['GET projects/42/milestones/101'] = (_) =>
        jsonResponse(milestone);
    server.overrides['PUT projects/42/milestones/101'] = (request) {
      mutations.add(request);
      milestone.addAll(Map<String, Object?>.from(request.data as Map));
      return jsonResponse(milestone);
    };
    server.overrides['GET projects/42/snippets/12'] = (_) =>
        jsonResponse(snippet);
    server.overrides['GET projects/42/snippets/12/raw'] = (_) =>
        ResponseBody.fromString('alpha\n', 200);
    server.overrides['GET projects/42/snippets/12/files/HEAD/a.txt/raw'] =
        (_) => ResponseBody.fromString('alpha\n', 200);
    server.overrides['PUT projects/42/snippets/12'] = (request) {
      mutations.add(request);
      snippet.addAll(Map<String, Object?>.from(request.data as Map));
      return jsonResponse(snippet);
    };
  }

  String description(_ResourceCase resource) => switch (resource) {
    _ResourceCase.release => releases['v1']!['description']! as String,
    _ResourceCase.milestone => milestone['description']! as String,
    _ResourceCase.snippet => snippet['description']! as String,
  };

  void setDescription(_ResourceCase resource, String description) {
    switch (resource) {
      case _ResourceCase.release:
        releases['v1']!['description'] = description;
      case _ResourceCase.milestone:
        milestone['description'] = description;
      case _ResourceCase.snippet:
        snippet['description'] = description;
    }
  }

  List<RequestOptions> mutationsFor(_ResourceCase resource) => [
    for (final request in mutations)
      if (switch (resource) {
        _ResourceCase.release => request.uri.path.endsWith('/releases/v1'),
        _ResourceCase.milestone => request.uri.path.endsWith('/milestones/101'),
        _ResourceCase.snippet => request.uri.path.endsWith('/snippets/12'),
      })
        request,
  ];
}
