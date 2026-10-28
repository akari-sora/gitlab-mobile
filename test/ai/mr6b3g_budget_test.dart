import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_transcript.dart';
import 'package:gitlab_mobile/core/ai/tools/gitlab_write_port.dart' as port;
import 'package:gitlab_mobile/core/ai/tools/tool_catalogue.dart';
import 'package:gitlab_mobile/core/ai/tools/write_coordinator.dart';
import 'package:gitlab_mobile/core/ai/tools/write_ledger.dart';
import 'package:gitlab_mobile/core/ai/write_text.dart' as text;
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/oauth.dart';
import 'package:gitlab_mobile/features/ai/ai_write_journal.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';

import '../support/fake_adapter.dart';
import '../support/namespace_work_item_query.dart';
import 'mr6b3_matrix_support.dart';
import 'mr6b3_support.dart';
import 'mr6b3g_support.dart';

// §15 rows 13/19/24/25. Independently counted fixed-document distributions
// from breakdown §4, never computed from a production capability's cap.
const g15LogicalReads = <String, int>{
  'updateGroupWorkItemState': 10,
  'updateGroupWorkItemStatus': 10,
  'updateGroupWorkItemDates': 14,
  'updateGroupWorkItemHealthStatus': 10,
  'updateGroupWorkItemAssignees': 18,
  'updateGroupWorkItemMilestone': 12,
  'updateGroupWorkItemWeight': 10,
  'createGroupWorkItemActivityComment': 10,
  'createGroupWorkItemActivityReply': 14,
  'deleteGroupWorkItemActivityNote': 14,
  'setGroupWorkItemActivityNoteReaction': 18,
  'setGroupWorkItemNotifications': 10,
  'updateGroupWorkItemContent': 10,
  'editGroupWorkItemActivityNote': 14,
  'updateGroupWorkItemLabels': 12,
  'snoozeTodo': 10,
  'unsnoozeTodo': 10,
};

const g15Key = AiConflictKey([g0eAccount, 'group:7', 'workItem', '5']);
const _group = {'id': 'gid://gitlab/Group/7', 'fullPath': g0ePath};
const _gid = 'gid://gitlab/WorkItem/91';

final class G15Ledger implements AiCapabilityLedger {
  const G15Ledger();
  @override
  AiCapability? find(String operationId) {
    final row = productionAiLedger.find(operationId);
    if (row == null || !g15LogicalReads.containsKey(operationId)) return row;
    // Production group rows stay hidden until G14. Passing that flag through
    // would make propose return unknownOperation, so this copy is explicitly
    // visible. Snooze rows are already visible; forcing true leaves them
    // unchanged. Guard and matrix tests pin the production flag separately.
    return AiCapability(
      operationId: row.operationId,
      namedMethod: row.namedMethod,
      baseTier: row.baseTier,
      scopeClass: row.scopeClass,
      boundary: row.boundary,
      httpCap: row.httpCap,
      readback: row.readback,
      editableField: row.editableField,
      arguments: row.arguments,
      modelVisible: true,
    );
  }

  @override
  List<AiCapability> get modelVisible => [
    for (final operation in g15LogicalReads.keys) find(operation)!,
  ];
}

Map<String, Object?> g15Arguments(String operation) {
  if (operation == 'snoozeTodo' || operation == 'unsnoozeTodo') {
    return {
      'todoId': 400,
      if (operation == 'snoozeTodo') 'until': '2099-01-01T00:00:00.000Z',
    };
  }
  final args = switch (operation) {
    'updateGroupWorkItemContent' => <String, Object?>{
      'title': 'Changed title',
      'description': 'Changed description',
    },
    'editGroupWorkItemActivityNote' => <String, Object?>{
      'noteId': 401,
      'body': 'Changed note',
    },
    'updateGroupWorkItemLabels' => <String, Object?>{
      'labels': ['next'],
    },
    _ => Map<String, Object?>.from(
      mr6b3ApiArguments(operation.replaceFirst('GroupWorkItem', 'WorkItem')),
    ),
  };
  args.remove('projectId');
  return {...args, 'groupId': 7, 'iid': 5};
}

