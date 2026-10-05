import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_labels_models.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/account_store.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/shell/app_shortcuts.dart';
import 'package:gitlab_mobile/features/shell/appearance.dart';
import 'package:gitlab_mobile/features/shell/authenticated_app.dart';
import 'package:gitlab_mobile/features/shell/build_info.dart';
import 'package:gitlab_mobile/features/workspace/project_extras.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/features/workspace/project_page.dart';
import 'package:gitlab_mobile/features/workspace/reactions.dart';
import 'package:gitlab_mobile/shared/scroll_performance.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import '../test/support/fake_adapter.dart';
import '../test/support/fake_shortcuts.dart';
import '../test/support/memory_appearance_store.dart';
import '../test/support/work_item_dates_parent_fixture.dart';
import '../test/support/work_item_status_fixture.dart';
import '../test/support/workspace_fixture.dart';

const emulatorUiQaEnabled = bool.fromEnvironment('EMULATOR_UI_QA');

/// Adds bounded synthetic performance data only to the guarded QA target.
///
/// Native QA opts in with `--dart-define=EMULATOR_PERF_QA=true`. Regular QA
/// fixtures remain unchanged when the flag is absent.
const emulatorPerfQaEnabled = bool.fromEnvironment('EMULATOR_PERF_QA');
const emulatorUiQaCommit = String.fromEnvironment(
  'GITLAB_MOBILE_COMMIT',
  defaultValue: 'local-qa',
);
const emulatorPerfQaChangedFileCount = 120;
const emulatorPerfQaLargeDiffLineCount = 3001;
const emulatorPerfQaLargeFileLineCount = 20000;
const emulatorPerfQaProjectCount = 120;
const emulatorPerfQaLargeFilePath = 'lib/large_code.dart';
const emulatorPerfQaSearchTokenAlpha = 'uniqueSearchTargetAlpha';
const emulatorPerfQaSearchTokenBeta = 'uniqueSearchTargetBeta';
const emulatorPerfQaDistantAnchor = 'stableDistantAnchor19001';

enum _QaNoteEditControl {
  contentAuthenticated,
  contentAnonymous,
  allowContent,
  denyContent,
  denyContentWrites,
  reviseContent,
  failContentAcknowledgement,
  failContentRead,
  absentDescription,
  presentDescription,
  allow,
  deny,
  revise,
  failNextAcknowledgement,
  allowReactions,
  denyReactions,
  failDeleteAcknowledgement,
  failReactionAcknowledgement,
  notificationAuthenticated,
  notificationAnonymous,
  allowNotificationWrites,
  denyNotificationWrites,
  failNotificationAcknowledgement,
  failNotificationRead,
  allowAssigneeMetadata,
  denyAssigneeMetadata,
  absentAssigneeWidget,
  presentAssigneeWidget,
  singleAssignee,
  multipleAssignees,
  loseNextAssigneeAck,
  dropNextAssigneeAckUser,
  mismatchAssigneeReadback,
  reviseAssignee,
  assigneeCount21,
  assigneeCount101,
  resetAssignees,
  assigneePagePastMax,
  assigneeRevisionDuringPage,
  allowMilestoneMetadata,
  denyMilestoneMetadata,
  failMilestoneCandidates,
  failMilestoneAcknowledgement,
  reviseMilestone,
  allowWeight,
  denyWeight,
  failWeightAcknowledgement,
  reviseWeight,
  absentWeight,
  presentWeight,
  allowLabelMetadata,
  denyLabelMetadata,
  labelCount120,
  failLabelCandidatePage,
  partialLabelCandidatePage,
  silentDenyLabelMutation,
  mismatchLabelReadback,
  resetLabels,
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(buildEmulatorQaApp());
}

Widget buildEmulatorQaApp({bool qaEnabled = emulatorUiQaEnabled}) {
  if (!qaEnabled) {
    throw StateError(
      'Emulator UI QA requires --dart-define=EMULATOR_UI_QA=true.',
    );
  }
  return const EmulatorQaApp();
}

final class EmulatorQaMemoryAccountStore implements AccountStore {
  List<Account> accounts = [];
  String? lastActive;
  bool signOutPending = false;

  @override
  Future<List<Account>> load() async => List.of(accounts);

  @override
  Future<void> save(List<Account> value) async {
    accounts = List.of(value);
  }

  @override
  Future<String?> loadLastActive() async => lastActive;

  @override
  Future<void> saveLastActive(String? key) async {
    lastActive = key;
  }

  @override
  Future<bool> loadSignOutPending() async => signOutPending;

  @override
  Future<void> saveSignOutPending(bool pending) async {
    signOutPending = pending;
  }
}

final class EmulatorQaFixture extends WorkspaceFixture {
  EmulatorQaFixture({bool performanceQa = emulatorPerfQaEnabled})
    : performanceQaEnabled = performanceQa {
    projectRecord['star_count'] = _starCount;
    pipelineSchedules.addAll([
      {
        'id': 3,
        'description': 'Nightly synthetic build',
        'ref': 'main',
        'cron': '0 2 * * *',
        'cron_timezone': 'UTC',
        'active': true,
        'next_run_at': '2026-10-04T02:00:00Z',
      },
      {
        'id': 4,
        'description': 'Weekly synthetic audit',
        'ref': 'release/qa',
        'cron': '0 6 * * 1',
        'cron_timezone': 'Asia/Taipei',
        'active': false,
      },
    ]);
  }

  final bool performanceQaEnabled;
  List<Json>? _performanceProjectsCache;
  List<Json>? _performanceDiffsCache;
  String? _performanceLargeDiffCache;
  String? _performanceLargeFileCache;

  List<Json> get _performanceProjects =>
      _performanceProjectsCache ??= List<Json>.unmodifiable([
        Map<String, dynamic>.unmodifiable(projectRecord),
        for (var number = 2; number <= emulatorPerfQaProjectCount; number++)
          Map<String, dynamic>.unmodifiable({
            'id': 1000 + number,
            'name': 'Performance project ${number.toString().padLeft(3, '0')}',
            'path_with_namespace':
                'qa/performance-project-${number.toString().padLeft(3, '0')}',
            'description':
                'Deterministic synthetic performance project $number.',
            'visibility': 'private',
            'default_branch': 'main',
            'archived': false,
            'last_activity_at':
                '2026-10-${((number - 1) % 28 + 1).toString().padLeft(2, '0')}T12:00:00Z',
          }),
      ]);

  String get _performanceLargeDiff {
    final cached = _performanceLargeDiffCache;
    if (cached != null) return cached;
    final buffer = StringBuffer('@@ -1,3000 +1,3000 @@\n');
    for (var line = 1; line <= 3000; line++) {
      buffer.write(
        ' performance UTF-8 差異 row ${line.toString().padLeft(4, '0')} '
        'abcdefghijklmnop',
      );
      if (line != 3000) buffer.write('\n');
    }
    return _performanceLargeDiffCache = buffer.toString();
  }

  List<Json>
  get _performanceDiffs => _performanceDiffsCache ??= List<Json>.unmodifiable([
    for (var index = 0; index < emulatorPerfQaChangedFileCount; index++)
      Map<String, dynamic>.unmodifiable({
        'old_path': index == 0
            ? 'lib/session.dart'
            : 'lib/performance/file_${index.toString().padLeft(3, '0')}.dart',
        'new_path': index == 0
            ? 'lib/session.dart'
            : 'lib/performance/file_${index.toString().padLeft(3, '0')}.dart',
        'a_mode': '100644',
        'b_mode': '100644',
        'new_file': false,
        'renamed_file': false,
        'deleted_file': false,
        'generated_file': false,
        'too_large': false,
        'collapsed': false,
        'diff': index == 0
            ? _performanceLargeDiff
            : '@@ -1 +1 @@\n-old $index\n+new $index',
      }),
  ]);

  String get _performanceLargeFile {
    final cached = _performanceLargeFileCache;
    if (cached != null) return cached;
    final buffer = StringBuffer();
    for (var line = 1; line <= emulatorPerfQaLargeFileLineCount; line++) {
      final content = switch (line) {
        501 => "const $emulatorPerfQaSearchTokenAlpha = 'line-00501';",
        15001 => "const $emulatorPerfQaSearchTokenBeta = 'line-15001';",
        19001 => "const $emulatorPerfQaDistantAnchor = 'line-19001';",
        _ =>
          'const performanceQaLine${line.toString().padLeft(5, '0')} = $line;',
      };
      buffer.write(content);
      if (line != emulatorPerfQaLargeFileLineCount) buffer.write('\n');
    }
    return _performanceLargeFileCache = buffer.toString();
  }

  bool _starred = false;
  int _starCount = 12;

  Map<String, dynamic> get _latestProjectRecord {
    projectRecord['star_count'] = _starCount;
    return Map<String, dynamic>.unmodifiable({
      ...projectRecord,
      'star_count': _starCount,
    });
  }

  ResponseBody _regularProjectsResponse(RequestOptions request) {
    var rows = <Json>[
      if (request.uri.queryParameters['starred'] != 'true' || _starred)
        _latestProjectRecord,
    ];
    final search = request.uri.queryParameters['search']?.trim().toLowerCase();
    if (search != null && search.isNotEmpty) {
      rows = rows
          .where(
            (row) =>
                (row['name'] as String).toLowerCase().contains(search) ||
                (row['path_with_namespace'] as String).toLowerCase().contains(
                  search,
                ),
          )
          .toList(growable: false);
    }
    final page = int.tryParse(request.uri.queryParameters['page'] ?? '') ?? 1;
    if (page > 1) {
      return jsonResponse(<Json>[]);
    }
    return jsonResponse(rows);
  }

  ResponseBody _performanceProjectsResponse(RequestOptions request) {
    final baseRows = _performanceProjects;
    final isStarredFilter = request.uri.queryParameters['starred'] == 'true';
    var rows = isStarredFilter
        ? [
            if (_starred) _latestProjectRecord,
            for (var index = 1; index < baseRows.length; index++)
              if ((index + 1) % 10 == 0) baseRows[index],
          ]
        : [
            _latestProjectRecord,
            ...baseRows.skip(1),
          ];
    final search = request.uri.queryParameters['search']?.trim().toLowerCase();
    if (search != null && search.isNotEmpty) {
      rows = rows
          .where(
            (row) =>
                (row['name'] as String).toLowerCase().contains(search) ||
                (row['path_with_namespace'] as String).toLowerCase().contains(
                  search,
                ),
          )
          .toList(growable: false);
    }
    final perPage =
        int.tryParse(request.uri.queryParameters['per_page'] ?? '') ?? 30;
    final page = int.tryParse(request.uri.queryParameters['page'] ?? '') ?? 1;
    if (perPage < 1 || perPage > 100 || page < 1) {
      return jsonResponse({
        'message': '400 Invalid synthetic pagination',
      }, status: 400);
    }
    final start = (page - 1) * perPage;
    final end = math.min(start + perPage, rows.length);
    final pageRows = start >= rows.length
        ? const <Json>[]
        : rows.sublist(start, end);
    final totalPages = rows.isEmpty ? 1 : (rows.length / perPage).ceil();
    final nextPage = page < totalPages ? page + 1 : null;
    return jsonResponse(
      pageRows,
      headers: {
        'x-page': ['$page'],
        'x-per-page': ['$perPage'],
        'x-total': ['${rows.length}'],
        'x-total-pages': ['$totalPages'],
        'x-next-page': [nextPage == null ? '' : '$nextPage'],
        'x-prev-page': [page > 1 ? '${page - 1}' : ''],
      },
    );
  }
  final Map<String, String> _workItemStates = {
    'gid://gitlab/WorkItem/1031': 'OPEN',
    'gid://gitlab/WorkItem/1041': 'OPEN',
  };
  final List<String> workItemStateEvents = [];
  final List<Json> workItemContentEvents = [];
  final List<String> workItemContentReads = [];
  final Map<bool, String> workItemContentTitles = {
    false: 'Synthetic project Work Item',
    true: 'Synthetic group Work Item',
  };
  final Map<bool, String?> workItemContentDescriptions = {
    false: 'Explicit in-memory QA fixture. No GitLab connection.',
    true: 'Explicit in-memory QA fixture. No GitLab connection.',
  };
  final Map<bool, bool> workItemDescriptionPresent = {false: true, true: true};
  final Set<bool> _editedWorkItemContent = {};
  bool workItemContentAuthenticated = true;
  bool workItemContentAllowed = true;
  bool workItemContentWritesAllowed = true;
  bool failNextWorkItemContentAcknowledgement = false;
  bool failNextWorkItemContentRead = false;
  final List<Json> workItemNoteEvents = [];
  final List<Json> workItemNoteEditEvents = [];
  final List<Json> workItemNoteDeleteEvents = [];
  final List<Json> workItemNoteReactionEvents = [];
  final List<Json> workItemNotificationEvents = [];
  final List<String> workItemNotificationReads = [];
  final Map<bool, bool> workItemNotificationSubscribed = {
    false: false,
    true: false,
  };
  bool workItemNotificationAuthenticated = true;
  bool workItemNotificationWritesAllowed = true;
  bool failNextWorkItemNotificationAcknowledgement = false;
  bool failNextWorkItemNotificationRead = false;
  final List<Json> workItemMilestoneEvents = [];
  final List<Json> workItemMilestonePickerReads = [];
  final Map<bool, String?> workItemMilestoneIds = {
    false: 'gid://gitlab/Milestone/905',
    true: 'gid://gitlab/Milestone/915',
  };
  bool workItemMilestoneMetadataAllowed = true;
  bool failNextWorkItemMilestoneCandidates = false;
  bool failNextWorkItemMilestoneAcknowledgement = false;
  final List<Json> workItemWeightEvents = [];
  final List<String> workItemWeightReads = [];
  final Map<bool, int?> workItemWeights = {false: 0, true: 7};
  bool workItemWeightAllowed = true;
  bool workItemWeightPresent = true;
  bool failNextWorkItemWeightAcknowledgement = false;
  bool workItemAssigneeMetadataAllowed = true;
  bool workItemAssigneeWidgetPresent = true;
  final workItemAssigneeMultiple = <bool, bool>{false: true, true: true};
  final workItemAssigneeIds = <bool, List<String>>{
    false: ['gid://gitlab/User/1001', 'gid://gitlab/User/1002'],
    true: ['gid://gitlab/User/3001', 'gid://gitlab/User/3002'],
  };
  bool failNextWorkItemAssigneeAcknowledgement = false;
  bool dropNextWorkItemAssigneeAckUser = false;
  bool mismatchNextWorkItemAssigneeReadback = false;
  bool _assigneeReadbackMismatchArmed = false;
  bool malformNextAssigneeRead = false;
  bool workItemAssigneeRevisionDuringPagination = false;
  final workItemAssigneeReads = <Json>[];
  final workItemAssigneeCandidateEvents = <Json>[];
  final workItemAssigneeEvents = <Json>[];
  Json? lastAssigneeMutationResponse;

  void setWorkItemAssigneeCount({required bool group, required int count}) {
    final base = group ? 3000 : 1000;
    workItemAssigneeIds[group] = [
      for (var number = 1; number <= count; number++)
        'gid://gitlab/User/${base + number}',
    ];
  }

  void resetWorkItemAssignees() {
    workItemAssigneeMetadataAllowed = true;
    workItemAssigneeWidgetPresent = true;
    workItemAssigneeMultiple[false] = true;
    workItemAssigneeMultiple[true] = true;
    failNextWorkItemAssigneeAcknowledgement = false;
    dropNextWorkItemAssigneeAckUser = false;
    mismatchNextWorkItemAssigneeReadback = false;
    _assigneeReadbackMismatchArmed = false;
    malformNextAssigneeRead = false;
    workItemAssigneeRevisionDuringPagination = false;
    setWorkItemAssigneeCount(group: false, count: 2);
    setWorkItemAssigneeCount(group: true, count: 2);
  }

  void reviseWorkItemAssignee({required bool group}) {
    final id = group
        ? 'gid://gitlab/WorkItem/1041'
        : 'gid://gitlab/WorkItem/1031';
    _workItemRevisions[id] = (_workItemRevisions[id] ?? 0) + 1;
  }

  bool workItemLabelMetadataAllowed = true;
  bool workItemLabelReadWorkItemAllowed = true;
  bool workItemLabelWidgetPresent = true;
  WorkItemLabelAllowsScoped workItemLabelAllowsScoped =
      WorkItemLabelAllowsScoped.allowed;
  final workItemLabelsMap = <bool, List<WorkItemLabel>>{};
  bool failNextWorkItemLabelCandidates = false;
  bool partialNextWorkItemLabelCandidates = false;
  bool failNextWorkItemLabelAcknowledgement = false;
  bool silentDenyNextWorkItemLabelMutation = false;
  bool mismatchNextWorkItemLabelReadback = false;
  bool _labelReadbackMismatchArmed = false;
  bool malformNextLabelRead = false;
  bool workItemLabelRevisionDuringPagination = false;
  final workItemLabelReads = <Json>[];
  final workItemLabelCandidateEvents = <Json>[];
  final workItemLabelEvents = <Json>[];
  Json? lastLabelMutationResponse;

  List<WorkItemLabel> workItemLabelList({required bool group}) {
    return workItemLabelsMap.putIfAbsent(
      group,
      () => _buildDefaultWorkItemLabels(group: group),
    );
  }

  List<WorkItemLabel> _buildDefaultWorkItemLabels({required bool group}) {
    return [
      _buildWorkItemLabel(group: group, index: 1),
      _buildWorkItemLabel(group: group, index: 2),
    ];
  }

