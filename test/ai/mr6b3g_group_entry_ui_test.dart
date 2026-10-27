import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/ai/ai_display.dart';
import 'package:gitlab_mobile/core/ai/ai_failure.dart';
import 'package:gitlab_mobile/core/ai/ai_provider.dart';
import 'package:gitlab_mobile/core/ai/runner.dart';
import 'package:gitlab_mobile/core/failure.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/core/work_item_graph_models.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_page.dart';
import 'package:gitlab_mobile/features/ai/ai_chat_session.dart';
import 'package:gitlab_mobile/features/ai/ai_history.dart';
import 'package:gitlab_mobile/features/ai/ai_scope.dart';
import 'package:gitlab_mobile/features/ai/ai_stores.dart';
import 'package:gitlab_mobile/features/auth/account_store.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/graph_work_items_page.dart';
import 'package:gitlab_mobile/l10n/l10n.dart';
import 'package:gitlab_mobile/shared/theme.dart';

import '../support/fake_adapter.dart';
import '../support/widget_settle.dart';

const _group = GraphResourceRef(id: 'gid://gitlab/Group/9', fullPath: 'team');
const _projectNamespace = GraphResourceRef(
  id: 'gid://gitlab/Namespaces::ProjectNamespace/42',
  fullPath: 'team/app',
);
const _projectRef = GraphResourceRef(
  id: 'gid://gitlab/Project/42',
  fullPath: 'team/app',
);
const _aiEntry = ValueKey('graph-work-item-ai');

final class _Session extends ChangeNotifier implements AiChatSession {
  _Session(this.origin, {List<AiChatItem>? items}) : items = items ?? [];

  @override
  final AiChatOrigin origin;
  @override
  String get id => origin.key;
  @override
  List<AiChatItem> items;
  @override
  AiChatPhase get phase => AiChatPhase.idle;
  @override
  AiChatBlocker get blocker => AiChatBlocker.noProvider;
  @override
  List<AiProviderConfig> get providers => const [];
  @override
  AiProviderConfig? get provider => null;
  @override
  AiConsentContract? get consentRequest => null;
  @override
  AiFailure? get failure => null;
  @override
  AiRunEnd? get lastEnd => null;
  @override
  bool get offerNewConversation => false;
  @override
  bool get historySaved => false;
  @override
  bool get reportNotSaved => false;
  @override
  AiAssistantItem? currentOf(AiAssistantItem item) =>
      items.contains(item) ? item : null;
  @override
  Future<bool> refreshSecrets() async => true;
  @override
  bool get canSend => false;
  @override
  Future<void> send(String text) async {}
  @override
  void stop() {}
  @override
  void startNewConversation() {}
  @override
  Future<void> useProvider(String providerId) async {}
  @override
  Future<void> recheck() async {}
  @override
  void markReported(AiAssistantItem item) {}
  @override
  set confirmCleartext(Future<bool> Function()? callback) {}
  @override
  String displaySafe(String text) => text;
  @override
  String draftSafe(String text) => text;
}

final class _Registry extends ChangeNotifier implements AiRunRegistry {
  final opened = <AiChatOrigin>[];
  final released = <AiChatSession>[];

  @override
  AiChatSession open(AiChatOrigin origin) {
    opened.add(origin);
    return _Session(origin);
  }

  @override
  void release(AiChatSession session) => released.add(session);

  @override
  int get runningCount => 0;
}

Map<String, Object?> _body(RequestOptions request) =>
    Map<String, Object?>.from(request.data as Map);

String _query(RequestOptions request) => _body(request)['query']! as String;

bool _isDetail(RequestOptions request) =>
    request.method == 'POST' &&
    _query(request).contains('MobileNamespaceWorkItem(');

/// A synthetic GitLab with one group-owned item (#7) and one descendant
/// project item (#5) in `team/app`. Unknown requests are recorded and fail.
final class _Server {
  _Server() {
    adapter = FakeAdapter(_respond);
    api = testApi(adapter);
    account = Account(
      instance: api.instance,
      user: const GitLabUser(id: 7, username: 'ada', name: 'Ada'),
      token: 'synthetic-test-token',
    );
  }

  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final Account account;
  final unexpected = <String>[];

  /// Holds the detail read with this number (1-based) until completed.
  int? holdDetail;
  final held = Completer<void>();
  int detailReads = 0;
  int groupReads = 0;
  int groupStatus = 200;

  int get freshReads => detailReads;