/// Existing stateful payloads with explicit group evidence at this adapter.
/// Requests run through the real coordinator, group port and core methods.
final class G15Server {
  G15Server({this.oauth = false, this.replayEveryRead = false}) {
    oracle.checkGraphqlIdentity = false;
    oracle.onRequest = (name, mutation, request, payload) {
      final converted = jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
      _groupPayload(converted);
      if (name == 'MobileProjectWorkItemMilestones' ||
          name == 'MobileProjectAssigneeCandidates') {
        final data = converted['data']! as Map<String, Object?>;
        final project = data.remove('project')! as Map<String, Object?>;
        data['group'] = {...project, ..._group};
      }
      if (name == 'MobileWorkItemActivityEditAccess') {
        ((converted['data']! as Map)['note']! as Map)['body'] = noteBody;
      }
      if (fullPages) _expandPages(name, converted);
      return jsonResponse(converted);
    };
    adapter = FakeAdapter((request) async {
      try {
        return await _respond(request);
      } catch (error) {
        // Dio wraps adapter assertions as transport failures. Never let a
        // refusal test pass by swallowing a broken fixed-document fixture.
        rejectedFixtures.add('${request.method} ${request.uri.path}: $error');
        rethrow;
      }
    });
    refreshAdapter = FakeAdapter((_) {
      refreshes++;
      return jsonResponse({
        'access_token': 'synthetic-g15-$refreshes',
        'refresh_token': 'synthetic-refresh',
        'token_type': 'bearer',
      });
    });
    api = oauth
        ? GitLabApi(
            instance: g0eScope.resolvedInstance!,
            credential: const OAuthCredential(
              accessToken: 'synthetic-access',
              refreshToken: 'synthetic-refresh',
              clientId: 'synthetic-client',
            ),
            dio: Dio()..httpClientAdapter = adapter,
            oauth: OAuthTokenClient(
              instance: g0eScope.resolvedInstance!,
              clientId: 'synthetic-client',
              dio: Dio()..httpClientAdapter = refreshAdapter,
            ),
          )
        : testApi(adapter);
    writer = port.GitLabAiWritePort(
      api,
      accountKey: g0eAccount,
      sessionGeneration: 7,
      isCurrent: () => live,
      workItemWriteRegistry: createAiWorkspaceWorkItemWriteRegistry(
        api: api,
        accountKey: g0eAccount,
        instanceKey: api.instance.key,
        generation: 7,
        isCurrent: () => live,
      ),
    );
  }

  final bool oauth;
  final bool replayEveryRead;
  final oracle = Mr6b3ApiServer(oauth: false);
  late final FakeAdapter adapter;
  late final FakeAdapter refreshAdapter;
  late final GitLabApi api;
  late final port.GitLabAiWritePort writer;
  bool live = true;
  int logicalReads = 0, mutations = 0, refreshes = 0;
  int ownerCorruptions = 0;
  bool fullPages = false;
  final pageSizes = <String, List<int>>{};
  int? challengeRead, mutationStatus, readbackStatus;
  int? failLogicalRead;
  int injectedReadFailures = 0;
  String? failReadName;
  int? failReadOccurrence;
  int failReadStatus = 500;
  bool corruptReadbackOwner = false, _replaying = false;

  /// After a real mutation acknowledgement, put the opening status and
  /// revision back so the independent readback still shows the old pair.
  bool restoreOpeningOnReadback = false;
  String? acknowledgedRevision;
  String? acknowledgedStatusId;
  final reads = <String, int>{};
  final rejectedFixtures = <String>[];
  final inputs = <Map<String, Object?>>[];
  String title = 'Original title', description = 'Original description';
  String noteBody = 'Synthetic note';
  List<String> labels = ['gid://gitlab/GroupLabel/1'];
  void Function()? onMutation;
  Completer<void>? mutationEntered, releaseMutation;

  Map<String, Object?> node({bool completeLabels = false}) => {
    'id': _gid,
    'iid': '5',
    'title': title,
    'state': oracle.workItemState,
    'createdAt': '2026-10-01T00:00:00Z',
    'updatedAt': oracle.revision,
    'project': null,
    'namespace': _group,
    'workItemType': {
      'id': 'gid://gitlab/WorkItems::Type/9',
      'name': 'Task',
      'widgetDefinitions': [
        {'type': 'LABELS', 'allowsScopedLabels': true},
      ],
    },
    'userPermissions': {
      'readWorkItem': true,
      'updateWorkItem': true,
      'setWorkItemMetadata': true,
    },
    'widgets': [
      {'type': 'DESCRIPTION', 'description': description, 'edited': false},
      {
        'type': 'LABELS',
        'labels': {
          'nodes': [
            for (final id in labels.take(completeLabels ? 100 : 50))
              label(int.parse(id.split('/').last)),
          ],
          'pageInfo': {
            'hasNextPage': !completeLabels && labels.length > 50,
            if (!completeLabels && labels.length > 50) 'endCursor': 'labels-50',
          },
        },
      },
    ],
  };

