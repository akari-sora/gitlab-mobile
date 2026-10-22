import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';

/// §15 row 21. Every write call site in `lib/` maps to a production ledger row
/// or to the MR6b-2 / MR6b-3 pending lists. Generic channel calls outside
/// those lists fail the test.
void main() {
  test('§15 row 21 ledger covers every lib write call site', () {
    final sites = _writeSites(_libRoot());
    final ledgerMethods = <String, String>{
      for (final AiCapability row in ProductionAiLedger.rows)
        row.namedMethod: row.operationId,
    };
    final pending2Methods = _pendingMr6b2Methods;
    final pending3Methods = _pendingMr6b3Methods;

    final unclassified = <String>[];
    final pending3 = <String>[];
    final mapped = <_Site>[];
    final screenGeneric = <_Site>[];

    for (final _Site site in sites) {
      final _Bucket bucket = _classify(
        site,
        ledgerMethods: ledgerMethods,
        pending2Methods: pending2Methods,
        pending3Methods: pending3Methods,
      );
      switch (bucket.kind) {
        case _Kind.ledger:
          mapped.add(site);
        case _Kind.mr6b2:
          if (site.kind != 'named' &&
              !site.file.endsWith('workspace_api.dart')) {
            screenGeneric.add(site);
          }
        case _Kind.mr6b3:
          pending3.add('${site.file}:${site.line} ${bucket.label}');
        case _Kind.unknown:
          unclassified.add(
            '${site.file}:${site.line} ${site.kind} ${site.detail}',
          );
      }
    }

    expect(
      unclassified,
      isEmpty,
      reason: 'write call sites outside the ledger and the pending lists',
    );

    final implementation = <String>{
      for (final _Site site in sites)
        if (site.file == 'lib/core/workspace_api.dart' && site.kind != 'named')
          site.detail,
    };
    expect(
      implementation,
      _ledgerImplementations.union(_pendingImplementations),
    );
    expect(
      implementation.intersection(_ledgerImplementations),
      _ledgerImplementations,
    );
    expect(
      implementation.intersection(_pendingImplementations),
      _pendingImplementations,
    );

    final counts = <String, int>{};
    for (final _Site site in screenGeneric) {
      counts[site.file] = (counts[site.file] ?? 0) + 1;
    }
    expect(_withinScreenGenericLimits(counts), isTrue,
      reason: 'generic calls may only decrease in the existing MR6b-1 files');
    final pending3Text = pending3.join('\n');
    expect(pending3Text, contains('graphMutation'));
    for (final String method in pending3Methods) {
      expect(pending3Text, contains(method), reason: method);
    }

    for (final (String file, String method) in _rewiredNamedCalls) {
      expect(
        mapped.any((site) => site.file.endsWith(file) && site.detail == method),
        isTrue,
        reason: '$file $method',
      );
    }

    const rewiredWithoutGeneric = <String>[
      'lib/features/workspace/comment_editor.dart',
      'lib/features/workspace/diff_page.dart',
    ];
    for (final String file in rewiredWithoutGeneric) {
      expect(counts.containsKey(file), isFalse, reason: file);
    }
  });

  test('screen rewiring may remove generic calls and whole pending files', () {
    expect(_withinScreenGenericLimits(_screenGenericCounts), isTrue);
    expect(_withinScreenGenericLimits({}), isTrue);
    expect(_withinScreenGenericLimits({
      'lib/features/workspace/snippets_page.dart': 2,
    }), isTrue);
  });

  test('screen generic calls cannot grow or appear in a new file', () {
    expect(_withinScreenGenericLimits({
      ..._screenGenericCounts,
      'lib/features/workspace/snippets_page.dart': 7,
    }), isFalse);
    expect(_withinScreenGenericLimits({
      'lib/features/workspace/new_page.dart': 1,
    }), isFalse);
  });
}

enum _Kind { ledger, mr6b2, mr6b3, unknown }

final class _Bucket {
  const _Bucket(this.kind, this.label);
  final _Kind kind;
  final String label;
}

final class _Site {
  const _Site({
    required this.file,
    required this.line,
    required this.kind,
    required this.detail,
  });

  final String file;
  final int line;
  final String kind;
  final String detail;
}

bool _withinScreenGenericLimits(Map<String, int> counts) =>
  counts.entries.every((entry) =>
    _screenGenericCounts.containsKey(entry.key) &&
    entry.value <= _screenGenericCounts[entry.key]!);

const _screenGenericCounts = <String, int>{
  'lib/features/workspace/snippets_page.dart': 6,
  'lib/features/workspace/registries_page.dart': 4,
  'lib/features/workspace/project_more_page.dart': 3,
  'lib/features/workspace/boards_page.dart': 2,
  'lib/features/workspace/draft_review_page.dart': 2,
  'lib/features/workspace/discussions_tab.dart': 1,
  'lib/features/workspace/work_item_page.dart': 1,
};