  WorkItemLabel _buildWorkItemLabel({required bool group, required int index}) {
    final idNumber = (group ? 70000 : 50000) + index;
    final id = group
        ? 'gid://gitlab/GroupLabel/$idNumber'
        : 'gid://gitlab/ProjectLabel/$idNumber';
    final title = switch (index) {
      1 => 'workflow::backend::review',
      2 => 'priority::high',
      3 => '::value',
      4 => 'a::',
      5 => 'a::b::c',
      6 => '範疇::前端::審查',
      7 => '狀態::進行中',
      8 => 'plain',
      9 => '標籤CJK',
      10 => 'contrast::bad',
      _ => group ? '群組標籤$index' : '專案標籤$index',
    };
    final color = switch (index) {
      1 => '#1068BF',
      2 => '#428BCA',
      3 => '#E0E0E0',
      4 => '#2EA44F',
      5 => '#D9534F',
      6 => '#6F42C1',
      7 => '#F0AD4E',
      8 => '#5CB85C',
      9 => '#003366',
      10 => '#1068BF',
      _ => '#1068BF',
    };
    final textColor = switch (index) {
      3 => '#000000',
      7 => '#000000',
      10 => '#1068BF',
      _ => '#FFFFFF',
    };
    return WorkItemLabel(
      id: id,
      title: title,
      color: color,
      textColor: textColor,
    );
  }

  void setWorkItemLabelCount({required bool group, required int count}) {
    workItemLabelsMap[group] = [
      for (var number = 1; number <= count; number++)
        _buildWorkItemLabel(group: group, index: number),
    ];
  }

  void resetWorkItemLabels() {
    workItemLabelMetadataAllowed = true;
    workItemLabelReadWorkItemAllowed = true;
    workItemLabelWidgetPresent = true;
    workItemLabelAllowsScoped = WorkItemLabelAllowsScoped.allowed;
    failNextWorkItemLabelCandidates = false;
    partialNextWorkItemLabelCandidates = false;
    failNextWorkItemLabelAcknowledgement = false;
    silentDenyNextWorkItemLabelMutation = false;
    mismatchNextWorkItemLabelReadback = false;
    _labelReadbackMismatchArmed = false;
    malformNextLabelRead = false;
    workItemLabelRevisionDuringPagination = false;
    setWorkItemLabelCount(group: false, count: 2);
    setWorkItemLabelCount(group: true, count: 2);
    workItemLabelReads.clear();
    workItemLabelCandidateEvents.clear();
    workItemLabelEvents.clear();
    lastLabelMutationResponse = null;
  }

  void reviseWorkItemLabel({required bool group}) {
    final id = group
        ? 'gid://gitlab/WorkItem/1041'
        : 'gid://gitlab/WorkItem/1031';
    _workItemRevisions[id] = (_workItemRevisions[id] ?? 0) + 1;
  }

  List<WorkItemLabel> _labelCandidates({required bool group}) {
    final list = <WorkItemLabel>[];
    if (group) {
      for (var i = 1; i <= 100; i++) {
        final id = 'gid://gitlab/GroupLabel/${90000 + i}';
        final title = switch (i) {
          1 => 'workflow::backend::done',
          2 => 'workflow::frontend::review',
          3 => 'priority::low',
          4 => 'priority::urgent',
          5 => '::value',
          6 => 'a::',
          7 => 'a::b::c',
          8 => '範疇::後端',
          9 => 'group::high',
          10 => 'contrast::bad',
          _ => '群組候選${i.toString().padLeft(2, '0')}',
        };
        final color = switch (i) {
          3 => '#2EA44F',
          4 => '#D9534F',
          5 => '#E0E0E0',
          8 => '#F0AD4E',
          10 => '#1068BF',
          _ => '#1068BF',
        };
        final textColor = switch (i) {
          5 => '#000000',
          8 => '#000000',
          10 => '#1068BF',
          _ => '#FFFFFF',
        };
        list.add(
          WorkItemLabel(
            id: id,
            title: title,
            color: color,
            textColor: textColor,
          ),
        );
      }
    } else {
      for (var i = 1; i <= 100; i++) {
        final isAncestorGroup = (i % 3 == 0) || i == 1 || i == 5 || i == 8;
        final id = isAncestorGroup
            ? 'gid://gitlab/GroupLabel/${80000 + i}'
            : 'gid://gitlab/ProjectLabel/${60000 + i}';
        final title = switch (i) {
          1 => 'workflow::backend::done',
          2 => 'workflow::frontend::review',
          3 => 'priority::low',
          4 => 'priority::urgent',
          5 => '::value',
          6 => 'a::',
          7 => 'a::b::c',
          8 => '範疇::後端',
          9 => 'bug',
          10 => 'contrast::bad',
          _ => '專案候選${i.toString().padLeft(2, '0')}',
        };
        final color = switch (i) {
          3 => '#2EA44F',
          4 => '#D9534F',
          5 => '#E0E0E0',
          8 => '#F0AD4E',
          10 => '#1068BF',
          _ => '#1068BF',
        };
        final textColor = switch (i) {
          5 => '#000000',
          8 => '#000000',
          10 => '#1068BF',
          _ => '#FFFFFF',
        };
        list.add(
          WorkItemLabel(
            id: id,
            title: title,
            color: color,
            textColor: textColor,
          ),
        );
      }
    }
    return list;
  }

  WorkItemLabel _lookupLabel(String id, {required bool group}) {
    for (final candidate in _labelCandidates(group: group)) {
      if (candidate.id == id) return candidate;
    }
    for (final candidate in _labelCandidates(group: !group)) {
      if (candidate.id == id) return candidate;
    }
    return WorkItemLabel(
      id: id,
      title: '標籤-$id',
      color: '#1068BF',
      textColor: '#FFFFFF',
    );
  }

  Json _workItemLabelPreviewWidget({required bool group}) {
    final list = workItemLabelList(group: group);
    final shown = list.take(50).map(_labelNode).toList(growable: false);
    final more = list.length > shown.length;
    return {
      'type': 'LABELS',
      'labels': {
        'nodes': shown,
        'pageInfo': {
          'hasNextPage': more,
          'endCursor': more ? 'qa-labels-preview:50' : null,
        },
      },
    };
  }

  Json _labelNode(WorkItemLabel label) {
    return {
      'id': label.id,
      'title': label.title,
      'color': label.color,
      'description': null,
      'textColor': label.textColor,
    };
  }

  final Map<bool, bool> workItemNoteEditAllowed = {false: true, true: true};
  // GitLab exposes the same adminNote permission for editing and deletion.
  Map<bool, bool> get workItemNoteDeleteAllowed => workItemNoteEditAllowed;
  final Map<bool, bool> workItemNoteReactionAllowed = {false: true, true: true};
  bool failNextWorkItemNoteUpdateAcknowledgement = false;
  bool failNextWorkItemNoteDeleteAcknowledgement = false;
  bool failNextWorkItemNoteReactionAcknowledgement = false;
  final Set<String> _deletedWorkItemNotes = {};
  final Map<String, List<Json>> _workItemNoteReactions = {};
  final Map<bool, List<Json>> _addedWorkItemDiscussions = {};
  final Map<String, List<Json>> _addedWorkItemReplies = {};
  final Map<String, Json> _editedWorkItemNotes = {};
  int _workItemNoteSequence = 0;
  int _workItemNoteEditSequence = 0;
  final Map<String, int> _workItemRevisions = {};
  final Set<int> _doneTodos = {};

  Json _workItemMilestoneOwner({required bool group, required int index}) {
    if (group) {
      return {
        'project': null,
        'group': {
          'id': index.isEven ? 'gid://gitlab/Group/84' : 'gid://gitlab/Group/8',
          'fullPath': index.isEven ? 'qa/synthetic-group' : 'qa',
        },
      };
    }
    if (index % 5 == 0) {
      return {
        'project': null,
        'group': {'id': 'gid://gitlab/Group/4', 'fullPath': 'studio'},
      };
    }
    return {
      'project': {
        'id': 'gid://gitlab/Project/42',
        'fullPath': 'studio/mobile-workspace',
      },
      'group': null,
    };
  }

  String _workItemMilestoneWebPath(Json owner, int iid) {
    final project = owner['project'];
    if (project is Map) {
      return '/${project['fullPath']}/-/milestones/$iid';
    }
    final group = owner['group'] as Map;
    return '/groups/${group['fullPath']}/-/milestones/$iid';
  }

  Json _closedWorkItemMilestone({required bool group}) {
    final number = group ? 915 : 905;
    final iid = group ? 15 : 5;
    final owner = _workItemMilestoneOwner(group: group, index: 0);
    return {
      'id': 'gid://gitlab/Milestone/$number',
      'iid': '$iid',
      'title': 'Closed expired ${group ? 'group' : 'project'} milestone',
      'state': 'CLOSED',
      'expired': true,
      'dueDate': '2026-09-15',
      'startDate': '2026-09-01',
      'webPath': _workItemMilestoneWebPath(owner, iid),
      ...owner,
    };
  }

  List<Json> workItemMilestoneCandidates({
    required bool group,
  }) => List<Json>.generate(65, (index) {
    final number = index + 1;
    final id = (group ? 2000 : 1000) + number;
    final owner = _workItemMilestoneOwner(group: group, index: number);
    return {
      'id': 'gid://gitlab/Milestone/$id',
      'iid': '$number',
      'title':
          '${number.isEven ? 'Release' : 'Planning'} ${number.toString().padLeft(2, '0')} ${group ? 'group' : 'project'}',
      'state': 'ACTIVE',
      'expired': number % 11 == 0,
      'dueDate': DateTime.utc(
        2026,
        10,
        1,
      ).add(Duration(days: number)).toIso8601String().substring(0, 10),
      'startDate': DateTime.utc(
        2026,
        9,
        1,
      ).add(Duration(days: number)).toIso8601String().substring(0, 10),
      'webPath': _workItemMilestoneWebPath(owner, number),
      ...owner,
    };
  }, growable: false);

  Json? workItemMilestoneById({required bool group, required String id}) {
    final closed = _closedWorkItemMilestone(group: group);
    if (closed['id'] == id) return closed;
    for (final milestone in workItemMilestoneCandidates(group: group)) {
      if (milestone['id'] == id) return milestone;
    }
    return null;
  }

  Json? currentWorkItemMilestone({required bool group}) {
    final id = workItemMilestoneIds[group];
    return id == null ? null : workItemMilestoneById(group: group, id: id);
  }

  Json workItemMilestoneRecord({required bool group}) => {
    ...workItemRecord(group: group),
    'userPermissions': {
      'readWorkItem': true,
      'setWorkItemMetadata': workItemMilestoneMetadataAllowed,
    },
    'widgets': [
      {
        'type': 'MILESTONE',
        'milestone': currentWorkItemMilestone(group: group),
      },
    ],
  };

  void reviseWorkItemMilestone({required bool group}) {
    final id = 'gid://gitlab/WorkItem/${group ? 1041 : 1031}';
    _workItemRevisions[id] = (_workItemRevisions[id] ?? 0) + 1;
  }

  Json workItemWeightRecord({required bool group}) => {
    ...workItemRecord(group: group),
    'userPermissions': {
      'readWorkItem': true,
      'adminWorkItem': workItemWeightAllowed,
    },
    'widgets': [
      if (workItemWeightPresent)
        {
          'type': 'WEIGHT',
          'weight': workItemWeights[group],
          'rolledUpWeight': group ? 12 : null,
          'rolledUpCompletedWeight': group ? 5 : null,
        },
    ],
  };

  void reviseWorkItemWeight({required bool group}) {
    final id = 'gid://gitlab/WorkItem/${group ? 1041 : 1031}';
    _workItemRevisions[id] = (_workItemRevisions[id] ?? 0) + 1;
  }