  Map<String, Object?> label(int id) => {
    'id': 'gid://gitlab/GroupLabel/$id',
    'title': id == 1
        ? 'old'
        : id == 2
        ? 'next'
        : 'label-$id',
    'color': '#000000',
    'textColor': '#ffffff',
  };

  Future<ResponseBody> _respond(RequestOptions request) async {
    final data = request.data;
    final query = data is Map ? data['query'] as String? : null;
    final name = query == null
        ? request.uri.path.endsWith('/user')
              ? 'user'
              : 'freshness'
        : RegExp(r'^(?:query|mutation) (\w+)').firstMatch(query)!.group(1)!;
    final mutation = query?.startsWith('mutation ') ?? false;
    final occurrence = (reads[name] ?? 0) + 1;
    final challenge =
        replayEveryRead ||
        challengeRead == logicalReads + 1 ||
        (challengeRead == null &&
            (logicalReads == 0 || mutations > 0) &&
            !(name == 'freshness' && occurrence > 1));
    if (!mutation && oauth && challenge && !_replaying) {
      _replaying = true;
      return jsonResponse({}, status: 401);
    }
    _replaying = false;
    reads[name] = occurrence;
    if (mutation) {
      mutations++;
      onMutation?.call();
      mutationEntered?.complete();
      if (releaseMutation != null) await releaseMutation!.future;
      if (mutationStatus != null) {
        return jsonResponse({}, status: mutationStatus!);
      }
    } else {
      logicalReads++;
      if (logicalReads == failLogicalRead) {
        injectedReadFailures++;
        return jsonResponse({}, status: 500);
      }
      if (name == failReadName && occurrence == failReadOccurrence) {
        return jsonResponse({}, status: failReadStatus);
      }
      if (mutations > 0 && readbackStatus != null) {
        return jsonResponse({}, status: readbackStatus!);
      }
    }
    if (name == 'freshness') {
      expect(request.uri.path, '/gitlab/api/v4/groups/7');
      expect(request.uri.queryParameters, {'with_projects': 'false'});
      return jsonResponse({
        'id': 7,
        'full_path': g0ePath,
        'visibility': 'private',
      });
    }
    if (name == 'MobileNamespaceWorkItem') {
      expect(query, namespaceWorkItemQuery);
      expect((data as Map)['variables'], {'path': g0ePath, 'iid': '5'});
      return jsonResponse({
        'data': {
          'namespace': {..._group, 'workItem': node()},
        },
      });
    }
    final variables = data is Map && data['variables'] is Map
        ? Map<String, Object?>.from(data['variables'] as Map)
        : <String, Object?>{};
    final input = variables['input'] is Map
        ? Map<String, Object?>.from(variables['input']! as Map)
        : <String, Object?>{};
    if (mutation) inputs.add(input.isEmpty ? variables : input);
    if (name == 'MobileUpdateWorkItemContent') {
      if (input['title'] is String) title = input['title']! as String;
      if (input['descriptionWidget'] case final Map<Object?, Object?> widget) {
        description = widget['description']! as String;
      }
      oracle.revision = mr6b3BumpedRevision;
    }
    if (name == 'MobileUpdateWorkItemLabels') {
      final widget = input['labelsWidget']! as Map;
      labels = [
        ...labels.where(
          (id) =>
              !((widget['removeLabelIds'] as List?) ?? const []).contains(id),
        ),
        ...((widget['addLabelIds'] as List?) ?? const []).cast<String>(),
      ];
      oracle.revision = mr6b3BumpedRevision;
    }
    if (name == 'MobileWorkItemContent' || name == 'MobileWorkItemLabels') {
      final result = node(completeLabels: true);
      if (name == 'MobileWorkItemLabels') {
        (pageSizes[name] ??= []).add(labels.length);
      }
      (result['widgets']! as List).removeWhere(
        (Object? widget) =>
            (widget! as Map)['type'] !=
            (name == 'MobileWorkItemContent' ? 'DESCRIPTION' : 'LABELS'),
      );
      return jsonResponse({
        'data': {
          'currentUser': {'id': 'gid://gitlab/User/7'},
          'workItem': _served(result),
        },
      });
    }
    if (name == 'MobileUpdateWorkItemContent' ||
        name == 'MobileUpdateWorkItemLabels') {
      final result = node(completeLabels: true);
      (result['widgets']! as List).removeWhere(
        (Object? widget) =>
            (widget! as Map)['type'] !=
            (name == 'MobileUpdateWorkItemContent' ? 'DESCRIPTION' : 'LABELS'),
      );
      return jsonResponse({
        'data': {
          'workItemUpdate': {'errors': <Object?>[], 'workItem': result},
        },
      });
    }
    if (name == 'MobileGroupWorkItemLabelCandidates') {
      final count = fullPages ? 100 : 2;
      (pageSizes[name] ??= []).add(count);
      return jsonResponse({
        'data': {
          'currentUser': {'id': 'gid://gitlab/User/7'},
          'group': {
            ..._group,
            'labels': {
              'nodes': [for (var id = 1; id <= count; id++) label(id)],
              'pageInfo': {'hasNextPage': false},
            },
          },
        },
      });
    }
    if (name == 'MobileUpdateWorkItemActivityNote') {
      noteBody = input['body']! as String;
      oracle.noteUpdatedAt = '2026-10-01T01:04:04Z';
      final response = await oracle.adapter.respond(
        request.copyWith(
          data: {
            'query': 'query MobileWorkItemActivityEditAccess',
            'variables': variables,
          },
        ),
      );
      final payload =
          jsonDecode(await utf8.decoder.bind(response.stream).join())
              as Map<String, dynamic>;
      return jsonResponse({
        'data': {
          'updateNote': {
            'errors': <Object?>[],
            'note': (payload['data'] as Map)['note'],
          },
        },
      });
    }
    final adaptedName = switch (name) {
      'MobileGroupAssigneeCandidates' => 'MobileProjectAssigneeCandidates',
      'MobileGroupWorkItemMilestones' => 'MobileProjectWorkItemMilestones',
      'MobileWorkItemActivityNoteReadback'
          when variables['noteId'] == 'gid://gitlab/Note/401' =>
        'MobileWorkItemActivityEditAccess',
      _ => name,
    };
    final openingRevision = oracle.revision;
    final openingStatusId = oracle.statusId;
    try {
      final response = await oracle.adapter.respond(
        adaptedName == name
            ? request
            : request.copyWith(
                data: {
                  'query': query!.replaceFirst(name, adaptedName),
                  'variables': variables,
                },
              ),
      );
      if (mutation && restoreOpeningOnReadback) {
        acknowledgedRevision = oracle.revision;
        acknowledgedStatusId = oracle.statusId;
        oracle.revision = openingRevision;
        oracle.statusId = openingStatusId;
      }
      if (!corruptReadbackOwner || mutations == 0 || mutation) return response;
      final payload =
          jsonDecode(await utf8.decoder.bind(response.stream).join())
              as Map<String, dynamic>;
      _corruptOwner(payload);
      return jsonResponse(payload);
    } catch (error) {
      rejectedFixtures.add('$name: $error');
      rethrow;
    }
  }

