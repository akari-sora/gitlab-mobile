import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/work_item_attribute_models.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/core/work_item_milestone_models.dart';
import 'package:gitlab_mobile/features/workspace/work_item_attributes.dart';
import 'package:gitlab_mobile/features/workspace/work_item_milestone.dart';

import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _project = GraphResourceRef(
  id: 'gid://gitlab/Project/42',
  fullPath: 'studio/mobile-workspace',
);
const _namespace = GraphResourceRef(
  id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
  fullPath: 'studio/mobile-workspace',
);
const _type = WorkItemGraphType(
  id: 'gid://gitlab/WorkItems::Type/9',
  name: 'Task',
);
final _createdAt = DateTime.utc(2026, 10, 1);
final _displayedAt = DateTime.utc(2026, 10, 2);

WorkItemGraphSummary _summary({DateTime? updatedAt}) => WorkItemGraphSummary(
  id: 'gid://gitlab/WorkItem/31',
  iid: 31,
  title: 'Displayed title',
  state: 'OPEN',
  createdAt: _createdAt,
  updatedAt: updatedAt ?? _displayedAt,
  project: _project,
  namespace: _namespace,
  type: _type,
);

WorkItemGraphDetail _detail({DateTime? updatedAt}) => WorkItemGraphDetail(
  summary: _summary(updatedAt: updatedAt),
  description: null,
  widgetsAvailable: true,
  widgetTypes: const {'MILESTONE'},
  descriptionWidget: null,
  assignees: null,
  labels: null,
  hierarchy: null,
  dates: null,
);

Account _account(GitLabApi api, {int id = 7}) => Account(
  instance: api.instance,
  user: GitLabUser(id: id, username: 'reader$id', name: 'Reader $id'),
  token: 'synthetic-token',
);

Map<String, Object?> _milestone({
  int id = 5,
  String title = 'October',
  String state = 'ACTIVE',
  bool expired = false,
  String ownerPath = 'studio/mobile-workspace',
}) => {
  'id': 'gid://gitlab/Milestone/$id',
  'iid': '$id',
  'title': title,
  'state': state,
  'expired': expired,
  'dueDate': '2026-10-31',
  'startDate': '2026-10-01',
  'webPath': '/studio/mobile-workspace/-/milestones/$id',
  'project': {'id': _project.id, 'fullPath': ownerPath},
  'group': null,
};

Map<String, Object?> _workItem({
  required Object? milestone,
  required String updatedAt,
  bool includePermissions = true,
  bool canSet = true,
}) => {
  'id': 'gid://gitlab/WorkItem/31',
  'iid': '31',
  'title': 'Fresh title',
  'state': 'OPEN',
  'createdAt': '2026-10-01T00:00:00.000Z',
  'updatedAt': updatedAt,
  'project': {'id': _project.id, 'fullPath': _project.fullPath},
  'namespace': {'id': _namespace.id, 'fullPath': _namespace.fullPath},
  'workItemType': {'id': _type.id, 'name': _type.name},
  if (includePermissions)
    'userPermissions': {'readWorkItem': true, 'setWorkItemMetadata': canSet},
  'widgets': [
    {'type': 'MILESTONE', 'milestone': milestone},
  ],
};

final class _MilestoneServer {
  _MilestoneServer({
    Map<String, Object?>? current,
    List<Map<String, Object?>>? choices,
  }) : current = current ?? _milestone(),
       choices = choices ?? [_milestone(id: 6, title: 'November')];

  Map<String, Object?>? current;
  List<Map<String, Object?>> choices;
  String updatedAt = '2026-10-03T10:00:00.000Z';
  bool canSet = true;
  bool failChoices = false;
  bool rejectNextWrite = false;
  bool conflictNextPreflight = false;
  bool loseNextWriteAcknowledgement = false;
  Completer<ResponseBody>? choiceGate;
  Completer<ResponseBody>? oldSearch;
  int reads = 0;
  int choiceReads = 0;
  int writes = 0;
  Map<Object?, Object?>? lastInput;
  final List<Map<Object?, Object?>> choiceVariables = [];