  Map<String, Object?> _summary(int iid) {
    final project = iid == 5;
    final owner = project ? _projectNamespace : _group;
    return {
      'id': 'gid://gitlab/WorkItem/${700 + iid}',
      'iid': '$iid',
      'title': project ? 'Descendant task' : 'Group planning item',
      'state': 'OPEN',
      'createdAt': '2026-10-01T01:02:03Z',
      'updatedAt': '2026-10-02T03:04:05Z',
      'project': project
          ? {'id': _projectRef.id, 'fullPath': _projectRef.fullPath}
          : null,
      'namespace': {'id': owner.id, 'fullPath': owner.fullPath},
      'workItemType': {
        'id': 'gid://gitlab/WorkItems::Type/99',
        'name': 'Objective',
      },
      'widgets': const <Object?>[],
    };
  }

  FutureOr<ResponseBody> _respond(RequestOptions request) async {
    final segments = request.uri.pathSegments;
    if (request.method == 'GET' && segments.contains('groups')) {
      groupReads++;
      if (groupStatus != 200) {
        return jsonResponse({'message': '404 Not found'}, status: groupStatus);
      }
      return jsonResponse({'id': 9, 'full_path': _group.fullPath});
    }
    if (request.method == 'GET' && segments.contains('projects')) {
      return jsonResponse({
        ...projectJson(42),
        'path_with_namespace': _projectRef.fullPath,
      });
    }
    if (request.method != 'POST') {
      unexpected.add('${request.method} ${request.uri.path}');
      throw StateError('Unexpected ${request.uri}');
    }
    final query = _query(request);
    final variables = Map<String, Object?>.from(
      _body(request)['variables']! as Map,
    );
    if (query.contains('MobileGroupWorkItems')) {
      return jsonResponse({
        'data': {
          'group': {
            'id': _group.id,
            'fullPath': _group.fullPath,
            'workItems': {
              'nodes': [_summary(7), _summary(5)],
              'pageInfo': {'hasNextPage': false, 'endCursor': null},
            },
          },
        },
      });
    }
    if (query.contains('MobileNamespaceWorkItemTypes')) {
      return jsonResponse({
        'data': {
          'namespace': {
            'id': _group.id,
            'fullPath': _group.fullPath,
            'workItemTypes': {
              'nodes': [
                {
                  'id': 'gid://gitlab/WorkItems::Type/99',
                  'name': 'Objective',
                  'enabled': true,
                  'isGroupWorkItemType': true,
                  'widgetDefinitions': <Object?>[],
                },
              ],
              'pageInfo': {'hasNextPage': false, 'endCursor': null},
            },
          },
        },
      });
    }
    if (query.contains('MobileWorkItemState')) {
      final iid = int.parse('${variables['iid'] ?? 7}');
      final summary = _summary(iid == 5 ? 5 : 7);
      return jsonResponse({
        'data': {
          'workItem': {
            'id': summary['id'],
            'iid': summary['iid'],
            'state': 'OPEN',
            'updatedAt': summary['updatedAt'],
            'project': summary['project'],
            'namespace': summary['namespace'],
            'workItemType': {'id': 'gid://gitlab/WorkItems::Type/99'},
            'userPermissions': {'updateWorkItem': false},
          },
        },
      });
    }
    if (query.contains('MobileProjectWorkItem(')) {
      return jsonResponse({
        'data': {
          'project': {
            'id': _projectRef.id,
            'fullPath': _projectRef.fullPath,
            'workItems': {
              'nodes': [
                {..._summary(5), 'description': ''},
              ],
              'pageInfo': {'hasNextPage': false, 'endCursor': null},
            },
          },
        },
      });
    }
    if (_isDetail(request)) {
      detailReads++;
      if (detailReads == holdDetail) await held.future;
      final iid = int.parse(variables['iid']! as String);
      final summary = _summary(iid);
      final owner = iid == 5 ? _projectNamespace : _group;
      if (variables['path'] != owner.fullPath) {
        return jsonResponse({
          'data': {'namespace': null},
        });
      }
      return jsonResponse({
        'data': {
          'namespace': {
            'id': owner.id,
            'fullPath': owner.fullPath,
            'workItem': {...summary, 'description': ''},
          },
        },
      });
    }
    unexpected.add(query.split('\n').first);
    throw StateError('Unexpected query');
  }
}

/// AI sits above the app, as in AuthenticatedApp, so pushed routes see it.
Future<_Registry?> _pump(
  WidgetTester tester,
  _Server server,
  Widget page, {
  bool ai = true,
  required SessionController owner,
  Size size = const Size(412, 900),
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final app = MaterialApp(
    theme: appTheme(Brightness.light),
    locale: const Locale('zh', 'TW'),
    supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: page,
  );
  if (!ai) {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(owner)],
        child: app,
      ),
    );
    await settleNetworkWidgets(tester);
    return null;
  }
  final store = MemoryAiStore();
  final settings = AiSettingsController(store);
  final history = AiHistoryCoordinator(store: store);
  addTearDown(settings.dispose);
  addTearDown(history.dispose);
  final registry = _Registry();
  addTearDown(registry.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sessionProvider.overrideWithValue(owner)],
      child: AiScope(
        controllers: AiControllers(settings: settings, history: history),
        accountKey: server.account.key,
        child: AiRunRegistryScope(registry: registry, child: app),
      ),
    ),
  );
  await settleNetworkWidgets(tester);
  return registry;
}