  Map<String, Object?> _served(Map<String, Object?> value) {
    if (corruptReadbackOwner && mutations > 0) _corruptOwner(value);
    return value;
  }

  // Fill the fixed documents' complete pages without changing their cursors
  // or adding a fallback request. Padding has unique server-owned IDs.
  void _expandPages(String name, Map<String, dynamic> payload) {
    final rawData = payload['data'];
    if (rawData is! Map) return;
    final data = rawData;
    if (name == 'MobileProjectWorkItemMilestones') {
      final connection = (data['group'] as Map)['milestones'] as Map;
      final nodes = connection['nodes'] as List;
      final template = Map<String, Object?>.from(nodes.first as Map);
      for (var id = 100; id < 148; id++) {
        nodes.add({
          ...template,
          'id': 'gid://gitlab/Milestone/$id',
          'iid': '$id',
          'title': 'Synthetic milestone $id',
          'webPath': '/groups/$g0ePath/-/milestones/$id',
        });
      }
      (pageSizes[name] ??= []).add(nodes.length);
    } else if (name == 'MobileProjectAssigneeCandidates') {
      final nodes = (data['group'] as Map)['autocompleteUsers'] as List;
      for (var id = 100; nodes.length < 20; id++) {
        nodes.add({
          'id': 'gid://gitlab/User/$id',
          'name': 'Padding $id',
          'username': 'padding-$id',
        });
      }
      (pageSizes[name] ??= []).add(nodes.length);
    } else if (name == 'MobileWorkItemActivityReactionAccess') {
      final connection = (data['note'] as Map)['awardEmoji'] as Map;
      final nodes = connection['nodes'] as List;
      final first = (connection['pageInfo'] as Map)['hasNextPage'] == true;
      for (var id = first ? 1000 : 2000; nodes.length < 50; id++) {
        nodes.insert(0, {
          'name': 'thumbsup',
          'unicode': null,
          'user': {'id': 'gid://gitlab/User/$id'},
        });
      }
      (pageSizes[name] ??= []).add(nodes.length);
    } else if (name == 'MobileWorkItemActivity') {
      final widget =
          ((data['workItem'] as Map)['widgets'] as List).single as Map;
      final connection = widget['discussions'] as Map;
      final nodes = connection['nodes'] as List;
      final target = nodes.isEmpty
          ? null
          : Map<String, Object?>.from(nodes.single as Map);
      final first = (connection['pageInfo'] as Map)['hasNextPage'] == true;
      nodes.clear();
      for (var discussion = 0; discussion < 20; discussion++) {
        final id = (first ? 1000 : 2000) + discussion;
        final notes = <Object?>[
          for (var note = 0; note < 20; note++)
            {
              'id': 'gid://gitlab/Note/${10000 + id * 20 + note}',
              'system': false,
              'body': 'Synthetic padding',
              'author': {
                'id': 'gid://gitlab/User/7',
                'name': 'Synthetic author',
                'username': 'synthetic',
              },
              'createdAt': '2026-10-01T00:00:00Z',
              'updatedAt': '2026-10-01T00:00:00Z',
            },
        ];
        if (discussion == 19 && target != null) {
          final targetNotes = target['notes'] as Map;
          notes[19] = (targetNotes['nodes'] as List).single;
          nodes.add({
            ...target,
            'notes': {
              'nodes': notes,
              'pageInfo': {'hasNextPage': false},
            },
          });
        } else {
          nodes.add({
            'id': 'gid://gitlab/Discussion/$id',
            'replyId': 'gid://gitlab/IndividualNoteDiscussion/$id',
            'createdAt': '2026-10-01T00:00:00Z',
            'notes': {
              'nodes': notes,
              'pageInfo': {'hasNextPage': false},
            },
          });
        }
        (pageSizes['activityNotes'] ??= []).add(notes.length);
      }
      (pageSizes[name] ??= []).add(nodes.length);
    }
  }