  Map<String, Object?> readEnvelope({bool includePermissions = true}) => {
    'data': {
      'currentUser': {'id': 'gid://gitlab/User/7'},
      'workItem': _workItem(
        milestone: current,
        updatedAt: updatedAt,
        includePermissions: includePermissions,
        canSet: canSet,
      ),
    },
  };

  Map<String, Object?> pickerEnvelope(List<Map<String, Object?>> nodes) => {
    'data': {
      'currentUser': {'id': 'gid://gitlab/User/7'},
      'project': {
        'id': _project.id,
        'fullPath': _project.fullPath,
        'milestones': {
          'nodes': nodes,
          'pageInfo': {'hasNextPage': false, 'endCursor': null},
        },
      },
    },
  };

  Future<ResponseBody> respond(RequestOptions request) async {
    final body = request.data as Map;
    final query = body['query'] as String;
    if (query.startsWith('query MobileWorkItemMilestone(')) {
      reads++;
      if (conflictNextPreflight && reads == 2) {
        conflictNextPreflight = false;
        return jsonResponse({
          'data': {
            'currentUser': {'id': 'gid://gitlab/User/7'},
            'workItem': _workItem(
              milestone: current,
              updatedAt: '2026-10-03T10:00:01.000Z',
              canSet: canSet,
            ),
          },
        });
      }
      return jsonResponse(readEnvelope());
    }
    if (query.startsWith('query MobileProjectWorkItemMilestones(')) {
      choiceReads++;
      final variables = Map<Object?, Object?>.from(body['variables'] as Map);
      choiceVariables.add(variables);
      if (choiceGate != null) return choiceGate!.future;
      if (variables['search'] == 'old' && oldSearch != null) {
        return oldSearch!.future;
      }
      if (failChoices) {
        return jsonResponse({'message': 'synthetic outage'}, status: 503);
      }
      final search = variables['search'] as String?;
      final nodes = search == null
          ? choices
          : choices
                .where(
                  (item) => (item['title'] as String).toLowerCase().contains(
                    search.toLowerCase(),
                  ),
                )
                .toList();
      return jsonResponse(pickerEnvelope(nodes));
    }
    if (query.startsWith('mutation MobileSetWorkItemMilestone(')) {
      writes++;
      lastInput = Map<Object?, Object?>.from(
        (body['variables'] as Map)['input'] as Map,
      );
      if (rejectNextWrite) {
        rejectNextWrite = false;
        return jsonResponse({
          'data': {
            'workItemUpdate': {
              'errors': ['Synthetic rejection'],
              'workItem': null,
            },
          },
        });
      }
      if (loseNextWriteAcknowledgement) {
        loseNextWriteAcknowledgement = false;
        return jsonResponse({'message': 'lost acknowledgement'}, status: 503);
      }
      final widget = lastInput!['milestoneWidget'] as Map;
      final desiredId = widget['milestoneId'];
      current = desiredId == null
          ? null
          : choices.singleWhere((item) => item['id'] == desiredId);
      updatedAt = '2026-10-03T10:01:00.000Z';
      return jsonResponse({
        'data': {
          'workItemUpdate': {
            'errors': <Object?>[],
            'workItem': _workItem(
              milestone: current,
              updatedAt: updatedAt,
              includePermissions: false,
            ),
          },
        },
      });
    }
    throw StateError('Unexpected operation: ${query.split('\n').first}');
  }
}

final class _Owner extends ChangeNotifier {
  bool current = true;

  void replace() {
    current = false;
    notifyListeners();
  }
}

enum _Replacement { account, api, resource }

Widget _controlHost({
  required GitLabApi api,
  required ValueChanged<WorkItemMilestoneSnapshot> onSaved,
  Account? account,
  WorkItemGraphDetail? detail,
  bool Function()? isCurrent,
  Listenable? ownerChanges,
  ValueChanged<Route<dynamic>>? onRoute,
  double textScale = 1,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: WorkItemMilestoneControl(
      account: account ?? _account(api),
      api: api,
      detail: detail ?? _detail(),
      onSaved: onSaved,
      isCurrent: isCurrent,
      ownerChanges: ownerChanges,
      onRoute: onRoute,
    ),
  ),
);

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('work-item-milestone-edit')));
  await pumpUntil(
    tester,
    () => find
        .byKey(const ValueKey('work-item-milestone-save'))
        .evaluate()
        .isNotEmpty,
    description: 'milestone picker route opens',
  );
  await settleNetworkWidgets(tester);
}

