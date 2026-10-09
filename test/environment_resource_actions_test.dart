import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitlab_mobile/core/gitlab_api.dart';
import 'package:gitlab_mobile/core/models.dart';
import 'package:gitlab_mobile/core/providers.dart';
import 'package:gitlab_mobile/features/auth/session_controller.dart';
import 'package:gitlab_mobile/features/workspace/project_extras.dart';
import 'package:gitlab_mobile/shared/resource_share.dart';

import 'session_test.dart' show MemoryAccountStore;
import 'support/fake_adapter.dart';
import 'support/widget_settle.dart';

const _project = Project(
  id: 42,
  name: 'Mobile Workspace',
  path: 'studio/mobile-workspace',
  defaultBranch: 'main',
);

String _apiPath(RequestOptions request) {
  final parts = request.uri.pathSegments;
  return parts.skip(parts.indexOf('v4') + 1).join('/');
}

final class _EnvironmentFixture {
  _EnvironmentFixture({
    required this.environments,
    this.deployments = const [],
    this.host = 'https://example.com/gitlab',
    this.userId = 7,
  }) {
    adapter = FakeAdapter((request) {
      switch (_apiPath(request)) {
        case 'projects/42/environments':
          return jsonResponse(environments);
        case 'projects/42/deployments':
          return jsonResponse(deployments);
        case 'projects/42':
          return jsonResponse({
            'id': 42,
            'name': 'Mobile Workspace',
            'path_with_namespace': 'studio/mobile-workspace',
            'default_branch': 'main',
          });
        default:
          throw StateError('Unexpected request: ${request.uri}');
      }
    });
    api = testApi(adapter, host: host);
    account = Account(
      instance: api.instance,
      user: GitLabUser(
        id: userId,
        username: 'developer$userId',
        name: 'Developer $userId',
      ),
      token: 'synthetic-test-token',
    );
  }

  final List<Map<String, dynamic>> environments;
  final List<Map<String, dynamic>> deployments;
  final String host;
  final int userId;
  late final FakeAdapter adapter;
  late final GitLabApi api;
  late final Account account;
}

Widget _host(Widget child, {double scale = 1}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: child,
);

final class _OwnerHarness extends StatefulWidget {
  const _OwnerHarness({
    super.key,
    required this.first,
    required this.second,
  });

  final _EnvironmentFixture first;
  final _EnvironmentFixture second;

  @override
  State<_OwnerHarness> createState() => _OwnerHarnessState();
}

final class _OwnerHarnessState extends State<_OwnerHarness> {
  bool replaced = false;

  void replace() => setState(() => replaced = true);
  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final fixture = replaced ? widget.second : widget.first;
    return EnvironmentsPage(
      account: fixture.account,
      api: fixture.api,
      project: _project,
    );
  }
}

final class _DeploymentOwnerHarness extends StatefulWidget {
  const _DeploymentOwnerHarness({
    super.key,
    required this.first,
    required this.second,
  });

  final _EnvironmentFixture first;
  final _EnvironmentFixture second;

  @override
  State<_DeploymentOwnerHarness> createState() =>
      _DeploymentOwnerHarnessState();
}

final class _DeploymentOwnerHarnessState
    extends State<_DeploymentOwnerHarness> {
  bool replaced = false;

  void replace() => setState(() => replaced = true);

  @override
  Widget build(BuildContext context) {
    final fixture = replaced ? widget.second : widget.first;
    return DeploymentsPage(
      account: fixture.account,
      api: fixture.api,
      project: _project,
      environment: 'production',
      environmentId: 9,
    );
  }
}

Future<void> _openEnvironment(WidgetTester tester, String name) async {
  await settleNetworkWidgets(tester);
  await tester.tap(find.text(name));
  await settleNetworkWidgets(tester);
}