  void _corruptOwner(Object? value) {
    if (value is Map) {
      if (value['id'] == _gid) {
        ownerCorruptions++;
        value['namespace'] = {
          'id': 'gid://gitlab/Group/8',
          'fullPath': g0ePath,
        };
      }
      for (final child in value.values.toList()) {
        _corruptOwner(child);
      }
    } else if (value is List) {
      for (final child in value) {
        _corruptOwner(child);
      }
    }
  }

  void _groupPayload(Object? value) {
    if (value is Map) {
      for (final child in value.values.toList()) {
        _groupPayload(child);
      }
      if (value['id'] == 'gid://gitlab/WorkItem/31') {
        value['id'] = _gid;
        value['iid'] = '5';
        value['project'] = null;
        value['namespace'] = _group;
      }
      if (value['noteableId'] == 31) {
        value['noteableId'] = 91;
        value['project'] = null;
      }
      if (value['id'] == 'gid://gitlab/Note/401') {
        value['body'] = noteBody;
      }
      if (value['id'] is String &&
          (value['id'] as String).startsWith('gid://gitlab/Todo/')) {
        value['project'] = null;
        value['group'] = _group;
      }
      if (value.containsKey('workItemId')) {
        value['workItemId'] = _gid;
        value['iid'] = '5';
        value['workItemProject'] = null;
        value['namespace'] = _group;
      }
      if (value['id'] is String &&
          (value['id'] as String).startsWith('gid://gitlab/Milestone/')) {
        value['project'] = null;
        value['group'] = _group;
        value['webPath'] =
            '/groups/$g0ePath/-/milestones/${(value['id'] as String).split('/').last}';
      }
    } else if (value is List) {
      for (final child in value) {
        _groupPayload(child);
      }
    }
  }

  void close() {
    api.close();
    oracle.close();
  }
}