  List<Json> get groupListRows => List.generate(30, (index) {
    final root = index < 5;
    final project = index >= 10;
    final iid =
        41 +
        (root
            ? index
            : project
            ? index - 10
            : index - 5);
    final path = root
        ? 'qa/synthetic-group'
        : project
        ? 'qa/synthetic-group/child-project'
        : 'qa/synthetic-group/child-group';
    return <String, Object?>{
      'id': root && iid == 41
          ? 'gid://gitlab/WorkItem/1041'
          : 'gid://gitlab/WorkItem/qa-list-$index',
      'iid': '$iid',
      'title':
          'Synthetic ${root
              ? 'root'
              : project
              ? 'project'
              : 'subgroup'} item $iid',
      'state': index.isEven ? 'OPEN' : 'CLOSED',
      'createdAt': DateTime.utc(2026, 10, 1, 0, index).toIso8601String(),
      'updatedAt': DateTime.utc(2026, 10, 2, 0, 29 - index).toIso8601String(),
      'namespace': {
        'id': root
            ? 'gid://gitlab/Group/84'
            : project
            ? 'gid://gitlab/Namespaces::ProjectNamespace/194'
            : 'gid://gitlab/Group/85',
        'fullPath': path,
      },
      'project': project
          ? {'id': 'gid://gitlab/Project/94', 'fullPath': path}
          : null,
      'workItemType': {
        'id':
            'gid://gitlab/WorkItems::Type/qa-${project ? 'project' : 'group'}',
        'name': project ? 'Synthetic Task' : 'Synthetic Epic',
      },
      'description': 'Explicit read-only group list QA fixture.',
      'widgets': <Object?>[],
      'userPermissions': {'updateWorkItem': false},
    };
  }, growable: false);

  Json workItemRecord({required bool group}) {
    final id = group
        ? 'gid://gitlab/WorkItem/1041'
        : 'gid://gitlab/WorkItem/1031';
    return {
      'id': id,
      'iid': group ? '41' : '31',
      'title': workItemContentTitles[group],
      'state': _workItemStates[id],
      'createdAt': '2026-10-01T00:00:00Z',
      'updatedAt': DateTime.utc(
        2026,
        10,
        3,
        0,
        0,
        _workItemRevisions[id] ?? 0,
      ).toIso8601String(),
      'project': group
          ? null
          : {
              'id': 'gid://gitlab/Project/42',
              'fullPath': 'studio/mobile-workspace',
            },
      'namespace': {
        'id': group
            ? 'gid://gitlab/Group/84'
            : 'gid://gitlab/Namespaces::ProjectNamespace/42',
        'fullPath': group ? 'qa/synthetic-group' : 'studio/mobile-workspace',
      },
      'workItemType': {
        'id': 'gid://gitlab/WorkItems::Type/qa-${group ? 'group' : 'project'}',
        'name': group ? 'Synthetic Epic' : 'Synthetic Task',
        'widgetDefinitions': [
          {
            'type': 'LABELS',
            'allowsScopedLabels': switch (workItemLabelAllowsScoped) {
              WorkItemLabelAllowsScoped.allowed => true,
              WorkItemLabelAllowsScoped.disabled => false,
              WorkItemLabelAllowsScoped.unknown => null,
            },
          },
        ],
      },
      'userPermissions': {
        'readWorkItem': true,
        'updateWorkItem': true,
        'setWorkItemMetadata': workItemMilestoneMetadataAllowed,
        'adminWorkItem': workItemWeightAllowed,
        'createNote': true,
      },
      'description': workItemContentDescriptions[group],
      'widgets': [
        if (workItemDescriptionPresent[group] == true)
          {
            'type': 'DESCRIPTION',
            'description': workItemContentDescriptions[group],
            'edited': _editedWorkItemContent.contains(group),
            'lastEditedAt': _editedWorkItemContent.contains(group)
                ? DateTime.utc(
                    2026,
                    10,
                    3,
                    0,
                    0,
                    _workItemRevisions[id] ?? 0,
                  ).toIso8601String()
                : null,
          },
        {'type': 'NOTES', 'discussionLocked': false},
        if (workItemAssigneeWidgetPresent)
          _workItemAssigneePreviewWidget(group: group),
        if (workItemLabelWidgetPresent)
          _workItemLabelPreviewWidget(group: group),
        {
          'type': 'MILESTONE',
          'milestone': currentWorkItemMilestone(group: group),
        },
        if (workItemWeightPresent)
          {
            'type': 'WEIGHT',
            'weight': workItemWeights[group],
            'rolledUpWeight': group ? 12 : null,
            'rolledUpCompletedWeight': group ? 5 : null,
          },
      ],
    };
  }

  Json _workItemAssigneePreviewWidget({required bool group}) {
    final ids = workItemAssigneeIds[group] ?? const <String>[];
    final shown = ids.take(20).map(_assigneeUserNode).toList(growable: false);
    final more = ids.length > shown.length;
    return {
      'type': 'ASSIGNEES',
      'allowsMultipleAssignees': workItemAssigneeMultiple[group] ?? true,
      'assignees': {
        'nodes': shown,
        'pageInfo': {
          'hasNextPage': more,
          'endCursor': more ? 'qa-assignee-preview:20' : null,
        },
      },
    };
  }

  Json _assigneeUserNode(String id) {
    final number = int.tryParse(id.split('/').last) ?? 0;
    return {'id': id, 'name': '負責人$number', 'username': 'user$number'};
  }

  int? _assigneePageOffset(bool group, Object? after) {
    final total = workItemAssigneeIds[group]?.length ?? 0;
    if (after == null) return 0;
    if (after is! String || after.isEmpty) return null;
    final scope = group ? 'group' : 'project';
    final match = RegExp('^qa-assignees:$scope:(\\d+)\$').firstMatch(after);
    if (match == null) return null;
    final offset = int.tryParse(match.group(1)!);
    if (offset == null || offset <= 0 || offset % 100 != 0) return null;
    if (offset >= total) return null;
    return offset;
  }

  Json workItemAssigneeRecord({
    required bool group,
    Object? after,
    bool acknowledge = false,
  }) {
    final id = group
        ? 'gid://gitlab/WorkItem/1041'
        : 'gid://gitlab/WorkItem/1031';
    final offset = _assigneePageOffset(group, after);
    if (offset == null) {
      return {
        'errors': [
          {'message': 'Synthetic assignee cursor rejected'},
        ],
      };
    }
    final ids = workItemAssigneeIds[group] ?? const <String>[];
    final end = math.min(offset + 100, ids.length);
    final page = ids.sublist(offset, end);
    final hasNext = end < ids.length;
    final revision = _workItemRevisions[id] ?? 0;
    if (!acknowledge &&
        after == null &&
        hasNext &&
        workItemAssigneeRevisionDuringPagination) {
      workItemAssigneeRevisionDuringPagination = false;
      reviseWorkItemAssignee(group: group);
    }
    if (!acknowledge && after == null && malformNextAssigneeRead) {
      malformNextAssigneeRead = false;
      return {
        'data': {
          'currentUser': {'id': 'gid://gitlab/User/7'},
          'workItem': {'id': id, 'widgets': 'malformed'},
        },
      };
    }
    var nodes = page.map(_assigneeUserNode).toList(growable: false);
    if (!acknowledge && after == null && _assigneeReadbackMismatchArmed) {
      _assigneeReadbackMismatchArmed = false;
      if (nodes.isEmpty) {
        nodes = [_assigneeUserNode('gid://gitlab/User/9')];
      } else {
        nodes = [
          ...nodes.take(nodes.length - 1),
          _assigneeUserNode('gid://gitlab/User/9'),
        ];
      }
    }
    return {
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/7'},
        'workItem': {
          'id': id,
          'iid': group ? '41' : '31',
          'title': workItemContentTitles[group],
          'state': _workItemStates[id],
          'createdAt': '2026-10-01T00:00:00Z',
          'updatedAt': DateTime.utc(
            2026,
            10,
            3,
            0,
            0,
            revision,
          ).toIso8601String(),
          'description': workItemContentDescriptions[group],
          'project': group
              ? null
              : {
                  'id': 'gid://gitlab/Project/42',
                  'fullPath': 'studio/mobile-workspace',
                },
          'namespace': {
            'id': group
                ? 'gid://gitlab/Group/84'
                : 'gid://gitlab/Namespaces::ProjectNamespace/42',
            'fullPath': group
                ? 'qa/synthetic-group'
                : 'studio/mobile-workspace',
          },
          'workItemType': {
            'id':
                'gid://gitlab/WorkItems::Type/qa-${group ? 'group' : 'project'}',
            'name': group ? 'Synthetic Epic' : 'Synthetic Task',
          },
          'userPermissions': {
            'readWorkItem': true,
            'setWorkItemMetadata': workItemAssigneeMetadataAllowed,
          },
          'widgets': workItemAssigneeWidgetPresent
              ? [
                  {
                    'type': 'ASSIGNEES',
                    'allowsMultipleAssignees':
                        workItemAssigneeMultiple[group] ?? true,
                    'assignees': {
                      'nodes': nodes,
                      'pageInfo': {
                        'hasNextPage': hasNext,
                        'endCursor': hasNext
                            ? 'qa-assignees:${group ? 'group' : 'project'}:$end'
                            : null,
                      },
                    },
                  },
                ]
              : <Object?>[],
        },
      },
    };
  }

  Json? _assigneeMutationBody(Map<dynamic, dynamic> variables) {
    final input = variables['input'];
    if (input is! Map ||
        input.length != 2 ||
        !input.containsKey('id') ||
        !input.containsKey('assigneesWidget')) {
      return _assigneeRejectedMutation('Synthetic assignee input was rejected');
    }
    final widget = input['assigneesWidget'];
    final rawIds = widget is Map ? widget['assigneeIds'] : null;
    final ids = <String>[];
    final seen = <String>{};
    var validIds = widget is Map && widget.length == 1 && rawIds is List;
    if (validIds) {
      for (final raw in rawIds) {
        if (raw is! String ||
            !RegExp(r'^gid://gitlab/User/[1-9][0-9]*$').hasMatch(raw) ||
            !seen.add(raw)) {
          validIds = false;
          break;
        }
        ids.add(raw);
      }
    }
    final id = input['id'];
    final shaped = validIds && id is String && _workItemStates.containsKey(id);
    if (!shaped) {
      return _assigneeRejectedMutation('Synthetic assignee input was rejected');
    }
    final group = id == 'gid://gitlab/WorkItem/1041';
    final lostAck = failNextWorkItemAssigneeAcknowledgement;
    final accepted =
        workItemAssigneeMetadataAllowed &&
        workItemAssigneeWidgetPresent &&
        !lostAck;
    final eventInput = <String, Object?>{
      'id': id,
      'assigneesWidget': <String, Object?>{'assigneeIds': ids},
    };
    workItemAssigneeEvents.add({
      'input': eventInput,
      'accepted': accepted,
      'group': group,
    });
    final sorted = [...ids]..sort();
    debugPrint(
      '[work_item_assignee_qa] scope=${group ? 'group' : 'project'} '
      'assigneeIds=$sorted accepted=$accepted '
      'sequence=${workItemAssigneeEvents.length} input=$eventInput',
    );
    if (!workItemAssigneeMetadataAllowed || !workItemAssigneeWidgetPresent) {
      return {
        'data': {
          'workItemUpdate': {
            'errors': ['Synthetic assignee update not permitted'],
            'workItem': null,
          },
        },
      };
    }
    var stored = List<String>.from(ids);
    if (dropNextWorkItemAssigneeAckUser) {
      dropNextWorkItemAssigneeAckUser = false;
      if (stored.isNotEmpty) stored = stored.sublist(0, stored.length - 1);
    }
    workItemAssigneeIds[group] = stored;
    reviseWorkItemAssignee(group: group);
    if (failNextWorkItemAssigneeAcknowledgement) {
      failNextWorkItemAssigneeAcknowledgement = false;
      return null;
    }
    if (mismatchNextWorkItemAssigneeReadback) {
      mismatchNextWorkItemAssigneeReadback = false;
      _assigneeReadbackMismatchArmed = true;
    }
    final ack = workItemAssigneeRecord(group: group, acknowledge: true);
    final workItem = (ack['data'] as Json)['workItem'];
    return {
      'data': {
        'workItemUpdate': {'errors': <String>[], 'workItem': workItem},
      },
    };
  }

  Json _assigneeCandidates(
    String operation,
    String query,
    Map<dynamic, dynamic> variables,
  ) {
    final group = operation == 'MobileGroupAssigneeCandidates';
    final search = variables['search'];
    final paged =
        variables.containsKey('first') ||
        variables.containsKey('after') ||
        query.contains('autocompleteUsers(first');
    final path = group ? 'qa/synthetic-group' : 'studio/mobile-workspace';
    final scoped = variables['fullPath'] == path && search is String && !paged;
    final pool = [
      for (var number = 1; number <= 25; number++)
        {
          'id': 'gid://gitlab/User/${(group ? 8000 : 6000) + number}',
          'name':
              '${group ? '群組候選' : '專案候選'}${number.toString().padLeft(2, '0')}',
          'username': '${group ? 'gcand' : 'pcand'}$number',
        },
    ];
    final matched = scoped
        ? pool
              .where(
                (user) =>
                    search.isEmpty ||
                    (user['name'] as String).contains(search) ||
                    (user['username'] as String).contains(search),
              )
              .take(20)
              .toList(growable: false)
        : const <Json>[];
    workItemAssigneeCandidateEvents.add({
      'group': group,
      'search': search,
      'count': matched.length,
      'accepted': scoped,
      'paged': paged,
    });
    if (!scoped) {
      return {
        'errors': [
          {'message': 'Synthetic assignee candidates rejected'},
        ],
      };
    }
    final owner = group
        ? {
            'group': {
              'id': 'gid://gitlab/Group/84',
              'fullPath': path,
              'autocompleteUsers': matched,
            },
          }
        : {
            'project': {
              'id': 'gid://gitlab/Project/42',
              'fullPath': path,
              'autocompleteUsers': matched,
            },
          };
    return {
      'data': {
        'currentUser': {'id': 'gid://gitlab/User/7'},
        ...owner,
      },
    };
  }

  Json _assigneeRejectedMutation(String message) {
    return {
      'data': {
        'workItemUpdate': {
          'errors': [message],
          'workItem': null,
        },
      },
    };
  }

  Json workItemContentRecord({required bool group}) {
    final record = workItemRecord(group: group);
    return {
      ...record,
      'userPermissions': {'updateWorkItem': workItemContentAllowed},
      'widgets': (record['widgets'] as List)
          .where((widget) => (widget as Map)['type'] == 'DESCRIPTION')
          .toList(growable: false),
    };
  }

  void reviseWorkItemContent({required bool group}) {
    final id = 'gid://gitlab/WorkItem/${group ? 1041 : 1031}';
    workItemContentTitles[group] =
        'Synthetic concurrent ${group ? 'group' : 'project'} revision';
    _workItemRevisions[id] = (_workItemRevisions[id] ?? 0) + 1;
  }

  Json workItemNotificationsRecord({required bool group}) => {
    ...workItemRecord(group: group),
    'widgets': [
      {
        'type': 'NOTIFICATIONS',
        'subscribed': workItemNotificationSubscribed[group],
      },
    ],
  };

  List<Json> workItemActivityDiscussions({required bool group}) {
    final scope = group ? 'group' : 'project';
    final discussions = <Json>[
      ...List<Json>.generate(48, (index) {
        final number = index + 1;
        final system = number.isEven;
        final timestamp = DateTime.utc(
          2026,
          10,
          1,
          0,
          number,
        ).toIso8601String();
        Json note(String suffix, String body) => _withWorkItemNoteEdit({
          'id':
              'gid://gitlab/Note/${(group ? 200000 : 100000) + number * 2 + (suffix == 'reply' ? 1 : 0)}',
          'system': system,
          'systemNoteIconName': system ? 'status' : null,
          'body': body,
          'createdAt': timestamp,
          'updatedAt': timestamp,
          'author': {
            'id': 'gid://gitlab/User/7',
            'name': 'Synthetic Reader',
            'username': 'synthetic-reader',
          },
        });
        return {
          'id': 'gid://gitlab/Discussion/qa-$scope-$number',
          'replyId': 'gid://gitlab/Discussion/qa-$scope-reply-$number',
          'createdAt': timestamp,
          'notes': {
            'nodes': [
              note(
                'root',
                system
                    ? 'Synthetic history $number'
                    : 'Synthetic comment $number',
              ),
              if (number == 1) note('reply', 'Synthetic reply 1'),
              ...?_addedWorkItemReplies['gid://gitlab/Discussion/qa-$scope-$number'],
            ],
            'pageInfo': {'hasNextPage': false, 'endCursor': null},
          },
        };
      }),
      for (final discussion in _addedWorkItemDiscussions[group] ?? <Json>[])
        {
          ...discussion,
          'notes': {
            'nodes': [
              for (final raw in ((discussion['notes'] as Map)['nodes'] as List))
                _withWorkItemNoteEdit(raw as Json),
              for (final raw
                  in _addedWorkItemReplies[discussion['id']] ?? <Json>[])
                _withWorkItemNoteEdit(raw),
            ],
            'pageInfo': {'hasNextPage': false, 'endCursor': null},
          },
        },
    ];
    return [
      for (final discussion in discussions)
        if (((discussion['notes'] as Map)['nodes'] as List).any(
          (note) => !_deletedWorkItemNotes.contains((note as Map)['id']),
        ))
          {
            ...discussion,
            'notes': {
              'nodes': [
                for (final note
                    in (discussion['notes'] as Map)['nodes'] as List)
                  if (!_deletedWorkItemNotes.contains((note as Map)['id']))
                    note,
              ],
              'pageInfo': {'hasNextPage': false, 'endCursor': null},
            },
          },
    ];
  }

  List<Json> _reactionsForNote(String noteId) =>
      _workItemNoteReactions.putIfAbsent(
        noteId,
        () => [
          {
            'name': 'thumbsup',
            'unicode': '👍',
            'user': {'id': 'gid://gitlab/User/9'},
          },
        ],
      );

  List<Json> workItemNoteReactionRecords(String noteId) => [
    for (final reaction in _reactionsForNote(noteId))
      {
        ...reaction,
        'user': {...reaction['user'] as Map},
      },
  ];

  bool _deleteWorkItemFixtureNote(Map<Object?, Object?> input) {
    final noteId = input['id'];
    final located = noteId is String
        ? _locateWorkItemActivityNote(noteId)
        : null;
    if (located == null ||
        located.note['system'] == true ||
        workItemNoteEditAllowed[located.group] != true) {
      return false;
    }
    _deletedWorkItemNotes.add(noteId as String);
    workItemNoteDeleteEvents.add({
      'scope': located.group ? 'group' : 'project',
      'noteId': noteId,
    });
    debugPrint(
      '[work_item_note_delete_qa] scope=${located.group ? 'group' : 'project'} writes=${workItemNoteDeleteEvents.length}',
    );
    return true;
  }

  Json? _reactToWorkItemFixtureNote(
    Map<Object?, Object?> input, {
    required bool awarded,
  }) {
    final noteId = input['awardableId'];
    final name = input['name'];
    final located = noteId is String
        ? _locateWorkItemActivityNote(noteId)
        : null;
    if (located == null ||
        name is! String ||
        located.note['system'] == true ||
        workItemNoteReactionAllowed[located.group] != true) {
      return null;
    }
    final reactions = _reactionsForNote(noteId as String);
    reactions.removeWhere(
      (r) =>
          r['name'] == name &&
          (r['user'] as Map)['id'] == 'gid://gitlab/User/7',
    );
    final reaction = <String, Object?>{
      'name': name,
      'unicode': reactionGlyph(name),
      'user': {'id': 'gid://gitlab/User/7'},
    };
    if (awarded) reactions.add(reaction);
    workItemNoteReactionEvents.add({
      'scope': located.group ? 'group' : 'project',
      'noteId': noteId,
      'name': name,
      'awarded': awarded,
    });
    debugPrint(
      '[work_item_note_reaction_qa] scope=${located.group ? 'group' : 'project'} name=$name awarded=$awarded writes=${workItemNoteReactionEvents.length}',
    );
    return reaction;
  }

  Json _withWorkItemNoteEdit(Json note) {
    final edit = _editedWorkItemNotes[note['id']];
    return edit == null ? note : {...note, ...edit};
  }

  bool reviseWorkItemActivityNote(
    String noteId, {
    String body = 'Synthetic concurrent server edit',
  }) {
    final located = _locateWorkItemActivityNote(noteId);
    if (located == null || located.note['system'] == true) return false;
    _recordWorkItemNoteEdit(noteId, body);
    return true;
  }

  ({bool group, Json note})? _locateWorkItemActivityNote(String noteId) {
    for (final group in [false, true]) {
      final note = workItemActivityNoteRecord(noteId, group: group);
      if (note != null) return (group: group, note: note);
    }
    return null;
  }

  Json _recordWorkItemNoteEdit(String noteId, String body) {
    final sequence = ++_workItemNoteEditSequence;
    final edit = <String, Object?>{
      'body': body,
      'updatedAt': DateTime.utc(2026, 10, 3, 6, 0, sequence).toIso8601String(),
    };
    _editedWorkItemNotes[noteId] = edit;
    return edit;
  }

  Json? workItemActivityNoteRecord(String id, {required bool group}) {
    for (final discussion in workItemActivityDiscussions(group: group)) {
      for (final raw in (discussion['notes'] as Map)['nodes'] as List) {
        final note = raw as Json;
        if (note['id'] != id) continue;
        return {
          ...note,
          'internal': false,
          'noteableType': 'Issue',
          'noteableId': group ? 1041 : 1031,
          'project': workItemRecord(group: group)['project'],
          'discussion': {
            'id': discussion['id'],
            'replyId': discussion['replyId'],
            'createdAt': discussion['createdAt'],
          },
        };
      }
    }
    return null;
  }

  Json? _createWorkItemFixtureNote(Map<Object?, Object?> input) {
    final id = input['noteableId'];
    final body = input['body'];
    final replyId = input['discussionId'];
    if (!_workItemStates.containsKey(id) ||
        body is! String ||
        body.trim().isEmpty ||
        (replyId != null && replyId is! String)) {
      return null;
    }
    final group = id == 'gid://gitlab/WorkItem/1041';
    Json? target;
    if (replyId != null) {
      final matches = workItemActivityDiscussions(
        group: group,
      ).where((entry) => entry['replyId'] == replyId);
      if (matches.length != 1) return null;
      target = matches.single;
    }
    final sequence = ++_workItemNoteSequence;
    final scope = group ? 'group' : 'project';
    final noteId = 'gid://gitlab/Note/${900000 + sequence}';
    final timestamp = DateTime.utc(
      2026,
      10,
      3,
      5,
      0,
      sequence,
    ).toIso8601String();
    final note = <String, dynamic>{
      'id': noteId,
      'system': false,
      'systemNoteIconName': null,
      'body': body,
      'createdAt': timestamp,
      'updatedAt': timestamp,
      'author': {
        'id': 'gid://gitlab/User/7',
        'name': 'Developer',
        'username': 'developer',
      },
    };
    if (target == null) {
      (_addedWorkItemDiscussions[group] ??= []).add({
        'id': 'gid://gitlab/Discussion/qa-$scope-added-$sequence',
        'replyId':
            'gid://gitlab/IndividualNoteDiscussion/qa-$scope-added-$sequence',
        'createdAt': timestamp,
        'notes': {
          'nodes': [note],
        },
      });
    } else {
      (_addedWorkItemReplies[target['id'] as String] ??= []).add(note);
    }
    _workItemRevisions[id as String] = (_workItemRevisions[id] ?? 0) + 1;
    workItemNoteEvents.add({
      'scope': scope,
      'reply': replyId != null,
      'noteId': noteId,
    });
    debugPrint(
      '[work_item_note_qa] scope=$scope reply=${replyId != null} writes=${workItemNoteEvents.length}',
    );
    return workItemActivityNoteRecord(noteId, group: group);
  }

  Json? _updateWorkItemFixtureNote(Map<Object?, Object?> input) {
    final noteId = input['id'];
    final body = input['body'];
    if (noteId is! String || body is! String || body.trim().isEmpty) {
      return null;
    }
    final located = _locateWorkItemActivityNote(noteId);
    if (located == null ||
        located.note['system'] == true ||
        workItemNoteEditAllowed[located.group] != true) {
      return null;
    }
    _recordWorkItemNoteEdit(noteId, body);
    workItemNoteEditEvents.add({
      'scope': located.group ? 'group' : 'project',
      'noteId': noteId,
      'body': body,
    });
    debugPrint(
      '[work_item_note_edit_qa] scope=${located.group ? 'group' : 'project'} writes=${workItemNoteEditEvents.length}',
    );
    return workItemActivityNoteRecord(noteId, group: located.group);
  }

  Json workItemActivityRecord({
    required bool group,
    required String filter,
    required String sort,
    required Object? after,
  }) {
    final scope = group ? 'group' : 'project';
    final prefix = 'activity:$scope:$filter:$sort:';
    final offset = after == null
        ? 0
        : after is String && after.startsWith(prefix)
        ? int.tryParse(after.substring(prefix.length))
        : null;
    if (offset == null || offset < 0 || offset > 1000) {
      throw StateError('Invalid synthetic activity cursor');
    }
    final entries = workItemActivityDiscussions(group: group);
    final selected = entries.where((entry) {
      final system = ((entry['notes'] as Map)['nodes'] as List).first['system'];
      return filter == 'ALL_NOTES' ||
          filter == 'ONLY_COMMENTS' && system == false ||
          filter == 'ONLY_ACTIVITY' && system == true;
    }).toList();
    final ordered = sort == 'CREATED_DESC'
        ? selected.reversed.toList()
        : selected;
    if (offset > ordered.length) throw StateError('Invalid activity offset');
    final page = ordered.skip(offset).take(20).toList();
    final nextOffset = offset + page.length;
    final hasNext = nextOffset < ordered.length;
    return {
      ...workItemRecord(group: group),
      'widgets': [
        {
          'type': 'NOTES',
          'discussionLocked': false,
          'discussions': {
            'nodes': page,
            'pageInfo': {
              'hasNextPage': hasNext,
              'endCursor': hasNext ? '$prefix$nextOffset' : null,
            },
          },
        },
      ],
    };
  }

  late final _qaApi = testApi(
    adapter,
    host: 'https://qa.invalid:8443/gitlab',
    cdnAdapter: adapter,
  );

  @override
  GitLabApi get api => _qaApi;

  List<Json> get environmentRows => List<Json>.generate(120, (index) {
    final id = 17 + index;
    return {
      'id': id,
      'name': index == 0 ? 'staging/mobile' : 'qa/environment-${index + 1}',
      'state': index % 9 == 8 ? 'stopped' : 'available',
      'tier': index == 0 ? 'staging' : 'testing',
      'external_url': '',
    };
  }, growable: false);

  List<Json> get deploymentRows => List<Json>.generate(120, (index) {
    final sequence = 120 - index;
    return {
      'id': 1000 + sequence,
      'iid': sequence,
      'status': index % 11 == 10 ? 'failed' : 'success',
      'ref': index.isEven ? 'main' : 'release/qa',
      'sha':
          '${sequence.toRadixString(16).padLeft(8, '0')}${List.filled(32, 'a').join()}',
      'created_at':
          '2026-10-${((index % 3) + 1).toString().padLeft(2, '0')}T12:00:00Z',
      'environment': {'id': 17, 'name': 'staging/mobile'},
      'user': {'id': 7, 'username': 'developer'},
      'deployable': {
        'id': 5000 + sequence,
        'name': 'Synthetic deploy $sequence',
        'status': 'success',
      },
    };
  }, growable: false);

  List<Json> get todoRows => List<Json>.generate(30, (index) {
    final number = index + 1;
    return {
      'id': 7000 + number,
      'action_name': switch (index % 3) {
        0 => 'assigned',
        1 => 'review_requested',
        _ => 'build_failed',
      },
      'target_type': index.isEven ? 'Issue' : 'MergeRequest',
      'state': 'pending',
      'target': {
        'id': 8000 + number,
        'iid': number,
        'title':
            'Synthetic mobile QA todo ${number.toString().padLeft(2, '0')}',
      },
      'project': {'id': 42, 'path_with_namespace': 'qa/synthetic-mobile'},
      'author': {'id': 7, 'username': 'qa-developer'},
      'updated_at':
          '2026-10-${((index % 3) + 1).toString().padLeft(2, '0')}T12:00:00Z',
    };
  }, growable: false).where((row) => !_doneTodos.contains(row['id'])).toList();

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    if (request.uri.path == '/gitlab/api/graphql' && request.method == 'POST') {
      final raw = request.data is String
          ? jsonDecode(request.data as String)
          : request.data;
      final data = raw is Map ? raw : const <String, Object?>{};
      final query = data['query'] as String? ?? '';
      final variables = data['variables'] is Map
          ? data['variables'] as Map
          : const <String, Object?>{};
      final operation = RegExp(
        r'^(query|mutation)\s+(\w+)',
      ).firstMatch(query.trim())?.group(2);
      if (operation == 'MobileWorkItemActivityWriteAccess' &&
          _workItemStates.containsKey(variables['id'])) {
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/7'},
            'workItem': workItemRecord(
              group: variables['id'] == 'gid://gitlab/WorkItem/1041',
            ),
          },
        });
      }
      if (operation == 'MobileWorkItemActivityEditAccess' &&
          _workItemStates.containsKey(variables['workItemId'])) {
        final group = variables['workItemId'] == 'gid://gitlab/WorkItem/1041';
        final noteId = variables['noteId'];
        final note = noteId is String
            ? workItemActivityNoteRecord(noteId, group: group)
            : null;
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/7'},
            'workItem': workItemRecord(group: group),
            'note': note == null
                ? null
                : {
                    ...note,
                    'userPermissions': {
                      'adminNote': workItemNoteEditAllowed[group] == true,
                    },
                  },
          },
        });
      }
      if (operation == 'MobileWorkItemActivityReactionAccess' &&
          _workItemStates.containsKey(variables['workItemId'])) {
        final group = variables['workItemId'] == 'gid://gitlab/WorkItem/1041';
        final noteId = variables['noteId'];
        final note = noteId is String
            ? workItemActivityNoteRecord(noteId, group: group)
            : null;
        final reactions = note == null
            ? <Json>[]
            : _reactionsForNote(noteId as String);
        final after = variables['after'];
        final offset = after == null
            ? 0
            : int.parse((after as String).split(':').last);
        final page = reactions.skip(offset).take(50).toList();
        final hasNext = offset + page.length < reactions.length;
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/7'},
            'workItem': workItemRecord(group: group),
            'note': note == null
                ? null
                : {
                    ...note,
                    'userPermissions': {
                      'awardEmoji': workItemNoteReactionAllowed[group] == true,
                    },
                    'awardEmoji': {
                      'nodes': page,
                      'pageInfo': {
                        'hasNextPage': hasNext,
                        'endCursor': hasNext
                            ? 'qa-reactions:${offset + page.length}'
                            : null,
                      },
                    },
                  },
          },
        });
      }
      if ((operation == 'MobileWorkItemActivityReplyPreflight' ||
              operation == 'MobileWorkItemActivityNoteReadback' ||
              operation == 'MobileWorkItemActivityDeleteReadback') &&
          _workItemStates.containsKey(variables['workItemId'])) {
        final group = variables['workItemId'] == 'gid://gitlab/WorkItem/1041';
        final noteId =
            variables[operation == 'MobileWorkItemActivityReplyPreflight'
                ? 'anchorNoteId'
                : 'noteId'];
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/7'},
            'workItem': workItemRecord(group: group),
            operation == 'MobileWorkItemActivityReplyPreflight'
                ? 'anchor'
                : 'note': noteId is String
                ? workItemActivityNoteRecord(noteId, group: group)
                : null,
          },
        });
      }
      if (operation == 'MobileDestroyWorkItemActivityNote') {
        final input = variables['input'];
        final removed = input is Map && _deleteWorkItemFixtureNote(input);
        if (removed && failNextWorkItemNoteDeleteAcknowledgement) {
          failNextWorkItemNoteDeleteAcknowledgement = false;
          return jsonResponse({
            'message': 'Synthetic acknowledgement unavailable',
          }, status: 503);
        }
        return jsonResponse({
          'data': {
            'destroyNote': {
              'errors': removed
                  ? <String>[]
                  : ['Unknown or forbidden synthetic note target'],
            },
          },
        });
      }
      if (operation == 'MobileAddWorkItemActivityNoteReaction' ||
          operation == 'MobileRemoveWorkItemActivityNoteReaction') {
        final input = variables['input'];
        final awarded = operation == 'MobileAddWorkItemActivityNoteReaction';
        final reaction = input is Map
            ? _reactToWorkItemFixtureNote(input, awarded: awarded)
            : null;
        if (reaction != null && failNextWorkItemNoteReactionAcknowledgement) {
          failNextWorkItemNoteReactionAcknowledgement = false;
          return jsonResponse({
            'message': 'Synthetic acknowledgement unavailable',
          }, status: 503);
        }
        return jsonResponse({
          'data': {
            awarded ? 'awardEmojiAdd' : 'awardEmojiRemove': {
              'errors': reaction == null
                  ? ['Unknown or forbidden synthetic note target']
                  : <String>[],
              'awardEmoji': awarded ? reaction : null,
            },
          },
        });
      }
      if (operation == 'MobileCreateWorkItemActivityNote') {
        final input = variables['input'];
        final note = input is Map ? _createWorkItemFixtureNote(input) : null;
        return jsonResponse({
          'data': {
            'createNote': {
              'errors': note == null
                  ? ['Unknown synthetic note target']
                  : <String>[],
              'note': note,
            },
          },
        });
      }
      if (operation == 'MobileUpdateWorkItemActivityNote') {
        final input = variables['input'];
        final note = input is Map ? _updateWorkItemFixtureNote(input) : null;
        if (note != null && failNextWorkItemNoteUpdateAcknowledgement) {
          failNextWorkItemNoteUpdateAcknowledgement = false;
          return jsonResponse({
            'message': 'Synthetic acknowledgement unavailable',
          }, status: 503);
        }
        return jsonResponse({
          'data': {
            'updateNote': {
              'errors': note == null
                  ? ['Unknown or forbidden synthetic note target']
                  : <String>[],
              'note': note,
            },
          },
        });
      }
      if (operation == 'MobileGroupWorkItems' &&
          variables['path'] == 'qa/synthetic-group') {
        final typeIds = variables['typeIds'] as List?;
        final search = (variables['search'] as String? ?? '').toLowerCase();
        final rows = groupListRows.where((row) {
          final namespace = row['namespace'] as Map;
          final type = row['workItemType'] as Map;
          return (variables['includeDescendants'] == true ||
                  namespace['fullPath'] == 'qa/synthetic-group') &&
              (variables['state'] == 'all' ||
                  row['state'] ==
                      (variables['state'] == 'closed' ? 'CLOSED' : 'OPEN')) &&
              (row['title'] as String).toLowerCase().contains(search) &&
              (typeIds == null || typeIds.contains(type['id']));
        }).toList();
        final sort = variables['sort'] as String;
        final field = sort.startsWith('UPDATED') ? 'updatedAt' : 'createdAt';
        rows.sort((a, b) => (a[field] as String).compareTo(b[field] as String));
        final ordered = sort.endsWith('DESC') ? rows.reversed.toList() : rows;
        final after = variables['after'];
        final offset = after == null
            ? 0
            : int.parse((after as String).split('-').last);
        final page = ordered.skip(offset).take(20).toList();
        final hasNext = offset + page.length < ordered.length;
        return jsonResponse({
          'data': {
            'group': {
              'id': 'gid://gitlab/Group/84',
              'fullPath': 'qa/synthetic-group',
              'workItems': {
                'nodes': page,
                'pageInfo': {
                  'hasNextPage': hasNext,
                  'endCursor': hasNext
                      ? 'qa-group-list-${offset + page.length}'
                      : null,
                },
              },
            },
          },
        });
      }
      if (operation == 'MobileNamespaceWorkItemTypes' &&
          variables['path'] == 'qa/synthetic-group') {
        return jsonResponse({
          'data': {
            'namespace': {
              'id': 'gid://gitlab/Group/84',
              'fullPath': 'qa/synthetic-group',
              'workItemTypes': {
                'nodes': [
                  for (final group in [true, false])
                    {
                      'id':
                          'gid://gitlab/WorkItems::Type/qa-${group ? 'group' : 'project'}',
                      'name': group ? 'Synthetic Epic' : 'Synthetic Task',
                      'enabled': true,
                      'isGroupWorkItemType': group,
                      'widgetDefinitions': <Object?>[],
                    },
                ],
                'pageInfo': {'hasNextPage': false, 'endCursor': null},
              },
            },
          },
        });
      }
      if (operation == 'MobileNamespaceWorkItem' &&
          !(variables['path'] == 'qa/synthetic-group' &&
              variables['iid'] == '41')) {
        final matches = groupListRows.where(
          (row) =>
              (row['namespace'] as Map)['fullPath'] == variables['path'] &&
              row['iid'] == variables['iid'],
        );
        if (matches.length == 1) {
          final row = matches.single;
          return jsonResponse({
            'data': {
              'namespace': {...row['namespace'] as Map, 'workItem': row},
            },
          });
        }
      }
      if (operation == 'MobileProjectWorkItem' &&
          variables['path'] == 'studio/mobile-workspace' &&
          variables['iid'] == '31') {
        return jsonResponse({
          'data': {
            'project': {
              'id': 'gid://gitlab/Project/42',
              'fullPath': 'studio/mobile-workspace',
              'workItems': {
                'nodes': [workItemRecord(group: false)],
                'pageInfo': {'hasNextPage': false, 'endCursor': null},
              },
            },
          },
        });
      }
      if (operation == 'MobileNamespaceWorkItem' &&
          variables['path'] == 'qa/synthetic-group' &&
          variables['iid'] == '41') {
        return jsonResponse({
          'data': {
            'namespace': {
              'id': 'gid://gitlab/Group/84',
              'fullPath': 'qa/synthetic-group',
              'workItem': workItemRecord(group: true),
            },
          },
        });
      }
      if ((operation == 'MobileWorkItemWeight' ||
              operation == 'MobileWorkItemWeightAttribute') &&
          _workItemStates.containsKey(variables['id'])) {
        final group = variables['id'] == 'gid://gitlab/WorkItem/1041';
        workItemWeightReads.add(operation!);
        return jsonResponse({
          'data': {
            if (operation == 'MobileWorkItemWeight')
              'currentUser': {'id': 'gid://gitlab/User/7'},
            'workItem': workItemWeightRecord(group: group),
          },
        });
      }
      if (operation == 'MobileSetWorkItemWeight') {
        final input = variables['input'];
        final widget = input is Map ? input['weightWidget'] : null;
        final id = input is Map ? input['id'] : null;
        final weight = widget is Map ? widget['weight'] : null;
        final valid =
            input is Map &&
            input.length == 2 &&
            input.containsKey('id') &&
            input.containsKey('weightWidget') &&
            widget is Map &&
            widget.length == 1 &&
            widget.containsKey('weight') &&
            (weight == null ||
                (weight is int && weight >= 0 && weight <= 2147483647));
        if (valid && id is String && _workItemStates.containsKey(id)) {
          final group = id == 'gid://gitlab/WorkItem/1041';
          final accepted = workItemWeightAllowed && workItemWeightPresent;
          final eventInput = <String, Object?>{
            'id': id,
            'weightWidget': <String, Object?>{'weight': weight},
          };
          workItemWeightEvents.add({
            'input': eventInput,
            'accepted': accepted,
            'group': group,
          });
          debugPrint(
            '[work_item_weight_qa] scope=${group ? 'group' : 'project'} '
            'weight=${weight ?? 'clear'} accepted=$accepted '
            'sequence=${workItemWeightEvents.length} input=$eventInput',
          );
          if (!accepted) {
            return jsonResponse({
              'data': {
                'workItemUpdate': {
                  'workItem': null,
                  'errors': ['Synthetic weight update not permitted'],
                },
              },
            });
          }
          workItemWeights[group] = weight as int?;
          reviseWorkItemWeight(group: group);
          if (failNextWorkItemWeightAcknowledgement) {
            failNextWorkItemWeightAcknowledgement = false;
            return jsonResponse({
              'message': 'Synthetic weight acknowledgement failure',
            }, status: 503);
          }
          return jsonResponse({
            'data': {
              'workItemUpdate': {
                'errors': <String>[],
                'workItem': workItemWeightRecord(group: group),
              },
            },
          });
        }
        return jsonResponse({
          'errors': [
            {'message': 'Synthetic weight input was rejected'},
          ],
        });
      }
      if (operation == 'MobileWorkItemAssignees' &&
          _workItemStates.containsKey(variables['id'])) {
        final group = variables['id'] == 'gid://gitlab/WorkItem/1041';
        final body = workItemAssigneeRecord(
          group: group,
          after: variables['after'],
        );
        workItemAssigneeReads.add({
          'group': group,
          'after': variables['after'],
          'accepted': body.containsKey('data'),
        });
        return jsonResponse(body);
      }
      if (operation == 'MobileProjectAssigneeCandidates' ||
          operation == 'MobileGroupAssigneeCandidates') {
        return jsonResponse(_assigneeCandidates(operation!, query, variables));
      }
      if (operation == 'MobileSetWorkItemAssignees') {
        final body = _assigneeMutationBody(variables);
        if (body == null) {
          return jsonResponse({
            'message': 'Synthetic assignee acknowledgement failure',
          }, status: 503);
        }
        lastAssigneeMutationResponse = body;
        return jsonResponse(body);
      }
      if ((operation == 'MobileWorkItemMilestone' ||
              operation == 'MobileWorkItemMilestoneAttribute') &&
          _workItemStates.containsKey(variables['id'])) {
        final group = variables['id'] == 'gid://gitlab/WorkItem/1041';
        return jsonResponse({
          'data': {
            if (operation == 'MobileWorkItemMilestone')
              'currentUser': {'id': 'gid://gitlab/User/7'},
            'workItem': workItemMilestoneRecord(group: group),
          },
        });
      }
      if ((operation == 'MobileProjectWorkItemMilestones' &&
              variables['fullPath'] == 'studio/mobile-workspace') ||
          (operation == 'MobileGroupWorkItemMilestones' &&
              variables['fullPath'] == 'qa/synthetic-group')) {
        final group = operation == 'MobileGroupWorkItemMilestones';
        final search = (variables['search'] as String? ?? '').toLowerCase();
        final rawAfter = variables['after'];
        final offset = rawAfter == null
            ? 0
            : int.parse((rawAfter as String).split(':').last);
        final filtered = workItemMilestoneCandidates(group: group)
            .where(
              (milestone) =>
                  (milestone['title'] as String).toLowerCase().contains(search),
            )
            .toList(growable: false);
        final page = filtered.skip(offset).take(50).toList(growable: false);
        final hasNext = offset + page.length < filtered.length;
        workItemMilestonePickerReads.add({
          'group': group,
          'search': variables['search'],
          'after': rawAfter,
          'count': page.length,
        });
        debugPrint(
          '[work_item_milestone_picker_qa] '
          'scope=${group ? 'group' : 'project'} search=${variables['search']} '
          'after=$rawAfter count=${page.length} '
          'sequence=${workItemMilestonePickerReads.length}',
        );
        if (failNextWorkItemMilestoneCandidates) {
          failNextWorkItemMilestoneCandidates = false;
          return jsonResponse({
            'message': 'Synthetic milestone candidate failure',
          }, status: 503);
        }
        final root = {
          'id': group ? 'gid://gitlab/Group/84' : 'gid://gitlab/Project/42',
          'fullPath': group ? 'qa/synthetic-group' : 'studio/mobile-workspace',
          'milestones': {
            'nodes': page,
            'pageInfo': {
              'hasNextPage': hasNext,
              'endCursor': hasNext
                  ? 'qa-milestones:${offset + page.length}'
                  : null,
            },
          },
        };
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/7'},
            group ? 'group' : 'project': root,
          },
        });
      }
      if (operation == 'MobileSetWorkItemMilestone') {
        final input = variables['input'];
        final widget = input is Map ? input['milestoneWidget'] : null;
        final id = input is Map ? input['id'] : null;
        final validShape =
            input is Map &&
            input.length == 2 &&
            input.containsKey('id') &&
            input.containsKey('milestoneWidget') &&
            widget is Map &&
            widget.length == 1 &&
            widget.containsKey('milestoneId');
        final milestoneId = widget is Map ? widget['milestoneId'] : null;
        final validMilestoneId = milestoneId == null || milestoneId is String;
        if (validShape && validMilestoneId && _workItemStates.containsKey(id)) {
          final group = id == 'gid://gitlab/WorkItem/1041';
          final milestone = milestoneId is String
              ? workItemMilestoneById(group: group, id: milestoneId)
              : null;
          final accepted =
              workItemMilestoneMetadataAllowed &&
              (milestoneId == null || milestone != null);
          final eventInput = <String, Object?>{
            'id': id,
            'milestoneWidget': <String, Object?>{'milestoneId': milestoneId},
          };
          workItemMilestoneEvents.add({
            'group': group,
            'accepted': accepted,
            'input': eventInput,
          });
          debugPrint(
            '[work_item_milestone_qa] '
            'scope=${group ? 'group' : 'project'} '
            'milestoneId=${milestoneId ?? 'clear'} accepted=$accepted '
            'sequence=${workItemMilestoneEvents.length} input=$eventInput',
          );
          if (!accepted) {
            return jsonResponse({
              'data': {
                'workItemUpdate': {
                  'errors': ['Synthetic milestone update not permitted'],
                  'workItem': null,
                },
              },
            });
          }
          workItemMilestoneIds[group] = milestoneId as String?;
          _workItemRevisions[id as String] = (_workItemRevisions[id] ?? 0) + 1;
          if (failNextWorkItemMilestoneAcknowledgement) {
            failNextWorkItemMilestoneAcknowledgement = false;
            return jsonResponse({
              'message': 'Synthetic milestone acknowledgement failure',
            }, status: 503);
          }
          return jsonResponse({
            'data': {
              'workItemUpdate': {
                'errors': <String>[],
                'workItem': workItemMilestoneRecord(group: group),
              },
            },
          });
        }
      }
      if (operation == 'MobileWorkItemContent' &&
          _workItemStates.containsKey(variables['id'])) {
        final id = variables['id'] as String;
        workItemContentReads.add(id);
        debugPrint(
          '[work_item_content_read_qa] '
          'scope=${id.endsWith('/1041') ? 'group' : 'project'} '
          'sequence=${workItemContentReads.length}',
        );
        if (failNextWorkItemContentRead) {
          failNextWorkItemContentRead = false;
          return jsonResponse({
            'message': 'Synthetic content read failure',
          }, status: 503);
        }
        return jsonResponse({
          'data': {
            'currentUser': workItemContentAuthenticated
                ? {'id': 'gid://gitlab/User/7'}
                : null,
            'workItem': workItemContentRecord(group: id.endsWith('/1041')),
          },
        });
      }
      if (operation == 'MobileUpdateWorkItemContent') {
        final input = variables['input'] is Map
            ? variables['input'] as Map
            : const <String, Object?>{};
        final id = input['id'];
        final descriptionWidget = input['descriptionWidget'];
        final title = input['title'];
        final description = descriptionWidget is Map
            ? descriptionWidget['description']
            : null;
        if (_workItemStates.containsKey(id) &&
            (!input.containsKey('title') || title is String) &&
            (!input.containsKey('descriptionWidget') ||
                description is String)) {
          final group = id == 'gid://gitlab/WorkItem/1041';
          final allowed =
              workItemContentAuthenticated &&
              workItemContentAllowed &&
              workItemContentWritesAllowed &&
              (!input.containsKey('descriptionWidget') ||
                  workItemDescriptionPresent[group] == true);
          workItemContentEvents.add({
            'id': id,
            'group': group,
            'accepted': allowed,
            'title': title,
            'descriptionWidget': descriptionWidget,
            'fields': input.keys.where((key) => key != 'id').toList(),
          });
          debugPrint(
            '[work_item_content_qa] scope=${group ? 'group' : 'project'} '
            'accepted=$allowed sequence=${workItemContentEvents.length} '
            'title=${input.containsKey('title')} description=${input.containsKey('descriptionWidget')}',
          );
          if (!allowed) {
            return jsonResponse({
              'data': {
                'workItemUpdate': {
                  'errors': ['Synthetic content update not permitted'],
                  'workItem': null,
                },
              },
            });
          }
          if (input.containsKey('title')) {
            workItemContentTitles[group] = title as String;
          }
          if (input.containsKey('descriptionWidget')) {
            workItemContentDescriptions[group] = description as String;
            _editedWorkItemContent.add(group);
          }
          _workItemRevisions[id as String] = (_workItemRevisions[id] ?? 0) + 1;
          if (failNextWorkItemContentAcknowledgement) {
            failNextWorkItemContentAcknowledgement = false;
            return jsonResponse({
              'message': 'Synthetic content acknowledgement failure',
            }, status: 503);
          }
          return jsonResponse({
            'data': {
              'workItemUpdate': {
                'errors': <String>[],
                'workItem': workItemContentRecord(group: group),
              },
            },
          });
        }
      }
      if (operation == 'MobileWorkItemNotifications' &&
          _workItemStates.containsKey(variables['id'])) {
        workItemNotificationReads.add(variables['id'] as String);
        debugPrint(
          '[work_item_notification_read_qa] '
          'scope=${variables['id'] == 'gid://gitlab/WorkItem/1041' ? 'group' : 'project'} '
          'sequence=${workItemNotificationReads.length}',
        );
        if (failNextWorkItemNotificationRead) {
          failNextWorkItemNotificationRead = false;
          return jsonResponse({
            'message': 'Synthetic notification read failure',
          }, status: 503);
        }
        return jsonResponse({
          'data': {
            'currentUser': workItemNotificationAuthenticated
                ? {'id': 'gid://gitlab/User/7'}
                : null,
            'workItem': workItemNotificationsRecord(
              group: variables['id'] == 'gid://gitlab/WorkItem/1041',
            ),
          },
        });
      }
      if (operation == 'MobileSetWorkItemNotifications') {
        final input = variables['input'] is Map
            ? variables['input'] as Map
            : const <String, Object?>{};
        final id = input['id'];
        final subscribed = input['subscribed'];
        if (_workItemStates.containsKey(id) && subscribed is bool) {
          final group = id == 'gid://gitlab/WorkItem/1041';
          final allowed =
              workItemNotificationAuthenticated &&
              workItemNotificationWritesAllowed;
          workItemNotificationEvents.add({
            'id': id,
            'group': group,
            'subscribed': subscribed,
            'accepted': allowed,
          });
          debugPrint(
            '[work_item_notification_qa] '
            'scope=${group ? 'group' : 'project'} '
            'subscribed=$subscribed accepted=$allowed '
            'sequence=${workItemNotificationEvents.length}',
          );
          if (!allowed) {
            return jsonResponse({
              'data': {
                'workItemSubscribe': {
                  'errors': ['Synthetic subscription not permitted'],
                  'workItem': null,
                },
              },
            });
          }
          workItemNotificationSubscribed[group] = subscribed;
          if (failNextWorkItemNotificationAcknowledgement) {
            failNextWorkItemNotificationAcknowledgement = false;
            return jsonResponse({
              'message': 'Synthetic notification acknowledgement failure',
            }, status: 503);
          }
          return jsonResponse({
            'data': {
              'workItemSubscribe': {
                'errors': <String>[],
                'workItem': workItemNotificationsRecord(group: group),
              },
            },
          });
        }
      }
      if (operation == 'MobileWorkItemState' &&
          _workItemStates.containsKey(variables['id'])) {
        return jsonResponse({
          'data': {
            'workItem': workItemRecord(
              group: variables['id'] == 'gid://gitlab/WorkItem/1041',
            ),
          },
        });
      }
      if (operation == 'MobileWorkItemState') {
        final matches = groupListRows.where(
          (row) => row['id'] == variables['id'],
        );
        if (matches.length == 1) {
          return jsonResponse({
            'data': {'workItem': matches.single},
          });
        }
      }
      if (operation == 'MobileWorkItemActivity' &&
          _workItemStates.containsKey(variables['id']) &&
          const [
            'ALL_NOTES',
            'ONLY_COMMENTS',
            'ONLY_ACTIVITY',
          ].contains(variables['filter']) &&
          const ['CREATED_ASC', 'CREATED_DESC'].contains(variables['sort'])) {
        return jsonResponse({
          'data': {
            'workItem': workItemActivityRecord(
              group: variables['id'] == 'gid://gitlab/WorkItem/1041',
              filter: variables['filter'] as String,
              sort: variables['sort'] as String,
              after: variables['after'],
            ),
          },
        });
      }
      if (operation == 'MobileUpdateWorkItemState') {
        final input = variables['input'] is Map
            ? variables['input'] as Map
            : const <String, Object?>{};
        final id = input['id'];
        final event = input['stateEvent'];
        if (_workItemStates.containsKey(id) &&
            const ['CLOSE', 'REOPEN'].contains(event)) {
          _workItemStates[id as String] = event == 'CLOSE' ? 'CLOSED' : 'OPEN';
          _workItemRevisions[id] = (_workItemRevisions[id] ?? 0) + 1;
          workItemStateEvents.add(event as String);
          return jsonResponse({
            'data': {
              'workItemUpdate': {
                'errors': <String>[],
                'workItem': workItemRecord(
                  group: id == 'gid://gitlab/WorkItem/1041',
                ),
              },
            },
          });
        }
      }
      if (operation == 'MobileWorkItemLabels' &&
          _workItemStates.containsKey(variables['id'])) {
        final id = variables['id'] as String;
        final group = id == 'gid://gitlab/WorkItem/1041';
        if (malformNextLabelRead) {
          malformNextLabelRead = false;
          return jsonResponse({
            'data': {
              'currentUser': {'id': 'gid://gitlab/User/7'},
              'workItem': {
                'id': id,
                'iid': group ? '41' : '31',
                'title': workItemContentTitles[group],
                'state': _workItemStates[id],
                'createdAt': '2026-10-01T00:00:00Z',
                'updatedAt': DateTime.utc(2026, 10, 3).toIso8601String(),
                'project': group
                    ? null
                    : {
                        'id': 'gid://gitlab/Project/42',
                        'fullPath': 'studio/mobile-workspace',
                      },
                'namespace': {
                  'id': group
                      ? 'gid://gitlab/Group/84'
                      : 'gid://gitlab/Namespaces::ProjectNamespace/42',
                  'fullPath': group
                      ? 'qa/synthetic-group'
                      : 'studio/mobile-workspace',
                },
                'workItemType': {
                  'id':
                      'gid://gitlab/WorkItems::Type/qa-${group ? 'group' : 'project'}',
                  'name': group ? 'Synthetic Epic' : 'Synthetic Task',
                  'widgetDefinitions': [
                    {'type': 'LABELS', 'allowsScopedLabels': true},
                  ],
                },
                'userPermissions': {
                  'readWorkItem': true,
                  'setWorkItemMetadata': true,
                },
                'widgets': 'malformed',
              },
            },
          });
        }
        final list = workItemLabelList(group: group);
        final rawAfter = variables['after'];
        var offset = 0;
        if (rawAfter is String) {
          if (rawAfter.startsWith('qa-labels:')) {
            offset = int.tryParse(rawAfter.split(':').last) ?? 0;
          } else {
            return jsonResponse({
              'errors': [
                {'message': 'Invalid cursor'},
              ],
            }, status: 400);
          }
        }
        if (workItemLabelRevisionDuringPagination && offset > 0) {
          workItemLabelRevisionDuringPagination = false;
          _workItemRevisions[id] = (_workItemRevisions[id] ?? 0) + 1;
        }
        final page = list.skip(offset).take(100).toList(growable: false);
        final hasNext = (offset + page.length) < list.length;
        final revision = _workItemRevisions[id] ?? 0;
        final updatedAt = _labelReadbackMismatchArmed
            ? DateTime.utc(2026, 10, 3, 0, 0, revision + 99).toIso8601String()
            : DateTime.utc(2026, 10, 3, 0, 0, revision).toIso8601String();
        if (_labelReadbackMismatchArmed) {
          _labelReadbackMismatchArmed = false;
        }
        final widgetDefinitions = [
          {
            'type': 'LABELS',
            'allowsScopedLabels': switch (workItemLabelAllowsScoped) {
              WorkItemLabelAllowsScoped.allowed => true,
              WorkItemLabelAllowsScoped.disabled => false,
              WorkItemLabelAllowsScoped.unknown => null,
            },
          },
        ];
        final widgets = workItemLabelWidgetPresent
            ? [
                {
                  'type': 'LABELS',
                  'labels': {
                    'nodes': page
                        .map(
                          (label) => {
                            'id': label.id,
                            'title': label.title,
                            'color': label.color,
                            'textColor': label.textColor,
                          },
                        )
                        .toList(growable: false),
                    'pageInfo': {
                      'hasNextPage': hasNext,
                      'endCursor': hasNext
                          ? 'qa-labels:${offset + page.length}'
                          : null,
                    },
                  },
                },
              ]
            : <Json>[];
        workItemLabelReads.add({
          'id': id,
          'group': group,
          'after': variables['after'],
          'accepted': true,
        });
        debugPrint(
          '[work_item_labels_read_qa] scope=${group ? 'group' : 'project'} '
          'after=${variables['after']} sequence=${workItemLabelReads.length}',
        );
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/7'},
            'workItem': {
              'id': id,
              'iid': group ? '41' : '31',
              'title': workItemContentTitles[group],
              'state': _workItemStates[id],
              'createdAt': '2026-10-01T00:00:00Z',
              'updatedAt': updatedAt,
              'project': group
                  ? null
                  : {
                      'id': 'gid://gitlab/Project/42',
                      'fullPath': 'studio/mobile-workspace',
                    },
              'namespace': {
                'id': group
                    ? 'gid://gitlab/Group/84'
                    : 'gid://gitlab/Namespaces::ProjectNamespace/42',
                'fullPath': group
                    ? 'qa/synthetic-group'
                    : 'studio/mobile-workspace',
              },
              'workItemType': {
                'id':
                    'gid://gitlab/WorkItems::Type/qa-${group ? 'group' : 'project'}',
                'name': group ? 'Synthetic Epic' : 'Synthetic Task',
                'widgetDefinitions': widgetDefinitions,
              },
              'userPermissions': {
                'readWorkItem': workItemLabelReadWorkItemAllowed,
                'setWorkItemMetadata': workItemLabelMetadataAllowed,
              },
              'widgets': widgets,
            },
          },
        });
      }
      if (operation == 'MobileProjectLabelCandidates' ||
          operation == 'MobileGroupLabelCandidates') {
        final group = operation == 'MobileGroupLabelCandidates';
        final expectedPath = group
            ? 'qa/synthetic-group'
            : 'studio/mobile-workspace';
        final fullPath = variables['fullPath'];
        final search = (variables['search'] as String? ?? '').trim();
        final rawAfter = variables['after'];
        final scoped = fullPath == expectedPath;
        if (failNextWorkItemLabelCandidates) {
          failNextWorkItemLabelCandidates = false;
          return jsonResponse({
            'errors': [
              {'message': 'Synthetic label candidate failure'},
            ],
          });
        }
        if (!scoped) {
          return jsonResponse({
            'errors': [
              {'message': 'Synthetic label candidates rejected: invalid scope'},
            ],
          }, status: 400);
        }
        final allCandidates = _labelCandidates(group: group);
        final filtered = allCandidates
            .where((label) {
              if (search.isEmpty) return true;
              return label.title.toLowerCase().contains(search.toLowerCase());
            })
            .toList(growable: false);
        var offset = 0;
        if (rawAfter is String) {
          if (rawAfter.startsWith('qa-label-candidate:')) {
            offset = int.tryParse(rawAfter.split(':').last) ?? 0;
          } else {
            return jsonResponse({
              'errors': [
                {'message': 'Invalid candidate cursor'},
              ],
            }, status: 400);
          }
        }
        final int takeCount;
        final bool hasNext;
        final String? endCursor;
        if (partialNextWorkItemLabelCandidates) {
          partialNextWorkItemLabelCandidates = false;
          takeCount = math.min(5, filtered.length - offset);
          hasNext = false;
          endCursor = null;
        } else {
          takeCount = math.min(20, math.max(0, filtered.length - offset));
          hasNext = (offset + takeCount) < filtered.length;
          endCursor = hasNext
              ? 'qa-label-candidate:${offset + takeCount}'
              : null;
        }
        final page = filtered
            .skip(offset)
            .take(takeCount)
            .toList(growable: false);
        workItemLabelCandidateEvents.add({
          'group': group,
          'search': variables['search'],
          'after': rawAfter,
          'count': page.length,
          'accepted': scoped,
        });
        debugPrint(
          '[work_item_labels_candidate_qa] scope=${group ? 'group' : 'project'} '
          'search=${variables['search']} after=$rawAfter count=${page.length} '
          'sequence=${workItemLabelCandidateEvents.length}',
        );
        final container = group
            ? {
                'group': {
                  'id': 'gid://gitlab/Group/84',
                  'fullPath': expectedPath,
                  'labels': {
                    'nodes': page
                        .map(
                          (l) => {
                            'id': l.id,
                            'title': l.title,
                            'color': l.color,
                            'textColor': l.textColor,
                          },
                        )
                        .toList(growable: false),
                    'pageInfo': {
                      'hasNextPage': hasNext,
                      'endCursor': endCursor,
                    },
                  },
                },
              }
            : {
                'project': {
                  'id': 'gid://gitlab/Project/42',
                  'fullPath': expectedPath,
                  'labels': {
                    'nodes': page
                        .map(
                          (l) => {
                            'id': l.id,
                            'title': l.title,
                            'color': l.color,
                            'textColor': l.textColor,
                          },
                        )
                        .toList(growable: false),
                    'pageInfo': {
                      'hasNextPage': hasNext,
                      'endCursor': endCursor,
                    },
                  },
                },
              };
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/7'},
            ...container,
          },
        });
      }
      if (operation == 'MobileUpdateWorkItemLabels') {
        final input = variables['input'] is Map
            ? variables['input'] as Map
            : const <String, Object?>{};
        final id = input['id'];
        final labelsWidget = input['labelsWidget'];
        final validId = id is String && _workItemStates.containsKey(id);
        final validWidget = labelsWidget is Map;
        final rawAdd = validWidget ? labelsWidget['addLabelIds'] : null;
        final rawRemove = validWidget ? labelsWidget['removeLabelIds'] : null;
        final addLabelIds = <String>[];
        final removeLabelIds = <String>[];
        var validGids = true;
        final gidPattern = RegExp(
          r'^gid://gitlab/(Label|GroupLabel|ProjectLabel)/[1-9][0-9]*$',
        );
        if (rawAdd != null) {
          if (rawAdd is! List) {
            validGids = false;
          } else {
            for (final raw in rawAdd) {
              if (raw is! String || !gidPattern.hasMatch(raw)) {
                validGids = false;
                break;
              }
              addLabelIds.add(raw);
            }
          }
        }
        if (rawRemove != null) {
          if (rawRemove is! List) {
            validGids = false;
          } else {
            for (final raw in rawRemove) {
              if (raw is! String || !gidPattern.hasMatch(raw)) {
                validGids = false;
                break;
              }
              removeLabelIds.add(raw);
            }
          }
        }
        if (!validId || !validWidget || !validGids) {
          return jsonResponse({
            'data': {
              'workItemUpdate': {
                'errors': [
                  'Synthetic label update was rejected: invalid input',
                ],
                'workItem': null,
              },
            },
          });
        }
        final group = id == 'gid://gitlab/WorkItem/1041';
        final accepted =
            workItemLabelMetadataAllowed &&
            workItemLabelWidgetPresent &&
            !failNextWorkItemLabelAcknowledgement;
        final eventInput = <String, Object?>{
          'id': id,
          'labelsWidget': <String, Object?>{
            if (addLabelIds.isNotEmpty) 'addLabelIds': addLabelIds,
            if (removeLabelIds.isNotEmpty) 'removeLabelIds': removeLabelIds,
          },
        };
        workItemLabelEvents.add({
          'input': eventInput,
          'accepted': accepted,
          'group': group,
        });
        debugPrint(
          '[work_item_labels_qa] scope=${group ? 'group' : 'project'} '
          'input=$eventInput accepted=$accepted sequence=${workItemLabelEvents.length}',
        );
        if (!workItemLabelMetadataAllowed || !workItemLabelWidgetPresent) {
          return jsonResponse({
            'data': {
              'workItemUpdate': {
                'errors': ['Synthetic label update not permitted'],
                'workItem': null,
              },
            },
          });
        }
        if (!silentDenyNextWorkItemLabelMutation) {
          final current = List<WorkItemLabel>.from(
            workItemLabelList(group: group),
          );
          final toRemove = removeLabelIds.toSet();
          final retained = current
              .where((l) => !toRemove.contains(l.id))
              .toList();
          final currentIds = retained.map((l) => l.id).toSet();
          for (final addId in addLabelIds) {
            if (!currentIds.contains(addId)) {
              retained.add(_lookupLabel(addId, group: group));
              currentIds.add(addId);
            }
          }
          workItemLabelsMap[group] = retained;
        } else {
          silentDenyNextWorkItemLabelMutation = false;
        }
        reviseWorkItemLabel(group: group);
        if (failNextWorkItemLabelAcknowledgement) {
          failNextWorkItemLabelAcknowledgement = false;
          return jsonResponse({
            'message': 'Synthetic label acknowledgement failure',
          }, status: 503);
        }
        if (mismatchNextWorkItemLabelReadback) {
          mismatchNextWorkItemLabelReadback = false;
          _labelReadbackMismatchArmed = true;
        }
        final revision = _workItemRevisions[id] ?? 0;
        final ackUpdatedAt = DateTime.utc(
          2026,
          10,
          3,
          0,
          0,
          revision,
        ).toIso8601String();
        final ackBody = {
          'data': {
            'workItemUpdate': {
              'errors': <String>[],
              'workItem': {'id': id, 'updatedAt': ackUpdatedAt},
            },
          },
        };
        lastLabelMutationResponse = ackBody;
        return jsonResponse(ackBody);
      }
      unhandled.add('POST $operation');
      return jsonResponse({
        'message': '404 Synthetic GraphQL operation not found',
      }, status: 404);
    }
    final segments = request.uri.pathSegments;
    final apiStart = segments.indexOf('v4');
    if (request.method == 'GET' &&
        apiStart >= 0 &&
        segments.length == apiStart + 3 &&
        segments[apiStart + 1] == 'projects' &&
        segments[apiStart + 2] == 'qa/synthetic-group/child-project') {
      return jsonResponse({
        ...projectRecord,
        'id': 94,
        'name': 'Synthetic descendant project',
        'path_with_namespace': 'qa/synthetic-group/child-project',
        'web_url':
            'https://qa.invalid:8443/gitlab/qa/synthetic-group/child-project',
      });
    }
    final path = segments.skip(apiStart + 1).join('/');
    final method = request.method;
    if (path == 'projects' && method == 'GET') {
      return performanceQaEnabled
          ? _performanceProjectsResponse(request)
          : _regularProjectsResponse(request);
    }
    if (path == 'projects/42' && method == 'GET') {
      return jsonResponse(_latestProjectRecord);
    }
    if (performanceQaEnabled) {
      if (path == 'projects/42/merge_requests/12/versions/1' &&
          method == 'GET') {
        return jsonResponse({
          'id': 1,
          'head_commit_sha': versionHeadSha,
          'base_commit_sha': versionBaseSha,
          'start_commit_sha': versionStartSha,
          'diffs': _performanceDiffs,
        });
      }
      if (path == 'projects/42/repository/tree' &&
          method == 'GET' &&
          request.uri.queryParameters['path'] == 'lib') {
        return jsonResponse([
          {
            'id': 'performance-large-code',
            'name': 'large_code.dart',
            'path': emulatorPerfQaLargeFilePath,
            'type': 'blob',
            'mode': '100644',
          },
        ]);
      }
      if (path == 'projects/42/repository/files/$emulatorPerfQaLargeFilePath' &&
          method == 'HEAD') {
        return ResponseBody.fromString(
          '',
          200,
          headers: {
            'x-gitlab-size': ['${utf8.encode(_performanceLargeFile).length}'],
            'x-gitlab-last-commit-id': [WorkspaceFixture.sha],
          },
        );
      }
      if (path ==
              'projects/42/repository/files/$emulatorPerfQaLargeFilePath/raw' &&
          method == 'GET') {
        return ResponseBody.fromString(_performanceLargeFile, 200);
      }
    }
    if (path == 'todos' && method == 'GET') {
      return jsonResponse(todoRows);
    }
    if (path == 'todos/mark_as_done' && method == 'POST') {
      _doneTodos.addAll(todoRows.map((row) => row['id'] as int));
      return Future.delayed(
        const Duration(milliseconds: 600),
        () => jsonResponse(<Json>[]),
      );
    }
    final todoDone = RegExp(r'^todos/(\d+)/mark_as_done$').firstMatch(path);
    if (todoDone != null && method == 'POST') {
      final id = int.parse(todoDone.group(1)!);
      if (id >= 7001 && id <= 7030 && _doneTodos.add(id)) {
        return Future.delayed(
          const Duration(milliseconds: 600),
          () => jsonResponse({'id': id, 'state': 'done'}),
        );
      }
    }
    if (path == 'projects/42/environments' && method == 'GET') {
      return jsonResponse(environmentRows);
    }
    if (path == 'projects/42/deployments' && method == 'GET') {
      final filter = request.uri.queryParameters['environment'];
      return jsonResponse(
        filter == null || filter == 'staging/mobile'
            ? deploymentRows
            : <Json>[],
      );
    }
    final jobMatch = RegExp(
      r'^projects/42/jobs/(\d+)(/trace)?$',
    ).firstMatch(path);
    if (jobMatch != null && method == 'GET') {
      final jobId = int.tryParse(jobMatch.group(1) ?? '') ?? 0;
      if (jobId < 5001 || jobId > 5120) {
        unhandled.add('$method $path');
        return jsonResponse({'message': '404 Job Not Found'}, status: 404);
      }
      if (jobMatch.group(2) == '/trace') {
        return ResponseBody.fromString(
          '[synthetic qa] deployment job $jobId\n'
          'Using fixed in-memory fixture data.\n'
          'Job completed successfully.\n',
          200,
          headers: const {
            'content-type': ['text/plain; charset=utf-8'],
            'x-gitlab-trace-eof': ['true'],
          },
        );
      }
      return jsonResponse(job(jobId));
    }
    if (path == 'projects/42/starrers' && method == 'GET') {
      return jsonResponse([
        if (_starred) {'user': account.user.toJson()},
      ]);
    }
    if ((path == 'projects/42/star' || path == 'projects/42/unstar') &&
        method == 'POST') {
      final next = path.endsWith('/star');
      if (_starred != next) {
        _starred = next;
        _starCount += next ? 1 : -1;
      }
      projectRecord['star_count'] = _starCount;
      return jsonResponse(_latestProjectRecord, status: 201);
    }
    return super.respond(request);
  }
}