void main() {
  testWidgets(
    'filtered deployments share the positive environment ID on the instance',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 900);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final fixture = _EnvironmentFixture(
        host: 'https://example.com:8443/gitlab/root',
        environments: [
          {
            'id': 9,
            'name': 'production/primary',
            'state': 'available',
            'tier': 'production',
            'external_url': 'https://deploy.example/app',
          },
        ],
      );
      addTearDown(fixture.api.close);

      await tester.pumpWidget(
        _host(
          EnvironmentsPage(
            account: fixture.account,
            api: fixture.api,
            project: _project,
          ),
          scale: 2,
        ),
      );
      await settleNetworkWidgets(tester);
      expect(find.byTooltip('開啟部署目標 production/primary'), findsOneWidget);

      await tester.tap(find.text('production/primary'));
      await settleNetworkWidgets(tester);

      final share = tester.widget<ResourceShareButton>(
        find.byType(ResourceShareButton),
      );
      expect(
        share.uri.toString(),
        'https://example.com:8443/gitlab/root/studio/mobile-workspace/-/environments/9',
      );
      expect(share.uri.path, isNot(contains('production')));
      expect(find.byTooltip('在 GitLab 開啟'), findsOneWidget);
      expect(
        tester.getRect(find.byTooltip('在 GitLab 開啟')).right,
        lessThanOrEqualTo(320),
      );
      expect(tester.takeException(), isNull);
      expect(
        fixture.adapter.requests
            .where((request) => _apiPath(request) == 'projects/42/deployments')
            .single
            .uri
            .queryParameters['environment'],
        'production/primary',
      );
    },
  );

  for (final id in [null, 0, -1]) {
    testWidgets('environment ID $id omits canonical actions', (tester) async {
      final fixture = _EnvironmentFixture(
        environments: [
          {
            'id': ?id,
            'name': 'review/missing-id',
            'state': 'available',
          },
        ],
      );
      addTearDown(fixture.api.close);
      await tester.pumpWidget(
        _host(
          EnvironmentsPage(
            account: fixture.account,
            api: fixture.api,
            project: _project,
          ),
        ),
      );
      await _openEnvironment(tester, 'review/missing-id');
      expect(find.byType(ResourceShareButton), findsNothing);
      expect(find.byTooltip('在 GitLab 開啟'), findsNothing);
    });
  }

  testWidgets('unfiltered deployments omit environment actions', (tester) async {
    final fixture = _EnvironmentFixture(environments: const []);
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      _host(
        DeploymentsPage(
          account: fixture.account,
          api: fixture.api,
          project: _project,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.byType(ResourceShareButton), findsNothing);
    expect(find.byTooltip('在 GitLab 開啟'), findsNothing);
  });

  testWidgets('unsafe deployment target is not actionable', (tester) async {
    final fixture = _EnvironmentFixture(
      environments: const [
        {
          'id': 9,
          'name': 'production',
          'state': 'available',
          'external_url': 'http://unsafe.example/token?private_token=secret',
        },
      ],
    );
    addTearDown(fixture.api.close);
    await tester.pumpWidget(
      _host(
        EnvironmentsPage(
          account: fixture.account,
          api: fixture.api,
          project: _project,
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    expect(find.byTooltip('開啟部署目標 production'), findsNothing);
  });

  testWidgets('same project ID owner replacement removes the nested route', (
    tester,
  ) async {
    final first = _EnvironmentFixture(
      environments: const [
        {'id': 9, 'name': 'First private environment', 'state': 'available'},
      ],
    );
    final second = _EnvironmentFixture(
      host: 'https://next.example/gitlab',
      userId: 8,
      environments: const [
        {'id': 10, 'name': 'Second environment', 'state': 'available'},
      ],
    );
    addTearDown(first.api.close);
    addTearDown(second.api.close);
    final key = GlobalKey<_OwnerHarnessState>();
    await tester.pumpWidget(
      _host(_OwnerHarness(key: key, first: first, second: second)),
    );
    await _openEnvironment(tester, 'First private environment');
    expect(find.text('部署 · First private environment'), findsOneWidget);

    key.currentState!.replace();
    await settleNetworkWidgets(tester);

    expect(find.text('部署 · First private environment'), findsNothing);
    expect(find.text('First private environment'), findsNothing);
    expect(find.text('Second environment'), findsOneWidget);
    expect(first.adapter.requests, hasLength(2));
    expect(second.adapter.requests, hasLength(1));
  });

  testWidgets('closed API rebuild hides rows and dismisses nested route', (
    tester,
  ) async {
    final fixture = _EnvironmentFixture(
      environments: const [
        {'id': 9, 'name': 'Closing private environment', 'state': 'available'},
      ],
    );
    addTearDown(() {
      if (!fixture.api.isClosed) fixture.api.close();
    });
    final key = GlobalKey<_OwnerHarnessState>();
    await tester.pumpWidget(
      _host(_OwnerHarness(key: key, first: fixture, second: fixture)),
    );
    await _openEnvironment(tester, 'Closing private environment');
    final share = tester.widget<ResourceShareButton>(
      find.byType(ResourceShareButton),
    );
    expect(share.isCurrent?.call(), isTrue);
    fixture.api.close();
    key.currentState!.rebuild();
    await tester.pumpAndSettle();

    expect(share.isCurrent?.call(), isFalse);
    expect(find.text('部署 · Closing private environment'), findsNothing);
    expect(find.text('Closing private environment'), findsNothing);
    expect(find.byType(ResourceShareButton), findsNothing);
  });

  testWidgets('ending the session hides rows and dismisses nested route', (
    tester,
  ) async {
    final fixture = _EnvironmentFixture(
      environments: const [
        {'id': 9, 'name': 'Session private environment', 'state': 'available'},
      ],
    );
    final session = SessionController(MemoryAccountStore())
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    addTearDown(session.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _host(
          EnvironmentsPage(
            account: fixture.account,
            api: fixture.api,
            project: _project,
          ),
        ),
      ),
    );
    await _openEnvironment(tester, 'Session private environment');
    final share = tester.widget<ResourceShareButton>(
      find.byType(ResourceShareButton),
    );
    expect(share.isCurrent?.call(), isTrue);
    await session.endSession();
    await tester.pumpAndSettle();

    expect(share.isCurrent?.call(), isFalse);
    expect(find.text('部署 · Session private environment'), findsNothing);
    expect(find.text('Session private environment'), findsNothing);
    expect(find.byType(ResourceShareButton), findsNothing);
  });

  testWidgets('present mismatched session fails closed without a request', (
    tester,
  ) async {
    final fixture = _EnvironmentFixture(
      environments: const [
        {'id': 9, 'name': 'Denied private environment', 'state': 'available'},
      ],
    );
    final active = _EnvironmentFixture(
      host: 'https://active.example/gitlab',
      userId: 8,
      environments: const [],
    );
    final session = SessionController(MemoryAccountStore())
      ..active = active.account
      ..api = active.api
      ..initializing = false;
    addTearDown(fixture.api.close);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _host(
          EnvironmentsPage(
            account: fixture.account,
            api: fixture.api,
            project: _project,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Denied private environment'), findsNothing);
    expect(fixture.adapter.requests, isEmpty);
  });

  testWidgets('mismatched session hides a filtered deployment owner', (
    tester,
  ) async {
    final fixture = _EnvironmentFixture(environments: const []);
    final active = _EnvironmentFixture(
      host: 'https://active.example/gitlab',
      userId: 8,
      environments: const [],
    );
    final session = SessionController(MemoryAccountStore())
      ..active = active.account
      ..api = active.api
      ..initializing = false;
    addTearDown(fixture.api.close);
    addTearDown(session.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _host(
          DeploymentsPage(
            account: fixture.account,
            api: fixture.api,
            project: _project,
            environment: 'Private production',
            environmentId: 9,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('部署 · Private production'), findsNothing);
    expect(find.byType(ResourceShareButton), findsNothing);
    expect(find.byTooltip('在 GitLab 開啟'), findsNothing);
    expect(fixture.adapter.requests, isEmpty);
  });

  testWidgets('deployment owner replacement dismisses an opened job route', (
    tester,
  ) async {
    final first = _EnvironmentFixture(
      environments: const [],
      deployments: const [
        {
          'id': 81,
          'iid': 3,
          'status': 'success',
          'environment': {'name': 'production'},
          'deployable': {'id': 77},
        },
      ],
    );
    final second = _EnvironmentFixture(
      host: 'https://next.example/gitlab',
      userId: 8,
      environments: const [],
    );
    addTearDown(first.api.close);
    addTearDown(second.api.close);
    final key = GlobalKey<_DeploymentOwnerHarnessState>();
    await tester.pumpWidget(
      _host(_DeploymentOwnerHarness(key: key, first: first, second: second)),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('#3'));
    await tester.pumpAndSettle();
    expect(find.text('Job #77'), findsOneWidget);

    key.currentState!.replace();
    await tester.pumpAndSettle();

    expect(find.text('Job #77'), findsNothing);
    expect(find.text('部署 · production'), findsOneWidget);
  });

  testWidgets('session ending dismisses a job opened from deployments', (
    tester,
  ) async {
    final fixture = _EnvironmentFixture(
      environments: const [],
      deployments: const [
        {
          'id': 81,
          'iid': 3,
          'status': 'success',
          'environment': {'name': 'production'},
          'deployable': {'id': 77},
        },
      ],
    );
    final session = SessionController(MemoryAccountStore())
      ..active = fixture.account
      ..api = fixture.api
      ..initializing = false;
    addTearDown(session.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWithValue(session)],
        child: _host(
          DeploymentsPage(
            account: fixture.account,
            api: fixture.api,
            project: _project,
            environment: 'production',
            environmentId: 9,
          ),
        ),
      ),
    );
    await settleNetworkWidgets(tester);
    await tester.tap(find.text('#3'));
    await tester.pumpAndSettle();
    expect(find.text('Job #77'), findsOneWidget);

    await session.endSession();
    await tester.pumpAndSettle();

    expect(find.text('Job #77'), findsNothing);
    expect(find.text('部署 · production'), findsNothing);
  });
}