final class G15Harness {
  G15Harness._(this.base, this.server, this.budget);
  static Future<G15Harness> create({
    bool oauth = false,
    bool replayEveryRead = false,
    int maxRequests = 40,
  }) async {
    final h = G15Harness._(
      await Mr6b3Harness.create(),
      G15Server(oauth: oauth, replayEveryRead: replayEveryRead),
      AiToolBudget(maxGitLabRequests: maxRequests),
    );
    h.coordinator = PolicyAiWriteCoordinator(
      snapshot: () => AiWritePolicySnapshot(
        scope: g0eScope,
        level: h.base.policy.level,
        ceiling: AiAutonomyLevel.bypass,
        consentHash: 'g15-actual-rows',
        writePolicyRevision: h.base.policy.revision,
        scopeRevision: 1,
        sessionGeneration: h.generation,
        ownerApi: h.server.api,
        appInForeground: h.foreground,
        alive: h.base.policy.alive,
        consentValid: h.base.policy.consentValid,
        clientMayStart: h.server.api.mayStartRequest,
      ),
      createPort: () => h.server.writer,
      journal: h.base.journal,
      conversationId: 'g15-real-group',
      budget: () => h.budget,
      readFreshness: (request) async {
        if (request.operationId == 'snoozeTodo' ||
            request.operationId == 'unsnoozeTodo') {
          return const AiWriteFreshness(visibilityUnreadable: false);
        }
        final group = await h.server.api.group(7);
        return AiWriteFreshness(
          targetVisibility: group['visibility'] as String?,
          visibilityUnreadable: true,
        );
      },
      placeholders: text.UploadPlaceholderTable(
        instance: h.server.api.instance,
        accountKey: g0eAccount,
        conversationId: 'g15-real-group',
      ),
      knownSecrets: () => const {},
      safeDisplay: (value) => value,
      ledger: const G15Ledger(),
      httpCost: oauth
          ? null
          : (op) => aiWriteRequestAllowance(op, oauthReplay: false),
    );
    h.coordinator.beginRun('Update this group work item.');
    h.coordinator.beginTurn();
    return h;
  }

  final Mr6b3Harness base;
  final G15Server server;
  final AiToolBudget budget;
  late final PolicyAiWriteCoordinator coordinator;
  int generation = 7;
  bool foreground = true;
  int _id = 0;
  Future<AiWriteProposal?> propose(
    String operation, {
    Map<String, Object?> arguments = const {},
  }) => coordinator.propose(
    AiToolCall(
      id: 'g15-${_id++}',
      name: operation,
      arguments: {
        ...g15Arguments(operation),
        ...arguments,
        'reason': 'Synthetic group request.',
      },
    ),
  );
  Future<AiWriteOutcome> approve(AiWriteProposal proposal) =>
      coordinator.approve(proposal, typedName: proposal.tier.typedName);
  Future<void> dispose() async {
    coordinator.stop();
    server.close();
    await base.dispose();
    expect(server.rejectedFixtures, isEmpty);
    server.oracle.verifyRequests();
  }
}