const _ledgerImplementations = <String>{
  'addAwardEmoji',
  'removeAwardEmoji',
  'setStar',
  'markTodoDone',
  'createNote',
  'updateNote',
  'createDiscussion',
  'createDiscussionNote',
  'updateDiscussionNote',
  'setDiscussionResolved',
  'createDraftNote',
  'updateDraftNote',
  'createIssue',
  'updateIssue',
  'createMergeRequest',
  'updateMergeRequest',
  'unapproveMergeRequest',
  'createTodo',
  'createLabel',
  'updateLabel',
  'createMilestone',
  'updateMilestone',
  'setMilestoneState',
  'createBoard',
  'renameBoard',
  'setBoardSystemListHidden',
  'createBoardList',
  'moveBoardList',
  'moveBoardCard',
};

const _pendingImplementations = <String>{
  'createProject',
  'editProject',
  'deleteProject',
  'deleteIssue',
  'deleteMergeRequest',
  'deleteNote',
  'approveMergeRequest',
  'mergeRequest',
  'cancelAutoMerge',
  'rebaseMergeRequest',
  'applySuggestion',
  'batchApplySuggestions',
  'createBranch',
  'deleteBranch',
  'createTag',
  'deleteTag',
  'createRepositoryFile',
  'updateRepositoryFile',
  'deleteFile',
  'createPipeline',
  'pipelineAction',
  'deletePipeline',
  'jobAction',
  'createRelease',
  'updateRelease',
  'deleteRelease',
  'playPipelineSchedule',
  'forkProject',
  'deleteDiscussionNote',
  'deleteDraftNote',
  'publishDraftNotes',
  'deleteLabel',
  'deleteMilestone',
  'deleteBoard',
  'deleteBoardList',
  'createSnippet',
  'updateSnippet',
  'updateSnippetMetadata',
  'updateSnippetFiles',
  'deleteSnippetFile',
  'deleteSnippet',
  'deletePackage',
  'deletePackageFile',
  'deleteContainerRepository',
  'deleteContainerTag',
};

const _pendingMr6b2Methods = <String>{
  ..._pendingImplementations,
  // Compatibility wrapper delegates to the create/update implementations.
  'saveFile',
  'markAllTodosDone',
};

const _pendingMr6b3Methods = <String>{
  'updateWorkItemWeight',
  'updateWorkItemStatus',
  'updateWorkItemState',
  'setWorkItemNotifications',
  'setWorkItemActivityNoteReaction',
  'deleteWorkItemActivityNote',
  'updateWorkItemMilestone',
  'updateWorkItemLabels',
  'updateWorkItemHealthStatus',
  'updateWorkItemDates',
  'updateWorkItemContent',
  'updateWorkItemAssignees',
  'editWorkItemActivityNote',
  'createWorkItemActivityComment',
  'createWorkItemActivityReply',
  'snoozeTodo',
  'unsnoozeTodo',
  'setIncidentStatus',
};

const _rewiredNamedCalls = <(String, String)>[
  ('comment_editor.dart', 'createNote'),
  ('discussions_tab.dart', 'updateNote'),
  ('discussions_tab.dart', 'updateDiscussionNote'),
  ('discussions_tab.dart', 'createDiscussionNote'),
  ('discussions_tab.dart', 'createDiscussion'),
  ('discussions_tab.dart', 'setDiscussionResolved'),
  ('diff_page.dart', 'createDraftNote'),
  ('diff_page.dart', 'createDiscussion'),
  ('diff_page.dart', 'createDiscussionNote'),
  ('diff_page.dart', 'setDiscussionResolved'),
  ('draft_review_page.dart', 'createDraftNote'),
  ('draft_review_page.dart', 'updateDraftNote'),
  ('work_item_page.dart', 'updateIssue'),
  ('work_item_page.dart', 'updateMergeRequest'),
  ('work_item_page.dart', 'createTodo'),
  ('work_item_page.dart', 'unapproveMergeRequest'),
  ('work_item_page.dart', 'setSubscribed'),
  ('boards_page.dart', 'createBoard'),
  ('boards_page.dart', 'renameBoard'),
  ('boards_page.dart', 'setBoardSystemListHidden'),
  ('boards_page.dart', 'createBoardList'),
  ('boards_page.dart', 'moveBoardList'),
  ('boards_page.dart', 'moveBoardCard'),
  ('project_more_page.dart', 'createLabel'),
  ('project_more_page.dart', 'updateLabel'),
  ('project_more_page.dart', 'createMilestone'),
  ('project_more_page.dart', 'updateMilestone'),
  ('project_more_page.dart', 'setMilestoneState'),
  ('reactions.dart', 'addAwardEmoji'),
  ('reactions.dart', 'removeAwardEmoji'),
  ('project_page.dart', 'setStar'),
];

