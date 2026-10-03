import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
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
import '../test/support/workspace_fixture.dart';

const emulatorUiQaEnabled = bool.fromEnvironment('EMULATOR_UI_QA');
const emulatorUiQaCommit = String.fromEnvironment(
  'GITLAB_MOBILE_COMMIT',
  defaultValue: 'local-qa',
);

enum _QaNoteEditControl {
  allow,
  deny,
  revise,
  failNextAcknowledgement,
  allowReactions,
  denyReactions,
  failDeleteAcknowledgement,
  failReactionAcknowledgement,
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
  EmulatorQaFixture() {
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

  bool _starred = false;
  int _starCount = 12;
  final Map<String, String> _workItemStates = {
    'gid://gitlab/WorkItem/1031': 'OPEN',
    'gid://gitlab/WorkItem/1041': 'OPEN',
  };
  final List<String> workItemStateEvents = [];
  final List<Json> workItemNoteEvents = [];
  final List<Json> workItemNoteEditEvents = [];
  final List<Json> workItemNoteDeleteEvents = [];
  final List<Json> workItemNoteReactionEvents = [];
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
      'title': group
          ? 'Synthetic group Work Item'
          : 'Synthetic project Work Item',
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
      },
      'userPermissions': {'updateWorkItem': true, 'createNote': true},
      'description': 'Explicit in-memory QA fixture. No GitLab connection.',
      'widgets': [
        {
          'type': 'DESCRIPTION',
          'description': 'Explicit in-memory QA fixture. No GitLab connection.',
          'edited': false,
          'lastEditedAt': null,
        },
        {'type': 'NOTES', 'discussionLocked': false},
      ],
    };
  }

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
      return jsonResponse(projectRecord, status: 201);
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