void main() {
  setUp(() => aiGroupWorkItemWritesEnabledForTesting = true);
  tearDown(() => aiGroupWorkItemWritesEnabledForTesting = null);
  test('seventeen group distributions pin static allowances independently', () {
    expect(g15LogicalReads, hasLength(17));
    for (final entry in g15LogicalReads.entries) {
      expect(
        productionAiLedger.find(entry.key)!.httpCap,
        2 * entry.value + 1,
        reason: entry.key,
      );
      expect(
        aiWriteRequestAllowance(entry.key, oauthReplay: false),
        entry.value + 1,
        reason: entry.key,
      );
      final productionVisible = productionAiLedger
          .find(entry.key)!
          .modelVisible;
      // Group rows are hidden until G14. Snooze rows are already visible;
      // the copy forces visible so hidden rows can be driven, and must not
      // hide a row production already exposes.
      expect(
        productionVisible,
        entry.key.endsWith('Todo') ? isTrue : isFalse,
        reason: entry.key,
      );
      expect(
        const G15Ledger().find(entry.key)!.modelVisible,
        isTrue,
        reason: entry.key,
      );
      expect(2 * entry.value + 1, lessThanOrEqualTo(40));
    }
  });
  for (final operation in [
    'updateGroupWorkItemAssignees',
    'updateGroupWorkItemMilestone',
    'updateGroupWorkItemLabels',
    'createGroupWorkItemActivityReply',
    'deleteGroupWorkItemActivityNote',
    'editGroupWorkItemActivityNote',
    'setGroupWorkItemActivityNoteReaction',
  ]) {
    test(
      '$operation complete maximum pages keep the fixed distribution',
      () async {
        final h = await G15Harness.create();
        addTearDown(h.dispose);
        h.server.fullPages = true;
        if (operation == 'updateGroupWorkItemLabels') {
          h.server.labels = [
            for (var id = 1; id <= 100; id++) 'gid://gitlab/GroupLabel/$id',
          ];
        }
        final proposal = await h.propose(
          operation,
          arguments: operation == 'updateGroupWorkItemLabels'
              ? {
                  'labels': [for (var id = 81; id <= 90; id++) 'label-$id'],
                }
              : const {},
        );
        expect(
          proposal,
          isNotNull,
          reason: h.coordinator.recordedOutcomeFor('g15-0')?.reasonCode,
        );
        final outcome = await h.approve(proposal!);
        expect(
          outcome.state,
          AiJournalState.succeeded,
          reason: outcome.reasonCode,
        );
        expect(h.server.mutations, 1);
        expect(h.server.logicalReads, g15LogicalReads[operation]);
        expect(
          h.server.adapter.requests,
          hasLength(g15LogicalReads[operation]! + 1),
        );
        final sizes = h.server.pageSizes;
        switch (operation) {
          case 'updateGroupWorkItemAssignees':
            expect(
              sizes['MobileProjectAssigneeCandidates'],
              List.filled(8, 20),
            );
          case 'updateGroupWorkItemMilestone':
            expect(sizes['MobileProjectWorkItemMilestones'], [50, 50]);
          case 'updateGroupWorkItemLabels':
            expect(sizes['MobileGroupWorkItemLabelCandidates'], [100, 100]);
            expect(sizes['MobileWorkItemLabels'], [100, 100, 100, 10]);
          default:
            expect(sizes['MobileWorkItemActivity'], [20, 20, 20, 20]);
            expect(sizes['activityNotes'], List.filled(80, 20));
            if (operation == 'setGroupWorkItemActivityNoteReaction') {
              expect(
                sizes['MobileWorkItemActivityReactionAccess'],
                List.filled(8, 50),
              );
            }
        }
      },
    );
  }
  // D26: each challenged pre-send read retains the real epoch fence. The
  // first freshness read precedes capture; final readback follows acceptance.
  const replayReasons = <String, List<String>>{
    'updateGroupWorkItemStatus': [
      'succeeded',
      'workItemUnverifiable',
      'preflightFailed',
      'preflightFailed',
      'workItemUnverifiable',
      'workItemUnverifiable',
      'preflightFailed',
      'preflightFailed',
      'statusNotStarted',
      'succeeded',
    ],
    'updateGroupWorkItemAssignees': [
      'succeeded',
      'workItemUnverifiable',
      'assigneeConflict',
      'assigneeConflict',
      'assigneeConflict',
      'assigneeConflict',
      'assigneeConflict',
      'assigneeConflict',
      'workItemUnverifiable',
      'workItemUnverifiable',
      'assigneeConflict',
      'assigneeConflict',
      'assigneeConflict',
      'assigneeConflict',
      'assigneeConflict',
      'assigneeConflict',
      'assigneeConflict',
      'succeeded',
    ],
    'updateGroupWorkItemWeight': [
      'succeeded',
      'workItemUnverifiable',
      'weightConflict',
      'weightConflict',
      'workItemUnverifiable',
      'workItemUnverifiable',
      'weightConflict',
      'weightConflict',
      'weightConflict',
      'succeeded',
    ],
  };
  for (final operation in replayReasons.entries) {
    for (var read = 1; read <= operation.value.length; read++) {
      test('${operation.key} D26 replay at logical read $read', () async {
        final h = await G15Harness.create(oauth: true);
        addTearDown(h.dispose);
        h.server.challengeRead = read;
        final proposal = await h.propose(operation.key);
        final outcome = proposal == null
            ? h.coordinator.recordedOutcomeFor('g15-0')!
            : await h.approve(proposal);
        final succeeds = read == 1 || read == operation.value.length;
        expect(outcome.reasonCode, operation.value[read - 1]);
        expect(
          outcome.state,
          succeeds ? AiJournalState.succeeded : AiJournalState.notExecuted,
        );
        expect(h.server.mutations, succeeds ? 1 : 0);
        expect(h.server.logicalReads, succeeds ? operation.value.length : read);
        expect(h.server.refreshes, 1);
        expect(h.server.refreshAdapter.requests, hasLength(1));
        expect(
          h.server.adapter.requests,
          hasLength((succeeds ? operation.value.length + 1 : read) + 1),
        );
        expect(
          h.server.adapter.requests.length,
          lessThanOrEqualTo(2 * operation.value.length + 1),
        );
      });
    }
  }
  for (final entry in g15LogicalReads.entries) {
    test(
      '${entry.key} reachable OAuth path counts refresh separately',
      () async {
        final h = await G15Harness.create(oauth: true);
        addTearDown(h.dispose);
        final todo = entry.key.endsWith('Todo');
        h.server.challengeRead = todo ? 0 : 1;
        final proposal = await h.propose(entry.key);
        expect(
          proposal,
          isNotNull,
          reason: h.coordinator.outcomeFor('g15-0')?.reasonCode,
        );
        final outcome = await h.approve(proposal!);
        expect(
          outcome.state,
          AiJournalState.succeeded,
          reason: outcome.reasonCode,
        );
        expect(h.server.logicalReads, entry.value, reason: '${h.server.reads}');
        expect(h.server.mutations, 1);
        expect(h.server.refreshes, todo ? 0 : 1);
        expect(h.server.refreshAdapter.requests, hasLength(todo ? 0 : 1));
        expect(
          h.server.adapter.requests,
          hasLength(entry.value + (todo ? 1 : 2)),
        );
        expect(h.budget.gitLabRequests, 2 * entry.value + 1);
      },
    );
    test(
      '${entry.key} every read challenged refuses captured context',
      () async {
        final h = await G15Harness.create(oauth: true, replayEveryRead: true);
        addTearDown(h.dispose);
        expect(await h.propose(entry.key), isNull);
        expect(
          h.coordinator.outcomeFor('g15-0')!.reasonCode,
          entry.key.startsWith('createGroup')
              ? 'activityUnverifiable'
              : 'workItemUnverifiable',
        );
        expect(h.server.mutations, 0);
        final reads = entry.key.endsWith('Todo') ? 1 : 2;
        expect(h.server.logicalReads, reads);
        expect(h.server.refreshes, reads);
        expect(h.server.refreshAdapter.requests, hasLength(reads));
        expect(h.server.adapter.requests, hasLength(2 * reads));
        expect(
          h.server.adapter.requests.length,
          lessThanOrEqualTo(2 * entry.value + 1),
        );
      },
    );
    test(
      '${entry.key} actual PAT proposal dispatch and maximum pages',
      () async {
        final h = await G15Harness.create();
        addTearDown(h.dispose);
        final proposal = await h.propose(entry.key);
        expect(
          proposal,
          isNotNull,
          reason: h.coordinator.outcomeFor('g15-0')?.reasonCode,
        );
        final reserved = h.budget.gitLabRequests;
        expect(reserved, entry.value + 1);
        final outcome = await h.approve(proposal!);
        expect(
          outcome.state,
          AiJournalState.succeeded,
          reason: outcome.reasonCode,
        );
        expect(outcome.mutationCount, 1);
        expect(h.server.mutations, 1);
        expect(h.server.logicalReads, entry.value, reason: '${h.server.reads}');
        expect(h.server.adapter.requests, hasLength(entry.value + 1));
        expect(h.budget.gitLabRequests, reserved);
        expect(outcome.readbackConfirmed, !entry.key.endsWith('Todo'));
      },
    );
    test('${entry.key} full cap reserved before any group HTTP', () async {
      final cap = 2 * entry.value + 1;
      final h = await G15Harness.create(oauth: true, maxRequests: cap - 1);
      addTearDown(h.dispose);
      expect(await h.propose(entry.key), isNull);
      expect(
        h.coordinator.outcomeFor('g15-0')!.reasonCode,
        'httpBudgetExceeded',
      );
      expect(h.server.adapter.requests, isEmpty);
      expect(h.server.mutations, 0);
      expect(h.base.journal.entries(g0eAccount), isEmpty);
    });
    test('${entry.key} exact full reservation remains usable', () async {
      final cap = 2 * entry.value + 1;
      final h = await G15Harness.create(oauth: true, maxRequests: cap);
      addTearDown(h.dispose);
      h.server.challengeRead = 0;
      final proposal = await h.propose(entry.key);
      expect(
        proposal,
        isNotNull,
        reason: h.coordinator.outcomeFor('g15-0')?.reasonCode,
      );
      expect(h.budget.gitLabRequests, cap);
      expect((await h.approve(proposal!)).state, AiJournalState.succeeded);
      expect(h.server.adapter.requests, hasLength(entry.value + 1));
      expect(h.server.mutations, 1);
    });
    for (final boundary in [39, 40, 41]) {
      test('${entry.key} total reserved HTTP $boundary on budget 40', () async {
        final h = await G15Harness.create(oauth: true);
        addTearDown(h.dispose);
        h.server.challengeRead = 0;
        final cap = 2 * entry.value + 1;
        expect(
          h.budget.reserve(requests: boundary - cap, search: false),
          isNull,
        );
        final proposal = await h.propose(entry.key);
        if (boundary <= 40) {
          expect(proposal, isNotNull);
          expect(h.budget.gitLabRequests, boundary);
          expect((await h.approve(proposal!)).state, AiJournalState.succeeded);
          expect(h.server.mutations, 1);
          expect(h.budget.gitLabRequests, boundary);
        } else {
          expect(proposal, isNull);
          expect(h.server.adapter.requests, isEmpty);
          expect(h.server.mutations, 0);
        }
      });
    }
  }
}