final class _EmulatorQaRuntime {
  _EmulatorQaRuntime()
    : fixture = EmulatorQaFixture(),
      store = EmulatorQaMemoryAccountStore(),
      appearance = AppearanceController(MemoryAppearanceStore('dark|0')),
      shortcuts = LauncherShortcuts(
        FakeAppShortcutHost(),
        MemoryRecentProjectStore(),
      ) {
    store.accounts = [fixture.account];
    store.lastActive = fixture.account.key;
    session = SessionController(store)
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    shortcuts.bind(fixture.account.key);
    unawaited(appearance.load());
    unawaited(shortcuts.start());
  }

  final EmulatorQaFixture fixture;
  final navigatorKey = GlobalKey<NavigatorState>();
  final EmulatorQaMemoryAccountStore store;
  final AppearanceController appearance;
  final LauncherShortcuts shortcuts;
  late final SessionController session;

  void dispose() {
    shortcuts.dispose();
    appearance.dispose();
    session.dispose();
  }
}

class EmulatorQaApp extends StatefulWidget {
  const EmulatorQaApp({super.key});

  @override
  State<EmulatorQaApp> createState() => _EmulatorQaAppState();
}

class _EmulatorQaAppState extends State<EmulatorQaApp> {
  late _EmulatorQaRuntime _runtime;