WorkItemAttributeSnapshot _attributeSnapshot(Map<String, Object?>? milestone) =>
    WorkItemAttributeSnapshot(
      workItemId: _summary().id,
      iid: _summary().iid,
      project: _project,
      namespace: _namespace,
      kind: WorkItemAttributeKind.milestone,
      availability: WorkItemAttributeAvailability.present,
      value: WorkItemMilestoneAttribute(
        milestone: milestone == null
            ? null
            : WorkItemMilestoneValue(
                id: milestone['id']! as String,
                iid: int.parse(milestone['iid']! as String),
                title: milestone['title']! as String,
                state: milestone['state']! as String,
                webPath: milestone['webPath']! as String,
                dueDate: DateTime.utc(2026, 10, 31),
                startDate: DateTime.utc(2026, 10, 1),
                project: const WorkItemAttributeOwnerRef(
                  id: 'gid://gitlab/Project/42',
                  fullPath: 'studio/mobile-workspace',
                ),
                group: null,
              ),
      ),
    );

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('selects a candidate and saves the exact assignment once', (
    tester,
  ) async {
    final server = _MilestoneServer();
    final api = testApi(
      FakeAdapter(server.respond),
      host: 'https://example.com:8443/gitlab',
    );
    addTearDown(api.close);
    WorkItemMilestoneSnapshot? saved;
    await tester.pumpWidget(
      _controlHost(api: api, onSaved: (value) => saved = value),
    );

    await _openPicker(tester);
    expect(find.text('目前：October'), findsOneWidget);
    expect(find.text('November'), findsOneWidget);
    await tester.tap(find.text('November'));
    await tester.pump();
    expect(find.textContaining('將更新為：November'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('work-item-milestone-save')));
    await pumpUntil(
      tester,
      () => saved != null,
      description: 'assignment saves',
    );

    expect(server.writes, 1);
    expect(server.lastInput, {
      'id': _summary().id,
      'milestoneWidget': {'milestoneId': 'gid://gitlab/Milestone/6'},
    });
    expect(saved!.milestone!.title, 'November');
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('work-item-milestone-save')),
      findsNothing,
    );
  });

  testWidgets('milestone choices expose one checked accessible radio row', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final server = _MilestoneServer();
    final api = testApi(FakeAdapter(server.respond));
    addTearDown(api.close);
    await tester.pumpWidget(_controlHost(api: api, onSaved: (_) {}));
    await _openPicker(tester);

    final current = find.byKey(const ValueKey('work-item-milestone-current'));
    final clear = find.byKey(const ValueKey('work-item-milestone-clear'));
    final candidate = find.byKey(
      const ValueKey('work-item-milestone-choice-gid://gitlab/Milestone/6'),
    );
    void expectChoice(
      Finder finder, {
      required bool checked,
      required String label,
    }) {
      expect(finder, findsOneWidget);
      final node = tester.getSemantics(finder);
      expect(
        node,
        isSemantics(
          isButton: true,
          hasCheckedState: true,
          isChecked: checked,
          isInMutuallyExclusiveGroup: true,
          hasTapAction: true,
        ),
      );
      expect(node.label, contains(label));
      expect(
        node.childrenCountInTraversalOrder,
        0,
        reason: 'the label and radio state must be one focusable AX node',
      );
    }

    expectChoice(current, checked: true, label: '目前：October');
    expectChoice(clear, checked: false, label: '移除里程碑');
    expectChoice(candidate, checked: false, label: 'November');
    final candidateNode = tester.getSemantics(candidate);
    expect(
      candidateNode.label,
      allOf(contains('所屬：studio/mobile-workspace'), contains('到期：2026/10/31')),
    );

    await tester.tap(candidate);
    await tester.pump();

    expectChoice(current, checked: false, label: '目前：October');
    expectChoice(clear, checked: false, label: '移除里程碑');
    expectChoice(candidate, checked: true, label: 'November');
    semantics.dispose();
  });

  testWidgets('current selection saves as a no-op without a mutation', (
    tester,
  ) async {
    final server = _MilestoneServer();
    final api = testApi(FakeAdapter(server.respond));
    addTearDown(api.close);
    WorkItemMilestoneSnapshot? saved;
    await tester.pumpWidget(
      _controlHost(api: api, onSaved: (value) => saved = value),
    );
    await _openPicker(tester);

    await tester.tap(find.byKey(const ValueKey('work-item-milestone-save')));
    await pumpUntil(tester, () => saved != null, description: 'no-op closes');

    expect(server.writes, 0);
    expect(saved!.milestone!.title, 'October');
  });

  testWidgets('candidate outage still permits clearing the current milestone', (
    tester,
  ) async {
    final server = _MilestoneServer()..failChoices = true;
    final api = testApi(FakeAdapter(server.respond));
    addTearDown(api.close);
    WorkItemMilestoneSnapshot? saved;
    await tester.pumpWidget(
      _controlHost(api: api, onSaved: (value) => saved = value),
    );
    await _openPicker(tester);

    expect(find.text('GitLab 暫時無法回應'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('work-item-milestone-clear')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('work-item-milestone-clear')));
    await tester.pump();
    expect(find.text('將移除目前里程碑'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('work-item-milestone-save')));
    await pumpUntil(tester, () => saved != null, description: 'clear saves');

    expect(server.writes, 1);
    expect(
      (server.lastInput!['milestoneWidget'] as Map)['milestoneId'],
      isNull,
    );
    expect(saved!.milestone, isNull);
  });

  testWidgets('closed expired current milestone stays visible and clearable', (
    tester,
  ) async {
    final server = _MilestoneServer(
      current: _milestone(
        title: 'September release',
        state: 'CLOSED',
        expired: true,
      ),
    );
    final api = testApi(FakeAdapter(server.respond));
    addTearDown(api.close);
    await tester.pumpWidget(_controlHost(api: api, onSaved: (_) {}));
    await _openPicker(tester);

    expect(find.text('目前：September release'), findsOneWidget);
    expect(find.textContaining('已關閉'), findsOneWidget);
    expect(find.textContaining('已到期'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('work-item-milestone-clear')),
      findsOneWidget,
    );
  });

  testWidgets(
    'search only submits explicitly and stale results cannot replace new results',
    (tester) async {
      final server = _MilestoneServer(
        choices: [
          _milestone(id: 6, title: 'Old roadmap'),
          _milestone(id: 7, title: 'New roadmap'),
        ],
      )..oldSearch = Completer<ResponseBody>();
      final api = testApi(FakeAdapter(server.respond));
      addTearDown(api.close);
      await tester.pumpWidget(_controlHost(api: api, onSaved: (_) {}));
      await _openPicker(tester);
      expect(server.choiceReads, 1);

      final search = find.byType(TextField);
      await tester.enterText(search, 'old');
      await tester.pump();
      expect(
        server.choiceReads,
        1,
        reason: 'typing alone must not issue a request',
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await pumpUntil(tester, () => server.choiceReads == 2);

      await tester.enterText(search, 'new');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await pumpUntil(
        tester,
        () => find.text('New roadmap').evaluate().isNotEmpty,
        description: 'new search result appears',
      );
      expect(find.text('Old roadmap'), findsNothing);

      server.oldSearch!.complete(
        jsonResponse(
          server.pickerEnvelope([_milestone(id: 6, title: 'Old roadmap')]),
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.text('New roadmap'), findsOneWidget);
      expect(find.text('Old roadmap'), findsNothing);
      expect(server.choiceVariables.map((item) => item['search']), [
        null,
        'old',
        'new',
      ]);
    },
  );

  testWidgets(
    'failed save is sent once and locks replay until the picker reopens',
    (tester) async {
      final server = _MilestoneServer()..rejectNextWrite = true;
      final api = testApi(FakeAdapter(server.respond));
      addTearDown(api.close);
      await tester.pumpWidget(_controlHost(api: api, onSaved: (_) {}));
      await _openPicker(tester);
      await tester.tap(find.text('November'));
      await tester.tap(find.byKey(const ValueKey('work-item-milestone-save')));
      await pumpUntil(
        tester,
        () => find.text('請關閉並重新開啟，讀取最新狀態後再變更。').evaluate().isNotEmpty,
        description: 'save failure locks picker',
      );

      expect(server.writes, 1);
      expect(find.textContaining('將更新為：November'), findsOneWidget);
      expect(find.text('GitLab 未接受里程碑更新'), findsOneWidget);
      expect(find.text('里程碑設定未被接受。重新開啟後，請重新選擇里程碑。'), findsOneWidget);
      expect(find.textContaining('草稿已保留'), findsNothing);
      final save = tester.widget<FilledButton>(
        find.byKey(const ValueKey('work-item-milestone-save')),
      );
      expect(save.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('work-item-milestone-save')));
      await tester.pump();
      expect(server.writes, 1);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await _openPicker(tester);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('work-item-milestone-save')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  for (final failure in ['conflict', 'writeUncertain']) {
    testWidgets(
      '$failure save notice does not claim an in-memory choice is a saved draft',
      (tester) async {
        final server = _MilestoneServer();
        if (failure == 'conflict') {
          server.conflictNextPreflight = true;
        } else {
          server.loseNextWriteAcknowledgement = true;
        }
        final api = testApi(FakeAdapter(server.respond));
        addTearDown(api.close);
        await tester.pumpWidget(_controlHost(api: api, onSaved: (_) {}));
        await _openPicker(tester);
        await tester.tap(find.text('November'));
        await tester.tap(
          find.byKey(const ValueKey('work-item-milestone-save')),
        );
        final title = failure == 'conflict' ? '內容已經變更' : '尚未確認操作結果';
        final recovery = failure == 'conflict'
            ? '工作項目已變更，請重新開啟確認最新的里程碑設定。'
            : '連線在寫入時中斷。請重新開啟確認目前設定，避免重複送出。';
        await pumpUntil(
          tester,
          () => find.text(title).evaluate().isNotEmpty,
          description: '$failure milestone save failure is visible',
        );

        expect(find.textContaining('草稿已保留'), findsNothing);
        expect(find.text(recovery), findsOneWidget);
        expect(find.textContaining('將更新為：November'), findsOneWidget);
        expect(server.writes, failure == 'conflict' ? 0 : 1);
        final save = tester.widget<FilledButton>(
          find.byKey(const ValueKey('work-item-milestone-save')),
        );
        expect(save.onPressed, isNull);
        await tester.tap(
          find.byKey(const ValueKey('work-item-milestone-save')),
        );
        await tester.pump();
        expect(server.writes, failure == 'conflict' ? 0 : 1);
      },
    );
  }

  testWidgets('owner invalidation dismisses an open picker route', (
    tester,
  ) async {
    final owner = _Owner();
    final server = _MilestoneServer();
    final api = testApi(FakeAdapter(server.respond));
    addTearDown(api.close);
    Route<dynamic>? ownedRoute;
    await tester.pumpWidget(
      _controlHost(
        api: api,
        onSaved: (_) {},
        isCurrent: () => owner.current,
        ownerChanges: owner,
        onRoute: (route) => ownedRoute = route,
      ),
    );
    await _openPicker(tester);
    expect(ownedRoute?.isActive, isTrue);

    owner.replace();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('work-item-milestone-save')),
      findsNothing,
    );
    expect(ownedRoute?.isActive, isFalse);
    expect(server.writes, 0);
  });

  for (final replacement in _Replacement.values) {
    testWidgets(
      '${replacement.name} replacement closes the picker and ignores a late choice response',
      (tester) async {
        final pending = Completer<ResponseBody>();
        final server = _MilestoneServer()..choiceGate = pending;
        final api = testApi(FakeAdapter(server.respond));
        addTearDown(api.close);
        final replacementApi = replacement == _Replacement.api
            ? testApi(FakeAdapter(_MilestoneServer().respond))
            : api;
        if (!identical(replacementApi, api)) {
          addTearDown(replacementApi.close);
        }
        Route<dynamic>? ownedRoute;
        var saves = 0;

        Widget host({
          GitLabApi? nextApi,
          Account? account,
          WorkItemGraphDetail? detail,
        }) => _controlHost(
          api: nextApi ?? api,
          account: account,
          detail: detail,
          onSaved: (_) => saves++,
          onRoute: (route) => ownedRoute = route,
        );

        await tester.pumpWidget(host());
        await tester.tap(
          find.byKey(const ValueKey('work-item-milestone-edit')),
        );
        await pumpUntil(
          tester,
          () =>
              find
                  .byKey(const ValueKey('work-item-milestone-save'))
                  .evaluate()
                  .isNotEmpty &&
              server.choiceReads == 1,
          description: 'picker opens with a pending choice request',
        );
        expect(ownedRoute?.isActive, isTrue);

        await tester.pumpWidget(switch (replacement) {
          _Replacement.account => host(account: _account(api, id: 8)),
          _Replacement.api => host(nextApi: replacementApi),
          _Replacement.resource => host(
            detail: _detail(updatedAt: DateTime.utc(2026, 10, 3, 12)),
          ),
        });
        await tester.pumpAndSettle();
        expect(ownedRoute?.isActive, isFalse);
        expect(
          find.byKey(const ValueKey('work-item-milestone-save')),
          findsNothing,
        );

        pending.complete(
          jsonResponse(
            server.pickerEnvelope([_milestone(id: 8, title: 'Late milestone')]),
          ),
        );
        await settleNetworkWidgets(tester);

        expect(find.text('Late milestone'), findsNothing);
        expect(saves, 0);
        expect(server.writes, 0);
      },
    );
  }

  testWidgets(
    'metadata permission denial opens a read-only picker without candidate reads',
    (tester) async {
      final server = _MilestoneServer()..canSet = false;
      final api = testApi(FakeAdapter(server.respond));
      addTearDown(api.close);
      await tester.pumpWidget(_controlHost(api: api, onSaved: (_) {}));
      await _openPicker(tester);

      expect(server.choiceReads, 0);
      expect(find.text('目前帳號沒有變更里程碑的權限。'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('November'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('work-item-milestone-save')),
            )
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('successful save updates the existing milestone attribute row', (
    tester,
  ) async {
    final server = _MilestoneServer();
    final api = testApi(FakeAdapter(server.respond));
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WorkItemAttributesPanel(
              account: _account(api),
              api: api,
              detail: _detail(),
              loadAttribute: (expected, kind, {isCurrent}) async {
                expect(kind, WorkItemAttributeKind.milestone);
                return _attributeSnapshot(server.current);
              },
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('屬性'));
    await tester.pumpAndSettle();
    expect(find.text('October'), findsOneWidget);

    await _openPicker(tester);
    await tester.tap(find.text('November'));
    await tester.tap(find.byKey(const ValueKey('work-item-milestone-save')));
    await pumpUntil(
      tester,
      () =>
          server.writes == 1 &&
          find
              .byKey(const ValueKey('work-item-milestone-save'))
              .evaluate()
              .isEmpty,
      description: 'attribute row reflects confirmed milestone',
    );
    await tester.pumpAndSettle();

    expect(find.text('October'), findsNothing);
    expect(find.text('November'), findsOneWidget);
    expect(server.writes, 1);
  });

  testWidgets(
    '320dp layout at 2x text keeps the save action usable without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(640, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = _MilestoneServer(
        current: _milestone(
          title: 'A very long current milestone title for narrow screens',
          state: 'CLOSED',
          expired: true,
        ),
        choices: [
          _milestone(
            id: 6,
            title: 'A very long replacement milestone title for narrow screens',
          ),
        ],
      );
      final api = testApi(FakeAdapter(server.respond));
      addTearDown(api.close);
      await tester.pumpWidget(
        _controlHost(api: api, onSaved: (_) {}, textScale: 2),
      );
      await _openPicker(tester);

      final save = find.byKey(const ValueKey('work-item-milestone-save'));
      expect(save, findsOneWidget);
      expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
      expect(tester.getRect(save).left, greaterThanOrEqualTo(0));
      expect(tester.getRect(save).right, lessThanOrEqualTo(320));
      expect(tester.takeException(), isNull);
    },
  );
}