_Bucket _classify(
  _Site site, {
  required Map<String, String> ledgerMethods,
  required Set<String> pending2Methods,
  required Set<String> pending3Methods,
}) {
  if (site.kind == 'graphMutation') {
    return _Bucket(_Kind.mr6b3, 'graphMutation ${site.detail}');
  }
  if (site.kind == 'named') {
    final operation = ledgerMethods[site.detail];
    if (operation != null) return _Bucket(_Kind.ledger, operation);
    if (pending3Methods.contains(site.detail)) {
      return _Bucket(_Kind.mr6b3, site.detail);
    }
    if (pending2Methods.contains(site.detail)) {
      return _Bucket(_Kind.mr6b2, site.detail);
    }
    return const _Bucket(_Kind.unknown, '');
  }
  if (site.file == 'lib/core/workspace_api.dart') {
    if (ledgerMethods.containsKey(site.detail)) {
      return _Bucket(_Kind.ledger, ledgerMethods[site.detail]!);
    }
    if (pending2Methods.contains(site.detail)) {
      return _Bucket(_Kind.mr6b2, site.detail);
    }
    return const _Bucket(_Kind.unknown, '');
  }
  return _Bucket(_Kind.mr6b2, _screenLabel(site));
}

String _screenLabel(_Site site) {
  switch (site.file) {
    case 'lib/features/workspace/snippets_page.dart':
      return 'snippets';
    case 'lib/features/workspace/registries_page.dart':
      return 'registry delete';
    case 'lib/features/workspace/project_more_page.dart':
      return site.kind == 'removeRecord'
          ? 'label milestone branch tag release delete'
          : 'branch tag release';
    case 'lib/features/workspace/boards_page.dart':
      return 'board and list delete';
    case 'lib/features/workspace/draft_review_page.dart':
      return site.kind == 'writeEmpty' ? 'bulk_publish' : 'draft delete';
    case 'lib/features/workspace/discussions_tab.dart':
      return 'comment delete';
    case 'lib/features/workspace/work_item_page.dart':
      return 'issue and merge request delete';
    default:
      return 'unlisted ${site.kind}';
  }
}

Directory _libRoot() {
  final direct = Directory('lib');
  if (direct.existsSync()) return direct;
  return Directory('${Directory.current.path}/lib');
}

List<_Site> _writeSites(Directory lib) {
  final named = _namedCallPattern();
  final generic = RegExp(r'\b(writeRecord|removeRecord|writeEmpty)\s*\(');
  final mutation = RegExp(r'graphMutation\s*:\s*true');
  // Indent of exactly two spaces: extension members. The name is the
  // identifier before the first parameter list, so `=> writeRecord(` on the
  // same line is not treated as the member name.
  final declaration = RegExp(
    r'^  (?! )[\w<>?,\s]*?([A-Za-z_][A-Za-z0-9_]*)\s*\(',
  );
  final sites = <_Site>[];
  for (final File file in _dartFiles(lib)) {
    final relative = _relativeLib(file.path);
    if (relative.startsWith('lib/l10n/')) continue;
    final lines = file.readAsLinesSync();
    var method = '';
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final declared = declaration.firstMatch(line);
      if (declared != null) method = declared.group(1)!;
      final lineNumber = index + 1;
      for (final Match match in generic.allMatches(line)) {
        final channel = match.group(1)!;
        if (declared != null && declared.group(1) == channel) continue;
        sites.add(
          _Site(
            file: relative,
            line: lineNumber,
            kind: channel,
            detail: method,
          ),
        );
      }
      if (mutation.hasMatch(line)) {
        sites.add(
          _Site(
            file: relative,
            line: lineNumber,
            kind: 'graphMutation',
            detail: method.isEmpty ? 'graphMutation' : method,
          ),
        );
      }
      for (final Match match in named.allMatches(line)) {
        sites.add(
          _Site(
            file: relative,
            line: lineNumber,
            kind: 'named',
            detail: match.group(1)!,
          ),
        );
      }
    }
  }
  return sites;
}

RegExp _namedCallPattern() {
  final methods = <String>{
    ...ProductionAiLedger.rows.map((row) => row.namedMethod),
    ..._pendingMr6b2Methods,
    ..._pendingMr6b3Methods,
  }.toList()..sort((a, b) => b.length.compareTo(a.length));
  return RegExp('(?:_api|\\bapi)\\.(${methods.join('|')})\\s*\\(');
}

Iterable<File> _dartFiles(Directory root) sync* {
  for (final FileSystemEntity entity in root.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) yield entity;
  }
}

String _relativeLib(String path) {
  final normalized = path.replaceAll('\\', '/');
  const marker = 'lib/';
  final index = normalized.lastIndexOf(marker);
  if (index < 0) return normalized;
  return normalized.substring(index);
}