  @override
  void initState() {
    super.initState();
    _runtime = _EmulatorQaRuntime();
  }

  void _resetSession() {
    final previous = _runtime;
    setState(() => _runtime = _EmulatorQaRuntime());
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  @override
  void dispose() {
    _runtime.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime;
    return ProviderScope(
      key: ValueKey(runtime),
      overrides: [sessionProvider.overrideWithValue(runtime.session)],
      child: ScrollPerformance(
        child: MaterialApp(
          key: ValueKey(runtime.session),
          navigatorKey: runtime.navigatorKey,
          debugShowCheckedModeBanner: false,
          theme: appTheme(Brightness.light),
          darkTheme: appTheme(Brightness.dark),
          locale: const Locale('zh', 'TW'),
          supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          builder: (context, child) => _QaChrome(
            session: runtime.session,
            fixture: runtime.fixture,
            navigatorKey: runtime.navigatorKey,
            onReset: _resetSession,
            child: child ?? const SizedBox.shrink(),
          ),
          home: _QaLanding(runtime: runtime),
        ),
      ),
    );
  }
}

class _QaChrome extends StatefulWidget {
  const _QaChrome({
    required this.session,
    required this.fixture,
    required this.navigatorKey,
    required this.onReset,
    required this.child,
  });

  final SessionController session;
  final EmulatorQaFixture fixture;
  final GlobalKey<NavigatorState> navigatorKey;
  final VoidCallback onReset;
  final Widget child;

