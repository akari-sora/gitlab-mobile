import 'dart:async';

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
import 'package:gitlab_mobile/features/workspace/project_page.dart';
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
  }, growable: false);

  @override
  FutureOr<ResponseBody> respond(RequestOptions request) {
    final segments = request.uri.pathSegments;
    final apiStart = segments.indexOf('v4');
    final path = segments.skip(apiStart + 1).join('/');
    final method = request.method;
    if (path == 'todos' && method == 'GET') {
      return jsonResponse(todoRows);
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
            onReset: _resetSession,
            child: child ?? const SizedBox.shrink(),
          ),
          home: _QaLanding(runtime: runtime),
        ),
      ),
    );
  }
}

class _QaChrome extends StatelessWidget {
  const _QaChrome({
    required this.session,
    required this.onReset,
    required this.child,
  });

  final SessionController session;
  final VoidCallback onReset;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      bottom: false,
      child: Column(
        verticalDirection: VerticalDirection.up,
        children: [
          Expanded(child: child),
          ListenableBuilder(
            listenable: session,
            builder: (context, _) => Container(
              key: const ValueKey('emulator-qa-controls'),
              width: double.infinity,
              color: Theme.of(context).colorScheme.surfaceContainerHigh,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  OutlinedButton.icon(
                    onPressed: onReset,
                    icon: const Icon(Icons.restart_alt, size: 18),
                    label: const Text('重設 Session'),
                  ),
                  OutlinedButton.icon(
                    onPressed: session.active == null
                        ? null
                        : () => unawaited(session.endSession()),
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('結束 Session'),
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