SessionController _owner(_Server server) {
  final owner = SessionController(SecureAccountStore())
    ..active = server.account
    ..api = server.api
    ..initializing = false;
  addTearDown(owner.dispose);
  return owner;
}

GraphWorkItemDetailPage _groupDetail(
  _Server server,
  SessionController owner, {
  GraphResourceRef? viewGroup = _group,
  GraphResourceRef namespace = _group,
  int iid = 7,
}) => GraphWorkItemDetailPage.namespace(
  account: server.account,
  api: server.api,
  namespacePath: namespace.fullPath,
  expectedNamespaceId: namespace.id,
  iid: iid,
  ownerChanges: owner,
  viewGroup: viewGroup,
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'the group list hands its own group to the detail, which opens AI fresh',
    (tester) async {
      final server = _Server();
      addTearDown(server.api.close);
      final owner = _owner(server);
      final registry = (await _pump(
        tester,
        server,
        Scaffold(
          body: GraphWorkItemsPage.group(
            account: server.account,
            api: server.api,
            namespacePath: _group.fullPath,
            ownerChanges: owner,
          ),
        ),
        owner: owner,
      ))!;
      // The list itself offers no AI entry.
      expect(find.byKey(_aiEntry), findsNothing);

      await tester.tap(find.text('Group planning item'));
      await settleNetworkWidgets(tester);
      final entry = find.byKey(_aiEntry);
      expect(entry, findsOneWidget);
      expect(find.byTooltip(l10n.aiDiscuss), findsOneWidget);
      expect(tester.widget<IconButton>(entry).onPressed, isNotNull);

      final readsBefore = server.freshReads;
      await tester.tap(entry);
      await settleNetworkWidgets(tester);
      // The owner group and the item are read again before the chat opens.
      expect(server.groupReads, 1);
      expect(server.freshReads, readsBefore + 1);
      expect(registry.opened, hasLength(1));
      final origin = registry.opened.single;
      expect(origin, isA<AiGroupWorkItemOrigin>());
      expect(origin.key, 'group-item:9:7');
      expect((origin as AiGroupWorkItemOrigin).title, 'Group planning item');
      expect(find.byType(AiChatPage), findsOneWidget);

      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settleNetworkWidgets(tester);
      expect(registry.released, hasLength(1));
      expect(tester.widget<IconButton>(entry).onPressed, isNotNull);

      // A descendant project item keeps its project as owner and the list's
      // group only as the entry point.
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await settleNetworkWidgets(tester);
      await tester.tap(find.text('Descendant task'));
      await settleNetworkWidgets(tester);
      await tester.tap(find.byKey(_aiEntry));
      await settleNetworkWidgets(tester);
      expect(registry.opened, hasLength(2));
      expect(registry.opened.last, isA<AiProjectWorkItemFromGroupPageOrigin>());
      expect(registry.opened.last.key, 'group-page:9:project:42:workItem:5');
      expect(server.unexpected, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('without AI built in a group-opened detail has no AI entry', (
    tester,
  ) async {
    final server = _Server();
    addTearDown(server.api.close);
    final owner = _owner(server);
    await _pump(
      tester,
      server,
      _groupDetail(server, owner),
      ai: false,
      owner: owner,
    );
    expect(find.text('Group planning item'), findsOneWidget);
    expect(find.byKey(_aiEntry), findsNothing);
    expect(find.byTooltip(l10n.aiDiscuss), findsNothing);
    expect(server.unexpected, isEmpty);
  });

  testWidgets('a detail not opened from a group list has no AI entry', (
    tester,
  ) async {
    final server = _Server();
    addTearDown(server.api.close);
    final owner = _owner(server);
    // Same group item, but no viewing group handed over (a parent or child
    // link, or any other opener).
    final registry = (await _pump(
      tester,
      server,
      _groupDetail(server, owner, viewGroup: null),
      owner: owner,
    ))!;
    expect(find.text('Group planning item'), findsOneWidget);
    expect(find.byKey(_aiEntry), findsNothing);

    // A project-only detail page never takes a viewing group.
    final project = Project.fromJson({
      ...projectJson(42),
      'path_with_namespace': _projectRef.fullPath,
    });
    await tester.pumpWidget(const SizedBox.shrink());
    await _pump(
      tester,
      server,
      GraphWorkItemDetailPage.project(
        account: server.account,
        api: server.api,
        project: project,
        iid: 5,
        ownerChanges: owner,
      ),
      owner: owner,
    );
    expect(find.text('Descendant task'), findsOneWidget);
    expect(find.byKey(_aiEntry), findsNothing);
    expect(find.byTooltip(l10n.aiDiscuss), findsNothing);
    expect(registry.opened, isEmpty);
    expect(server.unexpected, isEmpty);
  });

  testWidgets('the header with the AI entry fits 320dp at 2x text scale', (
    tester,
  ) async {
    final server = _Server();
    addTearDown(server.api.close);
    final owner = _owner(server);
    await _pump(
      tester,
      server,
      _groupDetail(server, owner),
      owner: owner,
      size: const Size(320, 1000),
      scale: 2,
    );
    expect(find.text('工作項目 #7'), findsOneWidget);
    expect(find.byTooltip(l10n.aiDiscuss), findsOneWidget);
    expect(find.byTooltip('分享連結'), findsOneWidget);
    expect(find.byTooltip('重新整理'), findsOneWidget);
    final ai = tester.getRect(find.byKey(_aiEntry));
    final title = tester.getRect(find.text('工作項目 #7'));
    expect(ai.left, greaterThanOrEqualTo(title.right));
    expect(ai.size.width, greaterThanOrEqualTo(48));
    expect(
      tester.getRect(find.byTooltip('重新整理')).right,
      lessThanOrEqualTo(320),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a value that is not a Group GID offers no entry', (
    tester,
  ) async {
    final server = _Server();
    addTearDown(server.api.close);
    final owner = _owner(server);
    await _pump(
      tester,
      server,
      _groupDetail(
        server,
        owner,
        viewGroup: const GraphResourceRef(
          id: 'gid://gitlab/Project/9',
          fullPath: 'team',
        ),
      ),
      owner: owner,
    );
    expect(find.text('Group planning item'), findsOneWidget);
    expect(find.byKey(_aiEntry), findsNothing);
  });

  for (final (name, change)
      in <(String, void Function(SessionController, _Server))>[
        ('a session generation', (owner, _) => owner.generation++),
        (
          'an API client',
          (owner, server) {
            final replacement = testApi(FakeAdapter((_) => jsonResponse({})));
            addTearDown(replacement.close);
            owner.api = replacement;
          },
        ),
        (
          'an account',
          (owner, server) {
            owner.active = Account(
              instance: server.api.instance,
              user: const GitLabUser(id: 8, username: 'bob', name: 'Bob'),
              token: 'synthetic-test-token',
            );
          },
        ),
      ]) {
    testWidgets('an owner read finishing after $name change opens nothing', (
      tester,
    ) async {
      final server = _Server();
      addTearDown(server.api.close);
      final owner = _owner(server);
      final registry = (await _pump(
        tester,
        server,
        _groupDetail(server, owner),
        owner: owner,
      ))!;
      expect(find.byKey(_aiEntry), findsOneWidget);
      server.holdDetail = server.detailReads + 1;
      await tester.tap(find.byKey(_aiEntry));
      await pumpUntil(
        tester,
        () => server.detailReads == server.holdDetail,
        description: 'fresh owner read starts',
      );
      // While the read runs the entry cannot be pressed again.
      expect(tester.widget<IconButton>(find.byKey(_aiEntry)).onPressed, isNull);
      change(owner, server);
      server.held.complete();
      await settleNetworkWidgets(tester);
      expect(registry.opened, isEmpty);
      expect(find.byType(AiChatPage), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(server.unexpected, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a failed owner read is shown and opens nothing', (tester) async {
    final server = _Server()..groupStatus = 404;
    addTearDown(server.api.close);
    final owner = _owner(server);
    final registry = (await _pump(
      tester,
      server,
      _groupDetail(server, owner),
      owner: owner,
    ))!;
    await tester.tap(find.byKey(_aiEntry));
    await settleNetworkWidgets(tester);
    expect(registry.opened, isEmpty);
    const failure = ApiFailure(FailureKind.invisible);
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining(failure.title),
      ),
      findsOneWidget,
    );
    // The page stays and the entry can be tried again.
    expect(find.text('Group planning item'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(_aiEntry)).onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a group Work Item read has its own tool label', (tester) async {
    final session = _Session(
      AiGroupWorkItemOrigin(group: _group, iid: 7, title: 'Item'),
      items: const [
        AiToolRunItem(
          name: 'get_group_work_item',
          argsPreview: '#7',
          status: AiToolRunStatus.completed,
          sizeChars: 40,
          provenance: '',
        ),
      ],
    );
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        locale: const Locale('zh', 'TW'),
        supportedLocales: const [Locale('zh', 'TW'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: AiChatPage(session: session),
      ),
    );
    await tester.pump();
    expect(find.text('讀取群組工作項目 · #7'), findsOneWidget);
    expect(find.text(l10n.aiToolUnknown), findsNothing);
  });
}