  @override
  State<_QaChrome> createState() => _QaChromeState();
}

class _QaChromeState extends State<_QaChrome> {
  Future<void> _openNoteEditMenu() async {
    final control = await showMenu<_QaNoteEditControl>(
      context: widget.navigatorKey.currentContext!,
      positionBuilder: (_, constraints) => RelativeRect.fromLTRB(
        constraints.biggest.width - 48,
        constraints.biggest.height - 48,
        8,
        8,
      ),
      items: [
        PopupMenuItem(
          value: _QaNoteEditControl.contentAuthenticated,
          child: _qaMenuLabel('還原內容帳號'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.contentAnonymous,
          child: _qaMenuLabel('匿名讀取內容'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.allowContent,
          child: _qaMenuLabel('允許內容編輯'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.denyContent,
          child: _qaMenuLabel('撤回內容編輯權限'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.denyContentWrites,
          child: _qaMenuLabel('拒絕內容寫入'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.reviseContent,
          child: _qaMenuLabel('更新工作項目版本'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.failContentAcknowledgement,
          child: _qaMenuLabel('下次內容確認失敗'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.failContentRead,
          child: _qaMenuLabel('下次內容讀取失敗'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.absentDescription,
          child: _qaMenuLabel('移除說明 Widget'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.presentDescription,
          child: _qaMenuLabel('還原說明 Widget'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _QaNoteEditControl.allowWeight,
          child: _qaMenuLabel('允許權重設定'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.denyWeight,
          child: _qaMenuLabel('撤回權重權限'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.failWeightAcknowledgement,
          child: _qaMenuLabel('下次權重確認失敗'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.reviseWeight,
          child: _qaMenuLabel('更新權重工作項目版本'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.absentWeight,
          child: _qaMenuLabel('移除權重 Widget'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.presentWeight,
          child: _qaMenuLabel('還原權重 Widget'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _QaNoteEditControl.allowAssigneeMetadata,
          child: _qaMenuLabel('允許負責人設定'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.denyAssigneeMetadata,
          child: _qaMenuLabel('撤回負責人權限'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.absentAssigneeWidget,
          child: _qaMenuLabel('移除負責人 Widget'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.presentAssigneeWidget,
          child: _qaMenuLabel('還原負責人 Widget'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.singleAssignee,
          child: _qaMenuLabel('單人負責人'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.multipleAssignees,
          child: _qaMenuLabel('多人負責人'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.loseNextAssigneeAck,
          child: _qaMenuLabel('下次負責人確認失敗'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.dropNextAssigneeAckUser,
          child: _qaMenuLabel('下次負責人確認少一人'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.mismatchAssigneeReadback,
          child: _qaMenuLabel('下次負責人回讀不符'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.reviseAssignee,
          child: _qaMenuLabel('更新負責人工作項目版本'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.assigneeCount21,
          child: _qaMenuLabel('目前名單 21 人'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.assigneeCount101,
          child: _qaMenuLabel('目前名單 101 人'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.resetAssignees,
          child: _qaMenuLabel('還原負責人預設名單'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.assigneePagePastMax,
          child: _qaMenuLabel('負責人第 20 頁仍有下一頁'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.assigneeRevisionDuringPage,
          child: _qaMenuLabel('負責人翻頁時更新版本'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _QaNoteEditControl.allowMilestoneMetadata,
          child: _qaMenuLabel('允許里程碑設定'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.denyMilestoneMetadata,
          child: _qaMenuLabel('撤回里程碑權限'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.failMilestoneCandidates,
          child: _qaMenuLabel('下次里程碑候選讀取失敗'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.failMilestoneAcknowledgement,
          child: _qaMenuLabel('下次里程碑確認失敗'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.reviseMilestone,
          child: _qaMenuLabel('更新里程碑工作項目版本'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _QaNoteEditControl.notificationAuthenticated,
          child: _qaMenuLabel('還原通知帳號'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.notificationAnonymous,
          child: _qaMenuLabel('匿名讀取通知'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.allowNotificationWrites,
          child: _qaMenuLabel('允許訂閱寫入'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.denyNotificationWrites,
          child: _qaMenuLabel('拒絕訂閱寫入'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.failNotificationAcknowledgement,
          child: _qaMenuLabel('下次訂閱確認失敗'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.failNotificationRead,
          child: _qaMenuLabel('下次訂閱讀取失敗'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _QaNoteEditControl.allow,
          child: _qaMenuLabel('允許留言編輯'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.deny,
          child: _qaMenuLabel('拒絕留言編輯'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.revise,
          child: _qaMenuLabel('更新既有留言版本'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.failNextAcknowledgement,
          child: _qaMenuLabel('下次編輯確認失敗'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.allowReactions,
          child: _qaMenuLabel('允許留言表情'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.denyReactions,
          child: _qaMenuLabel('拒絕留言表情'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.failDeleteAcknowledgement,
          child: _qaMenuLabel('下次刪除確認失敗'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.failReactionAcknowledgement,
          child: _qaMenuLabel('下次表情確認失敗'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _QaNoteEditControl.allowLabelMetadata,
          child: _qaMenuLabel('允許標籤設定'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.denyLabelMetadata,
          child: _qaMenuLabel('撤回標籤權限'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.labelCount120,
          child: _qaMenuLabel('目前標籤 120 個'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.failLabelCandidatePage,
          child: _qaMenuLabel('下次標籤候選讀取失敗'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.partialLabelCandidatePage,
          child: _qaMenuLabel('下次標籤候選未完少頁'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.silentDenyLabelMutation,
          child: _qaMenuLabel('下次標籤寫入靜默略過'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.mismatchLabelReadback,
          child: _qaMenuLabel('下次標籤回讀不符'),
        ),
        PopupMenuItem(
          value: _QaNoteEditControl.resetLabels,
          child: _qaMenuLabel('還原標籤預設設定'),
        ),
      ],
    );
    if (control != null && mounted) {
      _applyNoteEditControl(context, control);
    }
  }

  Widget _qaMenuLabel(String text) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: 1.25,
    child: Text(text),
  );

  void _applyNoteEditControl(BuildContext context, _QaNoteEditControl control) {
    final message = switch (control) {
      _QaNoteEditControl.contentAuthenticated => () {
        widget.fixture.workItemContentAuthenticated = true;
        return '內容帳號：已還原';
      }(),
      _QaNoteEditControl.contentAnonymous => () {
        widget.fixture.workItemContentAuthenticated = false;
        return '內容帳號：匿名';
      }(),
      _QaNoteEditControl.allowContent => () {
        widget.fixture.workItemContentAllowed = true;
        widget.fixture.workItemContentWritesAllowed = true;
        return '內容編輯：允許';
      }(),
      _QaNoteEditControl.denyContent => () {
        widget.fixture.workItemContentAllowed = false;
        return '內容編輯權限：撤回';
      }(),
      _QaNoteEditControl.denyContentWrites => () {
        widget.fixture.workItemContentWritesAllowed = false;
        return '內容寫入：拒絕';
      }(),
      _QaNoteEditControl.reviseContent => () {
        widget.fixture.reviseWorkItemContent(group: false);
        widget.fixture.reviseWorkItemContent(group: true);
        return '工作項目版本已更新';
      }(),
      _QaNoteEditControl.failContentAcknowledgement => () {
        widget.fixture.failNextWorkItemContentAcknowledgement = true;
        return '下一次內容確認將失敗';
      }(),
      _QaNoteEditControl.failContentRead => () {
        widget.fixture.failNextWorkItemContentRead = true;
        return '下一次內容讀取將失敗';
      }(),
      _QaNoteEditControl.absentDescription => () {
        widget.fixture.workItemDescriptionPresent[false] = false;
        widget.fixture.workItemDescriptionPresent[true] = false;
        return '說明 Widget：已移除';
      }(),
      _QaNoteEditControl.presentDescription => () {
        widget.fixture.workItemDescriptionPresent[false] = true;
        widget.fixture.workItemDescriptionPresent[true] = true;
        return '說明 Widget：已還原';
      }(),
      _QaNoteEditControl.notificationAuthenticated => () {
        widget.fixture.workItemNotificationAuthenticated = true;
        return '通知帳號：已還原';
      }(),
      _QaNoteEditControl.notificationAnonymous => () {
        widget.fixture.workItemNotificationAuthenticated = false;
        return '通知帳號：匿名';
      }(),
      _QaNoteEditControl.allowNotificationWrites => () {
        widget.fixture.workItemNotificationWritesAllowed = true;
        return '訂閱寫入：允許';
      }(),
      _QaNoteEditControl.denyNotificationWrites => () {
        widget.fixture.workItemNotificationWritesAllowed = false;
        return '訂閱寫入：拒絕';
      }(),
      _QaNoteEditControl.failNotificationAcknowledgement => () {
        widget.fixture.failNextWorkItemNotificationAcknowledgement = true;
        return '下一次訂閱確認將失敗';
      }(),
      _QaNoteEditControl.failNotificationRead => () {
        widget.fixture.failNextWorkItemNotificationRead = true;
        return '下一次訂閱讀取將失敗';
      }(),
      _QaNoteEditControl.allowWeight => () {
        widget.fixture.workItemWeightAllowed = true;
        return '權重設定：允許';
      }(),
      _QaNoteEditControl.denyWeight => () {
        widget.fixture.workItemWeightAllowed = false;
        return '權重權限：撤回';
      }(),
      _QaNoteEditControl.failWeightAcknowledgement => () {
        widget.fixture.failNextWorkItemWeightAcknowledgement = true;
        return '下一次權重確認將失敗';
      }(),
      _QaNoteEditControl.reviseWeight => () {
        widget.fixture.reviseWorkItemWeight(group: false);
        widget.fixture.reviseWorkItemWeight(group: true);
        return '權重工作項目版本已更新';
      }(),
      _QaNoteEditControl.absentWeight => () {
        widget.fixture.workItemWeightPresent = false;
        return '權重 Widget：移除';
      }(),
      _QaNoteEditControl.presentWeight => () {
        widget.fixture.workItemWeightPresent = true;
        return '權重 Widget：還原';
      }(),
      _QaNoteEditControl.allowAssigneeMetadata => () {
        widget.fixture.workItemAssigneeMetadataAllowed = true;
        return '負責人設定：允許';
      }(),
      _QaNoteEditControl.denyAssigneeMetadata => () {
        widget.fixture.workItemAssigneeMetadataAllowed = false;
        return '負責人權限：撤回';
      }(),
      _QaNoteEditControl.absentAssigneeWidget => () {
        widget.fixture.workItemAssigneeWidgetPresent = false;
        return '負責人 Widget：移除';
      }(),
      _QaNoteEditControl.presentAssigneeWidget => () {
        widget.fixture.workItemAssigneeWidgetPresent = true;
        return '負責人 Widget：還原';
      }(),
      _QaNoteEditControl.singleAssignee => () {
        widget.fixture.workItemAssigneeMultiple[false] = false;
        widget.fixture.workItemAssigneeMultiple[true] = false;
        return '負責人：單人';
      }(),
      _QaNoteEditControl.multipleAssignees => () {
        widget.fixture.workItemAssigneeMultiple[false] = true;
        widget.fixture.workItemAssigneeMultiple[true] = true;
        return '負責人：多人';
      }(),
      _QaNoteEditControl.loseNextAssigneeAck => () {
        widget.fixture.failNextWorkItemAssigneeAcknowledgement = true;
        return '下一次負責人確認將失敗';
      }(),
      _QaNoteEditControl.dropNextAssigneeAckUser => () {
        widget.fixture.dropNextWorkItemAssigneeAckUser = true;
        return '下一次負責人確認將少一人';
      }(),
      _QaNoteEditControl.mismatchAssigneeReadback => () {
        widget.fixture.mismatchNextWorkItemAssigneeReadback = true;
        return '下一次負責人回讀將不符';
      }(),
      _QaNoteEditControl.reviseAssignee => () {
        widget.fixture.reviseWorkItemAssignee(group: false);
        widget.fixture.reviseWorkItemAssignee(group: true);
        return '負責人工作項目版本已更新';
      }(),
      _QaNoteEditControl.assigneeCount21 => () {
        widget.fixture.setWorkItemAssigneeCount(group: false, count: 21);
        widget.fixture.setWorkItemAssigneeCount(group: true, count: 21);
        return '目前負責人名單：21 人';
      }(),
      _QaNoteEditControl.assigneeCount101 => () {
        widget.fixture.setWorkItemAssigneeCount(group: false, count: 101);
        widget.fixture.setWorkItemAssigneeCount(group: true, count: 101);
        return '目前負責人名單：101 人';
      }(),
      _QaNoteEditControl.resetAssignees => () {
        widget.fixture.resetWorkItemAssignees();
        return '負責人名單已還原';
      }(),
      _QaNoteEditControl.assigneePagePastMax => () {
        widget.fixture.setWorkItemAssigneeCount(group: false, count: 2001);
        widget.fixture.setWorkItemAssigneeCount(group: true, count: 2001);
        return '負責人第 20 頁仍有下一頁';
      }(),
      _QaNoteEditControl.assigneeRevisionDuringPage => () {
        widget.fixture.workItemAssigneeRevisionDuringPagination = true;
        return '負責人翻頁時將更新版本';
      }(),
      _QaNoteEditControl.allowMilestoneMetadata => () {
        widget.fixture.workItemMilestoneMetadataAllowed = true;
        return '里程碑設定：允許';
      }(),
      _QaNoteEditControl.denyMilestoneMetadata => () {
        widget.fixture.workItemMilestoneMetadataAllowed = false;
        return '里程碑權限：撤回';
      }(),
      _QaNoteEditControl.failMilestoneCandidates => () {
        widget.fixture.failNextWorkItemMilestoneCandidates = true;
        return '下一次里程碑候選讀取將失敗';
      }(),
      _QaNoteEditControl.failMilestoneAcknowledgement => () {
        widget.fixture.failNextWorkItemMilestoneAcknowledgement = true;
        return '下一次里程碑確認將失敗';
      }(),
      _QaNoteEditControl.reviseMilestone => () {
        widget.fixture.reviseWorkItemMilestone(group: false);
        widget.fixture.reviseWorkItemMilestone(group: true);
        return '里程碑工作項目版本已更新';
      }(),
      _QaNoteEditControl.allow => () {
        widget.fixture.workItemNoteEditAllowed[false] = true;
        widget.fixture.workItemNoteEditAllowed[true] = true;
        return '留言編輯權限：允許';
      }(),
      _QaNoteEditControl.deny => () {
        widget.fixture.workItemNoteEditAllowed[false] = false;
        widget.fixture.workItemNoteEditAllowed[true] = false;
        return '留言編輯權限：拒絕';
      }(),
      _QaNoteEditControl.revise => () {
        final revised = [
          widget.fixture.reviseWorkItemActivityNote('gid://gitlab/Note/100002'),
          widget.fixture.reviseWorkItemActivityNote('gid://gitlab/Note/200002'),
        ].where((value) => value).length;
        return '留言版本已更新：$revised 則';
      }(),
      _QaNoteEditControl.failNextAcknowledgement => () {
        widget.fixture.failNextWorkItemNoteUpdateAcknowledgement = true;
        return '下一次編輯確認將失敗';
      }(),
      _QaNoteEditControl.allowReactions => () {
        widget.fixture.workItemNoteReactionAllowed[false] = true;
        widget.fixture.workItemNoteReactionAllowed[true] = true;
        return '留言表情權限：允許';
      }(),
      _QaNoteEditControl.denyReactions => () {
        widget.fixture.workItemNoteReactionAllowed[false] = false;
        widget.fixture.workItemNoteReactionAllowed[true] = false;
        return '留言表情權限：拒絕';
      }(),
      _QaNoteEditControl.failDeleteAcknowledgement => () {
        widget.fixture.failNextWorkItemNoteDeleteAcknowledgement = true;
        return '下一次刪除確認將失敗';
      }(),
      _QaNoteEditControl.failReactionAcknowledgement => () {
        widget.fixture.failNextWorkItemNoteReactionAcknowledgement = true;
        return '下一次表情確認將失敗';
      }(),
      _QaNoteEditControl.allowLabelMetadata => () {
        widget.fixture.workItemLabelMetadataAllowed = true;
        return '標籤設定：允許';
      }(),
      _QaNoteEditControl.denyLabelMetadata => () {
        widget.fixture.workItemLabelMetadataAllowed = false;
        return '標籤權限：撤回';
      }(),
      _QaNoteEditControl.labelCount120 => () {
        widget.fixture.setWorkItemLabelCount(group: false, count: 120);
        widget.fixture.setWorkItemLabelCount(group: true, count: 120);
        return '目前標籤：120 個';
      }(),
      _QaNoteEditControl.failLabelCandidatePage => () {
        widget.fixture.failNextWorkItemLabelCandidates = true;
        return '下一次標籤候選讀取將失敗';
      }(),
      _QaNoteEditControl.partialLabelCandidatePage => () {
        widget.fixture.partialNextWorkItemLabelCandidates = true;
        return '下一次標籤候選將提前結束';
      }(),
      _QaNoteEditControl.silentDenyLabelMutation => () {
        widget.fixture.silentDenyNextWorkItemLabelMutation = true;
        return '下一次標籤寫入將被靜默略過';
      }(),
      _QaNoteEditControl.mismatchLabelReadback => () {
        widget.fixture.mismatchNextWorkItemLabelReadback = true;
        return '下一次標籤回讀將不符';
      }(),
      _QaNoteEditControl.resetLabels => () {
        widget.fixture.resetWorkItemLabels();
        return '標籤設定已還原';
      }(),
    };
    debugPrint(
      '[work_item_note_edit_qa_control] action=${control.name} '
      'projectAllowed=${widget.fixture.workItemNoteEditAllowed[false]} '
      'groupAllowed=${widget.fixture.workItemNoteEditAllowed[true]} '
      'editEvents=${widget.fixture.workItemNoteEditEvents.length} '
      'nextAckFailure=${widget.fixture.failNextWorkItemNoteUpdateAcknowledgement}',
    );
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 1400),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        bottom: false,
        child: Column(
          verticalDirection: VerticalDirection.up,
          children: [
            Expanded(child: widget.child),
            ListenableBuilder(
              listenable: widget.session,
              builder: (context, _) => Container(
                key: const ValueKey('emulator-qa-controls'),
                width: double.infinity,
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton.icon(
                          onPressed: widget.onReset,
                          icon: const Icon(Icons.restart_alt, size: 18),
                          label: const Text('重設 Session'),
                        ),
                        OutlinedButton.icon(
                          onPressed: widget.session.active == null
                              ? null
                              : () => unawaited(widget.session.endSession()),
                          icon: const Icon(Icons.logout, size: 18),
                          label: const Text('結束 Session'),
                        ),
                      ],
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      child: Center(
                        child: Semantics(
                          button: true,
                          label: '留言編輯 QA',
                          child: IconButton(
                            key: const ValueKey(
                              'emulator-qa-note-edit-controls',
                            ),
                            icon: const Icon(
                              Icons.edit_note_outlined,
                              size: 20,
                            ),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 40,
                              height: 40,
                            ),
                            onPressed: widget.session.active == null
                                ? null
                                : _openNoteEditMenu,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Semantics(
              container: true,
              liveRegion: true,
              label: '合成資料 QA，無 GitLab 連線，來源 $emulatorUiQaCommit',
              child: Container(
                key: const ValueKey('emulator-qa-banner'),
                width: double.infinity,
                color: Theme.of(context).colorScheme.errorContainer,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Text(
                  '合成資料 QA · 無 GitLab 連線',
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum DatesQaViewMode {
  project,
  group,
  split,
  launcher,
}

class DatesParentQaScreen extends StatefulWidget {
  const DatesParentQaScreen({
    super.key,
    this.fixture,
    this.session,
    this.initialMode = DatesQaViewMode.project,
  });

  final WorkItemDatesParentFixture? fixture;
  final SessionController? session;
  final DatesQaViewMode initialMode;

  @override
  State<DatesParentQaScreen> createState() => _DatesParentQaScreenState();
}

class _DatesParentQaScreenState extends State<DatesParentQaScreen> {
  late final bool _ownsFixture;
  late final bool _ownsSession;
  late final WorkItemDatesParentFixture _fixture;
  EmulatorQaMemoryAccountStore? _ownedStore;
  late SessionController _session;
  late GitLabApi _api;
  late DatesQaViewMode _viewMode;
  int _rebindNonce = 0;
  final Map<String, GlobalKey<NavigatorState>> _navKeys = {};

  GlobalKey<NavigatorState> _navKeyFor(String paneId) {
    return _navKeys.putIfAbsent(
      '$paneId-$_rebindNonce',
      () => GlobalKey<NavigatorState>(),
    );
  }

  @override
  void initState() {
    super.initState();
    _viewMode = widget.initialMode;
    _ownsFixture = widget.fixture == null;
    _ownsSession = widget.session == null;
    _fixture = widget.fixture ?? WorkItemDatesParentFixture();
    if (widget.session != null) {
      _session = widget.session!;
      _api = _session.api ?? _fixture.primaryApi();
    } else {
      _ownedStore = EmulatorQaMemoryAccountStore()
        ..accounts = [_fixture.account]
        ..lastActive = _fixture.account.key;
      _api = _fixture.primaryApi();
      _session = SessionController(
        _ownedStore!,
        createApi: (instance, credential, oauth, onOAuthRotated) =>
            _fixture.primaryApi(),
      )
        ..active = _fixture.account
        ..api = _api
        ..initializing = false;
    }
    _session.addListener(_onSessionChanged);
  }

  void _onSessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    if (_ownsSession) {
      _session.dispose();
    }
    if (_ownsFixture) {
      _fixture.releaseHolds();
      _fixture.closeAll();
    }
    super.dispose();
  }

  void _holdBeforeApply() {
    _fixture.holdBeforeApply = Completer<void>();
    _snack('已設定：暫停寫入 (Hold Before Apply)');
    setState(() {});
  }

  void _holdAck() {
    _fixture.holdAck = Completer<void>();
    _snack('已設定：暫停確認 (Hold ACK)');
    setState(() {});
  }

  void _releaseHolds() {
    _fixture.releaseHolds();
    _snack('已釋放所有 Hold 閘門');
    setState(() {});
  }

  void _loseNextAck() {
    _fixture.loseNextAck = true;
    _snack('已設定：下次寫入遺失確認 (503 Lose Next ACK)');
    setState(() {});
  }

  void _lagNextDetail() {
    _fixture.lagNextDetail = true;
    _snack('已設定：下次詳情讀取延遲 (Lag Next Detail)');
    setState(() {});
  }

  void _toggleSession() {
    if (_session.active == null) {
      if (!_ownsSession || _ownedStore == null) {
        _snack('外部注入的 Session 不支援由此還原');
        return;
      }
      _session.removeListener(_onSessionChanged);
      _session.dispose();
      _api = _fixture.primaryApi();
      _session = SessionController(
        _ownedStore!,
        createApi: (instance, credential, oauth, onOAuthRotated) =>
            _fixture.primaryApi(),
      )
        ..active = _fixture.account
        ..api = _api
        ..initializing = false;
      _session.addListener(_onSessionChanged);
      setState(() => _rebindNonce++);
      _snack('Session 已重新綁定為 ${_fixture.account.user.username}');
    } else {
      unawaited(_session.endSession());
      _snack('Session 已結束 (Owner Loss)');
      setState(() {});
    }
  }

  void _resetDates() {
    _fixture.releaseHolds();
    _fixture.dates[WorkItemDatesParentFixture.itemX] = DatesParentItem(
      startDate: '2026-10-10',
      dueDate: '2026-10-20',
    );
    _fixture.dates[WorkItemDatesParentFixture.itemY] = DatesParentItem(
      startDate: '2026-11-01',
      dueDate: '2026-11-30',
    );
    _fixture.loseNextAck = false;
    _fixture.lagNextDetail = false;
    _fixture.armFinalFence = false;
    setState(() => _rebindNonce++);
    _snack('Dates 伺服器狀態與暫停已重設');
  }

  void _snack(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger
      ?..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 1200),
        ),
      );
  }

  void _showLedger() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (context, scrollController) => Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            controller: scrollController,
            children: [
              Text(
                '網路紀錄與計數（開啟時快照）',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  Chip(label: Text('寫入請求: ${_fixture.datesMutationRequests}')),
                  Chip(label: Text('已套用: ${_fixture.datesApplied}')),
                  Chip(label: Text('詳情讀取: ${_fixture.detailReads()}')),
                  Chip(
                    label: Text(
                      'Base: ${_fixture.count(WorkItemDatesParentFixture.baseOp)}',
                    ),
                  ),
                  Chip(
                    label: Text(
                      'Probe: ${_fixture.count(WorkItemDatesParentFixture.probeOp)}',
                    ),
                  ),
                  Chip(
                    label: Text(
                      'EE: ${_fixture.count(WorkItemDatesParentFixture.eeMutationOp)}',
                    ),
                  ),
                  Chip(
                    label: Text(
                      'CE: ${_fixture.count(WorkItemDatesParentFixture.ceMutationOp)}',
                    ),
                  ),
                ],
              ),
              const Divider(height: 24),
              Text(
                '請求紀錄 (${_fixture.ledger.length} 筆)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (_fixture.ledger.isEmpty)
                const Text('目前尚無請求紀錄')
              else
                for (final req in _fixture.ledger.reversed.take(40))
                  ListTile(
                    dense: true,
                    title: Text('#${req.nonce} ${req.operation}'),
                    subtitle: Text(
                      'client: ${req.clientTag} · item: ${req.item ?? "none"}',
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProjectPage({Key? key}) => GraphWorkItemDetailPage.project(
    key: key ?? ValueKey('dates-qa-page-project-$_rebindNonce'),
    account: _session.active ?? _fixture.account,
    api: _session.api ?? _api,
    project: const Project(id: 42, name: 'mobile', path: 'studio/mobile'),
    iid: WorkItemStatusFixture.sharedIid,
    isCurrent: () =>
        _session.active?.key == _fixture.account.key &&
        identical(_session.api, _api),
    ownerChanges: _session,
  );

  Widget _buildGroupPage({Key? key}) => GraphWorkItemDetailPage.namespace(
    key: key ?? ValueKey('dates-qa-page-group-$_rebindNonce'),
    account: _session.active ?? _fixture.account,
    api: _session.api ?? _api,
    namespacePath: WorkItemStatusFixture.groupRef.fullPath,
    expectedNamespaceId: WorkItemStatusFixture.groupRef.id,
    iid: WorkItemStatusFixture.sharedIid,
    isCurrent: () =>
        _session.active?.key == _fixture.account.key &&
        identical(_session.api, _api),
    ownerChanges: _session,
  );

  void _openLauncherPage(String label, {required bool isProject}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProviderScope(
          overrides: [sessionProvider.overrideWithValue(_session)],
          child: Scaffold(
            appBar: AppBar(title: Text(label)),
            body: isProject
                ? _buildProjectPage(
                    key: ValueKey('dates-qa-launcher-$label-$_rebindNonce'),
                  )
                : _buildGroupPage(
                    key: ValueKey('dates-qa-launcher-$label-$_rebindNonce'),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _wrapNestedNavigator({
    required String paneId,
    required Widget child,
  }) {
    final navKey = _navKeyFor(paneId);
    return NavigatorPopHandler(
      key: ValueKey('dates-qa-pop-$paneId-$_rebindNonce'),
      onPopWithResult: (_) => navKey.currentState?.maybePop(),
      child: Navigator(
        key: navKey,
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => child,
        ),
      ),
    );
  }

  Widget _buildBody() {
    return switch (_viewMode) {
      DatesQaViewMode.project => _wrapNestedNavigator(
          paneId: 'project',
          child: _buildProjectPage(
            key: ValueKey('dates-qa-page-project-$_rebindNonce'),
          ),
        ),
      DatesQaViewMode.group => _wrapNestedNavigator(
          paneId: 'group',
          child: _buildGroupPage(
            key: ValueKey('dates-qa-page-group-$_rebindNonce'),
          ),
        ),
      DatesQaViewMode.split => Row(
          children: [
            Expanded(
              key: const ValueKey('dates-qa-split-pane-a'),
              child: Column(
                children: [
                  Container(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    width: double.infinity,
                    child: const Text(
                      'Writer A (專案)',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Expanded(
                    child: _wrapNestedNavigator(
                      paneId: 'split-a',
                      child: _buildProjectPage(
                        key: ValueKey('dates-qa-page-a-$_rebindNonce'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              key: const ValueKey('dates-qa-split-pane-b'),
              child: Column(
                children: [
                  Container(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    width: double.infinity,
                    child: const Text(
                      'Observer B (專案)',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  Expanded(
                    child: _wrapNestedNavigator(
                      paneId: 'split-b',
                      child: _buildProjectPage(
                        key: ValueKey('dates-qa-page-b-$_rebindNonce'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      DatesQaViewMode.launcher => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  key: const ValueKey('dates-qa-launcher-open-writer'),
                  onPressed: () => _openLauncherPage('Writer A', isProject: true),
                  icon: const Icon(Icons.edit_calendar),
                  label: const Text('開啟工作項目 Writer A'),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  key: const ValueKey('dates-qa-launcher-open-observer'),
                  onPressed: () =>
                      _openLauncherPage('Observer B', isProject: true),
                  icon: const Icon(Icons.remove_red_eye_outlined),
                  label: const Text('開啟工作項目 Observer B'),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  key: const ValueKey('dates-qa-launcher-open-group'),
                  onPressed: () =>
                      _openLauncherPage('群組項目', isProject: false),
                  icon: const Icon(Icons.group_work_outlined),
                  label: const Text('開啟群組工作項目'),
                ),
              ],
            ),
          ),
        ),
    };
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [sessionProvider.overrideWithValue(_session)],
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Container(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_month, size: 20),
                    const SizedBox(width: 6),
                    const Text(
                      'Dates QA',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SegmentedButton<DatesQaViewMode>(
                            showSelectedIcon: false,
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            segments: const [
                              ButtonSegment(
                                value: DatesQaViewMode.project,
                                label: Text('專案', style: TextStyle(fontSize: 12)),
                              ),
                              ButtonSegment(
                                value: DatesQaViewMode.group,
                                label: Text('群組', style: TextStyle(fontSize: 12)),
                              ),
                              ButtonSegment(
                                value: DatesQaViewMode.split,
                                label: Text('A/B', style: TextStyle(fontSize: 12)),
                              ),
                              ButtonSegment(
                                value: DatesQaViewMode.launcher,
                                label: Text('啟動器', style: TextStyle(fontSize: 12)),
                              ),
                            ],
                            selected: {_viewMode},
                            onSelectionChanged: (selected) {
                              setState(() => _viewMode = selected.first);
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(child: _buildBody()),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      IconButton(
                        key: const ValueKey('dates-qa-reset-dates'),
                        tooltip: '重設 Dates 狀態',
                        icon: const Icon(Icons.restart_alt, size: 20),
                        onPressed: _resetDates,
                      ),
                      const SizedBox(width: 4),
                      OutlinedButton(
                        key: const ValueKey('dates-qa-hold-apply'),
                        onPressed: _holdBeforeApply,
                        child: const Text('暫停寫入'),
                      ),
                      const SizedBox(width: 4),
                      OutlinedButton(
                        key: const ValueKey('dates-qa-hold-ack'),
                        onPressed: _holdAck,
                        child: const Text('暫停 ACK'),
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        key: const ValueKey('dates-qa-release-holds'),
                        onPressed: _releaseHolds,
                        child: const Text('釋放暫停'),
                      ),
                      const SizedBox(width: 4),
                      OutlinedButton(
                        key: const ValueKey('dates-qa-lose-ack'),
                        onPressed: _loseNextAck,
                        child: const Text('遺失 ACK'),
                      ),
                      const SizedBox(width: 4),
                      OutlinedButton(
                        key: const ValueKey('dates-qa-lag-detail'),
                        onPressed: _lagNextDetail,
                        child: const Text('延遲詳情'),
                      ),
                      const SizedBox(width: 4),
                      OutlinedButton(
                        key: const ValueKey('dates-qa-toggle-session'),
                        onPressed:
                            (_session.active == null && !_ownsSession)
                                ? null
                                : _toggleSession,
                        child: Text(
                          _session.active == null ? '還原 Session' : '結束 Session',
                        ),
                      ),
                      const SizedBox(width: 4),
                      OutlinedButton.icon(
                        key: const ValueKey('dates-qa-view-ledger'),
                        onPressed: _showLedger,
                        icon: const Icon(Icons.list_alt, size: 16),
                        label: const Text('紀錄'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QaLanding extends StatelessWidget {
  const _QaLanding({required this.runtime});

  final _EmulatorQaRuntime runtime;

  void _open(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Emulator UI QA')),
    body: ListenableBuilder(
      listenable: runtime.session,
      builder: (context, _) {
        final enabled =
            runtime.session.active != null &&
            runtime.session.api != null &&
            !runtime.fixture.api.isClosed;
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            const Text(
              '所有畫面皆使用固定合成資料；未知端點回傳 404。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            _QaDestination(
              icon: Icons.phone_android_outlined,
              label: '主畫面與底部導航',
              onTap: enabled
                  ? () =>
                        _open(context, _QaAuthenticatedShell(runtime: runtime))
                  : null,
            ),
            _QaDestination(
              icon: Icons.check_box_outlined,
              label: '專案 Work Item',
              onTap: enabled
                  ? () => _open(
                      context,
                      GraphWorkItemDetailPage.project(
                        account: runtime.fixture.account,
                        api: runtime.fixture.api,
                        project: runtime.fixture.project,
                        iid: 31,
                        isCurrent: () =>
                            runtime.session.active?.key ==
                                runtime.fixture.account.key &&
                            identical(runtime.session.api, runtime.fixture.api),
                        ownerChanges: runtime.session,
                      ),
                    )
                  : null,
            ),
            _QaDestination(
              icon: Icons.checklist_outlined,
              label: '群組 Work Item',
              onTap: enabled
                  ? () => _open(
                      context,
                      GraphWorkItemDetailPage.namespace(
                        account: runtime.fixture.account,
                        api: runtime.fixture.api,
                        namespacePath: 'qa/synthetic-group',
                        expectedNamespaceId: 'gid://gitlab/Group/84',
                        iid: 41,
                        isCurrent: () =>
                            runtime.session.active?.key ==
                                runtime.fixture.account.key &&
                            identical(runtime.session.api, runtime.fixture.api),
                        ownerChanges: runtime.session,
                      ),
                    )
                  : null,
            ),
            _QaDestination(
              icon: Icons.calendar_month_outlined,
              label: 'Work Item 日期 (Dates Parent QA)',
              onTap: enabled
                  ? () => _open(
                      context,
                      const DatesParentQaScreen(),
                    )
                  : null,
            ),
            _QaDestination(
              icon: Icons.filter_list_outlined,
              label: '群組工作項目清單',
              onTap: enabled
                  ? () => _open(
                      context,
                      Scaffold(
                        appBar: AppBar(title: const Text('群組工作項目清單')),
                        body: GraphWorkItemsPage.group(
                          account: runtime.fixture.account,
                          api: runtime.fixture.api,
                          namespacePath: 'qa/synthetic-group',
                          isCurrent: () =>
                              runtime.session.active?.key ==
                                  runtime.fixture.account.key &&
                              identical(
                                runtime.session.api,
                                runtime.fixture.api,
                              ),
                          ownerChanges: runtime.session,
                        ),
                      ),
                    )
                  : null,
            ),
            _QaDestination(
              icon: Icons.account_tree_outlined,
              label: '專案頁面',
              onTap: enabled
                  ? () => _open(
                      context,
                      ProjectPage(
                        account: runtime.fixture.account,
                        api: runtime.fixture.api,
                        project: runtime.fixture.project,
                      ),
                    )
                  : null,
            ),
            _QaDestination(
              icon: Icons.dns_outlined,
              label: '環境與部署',
              onTap: enabled
                  ? () => _open(
                      context,
                      EnvironmentsPage(
                        account: runtime.fixture.account,
                        api: runtime.fixture.api,
                        project: runtime.fixture.project,
                      ),
                    )
                  : null,
            ),
            _QaDestination(
              icon: Icons.event_repeat_outlined,
              label: 'Pipeline 排程',
              onTap: enabled
                  ? () => _open(
                      context,
                      PipelineSchedulesPage(
                        account: runtime.fixture.account,
                        api: runtime.fixture.api,
                        project: runtime.fixture.project,
                      ),
                    )
                  : null,
            ),
          ],
        );
      },
    ),
  );
}

Future<BuildInfo> _qaBuildInfo() async => const BuildInfo(
  version: 'QA',
  buildNumber: 'synthetic',
  commit: emulatorUiQaCommit,
);

class _QaAuthenticatedShell extends StatelessWidget {
  const _QaAuthenticatedShell({required this.runtime});

  final _EmulatorQaRuntime runtime;

  @override
  Widget build(BuildContext context) => MediaQuery.fromView(
    view: View.of(context),
    child: Builder(
      builder: (context) => KeyedSubtree(
        key: const ValueKey('emulator-qa-shell-viewport'),
        child: AuthenticatedApp(
          session: runtime.session,
          appearance: runtime.appearance,
          shortcuts: runtime.shortcuts,
          dynamicLight: const ColorScheme.light(),
          dynamicDark: const ColorScheme.dark(),
          buildInfoLoader: _qaBuildInfo,
        ),
      ),
    ),
  );
}

class _QaDestination extends StatelessWidget {
  const _QaDestination({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: const Icon(Icons.chevron_right),
      enabled: onTap != null,
      onTap: onTap,
    ),
  );
}
